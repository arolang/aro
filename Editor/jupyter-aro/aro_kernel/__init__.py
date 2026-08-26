"""Jupyter kernel for ARO (Action Result Object).

Runs notebook cells against a live `aro repl --json` session — see
`Editor/jupyter-aro/README.md` for installation and the protocol it speaks.
"""

from .kernel import AROKernel, __version__

__all__ = ["AROKernel", "__version__"]
