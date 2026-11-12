#!/usr/bin/env python3
"""Stand up a scratch copy of hermesdash's password gate for Talaria's sign-in tests.

It reuses the running `hermes serve` (it does not start or stop one) and listens on
loopback ports 4320 (ungated) and 4321 (password gate) with a throwaway password
written to <scratch>/password.txt. Nothing in ~/hermesdash is modified.

    python3 scripts/scratch-gate.py <scratch-dir> [--hermesdash ~/hermesdash]
"""
import argparse
import base64
import hashlib
import json
import os
import secrets
import shutil
import sys
import time
from pathlib import Path

parser = argparse.ArgumentParser()
parser.add_argument("scratch")
parser.add_argument("--hermesdash", default=str(Path.home() / "hermesdash"))
args = parser.parse_args()

source = Path(args.hermesdash).expanduser()
scratch = Path(args.scratch).expanduser()
scratch.mkdir(parents=True, exist_ok=True)

for name in ("hermesdash.py", ".serve_token"):
    if not (source / name).exists():
        sys.exit(f"missing {source / name}")
    shutil.copy2(source / name, scratch / name)
web = scratch / "web"
if not web.exists():
    web.symlink_to(source / "web")

live = json.loads((source / "config.json").read_text())
config = {
    "host": "127.0.0.1",
    "port": 4320,
    "public": {"host": "127.0.0.1", "port": 4321, "session_days": 1},
    "serve": {**live.get("serve", {}), "start": False},
    "hermes_bin": live.get("hermes_bin", "hermes"),
}
(scratch / "config.json").write_text(json.dumps(config, indent=2))

password = secrets.token_urlsafe(18) + " +&=é"  # exercises form encoding
salt = os.urandom(16)
digest = hashlib.scrypt(password.encode(), salt=salt, n=2**14, r=8, p=1, dklen=32, maxmem=2**26)
auth = {
    "salt": base64.b64encode(salt).decode(),
    "hash": base64.b64encode(digest).decode(),
    "key": secrets.token_hex(32),
    "set_at": time.time(),
}
(scratch / ".auth.json").write_text(json.dumps(auth))
os.chmod(scratch / ".auth.json", 0o600)
(scratch / "password.txt").write_text(password)
os.chmod(scratch / "password.txt", 0o600)
print(f"scratch gate ready in {scratch}\nrun: python3 {scratch / 'hermesdash.py'}")
