# Architecture

Talaria is a thin client. Every conversation, tool call and credential lives on
the Mac; the phone renders state and sends intent.

## Pieces

```
Talaria (SwiftUI app)
  AppModel        connection phase, inbox, navigation, prompts from the agent
  ChatModel       one open conversation and its composer
  AreaState       what Bots, Kanban and Cron have open (CronModel, KanbanModel)
  Views           Shell (tabs on iPhone, sidebar split on iPad), Connect,
                  Home, Chat, Bots, Kanban, Cron, Settings
        │
HermesKit (Swift package, no UI)
  HermesHTTP      REST through the gate, sign-in
  RPCConnection   JSON-RPC over the gateway WebSocket, reconnect
  HermesClient    the calls the app makes, by name
  ChatState       transcript + live status, advanced by gateway events
  TranscriptLayout  rows the transcript view draws
  FileExtraction  the files a turn wrote, edited or delivered
  Workspace       cron, kanban and file calls and their models
        │
MarkdownBlocks    block-level Markdown parser
```

`HermesKit` and `MarkdownBlocks` build and test on macOS with `swift test`,
which keeps the protocol logic checkable without a simulator.

## The gate

The Mac runs `hermes serve` bound to loopback. In front of it sits hermesdash,
a small Python server with two listeners:

| Listener | Auth | Used by |
|---|---|---|
| loopback | none | the simulator on the same Mac |
| public (behind Tailscale Funnel) | password, then a signed cookie | the phone |

What Talaria relies on:

- `POST /login` with a form-encoded `password`. Success is a redirect that
  sets `hd_session`; a wrong password is a 401 page; five failures from one
  client within fifteen minutes lock it out until they age off.
- `GET /hd/health`: 200 with backend state when the caller is allowed in, 401
  with `X-Hermesdash-Login: 1` when it must sign in, 503 when no password is
  set on the Mac.
- `GET /hd/owners`: conversations another Hermes process on the Mac holds.
- Everything under `/api/` is proxied to `hermes serve`, including the
  WebSocket at `/api/ws`. Writes and WebSocket upgrades must carry an `Origin`
  that matches the host.

The app keeps the cookie value in the Keychain and attaches it by hand to REST
calls and to the WebSocket handshake. Shared cookie storage is not used, and
the password is never written anywhere.

## The gateway protocol

`hermes serve` speaks JSON-RPC 2.0 over one WebSocket. The method list and the
payload shapes are in the contract that ships with Hermes
(`apps/shared/src/gateway-contract.openrpc.json`, 262 methods in 0.23.1).
Talaria's calls were checked against a running 0.23.1 backend.

Things that are easy to get wrong:

- One WebSocket message can carry several JSON lines.
- After the `gateway.ready` event the client must call
  `client.capabilities {server_requests: true}`. Without it the backend fails
  every approval and clarify request at once instead of sending it.
- Events address the **live** session id that `session.create` or
  `session.resume` returns. The sidebar lists the **stored** id. A chat has
  both.
- A socket that stays away for about 20 seconds has its live sessions reaped.
  `session.resume` with the stored id re-attaches. A chat that never had a turn
  has no stored row: resume it with `lazy: true`, and create a fresh session if
  that answers 4007.
- Session metadata writes over REST (`PATCH /api/sessions/{id}`) are fenced:
  each needs a fresh `request_id` and the `expected_revision` it was based on.

A turn looks like this on the wire:

```
→ prompt.submit {session_id, text}
← message.start
← thinking.delta / reasoning.delta       status line, reasoning
← tool.start {tool_id, name, context}    zero or more times
← tool.complete {tool_id, summary, duration_s, result}
← message.delta {text}                   the answer, token by token
← message.complete {text, usage}
← session.title {title}                  after the first turn
```

Questions from the agent arrive as JSON-RPC requests (they carry an `id` and
wait for a result): `approval`, `clarify`, `sudo`, `secret`.

## Knowing a reply is running

The chat says "Working" for as long as a turn runs, and that has to stay
true across reconnects:

- Any turn activity starts the running state: `message.start`, deltas,
  `thinking.delta` with text, `tool.start`, `tool.generating`,
  `tool.progress`. Only `message.complete`, an error or `turn.end` ends it.
- `session.resume` returns `running`, `status` (`working`, `waiting`,
  `idle`) and `turn_started_at` at the top level. `inflight` describes only
  streamed text and is null while a tool runs, so `running` decides.
- A turn that has been quiet for 20 seconds is checked against
  `session.active_list`; if the session is idle or gone, the chat re-attaches
  and takes the finished transcript.
- The inbox marks chats whose live session is `working` in the same list,
  refreshed on `sessions.changed` and every few seconds while anything works.
  The sidebar's own `is_active` still only means "touched recently".

### Turns another Hermes process runs

