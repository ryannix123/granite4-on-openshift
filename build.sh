#!/usr/bin/env bash
# build.sh — Download model weights, build OCI ModelCar image, push to Quay.
#
# Usage:
#   ./build.sh [TAG]
#
# Examples:
#   ./build.sh v1          # tag as v1
#   ./build.sh             # defaults to v1
#
# Prerequisites:
#   - python3 with huggingface_hub installed
#   - podman (native on Linux; podman machine on macOS)
#   - Logged in to Quay: podman login quay.io
#   - Logged in to HF: hf auth login (or export HF_TOKEN)
#
# Compatible with macOS (zsh/bash) and Linux. Uses BSD-friendly flags.

set -euo pipefail

# IBM's official FP8 quantization of granite-4.1-3b (Apache 2.0).
# Halves weight memory (~6.4 GiB -> ~3.2 GiB), which is what makes 32k
# context fit on an 8 GB card once OLS starts injecting RAG chunks.
# It also halves the ModelCar image size, which matters for mirroring
# into a disconnected registry.
MODEL_ID="ibm-granite/granite-4.1-3b-fp8"
IMAGE_REPO="quay.io/ryan_nix/granite4-llm"
TAG="${1:-v1}"

BUILD_DIR="$(cd "$(dirname "$0")" && pwd)"
MODEL_DIR="${BUILD_DIR}/model"

echo ">>> Build directory: ${BUILD_DIR}"
echo ">>> Image: ${IMAGE_REPO}:${TAG}"

# ---------------------------------------------------------------------------
# 1. Download model from Hugging Face if not already present.
#
# We invoke the Python API directly rather than the CLI. The `hf` CLI
# (1.x) has broken `--exclude` semantics — it treats the patterns as
# include filters instead of exclude filters, silently downloading zero
# files. The Python `snapshot_download()` function has a stable
# `ignore_patterns` kwarg that does what we want.
# ---------------------------------------------------------------------------
if [ ! -f "${MODEL_DIR}/config.json" ]; then
  echo ">>> Downloading ${MODEL_ID} from Hugging Face..."
  mkdir -p "${MODEL_DIR}"

  # Verify huggingface_hub is installed.
  if ! python3 -c "import huggingface_hub" 2>/dev/null; then
    echo "ERROR: huggingface_hub Python package not found." >&2
    echo "Install with: pip install --user --upgrade huggingface_hub" >&2
    exit 1
  fi

  # Call snapshot_download via inline Python. Ignores quantized GGUF and
  # legacy PyTorch .bin files — vLLM uses safetensors. Ignores
  # original/* which is the pre-conversion checkpoint.
  python3 - <<PYEOF
from huggingface_hub import snapshot_download
import os

model_id = "${MODEL_ID}"
local_dir = "${MODEL_DIR}"

path = snapshot_download(
    repo_id=model_id,
    local_dir=local_dir,
    ignore_patterns=["*.gguf", "*.bin", "original/*"],
    allow_patterns=None,
)
print(f"Downloaded to: {path}")
PYEOF
  echo ">>> Download complete."
else
  echo ">>> Model files already present in ${MODEL_DIR}, skipping download."
fi

# ---------------------------------------------------------------------------
# 2. Show what we're about to package (sanity check before building).
# ---------------------------------------------------------------------------
echo ">>> Model directory contents:"
ls -lh "${MODEL_DIR}"
echo ">>> Total size:"
du -sh "${MODEL_DIR}"

# Sanity check: model weights should be multiple GB. If the download
# silently failed (wrong repo ID, auth issue, gated model not accepted),
# the directory will be tiny. Bail loudly so we don't waste time building
# and pushing an empty image.
#
# Uses `stat` with two syntaxes to stay portable: BSD stat (-f %z) on
# macOS, GNU stat (--format=%s) on Linux. No `du -b` because that's
# GNU-only and silently breaks on macOS.
echo ">>> Running sanity check on model size..."
if stat -f %z "${MODEL_DIR}" >/dev/null 2>&1; then
  # macOS / BSD stat
  MODEL_SIZE_BYTES=$(find "${MODEL_DIR}" -type f -exec stat -f %z {} + | awk 'BEGIN{s=0} {s+=$1} END{print s}')
