from minutes_engine.align import align, assign_speakers, build_turns
from minutes_engine.transcript import Segment, Word, clock, turns_to_text


def w(text, start, end):
    return Word(text, start, end)


def test_no_segments_is_single_speaker():
    words = [w("hi", 0.0, 0.3), w("there", 0.4, 0.8)]
    turns = align(words, [])
    assert len(turns) == 1 and turns[0].speaker == 0 and turns[0].text == "hi there"


def test_max_overlap_wins():
    words = [w("a", 0.0, 1.0)]
    segs = [Segment(3, 0.0, 0.3), Segment(5, 0.2, 1.0)]
    assert assign_speakers(words, segs) == [5]


def test_overlap_accumulates_across_segments_of_same_speaker():
    words = [w("a", 0.0, 1.0)]
    segs = [Segment(1, 0.0, 0.3), Segment(1, 0.35, 0.65), Segment(2, 0.3, 0.7)]
    assert assign_speakers(words, segs) == [1]


def test_word_in_gap_uses_nearest_segment_within_1s():
    words = [w("a", 0.0, 0.5), w("b", 2.2, 2.4), w("c", 10.0, 10.2)]
    segs = [Segment(0, 0.0, 0.5), Segment(1, 2.5, 3.0)]
    # b is 0.1s from speaker 1's segment; c is far from everything -> previous speaker
    assert assign_speakers(words, segs) == [0, 1, 1]


def test_turns_split_on_speaker_change_and_long_pause():
    words = [w("a", 0, 0.5), w("b", 0.6, 1.0), w("c", 1.1, 1.5), w("d", 10.0, 10.5)]
    turns = build_turns(words, [7, 7, 2, 2])
    assert [(t.speaker, t.text) for t in turns] == [(7, "a b"), (2, "c"), (2, "d")]


def test_speakers_renumbered_by_first_appearance():
    words = [w("x", 0, 1), w("y", 2, 3), w("z", 4, 5)]
    segs = [Segment(4, 0, 1), Segment(1, 2, 3), Segment(4, 4, 5)]
    turns = align(words, segs)
    assert [t.speaker for t in turns] == [0, 1, 0]


def test_many_segments_are_fast_and_correct():
    words = [w(str(i), i + 0.1, i + 0.4) for i in range(5000)]
    segs = [Segment(i % 3, float(i), i + 0.9) for i in range(5000)]
    spk = assign_speakers(words, segs)
    assert spk[:6] == [0, 1, 2, 0, 1, 2]


def test_transcript_text_uses_names_and_clock():
    turns = align([w("hello", 65.0, 65.5)], [])
    assert turns_to_text(turns, {0: "Ana"}) == "[01:05] Ana: hello"
    assert clock(3725) == "1:02:05"
