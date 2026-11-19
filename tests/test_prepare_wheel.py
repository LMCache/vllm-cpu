import base64
import csv
import hashlib
import importlib.util
import io
import json
from pathlib import Path
from zipfile import ZipFile

from wheel.wheelfile import WheelFile


def test_publishable_wheel_preserves_marked_urls_and_valid_record(tmp_path):
    script = Path(__file__).resolve().parents[1] / "scripts/prepare_wheel.py"
    spec = importlib.util.spec_from_file_location("prepare_wheel", script)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    path = tmp_path / "vllm_cpu_nightly-1.0.dev202611190900-py3-none-any.whl"
    info = "vllm_cpu_nightly-1.0.dev202611190900.dist-info"
    url = 'triton @ https://example.org/triton.whl ; platform_machine == "x86_64"'
    with WheelFile(path, "w") as wheel:
        wheel.writestr(info + "/WHEEL", "Wheel-Version: 1.0\nTag: py3-none-any\n")
        wheel.writestr(
            info + "/METADATA",
            "Metadata-Version: 2.4\nName: vllm-cpu-nightly\nVersion: 1.0.dev202611190900\nRequires-Dist: torch==2.13.0\nRequires-Dist: "
            + url
            + "\n\nDescription\n",
        )
        wheel.writestr("vllm/__init__.py", "original = True\n")
    module.prepare_wheel(path, "a" * 40, "2026-11-19T09:00:00Z")
    with ZipFile(path) as wheel:
        metadata = wheel.read(info + "/METADATA").decode()
        assert "Requires-Dist: torch==2.13.0" in metadata
        assert "Requires-Dist: triton" not in metadata
        assert wheel.read("vllm/__init__.py") == b"original = True\n"
        assert json.loads(wheel.read(info + "/cpu-nightly.json")) == {
            "source_sha": "a" * 40,
            "built_at": "2026-11-19T09:00:00Z",
            "direct_requirements": [url],
        }
        for name, digest, size in csv.reader(
            io.StringIO(wheel.read(info + "/RECORD").decode())
        ):
            if digest:
                data = wheel.read(name)
                actual = (
                    base64.urlsafe_b64encode(hashlib.sha256(data).digest())
                    .rstrip(b"=")
                    .decode()
                )
                assert digest == "sha256=" + actual
                assert int(size) == len(data)
