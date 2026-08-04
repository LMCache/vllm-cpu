#!/usr/bin/env bash
# ----------------------------------------------------------------------------
# Build & publish a CPU-only vLLM wheel as `vllm-cpu-nightly` to PyPI.
#
# Strategy:
#   1. Spin up an `ubuntu:22.04` container that mirrors the GitHub Actions
#      runner used by .github/workflows/cpu_device.yml (python 3.12, gcc-12,
#      libnuma-dev). This gives a wheel that is binary-compatible with the
#      CI environment.
#   2. Clone vLLM `main` (the latest tip) and rename the distribution to
#      `vllm-cpu-nightly` by patching pyproject.toml + setup.py BEFORE the
#      build runs. The Python import name (`import vllm`) is preserved.
#   3. We build the wheel with a minute-stamped PEP-440 dev version:
#        `<base>.devN<YYYYMMDDHHMM>`
#      That number is monotonically increasing, so `pip install --upgrade
#      vllm-cpu-nightly` always pulls the newest one. PyPI keeps every
#      historical version reachable forever (so older builds stay
#      installable for rollback by pinning the exact version).
#   4. We pass `--plat-name manylinux_2_28_x86_64` directly to
#      `setup.py bdist_wheel` so the resulting wheel carries a PyPI-
#      acceptable platform tag from the start (PyPI rejects the bare
#      `linux_*` tag). This is safe because the ubuntu-22.04 build env
#      has glibc 2.35 and the GitHub runner used by cpu_device.yml is
#      also ubuntu-22.04 (same glibc).
#   5. Twine-upload to PyPI using the API token from
#      /data/home/baoloongmao/pypi_apikey.
#
# Usage (on the devcloud host):
#   bash build_and_publish_vllm_cpu_nightly.sh
#
# Optional env overrides:
#   PYPI_TOKEN_FILE   default: /data/home/baoloongmao/pypi_apikey
#   PKG_NAME          default: vllm-cpu-nightly
#   VLLM_GIT_REF      default: main      (set to a tag/sha to pin)
#   SKIP_UPLOAD       default: 0         (set to 1 for a dry-run build)
#   WORK_DIR          default: /data/vllm-cpu-nightly-build
# ----------------------------------------------------------------------------
set -euo pipefail

PYPI_TOKEN_FILE="${PYPI_TOKEN_FILE:-/data/home/baoloongmao/pypi_apikey}"
PKG_NAME="${PKG_NAME:-vllm-cpu-nightly}"
VLLM_GIT_REF="${VLLM_GIT_REF:-main}"
SKIP_UPLOAD="${SKIP_UPLOAD:-0}"
WORK_DIR="${WORK_DIR:-/data/vllm-cpu-nightly-build}"
IMAGE="ubuntu:22.04"

log() { printf '\033[1;36m[%s]\033[0m %s\n' "$(date +%H:%M:%S)" "$*"; }
die() { printf '\033[1;31m[ERR]\033[0m %s\n' "$*" >&2; exit 1; }

[[ -f "${PYPI_TOKEN_FILE}" ]] || die "PyPI token file not found: ${PYPI_TOKEN_FILE}"
PYPI_TOKEN="$(tr -d '[:space:]' < "${PYPI_TOKEN_FILE}")"
[[ -n "${PYPI_TOKEN}" ]] || die "PyPI token file is empty"

mkdir -p "${WORK_DIR}"
HOST_OUT_DIR="${WORK_DIR}/dist"
mkdir -p "${HOST_OUT_DIR}"

STAMP_FULL="$(date -u +%Y%m%d%H%M)"

log "Pulling ${IMAGE} (no-op if already present)..."
docker pull "${IMAGE}" >/dev/null

CONTAINER_NAME="vllm-cpu-nightly-build-$$"
trap 'docker rm -f "${CONTAINER_NAME}" >/dev/null 2>&1 || true' EXIT

log "Starting build container ${CONTAINER_NAME}..."
docker run -d --name "${CONTAINER_NAME}" \
    -e DEBIAN_FRONTEND=noninteractive \
    -e VLLM_TARGET_DEVICE=cpu \
    -e VLLM_GIT_REF="${VLLM_GIT_REF}" \
    -e PKG_NAME="${PKG_NAME}" \
    -e STAMP_FULL="${STAMP_FULL}" \
    -e CC=gcc-12 \
    -e CXX=g++-12 \
    -v "${HOST_OUT_DIR}:/out" \
    "${IMAGE}" \
    sleep infinity >/dev/null

