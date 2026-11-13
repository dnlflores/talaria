"""Talaria push: routes the phone registers with, mounted at /api/plugins/talaria-push/.

The routes sit behind Hermes' own sign-in like every /api route of the listener the app already
talks to. Importing this module starts the watcher (one per Mac, see talaria_push/runtime.py).
"""
import re
import sys
from pathlib import Path
from typing import Literal, Optional

from fastapi import APIRouter, HTTPException
from pydantic import BaseModel, Field, field_validator

sys.path.insert(0, str(Path(__file__).resolve().parent))

from talaria_push import runtime as _runtime  # noqa: E402

router = APIRouter()
_HEX = re.compile(r"^[0-9a-fA-F]{32,256}$")
_ID = re.compile(r"^[A-Za-z0-9._-]{1,120}$")
_BUNDLE = re.compile(r"^[A-Za-z0-9-]+(\.[A-Za-z0-9-]+)+$")
_TEAM = re.compile(r"^[A-Z0-9]{10}$")


def _runtime_now():
    return _runtime.shared()


_runtime_now()


class DeviceIn(BaseModel):
    device_id: str
    name: str = Field(default="", max_length=80)
    token: Optional[str] = None
    push_to_start_token: Optional[str] = None
    environment: Literal["development", "production"] = "production"
    topic: str
    team_id: Optional[str] = None
    alerts: bool = True
    live_activities: bool = True
    scope: Literal["all", "phone"] = "all"
    bots: dict[str, str] = Field(default_factory=dict)

    @field_validator("device_id")
    @classmethod
    def _device_id(cls, value: str) -> str:
        if not _ID.match(value):
            raise ValueError("bad device_id")
        return value

    @field_validator("token", "push_to_start_token")
    @classmethod
    def _token(cls, value: Optional[str]) -> Optional[str]:
        if value is not None and not _HEX.match(value):
            raise ValueError("tokens are hex")
        return value.lower() if value else value

    @field_validator("topic")
    @classmethod
    def _topic(cls, value: str) -> str:
        if not _BUNDLE.match(value) or len(value) > 155:
            raise ValueError("topic is the app's bundle id")
        return value

    @field_validator("team_id")
    @classmethod
    def _team(cls, value: Optional[str]) -> Optional[str]:
        if value and not _TEAM.match(value):
            raise ValueError("bad team id")
        return value or None

    @field_validator("bots")
    @classmethod
    def _bots(cls, value: dict[str, str]) -> dict[str, str]:
        return {k[:80]: v[:80] for k, v in list(value.items())[:100]}


class ActivityIn(BaseModel):
    device_id: str
    session_id: str
    profile: str = "default"
    token: str

    @field_validator("device_id", "session_id", "profile")
    @classmethod
    def _ids(cls, value: str) -> str:
        if not _ID.match(value):
            raise ValueError("bad id")
        return value

    @field_validator("token")
    @classmethod
    def _token(cls, value: str) -> str:
        if not _HEX.match(value):
            raise ValueError("tokens are hex")
        return value.lower()


class FollowIn(BaseModel):
    device_id: str
    session_id: str

    @field_validator("device_id", "session_id")
    @classmethod
    def _ids(cls, value: str) -> str:
        if not _ID.match(value):
            raise ValueError("bad id")
        return value


class DeviceRef(BaseModel):
    device_id: str


@router.get("/status")
def status():
    return _runtime_now().status()


@router.post("/devices")
def register_device(device: DeviceIn):
    runtime = _runtime_now()
    runtime.store.upsert_device(device.model_dump())
    runtime.store.prune()
    return {"ok": True, "apns_configured": runtime.apns.configured(device.team_id)}


@router.delete("/devices/{device_id}")
def remove_device(device_id: str):
    if not _ID.match(device_id):
        raise HTTPException(status_code=400, detail="bad device_id")
    return {"ok": True, "removed": _runtime_now().store.remove_device(device_id)}


@router.post("/activities")
def register_activity(activity: ActivityIn):
    runtime = _runtime_now()
    if runtime.store.device(activity.device_id) is None:
        raise HTTPException(status_code=404, detail="register the device first")
    runtime.register_activity(activity.device_id, activity.session_id, activity.profile, activity.token)
    return {"ok": True}


@router.post("/follow")
def follow(chat: FollowIn):
    _runtime_now().store.follow(chat.device_id, chat.session_id)
    return {"ok": True}


@router.post("/test")
def send_test(ref: DeviceRef):
    runtime = _runtime_now()
    device = runtime.store.device(ref.device_id)
    if device is None:
        raise HTTPException(status_code=404, detail="register the device first")
    try:
        result = runtime.sender.submit(runtime.notifier.send_test, device).result(timeout=30)
    except LookupError as exc:
        raise HTTPException(status_code=409, detail=str(exc)) from exc
    return {"ok": result.ok, "status": result.status, "reason": result.reason}
