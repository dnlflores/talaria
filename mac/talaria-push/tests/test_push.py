"""Unit tests for the Talaria push plugin. Run with the Hermes venv (it has cryptography, fastapi):

    ~/.hermes/hermes-agent/venv/bin/python -m unittest discover -s mac/talaria-push/tests -v
"""
import base64
import importlib.util
import json
import os
import sys
import tempfile
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent
DASHBOARD = HERE.parent / "dashboard"
sys.path.insert(0, str(DASHBOARD))

from cryptography.hazmat.primitives import hashes, serialization  # noqa: E402
from cryptography.hazmat.primitives.asymmetric import ec  # noqa: E402
from cryptography.hazmat.primitives.asymmetric.utils import encode_dss_signature  # noqa: E402

from talaria_push import payloads  # noqa: E402
from talaria_push.apns import APNs, Credentials, Result, make_jwt  # noqa: E402
from talaria_push.notifier import START_AFTER, STEP_INTERVAL, Notifier  # noqa: E402
from talaria_push.store import FOLLOW_TTL, Store  # noqa: E402
from talaria_push.tracker import Tracker  # noqa: E402


def b64decode(part: str) -> bytes:
    return base64.urlsafe_b64decode(part + "=" * (-len(part) % 4))


def new_key_pem() -> bytes:
    key = ec.generate_private_key(ec.SECP256R1())
    return key.private_bytes(serialization.Encoding.PEM, serialization.PrivateFormat.PKCS8,
                             serialization.NoEncryption())


class Clock:
    def __init__(self, now=1_800_000_000.0):
        self.now = now

    def __call__(self):
        return self.now


class FakeAPNs:
    """Records what would have gone to Apple."""

    def __init__(self, answers=None):
        self.sent = []
        self.answers = answers or {}

    def send(self, **kwargs):
        self.sent.append(kwargs)
        return self.answers.get(kwargs["token"], Result(200))

    def configured(self, team=None):
        return True

    def key_id(self):
        return "KEY"


class JWTTests(unittest.TestCase):
    def test_token_verifies_with_the_public_key(self):
        pem = new_key_pem()
        token = make_jwt(pem, "ABC123DEFG", "TEAM123456", 1_800_000_000)
        header, claims, signature = token.split(".")
        self.assertEqual(json.loads(b64decode(header)), {"alg": "ES256", "kid": "ABC123DEFG"})
        self.assertEqual(json.loads(b64decode(claims)), {"iss": "TEAM123456", "iat": 1_800_000_000})
        raw = b64decode(signature)
        self.assertEqual(len(raw), 64)
        der = encode_dss_signature(int.from_bytes(raw[:32], "big"), int.from_bytes(raw[32:], "big"))
        public = serialization.load_pem_private_key(pem, password=None).public_key()
        public.verify(der, f"{header}.{claims}".encode(), ec.ECDSA(hashes.SHA256()))

    def test_credentials_take_the_key_id_from_the_file_name(self):
        with tempfile.TemporaryDirectory() as folder:
            credentials = Credentials(Path(folder))
            self.assertIsNone(credentials.load())
            (Path(folder) / "AuthKey_ABC123DEFG.p8").write_bytes(new_key_pem())
            pem, key_id, team = credentials.load()
            self.assertEqual((key_id, team), ("ABC123DEFG", None))
            (Path(folder) / "config.json").write_text(json.dumps({"team_id": "TEAM123456"}))
            self.assertEqual(credentials.load()[2], "TEAM123456")


