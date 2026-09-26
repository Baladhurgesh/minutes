"""`librosa.filters.mel` (Slaney mel scale, optional HTK), ported from librosa with NumPy only."""

from __future__ import annotations

import numpy as np

_F_SP = 200.0 / 3
_MIN_LOG_HZ = 1000.0
_MIN_LOG_MEL = _MIN_LOG_HZ / _F_SP
_LOGSTEP = np.log(6.4) / 27.0


def hz_to_mel(frequencies, *, htk: bool = False):
    f = np.asanyarray(frequencies, dtype=float)
    if htk:
        return 2595.0 * np.log10(1.0 + f / 700.0)
    mels = f / _F_SP
    log_region = f >= _MIN_LOG_HZ
    return np.where(log_region, _MIN_LOG_MEL + np.log(np.maximum(f, _MIN_LOG_HZ) / _MIN_LOG_HZ) / _LOGSTEP, mels)


def mel_to_hz(mels, *, htk: bool = False):
    m = np.asanyarray(mels, dtype=float)
    if htk:
        return 700.0 * (10.0 ** (m / 2595.0) - 1.0)
    freqs = _F_SP * m
    log_region = m >= _MIN_LOG_MEL
    return np.where(log_region, _MIN_LOG_HZ * np.exp(_LOGSTEP * (m - _MIN_LOG_MEL)), freqs)


def mel_frequencies(n_mels: int = 128, *, fmin: float = 0.0, fmax: float = 11025.0, htk: bool = False):
    mels = np.linspace(hz_to_mel(fmin, htk=htk), hz_to_mel(fmax, htk=htk), n_mels)
    return mel_to_hz(mels, htk=htk)


def mel(*, sr: float, n_fft: int, n_mels: int = 128, fmin: float = 0.0, fmax: float | None = None,
        htk: bool = False, norm="slaney", dtype=np.float32):
    if fmax is None:
        fmax = float(sr) / 2
    n_mels = int(n_mels)
    weights = np.zeros((n_mels, int(1 + n_fft // 2)), dtype=dtype)
    fftfreqs = np.fft.rfftfreq(n=n_fft, d=1.0 / sr)
    mel_f = mel_frequencies(n_mels + 2, fmin=fmin, fmax=fmax, htk=htk)
    fdiff = np.diff(mel_f)
    ramps = np.subtract.outer(mel_f, fftfreqs)
    for i in range(n_mels):
        lower = -ramps[i] / fdiff[i]
        upper = ramps[i + 2] / fdiff[i + 1]
        weights[i] = np.maximum(0, np.minimum(lower, upper))
    if norm == "slaney":
        enorm = 2.0 / (mel_f[2: n_mels + 2] - mel_f[:n_mels])
        weights *= enorm[:, np.newaxis]
    elif norm is not None:
        raise NotImplementedError(f"norm={norm!r} is not supported by the Minutes librosa shim")
    return weights
