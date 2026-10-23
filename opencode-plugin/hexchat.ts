/* * hexchat.ts - part of hexchat-bridge, the HexChat agent control bridge
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
// .opencode/plugins/hexchat.ts
// Registers `hexchat_control` + `hexchat_events` tools so any agent in this
// project can fully drive the HexChat IRC client through the hexchat-bridge Lua
// plugin (file RPC in %APPDATA%\HexChat\hexchat-bridge).
import { Plugin } from "@opencode/plugin"
import fs from "node:fs/promises"
import path from "node:path"
import os from "node:os"

const APPDATA = process.env.APPDATA || path.join(os.homedir(), "AppData", "Roaming")
const DIR = path.join(APPDATA, "HexChat", "hexchat-bridge")
const CMD = path.join(DIR, "cmd.lua")
const RESP = path.join(DIR, "resp.json")
const STATUS = path.join(DIR, "status.json")
const EVENTS = path.join(DIR, "events.jsonl")

const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms))

function luaVal(v: any): string {
  if (v === null || v === undefined) return "nil"
  if (typeof v === "number" || typeof v === "boolean") return String(v)
  if (typeof v === "string") {
    let s = v
      .replace(/\\/g, "\\\\")
      .replace(/"/g, '\\"')
      .replace(/\n/g, "\\n")
      .replace(/\r/g, "\\r")
      .replace(/\t/g, "\\t")
    s = s.replace(/[\x00-\x08\x0b\x0c\x0e-\x1f\x7f]/g, (c) => "\\" + c.charCodeAt(0))
    return '"' + s + '"'
  }
  if (Array.isArray(v)) return "{" + v.map(luaVal).join(",") + "}"
  if (typeof v === "object") {
    const parts = Object.entries(v)
      .filter(([, x]) => x !== undefined)
      .map(([k, x]) => luaKey(k) + " = " + luaVal(x))
    return "{" + parts.join(", ") + "}"
  }
  return "nil"
}
const luaKey = (k: string) => (/^[A-Za-z_][A-Za-z0-9_]*$/.test(k) ? k : "[" + luaVal(k) + "]")

async function bridgeCall(method: string, args: Record<string, any>, signal?: AbortSignal, timeoutMs = 15000) {
  await fs.mkdir(DIR, { recursive: true })
  const id = Date.now().toString(36) + Math.random().toString(36).slice(2, 8)
  const chunk = `return { id = ${luaVal(id)}, method = ${luaVal(method)}, args = ${luaVal(args)} }\n`
  const tmp = path.join(DIR, "cmd.tmp.lua")
  await fs.writeFile(tmp, chunk, "utf8")
  try {
    await fs.access(CMD)
    await fs.unlink(CMD)
  } catch {}
  await fs.rename(tmp, CMD)
  const deadline = Date.now() + timeoutMs
  while (Date.now() < deadline) {
    if (signal?.aborted) throw new Error("hexchat call aborted")
    try {
      const j = JSON.parse(await fs.readFile(RESP, "utf8"))
      if (j.id === id) {
        if (!j.ok) throw new Error("hexchat bridge error: " + j.error)
        return j.result
      }
    } catch (e: any) {
      if (typeof e?.message === "string" && e.message.startsWith("hexchat bridge error")) throw e
    }
    await sleep(120)
  }
  throw new Error(
    `hexchat bridge timeout. HexChat must be running with the hexchat-bridge addon loaded (install: copy tools/hexchat/hexchat-bridge to %APPDATA%\\HexChat\\addons, then restart HexChat).`,
  )
}

async function bridgeHealth() {
  try {
    const st = JSON.parse(await fs.readFile(STATUS, "utf8"))
    const age = Math.floor(Date.now() / 1000) - st.last_poll
    return { alive: age < 6, last_poll: st.last_poll, age_seconds: age }
  } catch (e: any) {
    return { alive: false, error: String(e?.message) }
  }
}

async function tailEvents(limit: number, channel?: string) {
  let raw = ""
  try {
    raw = await fs.readFile(EVENTS, "utf8")
  } catch {
    return []
  }
  const out: any[] = []
  for (const line of raw.split("\n")) {
    if (!line.trim()) continue
    try {
      out.push(JSON.parse(line))
    } catch {}
  }
  const filtered = channel ? out.filter((e) => e.channel === channel) : out
  return filtered.slice(-Math.min(Math.max(limit || 50, 1), 500))
}

const METHODS = [
  "health", "ping", "status", "servlist", "buffers",
  "connect", "disconnect", "open", "close",
  "join", "part", "say", "command", "nick", "topic",
  "history", "clear_history",
] as const

export default Plugin.define({
  id: "hexchat",
  async setup(ctx) {
    const registration = await ctx.tool.transform((editor) => {
      editor.namespace({
        name: "hexchat",
        description: "Fully drive the user's HexChat IRC client: connect to networks, join/part channels, read and send messages, run any HexChat command.",
      })
      editor.add({
        name: "control",
        description:
          "Control HexChat. Methods: status (connections/channels), servlist (saved networks), buffers (open tabs), users {channel, server?} (nicklist), connect {network|address,port}, disconnect {network?}, join {channel, network?, server?, key?, nickserv?, password?}, part {channel, server?, message?}, say {channel, text, server?}, command {cmd, server?, channel?} (any raw HexChat/IRC command executed in a tab's context), nick {nick}, topic {channel, text?}, history {channel?, limit?, kind?}, open {network|server, channel}, close, clear_history, health. Returns JSON from the client. Note: bridge only lives while HexChat is running AND has made at least one connection (Lua engine lazy-loads on first connect).",
        input: {
          type: "object",
          properties: {
            method: { type: "string", enum: [...METHODS] },
            args: { type: "object", description: "Method arguments (see tool description)", additionalProperties: true },
          },
          required: ["method"],
          additionalProperties: false,
        },
        options: { namespace: "hexchat" },
        execute: async (input: any, context: any) => {
          const m = input.method
          const a = input.args || {}
          if (m === "health") return { content: JSON.stringify(await bridgeHealth(), null, 2) }
          if (m === "history") {
            // prefer in-memory bridge history, fall back to the log file if bridge is down
            try {
              return { content: JSON.stringify(await bridgeCall("history", a, context?.signal), null, 2) }
            } catch {
              return { content: JSON.stringify(await tailEvents(a.limit || 200, a.channel), null, 2) }
            }
          }
          const result = await bridgeCall(m, a, context?.signal)
          return { content: typeof result === "string" ? result : JSON.stringify(result, null, 2) }
        },
      })
      editor.add({
        name: "events",
        description:
          "Tail the captured HexChat event log (every message/join/part/status line the client saw, appended live by the bridge). Works even when the bridge is offline. Filter by channel optionally.",
        input: {
          type: "object",
          properties: {
            limit: { type: "number", description: "Max events to return (1-500, default 50)" },
            channel: { type: "string", description: "Optional channel to filter by" },
          },
          additionalProperties: false,
        },
        options: { namespace: "hexchat" },
        execute: async (input: any) => {
          const evs = await tailEvents(input.limit || 50, input.channel)
          if (evs.length === 0) return { content: "no captured events yet (events.jsonl empty or missing)" }
          return { content: JSON.stringify(evs, null, 2) }
        },
      })
    })
    return () => registration.dispose()
  },
})
