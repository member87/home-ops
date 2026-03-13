# ArgoCD to FluxCD Migration (HelmRelease)

This repository now contains a Flux migration scaffold that keeps workloads safe by default.

## What is staged

- Every existing Argo application (except `root-app`) has a matching Flux `HelmRelease` in `flux/apps/helmreleases.yaml`.
- All `HelmRelease` objects are created with `spec.suspend: true` so nothing reconciles until you explicitly opt in.
- Existing manifest directories are wrapped as Helm charts by adding `Chart.yaml` and `templates/manifests.yaml`.
- Chart-based apps are represented as chart wrappers with dependencies:
  - `charts/cert-manager`
  - `apps/podinfo`
  - `apps/pihole`
  - `infrastructure/longhorn`

## Flux bootstrap manifests

- Git source: `flux/system/gitrepository.yaml`
- Flux Kustomization: `flux/system/flux-kustomization.yaml`
- Kustomize entrypoint: `flux/system/kustomization.yaml`

## Safe rollout sequence

1. Install Flux controllers and CRDs.
2. Apply `flux/system` resources.
3. Confirm Flux source and kustomization are ready.
4. Unsuspend one low-risk app HelmRelease (canary).
5. Validate health, traffic, and restarts.
6. Continue app-by-app in waves.
7. Remove Argo finalizers before deleting Argo `Application` objects.

## Canary commands

```bash
# unsuspend one release
kubectl -n flux-system patch helmrelease <name> --type merge -p '{"spec":{"suspend":false}}'

# check release health
kubectl -n flux-system get helmrelease <name>
kubectl -n flux-system describe helmrelease <name>

# re-suspend quickly if needed
kubectl -n flux-system patch helmrelease <name> --type merge -p '{"spec":{"suspend":true}}'
```
