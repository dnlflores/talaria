# Talaria handoff

Written 2026-11-11 for the next agent picking this project up. Read this
first, then `README.md`, `docs/architecture.md` and `docs/roadmap.md`.

## What this is

Talaria is a native iPhone app that is a client for the owner's Hermes Agent
running on his Mac. It is for one person and one phone. The goal is every
feature of the Hermes desktop app in an elegant mobile app that looks like the
T3 Code mobile app.

- Repo: `github.com/dnlflores/talaria`, public, branch `main`, one commit.
- Stack: SwiftUI, Swift 6 language mode, iOS 27.0 or later, iPhone only, no
  third-party dependencies. The owner chose native SwiftUI over Expo.
- Connection: the phone talks to a small password gate (hermesdash) that sits
  in front of `hermes serve` on the Mac and is published at a public address.
  The owner chose this over a tailnet-only setup.
- Backend checked against: Hermes 0.23.1, gateway contract with 262 methods.

## Current state

Built and committed: sign-in, the inbox, and full chat. `README.md` lists the
features under "What works today".

How much of it has been proven:

| Evidence | What it covers |
|---|---|
| 65 package tests (`swift test`) | protocol parsing, transcript state, reconnect merge, session grouping, Markdown |
| Live package tests | a real turn against the backend; sign-in and the socket through a scratch copy of the gate |
| One end-to-end UI test in the simulator | inbox loads, new chat through the bot picker, a streamed answer, a terminal tool call and its work log, an inline question answered, the model sheet loading its catalog, rename, archive |
| The owner's iPhone 17 Pro | installed, signs in through the public gate with the real password; he reports it works well. Which screens he used there is not recorded |

Written but never exercised in the running app. Treat each as unproven until
you have run it:

- Approval, sudo and secret sheets.
- Photo and file attachments.
- Switching model or effort (the sheet opens; no switch was made).
- The stop button.
- Search, the bot filter, pin, mark unread, drafts.
- Theme and appearance switching.
- Watching a chat the Mac holds, and continuing it as a new version.
- Coming back after the phone slept (the merge logic is unit tested only).
- Sign out and "Use a different Mac".

Not built: slash commands, push notifications, and everything under "Next
features" below.

## Next features

### 1. Bots, Kanban and Cron (the owner's pick)

This is the one area the owner chose. All three are reachable through the
gate today. The endpoints marked "checked" answered 200 through the gate's
loopback listener on the owner's Mac; the rest are read from the desktop
app's source and have not been called.

**Navigation comes first, and it is an open decision.** The app is one
navigation stack: inbox, then a chat or Settings. There is no place for more
top-level areas yet. T3 Code uses a drawer, and the palette already carries
the drawer tokens (`drawer`, `drawerBorder`, `drawerForeground`,
`threadSelected` and others) that nothing uses so far. A drawer is the
recommended shell because the full feature list will need eight or more
areas. The owner has not been asked. Show him the options before building
it, since it changes the shell of an app he already likes.

**Bots.** A bot is a Hermes profile with a title, an avatar, a model and a
soul (its standing instructions).

- List and detail: `profiles.list` (already called by
  `HermesClient.profiles()`), `profiles.describe`, and
  `profiles.get_asset {name, asset: "avatar"}` (already called by
  `HermesClient.avatar`).
- Edit: `profiles.configure`. The contract lists `profile`, `name`,
  `ui_meta`, `ui_meta_expected_revisions`, `soul`, `description`, `model`,
  `provider`, `confirm_expensive_model`, `disabled_skills`,
  `enabled_toolsets`, `enabled_mcp_servers`. A costly model answers
  `confirm_required` with a `confirm_message`; show it, and retry with
  `confirm_expensive_model: true` only if the owner agrees.
- Soul: `GET` and `PUT /api/profiles/{name}/soul`.
- Avatar upload: `profiles.set_asset`. New bot: `profiles.create`.
- Bot Chat, the one standing chat per bot: find it with
  `session.list {profile, title: "Bot Chat", include_hidden: true}`, create it
  with `session.create {profile, title: "Bot Chat"}`.
- Group chats between bots (`groups.*`, 23 methods) come after single-bot
  pages work.
- Reference code: `renderBotsTab`, `botCard`, `renderBotDetail`,
  `botEditSheet` and `openBotChat` in `~/hermesdash/web/app.js`; the desktop
  plugin at `~/.hermes/hermes-agent/apps/desktop/src/plugins/hermes-bots/`.

**Kanban.** A backend plugin with a REST API under `/api/plugins/kanban/`.

- Checked: `GET /boards` returns `{boards, current}`; `GET /board` returns
  `{columns, tenants, assignees, latest_event_id, now}`.
