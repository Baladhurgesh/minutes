"""Minimal stand-in for librosa, shipped only inside the bundled app.

parakeet-mlx imports librosa solely for `librosa.filters.mel`; the real package pulls in scipy,
scikit-learn and numba (~250 MB). This provides that one function with identical output
(verified by engine/tests/test_librosa_shim.py against real librosa).
"""

from . import filters

__all__ = ["filters"]
__version__ = "0.0.0+minutes-shim"
