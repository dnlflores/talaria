# Architecture

Talaria is a thin client. Every conversation, tool call and credential lives on
the Mac; the phone renders state and sends intent.

## Pieces

```
Talaria (SwiftUI app)
  AppModel        connection phase, inbox, navigation (the Chats stack and the agent hub's
                  stack), prompts from the agent; starred models, each bot's default
                  catalog and skills (AppModel+Agents)
  ChatModel       one open conversation and its composer
  AreaState       what Agents, Kanban and Cron have open (CronModel, KanbanModel)
  PushCenter      notification permission, APNs and Live Activity tokens, registers
                  them with the Mac; opens the chat a notification or activity names
  Views           Shell (iPhone: a hidden-bar TabView of Chats and Agents under a
                  floating glass dock that adds New chat and Settings; Kanban and Cron in
                  the inbox's More menu and the hub. iPad: sidebar split without Cron),
                  Connect, Home, Chat, Models (model chooser parts), Bots (agent hub and
                  its pages), Kanban, Cron, Settings
TalariaActivity   widget extension: the Live Activity (Lock Screen, Dynamic Island)
        │
HermesKit (Swift package, no UI)
  HermesHTTP      REST to Hermes, sign-in tokens and their renewal
  NativeSignIn    PKCE and the loopback listener the sign-in comes back to
  RPCConnection   JSON-RPC over the gateway WebSocket, reconnect
  HermesClient    the calls the app makes, by name
  ChatState       transcript + live status, advanced by gateway events
  TranscriptLayout  rows the transcript view draws
  FileExtraction  the files a turn wrote, edited or delivered
  PromptQueue     messages waiting for the running reply
  PushRegistration  what the phone tells the Mac's push plugin; SigningFacts
  ComposerKey     what a hardware key does in the composer
  UserContent     a user message's words and its `@image:` pictures
  Workspace       cron, kanban and file calls and their models
  AgentSettings   favourite models (the desktop app's shared UI preference), a bot's
                  default model catalog and its change, skills
  ModelBrand      which company's logo a model or provider shows
  LearningGraph   what a bot learned (skills, memory notes, links) and
                  ConstellationLayout, the deterministic force layout that draws it
  MemoryNotes     a bot's memories with their full text, MemoryWeb (links by shared
                  words) and MemoryTitle (fallback titles, cleaning model titles)
        │
MarkdownBlocks    block-level Markdown parser

mac/talaria-push  Hermes plugin on the Mac: watches every chat, sends APNs pushes
```

`HermesKit` and `MarkdownBlocks` build and test on macOS with `swift test`,
which keeps the protocol logic checkable without a simulator.

## Transcript scrolling

Auto-follow and the **Jump to latest** button are separate states. Scrolling up
or expanding a work log stops auto-follow so incoming text does not pull you
away. That alone does not show the button: scroll geometry must put the bottom
at least one visible viewport below the screen. The distance includes the
bottom content inset (composer, keyboard and bars), and the threshold uses the
current visible rectangle, so it adapts to the keyboard and window size. A
short chat, the bottom itself and bottom overscroll keep the button hidden.

Following starts within 60 pt of the end and stops only when the person scrolls
up away from it, read frame by frame from the scroll offset. Content that grows
under a still view, or during a gesture, never stops it, and being near the top
of a short chat is not taken as reading back. While following, any change to
the content height or to the room it shows in (the composer, the queue panel,
the keyboard, the notice under the title) scrolls to the end, and growth during
a gesture is caught up when the scroll comes to rest. Reading back, the top
shown row stays as rows arrive below instead of sliding out of the window.

While following, every resize calls `scrollTo(edge: .bottom)`, even at the end
or in a chat shorter than the screen. Skipping those calls left a short chat
with no `scrollTo` since opening, and SwiftUI then kept it aligned to the bottom
on later size changes without any call from the app: Load more pulled the
reader down by the calls it revealed (`ToolPagingTests`).

