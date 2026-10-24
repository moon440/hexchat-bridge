-- hexchat-bridge.lua - part of hexchat-bridge, the HexChat agent control bridge
-- Copyright (C) 2026 moon440
--
-- This program is free software: you can redistribute it and/or modify
-- it under the terms of the GNU Affero General Public License as published
-- by the Free Software Foundation, either version 3 of the License, or
-- (at your option) any later version.
--
-- This program is distributed in the hope that it will be useful,
-- but WITHOUT ANY WARRANTY; without even the implied warranty of
-- MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
-- GNU Affero General Public License for more details.
--
-- You should have received a copy of the GNU Affero General Public License
-- along with this program.  If not, see <https://www.gnu.org/licenses/>.
--


-- hexchat-bridge -- HexChat file-RPC bridge for external AI agents (OpenCode)
-- Install: %APPDATA%\HexChat\addons\hexchat-bridge.lua
-- Protocol: client writes cmd.json (JSON: {id, token, ts, method, args}),
--           bridge executes, writes resp.json, heartbeats status.json,
--           logs all traffic to events.jsonl + in-memory ring.
-- Boot diagnostics: <configdir>\hexchat-bridge-boot.log

-- Boot breadcrumb first, before anything can fail
local bootpath = nil
pcall(function()
  local appdata = os.getenv("APPDATA")
  if appdata then bootpath = appdata .. "\\HexChat\\hexchat-bridge-boot.log" end
end)

local function boot(msg)
  if not bootpath then return end
  local ok, f = pcall(io.open, bootpath, "a")
  if ok and f then
    local t = 0
    pcall(function() t = os.time() end)
    f:write(tostring(t) .. " " .. tostring(msg) .. "\n")
    f:close()
  end
end
boot("chunk start")

hexchat.register("hexchat-bridge", "1.1.1", "HexChat agent control bridge (token RPC + policy safety layer + event log)")

local configdir = nil
pcall(function() configdir = hexchat.get_info("configdir") end)
if not configdir or configdir == "" then
  configdir = (os.getenv("APPDATA") or ".") .. "\\HexChat"
end
if string.sub(configdir, -1) == "\\" then configdir = string.sub(configdir, 1, -2) end
local bridge_dir = configdir .. "\\hexchat-bridge\\"
boot("configdir=" .. tostring(configdir))

