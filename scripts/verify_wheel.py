#!/usr/bin/env python3
"""Smoke-test a built wheel in a clean environment, including URL dependencies.

Usage: verify_wheel.py WHEEL VENV_DIRECTORY
"""

import json
import os
import subprocess
import sys
import venv
from pathlib import Path
from zipfile import ZipFile

from packaging.requirements import Requirement


def verify_wheel(wheel: Path, environment: Path) -> None:
    """Install a CPU wheel and exercise its CLI and startup hook imports."""
    venv.create(environment, with_pip=True)
    python = str(environment / "bin/python")
    subprocess.run(
        [
            python,
            "-m",
            "pip",
            "install",
            str(wheel),
            "numpy<2",
            "--extra-index-url",
            "https://download.pytorch.org/whl/cpu",
        ],
        check=True,
    )
    with ZipFile(wheel) as archive:
        manifest_path = next(
            n for n in archive.namelist() if n.endswith(".dist-info/cpu-nightly.json")
        )
        manifest = json.loads(archive.read(manifest_path))
    requirements = []
    for text in manifest["direct_requirements"]:
        requirement = Requirement(text)
        if requirement.marker is None or requirement.marker.evaluate():
            requirements.append(text)
    if requirements:
        subprocess.run([python, "-m", "pip", "install", *requirements], check=True)
    # Match the distribution alias used by LMCache's CPU installer.
    subprocess.run(
        [
            python,
            "-c",
            """
import importlib.metadata as md
import shutil
dist = md.distribution("vllm-cpu-nightly")
info = next(p.parts[0] for p in dist.files if p.parts[0].endswith(".dist-info"))
src = dist.locate_file(info)
dst = src.with_name("vllm-" + dist.version + "+cpu.dist-info")
shutil.copytree(src, dst)
metadata = dst / "METADATA"
metadata.write_text(metadata.read_text().replace("Name: vllm-cpu-nightly", "Name: vllm", 1).replace("Version: " + dist.version, "Version: " + dist.version + "+cpu", 1))
""",
        ],
        check=True,
    )
    env = {**os.environ, "VLLM_TARGET_DEVICE": "cpu"}
    subprocess.run([str(environment / "bin/vllm"), "--help"], env=env, check=True)
    subprocess.run(
        [
            python,
            "-c",
            """
from vllm.distributed.kv_transfer.kv_connector.v1.base import KVConnectorBase_V1
from vllm.platforms import current_platform
import torch
current_platform.import_kernels()
values = torch.arange(128, dtype=torch.float32).reshape(2, 64) / 64
output = torch.empty_like(values)
torch.ops._C.rms_norm(output, values, torch.ones(64), 1e-6)
expected = values * torch.rsqrt(values.square().mean(-1, keepdim=True) + 1e-6)
torch.testing.assert_close(output, expected)
print("Native CPU rms_norm passed; on_kv_cache_ready:", hasattr(KVConnectorBase_V1, "on_kv_cache_ready"))
""",
        ],
        env=env,
        check=True,
    )
    print("Verified source", manifest["source_sha"], "built", manifest["built_at"])


if __name__ == "__main__":
    verify_wheel(Path(sys.argv[1]).resolve(), Path(sys.argv[2]).resolve())