The transcript has no implicit animations: an animated update moves every row
it touches over its duration while the scroll jumps, so rows trail behind. The
working row's dots and shimmer are drawn from a `TimelineView` clock for the
same reason; animation phases there also animated the row's moves, and the dots
hung behind it as streamed lines wrapped.

`TranscriptScrollTests` exercises the production transcript and composer using
a DEBUG-only offline chat, including short drags, expanded tool logs, scrolling
back down and jumping to the latest reply. With `--live-turns` it plays running
turns through the real event handling (streamed text, steps, a queued message)
and checks that the end stays above the composer, that a chat one to two
screens tall keeps following after a scroll, and that reading back is not
moved.

## Connecting to Hermes

Talaria talks straight to Hermes on the Mac: the gateway's own HTTP listener,
the process the desktop app runs its chats in. Nothing else sits in between.

| Address | Auth | Used by |
|---|---|---|
| `http://127.0.0.1:9120` (`webapp.port`) | Hermes' sign-in when Web Access is on | the simulator on the same Mac |
| its public HTTPS address (Tailscale Funnel to that port, `webapp.public_url`) | Hermes' sign-in | the phone and iPad |

Turning it on is Hermes' own **Web Access** ("My own URL"): the desktop app's
Settings, or `hermes_cli.webapp_access` (`plan`, `register`, `serve`) then a
gateway restart. It registers the Nous sign-in callback for the public address.

Sign-in is Hermes' native-app flow (RFC 8252 with PKCE), the one the desktop
app uses for a remote backend:

1. The app listens on `http://127.0.0.1:<any port>/callback` (`LoopbackRedirect`)
   and opens `/auth/native/authorize?code_challenge=…&code_challenge_method=S256&redirect_uri=…&state=…`
   in an `ASWebAuthenticationSession`.
2. Hermes sends the browser through the Nous account sign-in and back to the
   loopback address with a one-time code. The listener answers with a redirect
   to `talaria-auth://signed-in`, which closes the sheet.
3. `POST /auth/native/token {code, code_verifier}` returns `access_token`,
   `refresh_token`, `expires_at` and `provider`. The app keeps them in the
   Keychain (`KeychainSignInStore`); the password goes to Nous, never to the app.

Then:

- REST calls carry `Authorization: Bearer <access_token>`. A 401 renews once
  with `POST /auth/native/refresh {refresh_token, provider}` (one renewal for
  any number of waiting calls) and retries; a refused renewal means sign in again.
- Each WebSocket gets a one-use ticket from `POST /api/auth/ws-ticket`, offered
  as the second subprotocol: `hermes-gateway-v1, hermes-gateway-ticket.<ticket>`.
- `GET /api/status` (no sign-in) says whether sign-in is needed
  (`auth_required`, `auth_providers`); `GET /api/auth/me` checks the held one.
- Bearer calls need no `Origin` (Hermes checks it only for cookie writes).
  Signing out forgets the tokens: `/auth/logout` revokes cookie sessions only.

## The gateway protocol

The gateway speaks JSON-RPC 2.0 over one WebSocket with the subprotocol
`hermes-gateway-v1`, the protocol of the desktop app
(`apps/desktop/src/api/canonical-protocol.ts` in Hermes is the reference
client). Talaria's calls were checked against the gateway that ships with the
November 2026 desktop app.

Why the gateway and not `hermes serve`: serve is a second agent runtime over
the same session store. A turn sent through it ran there, so the desktop app
never saw its thinking, questions or tool results ("Result unavailable"), and
while serve held a chat the desktop could not attach to it at all
(`runtime_coordination_required`). On the gateway the phone and the desktop
are two viewers of one live chat: each gets every event of every turn,
whoever started it, and either can answer a question.

Things that are easy to get wrong:

- One WebSocket message can carry several JSON lines.
- After the `gateway.ready` event the client must call
  `client.capabilities {server_requests: true}`.
