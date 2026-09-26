"""Meeting notes with a small local LLM (Qwen3-0.6B via mlx-lm), map-reduce over the transcript."""

from __future__ import annotations

import re
from typing import Any, Callable, Iterator

from minutes_engine.transcript import Turn, clock, speaker_label

SYSTEM = (
    "You are a precise meeting note-taker. You only write facts that are stated in the transcript. "
    "You never invent names, numbers, dates or tasks. You write short, plain sentences."
)

MAP_TEMPLATE = """Here is part {index} of {total} of a meeting transcript.

<transcript>
{text}
</transcript>

Write notes for this part using exactly these four headings, each followed by short bullet points:

Key points:
- ...
Decisions:
- ...
Action items:
- <person>: <task>
Open questions:
- ...

Write "- None" under a heading when nothing applies."""

MERGE_TEMPLATE = """Here are notes from consecutive parts of one meeting.

<notes>
{text}
</notes>

Merge them into one set of notes with exactly these four headings: "Key points:", "Decisions:", \
"Action items:", "Open questions:". Remove duplicates. Keep every distinct action item and its person."""

FINAL_TEMPLATE = """{kind}

<{tag}>
{text}
</{tag}>

Write the final meeting notes in Markdown with exactly this structure:

# <meeting title, at most 8 words>

## Summary
<3 to 5 sentences describing what the meeting was about and what was concluded>

## Key points
- <point>

## Decisions
- <decision>

## Action items
- [ ] **<person>**: <task>

## Open questions
- <question>

Write "- None" under a section when nothing applies."""

THINK_RE = re.compile(r"<think>.*?</think>\s*", re.DOTALL)


def transcript_lines(turns: list[Turn], names: dict[int, str] | None = None) -> list[str]:
    return [f"[{clock(t.start)}] {speaker_label(t.speaker, names)}: {t.text}" for t in turns if t.words]


def pack(lines: list[str], count_tokens: Callable[[str], int], budget: int) -> list[str]:
    """Greedy-pack lines into chunks of at most `budget` tokens (a single oversized line is split on words)."""
    chunks: list[str] = []
    cur: list[str] = []
    cur_tokens = 0
    for line in lines:
        n = count_tokens(line)
        if n > budget:
            words = line.split()
            step = max(1, len(words) * budget // (n + 1))
            pieces = [" ".join(words[i: i + step]) for i in range(0, len(words), step)]
        else:
            pieces = [line]
        for piece in pieces:
            n = count_tokens(piece)
            if cur and cur_tokens + n > budget:
                chunks.append("\n".join(cur))
                cur, cur_tokens = [], 0
            cur.append(piece)
            cur_tokens += n
    if cur:
        chunks.append("\n".join(cur))
    return chunks


def clean_markdown(text: str) -> tuple[str, str]:
    """Strip reasoning blocks and code fences; guarantee a '# Title' first line. Returns (title, markdown)."""
    text = THINK_RE.sub("", text).strip()
    text = re.sub(r"^```(?:markdown|md)?\s*|\s*```$", "", text).strip()
    lines = text.splitlines()
    while lines and not lines[0].strip():
        lines.pop(0)
    if not lines or not lines[0].startswith("# "):
        lines.insert(0, "# Meeting notes")
    title = lines[0][2:].strip().strip("*<>") or "Meeting notes"
    lines[0] = f"# {title}"
    return title, "\n".join(lines).strip() + "\n"


class NotesLLM:
    def __init__(
        self,
        model: Any,
        tokenizer: Any,
        *,
        gen_kwargs: dict[str, Any] | None = None,
        chunk_tokens: int = 2000,
        merge_tokens: int = 3000,
        temperature: float = 0.2,
        top_p: float = 0.9,
        repetition_penalty: float = 1.05,
    ):
        self.model = model
        self.tokenizer = tokenizer
        self.gen_kwargs = dict(gen_kwargs or {})
        self.chunk_tokens = chunk_tokens
        self.merge_tokens = merge_tokens
        self.temperature = temperature
        self.top_p = top_p
        self.repetition_penalty = repetition_penalty

    def count_tokens(self, text: str) -> int:
        return len(self.tokenizer.encode(text))

    def _prompt(self, user: str) -> str:
        messages = [{"role": "system", "content": SYSTEM}, {"role": "user", "content": user}]
        try:
            return self.tokenizer.apply_chat_template(
                messages, add_generation_prompt=True, tokenize=False, enable_thinking=False
            )
        except TypeError:
            return self.tokenizer.apply_chat_template(messages, add_generation_prompt=True, tokenize=False)

    def stream(self, user: str, *, max_tokens: int) -> Iterator[str]:
        from mlx_lm import stream_generate
        from mlx_lm.sample_utils import make_logits_processors, make_sampler

        sampler = make_sampler(temp=self.temperature, top_p=self.top_p)
        processors = make_logits_processors(repetition_penalty=self.repetition_penalty)
        for resp in stream_generate(
            self.model, self.tokenizer, self._prompt(user), max_tokens=max_tokens,
            sampler=sampler, logits_processors=processors, **self.gen_kwargs,
        ):
            if resp.text:
                yield resp.text

    def generate(self, user: str, *, max_tokens: int) -> str:
        return THINK_RE.sub("", "".join(self.stream(user, max_tokens=max_tokens))).strip()

    def notes(self, turns: list[Turn], names: dict[int, str] | None = None) -> Iterator[dict[str, Any]]:
        """Yields {"type": "stage"|"token"|"done", ...} events; the final pass streams tokens."""
        lines = transcript_lines(turns, names)
        if not lines:
            md = "# Meeting notes\n\n## Summary\nNo speech was detected in this recording.\n"
            yield {"type": "done", "title": "Meeting notes", "markdown": md}
            return

        chunks = pack(lines, self.count_tokens, self.chunk_tokens)
        if len(chunks) == 1:
            final_input, kind, tag = chunks[0], "Here is a meeting transcript.", "transcript"
        else:
            partial: list[str] = []
            for i, chunk in enumerate(chunks, 1):
                yield {"type": "stage", "stage": "map", "index": i, "total": len(chunks)}
                partial.append(self.generate(
                    MAP_TEMPLATE.format(index=i, total=len(chunks), text=chunk), max_tokens=400
                ))
            level = 0
            while sum(self.count_tokens(p) for p in partial) > self.merge_tokens and len(partial) > 1:
                level += 1
                groups = pack(partial, self.count_tokens, self.merge_tokens)
                if len(groups) == len(partial):
                    groups = ["\n\n".join(partial[i: i + 2]) for i in range(0, len(partial), 2)]
                merged: list[str] = []
                for i, group in enumerate(groups, 1):
                    yield {"type": "stage", "stage": "merge", "level": level, "index": i, "total": len(groups)}
                    merged.append(self.generate(MERGE_TEMPLATE.format(text=group), max_tokens=600))
                partial = merged
            final_input = "\n\n".join(partial)
            kind, tag = "Here are notes taken during one meeting, in order.", "notes"

        yield {"type": "stage", "stage": "final", "index": 1, "total": 1}
        tokens: list[str] = []
        for text in self.stream(FINAL_TEMPLATE.format(kind=kind, tag=tag, text=final_input), max_tokens=900):
            tokens.append(text)
            yield {"type": "token", "text": text}
        title, md = clean_markdown("".join(tokens))
        yield {"type": "done", "title": title, "markdown": md}
