# Home-Ops Justfile
# Talos cluster management with SOPS-encrypted configs

set shell := ["bash", "-c"]

# Cluster Configuration
PRIMARY_CONTROL_PLANE_IP := "10.0.0.10"
CONTROL_PLANE_IPS        := "10.0.0.10,10.0.0.20,10.0.0.21"
ALL_NODES                := CONTROL_PLANE_IPS
CLUSTER_NAME     := "talos-cluster"

# Talos Factory schematic ID (includes iscsi-tools + util-linux-tools + i915 extensions)
TALOS_SCHEMATIC  := "056d8e12ba2b9711c613665c43f0ebf86eb451839a22f360a42110362f84faa1"
TALOS_IMAGE      := "factory.talos.dev/installer/" + TALOS_SCHEMATIC

# Internal: decrypt talosconfig to a temp file, export TALOSCONFIG, run command
# Usage: just _talosctl -n 10.0.0.10 get machinestatus
[private]
_talosctl *ARGS:
    #!/usr/bin/env bash
    set -euo pipefail
    TMPCONFIG=$(mktemp /tmp/talosconfig.XXXXXX)
    trap "rm -f ${TMPCONFIG}" EXIT
    sops --decrypt --input-type yaml --output-type yaml talos/talosconfig > "${TMPCONFIG}"
    talosctl --talosconfig "${TMPCONFIG}" -e {{CONTROL_PLANE_IPS}} {{ARGS}}

# --- Status & Info ---

# Show the status of all cluster nodes
talos-status:
    just _talosctl -n {{ALL_NODES}} get machinestatus

# List all nodes in the cluster
talos-nodes:
    just _talosctl -n {{PRIMARY_CONTROL_PLANE_IP}} get nodes

# Fetch the kubeconfig for the cluster
talos-get-kubeconfig:
    just _talosctl -n {{PRIMARY_CONTROL_PLANE_IP}} kubeconfig .

# Watch the dashboard for a specific node
talos-dash node_ip=PRIMARY_CONTROL_PLANE_IP:
    just _talosctl -n {{node_ip}} dashboard

# --- Cluster Management ---

# Bootstrap the cluster (run after applying the first config)
talos-bootstrap:
    just _talosctl -n {{PRIMARY_CONTROL_PLANE_IP}} bootstrap

# Upgrade Talos on a specific node (uses factory image with extensions)
talos-upgrade node_ip image_version:
    just _talosctl -n {{node_ip}} upgrade --image "{{TALOS_IMAGE}}:v{{image_version}}"

# Rolling upgrade of all control plane nodes
talos-rolling-upgrade image_version:
    #!/usr/bin/env bash
    set -euo pipefail
    TMPCONFIG=$(mktemp /tmp/talosconfig.XXXXXX)
    trap "rm -f ${TMPCONFIG}" EXIT
    sops --decrypt --input-type yaml --output-type yaml talos/talosconfig > "${TMPCONFIG}"
    TALOS="talosctl --talosconfig ${TMPCONFIG} -e {{CONTROL_PLANE_IPS}}"
    IMAGE="{{TALOS_IMAGE}}:v{{image_version}}"
    IFS=',' read -ra NODES <<< "{{CONTROL_PLANE_IPS}}"
    echo "==> Starting rolling upgrade to ${IMAGE}"
    echo ""
    for node in "${NODES[@]}"; do
        echo "==> Upgrading control plane node ${node}..."
        ${TALOS} -n "${node}" upgrade --image "${IMAGE}" --wait
        echo "==> Control plane node ${node} upgraded successfully"
        echo ""
    done
    echo "==> Rolling upgrade complete. Checking cluster status..."
    ${TALOS} -n {{ALL_NODES}} get machinestatus

