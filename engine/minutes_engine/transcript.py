"""Transcript data types shared by ASR, alignment, notes and the HTTP API (no MLX imports)."""

from __future__ import annotations

from dataclasses import asdict, dataclass, field


@dataclass
class Word:
    text: str
    start: float
    end: float
    confidence: float = 1.0

    def to_dict(self) -> dict:
        return asdict(self)


@dataclass
class Segment:
    speaker: int
    start: float
    end: float


@dataclass
class Turn:
    speaker: int
    start: float
    end: float
    words: list[Word] = field(default_factory=list)

    @property
    def text(self) -> str:
        return " ".join(w.text for w in self.words)

    def to_dict(self) -> dict:
        return {
            "speaker": self.speaker,
            "start": self.start,
            "end": self.end,
            "text": self.text,
            "words": [w.to_dict() for w in self.words],
        }


def speaker_label(speaker: int, names: dict[int, str] | None = None) -> str:
    if names and names.get(speaker):
        return names[speaker]
    return f"Speaker {speaker + 1}"


def clock(seconds: float) -> str:
    s = int(seconds)
    h, rem = divmod(s, 3600)
    m, sec = divmod(rem, 60)
    return f"{h}:{m:02d}:{sec:02d}" if h else f"{m:02d}:{sec:02d}"


def turns_to_text(turns: list[Turn], names: dict[int, str] | None = None) -> str:
    return "\n".join(f"[{clock(t.start)}] {speaker_label(t.speaker, names)}: {t.text}" for t in turns)
