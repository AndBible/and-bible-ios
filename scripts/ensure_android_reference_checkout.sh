#!/usr/bin/env bash
set -euo pipefail

# Ensures parity guardrails can read a live AndBible checkout. By default the
# checkout lives next to this repository at ../and-bible; ANDBIBLE_ANDROID_ROOT,
# ANDBIBLE_ANDROID_REPO_URL, and ANDBIBLE_ANDROID_REF can override that setup.
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "${SCRIPT_DIR}/.." && pwd)"

android_root_input="${1:-${ANDBIBLE_ANDROID_ROOT:-${REPO_ROOT}/../and-bible}}"
android_repo_url="${ANDBIBLE_ANDROID_REPO_URL:-https://github.com/AndBible/and-bible.git}"

if [[ "${android_root_input}" = /* ]]; then
  android_root="${android_root_input}"
else
  android_root="${REPO_ROOT}/${android_root_input}"
fi

if git -C "${android_root}" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  echo "Android reference checkout already available: ${android_root}"
  exit 0
fi

if [[ -e "${android_root}" ]] && [[ -n "$(ls -A "${android_root}")" ]]; then
  echo "Android reference path exists but is not a git checkout: ${android_root}" >&2
  exit 2
fi

mkdir -p "$(dirname -- "${android_root}")"

clone_args=(--depth 1)
if [[ -n "${ANDBIBLE_ANDROID_REF:-}" ]]; then
  clone_args+=(--branch "${ANDBIBLE_ANDROID_REF}")
fi

echo "Cloning Android reference checkout into ${android_root}"
git clone "${clone_args[@]}" "${android_repo_url}" "${android_root}"
