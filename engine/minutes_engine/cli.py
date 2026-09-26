"""`minutes-engine` CLI: headless pipeline runs, profile listing, model fetch, and the HTTP sidecar."""

from __future__ import annotations

import json
import time
from pathlib import Path
from typing import Optional

import typer

app = typer.Typer(add_completion=False, no_args_is_help=True)


def load_segments(path: Path):
    from minutes_engine.transcript import Segment

    data = json.loads(path.read_text())
    items = data.get("segments", data) if isinstance(data, dict) else data
    return [Segment(int(s["speaker"]), float(s["start"]), float(s["end"])) for s in items]


@app.command()
def run(
    wav: Path = typer.Argument(..., exists=True, help="16 kHz mono PCM WAV (other rates are resampled)"),
    segments: Optional[Path] = typer.Option(None, exists=True, help="diarization JSON from minutes-cli diarize"),
    profile: str = typer.Option("default", help="profile name or path to a profile JSON"),
    out: Optional[Path] = typer.Option(None, help="output dir for transcript.json and notes.md"),
    notes: bool = typer.Option(True, help="generate meeting notes"),
):
    """Transcribe, align to speakers and write notes for one file."""
    from minutes_engine.align import align
    from minutes_engine.runtime import Engine
    from minutes_engine.transcript import turns_to_text

    engine = Engine(profile_name=profile)
    out = out or wav.parent / f"{wav.stem}.minutes"
    out.mkdir(parents=True, exist_ok=True)

    t0 = time.perf_counter()
    words = engine.asr.transcribe(wav, progress=lambda p: typer.echo(f"\r  asr {p:6.1%}", nl=False, err=True))
    typer.echo(f"\nASR: {len(words)} words in {time.perf_counter() - t0:.1f}s", err=True)

    segs = load_segments(segments) if segments else []
    turns = align(words, segs)
    transcript = {"profile": engine.profile.name, "turns": [t.to_dict() for t in turns]}
    (out / "transcript.json").write_text(json.dumps(transcript, indent=1))
    typer.echo(turns_to_text(turns)[:4000])

    if notes:
        t1 = time.perf_counter()
        md = ""
        for ev in engine.notes_llm().notes(turns):
            if ev["type"] == "stage":
                typer.echo(f"\n[notes {ev['stage']} {ev['index']}/{ev['total']}]", err=True)
            elif ev["type"] == "token":
                typer.echo(ev["text"], nl=False)
            elif ev["type"] == "done":
                md = ev["markdown"]
        (out / "notes.md").write_text(md)
        typer.echo(f"\nNotes in {time.perf_counter() - t1:.1f}s -> {out / 'notes.md'}", err=True)


@app.command()
def profiles():
    """List discovered model profiles."""
    from minutes_engine.runtime import Engine

    for name, p in Engine().profiles().items():
        typer.echo(f"{name:16} llm={p.llm.model} {json.dumps(p.llm.config)} kernels={sorted(p.llm.kernels)}  "
                   f"asr={p.asr.model}  diar={p.diarization.preset}  ({p.path})")


@app.command()
def fetch(profile: str = typer.Option("default", help="profile name or path")):
    """Download the profile's ASR and LLM weights into the Hugging Face cache."""
    from minutes_engine.runtime import Engine, fetch_models

    engine = Engine(profile_name=profile)
    for p in fetch_models(engine.profile, progress=lambda repo: typer.echo(f"fetching {repo} ...")):
        typer.echo(f"  ok {p}")


def _exit_when_orphaned(parent_pid: int) -> None:
    import os
    import threading

    def watch() -> None:
        while True:
            time.sleep(2)
            if os.getppid() != parent_pid:
                os._exit(0)

    threading.Thread(target=watch, daemon=True).start()


@app.command()
def serve(
    host: str = typer.Option("127.0.0.1"),
    port: int = typer.Option(8765, help="0 picks a free port"),
    token: Optional[str] = typer.Option(None, envvar="MINUTES_ENGINE_TOKEN", help="bearer token required on requests"),
    profile: str = typer.Option("default"),
    profiles_dir: list[Path] = typer.Option([], help="extra profile directories (repeatable)"),
    parent_pid: Optional[int] = typer.Option(None, help="exit when this parent process goes away"),
):
    """Run the HTTP sidecar used by the Mac app. Prints `MINUTES_ENGINE_READY port=<n>` once listening."""
    import socket
    import sys

    import uvicorn

    from minutes_engine.runtime import Engine, default_profile_dirs
    from minutes_engine.server import create_app

    if parent_pid:
        _exit_when_orphaned(parent_pid)
    engine = Engine(profile_dirs=default_profile_dirs() + list(profiles_dir), profile_name=profile)
    sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    sock.bind((host, port))
    sock.listen(64)
    print(f"MINUTES_ENGINE_READY port={sock.getsockname()[1]}", flush=True)
    sys.stdout.flush()
    uvicorn.Server(uvicorn.Config(create_app(engine, token=token), log_level="info")).run(sockets=[sock])


if __name__ == "__main__":
    app()
