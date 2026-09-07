#!/usr/bin/env bash
# build.sh — Download model weights, build OCI ModelCar image, push to Quay.
#
# Usage:
#   ./build.sh [TAG] [MODEL_ID]
#
# Examples:
#   ./build.sh                          # Granite 4.1 3B, tag :v1 + :latest
#   ./build.sh granite42-v1 ibm-granite/granite-4.2-3b
#                                       # Granite 4.2 3B, tag :granite42-v1 + :granite42-latest
#
# Or use the convenience wrappers:
#   ./build-granite41.sh                # builds 4.1 with the right tags
#   ./build-granite42.sh                # builds 4.2 with the right tags
#
# Prerequisites:
#   - python3 with huggingface_hub installed
#   - podman (native on Linux; podman machine on macOS)
#   - Logged in to Quay: podman login quay.io
#   - Logged in to HF: hf auth login (or export HF_TOKEN)
#
# Compatible with macOS (zsh/bash) and Linux. Uses BSD-friendly flags.
#
# Both model versions live in the SAME Quay repo, distinguished by tag:
#   granite-4.1-3b  ->  :v1 / :latest              (the proven default)
#   granite-4.2-3b  ->  :granite42-v1 / :granite42-latest  (reasoning model)
# This lets you pivot between them by changing only the storageUri tag in
# manifests/05-inferenceservice.yaml — no separate repo, no rebuild churn.

set -euo pipefail

MODEL_ID="${2:-ibm-granite/granite-4.1-3b}"
IMAGE_REPO="quay.io/ryan_nix/granite4-llm"
TAG="${1:-v1}"

# The "floating" convenience tag pushed alongside the explicit TAG.
# For 4.2 builds we keep a separate floating tag so :latest always means
# the proven 4.1 model unless you deliberately move it.
case "${MODEL_ID}" in
  *granite-4.2-*) FLOATING_TAG="granite42-latest" ;;
  *)              FLOATING_TAG="latest" ;;
esac

BUILD_DIR="$(cd "$(dirname "$0")" && pwd)"
# Version-specific model dir: a slug derived from the model ID. This keeps
# 4.1 and 4.2 weights in separate directories so switching MODEL_ID never
# reuses stale weights from the other version.
MODEL_SLUG="$(echo "${MODEL_ID}" | tr '/' '-' | tr '[:upper:]' '[:lower:]')"
MODEL_DIR="${BUILD_DIR}/model-${MODEL_SLUG}"

echo ">>> Build directory: ${BUILD_DIR}"
echo ">>> Model ID:        ${MODEL_ID}"
echo ">>> Image:           ${IMAGE_REPO}:${TAG}"
echo ">>> Floating tag:    ${IMAGE_REPO}:${FLOATING_TAG}"

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

MIN_EXPECTED_BYTES=$((3 * 1024 * 1024 * 1024))  # 3 GB floor
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
#
# The Containerfile copies from ./model (a fixed path in the build context).
# We point ./model at the version-specific directory via a symlink so the
# same Containerfile builds either version without edits.
# ---------------------------------------------------------------------------
echo ">>> Linking ${MODEL_DIR} -> ${BUILD_DIR}/model for the build context..."
rm -f "${BUILD_DIR}/model"
ln -s "${MODEL_DIR}" "${BUILD_DIR}/model"

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

# 5. Also push the floating tag (:latest for 4.1, :granite42-latest for 4.2).
echo ">>> Tagging and pushing :${FLOATING_TAG}..."
podman tag "${IMAGE_REPO}:${TAG}" "${IMAGE_REPO}:${FLOATING_TAG}"
podman push \
  --retry "${PUSH_RETRY_TIMES}" \
  --retry-delay "${PUSH_RETRY_DELAY}" \
  "${IMAGE_REPO}:${FLOATING_TAG}"

# ---------------------------------------------------------------------------
# Done.
# ---------------------------------------------------------------------------
echo ""
echo ">>> Done. Image pushed to ${IMAGE_REPO}:${TAG} and ${IMAGE_REPO}:${FLOATING_TAG}"
echo ">>> Update manifests/05-inferenceservice.yaml storageUri to:"
echo ">>>   oci://${IMAGE_REPO}:${TAG}"
echo ""
echo ">>> IMPORTANT: Make sure the Quay repo is set to PUBLIC:"
echo ">>>   https://quay.io/repository/ryan_nix/granite4-llm?tab=settings"
