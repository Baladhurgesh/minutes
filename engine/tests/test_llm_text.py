from minutes_engine.llm import clean_markdown, pack


def count(s: str) -> int:
    return len(s.split())


def test_pack_respects_budget_and_order():
    lines = [f"line {i} " + "w " * 5 for i in range(20)]
    chunks = pack(lines, count, budget=30)
    assert all(count(c) <= 30 for c in chunks)
    assert "\n".join(chunks).split("\n") == lines


def test_pack_splits_oversized_line():
    chunks = pack(["word " * 100], count, budget=30)
    assert len(chunks) >= 4 and all(count(c) <= 30 for c in chunks)


def test_clean_markdown_strips_think_and_fences():
    raw = "<think>hmm</think>\n```markdown\n# Budget review\n\n## Summary\nOk.\n```"
    title, md = clean_markdown(raw)
    assert title == "Budget review"
    assert md.startswith("# Budget review\n") and "think" not in md and "```" not in md


def test_clean_markdown_adds_title_when_missing():
    title, md = clean_markdown("## Summary\nStuff")
    assert title == "Meeting notes" and md.startswith("# Meeting notes\n## Summary")
