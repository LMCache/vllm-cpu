# Build and verification notes

- `SKIP_UPLOAD=1` builds must work without a PyPI token; publishing happens in
  the separate trusted workflow job after both platform builds pass.
- CPU requirements can contain marked direct URLs. PyPI rejects those in
  Requires-Dist even when the marker excludes the upload platform. Preserve
  them in the wheel manifest and install applicable entries during validation.
- Resolve one upstream SHA for both builds. Fetch that SHA with `git fetch
  --depth 1`; `git clone --branch <SHA>` cannot check out a raw commit.
- A GitHub OAuth credential without `workflow` scope cannot push workflow
  edits over HTTPS. Use the user's configured SSH remote when available.
- The Linux script explicitly starts `ubuntu:22.04` with `sleep infinity` and
  verifies GCC 12/Python 3.12 inside it; local Docker on Apple Silicon is ARM64
  and does not replace the native x86_64 GitHub runner.