else
  # GNU stat
  MODEL_SIZE_BYTES=$(find "${MODEL_DIR}" -type f -exec stat --format=%s {} + | awk 'BEGIN{s=0} {s+=$1} END{print s}')
fi

MIN_EXPECTED_BYTES=$((2 * 1024 * 1024 * 1024))  # 2 GB floor (FP8 weights are ~3.2 GB)
if [ "${MODEL_SIZE_BYTES:-0}" -lt "${MIN_EXPECTED_BYTES}" ]; then
  echo "" >&2
  echo "ERROR: Model directory is suspiciously small (< 3 GB)." >&2
  echo "       Actual size: ${MODEL_SIZE_BYTES} bytes" >&2
  echo "" >&2
  echo "       Model weights should be 3-16 GB. This usually means:" >&2
  echo "         1. Wrong HF repo ID (check case sensitivity)" >&2
  echo "         2. Not logged in: run 'hf auth login'" >&2
  echo "         3. Model license not accepted at:" >&2
  echo "            https://huggingface.co/${MODEL_ID}" >&2
  echo "" >&2
  echo "       Delete the model/ directory and re-run after fixing the issue." >&2
  exit 1
fi
echo ">>> Sanity check passed: model is ${MODEL_SIZE_BYTES} bytes ($(echo "scale=1; ${MODEL_SIZE_BYTES} / 1073741824" | bc)G)."

# ---------------------------------------------------------------------------
# 3. Build the image.
# ---------------------------------------------------------------------------
echo ">>> Building OCI image..."
podman build \
  --platform linux/amd64 \
  -t "${IMAGE_REPO}:${TAG}" \
  -f "${BUILD_DIR}/Containerfile" \
  "${BUILD_DIR}"

# ---------------------------------------------------------------------------
# 4. Push to Quay using `podman push --retry`.
#
# Pushing large model images over residential upload links is fragile.
# Podman 5.x supports --retry and --retry-delay natively, which retries
# each blob upload on transient errors rather than restarting from zero.
#
# Tip: If pushing from macOS is slow (iCloud competing for bandwidth,
# podman VM overhead), push from a RHEL bastion host instead. Native
# podman on Linux avoids VM storage and bandwidth issues entirely.
# ---------------------------------------------------------------------------
PUSH_RETRY_TIMES="${PUSH_RETRY_TIMES:-5}"
PUSH_RETRY_DELAY="${PUSH_RETRY_DELAY:-10s}"

echo ">>> Pushing ${IMAGE_REPO}:${TAG} via podman (retries: ${PUSH_RETRY_TIMES}, delay: ${PUSH_RETRY_DELAY})..."
podman push \
  --retry "${PUSH_RETRY_TIMES}" \
  --retry-delay "${PUSH_RETRY_DELAY}" \
  "${IMAGE_REPO}:${TAG}"

# 5. Also push the :latest tag for convenience.
echo ">>> Tagging and pushing :latest..."
podman tag "${IMAGE_REPO}:${TAG}" "${IMAGE_REPO}:latest"
podman push \
  --retry "${PUSH_RETRY_TIMES}" \
  --retry-delay "${PUSH_RETRY_DELAY}" \
  "${IMAGE_REPO}:latest"

# ---------------------------------------------------------------------------
# Done.
# ---------------------------------------------------------------------------
echo ""
echo ">>> Done. Image pushed to ${IMAGE_REPO}:${TAG} and ${IMAGE_REPO}:latest"
echo ">>> Update manifests/05-inferenceservice.yaml storageUri to:"
echo ">>>   oci://${IMAGE_REPO}:${TAG}"
echo ""
echo ">>> IMPORTANT: Make sure the Quay repo is set to PUBLIC:"
echo ">>>   https://quay.io/repository/ryan_nix/granite4-llm?tab=settings"