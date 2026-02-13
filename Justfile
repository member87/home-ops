# Home-Ops Justfile
# Talos cluster management with SOPS-encrypted configs

set shell := ["bash", "-c"]

# Cluster Configuration
CONTROL_PLANE_IP := "10.0.0.10"
WORKER_IPS       := "10.0.0.20,10.0.0.21"
ALL_NODES        := CONTROL_PLANE_IP + "," + WORKER_IPS
CLUSTER_NAME     := "talos-cluster"

# Talos Factory schematic ID (includes iscsi-tools + util-linux-tools extensions)
TALOS_SCHEMATIC  := "613e1592b2da41ae5e265e8789429f22e121aab91cb4deb6bc3c0b6262961245"
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
    talosctl --talosconfig "${TMPCONFIG}" -e {{CONTROL_PLANE_IP}} {{ARGS}}

# --- Status & Info ---

# Show the status of all cluster nodes
talos-status:
    just _talosctl -n {{ALL_NODES}} get machinestatus

# List all nodes in the cluster
talos-nodes:
    just _talosctl -n {{CONTROL_PLANE_IP}} get nodes

# Fetch the kubeconfig for the cluster
talos-get-kubeconfig:
    just _talosctl -n {{CONTROL_PLANE_IP}} kubeconfig .

# Watch the dashboard for a specific node
talos-dash node_ip=CONTROL_PLANE_IP:
    just _talosctl -n {{node_ip}} dashboard

# --- Cluster Management ---

# Bootstrap the cluster (run after applying the first config)
talos-bootstrap:
    just _talosctl -n {{CONTROL_PLANE_IP}} bootstrap

# Upgrade Talos on a specific node (uses factory image with extensions)
talos-upgrade node_ip image_version:
    just _talosctl -n {{node_ip}} upgrade --image "{{TALOS_IMAGE}}:v{{image_version}}"

# Rolling upgrade of all nodes (workers first, then control plane)
talos-rolling-upgrade image_version:
    #!/usr/bin/env bash
    set -euo pipefail
    TMPCONFIG=$(mktemp /tmp/talosconfig.XXXXXX)
    trap "rm -f ${TMPCONFIG}" EXIT
    sops --decrypt --input-type yaml --output-type yaml talos/talosconfig > "${TMPCONFIG}"
    TALOS="talosctl --talosconfig ${TMPCONFIG} -e {{CONTROL_PLANE_IP}}"
    IMAGE="{{TALOS_IMAGE}}:v{{image_version}}"
    IFS=',' read -ra WORKERS <<< "{{WORKER_IPS}}"
    echo "==> Starting rolling upgrade to ${IMAGE}"
    echo ""
    for node in "${WORKERS[@]}"; do
        echo "==> Upgrading worker node ${node}..."
        ${TALOS} -n "${node}" upgrade --image "${IMAGE}" --wait
        echo "==> Worker node ${node} upgraded successfully"
        echo ""
    done
    echo "==> Upgrading control plane node {{CONTROL_PLANE_IP}}..."
    ${TALOS} -n {{CONTROL_PLANE_IP}} upgrade --image "${IMAGE}" --wait
    echo "==> Control plane node {{CONTROL_PLANE_IP}} upgraded successfully"
    echo ""
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
    talosctl --talosconfig "${TMPCONFIG}" -e {{CONTROL_PLANE_IP}} -n {{node_ip}} apply-config --file "${TMPFILE}" --mode {{mode}}

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

# --- Help ---

# List all available commands
help:
    @just --list
