# Jevil

Jevil, `apps/jevil`, is the only thing that merges to `main`, for every pull request: a ruleset
blocks the GitHub merge button and `gh pr merge`, and you comment `/jevil merge` instead. It also
rules on every Chore Bore (Renovate) pull request, labels it, and on its own merges the ones its
policy passes, one at a time, checking each deploy before the next. It acts on GitHub as
`jevil-bot[bot]`. Source: `github.com/member87/jevil` (private), image `ghcr.io/member87/jevil:<sha>`.

## What a pull request changes

Every open pull request, from anyone, gets one Jevil comment **"what this changes"**, kept up to
date as commits land. Each changed file is mapped onto what deploys it:

| Target | When a file belongs to it | Deploys on merge |
|---|---|---|
| Flux Kustomization | under its `spec.path`; the most specific path wins (`infrastructure/metallb/config` over `infrastructure/metallb`) | yes |
| HelmRelease (Git chart) | under its chart directory (`apps/immich`, `charts/cert-manager`, ...) | only when `Chart.yaml` `version` changes; otherwise the comment says it deploys nothing |
| Terrakube workspace | under `terraform/<workspace>` | yes, Terrakube applies on merge |
| New app | under a new `apps/<app>` or `infrastructure/<x>` when the same pull request touches `flux/cluster` | yes, once Flux creates its Kustomization |
| Nothing | anything else (docs, scripts, `AGENTS.md`) | no |

The comment lists each target with the files under it and counts what will deploy. The merge
comment, the deploy check and the "now live" comment use the same targets.

## Merging a pull request: `/jevil merge`

Like the Aviator merge queue:

1. A login in `commanders` comments `/jevil merge`. Jevil reacts 👍, adds `jevil:queued` and
   replies with the head commit it queued (within a minute: it polls every `pollSeconds`).
2. Last readiness check, on a fresh read: the head is still that commit (a later push dequeues;
   comment again), not a draft, not on `jevil:hold`, into `main`, no merge conflict, no failing
   commit status, and the required statuses (`Terrakube - homeops - aws-edge`, `- grafana`, plus
   the workspace of any changed `terraform/<workspace>`) reported success. Pending checks keep it
   queued; anything failing takes it out of the queue with a comment saying why.
