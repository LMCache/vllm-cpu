#!/usr/bin/env bash
# ----------------------------------------------------------------------------
# Shared shell helpers for the vllm-cpu-nightly build scripts
# (build_and_publish_vllm_cpu_nightly.sh and its _macos.sh counterpart).
#
# Meant to be `source`d, not executed directly. Also gets mounted into the
# Linux build container so the same helpers are available on both sides of
# the docker boundary -- see build_and_publish_vllm_cpu_nightly.sh.
# ----------------------------------------------------------------------------

log() { printf '\033[1;36m[%s]\033[0m %s\n' "$(date +%H:%M:%S)" "$*"; }
die() { printf '\033[1;31m[ERR]\033[0m %s\n' "$*" >&2; exit 1; }

# compute_nightly_version <stamp>
#
# Prints "<base>.dev<stamp>" to stdout. Must be run with CWD inside the vLLM
# git checkout.
#
# Determine the upstream version that setuptools-scm would have produced for
# this commit. We deliberately do NOT trust setuptools-scm here: a shallow
# clone has no reachable tag and scm falls back to "0.1.dev1", which PyPI
# would treat as older than every real release. Instead, fetch all tags and
# use the latest stable release tag (vX.Y.Z, no rc/a/b suffix), then bump the
# patch by 1 because vLLM `main` is always post-release.
compute_nightly_version() {
    local stamp="$1"
    local last_stable base_raw base_ver

    git fetch --tags --depth=1 origin >/dev/null 2>&1 || true
    last_stable="$(git tag --sort=-v:refname | grep -E '^v[0-9]+\.[0-9]+\.[0-9]+$' | head -1)"
    last_stable="${last_stable:-v0.0.0}"
    base_raw="${last_stable#v}"
    base_ver="$(awk -v v="${base_raw}" 'BEGIN {
        n = split(v, a, ".");
        printf "%d.%d.%d", a[1], a[2], a[3] + 1;
    }')"

    log "  last stable tag  : ${last_stable}" >&2
    log "  bumped base ver  : ${base_ver}" >&2

    printf '%s.dev%s\n' "${base_ver}" "${stamp}"
}

# check_wheel_size <dist_dir>
#
# PyPI rejects files larger than 100 MiB with an opaque "400 Bad Request".
# One of our wheels sat ~3 MiB below that ceiling for weeks, crossed it on
# 2026-07-20, and every upload failed silently for the next twelve nights.
# Fail here with an actionable message instead of leaving that to twine.
check_wheel_size() {
    local dist_dir="$1"
    local max_bytes=$((100 * 1024 * 1024))
    local whl size

    for whl in "${dist_dir}"/*.whl; do
        size="$(wc -c <"${whl}")"
        printf '  %s: %d MiB\n' "$(basename "${whl}")" "$((size / 1024 / 1024))"
        if [[ "${size}" -gt "${max_bytes}" ]]; then
            echo "[ERROR] $(basename "${whl}") is $((size / 1024 / 1024)) MiB," \
                "over PyPI's 100 MiB per-file limit. Shrink the build (check" \
                "CMAKE_BUILD_TYPE) or publish somewhere without a size cap." >&2
            return 1
        fi
    done
}