run() { docker exec "${CONTAINER_NAME}" bash -ec "$*"; }

log "Installing system + python toolchain inside container..."
# We avoid `add-apt-repository` because the bare ubuntu:22.04 image
# ships a half-broken `software-properties-common` (gpg-agent missing,
# python3-launchpadlib pulls in 80MB of deps). Instead we register the
# deadsnakes PPA by hand: import its signing key into a trusted keyring
# and drop a sources.list snippet.
run '
set -euo pipefail
apt-get update -qq
apt-get install -y --no-install-recommends \
    ca-certificates curl gnupg git \
    gcc-12 g++-12 libnuma-dev patchelf >/dev/null
curl -fsSL "https://keyserver.ubuntu.com/pks/lookup?op=get&search=0xF23C5A6CF475977595C89F51BA6932366A755776" \
    | gpg --dearmor -o /etc/apt/trusted.gpg.d/deadsnakes.gpg
echo "deb http://ppa.launchpad.net/deadsnakes/ppa/ubuntu jammy main" \
    > /etc/apt/sources.list.d/deadsnakes.list
apt-get update -qq
apt-get install -y --no-install-recommends \
    python3.12 python3.12-venv python3.12-dev python3-pip >/dev/null
python3.12 -m venv /opt/venv
. /opt/venv/bin/activate
python -m pip install --upgrade pip wheel setuptools build twine auditwheel >/dev/null
'

log "Cloning vLLM @ ${VLLM_GIT_REF}..."
run '
set -euo pipefail
rm -rf /src/vllm
mkdir -p /src
git clone --depth 1 --branch "${VLLM_GIT_REF}" \
    https://github.com/vllm-project/vllm.git /src/vllm \
    2>/dev/null \
    || git clone https://github.com/vllm-project/vllm.git /src/vllm
cd /src/vllm
if [ "${VLLM_GIT_REF}" != "main" ]; then
    git checkout "${VLLM_GIT_REF}"
fi
git rev-parse HEAD > /src/vllm_commit.txt
echo "vLLM commit: $(cat /src/vllm_commit.txt)"
'

log "Patching distribution name -> ${PKG_NAME} and setting nightly version..."
run '
set -euo pipefail
cd /src/vllm
. /opt/venv/bin/activate

# Determine the upstream version that setuptools-scm would have produced
# for this commit. We deliberately do NOT trust setuptools-scm here:
# a shallow clone has no reachable tag and scm falls back to "0.1.dev1",
# which is too low (PyPI would consider it older than the real 0.x.y
# release line). Instead, fetch all tags and use the latest stable
# release tag (vX.Y.Z, no rc/a/b suffix), then bump the patch by 1
# because vLLM `main` is always post-release.
git fetch --tags --depth=1 origin >/dev/null 2>&1 || true
LAST_STABLE="$(git tag --sort=-v:refname | grep -E "^v[0-9]+\.[0-9]+\.[0-9]+$" | head -1)"
LAST_STABLE="${LAST_STABLE:-v0.0.0}"
BASE_RAW="${LAST_STABLE#v}"
BASE_VER="$(echo "${BASE_RAW}" | awk -F. "{ printf \"%d.%d.%d\", \$1, \$2, \$3+1 }")"
echo "Last stable tag : ${LAST_STABLE}"
echo "Bumped base ver : ${BASE_VER}"
echo "${BASE_VER}" > /src/base_version.txt

NIGHTLY_VER="${BASE_VER}.dev${STAMP_FULL}"
echo "${NIGHTLY_VER}" > /src/nightly_version.txt

# Rename the project distribution to PKG_NAME. Only [project].name in
# pyproject.toml needs to change; the import package (`vllm/`) is
# untouched so `import vllm` still works.
python - <<PY
import pathlib, re
pkg = "${PKG_NAME}"
p = pathlib.Path("pyproject.toml")
txt = p.read_text()
new = re.sub(r"^(\s*name\s*=\s*[\"\x27])vllm([\"\x27])",
             lambda m: m.group(1) + pkg + m.group(2),
             txt, count=1, flags=re.MULTILINE)
