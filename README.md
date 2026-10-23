# hexchat-bridge â€” HexChat agent control bridge

Give an AI agent (or a script) **full remote control of a running HexChat IRC
client**: connect to networks, join/part channels, send and receive every
message, and run any command â€” plus a live, structured log of all IRC traffic.

Built for [OpenCode](https://opencode.ai) agents, but the protocol is plain
files, so anything can drive it.

```
agent / shell user
      â”‚  JSON-RPC over local files (cmd.lua â†’ resp.json)
      â–¼
%APPDATA%\HexChat\hexchat-bridge\          â† heartbeat, command queue, event log
      â–²
      â”‚  200 ms poll + hooks on ALL server/print events
HexChat  â—„â”€â”€  addons/hexchat-bridge.lua (Lua addon, no network ports opened)
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

**1. Bridge addon** â€” copy `addons/hexchat-bridge.lua` into HexChat's config addons dir:

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

**3b. OpenCode agent usage** â€” copy `opencode-plugin/hexchat.ts` into your
project's `.opencode/plugins/` (or load via `plugins` in `opencode.json`).
The agent then gets `hexchat_control` and `hexchat_events` tools natively.

## Methods

| Method | Arguments | Effect |
|---|---|---|
| `health` | â€” | bridge heartbeat freshness (client-side, no round trip) |
| `status` | â€” | connected?, networks, channels, nick, users, lag |
| `servlist` | â€” | saved networks + servers (parsed from `servlist.conf`; password lines are never read) |
| `buffers` | â€” | open tabs |
| `users` | `{channel, server?}` | nicklist of a channel |
| `connect` | `{network}` or `{address, port?, channel?}` | connect (resolves network â†’ first saved server) |
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
| `clear_history` | â€” | wipe ring + log file |

Event log: every line is appended to `hexchat-bridge/events.jsonl`
(`kind`: `recv` / `query` / `notice` / `sent` / `join` / `part` / `quit` /
`nick` / `server`, with `network`, `channel`, `from`, `text`, `t`).

## Known limitations / gotchas

1. **The Lua engine only initializes after the first server connection.**
   While the startup "Network List" dialog is open, no plugins/scripts have
   loaded yet. Headless launch that works on Windows:
   `hexchat.exe irc.example.net` with the working directory set to the HexChat
   install folder. Once connected, the bridge loads automatically and forever.
2. **No `/CONNECT` or `/OPEN` commands** in recent HexChat builds â€” the bridge
   maps `connect`/`join` to `/SERVER <addr> [#channel]` via `servlist.conf`.
3. **Single pending command** at a time (fine for one operator; two agents
   racing will serialize through the response check).
4. `events.jsonl` grows unbounded (the RAM ring caps at 2000). Rotate/truncate
   it yourself or use `clear_history`.
5. Some server numerics parse with cosmetic quirks (e.g. `JOIN` events keep
   the channel in `text` rather than `channel`). Raw data is always preserved.
6. This is a **local** bridge: no sockets, no auth â€” anything that can write
   files in your profile can drive your IRC client. Don't run it on shared
   machines.

## Development notes (how it was found out)
- `hclua` requires every script to call `hexchat.register()`.
- Do **not** copy `hclua.dll` into `addons/` â€” it double-loads the Lua engine
  and every command executes twice. The bundled one in the install dir is enough.
- Boot diagnostics: `<configdir>/hexchat-bridge-boot.log`.
- To remove: delete `addons/hexchat-bridge.lua`, the `hexchat-bridge/` folder, and
  `hexchat-bridge-boot.log` from your HexChat config dir.

## License
GNU Affero General Public License v3.0 or later (AGPL-3.0-or-later).
See [LICENSE](LICENSE). In short: you may use, study, share and modify this
software; if you run a modified version as a network service, you must offer
its source code to your users.
