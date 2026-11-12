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

- **Sign in to your Mac** with the gate's password. The password is traded for
  a session that lives in the Keychain; it is never stored.
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
  chat. It holds across leaving the chat and the phone sleeping, and also
  covers chats the desktop app is running in its own backend.
- **Files the chat made:** files a turn writes, edits or hands over (`MEDIA:`)
  are listed under its answer and in the chat's Files list. Text and code open
  in the app; images, PDFs, audio and documents open in Quick Look; Share saves
  any of them to Files or sends them elsewhere.
- **Questions and approvals:** questions the agent asks are answered inline in
  the transcript; command approvals and sudo or secret prompts arrive as sheets.
- **Model and thinking effort** per conversation, from the Mac's own catalog.
- **Attachments:** photos (resized on the phone) and files.
- **Chats open elsewhere:** Hermes allows one live owner per conversation. A
  chat that the desktop app or a terminal has open is shown read-only and kept
  fresh; sending from the phone continues it as a new version, with the full
  history, and the original stays untouched on the Mac.
- **Reconnects:** the socket dies whenever the phone sleeps. On return the
  chat re-attaches and folds in what it missed without rebuilding the screen.
- **Themes:** six palette families, each light and dark.
- **Bots:** every bot with its model, soul and recent chats; its standing Bot
  Chat and a new chat one tap away.
- **Kanban:** the board one column at a time, cards with their brief, runs,
  comments and linked cards.
- **Cron:** every job with its schedule, next and last run and recent runs;
  pause, resume and run now.
- **iPad:** a sidebar with the areas, the list beside it and the open chat or
  page on the right, in either orientation.

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
   │  HTTPS + WebSocket, session cookie
   ▼
hermesdash gate on the Mac        password, rate limit, origin check
   │  loopback, session token
   ▼
hermes serve                      JSON-RPC gateway, one process, all profiles
```

Talaria does not talk to `hermes serve` directly. It goes through the public
entrance of a small gate (called hermesdash here) that sits in front of it and
is published with Tailscale Funnel. The gate adds two endpoints the app uses:
`/hd/health` and `/hd/owners` (which chats another Hermes process holds).
[docs/architecture.md](docs/architecture.md) describes the contract.

## Build

Requirements: Xcode 27, [XcodeGen](https://github.com/yonaskolb/XcodeGen)
(`brew install xcodegen`), and a Mac running Hermes behind the gate.

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

In the simulator the app can use the gate's loopback listener, which needs no
password:

```sh
SIMCTL_CHILD_TALARIA_SERVER=http://127.0.0.1:4300 \
  xcrun simctl launch booted <your bundle id>
```

## Test

```sh
# Protocol, transcript and Markdown logic (no network)
cd Packages/HermesKit && swift test

# The same package against a real backend (read-only unless TALARIA_LIVE_TURN=1)
TALARIA_LIVE_BASE=http://127.0.0.1:4300 TALARIA_LIVE_PROFILE=<bot> \
  swift test --filter Live

# The password gate, against a scratch copy with a throwaway password
python3 scripts/scratch-gate.py /tmp/talaria-gate
python3 /tmp/talaria-gate/hermesdash.py &
TALARIA_GATE_BASE=http://127.0.0.1:4321 \
TALARIA_GATE_PASSWORD="$(cat /tmp/talaria-gate/password.txt)" \
  swift test --filter passwordGate

# The app end to end in the simulator: new chat, streaming, the working
# state (also after leaving and reopening), a tool call, a written file
# opened on the phone, an inline question, the model sheet, rename, archive
TEST_RUNNER_TALARIA_UITEST_SERVER=http://127.0.0.1:4300 \
TEST_RUNNER_TALARIA_UITEST_BOT=<bot title> \
  xcodebuild test -project Talaria.xcodeproj -scheme Talaria \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro'
```

The live tests cost a few model calls and archive the chats they create.
`TourTests` walks every area read-only and saves screenshots
(`TEST_RUNNER_TALARIA_UITEST_TOUR=1`); `CronFlowTests` pauses and resumes a
throwaway job you name in `TEST_RUNNER_TALARIA_UITEST_CRON_JOB`;
`ElsewhereTests` checks a chat the desktop app is running right now
(`TEST_RUNNER_TALARIA_UITEST_ELSEWHERE=<its title>`) reads as working.

## Layout

```
Packages/HermesKit/        Swift package, no UI
  Sources/HermesKit/       gate + JSON-RPC client, models, transcript logic
  Sources/MarkdownBlocks/  block-level Markdown parser
Talaria/                   the app
  App/                     app and chat models
  Theme/                   palettes (generated), type scale
  Components/              Markdown view, shared controls
  Features/                Shell, Connect, Home, Chat, Bots, Kanban, Cron, Settings
scripts/                   palette generator, icon, scratch gate
docs/                      architecture, roadmap
```

## Credits

- Colors and layout follow T3 Code's mobile app (MIT, T3 Tools Inc.).
  `scripts/generate-palettes.mjs` ports its theme tokens.
- Type is DM Sans (SIL Open Font License 1.1).
- The protocol is Hermes Agent's gateway (MIT, Nous Research).

See [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md). Talaria itself is MIT
licensed.
