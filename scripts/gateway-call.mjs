// Calls a running Hermes backend the way the app does, for checking a method or a REST field
// before writing the Swift for it.
//
//   node scripts/gateway-call.mjs <method> '<json params>' [--session <profile>]
//   node scripts/gateway-call.mjs GET /api/profiles
//   node scripts/gateway-call.mjs PATCH /api/ui-preferences '{"values": {...}}'
//
// Environment: TALARIA_BASE (default http://127.0.0.1:9120) and TALARIA_SIGNIN, the tokens file
// scripts/sign-in.py writes. A stale access token is renewed once and written back to the file.
// `--session <profile>` opens a throwaway session first and passes its id as `session_id`.
import { readFileSync, writeFileSync } from "node:fs";

const base = (process.env.TALARIA_BASE ?? "http://127.0.0.1:9120").replace(/\/$/, "");
const signInFile = process.env.TALARIA_SIGNIN ?? "";
const args = process.argv.slice(2);
const sessionAt = args.indexOf("--session");
const sessionProfile = sessionAt >= 0 ? args.splice(sessionAt, 2)[1] : null;
const [first, second, third] = args;

let tokens = signInFile ? JSON.parse(readFileSync(signInFile, "utf8")) : null;

async function renew() {
  if (!tokens?.refresh_token) throw new Error("no refresh token: sign in again with scripts/sign-in.py");
  const response = await fetch(base + "/auth/native/refresh", {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ refresh_token: tokens.refresh_token, provider: tokens.provider }),
  });
  if (!response.ok) throw new Error(`renewal refused: ${response.status} ${await response.text()}`);
  const fresh = await response.json();
  tokens = { ...tokens, ...fresh, refresh_token: fresh.refresh_token || tokens.refresh_token };
  writeFileSync(signInFile, JSON.stringify(tokens), { mode: 0o600 });
}

async function http(method, path, body) {
  for (let attempt = 0; attempt < 2; attempt++) {
    const headers = { Accept: "application/json" };
    if (tokens?.access_token) headers.Authorization = `Bearer ${tokens.access_token}`;
    if (body !== undefined) headers["Content-Type"] = "application/json";
    const response = await fetch(base + path, { method, headers, body, redirect: "manual" });
    if (response.status === 401 && tokens && attempt === 0) {
      await renew();
      continue;
    }
    const text = await response.text();
    try {
      return { status: response.status, body: JSON.parse(text) };
    } catch {
      return { status: response.status, body: text };
    }
  }
}

async function rpc(method, params) {
  let ticket = null;
  if (tokens) {
    const minted = await http("POST", "/api/auth/ws-ticket");
    ticket = minted.body?.ticket ?? null;
  }
  const url = base.replace(/^http/, "ws") + "/api/ws" + (ticket ? `?ticket=${encodeURIComponent(ticket)}` : "");
  const ws = new WebSocket(url, { headers: { Origin: base } });
  let next = 0;
  const pending = new Map();
  const call = (name, callParams) =>
    new Promise((resolve, reject) => {
      const id = `c${++next}`;
      pending.set(id, { resolve, reject });
      ws.send(JSON.stringify({ jsonrpc: "2.0", id, method: name, params: callParams }));
    });
  return new Promise((resolve, reject) => {
    setTimeout(() => reject(new Error("timed out")), 60000);
    ws.onerror = (error) => reject(error);
    ws.onmessage = async (message) => {
      for (const line of String(message.data).split("\n")) {
        if (!line.trim()) continue;
        const frame = JSON.parse(line);
        if (frame.id && pending.has(frame.id)) {
          const { resolve: done, reject: fail } = pending.get(frame.id);
          pending.delete(frame.id);
          frame.error ? fail(frame.error) : done(frame.result);
        } else if (frame.method === "event" && frame.params?.type === "gateway.ready") {
          try {
            await call("client.capabilities", { server_requests: true });
            let session = null;
            if (sessionProfile) {
              session = await call("session.create", { profile: sessionProfile, source: "gui", request_id: `probe-${Date.now()}` });
              params = { ...params, session_id: session.session_id };
            }
            const result = await call(method, params);
            if (session) await call("session.close", { session_id: session.session_id }).catch(() => {});
            resolve(result);
          } catch (error) {
            reject(error);
          }
        }
      }
    };
  });
}

try {
  let out;
  if (/^(GET|POST|PATCH|PUT|DELETE)$/.test(first)) {
    out = await http(first, second, third);
  } else {
    out = await rpc(first, JSON.parse(second ?? "{}"));
  }
  console.log(JSON.stringify(out, null, 2));
  process.exit(0);
} catch (error) {
  console.error(typeof error === "object" ? JSON.stringify(error, null, 2) : String(error));
  process.exit(1);
}
