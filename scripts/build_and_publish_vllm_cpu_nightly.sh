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
# The steps that are identical to the macOS build (build_and_publish_
# vllm_cpu_nightly_macos.sh) live under scripts/common/ and are mounted
# read-only into the build container so both scripts execute the exact same
# code -- see the `-v ".../common:/opt/vllm-cpu-nightly-common:ro"` docker
# flag below.
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

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMMON_DIR="${SCRIPT_DIR}/common"
# shellcheck source=common/helpers.sh
source "${COMMON_DIR}/helpers.sh"

PYPI_TOKEN_FILE="${PYPI_TOKEN_FILE:-/data/home/baoloongmao/pypi_apikey}"
PKG_NAME="${PKG_NAME:-vllm-cpu-nightly}"
VLLM_GIT_REF="${VLLM_GIT_REF:-main}"
SKIP_UPLOAD="${SKIP_UPLOAD:-0}"
WORK_DIR="${WORK_DIR:-/data/vllm-cpu-nightly-build}"
IMAGE="ubuntu:22.04"

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
    -v "${COMMON_DIR}:/opt/vllm-cpu-nightly-common:ro" \
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
source /opt/vllm-cpu-nightly-common/helpers.sh

NIGHTLY_VER="$(compute_nightly_version "${STAMP_FULL}")"
echo "${NIGHTLY_VER}" > /src/nightly_version.txt

bash /opt/vllm-cpu-nightly-common/patch_vllm_source.sh
'

log "Installing build deps + torch(cpu) inside container..."
run '
set -euo pipefail
. /opt/venv/bin/activate
# Without build isolation we must install everything that
# pyproject.toml [build-system].requires asks forourselves.
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
# See scripts/common/resolve_torch_requirement.py for why we cannot just
# take the first `torch==` line in requirements/cpu.txt.
TORCH_REQ="$(python3 /opt/vllm-cpu-nightly-common/resolve_torch_requirement.py /src/vllm/requirements/cpu.txt)"
: "${TORCH_REQ:?no applicable torch== pin in /src/vllm/requirements/cpu.txt}"
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
    # limit, and uploads have been failing with an opaque 400ever since.
    # Release keeps the optimisation without the symbols.
    export CMAKE_BUILD_TYPE='${CMAKE_BUILD_TYPE:-Release}'
    export MAX_JOBS=\$(nproc)
    rm -rf /src/vllm/build /src/vllm/dist
    python setup.py bdist_wheel --plat-name manylinux_2_28_x86_64
    cp /src/vllm/dist/*.whl /out/
    ls -lh /out/
    twine check /out/*.whl
"

log "Verifying the wheel declares the torch it was built against..."
run '
set -euo pipefail
. /opt/venv/bin/activate
python3 /opt/vllm-cpu-nightly-common/verify_wheel_torch.py /out
'

log "Wheels staged on host:"
ls -lh "${HOST_OUT_DIR}"

check_wheel_size "${HOST_OUT_DIR}"

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
