"""HTTP sidecar for the Mac app. Long jobs stream Server-Sent Events: {"type": "progress"|"stage"|"token"|"done"|"error"}."""

from __future__ import annotations

import asyncio
import json
import logging
import threading
import time
from pathlib import Path
from typing import Any, Callable

from fastapi import Depends, FastAPI, Header, HTTPException
from pydantic import BaseModel, Field
from sse_starlette.sse import EventSourceResponse

from minutes_engine import __version__
from minutes_engine.align import align
from minutes_engine.runtime import Engine, fetch_models
from minutes_engine.transcript import Segment, Turn, Word

log = logging.getLogger("minutes_engine.server")


class Cancelled(Exception):
    pass


class WordIn(BaseModel):
    text: str
    start: float
    end: float
    confidence: float = 1.0


class SegmentIn(BaseModel):
    speaker: int
    start: float
    end: float


class TurnIn(BaseModel):
    speaker: int
    start: float
    end: float
    words: list[WordIn] = Field(default_factory=list)


class TranscribeRequest(BaseModel):
    audio_path: str


class AlignRequest(BaseModel):
    words: list[WordIn]
    segments: list[SegmentIn] = Field(default_factory=list)


class NotesRequest(BaseModel):
    turns: list[TurnIn]
    speaker_names: dict[int, str] = Field(default_factory=dict)


class SelectProfileRequest(BaseModel):
    name: str


def _turns(items: list[TurnIn]) -> list[Turn]:
    return [Turn(t.speaker, t.start, t.end, [Word(**w.model_dump()) for w in t.words]) for t in items]


def stream_job(engine: Engine, job: Callable[[Callable[[dict], None]], dict]) -> EventSourceResponse:
    """Run `job(emit)` on a worker thread holding the engine lock; relay its events as SSE.

    The job's return value is sent as the final {"type": "done", ...} event. If the client disconnects,
    the next emit() raises Cancelled inside the worker so GPU work stops early.
    """
    loop = asyncio.get_running_loop()
    queue: asyncio.Queue[dict | None] = asyncio.Queue()
    cancelled = threading.Event()

    def emit(event: dict) -> None:
        if cancelled.is_set():
            raise Cancelled()
        loop.call_soon_threadsafe(queue.put_nowait, event)

    def worker() -> None:
        try:
            with engine.lock:
                result = job(emit)
            loop.call_soon_threadsafe(queue.put_nowait, {"type": "done", **result})
        except Cancelled:
            log.info("job cancelled by client")
        except Exception as exc:  # noqa: BLE001
            log.exception("job failed")
            loop.call_soon_threadsafe(queue.put_nowait, {"type": "error", "message": f"{type(exc).__name__}: {exc}"})
        finally:
            loop.call_soon_threadsafe(queue.put_nowait, None)

    async def events():
        threading.Thread(target=worker, daemon=True).start()
        try:
            while True:
                ev = await queue.get()
                if ev is None:
                    break
                yield {"data": json.dumps(ev)}
        finally:
            cancelled.set()

    return EventSourceResponse(events(), ping=15)


def create_app(engine: Engine, token: str | None = None) -> FastAPI:
    app = FastAPI(title="Minutes engine", version=__version__)

    def auth(authorization: str | None = Header(default=None)) -> None:
        if token and authorization != f"Bearer {token}":
            raise HTTPException(status_code=401, detail="bad or missing bearer token")

    deps = [Depends(auth)]

    @app.get("/health", dependencies=deps)
    def health() -> dict[str, Any]:
        return {"status": "ok", "version": __version__, **engine.status()}

    @app.get("/profiles", dependencies=deps)
    def profiles() -> dict[str, Any]:
        return {"active": engine.profile.name,
                "profiles": [p.model_dump() for p in engine.profiles().values()]}

    @app.post("/profiles/select", dependencies=deps)
    def select_profile(req: SelectProfileRequest) -> dict[str, Any]:
        try:
            p = engine.set_profile(req.name)
        except KeyError as exc:
            raise HTTPException(status_code=404, detail=str(exc)) from exc
        return {"active": p.name, "profile": p.model_dump()}

    @app.post("/reload", dependencies=deps)
    def reload() -> dict[str, Any]:
        engine.reload()
        return {"status": "reloaded", "active": engine.profile.name}

    @app.post("/fetch", dependencies=deps)
    async def fetch():
        def job(emit):
            paths = fetch_models(engine.profile, progress=lambda repo: emit({"type": "stage", "stage": "fetch",
                                                                              "repo": repo}))
            emit({"type": "stage", "stage": "load_asr"})
            engine.asr
            emit({"type": "stage", "stage": "load_llm"})
            engine.llm
            return {"paths": paths, "llm_info": engine.llm.info}

        return stream_job(engine, job)

    @app.post("/transcribe", dependencies=deps)
    async def transcribe(req: TranscribeRequest):
        path = Path(req.audio_path).expanduser()
        if not path.is_file():
            raise HTTPException(status_code=404, detail=f"no such file: {path}")

        def job(emit):
            emit({"type": "stage", "stage": "load_asr"})
            asr = engine.asr
            t0 = time.perf_counter()
            emit({"type": "stage", "stage": "transcribe"})
            words = asr.transcribe(path, progress=lambda p: emit({"type": "progress", "value": round(p, 4)}))
            return {"words": [w.to_dict() for w in words], "elapsed": round(time.perf_counter() - t0, 3),
                    "model": asr.model_id}

        return stream_job(engine, job)

    @app.post("/align", dependencies=deps)
    def align_words(req: AlignRequest) -> dict[str, Any]:
        words = [Word(**w.model_dump()) for w in req.words]
        segs = [Segment(s.speaker, s.start, s.end) for s in req.segments]
        return {"turns": [t.to_dict() for t in align(words, segs)]}

    @app.post("/notes", dependencies=deps)
    async def notes(req: NotesRequest):
        turns = _turns(req.turns)

        def job(emit):
            emit({"type": "stage", "stage": "load_llm"})
            llm = engine.notes_llm()
            t0 = time.perf_counter()
            result: dict[str, Any] = {}
            for ev in llm.notes(turns, req.speaker_names):
                if ev["type"] == "done":
                    result = {k: v for k, v in ev.items() if k != "type"}
                else:
                    emit(ev)
            return {**result, "elapsed": round(time.perf_counter() - t0, 3), "llm_info": engine.llm.info}

        return stream_job(engine, job)

    return app
