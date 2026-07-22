#!/usr/bin/env bash
set -euo pipefail

# Ensures parity guardrails can read a live AndBible checkout. By default the
# checkout lives next to this repository at ../and-bible; ANDBIBLE_ANDROID_ROOT,
# ANDBIBLE_ANDROID_REPO_URL, and ANDBIBLE_ANDROID_REF can override that setup.
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "${SCRIPT_DIR}/.." && pwd)"

android_root_input="${1:-${ANDBIBLE_ANDROID_ROOT:-${REPO_ROOT}/../and-bible}}"
android_repo_url="${ANDBIBLE_ANDROID_REPO_URL:-https://github.com/AndBible/and-bible.git}"

if [[ "${android_root_input}" == "~" || "${android_root_input}" == "~/"* ]]; then
  android_root_input="${HOME}${android_root_input:1}"
fi

if [[ "${android_root_input}" = /* ]]; then
  android_root="${android_root_input}"
else
  android_root="${REPO_ROOT}/${android_root_input}"
fi

if git_root="$(git -C "${android_root}" rev-parse --show-toplevel 2>/dev/null)"; then
  canonical_git_root="$(cd -- "${git_root}" && pwd -P)"
  canonical_android_root="$(cd -- "${android_root}" && pwd -P)"
  if [[ "${canonical_git_root}" != "${canonical_android_root}" ]]; then
    echo "Android reference path is inside a git checkout but is not the checkout root: ${android_root}" >&2
    echo "Checkout root: ${canonical_git_root}" >&2
    exit 2
  fi

  update_ref="${ANDBIBLE_ANDROID_REF:-}"
  if [[ -z "${update_ref}" ]] && git -C "${android_root}" config --get remote.origin.url >/dev/null; then
    update_ref="HEAD"
  fi

  if [[ -n "${update_ref}" ]]; then
    if ! git -C "${android_root}" diff --quiet || ! git -C "${android_root}" diff --cached --quiet; then
      echo "Android reference checkout has local modifications: ${android_root}" >&2
      echo "Commit, stash, or point ANDBIBLE_ANDROID_ROOT at a clean reference checkout." >&2
      exit 2
    fi

    echo "Updating Android reference checkout to ${update_ref}: ${android_root}"
    git -C "${android_root}" fetch --depth 1 "${android_repo_url}" "${update_ref}"
    git -C "${android_root}" checkout --detach --quiet FETCH_HEAD
    echo "Android reference checkout ready: ${android_root}"
  else
    echo "Android reference checkout already available: ${android_root}"
  fi
  exit 0
fi

if [[ -e "${android_root}" ]] && [[ -n "$(ls -A "${android_root}")" ]]; then
  echo "Android reference path exists but is not a git checkout: ${android_root}" >&2
  exit 2
fi

mkdir -p "$(dirname -- "${android_root}")"

if [[ -n "${ANDBIBLE_ANDROID_REF:-}" ]]; then
  echo "Creating Android reference checkout at ${ANDBIBLE_ANDROID_REF}: ${android_root}"
  git init --quiet "${android_root}"
  git -C "${android_root}" remote add origin "${android_repo_url}"
  git -C "${android_root}" fetch --depth 1 "${android_repo_url}" "${ANDBIBLE_ANDROID_REF}"
  git -C "${android_root}" checkout --detach --quiet FETCH_HEAD
else
  echo "Cloning Android reference checkout into ${android_root}"
  git clone --depth 1 "${android_repo_url}" "${android_root}"
fi