- Not called yet: `/board?board=<slug>`, `/events` (poll from
  `latest_event_id`), `/tasks/{id}`, `/tasks/{id}/log`, `POST /tasks`,
  `PATCH` and `DELETE /tasks/{id}`, `/tasks/bulk`, `/tasks/{id}/comments`,
  `/tasks/{id}/reassign`, `/tasks/{id}/reclaim`, `/tasks/{id}/attachments`,
  `/dispatch`, `/orchestration`, `/profiles`, `/projects`.
- Reference code: `apps/desktop/src/plugins/kanban/api.ts` (every call) and
  `types.ts` (card and column shapes) in the Hermes checkout. The backend
  router is `plugins/kanban/dashboard/plugin_api.py`.
- A card's runs already show in the inbox under Runs (source `kanban`).
- Recommended layout, not yet shown to the owner: one column at a time,
  with a segmented control or a swipe between columns and cards as rows. A
  board shrunk to fit, or one that scrolls sideways, goes against how he
  reads.

**Cron.**

- Checked: `GET /api/cron/jobs` returns an array of jobs with `id`, `name`,
  `prompt`, `schedule`, `schedule_display`, `repeat`, `enabled`, `state`,
  `next_run_at`, `last_run_at`, `last_status`.
- Not called yet: `GET /api/cron/jobs/{id}`, `/jobs/{id}/runs`,
  `/api/cron/delivery-targets`, `POST /api/cron/jobs`, `PUT /jobs/{id}`,
  `POST /jobs/{id}/pause`, `/resume`, `/trigger`, `/cancel`,
  `DELETE /jobs/{id}`, and the blueprint endpoints.
- There is also an RPC, `cron.manage {action, name, schedule, prompt, repeat,
  continuity, deliver, profile, include_disabled}`. Prefer the REST API: it
  is what the desktop app uses.
- Reference code: `apps/desktop/src/api/cron.ts` and
  `apps/desktop/src/plugins/hermes-bots/cron.tsx`.
- Run history is already in the inbox under Runs (source `cron`).

**Writes here have real effects.** A cron job runs on its schedule and spends
model calls. A new Kanban card can dispatch a worker. Test writes with
clearly named throwaway items, create jobs paused where the API allows it,
delete what you made, and ask the owner before triggering a run.

### 2 to 5. The rest, in planned order

This order is a plan, not something the owner chose. `docs/roadmap.md` maps
each to its gateway methods.

2. Workspace panes: files changed and diffs, working folder, terminal,
   artifacts.
3. Capabilities: skills, MCP servers, connectors, toolsets, plugins.
4. Messaging channels, profiles and settings; slash commands in the composer;
   undo, compress, branch and steer.
5. Phone-only: push notifications with actions, a share extension, widgets,
   App Intents, a Live Activity for long turns.

Alongside any of these, work down the "never exercised" list above. A bug
there is more likely than in new code.

## Design language

The owner asked for the T3 Code mobile look and is happy with how the app
looks now. New screens must be indistinguishable in style from the existing
ones. Before designing a screen, open `Features/Home/HomeView.swift`,
`Features/Chat/TranscriptView.swift` and `Features/Settings/SettingsView.swift`
and reuse what is there.

### Principles

- **Quiet and dense.** Near-black or near-white canvas, one accent, small
  muted labels, a lot of information per screen without boxes around it.
- **Content sits on the canvas.** Lists are plain rows separated by
  hairlines. Cards are for grouped settings and for things that need an
  answer.
- **Glass is for what floats.** Bars, the composer, toasts and floating
  buttons use Liquid Glass. Content never does.
- **Monospace means machine.** Paths, branches, model ids, commands,
  durations and code are monospaced. Everything a person wrote or reads as
  prose is DM Sans.
- **Text wraps.** Nothing scrolls sideways to be read. Long single-line
  values truncate in the middle.
- **State is said in words.** "Needs you", "Active", "Open on Mac", "Not
  sent". Color supports the word and never replaces it.

### Color

- Every color comes from `@Environment(\.palette)`. No color literals in
  views. The one exception in the code is the avatar tile, whose gradient is
  computed from the bot's name and carries a white initial.
- `Theme/Palettes.generated.swift` is generated from T3 Code's theme tokens
  by `scripts/generate-palettes.mjs`. Do not edit it by hand. Six families
  (Default, Orchid, Grove, Ocean, Ember, Iris), each light and dark.
- Check every new screen in light and dark, and in at least one family
  other than Default.
- Roles in use:

