"""Model profiles: which ASR / LLM / diarizer to run and how, including visai-optimized deployments.

`llm.config` uses visai's deploy-config keys (visai/deploy/mlx_search.py: validate, gen_kwargs) and the
same in-memory quantization predicate as visai/models/mlx_model.py:load, so the winning config from a
`visai optimize` run can be pasted into a profile unchanged. `llm.kernels` maps op -> promoted kernel
file and is applied with visai's MLXModulePatcher when visai is importable
(`uv pip install -e /path/to/visai` inside engine/).
"""

from __future__ import annotations

import json
import logging
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any, Literal

from pydantic import BaseModel, Field, field_validator

log = logging.getLogger("minutes_engine.profiles")

ALLOWED = {
    "bits": {None, 3, 4, 5, 6, 8},
    "group_size": {32, 64, 128},
    "kv_bits": {None, 4, 8},
    "kv_group_size": {32, 64},
}
CONFIG_KEYS = {"bits", "group_size", "keep_high", "kv_bits", "kv_group_size", "prefill_step_size", "kernels"}
KERNEL_OPS = {"rmsnorm", "add_rmsnorm", "swiglu"}


def validate_llm_config(config: dict[str, Any]) -> list[str]:
    errs = []
    for k in ("bits", "group_size", "kv_bits", "kv_group_size"):
        if k in config and config[k] not in ALLOWED[k]:
            errs.append(f"{k}={config[k]!r} not in {sorted(v for v in ALLOWED[k] if v is not None)} (or null)")
    if config.get("prefill_step_size") is not None and not 256 <= int(config["prefill_step_size"]) <= 4096:
        errs.append("prefill_step_size must be in [256, 4096]")
    if config.get("keep_high") and not isinstance(config["keep_high"], list):
        errs.append("keep_high must be a list of strings")
    unknown = set(config) - CONFIG_KEYS
    if unknown:
        errs.append(f"unknown keys: {sorted(unknown)}")
    return errs


def gen_kwargs(config: dict[str, Any]) -> dict[str, Any]:
    kw: dict[str, Any] = {}
    if config.get("kv_bits"):
        kw["kv_bits"] = int(config["kv_bits"])
        kw["kv_group_size"] = int(config.get("kv_group_size") or 64)
    if config.get("prefill_step_size"):
        kw["prefill_step_size"] = int(config["prefill_step_size"])
    return kw


class LLMSpec(BaseModel):
    model: str = "Qwen/Qwen3-0.6B"
    config: dict[str, Any] = Field(default_factory=dict)
    kernels: dict[str, str] = Field(default_factory=dict)

    @field_validator("config")
    @classmethod
    def _check_config(cls, v: dict[str, Any]) -> dict[str, Any]:
        errs = validate_llm_config(v)
        if errs:
            raise ValueError("; ".join(errs))
        return v

    @field_validator("kernels")
    @classmethod
    def _check_kernels(cls, v: dict[str, str]) -> dict[str, str]:
        unknown = set(v) - KERNEL_OPS
        if unknown:
            raise ValueError(f"no model integration for kernel ops {sorted(unknown)}; have {sorted(KERNEL_OPS)}")
        return v


class ASRSpec(BaseModel):
    model: str = "mlx-community/parakeet-tdt-0.6b-v3"
    dtype: Literal["bfloat16", "float16", "float32"] = "bfloat16"
    chunk_duration: float = 120.0
    overlap_duration: float = 15.0


class DiarizationSpec(BaseModel):
    backend: str = "fluidaudio-nemotron3"
    preset: str = "fast128"
    threshold: float = 0.5


class ModelProfile(BaseModel):
    name: str
    description: str = ""
    llm: LLMSpec = Field(default_factory=LLMSpec)
    asr: ASRSpec = Field(default_factory=ASRSpec)
    diarization: DiarizationSpec = Field(default_factory=DiarizationSpec)
    path: str | None = None

    @property
    def base_dir(self) -> Path:
        return Path(self.path).parent if self.path else Path.cwd()

    def kernel_paths(self) -> dict[str, Path]:
        out = {}
        for op, p in self.llm.kernels.items():
            path = Path(p).expanduser()
            out[op] = path if path.is_absolute() else (self.base_dir / path).resolve()
        return out


def load_profile(path: str | Path) -> ModelProfile:
    path = Path(path).expanduser().resolve()
    data = json.loads(path.read_text())
    data["path"] = str(path)
    data.setdefault("name", path.stem)
    return ModelProfile.model_validate(data)


def discover_profiles(dirs: list[str | Path]) -> dict[str, ModelProfile]:
    """Profiles from all dirs; a later dir overrides an earlier one with the same profile name."""
    found: dict[str, ModelProfile] = {}
    for d in dirs:
        d = Path(d).expanduser()
        if not d.is_dir():
            continue
        for f in sorted(d.glob("*.json")):
            try:
                p = load_profile(f)
            except Exception as exc:  # noqa: BLE001
                log.warning("skipping invalid profile %s: %s", f, exc)
                continue
            found[p.name] = p
    return found


def quantize_in_memory(model: Any, bits: int, group_size: int, keep_high: list[str] | None) -> None:
    import mlx.core as mx
    import mlx.nn as nn

    keep = tuple(keep_high or ())

    def predicate(path: str, module: Any) -> bool:
        if not hasattr(module, "to_quantized"):
            return False
        if any(k in path for k in keep):
            return False
        w = getattr(module, "weight", None)
        return w is not None and w.shape[-1] % group_size == 0

    nn.quantize(model, group_size=group_size, bits=bits, class_predicate=predicate)
    mx.eval(model.parameters())


def model_type(model: Any) -> str:
    return getattr(getattr(model, "args", None), "model_type", "") or model.__class__.__module__.split(".")[-1]


@dataclass
class LoadedLLM:
    model: Any
    tokenizer: Any
    gen_kwargs: dict[str, Any]
    patcher: Any = None
    info: dict[str, Any] = field(default_factory=dict)

    def unload(self) -> None:
        if self.patcher is not None:
            self.patcher.revert()
            self.patcher = None


def apply_kernels(model: Any, kernels: dict[str, Path]) -> tuple[Any, dict[str, Any]]:
    if not kernels:
        return None, {"status": "none"}
    missing = [str(p) for p in kernels.values() if not p.exists()]
    if missing:
        log.warning("kernel files not found, skipping kernels: %s", missing)
        return None, {"status": "skipped", "reason": f"missing files: {missing}"}
    try:
        from visai.backends.patchers import MLXModulePatcher
    except ImportError:
        log.warning("profile requests kernels %s but visai is not installed (uv pip install -e /path/to/visai); "
                    "skipping", sorted(kernels))
        return None, {"status": "skipped", "reason": "visai not installed"}
    patcher = MLXModulePatcher(model_type(model), [{"op": op, "candidate": str(p)} for op, p in kernels.items()])
    return patcher, patcher.apply()


def load_llm(profile: ModelProfile) -> LoadedLLM:
    from mlx_lm import load as mlx_load

    spec = profile.llm
    model, tokenizer = mlx_load(spec.model)
    cfg = spec.config
    if cfg.get("bits"):
        quantize_in_memory(model, int(cfg["bits"]), int(cfg.get("group_size") or 64), cfg.get("keep_high"))
    patcher, kinfo = apply_kernels(model, profile.kernel_paths())
    info = {"model": spec.model, "model_type": model_type(model), "config": cfg, "kernels": kinfo}
    return LoadedLLM(model, tokenizer, gen_kwargs(cfg), patcher, info)
