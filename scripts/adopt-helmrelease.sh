#!/usr/bin/env bash
# Hand a component over from its HelmRelease to its Flux Kustomization WITHOUT ever
# running `helm uninstall` (which would delete every object in the release, PVCs included).
#
# Why this is safe, in order of importance:
#   1. `spec.suspend: true` is the actual guarantee. helm-controller only uninstalls a
#      deleted release when the object is NOT suspended
#      (helm-controller internal/controller/helmrelease_controller.go: `if !obj.Spec.Suspend`),
#      see https://github.com/fluxcd/flux2/discussions/2373.
#   2. Removing the finalizer is belt-and-braces: it takes the uninstall code path out of
#      the deletion flow entirely. Note helm-controller adds the finalizer before it checks
#      suspend, so the finalizer alone is not a guarantee - the suspend patch must stay.
#   3. The script refuses to touch anything unless the replacement Kustomization is already
#      Ready (so every object is owned by kustomize-controller first), every PV bound in the
#      namespace is on a Retain policy, and the object inventory is unchanged afterwards.
#
#   scripts/adopt-helmrelease.sh sonarr                        # dry run (default)
#   scripts/adopt-helmrelease.sh sonarr --apply
#   scripts/adopt-helmrelease.sh sonarr --apply --purge-history
set -euo pipefail

name="${1:-}"
case "$name" in
  ''|-*) echo "usage: $(basename "$0") <helmrelease-name> [--apply] [--purge-history]" >&2; exit 2 ;;
esac
shift
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
# Kinds a `helm uninstall` of these releases could take with it.
SNAPSHOT_KINDS=deploy,sts,ds,cronjob,job,svc,ingress,pvc,cm,secret,sa,role,rolebinding
run() {
  if [ "$apply" = true ]; then
    printf '  +'; printf ' %q' "$@"; printf '\n'
    "$@"
  else
    printf '  would run:'; printf ' %q' "$@"; printf '\n'
  fi
}
fail() { echo "ABORT: $*" >&2; exit 1; }
snapshot() {
  kubectl get "$SNAPSHOT_KINDS" -n "$1" \
    -o go-template='{{range .items}}{{.kind}}/{{.metadata.name}}{{"\n"}}{{end}}' 2>/dev/null | sort
}

kubectl get helmrelease "$name" -n "$hr_ns" >/dev/null 2>&1 \
  || fail "HelmRelease $hr_ns/$name not found (already adopted?)"

# The workload namespace and the Helm storage namespace are different things: Flux stores
# release history in the HelmRelease's own namespace, not in targetNamespace.
workload_ns=$(kubectl get helmrelease "$name" -n "$hr_ns" -o jsonpath='{.spec.targetNamespace}')
[ -n "$workload_ns" ] || workload_ns="$hr_ns"
storage_ns=$(kubectl get helmrelease "$name" -n "$hr_ns" -o jsonpath='{.status.storageNamespace}')
[ -n "$storage_ns" ] || storage_ns="$hr_ns"
release_name=$(kubectl get helmrelease "$name" -n "$hr_ns" -o jsonpath='{.spec.releaseName}')
[ -n "$release_name" ] || release_name="$name"
chart_obj=$(kubectl get helmrelease "$name" -n "$hr_ns" -o jsonpath='{.status.helmChart}')
echo "==> $name (workload ns $workload_ns, helm history in $storage_ns, release $release_name)"

# Preflight 1: the Kustomization taking over must already be applied and Ready, so every
# object is owned by kustomize-controller before Helm's record of it goes away.
ready=$(kubectl get kustomization "$name" -n "$hr_ns" \
  -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || true)
[ "$ready" = "True" ] || fail "Kustomization $hr_ns/$name is not Ready (got '${ready:-missing}')"
echo "  Kustomization $name is Ready"

# Preflight 2: fail closed. A query error, expired token or RBAC denial must abort, never
# skip the check - this is the only pre-delete data-safety gate.
kubectl get namespace "$workload_ns" >/dev/null 2>&1 \
  || fail "namespace $workload_ns does not exist"
pv_report=$(kubectl get pv -o go-template="{{range .items}}{{if .spec.claimRef}}{{if eq .spec.claimRef.namespace \"$workload_ns\"}}{{.metadata.name}} {{.spec.persistentVolumeReclaimPolicy}}{{\"\n\"}}{{end}}{{end}}{{end}}") \
  || fail "could not list PersistentVolumes (refusing to continue blind)"
pv_count=0
while read -r pv policy; do
  [ -n "$pv" ] || continue
  [ "$policy" = "Retain" ] || fail "PV $pv has reclaimPolicy=$policy (expected Retain)"
  pv_count=$((pv_count + 1))
done <<<"$pv_report"
echo "  $pv_count bound PV(s) in $workload_ns, all reclaimPolicy=Retain"

before=$(snapshot "$workload_ns")
before_count=$(printf '%s\n' "$before" | grep -c . || true)
[ "$before_count" -gt 0 ] || fail "no objects found in $workload_ns (wrong namespace?)"
echo "  $before_count objects in $workload_ns recorded"

# 1. suspend: this is what disarms `helm uninstall` on delete
run kubectl patch helmrelease "$name" -n "$hr_ns" --type=merge \
  -p '{"spec":{"suspend":true}}'

# 2. drop the finalizer so the uninstall code path is not entered at all
run kubectl patch helmrelease "$name" -n "$hr_ns" --type=merge \
  -p '{"metadata":{"finalizers":null}}'

# 3. delete the now-inert HelmRelease object
run kubectl delete helmrelease "$name" -n "$hr_ns" --wait=true

# 4. the HelmChart is only garbage-collected on the non-suspended path, so it is orphaned
#    here; left behind it retries a chart build forever against a deleted chart dir
if [ -n "$chart_obj" ]; then
  run kubectl delete helmchart "${chart_obj#*/}" -n "${chart_obj%/*}" --ignore-not-found
fi

# 5. prove the release took nothing with it
if [ "$apply" = true ]; then
  after=$(snapshot "$workload_ns")
  if ! lost=$(comm -23 <(printf '%s\n' "$before") <(printf '%s\n' "$after")) || [ -n "$lost" ]; then
    printf '%s\n' "$lost" >&2
    fail "objects disappeared from $workload_ns during adoption (see list above)"
  fi
  echo "  all $before_count objects still present"
  kubectl get kustomization "$name" -n "$hr_ns" \
    -o custom-columns=NAME:.metadata.name,READY:'.status.conditions[?(@.type=="Ready")].status' \
    --no-headers
fi

# 6. optional: drop the orphaned Helm release history
history=$(kubectl get secret -n "$storage_ns" -l "owner=helm,name=$release_name" \
  --no-headers 2>/dev/null | wc -l | tr -d ' ')
if [ "$purge" = true ]; then
  run kubectl delete secret -n "$storage_ns" -l "owner=helm,name=$release_name" --ignore-not-found
else
  echo "  $history Helm history secret(s) left in $storage_ns (re-run with --purge-history)"
fi

[ "$apply" = true ] || echo "  dry run only - re-run with --apply"
