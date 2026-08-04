#!/usr/bin/env bash
# ----------------------------------------------------------------------------
# Patches a freshly cloned vLLM checkout so it builds as a distribution named
# ${PKG_NAME}, and applies the two small portability fixes both build
# scripts need. Shared by build_and_publish_vllm_cpu_nightly.sh (run inside
# the Linux build container) and build_and_publish_vllm_cpu_nightly_macos.sh
# (run directly on the host).
#
# Requires:
#   - CWD is the root of the vLLM git checkout.
#   - PKG_NAME is exported in the environment.
# ----------------------------------------------------------------------------
set -euo pipefail

: "${PKG_NAME:?PKG_NAME must be set}"

# Rename the project distribution to PKG_NAME. Only [project].name in
# pyproject.toml needs to change; the import package (`vllm/`) is untouched
# so `import vllm` still works.
PKG_NAME="${PKG_NAME}" python3 - <<'PY'
import os
import pathlib
import re

pkg = os.environ["PKG_NAME"]
p = pathlib.Path("pyproject.toml")
txt = p.read_text()
new = re.sub(
    r"^(\s*name\s*=\s*[\"'])vllm([\"'])",
    lambda m: m.group(1) + pkg + m.group(2),
    txt,
    count=1,
    flags=re.MULTILINE,
)
assert new != txt, "failed to patch pyproject.toml name"
p.write_text(new)
print(f"Patched name -> {pkg} in pyproject.toml")
PY

# Patch requirements/cpu.txt: PyPI rejects wheels whose dependencies carry a
# PEP 440 local label like `torch==2.11.0+cpu`. Strip the +cpu suffix;
# downstream installers can still pull the cpu wheel with
# `--extra-index-url https://download.pytorch.org/whl/cpu`. macOS arm64
# wheels of torch live on plain PyPI without the +cpu label anyway, so this
# is correct on both platforms.
if [[ -f requirements/cpu.txt ]]; then
    sed -i.bak -E 's/torch==([0-9.]+)\+cpu/torch==\1/g' requirements/cpu.txt
    rm -f requirements/cpu.txt.bak
    echo "--- patched requirements/cpu.txt ---"
    grep -E '^torch' requirements/cpu.txt || true
fi

# Patch csrc/cpu/sgl-kernels/fla.cpp: it initialises a `constexpr float` from
# std::sqrt, which is not constexpr in libc++ before C++26, so Apple clang
# rejects it ("constexpr variable 'scale' must be initialized by a constant
# expression"). GCC accepts it as a builtin, which is why only macOS breaks
# today -- but keep both build scripts in step so a compiler change does not
# surprise us. `D` is a template parameter, so `const` is semantically
# identical here and still folds to a constant. Drop this once upstream
# makes it portable.
FLA_SRC="csrc/cpu/sgl-kernels/fla.cpp"
if [[ -f "${FLA_SRC}" ]] \
        && grep -q 'constexpr float scale = 1\.f / std::sqrt' "${FLA_SRC}"; then
    sed -i.bak -E \
        's/constexpr( float scale = 1\.f \/ std::sqrt)/const\1/' "${FLA_SRC}"
    rm -f "${FLA_SRC}.bak"
    echo "--- patched ${FLA_SRC} (constexpr -> const) ---"
    grep -n 'float scale = 1\.f / std::sqrt' "${FLA_SRC}" || true
fi
