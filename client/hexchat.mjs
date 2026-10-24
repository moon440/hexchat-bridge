/* * hexchat.mjs - part of hexchat-bridge, the HexChat agent control bridge
 * Copyright (C) 2026 moon440
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU Affero General Public License as published
 * by the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU Affero General Public License for more details.
 *
 * You should have received a copy of the GNU Affero General Public License
 * along with this program.  If not, see <https://www.gnu.org/licenses/>.
 *
 */
// hexchat.mjs -- CLI client for the HexChat hexchat-bridge (Lua plugin bridge).
// Usage:
//   node hexchat.mjs <method> ['{"json":"args"}']   e.g. node hexchat.mjs join '{"channel":"#x","network":"Libera"}'
//   node hexchat.mjs health                         bridge heartbeat freshness
//   node hexchat.mjs events [limit] [channel]       tail captured chat log (works offline, reads file)
// Methods: ping status servlist buffers connect disconnect open close join part say msg
//          command raw nick topic history clear_history
import fs from "node:fs/promises";
import path from "node:path";
import os from "node:os";
import crypto from "node:crypto";

const APPDATA = process.env.APPDATA || path.join(os.homedir(), "AppData", "Roaming");
const DIR = path.join(APPDATA, "HexChat", "hexchat-bridge");
const CMD = path.join(DIR, "cmd.json");
const RESP = path.join(DIR, "resp.json");
const STATUS = path.join(DIR, "status.json");
const EVENTS = path.join(DIR, "events.jsonl");
const TOKEN = path.join(DIR, "token.txt");

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

async function ensureDir() { await fs.mkdir(DIR, { recursive: true }); }

// Shared token: first client creates it; bridge refuses commands without it.
// Threat model: stops other local processes/users from driving the client
// blindly; NOT protection against malware that can already read your profile.
async function getToken() {
  try {
    const t = (await fs.readFile(TOKEN, "utf8")).trim();
    if (t) return t;
  } catch {}
  const t = crypto.randomBytes(24).toString("hex");
  try { await fs.writeFile(TOKEN, t, "utf8"); } catch {}
  return t;
}

export async function call(method, args = {}, timeoutMs = 15000) {
  await ensureDir();
  const token = await getToken();
  const id = crypto.randomBytes(8).toString("hex");
  const body = JSON.stringify({ id, token, ts: Math.floor(Date.now() / 1000), method, args });
  const tmp = path.join(DIR, `cmd.${process.pid}.${Date.now()}.tmp.json`);
  await fs.writeFile(tmp, body, "utf8");
  // atomic-ish handoff with retry (rename fails if another writer won the race)
  const handoffDeadline = Date.now() + 3000;
  for (;;) {
    try { await fs.rename(tmp, CMD); break; }
    catch (e) {
      if (e.code !== "EEXIST" && e.code !== "EPERM") throw e;
      if (Date.now() > handoffDeadline) throw new Error("bridge cmd handoff busy");
      await sleep(80);
    }
  }
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    let j = null;
    try { j = JSON.parse(await fs.readFile(RESP, "utf8")); } catch { /* torn/partial read, retry */ }
    if (j && j.id === id) {
      if (!j.ok) throw new Error("hexchat bridge error: " + j.error);
      return j.result;
    }
    await sleep(120);
  }
  throw new Error(`hexchat bridge timeout after ${timeoutMs}ms. Is HexChat running with the hexchat-bridge addon loaded? (must be connected to a network first)`);
}

export async function health() {
  await ensureDir();
  try {
    const st = JSON.parse(await fs.readFile(STATUS, "utf8"));
    const age = Math.floor(Date.now() / 1000) - st.last_poll;
    return { alive: age < 6, last_poll: st.last_poll, age_seconds: age };
  } catch (e) {
    return { alive: false, error: String(e.message) };
  }
}

export async function tailEvents(limit = 50, channel = null) {
  let raw = "";
  try { raw = await fs.readFile(EVENTS, "utf8"); } catch { return []; }
  const lines = raw.split("\n").filter((l) => l.trim());
  const events = [];
  for (const l of lines) { try { events.push(JSON.parse(l)); } catch {} }
  const filtered = channel ? events.filter((e) => e.channel === channel) : events;
  return filtered.slice(-limit);
}

// ---- CLI (only when run directly, not when imported) ----
import { pathToFileURL } from "node:url";
const isMain = process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href;
if (isMain) {
  const [, , method, arg1, arg2] = process.argv;
  if (!method) {
    console.log("usage: node hexchat.mjs <method> ['{json}'] | health | events [limit] [channel]");
    process.exit(0);
  }
  try {
    if (method === "health") {
      console.log(JSON.stringify(await health(), null, 2));
    } else if (method === "events") {
      console.log(JSON.stringify(await tailEvents(parseInt(arg1 || "50"), arg2 || null), null, 2));
    } else {
      const args = arg1 ? JSON.parse(arg1) : {};
      console.log(JSON.stringify(await call(method, args), null, 2));
    }
  } catch (e) {
    console.error(e.message);
    process.exit(1);
  }
}
