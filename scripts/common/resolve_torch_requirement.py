#!/usr/bin/env python3
"""Print the ``torch==`` pin from a vLLM ``requirements/cpu.txt`` that
applies to the current host.

``requirements/cpu.txt`` carries one torch line per platform group, each
guarded by an environment marker, e.g.::

    torch==2.13.0; platform_machine == "x86_64" or ... "aarch64"
    torch==2.13.0; platform_system == "Darwin" or ... "riscv64"

Taking the first match naively can pick a pin meant for another
architecture: pip then evaluates the marker, skips the install, and still
exits 0, leaving the build to fail later with "No module named 'torch'".
This lets ``packaging`` evaluate the markers and prints only the pin that
applies here.

Usage:
    resolve_torch_requirement.py <path/to/requirements/cpu.txt>
"""

# Standard
import sys

# Third Party
from packaging.requirements import Requirement


def main() -> None:
    """Read the requirements file given as argv[1] and print the applicable
    ``torch==`` requirement string, or exit with an error if none matches.
    """
    path = sys.argv[1]
    with open(path) as f:
        for line in f:
            line = line.split("#", 1)[0].strip()
            if not line.startswith("torch=="):
                continue
            req = Requirement(line)
            if req.marker is None or req.marker.evaluate():
                print(req.name + str(req.specifier))
                return
    sys.exit(f"no applicable 'torch==' pin in {path}")


if __name__ == "__main__":
    main()
