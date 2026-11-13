"""What the phones registered: device tokens, Live Activity tokens and chats sent from a phone.

One JSON file, written atomically (0600). Another process (``hermes dashboard`` next to the
gateway) may write it too, so every read checks the file's mtime and every write holds a lock file.
"""
from __future__ import annotations

import fcntl
import json
import os
import threading
import time
from contextlib import contextmanager
from pathlib import Path
from typing import Any, Optional

# A chat sent from the phone counts as "from this phone" for a day after the last send.
FOLLOW_TTL = 24 * 3600
# Activity tokens of activities iOS has long since ended.
ACTIVITY_TTL = 12 * 3600


class Store:
    def __init__(self, path: Path, clock=time.time):
        self.path = path
        self.clock = clock
        self._lock = threading.RLock()
        self._mtime: Optional[float] = None
        self._data: dict[str, Any] = {"devices": {}, "activities": {}, "follows": {}}
        path.parent.mkdir(parents=True, exist_ok=True)

    # MARK: Files

    @contextmanager
    def _file_lock(self):
        with open(self.path.with_suffix(".lock"), "w") as handle:
            fcntl.flock(handle, fcntl.LOCK_EX)
            try:
                yield
            finally:
                fcntl.flock(handle, fcntl.LOCK_UN)

    def _reload(self) -> None:
        try:
            mtime = self.path.stat().st_mtime
        except FileNotFoundError:
            return
        if mtime == self._mtime:
            return
        try:
            data = json.loads(self.path.read_text())
        except (OSError, ValueError):
            return
        if isinstance(data, dict):
            for key in ("devices", "activities", "follows"):
                if not isinstance(data.get(key), dict):
                    data[key] = {}
            self._data = data
            self._mtime = mtime

    def _save(self) -> None:
        temporary = self.path.with_suffix(".tmp")
        fd = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
        with os.fdopen(fd, "w") as handle:
            json.dump(self._data, handle, indent=1, sort_keys=True)
        os.replace(temporary, self.path)
        self._mtime = self.path.stat().st_mtime

    @contextmanager
    def _write(self):
        with self._lock, self._file_lock():
            self._reload()
            yield self._data
            self._save()

    def _read(self) -> dict[str, Any]:
        with self._lock:
            self._reload()
            return self._data

    # MARK: Devices

    def upsert_device(self, device: dict) -> dict:
        with self._write() as data:
            current = data["devices"].get(device["device_id"], {})
            current.update({k: v for k, v in device.items() if v is not None})
            current["updated_at"] = self.clock()
            data["devices"][device["device_id"]] = current
            return dict(current)

    def remove_device(self, device_id: str) -> bool:
        with self._write() as data:
            data["activities"].pop(device_id, None)
            data["follows"].pop(device_id, None)
            return data["devices"].pop(device_id, None) is not None

    def devices(self) -> list[dict]:
        return [dict(d) for d in self._read()["devices"].values()]

    def device(self, device_id: str) -> Optional[dict]:
        found = self._read()["devices"].get(device_id)
        return dict(found) if found else None

    def forget_token(self, device_id: str, field: str) -> None:
        """A token APNs called dead (``token`` or ``push_to_start_token``)."""
        with self._write() as data:
            device = data["devices"].get(device_id)
            if device:
                device.pop(field, None)

    # MARK: Live Activities

    def set_activity(self, device_id: str, session_id: str, profile: str, token: str) -> None:
        with self._write() as data:
            data["activities"].setdefault(device_id, {})[session_id] = {
                "token": token, "profile": profile, "updated_at": self.clock()}

    def activity(self, device_id: str, session_id: str) -> Optional[dict]:
        found = self._read()["activities"].get(device_id, {}).get(session_id)
        return dict(found) if found else None

    def drop_activity(self, device_id: str, session_id: str) -> None:
        with self._write() as data:
            data["activities"].get(device_id, {}).pop(session_id, None)

    # MARK: Chats sent from a phone

    def follow(self, device_id: str, session_id: str) -> None:
        with self._write() as data:
            data["follows"].setdefault(device_id, {})[session_id] = self.clock()

    def follows(self, device_id: str, session_id: str) -> bool:
        stamp = self._read()["follows"].get(device_id, {}).get(session_id)
        return stamp is not None and self.clock() - float(stamp) < FOLLOW_TTL

    def prune(self) -> None:
        now = self.clock()
        with self._write() as data:
            for device_id, chats in list(data["follows"].items()):
                data["follows"][device_id] = {k: v for k, v in chats.items() if now - float(v) < FOLLOW_TTL}
            for device_id, chats in list(data["activities"].items()):
                data["activities"][device_id] = {
                    k: v for k, v in chats.items() if now - float(v.get("updated_at", 0)) < ACTIVITY_TTL}
