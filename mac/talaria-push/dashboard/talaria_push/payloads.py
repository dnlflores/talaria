"""What the pushes say. Pure functions, so the wording and the wire shape are unit-tested.

The Live Activity fields must match ``ChatActivityAttributes`` in the app (Shared/ChatActivity.swift).
"""
from __future__ import annotations

import hashlib
import re
from pathlib import PurePosixPath
from typing import Optional

ATTRIBUTES_TYPE = "ChatActivityAttributes"
# How long a finished Live Activity stays on the Lock Screen.
DISMISS_AFTER = 10 * 60
# A running one with no news for this long shows as stale.
STALE_AFTER = 60 * 60


def bot_name(profile: str, bots: Optional[dict] = None) -> str:
    """The name the app shows for a bot: its title, else Hermes for the default profile."""
    if bots and isinstance(bots.get(profile), str) and bots[profile].strip():
        return bots[profile].strip()
    return "Hermes" if profile in ("", "default") else profile


def verb(name: str) -> str:
    """A tool call said as a person would. Same words as the app's working row (Working.swift)."""
    table = {
        "terminal": "Running a command", "shell": "Running a command", "process": "Running a command",
        "process_manage": "Running a command", "execute_code": "Running code", "read_file": "Reading a file",
        "write_file": "Writing a file", "patch": "Editing a file", "search_files": "Searching files",
        "web_search": "Searching the web", "web_extract": "Reading a page", "delegate_task": "Working with a helper",
        "clarify": "Asking you", "vision_analyze": "Looking at an image", "text_to_speech": "Making audio",
    }
    if name in table:
        return table[name]
    if name.startswith("browser"):
        return "Using the browser"
    if "skill" in name:
        return "Reading a skill"
    if "memory" in name or "notes" in name:
        return "Checking memory"
    words = re.sub(r"[_\-.]+", " ", name.removeprefix("mcp__")).strip()
    return f"Using {words.lower()}" if words else "Working"


# Tools whose target is safe and useful on a Lock Screen: a file's name, a skill's name.
_FILE_TOOLS = {"read_file", "write_file", "patch"}


def step_text(payload: dict) -> str:
    """The Live Activity's line for a ``tool.start``. Commands and code stay off the Lock Screen
    (anyone can read it); only a file's or skill's name joins the verb."""
    name = str(payload.get("name") or payload.get("tool_name") or "")
    label = verb(name)
    raw_args = payload.get("args")
    args: dict = raw_args if isinstance(raw_args, dict) else {}
    target = ""
    if name in _FILE_TOOLS:
        path = args.get("path") or args.get("file_path") or ""
        if isinstance(path, str) and path:
            target = PurePosixPath(path).name
    elif "skill" in name:
        target = str(args.get("name") or "")
    return f"{label}: {target}" if target else label


_FENCE = re.compile(r"```.*?(```|$)", re.S)
_IMAGE = re.compile(r"!\[[^\]]*\]\([^)]*\)")
_LINK = re.compile(r"\[([^\]]+)\]\([^)]*\)")
_MEDIA = re.compile(r"^\s*MEDIA:\S+\s*$", re.M)


def preview(text: Optional[str], limit: int = 180) -> str:
    """Markdown flattened to one readable line for a notification or the Lock Screen."""
    if not text:
        return ""
    text = _FENCE.sub(" ", text)
    text = _MEDIA.sub(" ", text)
    text = _IMAGE.sub(" ", text)
    text = _LINK.sub(r"\1", text)
    text = re.sub(r"^\s{0,3}(#{1,6}|>|[-*+]|\d+[.)])\s+", "", text, flags=re.M)
    text = re.sub(r"(\*\*|__|`|~~)", "", text)
    text = re.sub(r"(?<!\w)[*_](\S[^*_]*\S|\S)[*_](?!\w)", r"\1", text)
    text = re.sub(r"\s+", " ", text).strip()
    if len(text) > limit:
        cut = text[: limit - 1].rsplit(" ", 1)[0] if " " in text[: limit - 1] else text[: limit - 1]
        text = cut.rstrip(" ,.;:") + "…"
    return text


