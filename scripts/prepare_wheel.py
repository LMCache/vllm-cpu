#!/usr/bin/env python3
"""Make a CPU wheel publishable on PyPI without losing URL dependencies.

Usage: prepare_wheel.py WHEEL SOURCE_SHA BUILT_AT

URL requirements move from Requires-Dist to dist-info/cpu-nightly.json.
Installers must install the applicable requirements from that manifest.
Repacking with WheelFile regenerates RECORD, including the new manifest.
"""

import json
import re
import sys
import tempfile
from datetime import datetime
from email import policy
from email.parser import BytesParser
from pathlib import Path
from zipfile import ZipFile

from packaging.requirements import Requirement
from wheel.wheelfile import WheelFile


def prepare_wheel(path: Path, source_sha: str, built_at: str) -> None:
    """Repack a wheel with PyPI-compatible dependencies and build provenance."""
    if not re.fullmatch(r"[0-9a-f]{40}", source_sha):
        raise ValueError("SOURCE_SHA must be a full Git commit SHA")
    if datetime.fromisoformat(built_at.replace("Z", "+00:00")).tzinfo is None:
        raise ValueError("BUILT_AT must include its timezone")
    with ZipFile(path) as source, tempfile.TemporaryDirectory() as scratch:
        metadata_path = next(
            n for n in source.namelist() if n.endswith(".dist-info/METADATA")
        )
        metadata = BytesParser(policy=policy.compat32).parsebytes(
            source.read(metadata_path)
        )
        requirements = metadata.get_all("Requires-Dist", [])
        direct = [r for r in requirements if Requirement(r).url is not None]
        del metadata["Requires-Dist"]
        for requirement in requirements:
            if Requirement(requirement).url is None:
                metadata["Requires-Dist"] = requirement
        manifest = {
            "source_sha": source_sha,
            "built_at": built_at,
            "direct_requirements": direct,
        }
        manifest_path = metadata_path.rsplit("/", 1)[0] + "/cpu-nightly.json"
        target = Path(scratch) / path.name
        with WheelFile(target, "w") as wheel:
            for info in source.infolist():
                if (
                    info.filename.endswith(".dist-info/RECORD")
                    or info.filename == manifest_path
                ):
                    continue
                data = (
                    metadata.as_bytes()
                    if info.filename == metadata_path
                    else source.read(info.filename)
                )
                wheel.writestr(info, data)
            wheel.writestr(manifest_path, json.dumps(manifest, indent=2) + "\n")
        # The temporary directory may be on another filesystem.
        path.write_bytes(target.read_bytes())
    print(json.dumps(manifest, indent=2))


if __name__ == "__main__":
    prepare_wheel(Path(sys.argv[1]), sys.argv[2], sys.argv[3])
