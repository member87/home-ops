#!/usr/bin/env bash
# Hand a component over from its HelmRelease to its Flux Kustomization WITHOUT
# ever running `helm uninstall`.
#
# Deleting a HelmRelease normally makes helm-controller uninstall the release,
# which deletes every object in it - PVCs included. The finalizer is what runs
# that uninstall, so this script removes the finalizer BEFORE deleting the
# object. No uninstall is ever queued, nothing is deleted, and the Kustomization
# keeps serving the same manifests it already owns via server-side apply.
#
#   scripts/adopt-helmrelease.sh sonarr              # dry run (default)
#   scripts/adopt-helmrelease.sh sonarr --apply
#   scripts/adopt-helmrelease.sh sonarr --apply --purge-history
set -euo pipefail

name="${1:?usage: adopt-helmrelease.sh <name> [--apply] [--purge-history]}"
shift || true
apply=false
purge=false
for arg in "$@"; do
  case "$arg" in
    --apply) apply=true ;;
    --purge-history) purge=true ;;
    *) echo "unknown flag: $arg" >&2; exit 2 ;;
  esac
done

hr_ns=flux-system
run() {
  if [ "$apply" = true ]; then
    echo "  + $*"
    "$@"
  else
    echo "  would run: $*"
  fi
}
fail() { echo "ABORT: $*" >&2; exit 1; }

kubectl get helmrelease "$name" -n "$hr_ns" >/dev/null 2>&1 \
  || fail "HelmRelease $hr_ns/$name not found (already adopted?)"

release_ns=$(kubectl get helmrelease "$name" -n "$hr_ns" -o jsonpath='{.spec.targetNamespace}')
[ -n "$release_ns" ] || release_ns=$(kubectl get helmrelease "$name" -n "$hr_ns" -o jsonpath='{.status.storageNamespace}')
release_name=$(kubectl get helmrelease "$name" -n "$hr_ns" -o jsonpath='{.spec.releaseName}')
[ -n "$release_name" ] || release_name="$name"
echo "==> $name (helm release $release_ns/$release_name)"

# Preflight 1: the Kustomization that takes over must already be applied and Ready,
# so every object is owned by kustomize-controller before Helm's record goes away.
ready=$(kubectl get kustomization "$name" -n "$hr_ns" \
  -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || true)
[ "$ready" = "True" ] || fail "Kustomization $hr_ns/$name is not Ready (got '${ready:-missing}')"
echo "  Kustomization $name is Ready"

# Preflight 2: no PV in this namespace may be on a Delete reclaim policy, so even a
# stray PVC deletion cannot destroy data.
while read -r pv policy; do
  [ -n "$pv" ] || continue
  [ "$policy" = "Retain" ] || fail "PV $pv has reclaimPolicy=$policy (expected Retain)"
done < <(kubectl get pv -o go-template="{{range .items}}{{if .spec.claimRef}}{{if eq .spec.claimRef.namespace \"$release_ns\"}}{{.metadata.name}} {{.spec.persistentVolumeReclaimPolicy}}{{\"\n\"}}{{end}}{{end}}{{end}}")

pvcs_before=$(kubectl get pvc -n "$release_ns" --no-headers 2>/dev/null | wc -l | tr -d ' ')
echo "  PVCs in $release_ns: $pvcs_before (all backing PVs are Retain)"

# 1. stop reconciliation so helm-controller cannot re-add the finalizer
run kubectl patch helmrelease "$name" -n "$hr_ns" --type=merge \
  -p '{"spec":{"suspend":true}}'

# 2. drop the finalizer: this is what disarms `helm uninstall` on delete
run kubectl patch helmrelease "$name" -n "$hr_ns" --type=merge \
  -p '{"metadata":{"finalizers":null}}'

# 3. delete the now-inert HelmRelease object
run kubectl delete helmrelease "$name" -n "$hr_ns" --wait=true

# 4. prove nothing was taken with it
if [ "$apply" = true ]; then
  pvcs_after=$(kubectl get pvc -n "$release_ns" --no-headers 2>/dev/null | wc -l | tr -d ' ')
  [ "$pvcs_after" = "$pvcs_before" ] \
    || fail "PVC count changed in $release_ns: $pvcs_before -> $pvcs_after"
  echo "  PVCs intact: $pvcs_after"
  kubectl get kustomization "$name" -n "$hr_ns" \
    -o custom-columns=NAME:.metadata.name,READY:'.status.conditions[?(@.type=="Ready")].status' --no-headers
fi

# 5. optional: drop the orphaned Helm release history secrets
if [ "$purge" = true ]; then
  run kubectl delete secret -n "$release_ns" \
    -l "owner=helm,name=$release_name" --ignore-not-found
else
  kept=$(kubectl get secret -n "$release_ns" -l "owner=helm,name=$release_name" \
    --no-headers 2>/dev/null | wc -l | tr -d ' ')
  echo "  $kept Helm history secrets left in place (re-run with --purge-history to remove)"
fi

[ "$apply" = true ] || echo "  dry run only - re-run with --apply"