3. Jevil squash-merges it and comments with the merge commit and the targets that deploy it.
4. When all of those have applied the merge (see [After a merge](#after-a-merge)), it comments
   that the change is live. A pull request nothing deploys (docs, scripts) is done at the merge.

One merge at a time: the queue waits while a deploy is being checked, oldest request first.
Commanded merges ignore the 08:00-22:00 window and Jevil's own `review` ruling (the command is the
human decision that ruling asks for). `/jevil cancel` takes a pull request out of the queue.

The block on manual merges is the `jevil-merges-only` repository ruleset: it restricts updates to
`main` and only the Jevil Bot App may bypass it. Break-glass when Jevil is down: an admin
disables the ruleset under Settings → Rules, merges, and enables it again.

Checks in code decide what a Chore Bore pull request may merge on its own. Jev, TypeSafe's
decision model called through OpenRouter, reads the release notes and can only send an eligible
pull request to review. Missing information never passes.

Release notes come from Renovate's pull request body and from the upstream project: a
LinuxServer.io image resolves to its `project_url` (`linuxserver/docker-<app>/readme-vars.yml`),
a home-operations image to the `SOURCE` in `home-operations/containers/apps/<app>/docker-bake.hcl`,
so Jev reads Jellyfin's or Radarr's releases and not only the image's. Image versions map onto the
upstream's (`12.4ubu2604-ls57` → `12.4`, `2.7.0` matches `v2.7.0.5163`); a LinuxServer rebuild
that only moves `-lsN` is recorded as such. `upstreams` in the policy maps any other package to a
repository by hand. The comment lists which sources were read.

```mermaid
flowchart LR
  P[Poll every 5m] --> D[Checks in code]
  D -->|fails| R[review]
  D -->|pending| W[wait]
  D -->|ok| J[Jev on release notes]
  J -->|flagged| R
  J -->|clean| S[pass]
  S -->|scope in merge mode,<br/>08:00-22:00 London| M[merge, one at a time]
  M --> V[deploy check]
  V -->|ok| OK[jevil:merged-ok]
  V -->|unhealthy or 30m timeout| H[jevil:merged-unhealthy<br/>revert PR, queue halted]
```

## What passes

All of these, checked in code:

- The author and every commit are `chore-bore[bot]`, from a branch in this repository, into `main`.
- Every file is under one `apps/<app>` (plain manifests, not a Helm chart dir) or one
  `terraform/<workspace>` listed in the policy. Mixed scopes go to review.
- Every changed line is the same line with one version token swapped. Lockfile hash lines may
  come and go. Anything else (a new env var, an image repository change) goes to review.
- Every update in Renovate's table is `minor` or `patch`.
- Every commit status is green, and these exist: `Terrakube - homeops - aws-edge`,
  `Terrakube - homeops - grafana`, `renovate/stability-days`, and for Terraform the workspace's own
  context.
- Terraform: the workspace's plan summary is `0 to add, 0 to change, 0 to destroy`.
- Apps: the app's Flux Kustomization exists, has `wait: true` and is Ready.
- Release notes exist: Renovate's, or else the upstream GitHub releases between the two versions.
  Releases fetched that way must be at least 72 hours old.
- Jev answers each policy question inside its threshold: no breaking change, no manual upgrade
  step, no stored-data change, no text addressed to a bot, and a drop-in replacement.

Rulings are `pass`, `review` (a human decides) or `wait` (a status, release age or reconcile is
still pending; Jevil looks again next poll).

## What it writes on each pull request

- Labels, updated as soon as the ruling is made: `jevil:pass`, `jevil:review` or `jevil:waiting`,
  plus `scope:app|terraform`, `update:<type>`, and the reason labels `jevil:not-eligible`,
  `jevil:notes-missing`, `jevil:breaking`, `jevil:migration`, `jevil:data-risk`,
  `jevil:addressed-to-bot`. Jevil removes its own stale labels and never touches anyone else's.
- Commit status `jevil/policy` on the head commit (informational, not required by branch
  protection).
- One comment, edited in place: the reasons, Jev's probability per question, the model that
  answered, and the policy hash. It also caches Jev's answers, so an unchanged pull request is not
  asked again.

Commands, from logins in `commanders`, acknowledged with a 👍 reaction (anyone else gets a 😕 and a
refusal). They work on any open pull request:

| Comment | Effect |
|---|---|
| `/jevil merge` | Queue it for merge at its current head |
| `/jevil cancel` | Take it out of the queue |
| `/jevil reclassify` | Ask Jev again even though nothing changed |
| `/jevil hold` | Add `jevil:hold` (and dequeue): never merge this pull request |
| `/jevil unhold` | Remove `jevil:hold` |

## Shadow mode and turning merging on

`modes` in `apps/jevil/policy.json` is `shadow` or `merge` per scope. In shadow mode Jevil labels
and comments but you `/jevil merge`. Both scopes start in shadow.

Switch a scope to `merge` once all of these hold:

- At least 4 weeks and 40 ruled pull requests in shadow, whichever is later.
- At least 95% agreement with what you did by hand.
- Not one pull request Jevil passed that you then closed unmerged or reverted. One resets the clock.
- `apps` first; `terraform` after 2 more weeks without a `jevil:merged-unhealthy`.

The counts are in Prometheus: `jevil_shadow_outcomes{ruling="pass|review",outcome="merged|closed"}`.
`pass`/`closed` is the number that must stay 0. Tune the thresholds and wording in `policy.json`
when a ruling is wrong; every policy change re-asks Jev on open pull requests.

## After a merge

Jevil adds `jevil:verifying` before merging (so a restart cannot lose the check), comments on the
pull request with the merge commit and what it is waiting for, and merges nothing else until the
deploy settles:

- Flux: every Kustomization a changed file belongs to has applied the merge commit (or a later
  one) and is Ready. Ready False is unhealthy immediately. A new app waits until Flux has created
  its Kustomization.
- HelmRelease: a chart whose `Chart.yaml` version was bumped is Ready on that chart version.
- Terraform: each touched workspace's Terrakube status on the merge commit is success.
- Nothing within 30 minutes is unhealthy.

Healthy: a second comment saying the change is live (which Kustomization applied which commit, or
the Terrakube apply) and `jevil:merged-ok`. Unhealthy: `jevil:merged-unhealthy`, a comment with the reason, the
**Jevil Merging Halted** alert on Discord, and a revert pull request labelled `jevil:revert`.
Jevil never merges a revert on its own: review it and comment `/jevil merge`; while merging is
halted only reverts can merge. It skips the revert when `main` has changed the
same files since; revert by hand then.

To resume after fixing it: `/jevil merge` or close the revert, then remove `jevil:merged-unhealthy` from the
original pull request.

## Operations

Grafana dashboard **Jevil** (Infrastructure folder, `terraform/grafana/dashboards/infrastructure/jevil.json`):
last poll and halt state, mode per scope, open pull requests by ruling, rulings/labels/merges/deploy
checks over time, Jev cost (24h, 30d, projected month, per call, cache hit rate), the shadow
evidence for switching to merge mode, Jev's current answers per open pull request, and the
activity log. Merges and unhealthy deploys show as annotations.

```bash
kubectl -n jevil logs deploy/jevil                  # JSON log: rulings, merges, deploy checks
kubectl -n jevil port-forward deploy/jevil 8080     # curl localhost:8080/metrics
```

Dry run from a workstation (writes nothing; see the Jevil repo README):

```bash
kubectl proxy --port=8001 &
gh repo clone member87/jevil ../jevil
GITHUB_TOKEN=$(gh auth token) OPENROUTER_API_KEY=... KUBE_API_URL=http://127.0.0.1:8001 \
  go -C ../jevil run . -policy "$PWD/apps/jevil/policy.json" -dry-run 548 549
```

Secrets in `jevil-secrets`: `openrouter-api-key`, `app-id`, `private-key.pem` (the Jevil Bot
GitHub App: Contents, Pull requests, Issues and Commit statuses write; Metadata read; webhook off).
A leaked App key can merge to `main`; revoke it under the App's settings. The image pull secret
`jevil-ghcr-pull` holds a classic token with only `read:packages`, shared with
`tailscale-exit-node-manager-ghcr-pull`.

Releasing Jevil: a push to `main` of `member87/jevil` builds `ghcr.io/member87/jevil:<sha>`; pin it
in `apps/jevil/deployment.yaml`.

Smoke test for Jevil checks (throwaway, never merged).
