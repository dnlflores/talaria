"""Which chats are working, waiting on you, or done: ``session.active_list`` polls plus the events
of the chats the watcher follows. Pure state, no I/O, so every transition is unit-tested.
"""
from __future__ import annotations

from dataclasses import dataclass, field
from typing import Optional

from . import payloads

# Conversations a person started (desktop app, terminal, Talaria): the same set the app files under
# Chats. Messaging threads, cron runs, kanban tasks and sub-agents do not notify.
CHAT_SOURCES = {"desktop", "cli", "tui", "local", "codex", "gateway", "gui", ""}
BUSY = {"working", "waiting"}


@dataclass
class Turn:
    session_id: str
    profile: str
    source: str
    title: str
    status: str
    started_at: float
    step: Optional[str] = None
    question: Optional[str] = None
    final_text: Optional[str] = None
    final_status: Optional[str] = None
    ended_at: Optional[float] = None
    subscription_id: Optional[str] = None

    @property
    def phase(self) -> str:
        if self.ended_at is not None:
            return {"error": "failed", "interrupted": "stopped"}.get(self.final_status or "", "done")
        return "waiting" if self.status == "waiting" else "working"

    def state(self) -> dict:
        """The Live Activity's content state for this turn now."""
        if self.ended_at is not None:
            return payloads.content_state(
                phase=self.phase, started_at=self.started_at, ended_at=self.ended_at, title=self.title or None,
                summary=payloads.preview(self.final_text, 140) or None)
        step = self.question if self.status == "waiting" and self.question else self.step
        return payloads.content_state(phase=self.phase, started_at=self.started_at, title=self.title or None,
                                      step=step)


@dataclass
class Change:
    kind: str  # started | waiting | resumed | step | finished
    turn: Turn


@dataclass
class Tracker:
    turns: dict[str, Turn] = field(default_factory=dict)
    # Finished turns, kept a while for an activity token that arrives after the end.
    finished: dict[str, Turn] = field(default_factory=dict)

    def observe(self, profile: str, rows: list[dict], now: float) -> list[Change]:
        """One ``session.active_list`` answer for ``profile``."""
        changes: list[Change] = []
        seen: set[str] = set()
        for row in rows:
            sid = str(row.get("id") or row.get("session_key") or "")
            source = str(row.get("source") or "").lower()
            status = str(row.get("status") or "").lower()
            if not sid or source not in CHAT_SOURCES:
                continue
            seen.add(sid)
            turn = self.turns.get(sid)
            title = str(row.get("title") or "")
            if status in BUSY:
                if turn is None:
                    turn = Turn(sid, profile, source, title, status, now)
                    self.turns[sid] = turn
                    self.finished.pop(sid, None)
                    changes.append(Change("started", turn))
                    if status == "waiting":
                        changes.append(Change("waiting", turn))
                    continue
                if title:
                    turn.title = title
                if status != turn.status:
                    turn.status = status
                    if status == "working":
                        turn.question = None
                    changes.append(Change("waiting" if status == "waiting" else "resumed", turn))
            elif turn is not None and status != "starting":
                # ``starting`` is the next queued message about to run: still busy.
                if title:
                    turn.title = title
                changes.append(self._finish(turn, now))
        for sid, turn in list(self.turns.items()):
            if turn.profile == profile and sid not in seen:
                changes.append(self._finish(turn, now))
        return changes

    def _finish(self, turn: Turn, now: float) -> Change:
        turn.ended_at = now
        self.turns.pop(turn.session_id, None)
        self.finished[turn.session_id] = turn
        return Change("finished", turn)

    def event(self, session_id: str, kind: str, payload: dict) -> list[Change]:
        """An event from a chat the watcher follows."""
        turn = self.turns.get(session_id)
        if turn is None or not isinstance(payload, dict):
            return []
        if kind == "tool.start":
            step = payloads.step_text(payload)
            if step != turn.step:
                turn.step = step
                return [Change("step", turn)]
        elif kind in ("clarify.request", "approval.request"):
            turn.question = question_text(kind, payload)
            if turn.status != "waiting":
                turn.status = "waiting"
                return [Change("waiting", turn)]
        elif kind in ("clarify.settled", "approval.settled", "prompt.settled"):
            if turn.status == "waiting":
                turn.status = "working"
                turn.question = None
                if turn.step == payloads.verb("clarify"):
                    turn.step = None  # answered: it is no longer asking
                return [Change("resumed", turn)]
        elif kind == "message.start":
            # The next turn of a busy stretch (a queued message): its answer replaces the last one.
            turn.final_text = None
            turn.final_status = None
        elif kind == "message.complete":
            text = payload.get("text")
            turn.final_text = text if isinstance(text, str) else turn.final_text
            status = payload.get("status")
            turn.final_status = status if isinstance(status, str) else "complete"
        elif kind == "session.title":
            title = payload.get("title")
            if isinstance(title, str) and title.strip():
                turn.title = title.strip()
        return []

    def adopt_prompts(self, session_id: str, prompts: list) -> list[Change]:
        """Questions already open when the watcher subscribed (``session.resume``'s ``prompts``)."""
        for prompt in prompts or []:
            if isinstance(prompt, dict):
                kind = "approval.request" if prompt.get("kind") == "approval" else "clarify.request"
                return self.event(session_id, kind, prompt)
        return []

    def forget_finished(self, older_than: float) -> None:
        for sid, turn in list(self.finished.items()):
            if (turn.ended_at or 0) < older_than:
                self.finished.pop(sid, None)


def question_text(kind: str, payload: dict) -> str:
    if kind == "approval.request":
        description = str(payload.get("description") or "").strip()
        return description or "Wants your approval to run a command."
    question = payload.get("question")
    if isinstance(question, str) and question.strip():
        return question.strip()
    questions = payload.get("questions")
    if isinstance(questions, list) and questions and isinstance(questions[0], dict):
        return str(questions[0].get("question") or "").strip() or "Has a question for you."
    return "Has a question for you."
