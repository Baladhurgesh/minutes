#!/usr/bin/env python3
"""Synthesize a short multi-speaker meeting WAV with macOS `say` for end-to-end tests.

Usage: python3 scripts/make_sample_meeting.py [out.wav] [--voices Samantha,Daniel,Karen]
(default samples/standup.wav). --voices maps the three characters to other `say` voices.
"""

from __future__ import annotations

import subprocess
import sys
import tempfile
import wave
from pathlib import Path

RATE = 16000
SCRIPT = [
    ("Samantha", "Good morning everyone. Let's start the weekly planning meeting for the mobile app launch."),
    ("Daniel", "Thanks. The backend is ready. We finished the payment integration yesterday, "
               "but load testing is still pending."),
    ("Samantha", "Great. When can the load tests be done?"),
    ("Daniel", "I can finish the load tests by Thursday."),
    ("Karen", "On the design side, the onboarding screens are done. I still need feedback on the pricing page."),
    ("Samantha", "Okay. I will review the pricing page today and send comments to Karen by end of day."),
    ("Karen", "Perfect. One open question is whether we launch in Canada at the same time as the US."),
    ("Daniel", "Supporting Canada needs a second payment provider, so I would rather wait."),
    ("Samantha", "Agreed. We decided to launch in the US first on October fifteenth, and revisit Canada in November."),
    ("Karen", "Sounds good. I will also update the app store screenshots before the launch."),
    ("Samantha", "Thanks everyone. Daniel owns load testing, Karen owns screenshots, and I own the pricing review."),
]


def say_to_pcm(voice: str, text: str, tmp: Path, i: int) -> bytes:
    aiff, wav_path = tmp / f"{i}.aiff", tmp / f"{i}.wav"
    subprocess.run(["say", "-v", voice, "-o", str(aiff), text], check=True)
    subprocess.run(["afconvert", "-f", "WAVE", "-d", f"LEI16@{RATE}", "-c", "1", str(aiff), str(wav_path)], check=True)
    with wave.open(str(wav_path), "rb") as w:
        return w.readframes(w.getnframes())


def main() -> None:
    args = sys.argv[1:]
    voices = {"Samantha": "Samantha", "Daniel": "Daniel", "Karen": "Karen"}
    if "--voices" in args:
        i = args.index("--voices")
        voices = dict(zip(voices, args[i + 1].split(",")))
        del args[i: i + 2]
    out = Path(args[0] if args else Path(__file__).resolve().parents[1] / "samples" / "standup.wav")
    out.parent.mkdir(parents=True, exist_ok=True)
    gap = b"\x00\x00" * int(RATE * 0.6)
    with tempfile.TemporaryDirectory() as d:
        pcm = b"".join(say_to_pcm(voices[v], t, Path(d), i) + gap for i, (v, t) in enumerate(SCRIPT))
    with wave.open(str(out), "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(RATE)
        w.writeframes(pcm)
    print(f"wrote {out} ({len(pcm) / 2 / RATE:.1f}s, {len({v for v, _ in SCRIPT})} speakers)")


if __name__ == "__main__":
    main()
