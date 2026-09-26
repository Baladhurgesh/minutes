"""HTTP API tests with a fake engine (no models, no Metal)."""

import json
import threading

import pytest
from fastapi.testclient import TestClient

from minutes_engine.profiles import ModelProfile
from minutes_engine.server import create_app
from minutes_engine.transcript import Word


class FakeASR:
    model_id = "fake-asr"

    def transcribe(self, path, progress=None):
        for p in (0.5, 1.0):
            progress(p)
        return [Word("hello", 0.0, 0.4), Word("world", 0.5, 0.9)]


class FakeNotes:
    def notes(self, turns, names=None):
        yield {"type": "stage", "stage": "final", "index": 1, "total": 1}
        yield {"type": "token", "text": "# Hi"}
        who = names.get(turns[0].speaker, "?") if names else "?"
        yield {"type": "done", "title": "Hi", "markdown": f"# Hi\n{who}: {turns[0].text}\n"}


class FakeEngine:
    def __init__(self):
        self.lock = threading.RLock()
        self.profile = ModelProfile(name="default")
        self.asr = FakeASR()

    def status(self):
        return {"profile": self.profile.model_dump(), "asr_loaded": True, "llm_loaded": False, "llm_info": None}

    def profiles(self):
        return {"default": self.profile, "other": ModelProfile(name="other")}

    def set_profile(self, name):
        if name not in self.profiles():
            raise KeyError(name)
        self.profile = self.profiles()[name]
        return self.profile

    def notes_llm(self):
        return FakeNotes()

    @property
    def llm(self):
        return type("L", (), {"info": {"model": "fake-llm"}})()


def sse_events(resp):
    return [json.loads(line[5:].strip()) for line in resp.text.splitlines() if line.startswith("data:")]


@pytest.fixture
def client():
    return TestClient(create_app(FakeEngine(), token="secret"), headers={"Authorization": "Bearer secret"})


def test_auth_required():
    c = TestClient(create_app(FakeEngine(), token="secret"))
    assert c.get("/health").status_code == 401
    assert c.get("/health", headers={"Authorization": "Bearer secret"}).status_code == 200


def test_profiles_and_select(client):
    assert {p["name"] for p in client.get("/profiles").json()["profiles"]} == {"default", "other"}
    assert client.post("/profiles/select", json={"name": "other"}).json()["active"] == "other"
    assert client.post("/profiles/select", json={"name": "nope"}).status_code == 404


def test_transcribe_streams_progress_then_words(client, tmp_path):
    wav = tmp_path / "a.wav"
    wav.write_bytes(b"RIFF")
    events = sse_events(client.post("/transcribe", json={"audio_path": str(wav)}))
    assert [e["value"] for e in events if e["type"] == "progress"] == [0.5, 1.0]
    done = events[-1]
    assert done["type"] == "done" and [w["text"] for w in done["words"]] == ["hello", "world"]
    assert client.post("/transcribe", json={"audio_path": str(tmp_path / "missing.wav")}).status_code == 404


def test_align_and_notes(client):
    words = [{"text": "hello", "start": 0.0, "end": 0.4}, {"text": "world", "start": 0.5, "end": 0.9}]
    turns = client.post("/align", json={"words": words, "segments": [{"speaker": 3, "start": 0, "end": 1}]}).json()
    assert turns["turns"][0]["speaker"] == 0 and turns["turns"][0]["text"] == "hello world"
    events = sse_events(client.post("/notes", json={"turns": turns["turns"], "speaker_names": {"0": "Ana"}}))
    assert [e["type"] for e in events] == ["stage", "stage", "token", "done"]
    assert events[-1]["markdown"] == "# Hi\nAna: hello world\n"
