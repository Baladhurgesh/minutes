"""The bundled librosa shim must reproduce librosa.filters.mel exactly for Parakeet's settings."""

import importlib.util
import sys
from pathlib import Path

import numpy as np
import pytest

librosa = pytest.importorskip("librosa")

SHIM = Path(__file__).resolve().parents[1] / "bundle_shims" / "librosa" / "filters.py"


def load_shim():
    spec = importlib.util.spec_from_file_location("minutes_librosa_shim_filters", SHIM)
    mod = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = mod
    spec.loader.exec_module(mod)
    return mod


@pytest.mark.parametrize("sr,n_fft,n_mels", [(16000, 512, 128), (16000, 512, 80), (22050, 2048, 64)])
def test_mel_matches_librosa(sr, n_fft, n_mels):
    shim = load_shim()
    kw = dict(sr=sr, n_fft=n_fft, n_mels=n_mels, fmin=0, fmax=sr / 2, norm="slaney")
    np.testing.assert_allclose(shim.mel(**kw), librosa.filters.mel(**kw), rtol=1e-6, atol=1e-9)


def test_htk_matches_librosa():
    shim = load_shim()
    kw = dict(sr=16000, n_fft=512, n_mels=40, htk=True)
    np.testing.assert_allclose(shim.mel(**kw), librosa.filters.mel(**kw), rtol=1e-6, atol=1e-9)