class APNsTests(unittest.TestCase):
    def setUp(self):
        self.folder = tempfile.TemporaryDirectory()
        (Path(self.folder.name) / "AuthKey_ABC123DEFG.p8").write_bytes(new_key_pem())
        self.calls = []
        self.answers = []

        def transport(url, headers, body):
            self.calls.append((url, headers, json.loads(body)))
            return self.answers.pop(0) if self.answers else (200, {"apns-id": "x"}, b"")

        self.apns = APNs(Credentials(Path(self.folder.name)), transport=transport, clock=Clock())

    def tearDown(self):
        self.folder.cleanup()

    def test_headers_host_and_body(self):
        result = self.apns.send(token="ab" * 32, environment="development", topic="com.example.app",
                                push_type="alert", payload={"aps": {}}, collapse_id="c1", team_id="TEAM123456")
        self.assertTrue(result.ok)
        url, headers, body = self.calls[0]
        self.assertEqual(url, f"https://api.sandbox.push.apple.com/3/device/{'ab' * 32}")
        self.assertEqual(headers["apns-topic"], "com.example.app")
        self.assertEqual(headers["apns-push-type"], "alert")
        self.assertEqual(headers["apns-priority"], "10")
        self.assertEqual(headers["apns-collapse-id"], "c1")
        self.assertTrue(headers["authorization"].startswith("bearer "))
        self.assertEqual(body, {"aps": {}})

    def test_production_host_and_cached_token(self):
        for _ in range(2):
            self.apns.send(token="cd" * 32, environment="production", topic="t.t", push_type="alert",
                           payload={}, team_id="TEAM123456")
        self.assertTrue(self.calls[0][0].startswith("https://api.push.apple.com/"))
        self.assertEqual(self.calls[0][1]["authorization"], self.calls[1][1]["authorization"])

    def test_expired_provider_token_is_renewed_once(self):
        self.answers = [(403, {}, b'{"reason":"ExpiredProviderToken"}'), (200, {}, b"")]
        self.apns.clock.now += 1
        result = self.apns.send(token="ef" * 32, environment="production", topic="t.t", push_type="alert",
                                payload={}, team_id="TEAM123456")
        self.assertTrue(result.ok)
        self.assertEqual(len(self.calls), 2)

    def test_dead_tokens(self):
        self.answers = [(400, {}, b'{"reason":"BadDeviceToken"}')]
        result = self.apns.send(token="aa" * 32, environment="production", topic="t.t", push_type="alert",
                                payload={}, team_id="TEAM123456")
        self.assertTrue(result.token_dead)
        self.assertFalse(Result(429, "TooManyRequests").token_dead)

    def test_no_team_means_not_configured(self):
        self.assertFalse(self.apns.configured(None))
        self.assertTrue(self.apns.configured("TEAM123456"))
        with self.assertRaises(LookupError):
            self.apns.send(token="aa" * 32, environment="production", topic="t.t", push_type="alert", payload={})


