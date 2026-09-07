#!/usr/bin/env bash
# build-granite42.sh — Build the NEW Granite 4.2 3B reasoning model image.
# Tags: :granite42-v1 (or your arg) and :granite42-latest
# Keeps :latest pointing at the proven 4.1 model — switch by changing the
# storageUri tag in manifests/05-inferenceservice.yaml, then redeploy.
set -euo pipefail
TAG="${1:-granite42-v1}"
exec "$(dirname "$0")/build.sh" "${TAG}" "ibm-granite/granite-4.2-3b"
