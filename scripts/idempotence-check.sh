#!/usr/bin/env bash
# Usage: scripts/idempotence-check.sh <inventory> <playbook> [limit]
# Applies the playbook, applies it again, and fails if the 2nd run changed anything.
set -euo pipefail
inv="${1:?inventory}"; pb="${2:?playbook}"; limit="${3:-}"
args=(-i "$inv" "$pb"); [ -n "$limit" ] && args+=(--limit "$limit")
ansible-playbook "${args[@]}"
out="$(ansible-playbook "${args[@]}" | tee /dev/stderr)"
if echo "$out" | grep -E 'changed=[1-9]' >/dev/null; then
  echo "NOT IDEMPOTENT: second run reported changes" >&2; exit 1
fi
echo "OK: second run changed nothing"
