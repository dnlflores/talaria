# talaria-push

A Hermes plugin that sends the Talaria iPhone app its notifications and Live
Activities. It runs on the Mac, inside the Hermes gateway, and talks to Apple's
push service directly with your own APNs key: nothing goes through a third
party.

- **A chat finished**: "Ada finished", the chat's title, and the start of the
  reply. "Ada hit an error" or "Ada stopped" when it did not finish cleanly.
- **A bot needs you**: a clarify question or an approval is waiting.
- **Live Activity**: while a reply runs, the Lock Screen and the Dynamic Island
  show the bot, the chat, how long it has been working and what it is doing
  ("Editing a file: ChatView.swift"). Commands and code never show there,
  since anyone can read a Lock Screen. It turns into "Done in 4m" with the start
  of the answer when the reply ends, and leaves after ten minutes.

Only chats a person started count (desktop app, terminal, Talaria). Slack and
other messaging threads, cron runs, kanban tasks and sub-agents do not notify.
The app's Settings > Notifications can narrow it to chats sent from that phone.

## How it works

`dashboard/plugin_api.py` adds routes under `/api/plugins/talaria-push/` on the
listener the app already signs in to:

| Route | What |
|---|---|
| `POST /devices` | the phone's device token, push-to-start token, settings and bot names |
| `DELETE /devices/{id}` | signing out |
| `POST /activities` | a Live Activity's own update token |
| `POST /follow` | the phone sent a message to this chat |
| `POST /test` | send a test notification now |
| `GET /status` | key, watcher and recent sends (no tokens) |

Importing the routes starts the watcher (`talaria_push/runtime.py`), one per
Mac (a lock file keeps a second process from watching too). It dials the
gateway like any local client, polls `session.active_list` for every bot every
two seconds, follows each busy chat with `session.resume` for its tool steps,
questions and final answer, and turns the changes into pushes
(`talaria_push/tracker.py`, `notifier.py`, `payloads.py`). HTTP/2 to Apple goes
through the system `curl`; the provider token is an ES256 JWT signed with
`cryptography`, which Hermes already ships.

When a turn starts, the plugin starts the Live Activity with a push-to-start
push. iOS wakes the app to hand over that activity's update token, which the
app posts to `/activities`; steps, questions and the end then go to that
activity. If the token arrives after the reply already ended, the activity is
ended at once.

Data lives in `~/.hermes/plugin-data/talaria-push/` (0700): `state.json`
(tokens, 0600) and the APNs key.

## Setup

1. In your Apple developer account, Certificates, Identifiers & Profiles >
   Keys > +: name it, tick **Apple Push Notifications service (APNs)**, choose
   Sandbox & Production and Team Scoped, then download `AuthKey_<KEYID>.p8`.
2. `scripts/install-push-plugin.sh --key ~/Downloads/AuthKey_<KEYID>.p8`
   from the Talaria repository. It copies the plugin to
   `~/.hermes/plugins/talaria-push`, enables it, and puts the key in place.
   The team id comes from the app's signing; pass `--team <TEAMID>` to set it
   on the Mac instead.
3. Open Talaria. Settings > Notifications says "Ready" once the Mac has both
   the phone's token and the key; "Send a test notification" checks the whole
   path.

## Tests

```
~/.hermes/hermes-agent/venv/bin/python -m unittest discover -s mac/talaria-push/tests -v
```