# Apply a Talos config to a node (decrypts automatically)
talos-apply node_ip config_file mode="reboot":
    #!/usr/bin/env bash
    set -euo pipefail
    TMPCONFIG=$(mktemp /tmp/talosconfig.XXXXXX)
    TMPFILE=$(mktemp /tmp/talos-machine-config.XXXXXX)
    trap "rm -f ${TMPCONFIG} ${TMPFILE}" EXIT
    sops --decrypt --input-type yaml --output-type yaml talos/talosconfig > "${TMPCONFIG}"
    sops --decrypt talos/{{config_file}} > "${TMPFILE}"
    talosctl --talosconfig "${TMPCONFIG}" -e {{CONTROL_PLANE_IPS}} -n {{node_ip}} apply-config --file "${TMPFILE}" --mode {{mode}}

# --- Debugging & Maintenance ---

# View logs for a specific service on a node
talos-logs node_ip service="ext-containerd":
    just _talosctl -n {{node_ip}} logs {{service}}

# Check resource usage on a node
talos-top node_ip:
    just _talosctl -n {{node_ip}} usage

# Reset a node (CAUTION: This wipes the node!)
talos-reset node_ip:
    @echo "WARNING: This will wipe the node at {{node_ip}}!"
    just _talosctl -n {{node_ip}} reset

# --- SOPS Encrypted Config Management ---

# Edit an encrypted Talos config file (decrypts, opens editor, re-encrypts)
talos-edit file:
    sops talos/{{file}}

# Decrypt a Talos config to stdout (for inspection)
talos-decrypt file:
    sops --decrypt talos/{{file}}

# Re-encrypt all Talos configs (run after updating .sops.yaml or rotating keys)
talos-reencrypt:
    #!/usr/bin/env bash
    set -euo pipefail
    for f in talos/controlplane.yaml talos/worker.yaml; do
        echo "==> Re-encrypting ${f}..."
        sops updatekeys --yes "${f}"
    done
    echo "==> Re-encrypting talos/talosconfig..."
    sops updatekeys --yes --input-type yaml --output-type yaml talos/talosconfig
    echo "==> Done."

# --- Oracle VPS (FRP) ---

VPS_SSH := "ubuntu@140.238.67.83"
VPS_COMPOSE_DIR := "/home/ubuntu/frp-tunnel"

# Update the Oracle VPS: OS packages + Docker services, then optionally reboot.
# Usage: just update-vps          (update only)
#        just update-vps yes      (update and reboot)
update-vps reboot="no":
    #!/usr/bin/env bash
    set -euo pipefail
    echo "==> Updating VPS OS packages (apt)..."
    ssh -o BatchMode=yes {{VPS_SSH}} 'sudo apt-get update && sudo DEBIAN_FRONTEND=noninteractive apt-get -y upgrade && sudo apt-get -y autoremove'
    echo "==> Updating Docker services (frp-tunnel compose)..."
    ssh -o BatchMode=yes {{VPS_SSH}} 'cd {{VPS_COMPOSE_DIR}} && sudo docker compose pull && sudo docker compose up -d'
    echo "==> Service status:"
    ssh -o BatchMode=yes {{VPS_SSH}} 'cd {{VPS_COMPOSE_DIR}} && sudo docker compose ps'
    if [ "{{reboot}}" = "yes" ]; then
        echo "==> Rebooting VPS..."
        ssh -o BatchMode=yes {{VPS_SSH}} 'sudo reboot' || true
        echo "==> Reboot triggered; reconnect in ~1 min (ssh {{VPS_SSH}})."
    else
        echo "==> Skipped reboot (run 'just update-vps yes' to reboot)."
    fi

# --- Help ---

# List all available commands
help:
    @just --list

# --- Flux ---

# Build every path the Flux entrypoint references and run the layout checks.
flux-validate:
    ./scripts/validate-flux-manifests.sh

# Same, plus a server-side diff of every component against the live cluster.
flux-diff:
    ./scripts/validate-flux-manifests.sh --diff

# Hand a component from its HelmRelease to its Kustomization (dry run without `apply=yes`).
# Usage: just flux-adopt sonarr        /  just flux-adopt sonarr yes
flux-adopt name apply="no":
    #!/usr/bin/env bash
    set -euo pipefail
    if [ "{{apply}}" = "yes" ]; then
        ./scripts/adopt-helmrelease.sh {{name}} --apply
    else
        ./scripts/adopt-helmrelease.sh {{name}}
    fi
