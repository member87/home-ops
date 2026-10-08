#!/usr/bin/env bash
# Bring every node to the Talos and Kubernetes versions pinned in talos/controlplane.yaml,
# then apply talos/patches/*.yaml.
#
#   scripts/talos-sync.sh plan  NODES   show drift and the upgrade path, change nothing;
#                                       exits 2 when a node is out of date
#   scripts/talos-sync.sh apply NODES   carry the plan out
#
# NODES is a comma-separated list of node IPs, in the order they are upgraded.
#
# Talos is upgraded in waves, through the newest patch of every intermediate minor (the only
# path Sidero tests), so the cluster never spans more than one Talos minor. Kubernetes moves
# one minor at a time via `talosctl upgrade-k8s`, after every node runs the target Talos. Each
# step is checked against the Talos support matrix before anything changes.
#
# Before every reboot: all nodes Ready, `talosctl health` passes, no Longhorn volume is faulted
# or still rebuilding, the worst system-disk write latency over the last 2 minutes (from
# Prometheus, through the API server proxy) is under DISK_LATENCY_MAX_MS (default 50), and
# the node holds no attached volume's last healthy replica (the Longhorn drain policy would
# block the drain). Scale such a workload to 0 first; a detached volume does not block it.
# etcd shares the system disk with Longhorn, so rebooting into an I/O-saturated disk can
# stall etcd long enough to get a node marked NotReady and its pods evicted.
#
# Talos API credentials: $TALOSCONFIG when set, otherwise talos/talosconfig decrypted with sops.
set -euo pipefail
cd "$(dirname "$0")/.."

