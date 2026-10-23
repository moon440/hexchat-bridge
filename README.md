# hexchat-bridge

Give an AI agent (or any script) **full remote control of a running HexChat IRC
client**: connect to networks, join/part channels, send and receive every
message, and run any command - plus a live, structured log of all IRC traffic.

Built for [OpenCode](https://opencode.ai) agents, but the protocol is plain
files, so anything can drive it.

```
agent / shell user
      |  token-authenticated JSON-RPC over local files (cmd.lua -> resp.json)
      v
%APPDATA%\HexChat\hexchat-bridge\      <- heartbeat, command queue, token, event log
      ^
      |  200 ms poll + hooks on ALL server/print events
HexChat  <-  addons/hexchat-bridge.lua (Lua addon, no network ports opened)
```

## Components

| Path | What it is |
|---|---|
| `addons/hexchat-bridge.lua` | HexChat-side bridge: Lua addon, file RPC + full traffic logger |
| `client/hexchat.mjs` | Node.js CLI + importable library (`call`, `health`, `tailEvents`) |
| `opencode-plugin/hexchat.ts` | OpenCode V2 plugin registering `hexchat_control` + `hexchat_events` tools |

## Requirements
- HexChat 2.14+ with the **Lua plugin** bundled (standard Windows installer option)
- Node.js (any modern version) for the CLI / OpenCode plugin

## Install

**1. Bridge addon** - copy `addons/hexchat-bridge.lua` into HexChat's config addons dir:

- Windows: `%APPDATA%\HexChat\addons\hexchat-bridge.lua`
- Linux: `~/.config/hexchat/addons/hexchat-bridge.lua`

**2. Start HexChat and connect to any network** (see gotcha below).

**3a. CLI usage** (works from any shell):
```
node client/hexchat.mjs health
node client/hexchat.mjs status
node client/hexchat.mjs join '{"channel":"#example","network":"Libera.Chat"}'
node client/hexchat.mjs say '{"channel":"#example","text":"hello from an agent"}'
node client/hexchat.mjs events 20 '#example'
```

**3b. OpenCode agent usage** - copy `opencode-plugin/hexchat.ts` into your
project's `.opencode/plugins/` (or load via `plugins` in `opencode.json`).
The agent then gets `hexchat_control` and `hexchat_events` tools natively.

## Methods

| Method | Arguments | Effect |
|---|---|---|
| `health` | - | bridge heartbeat freshness (client-side, no round trip) |
| `status` | - | connected?, networks, channels, nick, users, lag |
| `servlist` | - | saved networks + servers (parsed from `servlist.conf`; password lines are never read) |
| `buffers` | - | open tabs |
| `users` | `{channel, server?}` | nicklist of a channel |
| `connect` | `{network}` or `{address, port?, channel?}` | connect (resolves network -> first saved server) |
| `disconnect` | `{network?}` | disconnect |
| `join` | `{channel, network?, server?, key?, nickserv?, password?}` | join a channel (optionally NickServ-identify) |
| `part` | `{channel, server?, message?}` | part a channel |
| `say` | `{channel, text, server?}` | send a message to any channel/query |
| `command` | `{cmd, server?, channel?}` | run ANY raw HexChat/IRC command, in a chosen tab's context |
| `nick` | `{nick}` | change nickname |
| `topic` | `{channel, text?}` | read or set topic |
| `open` | `{network|server, channel}` | open server+channel in a new tab |
| `close` | `{channel?}` | close a tab |
| `history` | `{channel?, kind?, limit?}` | in-memory event ring (2000 events) |
| `clear_history` | - | wipe ring + log file |

Event log: every line is appended to `hexchat-bridge/events.jsonl`
(`kind`: `recv` / `query` / `notice` / `sent` / `join` / `part` / `quit` /
`nick` / `server`, with `network`, `channel`, `from`, `text`, `t`).

## Security model

The bridge is a **local file RPC** - no network ports. Every command must carry
a shared secret from `hexchat-bridge/token.txt` (the first client generates it;
the bridge refuses commands without the right token). What this does and does
not protect:

- OK: stops other software or users on the machine from blindly driving your
  IRC identity through the bridge folder
- NOT OK: malware that can already read your user profile (it can just read the
  token) - and the `command` method is arbitrary IRC command execution *by design*

Revoke access: delete `token.txt` (a fresh one is generated on the next client
call) or remove the addon.

## Known limitations / gotchas

1. **The Lua engine only initializes after the first server connection.**
   While the startup "Network List" dialog is open, no plugins/scripts have
   loaded yet. Headless launch that works on Windows:
   `hexchat.exe irc.example.net` with the working directory set to the HexChat
   install folder. Once connected, the bridge loads automatically and forever.
2. **No `/CONNECT` or `/OPEN` commands** in recent HexChat builds - the bridge
   maps `connect`/`join` to `/SERVER <addr> [#channel]` via `servlist.conf`.
3. **Single pending command** at a time (concurrent writers serialize through
   the handoff retry; there is no queue).
4. Event log is bounded by rotation to the last ~2000 events; `clear_history`
   wipes it.
5. Numeric-reply parsing (`353` etc.) is best-effort; raw data is always
   preserved in `text`.

## Development notes (how it was found out)
- `hclua` requires every script to call `hexchat.register()`.
- Save the addon file as **UTF-8 without BOM** - Lua 5.1 rejects a leading BOM.
- Do **not** copy `hclua.dll` into `addons/` - it double-loads the Lua engine
  and every command executes twice. The bundled one in the install dir is enough.
- Boot diagnostics: `<configdir>/hexchat-bridge-boot.log`.
- To remove: delete `addons/hexchat-bridge.lua`, the `hexchat-bridge/` folder,
  and `hexchat-bridge-boot.log` from your HexChat config dir.

## Changelog

**1.0.1**
- Token-authenticated RPC (was: any local process could drive the client)
- UTF-8 sanitizer in the JSON encoder - invalid bytes from hostile servers can
  no longer produce unparseable JSON (parser-crash DoS)
- Correct pure-Lua `bit_band` fallback (previous one was wrong on Lua 5.1)
- Command handoff no longer deletes another writer's pending command
  (unique temp files + rename retry)
- Event log rotation (was unbounded)
- Fixed JOIN/numeric channel-field parsing
- Client: tolerate torn reads of resp.json (retry instead of crash)

**1.0.0** - initial release.

## License
GNU Affero General Public License v3.0 or later (AGPL-3.0-or-later).
See [LICENSE](LICENSE). In short: you may use, study, share and modify this
software; if you run a modified version as a network service, you must offer
its source code to your users.