class PayloadTests(unittest.TestCase):
    def test_preview_flattens_markdown(self):
        text = "## Done\n\nI fixed **the test** in `checkout.spec.ts`. See [the PR](https://x/1).\n\n```sh\nnpm test\n```\nMEDIA:/tmp/a.png"
        self.assertEqual(payloads.preview(text), "Done I fixed the test in checkout.spec.ts. See the PR.")
        long = "word " * 100
        cut = payloads.preview(long, 40)
        self.assertLessEqual(len(cut), 40)
        self.assertTrue(cut.endswith("…"))

    def test_step_text_keeps_commands_off_the_lock_screen(self):
        self.assertEqual(payloads.step_text({"name": "terminal", "args": {"command": "export TOKEN=secret"}}),
                         "Running a command")
        self.assertEqual(payloads.step_text({"name": "patch", "args": {"path": "/Users/me/app/ChatView.swift"}}),
                         "Editing a file: ChatView.swift")
        self.assertEqual(payloads.step_text({"name": "mcp__linear__save_issue"}), "Using linear save issue")

    def test_alert_carries_the_activity_state_and_wakes_the_app(self):
        state = payloads.content_state(phase="done", started_at=100, ended_at=160, title="Fix it", summary="All good.")
        alert = payloads.finished_alert(bot="Ada", title="Fix it", text="All good.", status="complete",
                                        session_id="s", profile="ada", state=state)
        self.assertEqual(alert["aps"]["content-available"], 1)
        self.assertEqual(alert["talaria"]["state"]["phase"], "done")
        plain = payloads.finished_alert(bot="Ada", title="Fix it", text="All good.", status="complete",
                                        session_id="s", profile="ada")
        self.assertNotIn("content-available", plain["aps"])
        self.assertNotIn("state", plain["talaria"])

    def test_finished_alert_titles(self):
        def title(status):
            return payloads.finished_alert(bot="Ada", title="Fix it", text="All good.", status=status,
                                           session_id="s", profile="ada")["aps"]["alert"]["title"]
        self.assertEqual(title("complete"), "Ada finished")
        self.assertEqual(title("error"), "Ada hit an error")
        self.assertEqual(title("interrupted"), "Ada stopped")
        alert = payloads.finished_alert(bot="Ada", title="", text="", status="complete", session_id="s", profile="ada")
        self.assertEqual(alert["aps"]["alert"], {"title": "Ada finished", "body": "The reply is ready.", "subtitle": "New chat"})
        self.assertEqual(alert["talaria"], {"kind": "finished", "profile": "ada", "session_id": "s"})

    def test_activity_start_matches_the_swift_attributes(self):
        state = payloads.content_state(phase="working", started_at=100.25)
        start = payloads.activity_start(now=200, profile="ada", session_id="s1", bot="Ada", title=None, state=state)
        aps = start["aps"]
        self.assertEqual(aps["event"], "start")
        self.assertEqual(aps["attributes-type"], "ChatActivityAttributes")
        self.assertEqual(set(aps["attributes"]), {"profile", "sessionID", "botName", "chatTitle"})
        self.assertEqual(aps["content-state"], {"phase": "working", "startedAt": 100.25})
        self.assertEqual(aps["input-push-token"], 1)
        self.assertIn("alert", aps)
        end = payloads.activity_end(now=300, state=state)["aps"]
        self.assertEqual(end["dismissal-date"], 300 + payloads.DISMISS_AFTER)

    def test_collapse_id_fits(self):
        self.assertLessEqual(len(payloads.collapse_id("local-" + "f" * 64)), 64)

    def test_bot_names(self):
        self.assertEqual(payloads.bot_name("default"), "Hermes")
        self.assertEqual(payloads.bot_name("ada", {"ada": "Ada"}), "Ada")
        self.assertEqual(payloads.bot_name("scout", {}), "scout")


def row(sid, status, source="gui", title=""):
    return {"id": sid, "status": status, "source": source, "title": title}


class TrackerTests(unittest.TestCase):
    def test_a_turn_from_start_to_finish(self):
        tracker = Tracker()
        kinds = lambda changes: [c.kind for c in changes]  # noqa: E731
        self.assertEqual(kinds(tracker.observe("ada", [row("a", "starting")], 1)), [])
        self.assertEqual(kinds(tracker.observe("ada", [row("a", "working")], 2)), ["started"])
        self.assertEqual(tracker.turns["a"].started_at, 2)
        self.assertEqual(kinds(tracker.observe("ada", [row("a", "working", title="Fix it")], 3)), [])
        self.assertEqual(tracker.turns["a"].title, "Fix it")
        self.assertEqual(kinds(tracker.event("a", "tool.start", {"name": "terminal"})), ["step"])
        self.assertEqual(kinds(tracker.event("a", "tool.start", {"name": "terminal"})), [])
        self.assertEqual(kinds(tracker.observe("ada", [row("a", "waiting")], 4)), ["waiting"])
        self.assertEqual(kinds(tracker.observe("ada", [row("a", "working")], 5)), ["resumed"])
        # The next queued message: still busy.
        self.assertEqual(kinds(tracker.observe("ada", [row("a", "starting")], 6)), [])
        tracker.event("a", "message.complete", {"text": "Done.", "status": "complete"})
        changes = tracker.observe("ada", [row("a", "idle")], 7)
        self.assertEqual(kinds(changes), ["finished"])
        turn = changes[0].turn
        self.assertEqual((turn.final_text, turn.phase, turn.ended_at), ("Done.", "done", 7))
        self.assertEqual(turn.state()["summary"], "Done.")
        self.assertIn("a", tracker.finished)

    def test_questions_from_events(self):
        tracker = Tracker()
        tracker.observe("ada", [row("a", "working")], 1)
        changes = tracker.event("a", "clarify.request", {"question": "Continue?", "choices": ["yes", "no"]})
        self.assertEqual([c.kind for c in changes], ["waiting"])
        self.assertEqual(tracker.turns["a"].state(), {"phase": "waiting", "startedAt": 1, "step": "Continue?"})
        # The poll agrees: no second change.
        self.assertEqual(tracker.observe("ada", [row("a", "waiting")], 2), [])
        self.assertEqual([c.kind for c in tracker.event("a", "clarify.settled", {})], ["resumed"])

    def test_vanished_and_failed_and_ignored(self):
        tracker = Tracker()
        tracker.observe("ada", [row("a", "working"), row("s", "working", source="slack"),
                                 row("c", "working", source="cron")], 1)
        self.assertEqual(set(tracker.turns), {"a"})
        tracker.event("a", "message.complete", {"text": "", "status": "error"})
        changes = tracker.observe("ada", [], 2)
        self.assertEqual(changes[0].turn.phase, "failed")
        # Another bot's poll does not end this bot's turns.
        tracker.observe("ada", [row("b", "working")], 3)
        self.assertEqual(tracker.observe("scout", [], 4), [])
        self.assertIn("b", tracker.turns)

    def test_open_prompts_on_follow(self):
        tracker = Tracker()
        tracker.observe("ada", [row("a", "working")], 1)
        changes = tracker.adopt_prompts("a", [{"kind": "approval", "description": "Delete the build folder"}])
        self.assertEqual([c.kind for c in changes], ["waiting"])
        self.assertEqual(tracker.turns["a"].question, "Delete the build folder")


