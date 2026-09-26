"""Assign ASR words to diarization speakers and merge them into speaker turns."""

from __future__ import annotations

import bisect

from minutes_engine.transcript import Segment, Turn, Word

NEAREST_SEGMENT_MAX_GAP = 1.0
TURN_SPLIT_PAUSE = 3.0


class _SegmentIndex:
    def __init__(self, segments: list[Segment]):
        self.segments = sorted((s for s in segments if s.end > s.start), key=lambda s: s.start)
        self.starts = [s.start for s in self.segments]
        self.max_len = max((s.end - s.start for s in self.segments), default=0.0)

    def overlapping(self, start: float, end: float) -> list[Segment]:
        hi = bisect.bisect_left(self.starts, end)
        lo = bisect.bisect_left(self.starts, start - self.max_len)
        return [s for s in self.segments[lo:hi] if s.end > start]

    def nearest(self, t: float, max_gap: float) -> Segment | None:
        i = bisect.bisect_left(self.starts, t)
        best, best_d = None, max_gap
        for s in self.segments[max(0, i - 50): i + 50]:
            d = 0.0 if s.start <= t <= s.end else min(abs(t - s.start), abs(t - s.end))
            if d <= best_d:
                best, best_d = s, d
        return best


def assign_speakers(words: list[Word], segments: list[Segment]) -> list[int]:
    """Speaker with the most overlap per word; else nearest segment within 1 s; else the previous speaker."""
    if not segments:
        return [0] * len(words)
    index = _SegmentIndex(segments)
    out: list[int] = []
    prev: int | None = None
    for w in words:
        start, end = w.start, max(w.end, w.start + 1e-3)
        overlap: dict[int, float] = {}
        for s in index.overlapping(start, end):
            overlap[s.speaker] = overlap.get(s.speaker, 0.0) + min(end, s.end) - max(start, s.start)
        if overlap:
            spk = max(overlap.items(), key=lambda kv: (kv[1], kv[0] == prev))[0]
        else:
            near = index.nearest((start + end) / 2, NEAREST_SEGMENT_MAX_GAP)
            spk = near.speaker if near else (prev if prev is not None else index.segments[0].speaker)
        out.append(spk)
        prev = spk
    return out


def build_turns(words: list[Word], speakers: list[int], pause: float = TURN_SPLIT_PAUSE) -> list[Turn]:
    turns: list[Turn] = []
    for w, spk in zip(words, speakers):
        cur = turns[-1] if turns else None
        if cur is None or cur.speaker != spk or w.start - cur.end > pause:
            turns.append(Turn(spk, w.start, w.end, [w]))
        else:
            cur.words.append(w)
            cur.end = max(cur.end, w.end)
    return turns


def renumber_by_first_appearance(turns: list[Turn]) -> list[Turn]:
    """Speaker ids become 0..k-1 in order of first speech, dropping diarizer slots that got no words."""
    mapping: dict[int, int] = {}
    for t in turns:
        if t.speaker not in mapping:
            mapping[t.speaker] = len(mapping)
        t.speaker = mapping[t.speaker]
    return turns


def align(words: list[Word], segments: list[Segment]) -> list[Turn]:
    return renumber_by_first_appearance(build_turns(words, assign_speakers(words, segments)))
