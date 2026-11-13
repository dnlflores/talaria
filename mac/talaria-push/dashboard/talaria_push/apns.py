"""Apple Push Notification service: token-based auth (ES256 JWT) over HTTP/2.

HTTP/2 goes through the system ``curl`` (built with nghttp2 on macOS), so the plugin needs no
package beyond ``cryptography``, which Hermes already ships.
"""
from __future__ import annotations

import base64
import json
import os
import shutil
import subprocess
import tempfile
import threading
import time
from dataclasses import dataclass
from pathlib import Path
from typing import Callable, Optional

HOSTS = {
    "development": "https://api.sandbox.push.apple.com",
    "production": "https://api.push.apple.com",
}
# Apple refuses a token older than an hour and throttles one renewed more often than every 20 min.
JWT_LIFETIME = 45 * 60


@dataclass
class Result:
    status: int
    reason: str = ""
    apns_id: str = ""

    @property
    def ok(self) -> bool:
        return self.status == 200

    @property
    def token_dead(self) -> bool:
        """The device or activity token will never work again: forget it."""
        return self.status == 410 or self.reason in ("BadDeviceToken", "Unregistered", "DeviceTokenNotForTopic")


def b64url(data: bytes) -> str:
    return base64.urlsafe_b64encode(data).rstrip(b"=").decode()


def make_jwt(key_pem: bytes, key_id: str, team_id: str, now: float) -> str:
    """The provider token APNs wants: ES256 over ``{alg, kid}.{iss, iat}``, signature as raw r||s."""
    from cryptography.hazmat.primitives import hashes, serialization
    from cryptography.hazmat.primitives.asymmetric import ec
    from cryptography.hazmat.primitives.asymmetric.utils import decode_dss_signature

    header = b64url(json.dumps({"alg": "ES256", "kid": key_id}, separators=(",", ":")).encode())
    claims = b64url(json.dumps({"iss": team_id, "iat": int(now)}, separators=(",", ":")).encode())
    signing_input = f"{header}.{claims}".encode()
    key = serialization.load_pem_private_key(key_pem, password=None)
    if not isinstance(key, ec.EllipticCurvePrivateKey):
        raise ValueError("the APNs key is not an EC private key")
    r, s = decode_dss_signature(key.sign(signing_input, ec.ECDSA(hashes.SHA256())))
    return f"{header}.{claims}.{b64url(r.to_bytes(32, 'big') + s.to_bytes(32, 'big'))}"


class Credentials:
    """The APNs auth key in the plugin's data folder.

    ``AuthKey_<KEYID>.p8`` (the file Apple's developer site downloads) names its own key id.
    ``config.json`` may set ``team_id``, ``key_id`` and ``key_file``; without a team id the one the
    app reports from its own signing is used.
    """

    def __init__(self, folder: Path):
        self.folder = folder

    def _config(self) -> dict:
        try:
            data = json.loads((self.folder / "config.json").read_text())
            return data if isinstance(data, dict) else {}
        except (OSError, ValueError):
            return {}

    def load(self) -> Optional[tuple[bytes, str, Optional[str]]]:
        """``(key_pem, key_id, team_id)`` or None when no key is in place."""
        config = self._config()
        key_file = config.get("key_file")
        path: Optional[Path] = None
        if isinstance(key_file, str) and key_file:
            path = Path(key_file).expanduser()
            if not path.is_absolute():
                path = self.folder / path
        else:
            keys = sorted(self.folder.glob("AuthKey_*.p8"))
            path = keys[-1] if keys else None
        if path is None or not path.is_file():
            return None
        key_id = config.get("key_id") or path.stem.removeprefix("AuthKey_")
        team_id = config.get("team_id") or None
        return path.read_bytes(), str(key_id), team_id


Transport = Callable[[str, dict, bytes], tuple[int, dict, bytes]]


