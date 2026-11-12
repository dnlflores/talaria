# Roadmap

The goal is parity with the Hermes desktop app, built in the order below. Each
area names the gateway surface it needs, so the work starts from the contract
(`apps/shared/src/gateway-contract.openrpc.json` in the Hermes repository)
instead of from guesses. Anything marked "to map" has not been read closely
yet.

## Done: connection, inbox, chat

- Sign-in through the gate, Keychain session, reconnect.
- Inbox grouped by bot (lead chat with its latest reply, up to three recent
  chats under it, "N more sessions" to the bot's full list), versions folded,
  search, pin, unread, archive, and "Working 3m" on chats whose reply is
  running.
- Chat: streaming, Markdown, work log, tool detail, inline questions,
  approvals, sudo and secret prompts, model (provider, then model) and effort,
  photo and file attachments, rename, read-along for chats held elsewhere,
  continue as a new version.
- A working row at the foot of a running turn and "Working" in the title bar.
  `session.resume`'s `running` and `turn_started_at` restore it after a
  reconnect; tool events alone start it; a quiet turn is re-checked against
  `session.active_list`. Chats the desktop app runs in its own backend are
  read from the session heartbeat (`last_activity_*`) and watched read-only.
- Files a chat made: from `write_file` and `patch` calls, produced-file keys
  in tool results, `MEDIA:` lines and paths in answers. Previews through
  `GET /api/fs/read-text`, downloads through `GET /api/fs/download`
  (`path`, `profile`, `session_id`).
- iPad: a three-column split (areas, list, detail).

## Done, read side: Bots, Kanban, Cron

- Bots: list, page with model, soul (`GET /api/profiles/{name}/soul`) and
  recent chats, Bot Chat (`session.list {title: "Bot Chat"}`, else
  `session.create`), new chat.
- Kanban: boards, the board one column at a time, card detail with brief,
  latest summary, runs (open the run's chat), comments and linked cards.
  Polled every 10 seconds while on screen.
- Cron: jobs with schedule, next and last run, delivery, prompt or script,
  recent runs (open agent runs as chats); pause, resume, run now (asks
  first). Polled every 20 seconds while on screen.

## Next: Bots, Kanban, Cron writes

- Bots: `profiles.configure` (model, description, title), `PUT
  /api/profiles/{name}/soul`, `profiles.set_asset`, `profiles.create`. A
  costly model answers `confirm_required`; ask before confirming.
- Kanban: `POST /tasks`, `PATCH /tasks/{id}` (move, assign), comments,
  reclaim, the `/events` stream instead of polling.
- Cron: `POST /api/cron/jobs` (create paused), `PUT /jobs/{id}`, `DELETE`,
  run history detail, delivery targets.
- Group chats between bots (`groups.*`) after single-bot pages.

## Then: workspace panes

- Diff review: the inline diff that arrives with `tool.complete` for the
  files the chat already lists, plus `rollback.list`, `rollback.diff`,
  `rollback.restore`.
- Working folder and project picker: `session.cwd.set`, `complete.path`,
  `projects.*`.
- Terminal: `shell.exec`, `terminal.resize`, `process.list`, `process.kill`.
  To map: the interactive terminal stream.
- Artifacts across chats (the desktop app's Artifacts page) on top of the
  per-chat file list.

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
