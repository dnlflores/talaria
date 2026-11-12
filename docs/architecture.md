# Architecture

Talaria is a thin client. Every conversation, tool call and credential lives on
the Mac; the phone renders state and sends intent.

## Pieces

```
Talaria (SwiftUI app)
  AppModel        connection phase, inbox, navigation, prompts from the agent
  ChatModel       one open conversation and its composer
  Views           Connect, Home, Chat, Settings
        │
HermesKit (Swift package, no UI)
  HermesHTTP      REST through the gate, sign-in
  RPCConnection   JSON-RPC over the gateway WebSocket, reconnect
  HermesClient    the calls the app makes, by name
  ChatState       transcript + live status, advanced by gateway events
  TranscriptLayout  rows the transcript view draws
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
- Files changed, diffs and the working-folder picker.
- Push notifications. iOS suspends the socket in the background, so a reply
  that finishes while the app is closed is seen on the next open.
- A direct connection to `hermes serve` (OAuth or basic auth) without the
  gate.