The desktop app starts its own backend, separate from the one this app talks
to; both share the session store. A chat the desktop app runs is in neither
`session.active_list` nor `/hd/owners` (it takes no lease in
`runtime/active_sessions.json`), and none of its events reach this app.

What does reach it is the agent's heartbeat. Whichever process runs a turn
stamps `last_activity_at` and `last_activity_description` on the session row
at least once a minute (every tool runs under an activity heartbeat) and
clears the description in the turn's `finally`. So:

- `SessionSummary.isTurnRunning(now:)`: a non-empty description stamped in
  the last 3 minutes. A process that died mid-turn never clears its label;
  the age limit keeps it from looking busy forever.
- The inbox reads it from its rows, kept fresh by a light probe every 10
  seconds while the app is in the foreground (the sidebar with 5 recent and
  3 messaging rows per bot, about 20 KB).
- A chat opened while such a turn runs, or one that starts while it sits
  open, is watched like a chat with an owner: read-only, the stored
  transcript polled, the turn laid out as live and its activity inferred
  (a tool call without a result is running). When the label clears, the
  chat goes live again. A fresh `session.active_list` is fetched before
  deciding, so a turn our own backend runs never counts as elsewhere.

## The inbox, grouped by bot

`AgentGrouping` (HermesKit, unit-tested) turns the loaded rows into one block
per bot: the lead chat is the pinned one, else the newest; under it go the
others that are working, waiting, unread or touched in the last day, live
ones first, at most three; the rest are "N more sessions". Bots with a pinned
lead come first, then by their newest activity (a running chat counts as
now), bots with no chats last.

- The sidebar endpoint caps its window across all bots, so a quiet bot can
  have no rows in it. After each load the app tops up any bot with fewer than
  four rows (`/api/profiles/sessions/sidebar?recents_profile=<bot>`) and reads
  every bot's count (`/api/sessions?limit=0&min_messages=1`) for the "more"
  number.
- The lead row shows the chat's latest reply, read from its newest stored
  rows (`/messages?order=latest&limit=16`, then 48 if those are all tool
  calls), Markdown flattened by `PreviewText`, re-read only when the chat
  moves.
- "Working 3m" counts from the open chat's `turn_started_at`, or from when
  the app saw the chat go from idle to working. A chat already working when
  the app first looks shows "Working" with no time, since its start is not
  known.
- A bot's full list pages through `/api/sessions?profile=<bot>&order=recent`.
  On iPad it replaces the inbox in the list column; swapping that column
  makes the split view hide the areas column in portrait, so the shell puts
  all three back.

## Files a chat made

`FileExtraction` reads the transcript, not the disk: `write_file` and `patch`
arguments, produced-file keys in tool results (`output_path`, `saved_to`,
`files_modified`, ...), `MEDIA:` lines and absolute paths with a file
extension in answers (not inside code blocks). `~/x` and `/Users/me/x` are
one file. A finished turn lists its files under its answer. Opening one asks
the Mac: `GET /api/fs/read-text` for text, `GET /api/fs/download` for the
bytes (Quick Look and the share sheet), both with the chat's `profile` and
stored `session_id` so relative paths resolve against its working folder.

## One owner per conversation

Hermes lets one process hold a conversation at a time. The desktop app takes a
lease on a chat when it runs a turn in it, and the backend refuses turns from
anyone else. Talaria treats that as a normal state, not an error:

1. Before opening a chat it asks `/hd/owners`.
2. An owned chat opens in watch mode: the stored transcript, refreshed every
   few seconds, with a notice explaining why.
3. Sending from an owned chat calls `session.branch_stored`, which copies the
   whole history into a new conversation this client owns. The draft and
   attachments move to it and the message is sent there. Lists show the two as
   one conversation with versions.
4. When the other process lets go, the chat goes live in place.
5. Talaria lets go too: 45 seconds after you leave a chat you spoke in, it
   closes its live session if no reply is running, so the Mac can pick the chat
   back up.

Messaging threads (Slack and others) are answered by the gateway process, so
they follow the same watch and continue-as-new-version path.

## Reconnecting without redrawing

The phone drops its socket whenever it sleeps. On return, `ChatState.reconcile`
compares what is on screen with the fresh transcript by signature (kind plus
normalized text, or tool name). When the fresh copy only extends the old one,
the new tail is appended and existing items keep their identity, so nothing on
screen moves. A real divergence (undo, compression, an edit from another
device) replaces the settled items once. A message that was typed and not yet
acknowledged is matched against the fresh copy so it is neither lost nor sent
twice.

## What is deliberately not here yet

- Slash commands typed into the composer are sent as plain text.
- Diff review and the working-folder picker.
- Push notifications. iOS suspends the socket in the background, so a reply
  that finishes while the app is closed is seen on the next open.
- A direct connection to `hermes serve` (OAuth or basic auth) without the
  gate.