local ok, err = pcall(function()

local VERSION = "1.1.1"

----------------------------------------------------------------------
-- JSON encoder (UTF-8 safe: invalid bytes are replaced with U+FFFD so
-- the output is ALWAYS valid JSON, even from hostile/broken servers)
----------------------------------------------------------------------
local REPLACER = "\239\191\189" -- U+FFFD in UTF-8

local function utf8_clean(s)
  local out = {}
  local i, n = 1, #s
  while i <= n do
    local b = s:byte(i)
    local len
    if b < 0x80 then len = 1
    elseif b >= 0xC2 and b <= 0xDF then len = 2
    elseif b >= 0xE0 and b <= 0xEF then len = 3
    elseif b >= 0xF0 and b <= 0xF4 then len = 4
    else len = 0 end
    local okseq = len > 0
    if okseq and len >= 2 then
      for k = 1, len - 1 do
        local cb = s:byte(i + k)
        if not cb or cb < 0x80 or cb > 0xBF then okseq = false break end
      end
    end
    if okseq and len == 3 then -- overlong / surrogate guards
      local b2 = s:byte(i + 1)
      if b == 0xE0 and b2 < 0xA0 then okseq = false end
      if b == 0xED and b2 > 0x9F then okseq = false end
    end
    if okseq and len == 4 then
      local b2 = s:byte(i + 1)
      if b == 0xF0 and b2 < 0x90 then okseq = false end
      if b == 0xF4 and b2 > 0x8F then okseq = false end
    end
    if okseq then
      out[#out + 1] = s:sub(i, i + len - 1)
      i = i + len
    else
      out[#out + 1] = REPLACER
      i = i + 1
    end
  end
  return table.concat(out)
end

local function enc_str(s)
  s = utf8_clean(tostring(s))
  s = s:gsub("\\", "\\\\"):gsub('"', '\\"'):gsub("\n", "\\n"):gsub("\r", "\\r"):gsub("\t", "\\t")
  s = s:gsub("%c", function(c) return string.format("\\u%04x", c:byte()) end)
  return '"' .. s .. '"'
end

local function is_array(t)
  local n = 0
  for k, v in pairs(t) do
    if type(k) ~= "number" or k ~= math.floor(k) or k < 1 then return false end
    n = n + 1
  end
  if n == 0 then return false end
  for i = 1, n do if t[i] == nil then return false end end
  return true
end

local enc
function enc(v)
  if v == nil then return "null" end
  local tv = type(v)
  if tv == "string" then return enc_str(v) end
  if tv == "number" then
    if v == math.floor(v) and math.abs(v) < 1e15 then return string.format("%d", v)
    else return string.format("%.10g", v) end
  end
  if tv == "boolean" then return tostring(v) end
  if tv == "table" then
    if is_array(v) then
      local parts = {}
      for i = 1, #v do parts[i] = enc(v[i]) end
      return "[" .. table.concat(parts, ",") .. "]"
    else
      local parts = {}
      for k, vv in pairs(v) do parts[#parts + 1] = enc_str(k) .. ":" .. enc(vv) end
      return "{" .. table.concat(parts, ",") .. "}"
    end
  end
  return "null"
end

----------------------------------------------------------------------
-- events ring + jsonl log
----------------------------------------------------------------------
local events = {}
local ev_n = 0
local EV_MAX = 2000

local ev_written = 0

local function rotate_log()
  local ok3, wf = pcall(io.open, bridge_dir .. "events.jsonl", "w")
  if ok3 and wf then
    for i = 1, ev_n do wf:write(enc(events[i]) .. "\n") end
    wf:close()
  end
  ev_written = ev_n
end

local function record(e)
  ev_n = ev_n + 1
  events[ev_n] = e
  if ev_n > EV_MAX then table.remove(events, 1); ev_n = EV_MAX end
  local ok2, f = pcall(io.open, bridge_dir .. "events.jsonl", "a")
  if ok2 and f then f:write(enc(e) .. "\n"); f:close() end
  ev_written = ev_written + 1
  if ev_written >= EV_MAX * 2 then rotate_log() end -- bound the file to ~ring size
end

local has_bit = nil
pcall(function() has_bit = require("bit") end)

local function bit_band(a, b)
  if has_bit then return has_bit.band(a, b) end
  -- pure-Lua fallback (correct on plain 5.1: no 2-arg math.log there)
  local r, m = 0, 1
  a = math.floor(a); b = math.floor(b)
  while a > 0 and b > 0 do
    local ra, rb = a % 2, b % 2
    if ra == 1 and rb == 1 then r = r + m end
    a = (a - ra) / 2; b = (b - rb) / 2; m = m * 2
  end
  return r
end

----------------------------------------------------------------------
-- raw server line capture (ALL inbound traffic)
----------------------------------------------------------------------
local logged_shape = false

local function parse_raw(raw)
  local from = string.match(raw, "^:([^ !]+)") or ""
  local rest = string.match(raw, "^:%S+ (.*)$") or raw
  local ev = string.upper(string.match(rest, "^(%a+)") or string.match(rest, "^(%d%d%d)") or "LINE")
  local target = string.match(rest, "^%a+ (%S+)") or string.match(rest, "^%d%d%d %S+ (%S+)") or ""
  local text = string.match(rest, ":([^:]*)$") or ""
  if text == "" then text = string.match(rest, "^[^:]+$") or "" end
  -- JOIN: trailing ":" form means the target IS the channel
  if ev == "JOIN" then
    target = string.gsub(target, "^:", "")
    text = ""
  end
  -- numerics: first argument is usually our own nick; find the real #channel arg
  if string.match(ev, "^%d%d%d$") then
    for w in string.gmatch(rest, "%S+") do
      local c1 = string.sub(w, 1, 1)
      if c1 == "#" or c1 == "&" then target = w break end
    end
    if target == "=" then target = "" end
  end
  return from, ev, target, text
end

hexchat.hook_server(nil, function(word, word_eol)
  local raw = ""
  pcall(function()
    raw = word_eol[0] or word[0] or word_eol[1] or word[1] or ""
  end)
  if not logged_shape then
    logged_shape = true
    boot("server hook shape ok, sample=" .. string.sub(raw, 1, 60))
  end
  if raw == "" then return end
  local from, ev, target, text = parse_raw(raw)
  local c = {}
  pcall(function() c = hexchat.get_context() or c end)
  local kind = "server"
  if ev == "PRIVMSG" then
    if string.sub(target, 1, 1) == "#" or string.sub(target, 1, 1) == "&" then kind = "recv"
    else kind = "query" end
  elseif ev == "NOTICE" then kind = "notice"
  elseif ev == "JOIN" then kind = "join" -- parse_raw already fixed target/text
  elseif ev == "PART" then kind = "part"
  elseif ev == "QUIT" then kind = "quit"
  elseif ev == "NICK" then kind = "nick"
  end
  record({
    t = os.time(), kind = kind, ev = ev,
    network = c.network or "", channel = target,
    from = from, text = text,
  })
end)

-- outgoing message capture at the COMMAND layer (reliable: fires for human-typed
-- input AND programmatic hexchat.command/ctx:command; print-event hooks proved
-- unreliable for sent text on this build)
local function record_sent(target, text)
  local c = {}
  pcall(function() c = hexchat.get_context() or c end)
  if not target or target == "" then target = c.channel or c.tab or "" end
  record({
    t = os.time(), kind = "sent",
    network = c.network or "", channel = target,
    nick = c.nick or "", text = text or "",
  })
end

pcall(function()
  -- plain text typed into a tab (non-command input, includes /say? no: /say is a command)
  hexchat.hook_command(nil, function(word, word_eol)
    record_sent(nil, word_eol[1] or "")
  end)
end)
pcall(function()
  hexchat.hook_command("SAY", function(word, word_eol)
    record_sent(nil, word_eol[2] or "")
  end)
end)
pcall(function()
  hexchat.hook_command("MSG", function(word, word_eol)
    record_sent(word[2], word_eol[3] or "")
  end)
end)

----------------------------------------------------------------------
-- SAFETY LAYER (defends against a prompt-injected agent as much as
-- against rogue local processes; policy file is human-editable and
-- cached at load - reload with the reload_policy method)
----------------------------------------------------------------------
local policy_file = configdir .. "\\hexchat-bridge-policy.lua"

local policy = {
  block_verbs = { "exec", "luaexec", "luareload", "luaconsole", "luareset",
                  "load", "unload", "stop", "dcc", "url", "gui" },
  allow_send_channels = nil,   -- nil = unrestricted; else { "#chan", "nick", ... }
  max_msgs_per_min = 25,       -- token-bucket for say/command
  max_per_sec = 2,             -- burst cap (also reads as human pacing)
}

local function load_policy()
  local okf, f = pcall(io.open, policy_file, "r")
  if not okf or not f then return end
  local data = f:read("*a"); f:close()
  local chunk = data and loadstring(data)
  if chunk then
    local okr, user = pcall(chunk)
    if okr and type(user) == "table" then
      for k, v in pairs(user) do policy[k] = v end
    end
  end
end
load_policy()

local function is_paused()
  local ok, f = pcall(io.open, bridge_dir .. "PAUSE", "r")
  if ok and f then f:close(); return true end
  return false
end

local function verb_blocked(cmdtext)
  local t = string.gsub(cmdtext, "^[%s/]+", "") -- normalize leading space/tab/slash
  local verb = string.lower(string.match(t, "^([%w_]+)") or "")
  for i = 1, #(policy.block_verbs or {}) do
    if policy.block_verbs[i] == verb then return verb end
  end
  return nil
end

local send_times = {}
local function rate_gate()
  local now = os.time()
  while #send_times > 0 and now - send_times[1] >= 60 do table.remove(send_times, 1) end
  if #send_times >= (policy.max_msgs_per_min or 25) then
    return false, "rate limit: max_msgs_per_min reached"
  end
  local recent = 0
  for i = #send_times, 1, -1 do
    if now - send_times[i] < 1 then recent = recent + 1 else break end
  end
  if recent >= (policy.max_per_sec or 2) then
    return false, "send pacing: max_per_sec reached (wait ~1s)"
  end
  send_times[#send_times + 1] = now
  return true
end

local function sendable(channel)
  if not policy.allow_send_channels then return true end
  local lc = string.lower(channel or "")
  for i = 1, #policy.allow_send_channels do
    if string.lower(policy.allow_send_channels[i]) == lc then return true end
  end
  return false
end

-- every mutating method starts with: guard()  (raises on pause)
local function guard()
  if is_paused() then error("bridge PAUSED (PAUSE file present) - human must delete it or call resume") end
end

----------------------------------------------------------------------
-- strict JSON decoder (protocol input is DATA, never code - no loadstring)
----------------------------------------------------------------------
local function utf8_cp(cp)
  if cp < 0x80 then return string.char(cp) end
  if cp < 0x800 then return string.char(0xC0 + math.floor(cp / 0x40), 0x80 + cp % 0x40) end
  if cp < 0x10000 then
    return string.char(0xE0 + math.floor(cp / 0x1000), 0x80 + math.floor(cp / 0x40) % 0x40, 0x80 + cp % 0x40)
  end
  return string.char(0xF0 + math.floor(cp / 0x40000), 0x80 + math.floor(cp / 0x1000) % 0x40,
                     0x80 + math.floor(cp / 0x40) % 0x40, 0x80 + cp % 0x40)
end

local function json_decode(s)
  local i = 1
  local function ws()
    while i <= #s do
      local c = s:sub(i, i)
      if c == " " or c == "\t" or c == "\n" or c == "\r" then i = i + 1 else break end
    end
  end
  local function str()
    i = i + 1
    local parts = {}
    while i <= #s do
      local c = s:sub(i, i)
      if c == '"' then i = i + 1 return table.concat(parts) end
      if c == "\\" then
        local n = s:sub(i + 1, i + 1)
        local map = { n = "\n", r = "\r", t = "\t", b = "\b", f = "\f", ["'"] = "/", ['/'] = "/", ['"'] = '"', ["\\"] = "\\" }
        if n == "u" then
          local cp = tonumber(s:sub(i + 2, i + 5), 16) or 0xFFFD
          i = i + 6
          if cp >= 0xD800 and cp <= 0xDBFF and s:sub(i, i + 1) == "\\u" then
            local lo = tonumber(s:sub(i + 2, i + 5), 16) or 0
            if lo >= 0xDC00 and lo <= 0xDFFF then
              cp = 0x10000 + (cp - 0xD800) * 0x400 + (lo - 0xDC00)
              i = i + 6
            end
          end
          parts[#parts + 1] = utf8_cp(cp)
        elseif map[n] then
          parts[#parts + 1] = map[n]
          i = i + 2
        else
          error("bad escape")
        end
      else
        parts[#parts + 1] = c
        i = i + 1
      end
    end
    error("unterminated string")
  end
  local val
  function val()
    ws()
    local c = s:sub(i, i)
    if c == "{" then
      i = i + 1
      local t = {}
      ws()
      if s:sub(i, i) == "}" then i = i + 1 return t end
      while true do
        local k = str()
        ws()
        if s:sub(i, i) ~= ":" then error("expected :") end
        i = i + 1
        local v = val()
        if v ~= nil then t[k] = v end
        ws()
        local d = s:sub(i, i)
        i = i + 1
        if d == "}" then return t end
        if d ~= "," then error("expected , or }") end
      end
    elseif c == "[" then
      i = i + 1
      local t = {}
      ws()
      if s:sub(i, i) == "]" then i = i + 1 return t end
      while true do
        t[#t + 1] = val()
        ws()
        local d = s:sub(i, i)
        i = i + 1
        if d == "]" then return t end
        if d ~= "," then error("expected , or ]") end
      end
    elseif c == '"' then return str()
    elseif s:sub(i, i + 3) == "true" then i = i + 4 return true
    elseif s:sub(i, i + 4) == "false" then i = i + 5 return false
    elseif s:sub(i, i + 3) == "null" then i = i + 4 return nil
    else
      local num = string.match(s, "^-?%d+%.?%d*[eE]?[-+]?%d*", i)
      if not num or num == "" then error("bad value at " .. i) end
      i = i + #num
      return tonumber(num)
    end
  end
  return val()
end

----------------------------------------------------------------------
-- helpers
----------------------------------------------------------------------
local function run_in(a, cmdtext)
  -- execute cmdtext in the context of a.server/a.channel if given, else current
  if a and (a.server or a.channel) then
    local ctx = nil
    pcall(function() ctx = hexchat.find_context(a.server, a.channel) end)
    if ctx then
      local ok2 = pcall(function() ctx:command(cmdtext) end)
      if ok2 then return true end
    end
  end
  hexchat.command(cmdtext)
  return true
end

local function escape_arg(s)
  -- guard against command injection: no newlines (command split), no NUL (truncation).
  -- NOTE: a literal \0 inside a Lua 5.1 pattern is INVALID (pattern truncates at NUL);
  -- the correct class for a zero byte is %z.
  return (string.gsub(s, "[\r\n]", " "):gsub("%z", " "))
end

----------------------------------------------------------------------
-- servlist helpers (this build has no /CONNECT or /OPEN; use /SERVER)
----------------------------------------------------------------------
local function parse_servlist()
  local out = {}
  local ok2, f = pcall(io.open, configdir .. "\\servlist.conf", "r")
  if not ok2 or not f then return out end
  local cur = nil
  for line in f:lines() do
    local n = string.match(line, "^N=(.*)")
    local s = string.match(line, "^S=(.*)")
    if n then
      cur = { network = n, servers = {} }
      out[#out + 1] = cur
    elseif s and cur then
      cur.servers[#cur.servers + 1] = s
    end
  end
  f:close()
  return out
end

local function find_server(network)
  local list = parse_servlist()
  for i = 1, #list do
    if string.lower(list[i].network) == string.lower(network) and #list[i].servers > 0 then
      return list[i].servers[1]
    end
  end
  return nil
end

----------------------------------------------------------------------
-- methods
----------------------------------------------------------------------
local M = {}

function M.ping(a)
  return { version = hexchat.get_info("version"), dir = bridge_dir }
end

function M.status(a)
  local out = { connected = false, networks = {}, channels = {},
                nick = hexchat.get_info("nick") or "",
                paused = is_paused(),
                policy = { max_msgs_per_min = policy.max_msgs_per_min,
                           max_per_sec = policy.max_per_sec,
                           allow_send_channels = policy.allow_send_channels } }
  pcall(function()
    for ch in hexchat.iterate("channels") do
      local flags = ch.flags or 0
      local is_conn = bit_band(flags, 1) == 1
      local is_conn2 = bit_band(flags, 2) == 1 -- connecting
      out.channels[#out.channels + 1] = {
        network = ch.network or "", server = ch.server or "",
        channel = ch.channel or "", type = ch.type or 0,
        users = ch.users or 0, lag = ch.lag or 0,
        connected = is_conn, connecting = is_conn2,
      }
      if is_conn then out.connected = true end
    end
  end)
  local seen = {}
  local nets = {}
  for i = 1, #out.channels do
    local n = out.channels[i].network
    if n and n ~= "" and not seen[n] then seen[n] = true; nets[#nets + 1] = n end
  end
  out.networks = nets
  return out
end

function M.servlist(a)
  return parse_servlist()
end

function M.buffers(a)
  local out = {}
  pcall(function()
    for ch in hexchat.iterate("channels") do
      -- iterate reports channel==servername for the server pseudo-tab; mark it type=1
      local name = ch.channel or ""
      if ch.type == 1 then name = "" end
      out[#out + 1] = {
        network = ch.network or "", server = ch.server or "",
        channel = name, type = ch.type or 0,
        users = ch.users or 0, flags = ch.flags or 0,
      }
    end
  end)
  return out
end

function M.users(a)
  if not a or not a.channel then error("users needs args.channel") end
  local out = {}
  local ctx = nil
  pcall(function() ctx = hexchat.find_context(a.server, a.channel) end)
  if not ctx then return { error = "channel not found" } end
  pcall(function()
    for u in ctx:iterate("users") do
      out[#out + 1] = { nick = u.nick or "", prefix = u.prefix or "", host = u.host or "", away = u.away or "", realname = u.realname or "" }
    end
  end)
  return out
end

function M.connect(a)
  guard()
  if a and a.address and a.address ~= "" then
    hexchat.command("SERVER " .. escape_arg(a.address) .. (a.port and (" " .. tostring(a.port)) or "") .. (a.channel and (" " .. escape_arg(a.channel)) or ""))
  elseif a and a.network and a.network ~= "" then
    local addr = find_server(a.network)
    if not addr then error("network not found in servlist: " .. a.network) end
    hexchat.command("SERVER " .. escape_arg(addr) .. (a.channel and (" " .. escape_arg(a.channel)) or ""))
  else
    hexchat.command("SCONNECT")
  end
  return { sent = true }
end

function M.disconnect(a)
  guard()
  if a and a.network then
    local ctx = nil
    pcall(function() ctx = hexchat.find_context(a.network, nil) end)
    if ctx then hexchat.set_context(ctx) end
  end
  hexchat.command("DISCONNECT")
  return { sent = true }
end

function M.open(a)
  if not a or not a.channel then error("open needs args.channel") end
  if a.network and a.network ~= "" then
    local addr = find_server(a.network)
    if not addr then error("network not found in servlist: " .. a.network) end
    hexchat.command("SERVER " .. escape_arg(addr) .. " " .. escape_arg(a.channel))
  else
    hexchat.command("SERVER " .. escape_arg(a.server or "") .. " " .. escape_arg(a.channel))
  end
  return { sent = true }
end

function M.close(a)
  if a and a.channel then
    local done = false
    pcall(function()
      for ch in hexchat.iterate("channels") do
        if ch.channel == a.channel then
          local ctx = ch.context
          if ctx then hexchat.set_context(ctx); hexchat.command("CLOSE"); done = true end
        end
      end
    end)
    return { closed = done }
  end
  hexchat.command("CLOSE")
  return { sent = true }
end

function M.join(a)
  guard()
  if not a or not a.channel then error("join needs args.channel") end
  local joined_ctx = false
  if a.network and a.network ~= "" then
    local ctx = nil
    pcall(function() ctx = hexchat.find_context(a.network, nil) end)
    if ctx then
      pcall(function() ctx:command("JOIN " .. escape_arg(a.channel) .. (a.key and (" " .. escape_arg(a.key)) or "")) end)
      joined_ctx = true
    else
      local addr = find_server(a.network)
      if not addr then error("network not found in servlist: " .. a.network) end
      hexchat.command("SERVER " .. escape_arg(addr) .. " " .. escape_arg(a.channel))
    end
  else
    local cmd = "JOIN " .. escape_arg(a.channel) .. (a.key and (" " .. escape_arg(a.key)) or "")
    run_in({ server = a.server }, cmd)
  end
  if a.nickserv and a.password and a.password ~= "" then
    run_in({ server = a.network or a.server }, "MSG NickServ +p IDENTIFY " .. escape_arg(a.password))
  end
  return { sent = true, used_existing_context = joined_ctx }
end

function M.part(a)
  guard()
  if not a or not a.channel then error("part needs args.channel") end
  run_in({ server = a.server, channel = a.channel }, "PART " .. escape_arg(a.channel) .. (a.message and (" :" .. escape_arg(a.message)) or ""))
  return { sent = true }
end

function M.say(a)
  guard()
  if not a or not a.channel or a.text == nil then error("say needs args.channel and args.text") end
  if not sendable(a.channel) then error("policy: channel not in allow_send_channels: " .. a.channel) end
  local ok2, why = rate_gate()
  if not ok2 then error("policy: " .. why) end
  run_in({ server = a.server, channel = a.channel }, "MSG " .. escape_arg(a.channel) .. " " .. escape_arg(a.text))
  return { sent = true }
end

M.msg = M.say

function M.command(a)
  guard()
  if not a or not a.cmd then error("command needs args.cmd") end
  local blocked = verb_blocked(a.cmd)
  if blocked then error("policy: verb blocked: /" .. blocked .. " (edit hexchat-bridge-policy.lua to allow)") end
  local ok2, why = rate_gate()
  if not ok2 then error("policy: " .. why) end
  run_in(a, escape_arg(a.cmd))
  return { sent = true }
end

M.raw = M.command

function M.nick(a)
  guard()
  if not a or not a.nick then error("nick needs args.nick") end
  hexchat.command("NICK " .. escape_arg(a.nick))
  return { sent = true }
end

function M.topic(a)
  if not a or not a.channel then error("topic needs args.channel") end
  if a.text then run_in({ server = a.server, channel = a.channel }, "TOPIC " .. escape_arg(a.channel) .. " :?" .. " " .. escape_arg(a.text))
  else
    local ctx = nil
    pcall(function() ctx = hexchat.find_context(a.server, a.channel) end)
    if ctx then return { topic = ctx:get_info("topic") or "" } end
    return { topic = hexchat.get_info("topic") or "" }
  end
  return { sent = true }
end

function M.history(a)
  local limit = (a and tonumber(a.limit)) or 200
  local chan = a and a.channel
  local kind = a and a.kind
  local out = {}
  for i = 1, ev_n do
    local e = events[i]
    local keep = true
    if chan and (e.channel or "") ~= chan then keep = false end
    if kind and (e.kind or "") ~= kind then keep = false end
    if keep then out[#out + 1] = e end
  end
  while #out > limit do table.remove(out, 1) end
  return out
end

function M.clear_history(a)
  events = {}; ev_n = 0; ev_written = 0
  local ok2, f = pcall(io.open, bridge_dir .. "events.jsonl", "w")
  if ok2 and f then f:close() end
  return { cleared = true }
end

----------------------------------------------------------------------
-- safety control methods (never guarded - they ARE the controls)
----------------------------------------------------------------------
function M.pause(a)
  local ok2, f = pcall(io.open, bridge_dir .. "PAUSE", "w")
  if not ok2 or not f then error("cannot create PAUSE file") end
  f:write("paused via RPC " .. tostring(os.time())); f:close()
  return { paused = true }
end

function M.resume(a)
  os.remove(bridge_dir .. "PAUSE")
  return { paused = is_paused() }
end

function M.reload_policy(a)
  policy = {
    block_verbs = { "exec", "luaexec", "luareload", "luaconsole", "luareset",
                    "load", "unload", "stop", "dcc", "url", "gui" },
    allow_send_channels = nil,
    max_msgs_per_min = 25,
    max_per_sec = 2,
  }
  load_policy()
  return { reloaded = true, max_msgs_per_min = policy.max_msgs_per_min,
           allow_send_channels = policy.allow_send_channels }
end

----------------------------------------------------------------------
-- poll loop (token-authenticated)
----------------------------------------------------------------------
local last_id = nil

local function read_token()
  local okf, f = pcall(io.open, bridge_dir .. "token.txt", "r")
  if not okf or not f then return nil end
  local t = f:read("*a")
  f:close()
  t = (t or ""):gsub("%s+$", "")
  if t == "" then return nil end
  return t
end

local function poll()
  local ok1, sf = pcall(io.open, bridge_dir .. "status.json", "w")
  if ok1 and sf then sf:write('{"last_poll":' .. tostring(os.time()) .. ',"bridge":"hexchat-bridge"}'); sf:close() end

  local ok2, f = pcall(io.open, bridge_dir .. "cmd.json", "r")
  if ok2 and f then
    local data = f:read(65536) -- hard size cap: no memory spikes from junk files
    f:close()
    os.remove(bridge_dir .. "cmd.json")
    if data and data ~= "" then
      local okd, cmd = pcall(json_decode, data)
      if not okd or type(cmd) ~= "table" then
        -- malformed input: answer with an error if we can salvage the id
        local mid = string.match(data, '"id"%s*:%s*"([^"]*)"')
        if mid then
          local okw, rf = pcall(io.open, bridge_dir .. "resp.json", "w")
          if okw and rf then rf:write('{"id":' .. enc_str(mid) .. ',"ok":false,"error":"malformed command json"}'); rf:close() end
        end
      elseif cmd.id and cmd.id ~= last_id then
        last_id = cmd.id
        local fn = M[cmd.method]
        local rerr, res = nil, nil
        local expected = read_token()
        local ts = tonumber(cmd.ts) or 0
        if not expected then
          rerr = "token.txt missing in bridge dir - refusing unauthenticated command"
        elseif cmd.token ~= expected then
          rerr = "invalid token"
        elseif math.abs(os.time() - ts) > 30 then
          rerr = "stale or future-dated command (ts skew > 30s) - rejected"
        elseif not fn then
          rerr = "unknown method: " .. tostring(cmd.method)
        else
          local ok4, r2 = pcall(fn, cmd.args or {})
          if ok4 then res = r2 else rerr = tostring(r2) end
        end
        local out
        if rerr then
          out = '{"id":' .. enc_str(cmd.id) .. ',"ok":false,"error":' .. enc_str(rerr) .. '}'
        else
          out = '{"id":' .. enc_str(cmd.id) .. ',"ok":true,"result":' .. enc(res) .. '}'
        end
        local ok5, rf = pcall(io.open, bridge_dir .. "resp.json", "w")
        if ok5 and rf then rf:write(out); rf:close() end
      end
    end
  end
  return true
end

hexchat.hook_timer(200, poll)
record({ t = os.time(), kind = "system", text = "hexchat-bridge " .. VERSION .. " loaded dir=" .. bridge_dir })
boot("hexchat-bridge " .. VERSION .. " main() complete")

end)

if not ok then
  boot("LOAD ERROR: " .. tostring(err))
end

