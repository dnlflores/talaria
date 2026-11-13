"""The watcher: one per Mac, running inside the Hermes gateway process next to the plugin's routes.

It dials the gateway the way a local client does (the control socket's host-scoped ticket),
polls ``session.active_list`` for every bot, follows each busy chat's events with
``session.resume``, and hands every change to the notifier on one sender thread, so pushes for a
chat leave in order.
"""
from __future__ import annotations

import asyncio
import fcntl
import logging
import os
import threading
import time
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path
from typing import Callable, Optional

from .apns import APNs, Credentials
from .notifier import Notifier
from .store import Store
from .tracker import Change, Tracker, Turn

log = logging.getLogger("talaria_push")

POLL_SECONDS = 2.0


def hermes_root() -> Path:
    try:
        from hermes_constants import get_default_hermes_root
        return Path(get_default_hermes_root())
    except Exception:  # noqa: BLE001 -- outside Hermes (unit tests)
        return Path(os.environ.get("HERMES_HOME", "~/.hermes")).expanduser()


def data_dir() -> Path:
    override = os.environ.get("TALARIA_PUSH_HOME")
    folder = Path(override).expanduser() if override else hermes_root() / "plugin-data" / "talaria-push"
    folder.mkdir(parents=True, exist_ok=True)
    os.chmod(folder, 0o700)
    return folder


def profile_names(root: Path) -> list[str]:
    """Every bot: the default profile plus each folder under ``profiles/`` with a config."""
    names = ["default"]
    folder = root / "profiles"
    if folder.is_dir():
        names += sorted(p.name for p in folder.iterdir() if p.is_dir() and (p / "config.yaml").exists())
    return names