- A socket reaches only the chats it opened (`session.create`,
  `session.resume`). After a reconnect every chat answers `permission_denied`
  until it is resumed again, which the app treats like a lost session.
- Session ids are the stored ids; there is no separate live id.
- `session.create` with a `title` finds the chat with that title or creates
  it (used for Bot Chat). New chats are created untitled.
- Questions reach every viewer as `clarify.request` / `approval.request`
  events and are answered with `clarify.respond` / `approval.respond`, naming
  the `prompt_id` and the turn's `execution_generation`. `*.settled` says one
  was answered (anywhere) or given up on. `sudo` and `secret` are still
  JSON-RPC requests to this socket.
- Changes are fenced. `session.mutate` (model, reasoning, rename, archive,
  branch) carries `expected_revision` (and `expected_generation` for
  settings); `session.interrupt` and `session.redirect` carry the running
  turn's `execution_generation`. `RPCConnection` keeps the newest fences it
  saw per chat; a `stale_generation` or `revision_conflict` refusal is retried
  once with fresh ones.
- `prompt.submit` needs a `submission_id`; pictures staged with
  `image.attach_bytes` go in `attachments: [{path, mime}]`.
- A snapshot leaves out a running turn's streamed text. `session.events.since`
  from sequence 0 replays the turn, and the app rebuilds the text so far from
  it.
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

Clarify and approval questions arrive as events every viewer of the chat
sees (above); `sudo` and `secret` as JSON-RPC requests that wait for a result.

## Knowing a reply is running

The chat says "Working" for as long as a turn runs, and that has to stay
true across reconnects:

- Any turn activity starts the running state: `message.start`, deltas,
  `thinking.delta` with text, `tool.start`, `tool.generating`,
  `tool.progress`. Only `message.complete`, an error or `turn.end` ends it.
- `session.resume` returns `running` at the top level, which decides.
- A turn that has been quiet for 20 seconds is checked against
  `session.active_list`; if the session is idle or gone, the chat re-attaches
  and takes the finished transcript.
- The inbox marks chats whose live session is `working` in the same list,
  refreshed on `sessions.changed` and every few seconds while anything works.
  The sidebar's own `is_active` still only means "touched recently".

### Steps and the answer

