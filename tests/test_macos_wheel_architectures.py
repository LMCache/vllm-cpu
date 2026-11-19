import importlib.util
import subprocess
import sys
from pathlib import Path
from zipfile import ZipFile

import pytest


@pytest.fixture(scope="module")
def native_libraries(tmp_path_factory):
    if sys.platform != "darwin":
        pytest.skip("Mach-O validation requires Apple's clang and lipo")
    root = tmp_path_factory.mktemp("native-architectures")
    libraries = {}
    for arch in ("arm64", "x86_64"):
        library = root / f"{arch}.dylib"
        subprocess.run(
            ["clang", "-arch", arch, "-dynamiclib", "-x", "c", "-o", str(library), "-"],
            input="int wheel_architecture_test(void) { return 1; }\n",
            text=True,
            check=True,
        )
        libraries[arch] = library
    libraries["universal2"] = root / "universal2.dylib"
    subprocess.run(
        [
            "lipo",
            "-create",
            str(libraries["arm64"]),
            str(libraries["x86_64"]),
            "-output",
            str(libraries["universal2"]),
        ],
        check=True,
    )
    return libraries


@pytest.mark.parametrize(
    "tag,library,valid",
    [
        ("universal2", "arm64", False),
        ("arm64", "arm64", True),
        ("arm64", "x86_64", False),
        ("universal2", "universal2", True),
    ],
)
def test_native_architectures_match_advertised_platform(
    tmp_path, native_libraries, tag, library, valid
):
    script = Path(__file__).resolve().parents[1] / "scripts/verify_wheel.py"
    spec = importlib.util.spec_from_file_location("verify_wheel", script)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    wheel = tmp_path / f"vllm_cpu_nightly-1.0-cp312-cp312-macosx_11_0_{tag}.whl"
    with ZipFile(wheel, "w") as archive:
        archive.writestr("vllm/_C.abi3.so", native_libraries[library].read_bytes())
    if valid:
        module.verify_macos_architectures(wheel)
    else:
        with pytest.raises(ValueError, match="promises.*but.*contains"):
            module.verify_macos_architectures(wheel)
