# Roadmap

The goal is parity with the Hermes desktop app, built in the order below. Each
area names the gateway surface it needs, so the work starts from the contract
(`apps/shared/src/gateway-contract.openrpc.json` in the Hermes repository)
instead of from guesses. Anything marked "to map" has not been read closely
yet.

## Done: connection, inbox, chat

- Sign-in through the gate, Keychain session, reconnect.
- Inbox across profiles with sections, versions, search, pin, unread, archive.
- Chat: streaming, Markdown, work log, tool detail, inline questions,
  approvals, sudo and secret prompts, model and effort, photo and file
  attachments, rename, read-along for chats held elsewhere, continue as a new
  version.

## Next: Bots, Kanban, Cron

**Bots.** A bot is a profile with a title, an avatar and a soul. The desktop
app's Bots tab also keeps one canonical "Bot Chat" per bot.

- `profiles.list`, `profiles.describe`, `profiles.get_asset`,
  `profiles.set_asset`, `profiles.configure`, `profiles.create`
- `GET/PUT /api/profiles/{name}/soul`
- Bot Chat: `session.list {profile, title: "Bot Chat", include_hidden: true}`,
  `session.create {profile, title: "Bot Chat"}`
- Group chats between bots (`groups.*`) come after single-bot pages.

**Kanban.** Served by a backend plugin under `/api/plugins/kanban/`. To map:
boards, cards, card events, and how a card's runs relate to the sessions the
inbox already groups by task id.

**Cron.**

- `cron.manage {action: list | add | remove | pause | resume}`
- Run history is already in the inbox under Runs (source `cron`).

## Then: workspace panes

- Files changed and diffs: derived from `write_file` and `patch` tool calls
  (the inline diff arrives with `tool.complete`), plus `rollback.list`,
  `rollback.diff`, `rollback.restore`.
- Working folder and project picker: `session.cwd.set`, `complete.path`,
  `projects.*`.
- Terminal: `shell.exec`, `terminal.resize`, `process.list`, `process.kill`.
  To map: the interactive terminal stream.
- Artifacts and previews: to map.

## Then: capabilities

- Skills: `skills.manage`, `skills.reload`
- MCP servers: `mcp.catalog`, `mcp.servers.*`
- Connectors: `connectors.*`
- Tools and toolsets: `tools.list`, `tools.configure`, `toolsets.list`
- Plugins: `plugins.list`, `plugins.manage`

## Then: messaging, profiles, settings

- Channels and gateway status: `/api/status`, `platforms.changed` events. To
  map: per-platform configuration.
- Configuration: `config.get`, `config.set`, `config.show`
- Memory and learning: `learning.*`, `insights.get`
- Usage and billing: `usage.bars`, `session.usage`, `billing.*`
- Slash commands in the composer: `commands.catalog`, `slash.exec`,
  `command.dispatch`, `complete.slash`
- Conversation tools: `session.undo`, `session.compress`, `session.branch`,
  `session.steer`, `prompt.btw`, `prompt.background`

## Then: what only a phone can do

- Push notifications with actions (approve, answer, reply). This needs a
  sender on the Mac that watches the event stream and holds an APNs key, plus
  device tokens in place of the browser-style cookie.
- Share extension: send a photo, file, link or text to a bot from any app.
- App Intents and widgets: ask a bot from Siri or Shortcuts, see running turns.
- A Live Activity while a long turn runs.
- Voice: dictation is the keyboard's today; `voice.*` covers the rest.
