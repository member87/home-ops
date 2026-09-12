#!/usr/bin/env bash
# Build every path referenced by the Flux entrypoint, so a broken kustomization
# is caught before it reaches the cluster.
#
#   scripts/validate-flux-manifests.sh            # build only
#   scripts/validate-flux-manifests.sh --diff     # also server-side diff against the live cluster
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

mode="${1:-build}"
paths=$(grep -h '^  path:' flux/cluster/*.yaml | awk '{print $2}' | sort -u)
paths="$paths ./flux/cluster"

failed=0
for path in $paths; do
  if ! out=$(kubectl kustomize "$path" 2>&1); then
    printf 'FAIL  %s\n%s\n' "$path" "$out" >&2
    failed=1
    continue
  fi
  objects=$(printf '%s\n' "$out" | grep -c '^kind:' || true)
  printf 'ok    %-48s %s objects\n' "$path" "$objects"

  if [ "$mode" = "--diff" ]; then
    kubectl diff --server-side --force-conflicts \
      --field-manager=kustomize-controller -k "$path" 2>/dev/null || true
  fi
done

if [ "$failed" -ne 0 ]; then
  echo "==> validation failed" >&2
  exit 1
fi
echo "==> all paths build"