| Role | Tokens |
|---|---|
| Canvas | `screen`; sheets use `sheetSolid` |
| Text | `foreground`, `foregroundSecondary`, `foregroundMuted` |
| Icons | `icon`, `iconMuted`, `chevron` |
| Lines | `border` (hairlines, card outlines) |
| Surfaces | `groupedCard` (settings groups, pickers), `card` (question cards), `subtle` (unselected choices), `rowHover` (pressed row) |
| Accent | `primary` (send button, selection, unread dot), `primaryText` (accent-colored text), `primaryForeground` (on accent) |
| Main action | `prominentAction` with `prominentActionForeground` |
| Secondary action | `secondary` with `secondaryBorder` and `foregroundSecondary` |
| User message | `userBubble`, `userBubbleForeground` |
| Code | `mdCodeBg`, `mdCodeText` |
| Caution | `warning`, `warningBorder`, `warningForeground` |
| Failure | `dangerForeground` |
| Success | `success`, `successSurface` (added in `Theme.swift`) |
| Diffs | `diffAdded`, `diffRemoved` (added in `Theme.swift`, unused so far) |

### Type

DM Sans through `AppFont` in `Theme/Typography.swift`. Never call
`.font(.system(...))` for text; it is used only to size SF Symbols. All
sizes scale with Dynamic Type.

| Style | Size | Used for |
|---|---|---|
| `micro` | 11 | chat subtitle under the title |
| `caption` | 12 | timestamps, "Draft", status under a control |
| `label`, `labelMedium` | 13 | row eyebrow, status words, work log label, notices |
| `footnote`, `footnoteMedium` | 14 | secondary body, choice text, small buttons |
| `body`, `bodyMedium`, `bodySemibold` | 16 | row titles, messages, main buttons |
| `headline` | 18 semibold | sheet titles, empty-state titles |
| `title` | 21 bold | the bot's name on an empty chat |
| `display` | 30 bold | the connect screen heading |
| `largeTitle` | 26 bold | unused so far |
| `AppFont.mono(12)` | 12 | row metadata, tool detail; 11 for durations, 13 for commands |

- Unread rows use `bodySemibold` for the title; read rows use `body`.
- Group headings are 11 pt semibold, uppercase, kerning 0.6, muted.
- The wordmark sets the first syllable bold in `wordmark` and the rest
  medium in `foregroundMuted`.
- Reasoning text is DM Sans Italic 13, muted.

### Spacing and shape

From `Metrics`: screen padding 18, card radius 22, bubble radius 20, control
radius 14.

- All rounded rectangles use `style: .continuous`.
- Radii in use: 22 grouped cards, 20 user bubble, 18 question cards and
  toasts, 14 notices and code blocks, 12 choice rows, 24 composer.
- Buttons and tags are capsules. The send button is a 34 pt circle inside a
  40 pt hit area.
- List rows: 18 horizontal, 12 vertical. Rows inside a grouped card: 16
  horizontal, 13 vertical, hairline between rows inset 16 from the leading
  edge (62 when the row starts with a 34 pt avatar).
- Transcript: 18 between blocks.
- Give a control a hit area larger than its drawing: the send button draws
  at 34 pt inside 40, the copy button at 13 pt inside 30.

### Patterns to reuse

- **List row** (`SessionRow`): three lines. Line 1 is a 16 pt avatar, the
  owner name in `label`, and a status word on the right. Line 2 is the title
  in `body`. Line 3 is monospaced metadata joined with " · " and a small
  source symbol on the right. Use this for bots, cards and cron jobs too.
- **Shelf** (`ShelfHeader`): a collapsed group at the foot of a list, drawn
  as "Runs (34)", a hairline, and a chevron that rotates.
- **Swipe actions** on rows for the common actions, full swipe allowed.
- **Grouped card** (`group(_:)`, `valueRow`, `actionRow` in Settings): for
  settings and detail pages. Move these three helpers into `Components/`
  when a second screen needs them; do not copy them.
- **Row press**: `RowButtonStyle` tints the row with `rowHover`.
- **Collapsed detail** (`WorkLogView`): a muted label with a chevron and a
  hairline under it; tap to expand. A live label shimmers (`ShimmerText`).
- **Detail sheet** (`ToolDetailSheet`): medium and large detents, content in
  code blocks on `mdCodeBg` with a 1 pt `border` outline and a copy button.
- **Question card** (`ClarifyCard`): `card` background, radius 18, accent
  outline at 45% while it waits for an answer and `border` after. Choices
  are radius 12 rows with a circle or square symbol. It lives in the
  content, not in a sheet.
