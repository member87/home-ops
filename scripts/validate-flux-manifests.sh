#!/usr/bin/env bash
# Gate for the manifest layout. Catches the bug classes this repo has actually hit:
#   - a file on disk that no kustomization.yaml references (the old Helm glob applied it,
#     kustomize silently will not)
#   - a kustomization.yaml entry pointing at a file that does not exist
#   - a component Kustomization that never reaches the entrypoint build
#   - a namespaced object with no explicit metadata.namespace
#   - an edit inside a ChartVersion chart dir with no Chart.yaml version bump, which Flux
#     would accept and never deploy
#
#   scripts/validate-flux-manifests.sh            # build + layout checks
#   scripts/validate-flux-manifests.sh --diff     # also server-side diff against the cluster
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

mode="${1:-build}"
case "$mode" in
  build|--diff) ;;
  *) echo "usage: $(basename "$0") [--diff]" >&2; exit 2 ;;
esac

need() { command -v "$1" >/dev/null || { echo "missing required tool: $1" >&2; exit 2; }; }
need kubectl
need yq

failed=0
fail() { printf 'FAIL  %s\n' "$*" >&2; failed=1; }

# 1. The entrypoint must build, and every Kustomization declared on disk must survive it.
#    (Dropping a file from flux/cluster/kustomization.yaml would otherwise pass unnoticed.)
if ! entrypoint=$(kubectl kustomize ./flux/cluster 2>&1); then
  printf 'FAIL  ./flux/cluster does not build\n%s\n' "$entrypoint" >&2
  exit 1
fi
mapfile -t paths < <(printf '%s\n' "$entrypoint" \
  | yq -r 'select(.apiVersion == "kustomize.toolkit.fluxcd.io/v1" and .kind == "Kustomization") | .spec.path' \
  | grep -vx -- '---' | sort -u)
declared=$(grep -h '^  path:' flux/cluster/*.yaml | awk '{gsub(/"/, "", $2); print $2}' | sort -u | wc -l)
if [ "${#paths[@]}" -ne "$declared" ]; then
  fail "${#paths[@]} of $declared declared Kustomizations reach the entrypoint build"
fi
printf 'ok    entrypoint builds, %s component Kustomizations\n' "${#paths[@]}"

# Cluster-scoped kinds are the only ones allowed to omit metadata.namespace.
cluster_scoped=""
if kubectl api-resources --namespaced=false --no-headers >/dev/null 2>&1; then
  cluster_scoped=$(kubectl api-resources --namespaced=false --no-headers | awk '{print $NF}' | sort -u)
fi

for path in "${paths[@]}"; do
  if ! out=$(kubectl kustomize "$path" 2>&1); then
    fail "$path does not build: $(printf '%s' "$out" | tail -1)"
    continue
  fi
  objects=$(printf '%s\n' "$out" | yq -r 'select(.kind != null) | .kind' | grep -cvx -- '---' || true)
  [ "$objects" -gt 0 ] || fail "$path renders 0 objects"

  # 2. Every YAML on disk in that directory must be reachable from its kustomization.yaml.
  if [ -f "$path/kustomization.yaml" ]; then
    referenced=$(yq -r '[(.resources // [])[], (.components // [])[],
                         ((.configMapGenerator // [])[] | (.files // [])[], (.envs // [])[]),
                         ((.secretGenerator // [])[] | (.files // [])[], (.envs // [])[]),
                         ((.patches // [])[] | .path // "")] | .[]' \
                 "$path/kustomization.yaml" 2>/dev/null | sed 's/.*=//' | sort -u)
    while read -r file; do
      [ -n "$file" ] || continue
      case "$file" in kustomization.yaml) continue ;; esac
      printf '%s\n' "$referenced" | grep -qxF "$file" \
        || fail "$path/$file is on disk but referenced by no kustomization.yaml entry"
    done < <(cd "$path" && find . -maxdepth 1 -name '*.yaml' -printf '%f\n' | sort)
  fi

  # 3. No namespaced object may rely on an implicit namespace.
  if [ -n "$cluster_scoped" ]; then
    while read -r kind name; do
      [ -n "$kind" ] || continue
      case "$kind" in ---) continue ;; esac
      printf '%s\n' "$cluster_scoped" | grep -qxF -- "$kind" \
        || fail "$path renders $kind/$name without metadata.namespace"
    done < <(printf '%s\n' "$out" | yq -r 'select(.metadata.namespace == null and .kind != null)
                                            | .kind + " " + .metadata.name')
  fi

  printf 'ok    %-44s %s objects\n' "$path" "$objects"

  if [ "$mode" = "--diff" ]; then
    kubectl diff --server-side --force-conflicts \
      --field-manager=kustomize-controller -k "$path" >/dev/null 2>&1 || rc=$?
    case "${rc:-0}" in
      0) ;;
      1) printf '      drift vs cluster (run kubectl diff -k %s to inspect)\n' "$path" ;;
      *) fail "kubectl diff errored for $path (rc=${rc})" ;;
    esac
    unset rc
  fi
done

# 4. Git-sourced HelmReleases use reconcileStrategy: ChartVersion, so a change inside one of
#    those chart dirs only deploys if Chart.yaml's version moves. Catch the silent no-deploy.
base="${VALIDATE_BASE:-origin/main}"
if git rev-parse --verify -q "$base" >/dev/null 2>&1; then
  while read -r chart; do
    dir=$(dirname "$chart")
    changed=$(git diff --name-only "$base...HEAD" -- "$dir" | grep -v '^$' || true)
    [ -n "$changed" ] || continue
    if ! git diff -U0 "$base...HEAD" -- "$chart" | grep -q '^[+-]version:'; then
      fail "$dir changed without a Chart.yaml version bump: ChartVersion means it will not deploy"
    fi
  done < <(git ls-files '*/Chart.yaml')
else
  printf 'note  %s not available, skipped the Chart.yaml version-bump check\n' "$base"
fi

if [ "$failed" -ne 0 ]; then
  echo "==> validation failed" >&2
  exit 1
fi
echo "==> ok"