class StoreTests(unittest.TestCase):
    def test_round_trip_and_follow_ttl(self):
        with tempfile.TemporaryDirectory() as folder:
            clock = Clock()
            store = Store(Path(folder) / "state.json", clock=clock)
            store.upsert_device({"device_id": "d1", "token": "ab" * 32, "topic": "t.t", "alerts": True})
            store.set_activity("d1", "s1", "ada", "cd" * 32)
            store.follow("d1", "s1")
            again = Store(Path(folder) / "state.json", clock=clock)
            self.assertEqual(again.device("d1")["token"], "ab" * 32)
            self.assertEqual(again.activity("d1", "s1")["token"], "cd" * 32)
            self.assertTrue(again.follows("d1", "s1"))
            clock.now += FOLLOW_TTL + 1
            self.assertFalse(again.follows("d1", "s1"))
            self.assertEqual(oct(os.stat(Path(folder) / "state.json").st_mode & 0o777), "0o600")
            store.upsert_device({"device_id": "d1", "token": None, "alerts": False})
            self.assertEqual(again.device("d1")["token"], "ab" * 32)  # None leaves a field alone
            self.assertFalse(again.device("d1")["alerts"])
            self.assertTrue(again.remove_device("d1"))
            self.assertIsNone(store.device("d1"))