class Runtime:
    def __init__(self, folder: Optional[Path] = None, profiles: Optional[Callable[[], list[str]]] = None):
        self.folder = folder or data_dir()
        self.store = Store(self.folder / "state.json")
        self.apns = APNs(Credentials(self.folder))
        self.notifier = Notifier(self.store, self.apns)
        self.tracker = Tracker()
        self.profiles = profiles or (lambda: profile_names(hermes_root()))
        self.sender = ThreadPoolExecutor(max_workers=1, thread_name_prefix="talaria-push-send")
        self.connected = False
        self.owner = False
        self.last_error = ""
        self._lock = threading.Lock()
        self._stop = threading.Event()
        self._thread: Optional[threading.Thread] = None
        self._lock_handle = None

    # MARK: Life

    def start(self) -> None:
        if self._thread is not None:
            return
        self._thread = threading.Thread(target=self._run, name="talaria-push-watcher", daemon=True)
        self._thread.start()

    def stop(self) -> None:
        self._stop.set()

    def _take_lock(self) -> bool:
        """One watcher per Mac: a second process that imports the routes (``hermes dashboard``,
        route inspection) serves registrations but leaves the watching to the first."""
        if self._lock_handle is not None:
            return True
        handle = open(self.folder / "watcher.lock", "w")
        try:
            fcntl.flock(handle, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except OSError:
            handle.close()
            return False
        self._lock_handle = handle
        self.owner = True
        return True

    def _run(self) -> None:
        backoff = 2.0
        while not self._stop.is_set():
            if not self._take_lock():
                self._stop.wait(30)
                continue
            try:
                asyncio.run(self._watch())
                backoff = 2.0
            except Exception as exc:  # noqa: BLE001 -- the gateway restarts, drops sockets; keep trying
                self.last_error = f"{type(exc).__name__}: {exc}"[:300]
                log.info("talaria-push: watcher reconnecting after %s", self.last_error)
            self.connected = False
            self._stop.wait(backoff)
            backoff = min(backoff * 2, 60.0)

    async def _watch(self) -> None:
        from tui_gateway.owner_forward import connect_owner, discover_owner

        root = hermes_root()
        endpoint = await asyncio.to_thread(discover_owner, root)
        async with connect_owner(root, endpoint, scope="host", max_size=8 * 2 ** 20) as client:
            self.connected = True
            self.last_error = ""
            with self._lock:
                # A new socket follows nothing yet.
                for turn in self.tracker.turns.values():
                    turn.subscription_id = None
            pump = asyncio.create_task(self._pump(client))
            try:
                while not self._stop.is_set():
                    await self._poll(client)
                    await asyncio.sleep(POLL_SECONDS)
                    if pump.done():
                        raise pump.exception() or ConnectionError("the event stream ended")
            finally:
                pump.cancel()

    # MARK: Watching

    async def _poll(self, client) -> None:
        from hermes_cli.gateway_client import GatewayRPCError

        now = time.time()
        for profile in self.profiles():
            try:
                answer = await client.rpc("session.active_list", profile=profile)
            except GatewayRPCError:
                continue  # a bot the gateway does not serve
            rows = answer.get("sessions", []) if isinstance(answer, dict) else []
            with self._lock:
                changes = self.tracker.observe(profile, rows, now)
            for change in changes:
                if change.kind == "started":
                    await self._follow(client, change.turn)
                elif change.kind == "finished":
                    await self._unfollow(client, change.turn)
                self._dispatch(change)
        for turn in list(self.tracker.turns.values()):
            if turn.subscription_id is None:
                await self._follow(client, turn)
        self.sender.submit(self._safe, self.notifier.flush)
        with self._lock:
            self.tracker.forget_finished(now - 3600)

    async def _follow(self, client, turn: Turn) -> None:
        """Subscribe to a busy chat's events: its steps, questions and final answer."""
        from hermes_cli.gateway_client import GatewayRPCError

        try:
            snapshot = await client.rpc("session.resume", session_id=turn.session_id, profile=turn.profile,
                                        omit_messages=True)
        except GatewayRPCError as exc:
            turn.subscription_id = ""  # tried; the poll still sees it start and end
            log.debug("talaria-push: could not follow %s: %s", turn.session_id, exc)
            return
        turn.subscription_id = str(snapshot.get("subscription_id") or "")
        with self._lock:
            changes = self.tracker.adopt_prompts(turn.session_id, snapshot.get("prompts") or [])
        for change in changes:
            self._dispatch(change)

    async def _unfollow(self, client, turn: Turn) -> None:
        if not turn.subscription_id:
            return
        try:
            await client.rpc("session.detach", session_id=turn.session_id, profile=turn.profile,
                             subscription_id=turn.subscription_id)
        except Exception:  # noqa: BLE001 -- best effort; the gateway drops it with the socket anyway
            pass

    async def _pump(self, client) -> None:
        while True:
            event = await client.events.get()
            if isinstance(event, BaseException):
                raise event
            params = event.get("params") if isinstance(event, dict) else None
            if not isinstance(params, dict):
                continue
            session_id, kind = params.get("session_id"), params.get("type")
            if not session_id or not kind:
                continue
            payload = params.get("payload")
            with self._lock:
                changes = self.tracker.event(session_id, kind, payload if isinstance(payload, dict) else {})
            for change in changes:
                self._dispatch(change)

    def _dispatch(self, change: Change) -> None:
        self.sender.submit(self._safe, self.notifier.handle, change)

    @staticmethod
    def _safe(function, *args) -> None:
        try:
            function(*args)
        except Exception:  # noqa: BLE001 -- the sender thread must survive any one push
            log.exception("talaria-push: send failed")

    # MARK: For the routes

    def register_activity(self, device_id: str, session_id: str, profile: str, token: str) -> None:
        self.store.set_activity(device_id, session_id, profile, token)
        with self._lock:
            turn = self.tracker.turns.get(session_id) or self.tracker.finished.get(session_id)
        self.sender.submit(self._safe, self.notifier.activity_registered, device_id, turn)

    def status(self) -> dict:
        with self._lock:
            busy = [{"profile": t.profile, "phase": t.phase, "started_at": round(t.started_at)}
                    for t in self.tracker.turns.values()]
        devices = self.store.devices()
        team = next((d.get("team_id") for d in devices if d.get("team_id")), None)
        return {
            "watcher": {"owner": self.owner, "connected": self.connected, "last_error": self.last_error,
                        "busy": busy},
            "apns": {"configured": self.apns.configured(team), "key_id": self.apns.key_id()},
            "devices": [{"name": d.get("name", ""), "environment": d.get("environment"), "alerts": d.get("alerts"),
                         "live_activities": d.get("live_activities"), "scope": d.get("scope"),
                         "has_token": bool(d.get("token")),
                         "has_push_to_start": bool(d.get("push_to_start_token"))} for d in devices],
            "recent": list(self.notifier.recent)[-15:],
        }


_runtime: Optional[Runtime] = None
_runtime_lock = threading.Lock()


def shared() -> Runtime:
    """The process's runtime, started on first use."""
    global _runtime
    with _runtime_lock:
        if _runtime is None:
            _runtime = Runtime()
            # Tests of the routes run without a gateway to watch.
            if os.environ.get("TALARIA_PUSH_NO_WATCH") != "1":
                _runtime.start()
        return _runtime
