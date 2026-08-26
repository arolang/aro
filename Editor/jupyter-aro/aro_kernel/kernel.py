"""The ARO Jupyter kernel.

A thin translation layer: Jupyter messages in, `aro repl --json` requests
out. Everything language-shaped — splitting a cell, deciding what to display,
formatting an error — happens on the ARO side, so a notebook and an editor
embedding the same protocol behave identically.
"""

from __future__ import annotations

from typing import Any, Dict, List

from ipykernel.kernelbase import Kernel

from .backend import AROBackend, AROBackendError

__version__ = "0.1.0"


class AROKernel(Kernel):
    implementation = "aro"
    implementation_version = __version__

    language_info = {
        "name": "aro",
        "version": "0.1",
        "mimetype": "text/x-aro",
        "file_extension": ".aro",
        # No Pygments lexer exists for ARO yet, so `text` keeps nbconvert
        # from failing on export; editors highlight from their own grammar
        # (Editor/vscode-aro) keyed off the language name above.
        "pygments_lexer": "text",
        "codemirror_mode": "aro",
    }

    banner = (
        "ARO — business features as Action-Result-Object statements.\n"
        "Statements share the session: define a feature set in one cell, call it in the next.\n"
        "Meta-commands work too — try :vars, :fs, :help."
    )

    help_links = [
        {"text": "ARO Language Guide", "url": "https://github.com/arolang/aro/wiki"},
    ]

    def __init__(self, **kwargs):
        super().__init__(**kwargs)
        self._backend_error: str | None = None
        try:
            self.backend: AROBackend | None = AROBackend()
        except AROBackendError as exc:
            # Failing here would leave the client with a kernel that dies at
            # startup and no explanation. Start anyway and report the reason
            # in the first cell the user runs.
            self.backend = None
            self._backend_error = str(exc)

    # -- execute ------------------------------------------------------

    def do_execute(
        self,
        code,
        silent,
        store_history=True,
        user_expressions=None,
        allow_stdin=False,
        *,
        cell_id=None,
    ):
        if self.backend is None:
            return self._fail("KernelError", self._backend_error or "ARO backend unavailable")

        if not code.strip():
            return self._ok()

        def on_stream(name: str, text: str) -> None:
            if silent or not text:
                return
            self.send_response(
                self.iopub_socket,
                "stream",
                {"name": "stderr" if name == "stderr" else "stdout", "text": text},
            )

        try:
            result = self.backend.request("execute", on_stream=on_stream, code=code)
        except KeyboardInterrupt:
            # The cell is blocked inside the ARO runtime, which cannot be
            # unwound from here. Replace the process and say so — a silently
            # restarted session that has lost its variables is worse than an
            # interruption the user knows about.
            self.backend.restart()
            return self._fail(
                "Interrupted",
                "Execution was interrupted. The ARO session has been restarted, "
                "so variables and feature sets defined earlier are gone.",
            )
        except AROBackendError as exc:
            return self._fail("KernelError", str(exc))

        if result.get("status") == "error":
            error = result.get("error", {})
            payload = {
                "ename": error.get("ename", "AROError"),
                "evalue": error.get("evalue", ""),
                "traceback": error.get("traceback", []),
            }
            if not silent:
                self.send_response(self.iopub_socket, "error", payload)
            return {"status": "error", "execution_count": self.execution_count, **payload}

        display = result.get("display")
        if display and not silent:
            self.send_response(
                self.iopub_socket,
                "execute_result",
                {
                    "execution_count": self.execution_count,
                    "data": display,
                    "metadata": {},
                },
            )
        return self._ok()

    # -- completion & inspection --------------------------------------

    def do_complete(self, code, cursor_pos):
        empty = {
            "matches": [],
            "cursor_start": cursor_pos,
            "cursor_end": cursor_pos,
            "metadata": {},
            "status": "ok",
        }
        if self.backend is None:
            return empty
        try:
            result = self.backend.request("complete", code=code, cursor=cursor_pos, timeout=5)
        except AROBackendError:
            return empty

        return {
            "matches": result.get("matches", []),
            "cursor_start": result.get("cursorStart", cursor_pos),
            "cursor_end": result.get("cursorEnd", cursor_pos),
            "metadata": {},
            "status": "ok",
        }

    def do_inspect(self, code, cursor_pos, detail_level=0, omit_sections=()):
        missing = {"status": "ok", "found": False, "data": {}, "metadata": {}}
        if self.backend is None:
            return missing
        try:
            result = self.backend.request("inspect", code=code, cursor=cursor_pos, timeout=5)
        except AROBackendError:
            return missing

        if not result.get("found"):
            return missing
        return {
            "status": "ok",
            "found": True,
            "data": {"text/plain": result.get("text", "")},
            "metadata": {},
        }

    def do_is_complete(self, code):
        if self.backend is None:
            return {"status": "unknown"}
        try:
            result = self.backend.request("is_complete", code=code, timeout=5)
        except AROBackendError:
            return {"status": "unknown"}

        status = result.get("status", "complete")
        if status == "incomplete":
            return {"status": "incomplete", "indent": result.get("indent", "    ")}
        if status == "invalid":
            return {"status": "invalid"}
        return {"status": "complete"}

    # -- lifecycle ----------------------------------------------------

    def do_shutdown(self, restart):
        if self.backend is not None:
            if restart:
                self.backend.restart()
            else:
                self.backend.stop()
                self.backend = None
        return {"status": "ok", "restart": restart}

    # -- helpers ------------------------------------------------------

    def _ok(self) -> Dict[str, Any]:
        return {
            "status": "ok",
            "execution_count": self.execution_count,
            "payload": [],
            "user_expressions": {},
        }

    def _fail(self, name: str, message: str) -> Dict[str, Any]:
        traceback: List[str] = message.split("\n")
        self.send_response(
            self.iopub_socket,
            "error",
            {"ename": name, "evalue": traceback[0], "traceback": traceback},
        )
        return {
            "status": "error",
            "execution_count": self.execution_count,
            "ename": name,
            "evalue": traceback[0],
            "traceback": traceback,
        }