usage() { sed -n '2,10p' "$0" | sed -E 's/^# ?//' >&2; exit 64; }
[[ $# -eq 2 && ( $1 == plan || $1 == apply ) ]] || usage
MODE=$1
IFS=',' read -ra NODES <<< "$2"
CONFIG=talos/controlplane.yaml

log() { printf '==> %s\n' "$*"; }
die() { printf 'error: %s\n' "$*" >&2; exit 1; }

for bin in talosctl kubectl yq jq curl; do
  command -v "$bin" >/dev/null || die "missing required tool: $bin"
done

# Talos minor -> oldest and newest supported Kubernetes minor.
# Source: https://docs.siderolabs.com/talos/<version>/getting-started/support-matrix
declare -A K8S_RANGE=([1.12]="1.30 1.35" [1.13]="1.31 1.36" [1.14]="1.33 1.37")

minor() { [[ $1 =~ ^v?([0-9]+)\.([0-9]+) ]] && echo "${BASH_REMATCH[1]}.${BASH_REMATCH[2]}"; }
ver_lt() { [[ ${1#v} != "${2#v}" && $(printf '%s\n%s\n' "${1#v}" "${2#v}" | sort -V | head -1) == "${1#v}" ]]; }
next_minor() { echo "${1%%.*}.$(( ${1#*.} + 1 ))"; }

k8s_supported() { # talos-version k8s-version
  local range=${K8S_RANGE[$(minor "$1")]:-}
  [[ -n $range ]] || die "no Kubernetes support range for Talos $(minor "$1"); add it to K8S_RANGE"
  local k; k=$(minor "$2")
  ! ver_lt "$k" "${range% *}" && ! ver_lt "${range#* }" "$k"
}

# --- desired state (Git) -----------------------------------------------------------------

install_image=$(yq '.machine.install.image' "$CONFIG")
[[ $install_image =~ ^factory\.talos\.dev/(metal-)?installer/([0-9a-f]{64}):(v[0-9]+\.[0-9]+\.[0-9]+)$ ]] ||
  die "$CONFIG machine.install.image is not a factory installer image: $install_image"
SCHEMATIC=${BASH_REMATCH[2]}
WANT_TALOS=${BASH_REMATCH[3]}

kubelet_image=$(yq '.machine.kubelet.image' "$CONFIG")
WANT_K8S=${kubelet_image##*:}
for path in .cluster.apiServer.image .cluster.controllerManager.image .cluster.scheduler.image .cluster.proxy.image; do
  image=$(yq "$path" "$CONFIG")
  [[ ${image##*:} == "$WANT_K8S" ]] || die "$CONFIG $path is ${image##*:} but kubelet is $WANT_K8S"
done
k8s_supported "$WANT_TALOS" "$WANT_K8S" ||
  die "$CONFIG pins Kubernetes $WANT_K8S, which Talos $WANT_TALOS does not support (${K8S_RANGE[$(minor "$WANT_TALOS")]/ / - }); bump Talos first"

installer_image() { # Talos 1.14 stopped serving installer/, only metal-installer/
  if ver_lt "$(minor "$1")" 1.14; then echo "factory.talos.dev/installer/$SCHEMATIC:$1"
  else echo "factory.talos.dev/metal-installer/$SCHEMATIC:$1"; fi
}

TALOS_RELEASES=$(curl -fsSL "https://api.github.com/repos/siderolabs/talos/releases?per_page=100" |
  jq -r '.[] | select(.prerelease | not) | .tag_name')
latest_talos() { grep -E "^v${1//./\\.}\.[0-9]+$" <<< "$TALOS_RELEASES" | sort -V | tail -1; }
latest_k8s() { curl -fsSL "https://dl.k8s.io/release/stable-$1.txt"; }

client=$(talosctl version --client --short | grep -m1 -oE 'v[0-9]+\.[0-9]+\.[0-9]+')
ver_lt "$(minor "$client")" "$(minor "$WANT_TALOS")" &&
  die "talosctl $client is older than the target Talos $WANT_TALOS; install talosctl $(minor "$WANT_TALOS") or newer"

# --- live state ----------------------------------------------------------------------------

if [[ -z ${TALOSCONFIG:-} ]]; then
  TALOSCONFIG=$(mktemp /tmp/talosconfig.XXXXXX)
  trap 'rm -f "$TALOSCONFIG"' EXIT
  sops --decrypt --input-type yaml --output-type yaml talos/talosconfig > "$TALOSCONFIG"
fi
export TALOSCONFIG

tc() { local node=$1; shift; talosctl -e "$node" -n "$node" "$@"; }
node_talos() { tc "$1" version | sed -n '/^Server:/,$p' | grep -m1 -oE 'v[0-9]+\.[0-9]+\.[0-9]+'; }
node_schematic() { tc "$1" get extensions -o json | jq -r 'select(.spec.metadata.name == "schematic") | .spec.metadata.version'; }
node_name() {
  kubectl get nodes -o json | jq -r --arg ip "$1" \
    '.items[] | select(any(.status.addresses[]; .type == "InternalIP" and .address == $ip)) | .metadata.name'
}
live_k8s() { # oldest kubelet or control-plane component in the cluster
  { kubectl get nodes -o jsonpath='{range .items[*]}{.status.nodeInfo.kubeletVersion}{"\n"}{end}'
    kubectl -n kube-system get pods -l tier=control-plane \
      -o jsonpath='{range .items[*]}{.spec.containers[0].image}{"\n"}{end}' | sed 's/.*://'
  } | grep -E '^v[0-9]' | sort -V | head -1
}

talos_path() { # current target -> steps, each the newest patch of an intermediate minor
  local cur=$1 want=$2 m steps=() newest
  m=$(minor "$cur")
  while ver_lt "$m" "$(minor "$want")"; do
    newest=$(latest_talos "$m")
    [[ -n $newest ]] || die "no stable Talos release found for $m"
    ver_lt "$cur" "$newest" && steps+=("$newest")
    cur=$newest
    m=$(next_minor "$m")
  done
  steps+=("$want")
  echo "${steps[*]}"
}

k8s_path() { # current target -> steps, one minor at a time
  local cur=$1 want=$2 m steps=()
  m=$(minor "$cur")
  while ver_lt "$(next_minor "$m")" "$(minor "$want")"; do
    m=$(next_minor "$m")
    steps+=("$(latest_k8s "$m")")
  done
  steps+=("$want")
  echo "${steps[*]}"
}

# --- plan ----------------------------------------------------------------------------------

log "Git: Talos $WANT_TALOS (schematic ${SCHEMATIC:0:12}), Kubernetes $WANT_K8S"
LIVE_K8S=$(live_k8s)
declare -A STEPS=()
drift=0
for ip in "${NODES[@]}"; do
  cur=$(node_talos "$ip")
  schematic=$(node_schematic "$ip")
  [[ -n $cur && -n $schematic ]] || die "$ip: cannot read Talos version or schematic"
  ver_lt "$WANT_TALOS" "$cur" && die "$ip runs Talos $cur, newer than Git's $WANT_TALOS; refusing to downgrade"
  if [[ $cur == "$WANT_TALOS" && $schematic == "$SCHEMATIC" ]]; then
    printf '    %-12s Talos %-8s in sync\n' "$ip" "$cur"
    continue
  fi
  STEPS[$ip]=$(talos_path "$cur" "$WANT_TALOS")
  for step in ${STEPS[$ip]}; do
    k8s_supported "$step" "$LIVE_K8S" ||
      die "$ip: Talos $step does not support the running Kubernetes $LIVE_K8S"
  done
  note=""; [[ $schematic != "$SCHEMATIC" ]] && note=" (schematic ${schematic:0:12} -> ${SCHEMATIC:0:12})"
  printf '    %-12s Talos %-8s -> %s%s\n' "$ip" "$cur" "${STEPS[$ip]// / -> }" "$note"
  drift=1
done

ver_lt "$WANT_K8S" "$LIVE_K8S" && die "cluster runs Kubernetes $LIVE_K8S, newer than Git's $WANT_K8S; refusing to downgrade"
K8S_STEPS=""
if [[ $LIVE_K8S != "$WANT_K8S" ]]; then
  K8S_STEPS=$(k8s_path "$LIVE_K8S" "$WANT_K8S")
  printf '    Kubernetes %s -> %s\n' "$LIVE_K8S" "${K8S_STEPS// / -> }"
  drift=1
else
  printf '    Kubernetes %s in sync\n' "$LIVE_K8S"
fi
patches=(talos/patches/*.yaml)
printf '    patches applied once a node runs %s: %s\n' "$WANT_TALOS" "${patches[*]##*/}"

if [[ $MODE == plan ]]; then
  (( drift )) && exit 2
  exit 0
fi

# --- apply ---------------------------------------------------------------------------------

PROM_QUERY=/api/v1/namespaces/prometheus/services/prometheus:9090/proxy/api/v1/query
DISK_LATENCY_MAX_MS=${DISK_LATENCY_MAX_MS:-50}
disk_latency_ms() { # worst sda write latency across nodes over 2m; empty when Prometheus is unreachable
  local q='max(rate(node_disk_write_time_seconds_total{device="sda"}[2m]) / rate(node_disk_writes_completed_total{device="sda"}[2m])) * 1000'
  kubectl get --raw "$PROM_QUERY?query=$(jq -rn --arg q "$q" '$q | @uri')" 2>/dev/null |
    jq -r '.data.result[0].value[1] // empty'
}

wait_healthy() { # via-node: a node that is not about to reboot
  kubectl wait node --all --for=condition=Ready --timeout=20m >/dev/null
  local attempt
  for attempt in 1 2 3; do # a single Talos API timeout should not abort a multi-hour rollout
    tc "$1" health --wait-timeout 20m >/dev/null && break
    (( attempt < 3 )) || die "talosctl health via $1 failed 3 times"
    log "talosctl health via $1 failed (attempt $attempt), retrying in 30s"
    sleep 30
  done
  local deadline=$((SECONDS + 3600)) volumes busy faulted latency reason
  while :; do
    volumes=$(kubectl -n longhorn-system get volumes.longhorn.io -o json)
    faulted=$(jq -r '.items[] | select(.status.robustness == "faulted") | .status.kubernetesStatus.pvcName // .metadata.name' <<< "$volumes")
    [[ -z $faulted ]] || die "Longhorn volumes faulted: $(tr '\n' ' ' <<< "$faulted")"
    # degraded with Scheduled=True is a rebuild in progress; Scheduled=False cannot place a replica
    busy=$(jq -r '.items[] | select(.status.robustness == "degraded" and any((.status.conditions // [])[]; .type == "Scheduled" and .status == "True")) | .status.kubernetesStatus.pvcName // .metadata.name' <<< "$volumes")
    if [[ -n $busy ]]; then
      reason="Longhorn rebuilding: $(tr '\n' ' ' <<< "$busy")"
    else
      latency=$(disk_latency_ms)
      # NaN means no writes at all in the window
      [[ -n $latency ]] && awk -v l="$latency" -v m="$DISK_LATENCY_MAX_MS" 'BEGIN { exit !(l == "NaN" || l + 0 < m) }' && return
      reason="system disk write latency ${latency:+$(printf '%.0f' "$latency")ms}${latency:-unknown (Prometheus unreachable)}, limit ${DISK_LATENCY_MAX_MS}ms"
    fi
    (( SECONDS < deadline )) || die "not healthy after 60m: $reason"
    log "waiting: $reason"
    sleep 30
  done
}

check_last_replicas() { # node-ip
  local name sole
  name=$(node_name "$1")
  # only attached volumes: with nodeDrainPolicy allow-if-replica-is-stopped a detached
  # volume's last replica does not block the drain
  sole=$({ kubectl -n longhorn-system get replicas.longhorn.io -o json
           kubectl -n longhorn-system get volumes.longhorn.io -o json; } | jq -rs --arg n "$name" '
    .[0].items as $replicas
    | (.[1].items | map(select(.status.state == "attached") | {key: .metadata.name, value: "\(.status.kubernetesStatus.namespace)/\(.status.kubernetesStatus.pvcName)"}) | from_entries) as $attached
    | [$replicas[] | select(.spec.healthyAt != "" and .spec.failedAt == "" and $attached[.spec.volumeName] != null)]
    | group_by(.spec.volumeName)[] | select(all(.[]; .spec.nodeID == $n)) | $attached[.[0].spec.volumeName]')
  [[ -z $sole ]] && return
  die "$1 ($name) holds the last healthy replica of attached volume(s): $(tr '\n' ' ' <<< "$sole")- scale the workload to 0 or add a replica first"
}

other_node() { local n; for n in "${NODES[@]}"; do [[ $n != "$1" ]] && { echo "$n"; return; }; done; echo "$1"; }

apply_patches() { # node-ip
  local f
  for f in "${patches[@]}"; do
    log "$1: patch mc ${f##*/}"
    tc "$1" patch mc --mode=no-reboot --patch @"$f" >/dev/null
  done
}

# Waves by version, oldest first: every node whose next step is V takes it before any node goes
# past V. A rollout that stopped halfway therefore resumes in step: a node left behind catches
# up alone before the rest move on, so the cluster never spans more than one Talos minor.
mapfile -t WAVES < <(for ip in "${NODES[@]}"; do tr ' ' '\n' <<< "${STEPS[$ip]:-}"; done | grep . | sort -uV)
for step in "${WAVES[@]}"; do
  for ip in "${NODES[@]}"; do
    read -ra rest <<< "${STEPS[$ip]:-}"
    (( ${#rest[@]} )) && [[ ${rest[0]} == "$step" ]] || continue
    STEPS[$ip]=${rest[*]:1}
    via=$(other_node "$ip")
    log "$ip: pre-flight"
    wait_healthy "$via"
    check_last_replicas "$ip"
    log "$ip: upgrading to Talos $step ($(installer_image "$step"))"
    # drain-timeout covers qbittorrent's 30 minute termination grace period
    tc "$ip" upgrade --image "$(installer_image "$step")" --wait --timeout 45m --drain-timeout 35m
    got=$(node_talos "$ip")
    [[ $got == "$step" ]] || die "$ip reports Talos $got after upgrading to $step (rolled back?)"
    got=$(node_schematic "$ip")
    [[ $got == "$SCHEMATIC" ]] || die "$ip booted schematic $got, expected $SCHEMATIC"
    [[ $step == "$WANT_TALOS" ]] && apply_patches "$ip"
  done
done

for ip in "${NODES[@]}"; do # nodes that were already on the target still get the patches
  [[ -v STEPS[$ip] ]] || apply_patches "$ip"
done

for step in $K8S_STEPS; do
  log "pre-flight"
  wait_healthy "${NODES[0]}"
  log "upgrading Kubernetes to $step"
  tc "${NODES[0]}" upgrade-k8s --to "${step#v}"
done

log "post-flight"
wait_healthy "${NODES[0]}"
"$0" plan "$(IFS=,; echo "${NODES[*]}")" # not exec: the EXIT trap must remove the decrypted talosconfig
