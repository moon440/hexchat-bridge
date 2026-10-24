-- hexchat-bridge-policy.example.lua
-- Copy to <configdir>\hexchat-bridge-policy.lua to activate, then call
-- the reload_policy method (or restart HexChat). All keys optional.
return {
  -- verbs the RPC path may NEVER run (client-side damage control:
  -- a prompt-injected agent holding a valid token still can't shell out)
  block_verbs = {
    "exec", "luaexec", "luareload", "luaconsole", "luareset",
    "load", "unload", "stop", "dcc", "url", "gui",
  },

  -- nil = agent may speak anywhere. List = only these channels/nicks.
  -- allow_send_channels = { "#mychannel", "myfriend" },
  allow_send_channels = nil,

  -- token-bucket pacing: hard cap per rolling minute, and burst per second
  -- (the per-second cap also makes agent traffic look human-paced)
  max_msgs_per_min = 25,
  max_per_sec = 2,
}