A turn's text is either a note between steps or the answer, and the backend
says which only after the fact: Claude streams a note through
`message.delta` like an answer, then `tool.generating` starts the next call
(it can last a minute while a file's contents are written) and
`message.interim` seals the note (`already_streamed: true`); some models send
the note only as `message.interim`. So:

- Every public assistant message stays visible in chronological order, outside
  the collapsed work logs. While a turn runs, its text uses commentary styling,
  not final-answer styling; when the turn ends, the last text becomes the answer.
  Earlier progress messages never disappear into tool calls.
- GPT/Codex public progress arrives in the gateway's `display_commentary` array;
  Claude usually sends normal assistant text. Both history readers honor that
  array and `display_reasoning`, including explicitly empty projections. Raw
  provider sidecars are never used to recover text, bypass redaction, or override
  a profile's commentary policy. Projected progress cannot become a final answer.
- Typed `internal_notification`, `process_complete` and
  `async_delegation_complete` wake receipts are omitted from the conversation,
  rather than shown as truncated model-facing instructions. No prefix matching
  is used to hide a person's own words.
- Only actual `reasoning`/`reasoning_content` and tool calls enter work logs.
  A message with both reasoning and public text produces two independently
  identified rows, so neither part hides the other. Questions remain inline.
- Expanding a work log renders its first 20 tool calls. Load more adds the next
  20 until exhausted, counting calls rather than reasoning blocks. Collapsing
  resets the allowance; collapsed live logs still show the latest three steps.
  This bounds rendered tool rows, not the stored-history network payload.
  Inputs and outputs are rendered only when a call is inspected.
- `tool.generating` settles the text before it and names the call being
  drafted ("Writing a file"); `message.interim` replaces that text rather
  than repeating it.
- `session.resume` mid-turn holds the turn's notes as messages and repeats
  them all, joined, in `inflight.assistant`. Only the text after them is
  added as still being written. The history also leaves out a call that has
  not finished; the stored rows (`/messages?order=latest`) name it, so the
  reopened chat says what is running.

### Turns another Hermes process runs

Turns the desktop app runs are not elsewhere: they run in the gateway this
app talks to, show in `session.active_list`, and stream here live. A process
outside the gateway (a terminal running its own agent) still shares only the
session store, and none of its events reach this app.

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

## Sending while a reply runs

The backend's own answer to a message sent mid-turn is `display.busy_input_mode`,
`interrupt` by default: the message cuts into the reply. Talaria queues instead,
on the phone (`PromptQueue`, HermesKit, unit-tested):

- While a reply runs, or a message is on its way, the composer queues. The queue
  floats above the composer; nothing queued is in the transcript.
- When the reply ends the oldest entry goes out as the next turn, one per turn,
  with `prompt.submit {queued: true}`: should the Mac still be wrapping the last
  reply up, that makes it wait rather than cut in.
- "Send now" sends a text entry with `session.redirect`. `redirected` means the
  reply took it in (the model call in flight restarts with it, or it waits for
  the running step) and the bubble goes where it arrived; the resumed history
  later stores it as a `steer` row, which is the person's own words. Photos
  cannot ride a redirect, and an older agent may refuse one: then the entry
  goes to the front and the reply is stopped, so it goes out next.
- Stop pauses the queue. Leaving the chat or the app going to the background
  hands the queue to the Mac (`queued: true`), which runs it after the reply
  with the phone asleep; what cannot be handed over becomes the chat's draft.
- The Mac's queue merges text entries into one turn and writes each queued row
  into the history at once, right after the running turn's message, moving it
  to the end when its turn starts. So the visible queue stays on the phone, and
  entries handed over show "On your Mac" in the panel: a resume while the reply
  still runs leaves their early rows out (`withoutEarlyQueued`), the next turn
  the Mac starts shows them as its message, and a resume after the reply puts
  back in the queue (held) whatever the Mac dropped, for a stopped reply clears
  its queue.

## Pictures

Hermes stores a picture sent with a message as an `@image:<path>` line in the
message text, plus a `[screenshot]` line where the session store flattened the
inline picture. `UserContent` lifts the references out (code blocks excepted)
and drops the placeholder only when a reference was found. Pictures load
through `/api/fs/download`, decoded straight to screen size and kept in memory
(`RemoteImageStore`). Picture files a turn produced, delivered (`MEDIA:`) or
named by path show as pictures under its answer instead of file chips.

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

Hermes lets one process hold a conversation at a time. The gateway is one
process, so chats it runs are shared by the desktop app and this one. A chat
another process holds (a terminal running its own agent) refuses turns from
anyone else. Talaria treats that as a normal state, not an error:

1. Hermes has no list of chats other processes hold. A chat counts as held
   elsewhere when its row says a turn is running there (the heartbeat:
   `last_activity_description` set, `last_activity_at` under three minutes
   old) and the gateway is not running it, or when a send is refused.
2. An owned chat opens in watch mode: the stored transcript, refreshed every
   few seconds, with a notice explaining why.
3. Sending from an owned chat calls `session.branch_stored`, which copies the
   whole history into a new conversation this client owns. The draft and
   attachments move to it and the message is sent there. Lists show the two as
   one conversation with versions.
4. When the other process lets go, the chat goes live in place.

Leaving a chat detaches this socket from it (`session.detach`) unless a reply
there is still running, so a question that reply asks still reaches the phone.
Nothing is locked by following a chat.

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

## Notifications and Live Activities

iOS suspends the app's socket soon after it leaves the screen, so the phone
cannot notice a reply ending on its own. The Mac does: the `talaria-push`
Hermes plugin (`mac/talaria-push`) runs inside the gateway and sends Apple's
push service what to show, with the user's own APNs key.

```
Talaria ── POST /api/plugins/talaria-push/devices ──▶ plugin routes (gateway listener)
   ▲        device token, push-to-start token,           │
   │        settings, bot names                          ▼
   │                                              watcher (one per Mac)
   │                                                session.active_list every 2 s, all bots
   │                                                session.resume of each busy chat:
   │                                                tool.start, clarify/approval, message.complete
   │                                                  │
   └──────────────── APNs (HTTP/2, ES256 token) ◀─────┘
```

- **Which chats:** sources a person starts (desktop app, terminal, Talaria;
  `gui`, `local`, `tui`, ...). Messaging threads, cron, kanban and sub-agents
  do not notify. With "Sent from this phone", only chats the phone sent to in
  the last day (`POST /follow` on every send).
- **Alerts:** working or waiting to idle is "<bot> finished" (or "hit an
  error", "stopped", from `message.complete`'s `status`), the chat's title and
  the start of the answer, Markdown flattened. A clarify or approval is
  "<bot> needs you" with the question. One notification per chat in
  Notification Center (`apns-collapse-id` from the chat id). On screen, a
  notification for the chat already open is not shown; opening a chat clears
  its notifications.
- **Live Activities:** a chat that starts working gets one through
  push-to-start (`input-push-token: 1`). iOS wakes the app to hand over that
  activity's own update token, which `PushCenter` posts to `/activities`
  (in a background task, with a REST client built from the saved address when
  there is no screen). The Mac then sends the step ("Editing a file: x.swift";
  commands and code never go on the Lock Screen), "Needs you", and the end with
  the start of the answer, dismissed after ten minutes. A token that arrives
  after the reply ended ends the activity at once. Step updates go at most every
  12 seconds at priority 5; phase changes at once. If an end never arrives, the
  app ends an activity whose chat it sees idle when the inbox loads.
- **Wire shape:** `ChatActivityAttributes` (`Shared/`) is the contract: the
  plugin sends `attributes` and `content-state` with the same keys
  (`phase`, `startedAt` in Unix seconds, `endedAt`, `step`, `summary`, `title`).
- **Environment:** the app reads `aps-environment` and the team from its
  embedded provisioning profile (`SigningFacts`): Xcode-signed builds use the
  sandbox host. The simulator has no profile; it uses the sandbox and the team
  from the plugin's `config.json`.
- **Keyboard:** the composer is a `UITextView` (`ComposerInput`). SwiftUI's
  multi-line `TextField` swallows a hardware Return on iOS 27 (no new line, no
  `onSubmit`, no `onKeyPress`), while a text view's `pressesBegan` sees it
  before text input does. The on-screen keyboard's Return never goes through
  `pressesBegan`, so it still types a new line.

## The look and the agent hub

The app follows the Hermes mobile app. The Hermes family (`Theme/HermesPalette.swift`,
hand-written, light and dark) is the default; an install that predates it is switched
to it once (`theme.hermesLook`), and Settings still offers the six T3 families. Shared
pieces live in `Components/Glass.swift`: `glassCard()` (grouped surface, hairline
edge, soft shadow), `NavRow` (line icon, name, value, chevron), `Chip` (lavender fill
and indigo edge when picked, derived from each palette's `primary`), `GlassSearchField`.
Real Liquid Glass (`glassEffect`) is kept for floating controls: the dock and capsule
buttons.

On iPhone the system tab bar is hidden and `Dock` floats over the first screen of
Chats and Agents (`TabView` still keeps each area's place and appear/disappear). It
hides once a page is stacked on top, so chats and pages get the whole screen. New chat
starts with the hub's bot in Agents and asks which bot in Chats; Settings stacks on the
area on screen.

The Agents area (`AgentHubView.swift`) shows one bot: a switcher over every bot on
iPhone, the bot list's pick on iPad. Its rows open pages on the hub's own stack
(`HubRoute`, `AppModel.hubPath`); a chat opened from there stacks there too
(`openChat`, `show` and `startChat` check `tab == .bots`). On iPad Chats, Cron and
Kanban rows switch to those areas instead (Cron filtered to the bot through
`AreaState.cronProfile`).

- **Default model:** `GET /api/model/options?profile=` (the catalog without a session,
  same shape as `model.options`, plus the bot's `model` and `provider`) and `POST
  /api/model/set?profile= {scope: "main", provider, model}`, the desktop app's
  Settings > Models write. An expensive model answers `confirm_required` with a
  message; the app asks, then repeats with `confirm_expensive_model`. It writes the
  bot's config.yaml (new chats only) and reserializes the file (`null`s become empty,
  empty maps are dropped).
- **Favourites:** the desktop app keeps starred models in the Mac's shared UI
  preferences (`GET`/`PATCH /api/ui-preferences`, key `hermes.desktop.favorite-models`,
  a JSON array of `provider::model` in starring order; an empty list deletes the key).
  The phone reads them each time a chooser opens and merges with the Mac's list before
  writing, so stars set on either side show on both.
- **Skills:** `skills.manage {action: "list", profile}` answers category to names.
- **Logos:** `ModelBrand.logo(model:provider:)` picks the maker of the model from its name
  or `vendor/` prefix (Claude for `claude-…` and `anthropic/…`, Qwen for a local
  `Qwen3.6-…` file), else the provider's own logo, else nothing (a computer for local
  providers, the provider's initial otherwise). The images are Lobe Icons' monochrome SVGs
  in `Assets.xcassets/Logos` as template vectors, tinted by the palette; rerun
  `scripts/import-logos.mjs` to add one, and add its rule to `ModelBrand`.
- **Composer:** the model and effort sit in the composer's bottom row and open the model
  sheet (the title bar's model button is gone). Dictation (`Dictation`) feeds
  `AVAudioEngine` buffers to `SFSpeechAudioBufferRecognitionRequest`, on-device where
  supported; the tap block and the result handler are built in `nonisolated` functions,
  since closures made in a main-actor method would be main-actor isolated and trap on the
  audio thread. A session counter drops results that arrive after it stopped, so a sent
  message does not refill the composer.
- **Memory & Learning:** `GET /api/learning/graph?profile=` (the desktop star map's data)
  supplies the memory nodes and cards; the skill nodes and their edges are dropped. A node
  is joined to its card by the fingerprint its id ends with. Memories are linked by
  `MemoryWeb`: TF-IDF over their words (a word in only one memory is ignored), cosine
  similarity, each memory joined to its two closest above 0.15 and to any above 0.3.
  `GET /api/learning/node?id=&profile=` opens one in full.
- **Memory titles:** Hermes keeps memories as untitled paragraphs. `MemoryTitles` asks
  the on-device Foundation Models model (guided generation, greedy, a few examples in the
  instructions) for a two-to-four word title per memory, one at a time, and stores them in
  UserDefaults keyed by the memory's fingerprint, so a memory is named once and a rewritten
  memory is named again. When the model is unavailable or declines, `MemoryTitle.fallback`
  uses the first clause's first words.
- **Constellation layout:** `ConstellationLayout` runs off the main thread: repulsion, link
  springs, gravity shaped to the card (a tall card gets a tall web), then a pass that
  pushes apart stars whose name boxes would overlap. Names do not scale with pinch (only
  distances do), so the layout reserves their box at the smallest scale the map opens at
  (0.85), and the map is centered with the names included. Clipping does not stop taps,
  so stars past the card's edge are made inert.

## What is deliberately not here yet

- Slash commands typed into the composer are sent as plain text.
- Diff review and the working-folder picker.
- Actions on notifications (approve, answer, reply from the banner).