def curl_transport(url: str, headers: dict, body: bytes, timeout: float = 15) -> tuple[int, dict, bytes]:
    """POST over HTTP/2 with the system curl. Headers go through a private file, not the command
    line, so the provider token never shows in ``ps``."""
    curl = shutil.which("curl") or "/usr/bin/curl"
    with tempfile.TemporaryDirectory(prefix="talaria-push-") as folder:
        header_file = Path(folder) / "headers"
        response_headers = Path(folder) / "response-headers"
        header_file.write_text("".join(f"{k}: {v}\n" for k, v in headers.items()))
        os.chmod(header_file, 0o600)
        proc = subprocess.run(
            [curl, "--http2", "-sS", "--max-time", str(int(timeout)), "-X", "POST", "-H", f"@{header_file}",
             "--data-binary", "@-", "-D", str(response_headers), "-o", "-", "-w", "\n%{http_code}", url],
            input=body, capture_output=True, timeout=timeout + 5)
        if proc.returncode != 0:
            raise OSError(f"curl failed ({proc.returncode}): {proc.stderr.decode(errors='replace').strip()[:200]}")
        out = proc.stdout
        text, _, code = out.rpartition(b"\n")
        received: dict = {}
        try:
            for line in response_headers.read_text(errors="replace").splitlines():
                name, sep, value = line.partition(":")
                if sep:
                    received[name.strip().lower()] = value.strip()
        except OSError:
            pass
        return int(code.strip() or 0), received, text


class APNs:
    """Sends pushes, holding one provider token per (key, team) and renewing it before it ages out."""

    def __init__(self, credentials: Credentials, transport: Transport = curl_transport,
                 clock: Callable[[], float] = time.time):
        self.credentials = credentials
        self.transport = transport
        self.clock = clock
        self._lock = threading.Lock()
        self._jwt: dict[tuple[str, str], tuple[str, float]] = {}

    def team_id(self, fallback: Optional[str]) -> Optional[str]:
        loaded = self.credentials.load()
        if loaded is None:
            return None
        return loaded[2] or fallback

    def configured(self, fallback_team: Optional[str] = None) -> bool:
        return self.team_id(fallback_team) is not None

    def key_id(self) -> Optional[str]:
        loaded = self.credentials.load()
        return loaded[1] if loaded else None

    def _token(self, fallback_team: Optional[str], renew: bool = False) -> str:
        loaded = self.credentials.load()
        if loaded is None:
            raise LookupError("no APNs key in place")
        key_pem, key_id, team = loaded
        team = team or fallback_team
        if not team:
            raise LookupError("no team id for the APNs key")
        now = self.clock()
        with self._lock:
            held = self._jwt.get((key_id, team))
            if held and not renew and now - held[1] < JWT_LIFETIME:
                return held[0]
            token = make_jwt(key_pem, key_id, team, now)
            self._jwt[(key_id, team)] = (token, now)
            return token

    def send(self, *, token: str, environment: str, topic: str, push_type: str, payload: dict,
             priority: int = 10, collapse_id: Optional[str] = None, expiration: Optional[int] = None,
             team_id: Optional[str] = None) -> Result:
        host = HOSTS.get(environment, HOSTS["production"])
        body = json.dumps(payload, separators=(",", ":"), ensure_ascii=False).encode()
        result = Result(0, "NotSent")
        for attempt in range(2):
            headers = {
                "authorization": f"bearer {self._token(team_id, renew=attempt > 0)}",
                "apns-topic": topic,
                "apns-push-type": push_type,
                "apns-priority": str(priority),
            }
            if collapse_id:
                headers["apns-collapse-id"] = collapse_id
            if expiration is not None:
                headers["apns-expiration"] = str(expiration)
            status, received, text = self.transport(f"{host}/3/device/{token}", headers, body)
            reason = ""
            if text.strip():
                try:
                    reason = str(json.loads(text).get("reason", ""))
                except ValueError:
                    reason = text.decode(errors="replace")[:120]
            result = Result(status, reason, received.get("apns-id", ""))
            # A provider token Apple calls expired: make a new one and try once more.
            if status == 403 and reason == "ExpiredProviderToken" and attempt == 0:
                continue
            return result
        return result
