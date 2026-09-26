"""Parakeet TDT ASR via parakeet-mlx, returning word-level timestamps."""

from __future__ import annotations

from pathlib import Path
from typing import Callable

import mlx.core as mx

from minutes_engine.audio import load_wav
from minutes_engine.transcript import Word

DTYPES = {"bfloat16": mx.bfloat16, "float16": mx.float16, "float32": mx.float32}


def tokens_to_words(tokens) -> list[Word]:
    """Parakeet emits SentencePiece pieces; a piece starting with a space begins a new word."""
    words: list[Word] = []
    for t in tokens:
        text = t.text
        if not text:
            continue
        if words and not text.startswith(" "):
            w = words[-1]
            w.text += text
            w.end = max(w.end, t.end)
            w.confidence = min(w.confidence, t.confidence)
        else:
            stripped = text.strip()
            if stripped:
                words.append(Word(stripped, t.start, t.end, t.confidence))
    return words


class ParakeetASR:
    def __init__(
        self,
        model_id: str = "mlx-community/parakeet-tdt-0.6b-v3",
        *,
        dtype: str = "bfloat16",
        chunk_duration: float = 120.0,
        overlap_duration: float = 15.0,
    ):
        from parakeet_mlx import from_pretrained

        self.model_id = model_id
        self.dtype = DTYPES[dtype]
        self.chunk_duration = chunk_duration
        self.overlap_duration = overlap_duration
        self.model = from_pretrained(model_id, dtype=self.dtype)

    def transcribe(self, wav_path: str | Path, progress: Callable[[float], None] | None = None) -> list[Word]:
        """Same chunk/merge strategy as BaseParakeet.transcribe, but fed from an in-memory WAV."""
        from parakeet_mlx.parakeet import (
            DecodingConfig,
            get_logmel,
            merge_longest_common_subsequence,
            merge_longest_contiguous,
        )

        model = self.model
        cfg = model.preprocessor_config
        audio = mx.array(load_wav(wav_path, cfg.sample_rate))
        n = audio.shape[0]
        decoding = DecodingConfig()
        chunk = int(self.chunk_duration * cfg.sample_rate)
        overlap = int(self.overlap_duration * cfg.sample_rate)

        if n <= chunk:
            result = model.generate(get_logmel(audio, cfg), decoding_config=decoding)[0]
            if progress:
                progress(1.0)
            return tokens_to_words(result.tokens)

        all_tokens: list = []
        for start in range(0, n, chunk - overlap):
            end = min(start + chunk, n)
            if end - start < cfg.hop_length:
                break
            result = model.generate(get_logmel(audio[start:end], cfg), decoding_config=decoding)[0]
            offset = start / cfg.sample_rate
            tokens = result.tokens
            for t in tokens:
                t.start += offset
                t.end = t.start + t.duration
            if all_tokens:
                try:
                    all_tokens = merge_longest_contiguous(all_tokens, tokens, overlap_duration=self.overlap_duration)
                except RuntimeError:
                    all_tokens = merge_longest_common_subsequence(
                        all_tokens, tokens, overlap_duration=self.overlap_duration
                    )
            else:
                all_tokens = tokens
            if progress:
                progress(end / n)
            if end == n:
                break
        return tokens_to_words(all_tokens)
