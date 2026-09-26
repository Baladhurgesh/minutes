"""Engine runtime: lazily loaded models for the active profile, shared by the CLI and the HTTP server."""

from __future__ import annotations

import gc
import os
import threading
from pathlib import Path
from typing import Any

from minutes_engine.profiles import LoadedLLM, ModelProfile, discover_profiles

REPO_PROFILES = Path(__file__).resolve().parents[2] / "profiles"
USER_PROFILES = Path("~/Library/Application Support/Minutes/profiles").expanduser()


def default_profile_dirs() -> list[Path]:
    dirs = [REPO_PROFILES, USER_PROFILES]
    extra = os.environ.get("MINUTES_PROFILES_DIRS")
    if extra:
        dirs += [Path(p) for p in extra.split(os.pathsep) if p]
    return dirs


class Engine:
    """Holds at most one ASR and one LLM model. MLX work is serialized with `lock` (one GPU)."""

    def __init__(self, profile_dirs: list[Path] | None = None, profile_name: str = "default"):
        self.profile_dirs = [Path(d) for d in (profile_dirs or default_profile_dirs())]
        self.lock = threading.RLock()
        self._asr: Any = None
        self._llm: LoadedLLM | None = None
        self.profile = self._resolve(profile_name)

    def profiles(self) -> dict[str, ModelProfile]:
        return discover_profiles(self.profile_dirs)

    def _resolve(self, name: str) -> ModelProfile:
        profiles = self.profiles()
        if name in profiles:
            return profiles[name]
        if Path(name).expanduser().is_file():
            from minutes_engine.profiles import load_profile

            return load_profile(name)
        if name == "default":
            return ModelProfile(name="default")
        raise KeyError(f"unknown profile {name!r}; have {sorted(profiles)}")

    def set_profile(self, name: str) -> ModelProfile:
        new = self._resolve(name)
        with self.lock:
            if new.asr != self.profile.asr:
                self._asr = None
            if new.llm != self.profile.llm or new.path != self.profile.path:
                self._unload_llm()
            self.profile = new
            gc.collect()
        return new

    def _unload_llm(self) -> None:
        if self._llm is not None:
            self._llm.unload()
            self._llm = None

    @property
    def asr(self):
        with self.lock:
            if self._asr is None:
                from minutes_engine.asr import ParakeetASR

                a = self.profile.asr
                self._asr = ParakeetASR(a.model, dtype=a.dtype, chunk_duration=a.chunk_duration,
                                        overlap_duration=a.overlap_duration)
            return self._asr

    @property
    def llm(self) -> LoadedLLM:
        with self.lock:
            if self._llm is None:
                from minutes_engine.profiles import load_llm

                self._llm = load_llm(self.profile)
            return self._llm

    def notes_llm(self):
        from minutes_engine.llm import NotesLLM

        loaded = self.llm
        return NotesLLM(loaded.model, loaded.tokenizer, gen_kwargs=loaded.gen_kwargs)

    def status(self) -> dict[str, Any]:
        return {
            "profile": self.profile.model_dump(),
            "asr_loaded": self._asr is not None,
            "llm_loaded": self._llm is not None,
            "llm_info": self._llm.info if self._llm else None,
        }

    def reload(self) -> None:
        with self.lock:
            self._asr = None
            self._unload_llm()
            self.profile = self._resolve(self.profile.path or self.profile.name)
            gc.collect()


def fetch_models(profile: ModelProfile, progress=None) -> list[str]:
    """Download the profile's Hugging Face models (no-op for local paths). Returns local snapshot paths."""
    from huggingface_hub import snapshot_download

    paths = []
    for repo in (profile.asr.model, profile.llm.model):
        if Path(repo).expanduser().exists():
            paths.append(str(Path(repo).expanduser()))
            continue
        if progress:
            progress(repo)
        paths.append(snapshot_download(repo, allow_patterns=["*.json", "*.safetensors", "*.txt", "*.model",
                                                             "*.tiktoken", "tokenizer*", "*.jinja"]))
    return paths
