#!/usr/bin/env bash
# Install NixOS on a fresh VPS as the public edge (nixosConfigurations.edge, nixos/edge/)
# with nixos-anywhere: kexec into an installer, partition edge.disk with disko, install,
# reboot. THIS WIPES THE TARGET'S DISK.
#
#   just edge-install ubuntu@203.0.113.10          # asks for confirmation
#   just edge-install ubuntu@203.0.113.10 --yes
#
# The target user must be root or have passwordless sudo (OVH's Ubuntu image: ubuntu).
# Runs on the workstation from any directory of the repo and needs nix, sops (with the age
# key in ~/.config/sops/age/keys.txt), jq, ssh, and kubectl for the cluster.
#
# What it puts on the box besides the system:
#   /etc/ssh/ssh_host_ed25519_key   from nixos/edge/ssh_host_ed25519_key.sops.yaml. The
#                                   host's identity and its sops-nix age key, so secrets.yaml
#                                   decrypts on first boot.
#   /var/lib/edge/tailscale-authkey a one-off Headscale preauth key (user jack, 2h) that
#                                   tailscaled-autoconnect uses to join the tailnet.
# After the reboot it waits for the new node to come online in Headscale and prints its
# tailnet address. comin keeps the box on main from then on.
set -euo pipefail

usage() {
  echo "usage: $0 [--yes] <user@host>" >&2
  exit 2
}

assume_yes=false
target=""
for arg in "$@"; do
  case "$arg" in
    --yes | -y) assume_yes=true ;;
    -h | --help) usage ;;
    -*) echo "unknown option: $arg" >&2; usage ;;
    *)
      [ -z "$target" ] || usage
      target=$arg
      ;;
  esac
done
[ -n "$target" ] || usage

for tool in nix sops jq ssh kubectl; do
  command -v "$tool" >/dev/null || { echo "missing $tool" >&2; exit 1; }
done

cd "$(git rev-parse --show-toplevel)"

headscale() {
  kubectl -n headscale exec deploy/headscale -- headscale "$@"
}

disk=$(nix eval --raw .#nixosConfigurations.edge.config.edge.disk)

echo "==> checking $target"
# shellcheck disable=SC2016 # expanded on the target
ssh -o BatchMode=yes -o ConnectTimeout=10 "$target" sh -s -- "$disk" <<'EOF'
set -eu
if [ "$(id -u)" != 0 ] && ! sudo -n true 2>/dev/null; then
  echo "$(id -un) is neither root nor allowed passwordless sudo" >&2
  exit 1
fi
if [ ! -b "$1" ]; then
  echo "$1 does not exist on the target (set edge.disk in nixos/edge/host.nix):" >&2
  lsblk -dno NAME,SIZE,TYPE >&2
  exit 1
fi
lsblk -dno NAME,SIZE,MODEL "$1"
EOF

if ! $assume_yes; then
  printf 'This erases %s on %s. Type the host (%s) to continue: ' "$disk" "$target" "${target#*@}"
  read -r answer
  [ "$answer" = "${target#*@}" ] || { echo "aborted" >&2; exit 1; }
fi

extra=$(mktemp -d)
trap 'rm -rf "$extra"' EXIT
install -d -m 0755 "$extra/etc/ssh"
install -d -m 0700 "$extra/var/lib/edge"

echo "==> decrypting the host key"
(
  umask 077
  sops --decrypt --input-type yaml --output-type binary \
    nixos/edge/ssh_host_ed25519_key.sops.yaml > "$extra/etc/ssh/ssh_host_ed25519_key"
)
install -m 0644 nixos/edge/ssh_host_ed25519_key.pub "$extra/etc/ssh/ssh_host_ed25519_key.pub"

echo "==> creating a Headscale preauth key"
user_id=$(headscale users list -o json | jq -r '.[] | select(.name == "jack") | .id')
[ -n "$user_id" ] || { echo "Headscale user jack not found" >&2; exit 1; }
authkey=$(headscale preauthkeys create --user "$user_id" --expiration 2h -o json | jq -r '.key')
[ -n "$authkey" ] && [ "$authkey" != null ] || { echo "could not create a preauth key" >&2; exit 1; }
(
  umask 077
  printf '%s' "$authkey" > "$extra/var/lib/edge/tailscale-authkey"
)

known_nodes=$(headscale nodes list -o json | jq -c '[.[].id]')

echo "==> installing"
nix run .#nixos-anywhere -- \
  --flake .#edge \
  --target-host "$target" \
  --extra-files "$extra" \
  --build-on local

echo "==> waiting for the edge to join the tailnet"
for _ in $(seq 60); do
  node=$(headscale nodes list -o json | jq -c --argjson known "$known_nodes" \
    '[.[] | select(.online and (.id | IN($known[]) | not) and (.given_name | startswith("edge")))] | first // empty')
  if [ -n "$node" ]; then
    ip=$(jq -r '.ip_addresses[] | select(test("^100\\."))' <<<"$node")
    echo "edge is online as $(jq -r .given_name <<<"$node"): ssh root@$ip"
    exit 0
  fi
  sleep 10
done
echo "edge did not come online in Headscale within 10 minutes; check the OVH KVM console" >&2
exit 1