def collapse_id(session_id: str) -> str:
    """One notification per chat in Notification Center: APNs caps the id at 64 bytes."""
    return hashlib.sha1(session_id.encode()).hexdigest()


def chat_title(title: Optional[str]) -> str:
    title = (title or "").strip()
    return title if title else "New chat"


# MARK: Alerts


def _alert(title: str, subtitle: str, body: str, *, session_id: str, profile: str, kind: str,
           state: Optional[dict] = None) -> dict:
    """``state`` is the chat's Live Activity content state now. With it the alert also wakes the app
    (``content-available``), which moves the activity on itself: iOS does not hand the app the
    update token of an activity the Mac started by push, so the Mac often cannot."""
    alert = {"title": title, "body": body or subtitle}
    if body and subtitle:
        alert["subtitle"] = subtitle
    aps = {"alert": alert, "sound": "default", "thread-id": session_id, "mutable-content": 0}
    custom = {"kind": kind, "profile": profile, "session_id": session_id}
    if state is not None:
        aps["content-available"] = 1
        custom["state"] = state
    return {"aps": aps, "talaria": custom}


def finished_alert(*, bot: str, title: Optional[str], text: Optional[str], status: Optional[str],
                   session_id: str, profile: str, state: Optional[dict] = None) -> dict:
    heading = {"error": f"{bot} hit an error", "interrupted": f"{bot} stopped"}.get(status or "", f"{bot} finished")
    body = preview(text) or ("The reply is ready." if status not in ("error", "interrupted") else "")
    return _alert(heading, chat_title(title), body, session_id=session_id, profile=profile, kind="finished",
                  state=state)


def waiting_alert(*, bot: str, title: Optional[str], question: Optional[str], session_id: str, profile: str,
                  state: Optional[dict] = None) -> dict:
    body = preview(question, 200) or "It is waiting for your answer."
    return _alert(f"{bot} needs you", chat_title(title), body, session_id=session_id, profile=profile, kind="waiting",
                  state=state)


def test_alert() -> dict:
    return {"aps": {"alert": {"title": "Talaria", "body": "Notifications from your Mac work."}, "sound": "default"},
            "talaria": {"kind": "test"}}


# MARK: Live Activities


def content_state(*, phase: str, started_at: float, title: Optional[str] = None, step: Optional[str] = None,
                  summary: Optional[str] = None, ended_at: Optional[float] = None) -> dict:
    state: dict = {"phase": phase, "startedAt": round(started_at, 3)}
    if ended_at is not None:
        state["endedAt"] = round(ended_at, 3)
    if step:
        state["step"] = step
    if summary:
        state["summary"] = summary
    if title:
        state["title"] = title
    return state


def activity_start(*, now: float, profile: str, session_id: str, bot: str, title: Optional[str],
                   state: dict) -> dict:
    """Push-to-start. ``input-push-token`` asks iOS for the new activity's own update token, which
    the app then registers (POST /activities); ``alert`` is required for a start."""
    return {"aps": {
        "timestamp": int(now), "event": "start", "content-state": state,
        "attributes-type": ATTRIBUTES_TYPE,
        "attributes": {"profile": profile, "sessionID": session_id, "botName": bot, "chatTitle": chat_title(title)},
        "alert": {"title": f"{bot} is working", "body": chat_title(title)},
        "input-push-token": 1,
        "stale-date": int(now + STALE_AFTER),
    }}


def activity_update(*, now: float, state: dict) -> dict:
    return {"aps": {"timestamp": int(now), "event": "update", "content-state": state,
                    "stale-date": int(now + STALE_AFTER)}}


def activity_end(*, now: float, state: dict) -> dict:
    return {"aps": {"timestamp": int(now), "event": "end", "content-state": state,
                    "dismissal-date": int(now + DISMISS_AFTER)}}
