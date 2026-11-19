# vllm-cpu

Nightly CI that builds CPU-only [vLLM](https://github.com/vllm-project/vllm)
wheels for **Linux x86_64** and **macOS arm64** and publishes them to PyPI as
[`vllm-cpu-nightly`](https://pypi.org/project/vllm-cpu-nightly/).

The Python import name is unchanged — consumers still write `import vllm`.

## Why this repo exists

vLLM upstream does not publish prebuilt CPU wheels for either Linux or macOS.
Building from source on every CI run takes 30–40 minutes per platform and
burns CI minutes; this repo does the build once a day and downstream
projects (e.g. LMCache CPU device tests) just `pip install` the wheel.

## Triggers

* **Daily schedule** — every day at `06:00 UTC` (~14:00 Beijing).
* **Manual** — via the *Actions → Nightly build & publish vllm-cpu →
  Run workflow* button, or:

  ```bash
  gh workflow run nightly.yml -R LMCache/vllm-cpu
  # optional inputs:
  gh workflow run nightly.yml -R LMCache/vllm-cpu \
      -f vllm_git_ref=main \
      -f skip_upload=0
  ```

## Versioning

Each run produces a wheel whose version is

```
<latest-stable-tag-of-vllm-bumped>.devN<YYYYMMDDHHMM>
```

e.g. `0.11.1.dev202506110600`. The minute stamp is monotonically
increasing, so `pip install --upgrade vllm-cpu-nightly` always picks up
the newest one. Older versions stay installable on PyPI for rollback by
pinning the exact version string.

## Repository secret

The workflow needs a single repository secret:

| Name        | Value                                                      |
|-------------|------------------------------------------------------------|
| `PYPI_TOKEN`| A PyPI API token with upload permission to `vllm-cpu-nightly`. |

## How consumers install the wheel

```bash
pip install --upgrade vllm-cpu-nightly \
    --extra-index-url https://download.pytorch.org/whl/cpu
```

The `--extra-index-url` is required on Linux because the wheel depends on
`torch==2.11.0` (CPU build), which only lives on the PyTorch index.
On macOS arm64 the default PyPI torch wheel is already CPU-only so the
extra index is harmless.

PyPI rejects direct URL dependencies in wheel metadata. The wheel preserves
these dependencies, including Triton CPU, in its `cpu-nightly.json` dist-info
manifest. After installing, install the requirements matching your platform:

```bash
python - <<'PY'
import importlib.metadata as md
import json
import subprocess
import sys
from packaging.requirements import Requirement

manifest = json.loads(md.distribution("vllm-cpu-nightly").read_text("cpu-nightly.json"))
requirements = []
for text in manifest["direct_requirements"]:
    requirement = Requirement(text)
    if requirement.marker is None or requirement.marker.evaluate():
        requirements.append(text)
if requirements:
    subprocess.run([sys.executable, "-m", "pip", "install", *requirements], check=True)
print("vLLM source:", manifest["source_sha"], "built:", manifest["built_at"])
PY
```

LMCache's CPU installer performs this step automatically. PR builds and manual
`skip_upload=1` builds require no PyPI token. Both platforms build the same
resolved upstream SHA and timestamp; publication starts after both pass.

Publication failures open or update a tracking issue. GitHub can disable a
scheduled workflow after repository inactivity; downstream freshness checks
must detect that case independently. Re-enable the workflow with
`gh workflow enable nightly.yml -R LMCache/vllm-cpu` after repairing it.

## Layout

```
.
├── .github/workflows/nightly.yml      # the cron + dispatch workflow
└── scripts/
    ├── build_and_publish_vllm_cpu_nightly.sh         # ubuntu/x86_64 build
    └── build_and_publish_vllm_cpu_nightly_macos.sh   # macos/arm64 build
```

Both scripts are also runnable locally for debugging — see the header
comments in each script for env knobs (`PYPI_TOKEN_FILE`, `VLLM_GIT_REF`,
`SKIP_UPLOAD`, `WORK_DIR`, …).
