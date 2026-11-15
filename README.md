# Talaria

A native iPhone and iPad app for [Hermes Agent](https://github.com/NousResearch/hermes-agent)
running on your own Mac. Talaria is named after Hermes' winged sandals: the agent
stays on the Mac, and this is how it travels.

It is a personal project, built for one phone and one Mac, and shared in case the
parts are useful to someone else. It is not affiliated with Nous Research or
T3 Tools.

- **Stack:** SwiftUI, Swift 6, no third-party dependencies.
- **Target:** iPhone and iPad, iOS 27.0 or later (developed against an iPhone 17 Pro).
- **Look:** the Hermes mobile app's: a white canvas, frosted cards with line
  icons, lavender chips and a floating Liquid Glass dock, rebuilt natively.
  Type is DM Sans; six more color families come from
  [T3 Code](https://github.com/pingdotgg/t3code)'s mobile app.

## What works today

- **Sign in to Hermes on your Mac** with your Nous account, through Hermes' own
  native-app sign-in. The password goes to Nous; the app keeps only the tokens
  Hermes gives it, in the Keychain.
- **Inbox grouped by bot**, as the Hermes mobile app lists agents: each bot
  with the latest reply of its lead chat (the pinned one, else the newest),
  the chats worth a look now under it (working, waiting on you, unread or
  active in the last day, up to three), and "N more sessions" opening that
  bot's full list: chats, messaging threads (Slack and others) and runs.
  Search bots and chats, pin, mark unread, archive.
- **Where each chat started:** a filter in the inbox's top bar shows only
  chats started from one place (the Hermes app, this phone, a terminal,
  Workdash, Slack, automations), and rows carry a small icon for it. Tags come
  from an optional file the Mac keeps
  (`~/.hermes/plugin-data/chat-origins/origins.json`); without it, a chat's
  stored source decides. Chats made on this phone always read as Talaria.
- **A living background:** every screen sits on a sky of scattered particles
  drifting like water, with broad soft waves rolling through and patches that
  shimmer, like stars moving through the Milky Way. Tilt the phone and held
  for a few seconds the waves lean that way; swipes nudge them too. It runs on
  the GPU and holds still with Reduce Motion on.
- **Chat** with streaming replies, Markdown (code, tables, task lists, quotes)
  and visible progress messages from the agent between steps. Only actual thinking
  and tool calls go in collapsed work logs. Opening a log shows the first 20
  calls; **Load more** reveals the next 20, with each call's input and output
  available on tap. GPT and Claude progress updates use the same readable
  presentation; internal wake receipts do not appear as chat messages.
  While a reply streams, its newest line stays in sight above the composer
  until you scroll up, and reading back is never moved by what arrives below.
  **Jump to latest** appears only when you are
  at least one visible chat screen from the bottom, not when you expand a tool
  log near the latest reply.
- **A working state you can see:** while a reply runs, the foot of the chat
  says what the agent is doing ("Running a command", "Writing the answer")
  with the elapsed time, the title bar says "Working", and the inbox marks the
  chat. It holds across leaving the chat and the phone sleeping.
- **Background work:** a separate strip above the composer names running agents
  and commands even after the main reply finishes. Expand it for recent task
  status and tap for details. Discovery stays silent until tasks are found,
  including on initial connection failures. If known work cannot be refreshed,
  it stays visible with status unavailable rather than pretending it finished.
- **Sending while it works:** a message written while a reply runs waits in a
  queue above the composer instead of cutting in, and goes out as the next turn
  when the reply ends. "Send now" puts a queued message into the running reply,
  and the agent answers it right away. Tap a queued message to edit it; Stop
  pauses the queue. Leaving and reopening a chat preserves its queue, order and
  attachments. If the phone sleeps or the chat closes first, waiting messages
  are handed to the Mac and remain visible until their own turns start; they
  can still be edited, removed or sent now from there. Messages queued from
  another device or app (the iPad, Hermes desktop, a terminal) show in the same
  queue, each named by where it came from. Queued words are saved on the phone
  and come back, held, even after the app restarts.
- **Pictures:** pictures sent in a chat show as pictures, from any app (the
  desktop app, a terminal, the phone), and so do pictures a reply delivers or
  names by path. Tap one to see it full screen and share it.
- **Files the chat made:** files a turn writes, edits or hands over (`MEDIA:`)
  are listed under its answer and in the chat's Files list. Text and code open
  in the app; images, PDFs, audio and documents open in Quick Look; Share saves
  any of them to Files or sends them elsewhere.
- **What each edit changed:** a file a reply edited or wrote shows the lines
  it added and removed (`+12 -3`) on its chip and in the Files list. Opening it
  starts on Changes: the diff with added lines in green and removed lines in
  red, one block per edit, wrapped to the screen. A tool's details color its
  diff the same way.
- **Code changes in the conversation:** every finished edit shows as its own
  message, like the desktop app: "Edited Greeting.swift +3 -2" over its
  colored diff, open by default. Tap the header to fold it to that line and
  back; a long diff shows its first 12 lines until Show all. Long-press for
  Copy diff and Details.
- **Questions and approvals:** questions the agent asks are answered inline in
  the transcript; command approvals and sudo or secret prompts arrive as sheets.
- **Model and thinking effort** per conversation, from the Mac's own catalog,
  and each bot's default model.
- **Notifications:** "Ada finished" with the start of the reply when a chat
  ends, and "Ada needs you" when a bot asks something or wants an approval,
  with the phone locked or the app closed. Tapping one opens the chat. Your Mac
  sends them straight to Apple with your own APNs key (the `talaria-push`
  Hermes plugin in `mac/`); nothing goes through a third party. Settings can
  limit them to chats sent from the phone.
- **Live Activities:** while a reply runs, the Lock Screen and the Dynamic
  Island show the bot, the chat, how long it has been working and what it is
  doing ("Editing a file: ChatView.swift"); a question shows as "Needs you" and
  the end as "Done in 4m" with the start of the answer. Commands and code never
  show there.
- **Home screen shortcuts:** press and hold the Talaria icon for New chat with
  the bot you used last, or one of the last three chats you opened on the
  phone.
- **Keyboard:** with a hardware keyboard, Return sends and Shift-Return adds a
  line. The on-screen keyboard's Return still adds a line.
- **Skills and slash commands:** type `/` in a chat (or a new chat) for a list
  of the bot's skills and commands, each with a line about it and a Skill or
  Command tag; it narrows as you type, and tapping one puts it in the
  composer. Sending `/work fix the leak` starts the turn with the skill loaded,
  as the desktop app does, and your message shows what you typed. A command
  that answers in words shows them in a card under it, only on the phone;
  `/undo` puts the message back in the composer to edit. Commands the desktop
  app handles itself (`/skin`, `/new`, ...) say to run them on the Mac. Sent
  while a reply runs, a command waits in the queue like any message.
- **Composer:** a card with the text on top and, under it, attach, the model
  in use with its logo and thinking effort ("GPT-6.1 Sol 900K • High", tap to
  change either), dictation and send. Dictation uses Apple's speech
  recognition, on the phone where it can.
- **Attachments:** photos (resized on the phone) and files.
- **One chat on the phone and the desktop app:** chats run in the Hermes
  gateway on the Mac, the process the desktop app runs them in. A chat open in
  both is the same live chat: either side sees the other's turns, thinking,
  tool results and questions as they happen, and either can answer.
- **Chats a terminal holds:** a chat another Hermes process (a terminal running
  its own agent) has open is shown read-only and kept fresh; sending from the
  phone continues it as a new version, with the full history.
- **Reconnects:** the socket dies whenever the phone sleeps. On return the
  chat re-attaches and folds in what it missed without rebuilding the screen.
- **Themes:** Hermes and six T3 color families, each light and dark.
- **Agents:** one hub per bot, as the Hermes mobile app shows an agent. Swipe
  between bots at the top; below, its Bot Chat and a new chat, then rows for
  its default model, skills, chats, cron jobs, the kanban board, its soul and
  its memory.
- **Memory & Learning:** what a bot remembers, drawn as a constellation: each
  memory is a star titled by its own first words, with lines between memories
  that talk about the same things. Drag and pinch to look around; tap a star
  to light up its links and open it. Below, every memory with its title and
  the file it lives in (MEMORY.md or USER.md).
- **Kanban:** the board one column at a time, cards with their brief, runs,
  comments and linked cards.
- **Cron:** every job with its schedule, next and last run and recent runs;
  pause, resume and run now. Opened from the inbox's ••• menu, or from a bot's
  hub with only that bot's jobs.
- **Model:** the model in use on top, then your starred models, then All
  models: a chip per provider (the one in use first) and its models, each with
  its maker's logo (OpenAI, Claude, Gemini, Qwen and so on), named the
  way people say them ("Opus 4.5", "GPT-6.1 Sol 900K") and newest first. Models
  a plan does not include are folded away; search finds a model across every
  provider. Stars are the desktop app's favourites, kept on the Mac, so a star
  set on either shows on both. The same chooser sets a bot's default model
  (the one new chats start on) from its hub.
  Thinking effort lists only the levels the model in use really has: Opus 5.5
  offers Low through Max and no Off (it always thinks), Opus 4.6 has no Extra
  high, Opus 4.5 no Max. `scripts/record-effort-levels.py` checks those rules
  against the backend's own request builders.
- **Docks:** Chats and Agents, nothing else. On iPhone a floating glass dock at
  the bottom; on iPad and an unfolded iPhone Duo a floating side dock (a pill of
  glass, like Instagram's on iPad) with a red count on Chats when chats need
  you. The inbox's top corner holds two buttons: the origin filter and Settings.
  New chat, Cron and Kanban open
  per bot from its hub. A full-size iPad puts the list beside the side dock and
  the open chat or page on the right; an unfolded iPhone Duo or a half-screen
  iPad window shows one page at a time beside it, and a folded Duo gets the
  iPhone dock.

## What is next

The goal is everything the Hermes desktop app does. In order:

1. Agents, Kanban and Cron writes: edit a bot, add and move cards, create and
   edit jobs.
2. Workspace panes: diff review, working folder, terminal.
3. Capabilities: skills, MCP servers, connectors, toolsets.
4. Messaging channels, profiles and settings.
5. Notification actions (approve, answer, reply), a share extension, widgets.

[docs/roadmap.md](docs/roadmap.md) maps each area to the gateway methods it
needs.

## How it connects

```
iPhone (Talaria)
   │  HTTPS + WebSocket, Hermes sign-in (bearer token, one-use socket tickets)
   ▼
Tailscale Funnel on the Mac       public HTTPS address, forwards to loopback
   │
   ▼
Hermes gateway                    the desktop app's runtime, all profiles
```

Talaria talks to the Hermes gateway directly, through the listener Hermes'
**Web Access** turns on ("My own URL", published with Tailscale Funnel). The
phone signs in with Hermes' native-app sign-in (the same flow the desktop app
uses for a remote backend), sends REST calls with the bearer token it gets, and
opens the gateway's WebSocket with a one-use ticket. Its chats are the desktop
app's chats, live on both. [docs/architecture.md](docs/architecture.md)
describes the contract.

## Build

Requirements: Xcode 27, [XcodeGen](https://github.com/yonaskolb/XcodeGen)
(`brew install xcodegen`), and a Mac running Hermes with Web Access on: in the
desktop app's Settings, Web Access, "My own URL", with a Tailscale Funnel
address forwarding to it (`tailscale funnel --bg --https=10000
http://127.0.0.1:9120`).

```sh
git clone https://github.com/dnlflores/talaria.git
cd talaria
cp Config/Local.xcconfig.example Config/Local.xcconfig   # team id, bundle id
xcodegen generate
open Talaria.xcodeproj
```

`Config/Local.xcconfig` is untracked. It holds your signing team, a bundle id
you control and, optionally, the address to prefill on first launch. No address
or credential is committed to this repository. The app uses the Push
Notifications capability, so it needs a paid developer team; Xcode's automatic
signing registers the app id (and `<bundle id>.activity` for the Live Activity)
with `-allowProvisioningUpdates`.

### Notifications

Your Mac sends them, through the `talaria-push` Hermes plugin
([mac/talaria-push](mac/talaria-push/README.md)):

1. In your Apple developer account, Keys > +: tick Apple Push Notifications
   service (APNs), Sandbox & Production, Team Scoped; download
   `AuthKey_<KEYID>.p8`.
2. `scripts/install-push-plugin.sh --key ~/Downloads/AuthKey_<KEYID>.p8`
   copies the plugin into `~/.hermes/plugins/`, enables it and puts the key in
   place. Add `--team <TEAMID>` for the simulator, whose builds carry no team.
3. Open the app: Settings > Notifications says "Ready", and "Send a test
   notification" checks the whole path.

In the simulator the app can use Hermes' loopback address. With Web Access on it
asks for the sign-in too; a Debug build can take saved tokens instead:

```sh
python3 scripts/sign-in.py https://<your mac>.ts.net:10000 ~/talaria-sign-in.json
SIMCTL_CHILD_TALARIA_SERVER=http://127.0.0.1:9120 \
SIMCTL_CHILD_TALARIA_SIGNIN_FILE=~/talaria-sign-in.json \
  xcrun simctl launch booted <your bundle id>
```

## Test

```sh
# Protocol, transcript and Markdown logic (no network)
cd Packages/HermesKit && swift test

# Sign in once in the browser; the tests reuse and renew the saved tokens
python3 scripts/sign-in.py https://<your mac>.ts.net:10000 ~/talaria-sign-in.json

# The same package against a real backend (read-only unless TALARIA_LIVE_TURN=1),
# sign-in and its renewal included
TALARIA_LIVE_BASE=https://<your mac>.ts.net:10000 \
TALARIA_LIVE_SIGNIN=~/talaria-sign-in.json TALARIA_LIVE_PROFILE=<bot> \
  swift test --filter Live

# The app end to end in the simulator: new chat, streaming, the working
# state (also after leaving and reopening), a tool call, a written file
# opened on the phone, an inline question, the model sheet, rename, archive
TEST_RUNNER_TALARIA_UITEST_SERVER=http://127.0.0.1:9120 \
TEST_RUNNER_TALARIA_UITEST_SIGNIN=~/talaria-sign-in.json \
TEST_RUNNER_TALARIA_UITEST_BOT=<bot title> \
  xcodebuild test -project Talaria.xcodeproj -scheme Talaria \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro'
```

Queue navigation also has a local-only regression harness (Python with `aiohttp`
and `PyYAML`, plus XcodeGen). It runs the real hosted `AppModel` / `ChatModel`
against an isolated loopback gateway fixture, without touching existing chats:

```sh
python TalariaQueueTests/run-tests.py --sim "$SIM"
# Actual navigation, queue panel and admission delivery on iPhone or iPad:
python TalariaQueueTests/run-tests.py --sim "$SIM" --ui
```

Use a dedicated simulator UUID for `SIM`, a Python environment containing the two
dependencies, and set `TMPDIR` to your active scratch directory. The harness uses
only `127.0.0.1:19129` and a nonexistent fixture sign-in file (not Keychain), refuses
an occupied fixture port, and saves build logs, fixture calls and `.xcresult`
bundles under scratch. Shut down/delete only the simulator you created afterward.

`QueueFlowTests/testQueueSurvivesNavigatingAwayAndBack` exercises the same
navigation against the real gateway with the live-test environment above.

The live tests cost a few model calls and archive the chats they create.
`TourTests` walks every area read-only and saves screenshots
(`TEST_RUNNER_TALARIA_UITEST_TOUR=1`); `CronFlowTests` pauses and resumes a
throwaway job you name in `TEST_RUNNER_TALARIA_UITEST_CRON_JOB`;
`ElsewhereTests` checks a chat a terminal is running right now
(`TEST_RUNNER_TALARIA_UITEST_ELSEWHERE=<its title>`) reads as working.
`swift test --filter SharedChat` (with `TALARIA_LIVE_TURN=1`) checks that a
turn from either the phone or the desktop app reaches the other, questions
included. `ActivityLookTests` (`TEST_RUNNER_TALARIA_UITEST_ACTIVITY_LOOK=1`)
screenshots the Live Activity in each phase with no Mac;
`QuickActionTests` presses the app icon on the home screen and taps its
shortcuts, with made-up chats and no Mac;
`SlashCommandTests` opens the `/` menu, picks from it and sends a skill and a
command against canned answers, with no Mac;
`SlashDeliveryTests` (the `TalariaTests` target, `-only-testing:TalariaTests`)
runs the app's own chat model against a stand-in gateway on loopback: leaving
or going to sleep while a command is worked out, and what comes back (words,
files, queued messages) when the chat opens again, with no Mac;
`NotificationSettingsTests` (`TEST_RUNNER_TALARIA_UITEST_PUSH=1`) allows
notifications and shows what the Mac said; the push plugin has its own tests
(`python -m unittest discover -s mac/talaria-push/tests` with Hermes' Python).

## Layout

```
Packages/HermesKit/        Swift package, no UI
  Sources/HermesKit/       sign-in, REST + JSON-RPC client, models, transcript logic
  Sources/MarkdownBlocks/  block-level Markdown parser
Talaria/                   the app
  App/                     app and chat models
  Theme/                   palettes (Hermes by hand, T3 generated), type scale
  Components/              Markdown view, frosted cards, rows, chips, shared controls
  Features/                Shell, Connect, Home, Chat, Models, Bots (agent hub), Kanban,
                           Cron, Settings
Shared/                    the Live Activity's attributes (app and widget)
TalariaActivity/           the Live Activity: Lock Screen and Dynamic Island
TalariaTests/              the app's chat model against a loopback stand-in gateway
TalariaUITests/            UI tests in the simulator
mac/talaria-push/          Hermes plugin on the Mac that sends the pushes
scripts/                   palette generator, icon, sign-in for tests, push plugin install,
                           gateway-call.mjs (call the backend as the app does),
                           import-logos.mjs (provider logos into the asset catalog)
docs/                      architecture, roadmap
```

## Credits

- The look follows the Hermes mobile app. The Classic, Orchid, Grove, Ocean,
  Ember and Iris color families come from T3 Code's mobile app (MIT, T3 Tools
  Inc.); `scripts/generate-palettes.mjs` ports its theme tokens.
- Type is DM Sans (SIL Open Font License 1.1).
- Provider and model logos come from Lobe Icons (MIT, LobeHub); the logos are
  trademarks of their companies.
- The protocol is Hermes Agent's gateway (MIT, Nous Research).

See [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md). Talaria itself is MIT
licensed.
