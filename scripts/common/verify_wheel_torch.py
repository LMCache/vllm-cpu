#!/usr/bin/env python3
"""Verify that built wheels declare the torch version they were actually
compiled against.

``twine check`` only validates metadata, so it would happily pass a wheel
built against a different torch than it declares -- the exact defect that
shipped on 2026-07-30. This compares the two versions directly.

Do NOT try to dlopen the extensions to verify this instead. vLLM builds
several ISA-specialised variants (_C, _C_AVX2, _C_AVX512) and the default
one is compiled with -mavx512* -mamx-*; loading it on a host that lacks
those instructions, or that has not requested AMX state via arch_prctl,
dies with SIGILL and tells us nothing about the ABI. vLLM picks a variant at
runtime after probing the CPU, so "every .so dlopens here" was never the
right invariant.

Usage:
    verify_wheel_torch.py <dist_dir>
"""

# Standard
import glob
import sys
import zipfile

# Third Party
import torch


def normalize(version: str) -> str:
    """Drop the PEP 440 local label, e.g. ``2.13.0+cpu`` -> ``2.13.0``."""
    return version.split("+")[0]


def main() -> None:
    """Check every wheel in the directory given as argv[1] declares exactly
    the torch version this interpreter is built against; exit non-zero on
    any mismatch.
    """
    dist_dir = sys.argv[1]
    built = normalize(torch.__version__)
    wheels = glob.glob(dist_dir + "/*.whl")
    if not wheels:
        sys.exit("no wheel found in " + dist_dir)

    for whl in wheels:
        with zipfile.ZipFile(whl) as z:
            names = [n for n in z.namelist() if n.endswith(".dist-info/METADATA")]
            if not names:
                sys.exit("no METADATA in " + whl)
            text = z.read(names[0]).decode("utf-8", "replace")

        declared = set()
        for line in text.splitlines():
            if line.startswith("Requires-Dist: torch=="):
                spec = line.split("==", 1)[1].split(";")[0].strip()
                declared.add(normalize(spec))

        if not declared:
            sys.exit(whl + " declares no pinned torch requirement")
        if declared != {built}:
            sys.exit(
                "ABI mismatch: built against torch %s but the wheel declares %s"
                % (built, ", ".join(sorted(declared)))
            )
        print("torch matches: built against and declares %s" % built)


if __name__ == "__main__":
    main()
