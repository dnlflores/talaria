// Writes the model catalog (`model.options`) of a running Hermes backend to a JSON file, for
// scripts/record-effort-levels.py.
// usage: node scripts/model-catalog.mjs [out.json] [profile] [base]   (base defaults to http://127.0.0.1:4300)
import { writeFileSync } from "node:fs";

const [out = "catalog.json", profile = "default", base = "http://127.0.0.1:4300"] = process.argv.slice(2);
const ws = new WebSocket(base.replace(/^http/, "ws") + "/api/ws", { headers: { Origin: base } });
let next = 0;
const pending = new Map();
const call = (method, params) =>
  new Promise((resolve, reject) => {
    const id = `c${++next}`;
    pending.set(id, { resolve, reject });
    ws.send(JSON.stringify({ jsonrpc: "2.0", id, method, params }));
  });

ws.onmessage = async (message) => {
  for (const line of String(message.data).split("\n")) {
    if (!line.trim()) continue;
    const frame = JSON.parse(line);
    if (frame.id && pending.has(frame.id)) {
      const { resolve, reject } = pending.get(frame.id);
      pending.delete(frame.id);
      frame.error ? reject(frame.error) : resolve(frame.result);
    } else if (frame.method === "event" && frame.params?.type === "gateway.ready") {
      await call("client.capabilities", { server_requests: true });
      const session = await call("session.create", { profile, cols: 100 });
      const catalog = await call("model.options", { session_id: session.session_id, profile });
      writeFileSync(out, JSON.stringify(catalog));
      await call("session.close", { session_id: session.session_id }).catch(() => {});
      console.log(`wrote ${out}: ${(catalog.providers ?? []).length} providers`);
      process.exit(0);
    }
  }
};
setTimeout(() => {
  console.error("timed out");
  process.exit(1);
}, 60000);
