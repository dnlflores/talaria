#!/usr/bin/env python3
"""Sign in to Hermes on this Mac the way Talaria does, and save the tokens for the live tests.

Runs Hermes' native-app sign-in (RFC 8252 with PKCE): opens the browser at
<base>/auth/native/authorize, waits on 127.0.0.1 for the browser to come back with a
one-time code, trades it at /auth/native/token, and writes the tokens to <out> (mode 0600):

    scripts/sign-in.py https://<mac>.ts.net:10000 ~/.hermes/cache/scratch/talaria-sign-in.json
    TALARIA_LIVE_BASE=https://<mac>.ts.net:10000 \
      TALARIA_LIVE_SIGNIN=~/.hermes/cache/scratch/talaria-sign-in.json swift test --filter Live

The live tests write renewed tokens back to the same file. Standard library only.
"""

import base64
import hashlib
import http.server
import json
import os
import secrets
import subprocess
import sys
import threading
import urllib.parse
import urllib.request


def b64url(data: bytes) -> str:
    return base64.urlsafe_b64encode(data).rstrip(b"=").decode()


def main() -> int:
    if len(sys.argv) != 3:
        print("usage: sign-in.py <base url> <output file>")
        return 2
    base, out = sys.argv[1].rstrip("/"), os.path.expanduser(sys.argv[2])
    verifier = b64url(secrets.token_bytes(32))
    challenge = b64url(hashlib.sha256(verifier.encode()).digest())
    state = b64url(secrets.token_bytes(16))
    result: dict = {}
    done = threading.Event()

    class Callback(http.server.BaseHTTPRequestHandler):
        def do_GET(self):  # noqa: N802
            url = urllib.parse.urlsplit(self.path)
            if url.path != "/callback":
                self.send_response(404)
                self.end_headers()
                return
            result.update(urllib.parse.parse_qs(url.query))
            self.send_response(200)
            self.send_header("Content-Type", "text/plain; charset=utf-8")
            self.end_headers()
            self.wfile.write(b"Signed in. You can close this tab.\n")
            done.set()

        def log_message(self, format, *args):  # noqa: A002 (the base class's name)
            pass

    server = http.server.HTTPServer(("127.0.0.1", 0), Callback)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    redirect = f"http://127.0.0.1:{server.server_port}/callback"
    query = urllib.parse.urlencode({
        "code_challenge": challenge, "code_challenge_method": "S256",
        "redirect_uri": redirect, "state": state,
    })
    authorize = f"{base}/auth/native/authorize?{query}"
    print("Opening the sign-in page. If no browser opens, visit:\n" + authorize, flush=True)
    subprocess.Popen(["open", authorize], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                     start_new_session=True)
    if not done.wait(timeout=600):
        print("No sign-in within 10 minutes.", file=sys.stderr)
        return 1
    server.shutdown()
    if result.get("error"):
        print("Sign-in failed:", result.get("error_description", result["error"])[0], file=sys.stderr)
        return 1
    if result.get("state", [""])[0] != state or not result.get("code"):
        print("The sign-in came back for another request.", file=sys.stderr)
        return 1
    body = json.dumps({"code": result["code"][0], "code_verifier": verifier}).encode()
    request = urllib.request.Request(f"{base}/auth/native/token", data=body, method="POST",
                                     headers={"Content-Type": "application/json"})
    with urllib.request.urlopen(request, timeout=30) as response:
        tokens = json.load(response)
    saved = {key: tokens.get(key) for key in ("access_token", "refresh_token", "expires_at", "provider")}
    os.makedirs(os.path.dirname(out) or ".", exist_ok=True)
    descriptor = os.open(out, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(descriptor, "w") as handle:
        json.dump(saved, handle)
    print(f"Signed in with {saved['provider'] or 'the Mac'}; tokens saved to {out}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
