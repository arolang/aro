"""Client for the `aro repl --json` protocol.

The kernel owns one long-lived `aro` process and talks to it over stdio with
one JSON object per line. The ARO side redirects its own stdout and stderr
into `stream` messages before it answers anything, so the pipe carries
protocol only and program output arrives as data rather than as noise mixed
into the channel.

Ordering is guaranteed by the server: every `stream` message for a request
is written before that request's `result`. This client therefore never has
to guess when a cell's output is finished.
"""

from __future__ import annotations

import json
import os
import shutil
import subprocess
import threading
from queue import Empty, Queue
from typing import Any, Callable, Dict, List, Optional


class AROBackendError(RuntimeError):
    """The ARO process could not be started, or died mid-request."""


def find_aro() -> str:
    """Locate the `aro` executable.

    `ARO_KERNEL_ARO` wins so a checkout can be tested without installing:
    point it at `.build/debug/aro` and the kernel runs against the build you
    just made.
    """
    explicit = os.environ.get("ARO_KERNEL_ARO")
    if explicit:
        if not os.path.isfile(explicit):
            raise AROBackendError(f"ARO_KERNEL_ARO points at {explicit!r}, which does not exist")
        return explicit

    found = shutil.which("aro")
    if found:
        return found

    raise AROBackendError(
        "Could not find the 'aro' executable. Install it and make sure it is on PATH, "
        "or set ARO_KERNEL_ARO to its full path."
    )


class AROBackend:
    """A running `aro repl --json` process."""

    def __init__(self, executable: Optional[str] = None, cwd: Optional[str] = None):
        self.executable = executable or find_aro()
        self.cwd = cwd or os.getcwd()
        self._process: Optional[subprocess.Popen] = None
        self._messages: "Queue[Optional[Dict[str, Any]]]" = Queue()
        self._reader: Optional[threading.Thread] = None
        self._stderr: List[str] = []
        self._request_id = 0
        self._lock = threading.Lock()
        self.start()

    # -- lifecycle ----------------------------------------------------

    def start(self) -> None:
        self._process = subprocess.Popen(
            [self.executable, "repl", "--json"],
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            cwd=self.cwd,
            text=True,
            bufsize=1,
        )
        self._messages = Queue()
        self._stderr = []

        self._reader = threading.Thread(target=self._read_loop, daemon=True)
        self._reader.start()
        threading.Thread(target=self._read_stderr, daemon=True).start()

        # The server announces itself before accepting work; waiting for that
        # turns "the binary is not runnable" into an error at kernel start
        # rather than a hang on the first cell.
        ready = self._await_message(lambda m: m.get("type") == "ready", timeout=30.0)
        if ready is None:
            raise AROBackendError(
                "The ARO REPL did not start.\n" + "".join(self._stderr).strip()
            )
        self.version = ready.get("version", "unknown")

    def stop(self) -> None:
        process, self._process = self._process, None
        if process is None:
            return
        try:
            if process.stdin and not process.stdin.closed:
                process.stdin.close()
            process.wait(timeout=2)
        except Exception:
            process.kill()

    def restart(self) -> None:
        """Kill and replace the process, losing session state.

        Used for interrupts: a cell blocked inside the runtime cannot be
        unwound from here, so the honest recovery is a fresh session — said
        plainly to the user rather than pretended away.
        """
        process, self._process = self._process, None
        if process is not None:
            process.kill()
            try:
                process.wait(timeout=5)
            except Exception:
                pass
        self.start()

    @property
    def alive(self) -> bool:
        return self._process is not None and self._process.poll() is None

    # -- reading ------------------------------------------------------

    def _read_loop(self) -> None:
        process = self._process
        if process is None or process.stdout is None:
            return
        for line in process.stdout:
            line = line.strip()
            if not line:
                continue
            try:
                self._messages.put(json.loads(line))
            except json.JSONDecodeError:
                # Anything unparseable is output that escaped capture (a
                # crash report, say). Surface it rather than discard it.
                self._messages.put({"type": "stream", "name": "stderr", "text": line + "\n"})
        self._messages.put(None)  # EOF sentinel

    def _read_stderr(self) -> None:
        process = self._process
        if process is None or process.stderr is None:
            return
        for line in process.stderr:
            self._stderr.append(line)

    def _await_message(self, predicate, timeout: float) -> Optional[Dict[str, Any]]:
        while True:
            try:
                message = self._messages.get(timeout=timeout)
            except Empty:
                return None
            if message is None:
                return None
            if predicate(message):
                return message

    # -- requests -----------------------------------------------------

    def request(
        self,
        kind: str,
        on_stream: Optional[Callable[[str, str], None]] = None,
        timeout: Optional[float] = None,
        **payload: Any,
    ) -> Dict[str, Any]:
        """Send one request and return its result message.

        `on_stream` is called with (name, text) for each output chunk as it
        arrives, so a long-running cell shows its `Log` output while it runs
        instead of all at once at the end.
        """
        if not self.alive:
            raise AROBackendError("The ARO REPL process is not running")

        with self._lock:
            self._request_id += 1
            request_id = self._request_id

        message = {"id": request_id, "type": kind}
        message.update(payload)

        process = self._process
        assert process is not None and process.stdin is not None
        process.stdin.write(json.dumps(message) + "\n")
        process.stdin.flush()

        while True:
            try:
                received = self._messages.get(timeout=timeout)
            except Empty as exc:
                raise AROBackendError(f"Timed out waiting for a {kind} result") from exc

            if received is None:
                detail = "".join(self._stderr).strip()
                raise AROBackendError(
                    "The ARO REPL exited unexpectedly." + (f"\n{detail}" if detail else "")
                )

            if received.get("type") == "stream":
                if on_stream is not None:
                    on_stream(received.get("name", "stdout"), received.get("text", ""))
                continue

            if received.get("type") == "result" and received.get("id") == request_id:
                return received

            # A result for a request we already gave up on: drop it rather
            # than mistake it for this one's answer.
