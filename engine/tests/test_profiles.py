import json
from pathlib import Path

import pytest
from pydantic import ValidationError

from minutes_engine.profiles import discover_profiles, gen_kwargs, load_profile, validate_llm_config

REPO_PROFILES = Path(__file__).resolve().parents[2] / "profiles"


def test_repo_profiles_are_valid():
    profiles = discover_profiles([REPO_PROFILES])
    assert "default" in profiles
    assert profiles["default"].llm.model == "Qwen/Qwen3-0.6B"


def test_visai_config_validation_matches_search_space():
    assert validate_llm_config({"bits": 4, "group_size": 64, "keep_high": ["lm_head"], "kv_bits": 8}) == []
    assert validate_llm_config({"bits": 7})
    assert validate_llm_config({"prefill_step_size": 100})
    assert validate_llm_config({"speculative": True})


def test_gen_kwargs():
    assert gen_kwargs({"kv_bits": 8, "prefill_step_size": 1024}) == {
        "kv_bits": 8, "kv_group_size": 64, "prefill_step_size": 1024}
    assert gen_kwargs({"bits": 4}) == {}


def test_kernel_paths_resolve_relative_to_profile(tmp_path):
    (tmp_path / "kernels").mkdir()
    f = tmp_path / "opt.json"
    f.write_text(json.dumps({"name": "opt", "llm": {"model": "Qwen/Qwen3-0.6B",
                                                   "kernels": {"add_rmsnorm": "kernels/add_rmsnorm.py"}}}))
    p = load_profile(f)
    assert p.kernel_paths()["add_rmsnorm"] == (tmp_path / "kernels" / "add_rmsnorm.py").resolve()


def test_invalid_profile_rejected(tmp_path):
    f = tmp_path / "bad.json"
    f.write_text(json.dumps({"name": "bad", "llm": {"config": {"bits": 2}}}))
    with pytest.raises(ValidationError):
        load_profile(f)
    f.write_text(json.dumps({"name": "bad", "llm": {"kernels": {"softmax": "x.py"}}}))
    with pytest.raises(ValidationError):
        load_profile(f)
    assert "bad" not in discover_profiles([tmp_path])


def test_later_dir_overrides(tmp_path):
    (tmp_path / "default.json").write_text(json.dumps({"name": "default", "description": "mine"}))
    assert discover_profiles([REPO_PROFILES, tmp_path])["default"].description == "mine"