- **Blocking prompt** (`ServerPromptSheet`): a sheet that cannot be swiped
  away, used only when the agent is stopped waiting for a decision. Full
  width 48 pt capsule buttons stacked, "Allow once" first and "Deny" last.
- **Notice** (`ChatNotice`): a calm `warning` strip, radius 14, that
  explains why a screen behaves differently. One sentence.
- **Toast** (`ToastOverlay`, `app.show(_:kind:)`): glass, top of screen, for
  results and failures of an action. Tap to dismiss.
- **Tag** (`TagLabel`): 10 pt semibold uppercase capsule for connection
  state.
- **Avatar** (`AvatarView`): the bot's picture, or a gradient tile with its
  initial, radius 28% of its size.
- **Loading**: placeholder bars in `groupedCard` in the shape of the
  content. A spinner only inside a button that is working.
- **Empty state**: one `headline` line, one muted `footnote` line, one
  small capsule action.
- **Copy** (`CopyButton`): confirms with a checkmark for a moment.
- **Formatting** (`Format`): relative times ("9m", "3h", "2d"), short model
  names, folder names, byte counts. Reuse these so the same value reads the
  same everywhere.

### Chrome

- Navigation bars are inline. The home bar shows the wordmark on the left
  with no glass behind it, and a menu on the right.
- The bottom bar on a list screen holds search and the one main action for
  that screen (a pencil for a new chat).
- A chat's bar has a two-line principal: title in 15 pt semibold over a
  muted subtitle joined with " · ".
- The composer is a glass capsule pinned to the bottom with a plus menu on
  the left and the send button on the right.
- Icons are SF Symbols, medium or semibold weight, in `icon` or
  `iconMuted`.

### Motion and touch

- `.snappy` between 0.2 and 0.3 s for expanding, collapsing and scrolling;
  `.easeInOut` 0.2 to 0.25 s for cross-fades. Nothing bounces.
- Symbols change with `.contentTransition(.symbolEffect(.replace))`.
- Haptics: a light impact on send, a selection tick on copy and on picking
  an effort, a success notification when a reply finishes, and a warning
  notification when the agent asks a question or needs a decision. Nothing
  else.

### Words

- Sentence case everywhere. Plain, short, and specific: "Can't reach your
  Mac. Retrying."
- Say what happened and what the person can do. No exclamation marks, no
  "Oops", no jargon like "session" or "RPC" in the interface: it is a
  "chat", a "bot", "your Mac".
- A label must be true. The inbox says "Active" for a recently touched chat
  because the backend flag does not mean a reply is running.
- No em dashes in interface copy, docs, commit messages or PR text.

### Accessibility

- Every icon-only button has an `accessibilityLabel`.
- Rows combine their children into one element.
- Expandable things report "expanded" or "collapsed" as their value.
- Give anything a UI test needs an `accessibilityIdentifier`
  (`composer.input`, `transcript.answer`, `transcript.work`, `session.row`,
  `model.row` exist).

## Engineering rules

- **Layers.** `Packages/HermesKit` has no UI and builds on macOS so its
  tests run in seconds. The app target holds models (`App/`) and views
  (`Features/`). Network calls go through `HermesClient`: add a named method
  there for each new call, using `http.json(...)` for REST and
  `rpc.call(...)` for the gateway. Views never build requests.
- **State.** Logic that can be wrong lives in value types with no I/O
  (`ChatState` is the model) so it can be tested against recorded input.
  View models are `@Observable` and `@MainActor`.
- **Wire data.** Decode through `JSONValue` and read only the fields you
  need. Gateway payloads gain fields between releases, so strict `Codable`
  models break.
- **Contract first.** Before writing Swift for a call, read its entry in
  `~/.hermes/hermes-agent/apps/shared/src/gateway-contract.openrpc.json` and
  call it once against the running backend to see the real shape.
- **Reference client.** `~/hermesdash/web/app.js` is a working web client
  for the same backend. Port its behavior; it has already met the edge
  cases.
- **Style.** Swift 6 language mode, 2-space indent, doc comments that say
  why, swift-testing (`@Suite`, `@Test`, `#expect`) for the package.
- **Project file.** `Talaria.xcodeproj` is generated and untracked. Run
  `xcodegen generate` after adding, moving or deleting a file.

## Build, test, install

