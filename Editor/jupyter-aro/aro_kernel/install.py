"""Install the ARO kernelspec so Jupyter, VS Code, and DataSpell list it.

    python -m aro_kernel.install --user

The spec launches this package with the interpreter that installed it, so a
virtualenv install keeps working when Jupyter itself lives elsewhere.
"""

from __future__ import annotations

import argparse
import json
import os
import sys
import tempfile

from jupyter_client.kernelspec import KernelSpecManager

KERNEL_NAME = "aro"


def kernel_json() -> dict:
    spec = {
        "argv": [sys.executable, "-m", "aro_kernel", "-f", "{connection_file}"],
        "display_name": "ARO",
        "language": "aro",
        # Signal mode: Jupyter's "interrupt" sends SIGINT to this process,
        # which the kernel turns into a restart of the ARO session. A cell
        # blocked inside the runtime cannot be unwound any other way.
        "interrupt_mode": "signal",
        "metadata": {"debugger": False},
    }

    # Carry an explicit interpreter path through to the child so a kernel
    # started from a different Jupyter environment still finds this package.
    aro_path = os.environ.get("ARO_KERNEL_ARO")
    if aro_path:
        spec["env"] = {"ARO_KERNEL_ARO": aro_path}
    return spec


def install(user: bool = True, prefix: str | None = None, sys_prefix: bool = False) -> str:
    with tempfile.TemporaryDirectory() as directory:
        os.chmod(directory, 0o755)
        with open(os.path.join(directory, "kernel.json"), "w", encoding="utf-8") as handle:
            json.dump(kernel_json(), handle, indent=2, sort_keys=True)

        if sys_prefix:
            user, prefix = False, sys.prefix

        return KernelSpecManager().install_kernel_spec(
            directory,
            KERNEL_NAME,
            user=user,
            prefix=prefix,
        )


def main() -> None:
    parser = argparse.ArgumentParser(description="Install the ARO Jupyter kernelspec")
    location = parser.add_mutually_exclusive_group()
    location.add_argument("--user", action="store_true", help="install for the current user (default)")
    location.add_argument("--sys-prefix", action="store_true", help="install into sys.prefix (virtualenv)")
    location.add_argument("--prefix", help="install into a specific prefix")
    arguments = parser.parse_args()

    user = arguments.user or not (arguments.sys_prefix or arguments.prefix)
    destination = install(user=user, prefix=arguments.prefix, sys_prefix=arguments.sys_prefix)
    print(f"Installed the ARO kernelspec to {destination}")


if __name__ == "__main__":
    main()
