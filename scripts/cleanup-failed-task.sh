#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"; repo="${REPO:-$ROOT}"; state_dir="${AUTONOMOUS_CLEANUP_STATE_DIR:-${HOME:-$ROOT}/.openclaw/workspace-junie-live/.openclaw/state/autonomous-cleanup}"; reason="autonomous task failed"
while [[ $# -gt 0 ]]; do case "$1" in --repo) repo="$2"; shift 2;; --state-dir) state_dir="$2"; shift 2;; --reason) reason="$2"; shift 2;; *) exit 2;; esac; done
repo="$(cd "$repo" && pwd)"; mkdir -p "$state_dir"; id="cleanup-$(date -u +%Y%m%dT%H%M%SZ)-$$"
git -C "$repo" status --short --branch --untracked-files=all >"$state_dir/$id-status-before.txt" || true; git -C "$repo" diff --binary >"$state_dir/$id-diff-before.patch" || true; git -C "$repo" ls-files --others --exclude-standard -z | tar --null -C "$repo" -cf "$state_dir/$id-untracked-before.tar" --files-from - 2>/dev/null || true; printf '{"reason":"%s"}\n' "$reason" >"$state_dir/$id.json"
git -C "$repo" reset --hard HEAD >/dev/null; git -C "$repo" clean -fd >/dev/null
git -C "$repo" status --short --branch --untracked-files=all >"$state_dir/$id-status-after.txt" || true
if git -C "$repo" status --porcelain --untracked-files=all | grep -q .; then echo cleanup_status=dirty; exit 1; fi; echo cleanup_status=clean