```sh
# Logic, on macOS, seconds
cd Packages/HermesKit && swift test

# The app in the simulator
xcodegen generate
SIM=$(xcrun simctl list devices | grep -m1 "iPhone 17 Pro (" \
  | grep -oE "[0-9A-F-]{36}")
xcodebuild -project Talaria.xcodeproj -scheme Talaria \
  -destination "platform=iOS Simulator,id=$SIM" \
  -derivedDataPath build -quiet build-for-testing

# Look at it. The loopback listener needs no password.
xcrun simctl boot "$SIM"; xcrun simctl install "$SIM" \
  build/Build/Products/Debug-iphonesimulator/Talaria.app
SIMCTL_CHILD_TALARIA_SERVER=http://127.0.0.1:4300 \
  xcrun simctl launch "$SIM" <bundle id>
xcrun simctl io "$SIM" screenshot /tmp/talaria.png

# End to end. About 70 seconds and several model calls.
TEST_RUNNER_TALARIA_UITEST_SERVER=http://127.0.0.1:4300 \
TEST_RUNNER_TALARIA_UITEST_BOT=<bot title> \
  xcodebuild test-without-building -project Talaria.xcodeproj \
  -scheme Talaria -destination "platform=iOS Simulator,id=$SIM" \
  -derivedDataPath build -test-timeouts-enabled YES \
  -maximum-test-execution-time-allowance 600
```

The bundle id and signing team are in `Config/Local.xcconfig`, which is
untracked and exists on the owner's Mac.

To put a build on the phone (owner's Mac only):

```sh
xcodebuild -project Talaria.xcodeproj -scheme Talaria -configuration Debug \
  -destination 'generic/platform=iOS' -derivedDataPath build \
  -allowProvisioningUpdates build
xcrun devicectl list devices            # find the phone's identifier
xcrun devicectl device install app --device <identifier> \
  build/Build/Products/Debug-iphoneos/Talaria.app
```

An install over the same bundle id should keep the saved sign-in, since
Keychain items survive an app update. That has not been observed yet.

## What counts as done

- A green build proves nothing about the interface. Every interface change
  needs a simulator screenshot that you looked at, in light and dark.
- A behavior change needs the behavior exercised: extend
  `TalariaUITests/LiveFlowTests.swift` or add a test beside it, and run it
  against the real backend.
- Say exactly what was run and what was not. The owner does not accept
  passing checks as proof of a fix, and wants claims scoped to what was
  observed.
- Only the owner can confirm something works on the phone.

## Pitfalls already hit

- **Blank transcript.** A lazy stack with a bottom scroll anchor lost its
  layout when a row changed height. The transcript is an eager `VStack`
  showing the newest 60 rows with a "show earlier" button. Do not make it
  lazy again without testing an expanding row.
- **`is_active`** in the inbox data means touched in the last five minutes,
  not that a reply is running.
- **`client.capabilities {server_requests: true}`** must be sent after
  `gateway.ready`, or approvals and questions fail at once.
- **Two ids per chat.** Events use the live id; the inbox lists the stored
  id.
- **One owner per chat.** A chat the desktop app or a terminal holds is
  read-only here, and sending continues it with `session.branch_stored`. Do
  not try to take a chat over.
- **REST writes** through the gate need an `Origin` matching the host.
  `HermesHTTP` sets it; go through it.
- **xcconfig** treats `//` as a comment, so the default server setting holds
  `host:port` with no scheme.
- **XCUITest under Swift 6**: mark the test class `@MainActor` and use
  `setUp() async throws`.
- **A killed UI test** leaves its chat behind. Archive it afterwards
  (`session.archive`).
- **`No Accounts`** from `xcodebuild` can appear while the owner is signed in
  to Xcode. Ask him to open Xcode's Apple Accounts settings and rerun; do
  not touch the account.

## Safety

- **The repo is public.** Never commit a hostname, signing team id, device
  identifier, home path, credential, the names of the owner's bots, or a
  screenshot of his inbox. Search the staged diff for these before every
  push.
- **Never read, type or ask for the gate password.** Test sign-in against a
  scratch copy of the gate: `python3 scripts/scratch-gate.py <dir>`, then run
  the copied `hermesdash.py` from that folder. It listens on 4320 and 4321
  with a throwaway password in `<dir>/password.txt`. Stop it when done. On
  the owner's Mac both need `/opt/homebrew/bin/python3`.
- **Do not modify `~/hermesdash` or restart `hermes serve`.** If the app
  needs something the gate does not offer, raise it with the owner.
- **Live tests cost model calls** on the owner's account and create chats in
  his history. Run them when they prove something, and archive what they
  create.
- **Ask before** anything that changes his Mac's setup, his Apple account,
  or what is installed on his phone while he may be using it.

## Working with the owner

- He wants things attempted and shown, not explained. Keep reports short:
  what changed, what was verified, what is left.
- Long lines must wrap, in the app and in anything written for him.
- PR descriptions are short: what changed and why, plus the final evidence.
  No process notes.
- He reviews wording of anything posted under his name before it goes out.
