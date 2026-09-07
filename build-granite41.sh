#!/usr/bin/env bash
# build-granite41.sh — Build the PROVEN Granite 4.1 3B image.
# Tags: :v1 (or your arg) and :latest
# This is the default OLS backend that passed the 95% validation suite.
set -euo pipefail
TAG="${1:-v1}"
exec "$(dirname "$0")/build.sh" "${TAG}" "ibm-granite/granite-4.1-3b"