class NotifierTests(unittest.TestCase):
    def setUp(self):
        self.folder = tempfile.TemporaryDirectory()
        self.clock = Clock()
        self.store = Store(Path(self.folder.name) / "state.json", clock=self.clock)
        self.apns = FakeAPNs()
        self.notifier = Notifier(self.store, self.apns, clock=self.clock)
        self.tracker = Tracker()
        self.device = {"device_id": "d1", "name": "iPhone", "token": "11" * 32, "push_to_start_token": "22" * 32,
                       "environment": "development", "topic": "com.example.talaria", "team_id": "TEAM123456",
                       "alerts": True, "live_activities": True, "scope": "all", "bots": {"ada": "Ada"}}
        self.store.upsert_device(self.device)

    def tearDown(self):
        self.folder.cleanup()

    def feed(self, changes):
        for change in changes:
            self.notifier.handle(change)

    def test_whole_turn(self):
        self.feed(self.tracker.observe("ada", [row("s1", "working", title="Fix it")], self.clock.now))
        self.notifier.flush()
        self.assertEqual(self.apns.sent, [])  # a quick reply needs no Live Activity
        self.clock.now += START_AFTER
        self.notifier.flush()
        start = self.apns.sent[-1]
        self.assertEqual(start["token"], "22" * 32)
        self.assertEqual(start["topic"], "com.example.talaria.push-type.liveactivity")
        self.assertEqual(start["push_type"], "liveactivity")
        self.assertEqual(start["payload"]["aps"]["attributes"]["botName"], "Ada")

        # No activity token yet: steps have nowhere to go.
        self.feed(self.tracker.event("s1", "tool.start", {"name": "read_file", "args": {"path": "/a/b.py"}}))
        self.assertEqual(len(self.apns.sent), 1)

        # The phone registers the new activity's token: it is brought up to date at once.
        self.store.set_activity("d1", "s1", "ada", "33" * 32)
        self.notifier.activity_registered("d1", self.tracker.turns["s1"])
        update = self.apns.sent[-1]
        self.assertEqual(update["token"], "33" * 32)
        self.assertEqual(update["payload"]["aps"]["content-state"]["step"], "Reading a file: b.py")

        # Steps are throttled; the held one goes out once the wait is over.
        self.clock.now += 1
        self.feed(self.tracker.event("s1", "tool.start", {"name": "terminal"}))
        self.assertEqual(len(self.apns.sent), 2)
        self.clock.now += STEP_INTERVAL
        self.notifier.flush()
        self.assertEqual(self.apns.sent[-1]["payload"]["aps"]["content-state"]["step"], "Running a command")
        self.assertEqual(self.apns.sent[-1]["priority"], 5)

        # A question: an alert, and the activity says so at once.
        self.feed(self.tracker.event("s1", "clarify.request", {"question": "Open the PR?"}))
        alert, activity = self.apns.sent[-2:]
        self.assertEqual(alert["push_type"], "alert")
        self.assertEqual(alert["payload"]["aps"]["alert"]["title"], "Ada needs you")
        self.assertEqual(alert["payload"]["aps"]["alert"]["body"], "Open the PR?")
        self.assertEqual(activity["payload"]["aps"]["content-state"]["phase"], "waiting")
        self.assertEqual(activity["priority"], 10)

        # Finished: an alert with the answer, and the activity ends.
        self.feed(self.tracker.event("s1", "clarify.settled", {}))
        self.tracker.event("s1", "message.complete", {"text": "PR is up: **#42**", "status": "complete"})
        self.clock.now += 30
        self.feed(self.tracker.observe("ada", [row("s1", "idle", title="Fix it")], self.clock.now))
        alert, end = self.apns.sent[-2:]
        self.assertEqual(alert["payload"]["aps"]["alert"], {"title": "Ada finished", "subtitle": "Fix it",
                                                           "body": "PR is up: #42"})
        self.assertEqual(alert["collapse_id"], payloads.collapse_id("s1"))
        self.assertEqual(end["payload"]["aps"]["event"], "end")
        self.assertEqual(end["payload"]["aps"]["content-state"]["phase"], "done")
        self.assertIsNone(self.store.activity("d1", "s1"))

    def test_quick_replies_start_no_activity_and_questions_start_one_at_once(self):
        self.feed(self.tracker.observe("ada", [row("s1", "working")], self.clock.now))
        self.clock.now += 5
        self.feed(self.tracker.observe("ada", [], self.clock.now))
        self.clock.now += START_AFTER
        self.notifier.flush()
        self.assertEqual([s["push_type"] for s in self.apns.sent], ["alert"])  # finished, no activity
        self.feed(self.tracker.observe("ada", [row("s2", "working")], self.clock.now))
        self.feed(self.tracker.event("s2", "clarify.request", {"question": "Go?"}))
        self.assertEqual([s["push_type"] for s in self.apns.sent[1:]], ["alert", "liveactivity"])
        self.assertEqual(self.apns.sent[-1]["payload"]["aps"]["event"], "start")
        self.clock.now += START_AFTER
        self.notifier.flush()
        self.assertEqual(len(self.apns.sent), 3)  # not started twice

    def test_token_after_the_end_ends_the_activity(self):
        self.feed(self.tracker.observe("ada", [row("s1", "working")], 1))
        self.feed(self.tracker.observe("ada", [], 2))
        sent = len(self.apns.sent)
        self.store.set_activity("d1", "s1", "ada", "33" * 32)
        self.notifier.activity_registered("d1", self.tracker.finished["s1"])
        self.assertEqual(len(self.apns.sent), sent + 1)
        self.assertEqual(self.apns.sent[-1]["payload"]["aps"]["event"], "end")

    def test_settings_scope_and_dead_tokens(self):
        self.store.upsert_device({"device_id": "d1", "scope": "phone", "live_activities": False})
        self.feed(self.tracker.observe("ada", [row("s1", "working")], 1))
        self.feed(self.tracker.observe("ada", [], 2))
        self.assertEqual(self.apns.sent, [])  # not sent from this phone
        self.store.follow("d1", "s2")
        self.feed(self.tracker.observe("ada", [row("s2", "working")], 3))
        self.assertEqual(self.apns.sent, [])  # live activities off
        self.apns.answers["11" * 32] = Result(410, "Unregistered")
        self.feed(self.tracker.observe("ada", [], 4))
        self.assertEqual([s["push_type"] for s in self.apns.sent], ["alert"])
        self.assertNotIn("token", self.store.device("d1"))

    def test_alerts_off(self):
        self.store.upsert_device({"device_id": "d1", "alerts": False, "push_to_start_token": None})
        self.store.forget_token("d1", "push_to_start_token")
        self.feed(self.tracker.observe("ada", [row("s1", "working")], 1))
        self.feed(self.tracker.observe("ada", [], 2))
        self.assertEqual(self.apns.sent, [])