assert new != txt, "failed to patch pyproject.toml name"
p.write_text(new)
print(f"Patched name -> {pkg} in pyproject.toml")
PY

# Patch requirements/cpu.txt: PyPI rejects wheels whose dependencies
# carry a PEP 440 local label like `torch==2.11.0+cpu`. Strip the +cpu
# suffix; downstream installers can still pull the cpu wheel with
# `--extra-index-url https://download.pytorch.org/whl/cpu`.
sed -i -E "s/torch==([0-9.]+)\+cpu/torch==\1/g" requirements/cpu.txt
echo "--- patched requirements/cpu.txt ---"
grep -E "^torch" requirements/cpu.txt || true

# Patch csrc/cpu/sgl-kernels/fla.cpp: it initialises a constexpr float from
# std::sqrt, which is not constexpr in libc++ before C++26. GCC accepts it
# as a builtin so Linux is unaffected today, but keep the two build scripts
# in step so a compiler change does not surprise us. D is a template
# parameter, so const is semantically identical and still folds.
FLA_SRC="csrc/cpu/sgl-kernels/fla.cpp"
if [ -f "$FLA_SRC" ] \
        && grep -q "constexpr float scale = 1\.f / std::sqrt" "$FLA_SRC"; then
    sed -i -E "s/constexpr( float scale = 1\.f \/ std::sqrt)/const\1/" "$FLA_SRC"
    echo "--- patched $FLA_SRC (constexpr -> const) ---"
    grep -n "float scale = 1\.f / std::sqrt" "$FLA_SRC" || true
fi
'

log "Installing build deps + torch(cpu) inside container..."
run '
set -euo pipefail
. /opt/venv/bin/activate
# Without build isolation we must install everything that
# pyproject.toml [build-system].requires asks for ourselves.
pip install "cmake>=3.26.1" ninja "packaging>=24.2" \
    "setuptools>=77.0.3,<81.0.0" "setuptools-scm>=8.0" \
    "setuptools-rust>=1.9.0" wheel jinja2 >/dev/null
# vLLM ships a Rust frontend -> need cargo + system C toolchain so
# rustc can find a default linker and so torch.utils.cpp_extension can
# build the C++ extensions.
apt-get install -y --no-install-recommends build-essential >/dev/null
if ! command -v cargo >/dev/null 2>&1; then
    curl --proto =https --tlsv1.2 -sSf https://sh.rustup.rs \
        | sh -s -- -y --default-toolchain stable -q
fi
# Plain torch (cpu) so setup.py can `import torch`.
pip install "numpy<2" >/dev/null
# Build against exactly the torch this wheel will declare as a dependency.
# This used to be hardcoded to 2.11.0 while the declared version tracked
# upstream requirements/cpu.txt; when upstream moved to 2.13.0 the macOS
# wheel still linked against 2.11 and its _C.abi3.so ended up referencing a
# c10 symbol the installed torch does not export. Absolute path because this
# step does not cd into the source tree.
TORCH_REQ="$(grep -E "^torch==" /src/vllm/requirements/cpu.txt | head -1)"
: "${TORCH_REQ:?no torch== pin found in /src/vllm/requirements/cpu.txt}"
echo "building against ${TORCH_REQ}"
pip install "${TORCH_REQ}" \
    --extra-index-url https://download.pytorch.org/whl/cpu >/dev/null
'

NIGHTLY_VER="$(run 'cat /src/nightly_version.txt')"
log "  nightly version : ${NIGHTLY_VER}  (minute-stamped, monotonic)"

