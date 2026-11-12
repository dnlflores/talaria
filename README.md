# Talaria

A native iPhone and iPad app for [Hermes Agent](https://github.com/NousResearch/hermes-agent)
running on your own Mac. Talaria is named after Hermes' winged sandals: the agent
stays on the Mac, and this is how it travels.

It is a personal project, built for one phone and one Mac, and shared in case the
parts are useful to someone else. It is not affiliated with Nous Research or
T3 Tools.

- **Stack:** SwiftUI, Swift 6, no third-party dependencies.
- **Target:** iPhone and iPad, iOS 27.0 or later (developed against an iPhone 17 Pro).
- **Look:** the palettes, type scale and layout of
  [T3 Code](https://github.com/pingdotgg/t3code)'s mobile app, rebuilt natively
  with Liquid Glass.

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
- **Chat** with streaming replies, Markdown (code, tables, task lists, quotes)
  and a collapsed work log per turn ("Worked for 2m") that opens to every tool
  call with its input and output.
- **A working state you can see:** while a reply runs, the foot of the chat
  says what the agent is doing ("Running a command", "Writing the answer")
  with the elapsed time, the title bar says "Working", and the inbox marks the
  chat. It holds across leaving the chat and the phone sleeping.
- **Sending while it works:** a message written while a reply runs waits in a
  queue above the composer instead of cutting in, and goes out as the next turn
  when the reply ends. "Send now" puts a queued message into the running reply,
  and the agent answers it right away. Tap a queued message to edit it; Stop
  pauses the queue. If the phone sleeps first, the queue is handed to the Mac.
- **Pictures:** pictures sent in a chat show as pictures, from any app (the
  desktop app, a terminal, the phone), and so do pictures a reply delivers or
  names by path. Tap one to see it full screen and share it.
- **Files the chat made:** files a turn writes, edits or hands over (`MEDIA:`)
  are listed under its answer and in the chat's Files list. Text and code open
  in the app; images, PDFs, audio and documents open in Quick Look; Share saves
  any of them to Files or sends them elsewhere.
- **Questions and approvals:** questions the agent asks are answered inline in
  the transcript; command approvals and sudo or secret prompts arrive as sheets.
- **Model and thinking effort** per conversation, from the Mac's own catalog.
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
- **Themes:** six palette families, each light and dark.
- **Bots:** every bot with its model, soul and recent chats; its standing Bot
  Chat and a new chat one tap away.
- **Kanban:** the board one column at a time, cards with their brief, runs,
  comments and linked cards.
- **Cron:** every job with its schedule, next and last run and recent runs;
  pause, resume and run now. Opened from the inbox's ••• menu.
- **Model:** pick a provider, then one of its models, named the way people say
  them ("Opus 4.5", "GPT-6.1 Sol 900K") and newest first. Models a plan does not
  include are folded away; a search box finds a model across every provider.
  Thinking effort lists only the levels the model in use really has: Opus 5.5
  offers Low through Max and no Off (it always thinks), Opus 4.6 has no Extra
  high, Opus 4.5 no Max. `scripts/record-effort-levels.py` checks those rules
  against the backend's own request builders.
- **iPad:** a sidebar with Chats, Bots, Kanban and Settings, the list beside it
  and the open chat or page on the right, in either orientation. On iPhone the
  tab bar holds Chats and Bots; Kanban, Cron and Settings are in the inbox's
  ••• menu.

## What is next

The goal is everything the Hermes desktop app does. In order:

1. Bots, Kanban and Cron writes: edit a bot, add and move cards, create and
   edit jobs.
2. Workspace panes: diff review, working folder, terminal.
3. Capabilities: skills, MCP servers, connectors, toolsets.
4. Messaging channels, profiles and settings.
5. Push notifications with actions, a share extension, widgets.

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
or credential is committed to this repository.

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

The live tests cost a few model calls and archive the chats they create.
`TourTests` walks every area read-only and saves screenshots
(`TEST_RUNNER_TALARIA_UITEST_TOUR=1`); `CronFlowTests` pauses and resumes a
throwaway job you name in `TEST_RUNNER_TALARIA_UITEST_CRON_JOB`;
`ElsewhereTests` checks a chat a terminal is running right now
(`TEST_RUNNER_TALARIA_UITEST_ELSEWHERE=<its title>`) reads as working.
`swift test --filter SharedChat` (with `TALARIA_LIVE_TURN=1`) checks that a
turn from either the phone or the desktop app reaches the other, questions
included.

## Layout

```
Packages/HermesKit/        Swift package, no UI
  Sources/HermesKit/       sign-in, REST + JSON-RPC client, models, transcript logic
  Sources/MarkdownBlocks/  block-level Markdown parser
Talaria/                   the app
  App/                     app and chat models
  Theme/                   palettes (generated), type scale
  Components/              Markdown view, shared controls
  Features/                Shell, Connect, Home, Chat, Bots, Kanban, Cron, Settings
scripts/                   palette generator, icon, sign-in for tests
docs/                      architecture, roadmap
```

## Credits

- Colors and layout follow T3 Code's mobile app (MIT, T3 Tools Inc.).
  `scripts/generate-palettes.mjs` ports its theme tokens.
- Type is DM Sans (SIL Open Font License 1.1).
- The protocol is Hermes Agent's gateway (MIT, Nous Research).

See [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md). Talaria itself is MIT
licensed.