class RouteTests(unittest.TestCase):
    """The routes as Hermes mounts them: plugin_api.py loaded by path, its router on an app."""

    def test_register_and_status(self):
        from fastapi import FastAPI
        from fastapi.testclient import TestClient

        with tempfile.TemporaryDirectory() as folder:
            os.environ["TALARIA_PUSH_HOME"] = folder
            os.environ["TALARIA_PUSH_NO_WATCH"] = "1"
            spec = importlib.util.spec_from_file_location("hermes_dashboard_plugin_talaria_push",
                                                          DASHBOARD / "plugin_api.py")
            module = importlib.util.module_from_spec(spec)
            sys.modules[spec.name] = module
            spec.loader.exec_module(module)
            app = FastAPI()
            app.include_router(module.router, prefix="/api/plugins/talaria-push")
            client = TestClient(app)
            device = {"device_id": "ABC-123", "name": "iPhone", "token": "AB" * 32, "environment": "development",
                      "topic": "com.example.talaria", "alerts": True, "live_activities": True, "scope": "all",
                      "bots": {"ada": "Ada"}}
            answer = client.post("/api/plugins/talaria-push/devices", json=device)
            self.assertEqual(answer.status_code, 200, answer.text)
            self.assertEqual(answer.json(), {"ok": True, "apns_configured": False})
            self.assertEqual(client.post("/api/plugins/talaria-push/devices",
                                         json={**device, "token": "not-hex"}).status_code, 422)
            self.assertEqual(client.post("/api/plugins/talaria-push/activities",
                                         json={"device_id": "nobody", "session_id": "s", "token": "cd" * 32}).status_code, 404)
            self.assertEqual(client.post("/api/plugins/talaria-push/activities",
                                         json={"device_id": "ABC-123", "session_id": "s", "profile": "ada",
                                               "token": "cd" * 32}).status_code, 200)
            status = client.get("/api/plugins/talaria-push/status").json()
            self.assertEqual(status["devices"][0]["name"], "iPhone")
            self.assertTrue(status["devices"][0]["has_token"])
            self.assertFalse(status["apns"]["configured"])
            self.assertEqual(client.post("/api/plugins/talaria-push/test", json={"device_id": "ABC-123"}).status_code, 409)
            stored = json.loads((Path(folder) / "state.json").read_text())
            self.assertEqual(stored["devices"]["ABC-123"]["token"], "ab" * 32)
            self.assertEqual(client.delete("/api/plugins/talaria-push/devices/ABC-123").json()["removed"], True)


if __name__ == "__main__":
    unittest.main()