log "Building wheel with version=${NIGHTLY_VER} (~30-40 min)..."
run "
    set -euo pipefail
    cd /src/vllm
    . /opt/venv/bin/activate
    . \$HOME/.cargo/env
    export VLLM_TARGET_DEVICE=cpu
    export CC=gcc-12 CXX=g++-12
    export SETUPTOOLS_SCM_PRETEND_VERSION='${NIGHTLY_VER}'
    export VLLM_VERSION_OVERRIDE='${NIGHTLY_VER}'
    # vLLM's setup.py defaults to RelWithDebInfo (-O2 -g). The debug symbols
    # pushed this wheel from 96 MiB to 105 MiB, past PyPI's 100 MiB per-file
    # limit, and uploads have been failing with an opaque 400 ever since.
    # Release keeps the optimisation without the symbols.
    export CMAKE_BUILD_TYPE='${CMAKE_BUILD_TYPE:-Release}'
    export MAX_JOBS=\$(nproc)
    rm -rf /src/vllm/build /src/vllm/dist
    python setup.py bdist_wheel --plat-name manylinux_2_28_x86_64
    cp /src/vllm/dist/*.whl /out/
    ls -lh /out/
    twine check /out/*.whl
"

# `twine check` only validates metadata, so it happily passes a wheel whose
# compiled extension cannot resolve its libtorch symbols. dlopen every .so
# for real instead. Loading the extension directly (rather than
# `import vllm._C`) keeps this independent of vLLM's runtime dependencies:
# importing torch first is enough to bring libc10/libtorch into the process.
log "Verifying the built extension actually loads..."
run '
set -euo pipefail
. /opt/venv/bin/activate
python - /out <<"PYEOF"
import ctypes
import glob
import sys
import tempfile
import zipfile

import torch  # noqa: F401  -- must be imported first to load libtorch

# An unresolved *symbol* means the extension was compiled against a
# different libtorch than the one it declares -- that must never ship.
# A missing *library* is a different (also real) problem: the extension
# links a build-host library that was not bundled into the wheel. Warn
# about it rather than blocking the publish, so the two failure modes stay
# distinguishable.
FATAL = ("symbol not found", "undefined symbol")

wheels = glob.glob(sys.argv[1] + "/*.whl")
assert wheels, "no wheel found in " + sys.argv[1]
problems = []
for whl in wheels:
    with zipfile.ZipFile(whl) as z, tempfile.TemporaryDirectory() as tmp:
        sos = [n for n in z.namelist() if n.endswith(".so")]
        assert sos, "no extension modules inside " + whl
        for name in sos:
            try:
                ctypes.CDLL(z.extract(name, tmp))
                print("dlopen ok:", name)
            except OSError as exc:
                msg = str(exc)
                if any(f in msg.lower() for f in FATAL):
                    problems.append(name + ": " + msg)
                    print("dlopen FAILED (ABI):", name)
                else:
                    print("WARNING: dlopen failed, unbundled library?", name)
                print("   ", msg.strip().splitlines()[0])
if problems:
    sys.exit(
        "ABI check failed -- the extension does not match the torch this "
        "wheel declares:\n" + "\n".join(problems)
    )
PYEOF
'

log "Wheels staged on host:"
ls -lh "${HOST_OUT_DIR}"

# PyPI rejects files larger than 100 MiB with an opaque "400 Bad Request".
# This wheel sat ~3 MiB below that ceiling for weeks, crossed it on
# 2026-07-20, and every upload failed silently for the next twelve nights.
# Fail here with an actionable message instead.
PYPI_MAX_BYTES=$((100 * 1024 * 1024))
for whl in "${HOST_OUT_DIR}"/*.whl; do
    size="$(wc -c <"${whl}")"
    printf '  %s: %d MiB\n' "$(basename "${whl}")" "$((size / 1024 / 1024))"
    if [[ "${size}" -gt "${PYPI_MAX_BYTES}" ]]; then
        echo "[ERROR] $(basename "${whl}") is $((size / 1024 / 1024)) MiB," \
            "over PyPI's 100 MiB per-file limit. Shrink the build (check" \
            "CMAKE_BUILD_TYPE) or publish somewhere without a size cap." >&2
        exit 1
    fi
done

if [[ "${SKIP_UPLOAD}" == "1" ]]; then
    log "SKIP_UPLOAD=1 -> stopping before twine upload."
    exit 0
fi

log "Uploading to PyPI via twine..."
docker exec \
    -e TWINE_USERNAME="__token__" \
    -e TWINE_PASSWORD="${PYPI_TOKEN}" \
    "${CONTAINER_NAME}" \
    bash -ec '
        . /opt/venv/bin/activate
        twine upload --non-interactive --disable-progress-bar /out/*.whl
    '

log "Done. Index page: https://pypi.org/project/${PKG_NAME}/"
log "Install with:    pip install ${PKG_NAME}"