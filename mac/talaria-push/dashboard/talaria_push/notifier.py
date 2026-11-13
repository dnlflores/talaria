"""Turns tracker changes into pushes for every registered phone."""
from __future__ import annotations

import logging
import time
from collections import deque
from typing import Callable, Optional

from . import payloads
from .apns import APNs, Result
from .store import Store
from .tracker import Change, Turn

log = logging.getLogger("talaria_push")

# Step changes come often; Apple throttles a Live Activity that updates too much. At most one step
# update per activity in this many seconds (the latest step wins); phase changes go at once.
STEP_INTERVAL = 12.0

# iOS allows only a handful of push-started Live Activities an hour (about eight on a development
# build), and quick replies do not need one: the finished notification says it all. So the Mac
# starts one only for a reply still running after this many seconds, or one asking a question.
START_AFTER = 15.0


class Notifier:
    def __init__(self, store: Store, apns: APNs, clock: Callable[[], float] = time.time):
        self.store = store
        self.apns = apns
        self.clock = clock
        self.recent: deque[dict] = deque(maxlen=40)
        self._last_update: dict[tuple[str, str], float] = {}
        self._pending: dict[tuple[str, str], Turn] = {}
        self._pending_start: dict[tuple[str, str], Turn] = {}

    # MARK: Routing

    def wants(self, device: dict, turn: Turn) -> bool:
        if device.get("scope") == "phone":
            return self.store.follows(device["device_id"], turn.session_id)
        return True

    def handle(self, change: Change) -> None:
        for device in self.store.devices():
            if not self.wants(device, change.turn):
                continue
            try:
                self._for_device(device, change)
            except LookupError as exc:  # no key yet: nothing can be sent, and that is not news
                self.recent.append({"at": round(self.clock(), 1), "kind": change.kind,
                                    "device": device.get("name") or device["device_id"][:8], "status": 0,
                                    "reason": str(exc)})
            except Exception:  # noqa: BLE001 -- one phone's failure must not stop the others
                log.exception("talaria-push: %s for %s failed", change.kind, change.turn.session_id)

    def _for_device(self, device: dict, change: Change) -> None:
        turn, kind, now = change.turn, change.kind, self.clock()
        bot = payloads.bot_name(turn.profile, device.get("bots"))
        alerts = device.get("alerts", True)
        activities = device.get("live_activities", True)
        key = (device["device_id"], turn.session_id)
        if kind == "started":
            if activities:
                if now - turn.started_at >= START_AFTER:
                    self._start_activity(device, turn, bot, now)
                else:
                    self._pending_start[key] = turn
        elif kind == "step":
            if activities:
                self._update_activity(device, turn, now, priority=5, throttle=True)
        elif kind == "waiting":
            if alerts:
                self._alert(device, turn, payloads.waiting_alert(
                    bot=bot, title=turn.title, question=turn.question, session_id=turn.session_id,
                    profile=turn.profile, state=turn.state() if activities else None), "waiting")
            if activities:
                if self._pending_start.pop(key, None) is not None:
                    self._start_activity(device, turn, bot, now)
                else:
                    self._update_activity(device, turn, now, priority=10)
        elif kind == "resumed":
            if activities:
                self._update_activity(device, turn, now, priority=5)
        elif kind == "finished":
            self._pending_start.pop(key, None)
            if alerts:
                self._alert(device, turn, payloads.finished_alert(
                    bot=bot, title=turn.title, text=turn.final_text, status=turn.final_status,
                    session_id=turn.session_id, profile=turn.profile,
                    state=turn.state() if activities else None), "finished")
            if activities:
                self._end_activity(device, turn, now)

    def flush(self) -> None:
        """Activities whose reply has now run long enough, and step updates held back by the
        throttle whose wait is over."""
        now = self.clock()
        for key, turn in list(self._pending_start.items()):
            if turn.ended_at is not None:
                self._pending_start.pop(key, None)
            elif now - turn.started_at >= START_AFTER:
                self._pending_start.pop(key, None)
                device = self.store.device(key[0])
                if device and device.get("live_activities", True) and self.wants(device, turn):
                    self._start_activity(device, turn, payloads.bot_name(turn.profile, device.get("bots")), now)
        for key, turn in list(self._pending.items()):
            if now - self._last_update.get(key, 0) < STEP_INTERVAL:
                continue
            self._pending.pop(key, None)
            device = self.store.device(key[0])
            if device and turn.ended_at is None:
                self._update_activity(device, turn, now, priority=5)

    def activity_registered(self, device_id: str, turn: Optional[Turn]) -> None:
        """An activity's update token just arrived: bring it up to date at once. A turn that ended
        before the token came is ended now, or the activity would say Working forever."""
        device = self.store.device(device_id)
        if device is None or turn is None:
            return
        now = self.clock()
        if turn.ended_at is not None:
            self._end_activity(device, turn, now)
        else:
            self._update_activity(device, turn, now, priority=10)

    # MARK: Sends

    def _alert(self, device: dict, turn: Turn, payload: dict, kind: str) -> None:
        token = device.get("token")
        if not token:
            return
        result = self.apns.send(
            token=token, environment=device.get("environment", "production"), topic=device["topic"],
            push_type="alert", payload=payload, priority=10, collapse_id=payloads.collapse_id(turn.session_id),
            team_id=device.get("team_id"))
        self._note(kind, device, result)
        if result.token_dead:
            self.store.forget_token(device["device_id"], "token")

    def _start_activity(self, device: dict, turn: Turn, bot: str, now: float) -> None:
        if self.store.activity(device["device_id"], turn.session_id):
            # The phone already has one for this chat (it was open when the turn began).
            self._update_activity(device, turn, now, priority=10)
            return
        token = device.get("push_to_start_token")
        if not token:
            return
        payload = payloads.activity_start(now=now, profile=turn.profile, session_id=turn.session_id, bot=bot,
                                          title=turn.title, state=turn.state())
        result = self._activity_send(device, token, payload, priority=10)
        self._note("activity.start", device, result)
        if result.token_dead:
            self.store.forget_token(device["device_id"], "push_to_start_token")

    def _update_activity(self, device: dict, turn: Turn, now: float, *, priority: int, throttle: bool = False) -> None:
        key = (device["device_id"], turn.session_id)
        record = self.store.activity(*key)
        if not record:
            return
        if throttle and now - self._last_update.get(key, 0) < STEP_INTERVAL:
            self._pending[key] = turn
            return
        self._pending.pop(key, None)
        self._last_update[key] = now
        result = self._activity_send(device, record["token"], payloads.activity_update(now=now, state=turn.state()),
                                     priority=priority)
        self._note("activity.update", device, result)
        if result.token_dead:
            self.store.drop_activity(*key)

    def _end_activity(self, device: dict, turn: Turn, now: float) -> None:
        key = (device["device_id"], turn.session_id)
        self._pending.pop(key, None)
        record = self.store.activity(*key)
        if not record:
            return
        result = self._activity_send(device, record["token"], payloads.activity_end(now=now, state=turn.state()),
                                     priority=10)
        self._note("activity.end", device, result)
        if result.ok or result.token_dead:
            self.store.drop_activity(*key)

    def _activity_send(self, device: dict, token: str, payload: dict, *, priority: int) -> Result:
        return self.apns.send(
            token=token, environment=device.get("environment", "production"),
            topic=f"{device['topic']}.push-type.liveactivity", push_type="liveactivity", payload=payload,
            priority=priority, team_id=device.get("team_id"))

    def send_test(self, device: dict) -> Result:
        token = device.get("token")
        if not token:
            return Result(0, "NoDeviceToken")
        result = self.apns.send(token=token, environment=device.get("environment", "production"),
                                topic=device["topic"], push_type="alert", payload=payloads.test_alert(),
                                team_id=device.get("team_id"))
        self._note("test", device, result)
        return result

    def _note(self, kind: str, device: dict, result: Result) -> None:
        entry = {"at": round(self.clock(), 1), "kind": kind, "device": device.get("name") or device["device_id"][:8],
                 "status": result.status, "reason": result.reason}
        self.recent.append(entry)
        if not result.ok:
            log.warning("talaria-push: %s -> %s %s", kind, result.status, result.reason)
