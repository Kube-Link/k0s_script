#!/bin/bash

# =============================================================================
# Kairos + k0s + Cilium Cluster Manager
# =============================================================================
# For use with Hadron-based Kairos images (v4.x+) with the k0s provider.
# k0s is baked into the image at build time by kairos-init — this script does
# NOT install k0s. It generates cloud-config files, builds images, and manages
# the cluster lifecycle (Cilium, Flux, BGP, OS upgrades).
#
# Companion to k3s_cilium_cluster_manager.sh — Cilium/Flux/BGP logic is shared
# conceptually but paths differ (k0s kubeconfig vs k3s kubeconfig).
# =============================================================================

# Color codes for output
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

print_successful() { echo -e "${GREEN}$1${NC}"; }
print_info()       { echo -e "${YELLOW}$1${NC}"; }
print_warning()    { echo -e "${YELLOW}⚠️  $1${NC}"; }
print_error()      { echo -e "${RED}$1${NC}"; }

# -----------------------------------------------------------------------------
# Constants — k0s / Kairos paths and defaults
# -----------------------------------------------------------------------------
CONFIG_FILE="kairos_k0s_config.cfg"
CONTROLLER_CC_FILE="controller-cloud-config.yaml"
WORKER_CC_FILE="worker-cloud-config.yaml"
CONTROLLER_JOIN_CC_FILE="controller-join-cloud-config.yaml"
KAIROS_DOCKERFILE="Dockerfile.kairos"

# k0s paths (different from k3s)
K0S_KUBECONFIG="/var/lib/k0s/pki/admin.conf"
K0S_CONFIG_PATH="/etc/k0s/k0s.yaml"
K0S_TOKEN_FILE="/etc/k0s/token"

# Kairos image defaults
# TODO: decide on a base image tag strategy (pin to a release or track latest)
KAIROS_BASE_IMAGE="quay.io/kairos/hadron"        # Hadron base (musl + systemd)
KAIROS_INIT_IMAGE="quay.io/kairos/kairos-init"   # kairos-init tool
KAIROS_IMAGE_VERSION="v4.1.2"                   # TODO: make this configurable
K0S_PROVIDER_VERSION="latest"                   # k0s version baked into image

# Script version — bump manually when making changes; compared against VERSION file in repo
SCRIPT_VERSION="1.0.1"

# Cluster defaults
DEFAULT_POD_CIDR="10.42.0.0/16"
DEFAULT_SERVICE_CIDR="10.96.0.0/12"
DEFAULT_CLUSTER_NAME="homelab"

# -----------------------------------------------------------------------------
# Config file (shell vars, consumed by this script — NOT the cloud-config)
# -----------------------------------------------------------------------------
generate_config_file() {
    print_info "Generating Kairos/k0s config file..."
    read -p "Enter controller IP: " CONTROLLER_IP
    echo "CONTROLLER_IP=$CONTROLLER_IP" > "$CONFIG_FILE"

    read -p "Enter worker IPs (comma-separated): " WORKERS_INPUT
    IFS=',' read -ra WORKERS <<< "$WORKERS_INPUT"
    echo "WORKERS=(${WORKERS[@]})" >> "$CONFIG_FILE"

    read -p "Enter cluster name (default: $DEFAULT_CLUSTER_NAME): " CLUSTER_NAME
    CLUSTER_NAME=${CLUSTER_NAME:-$DEFAULT_CLUSTER_NAME}
    echo "CLUSTER_NAME=$CLUSTER_NAME" >> "$CONFIG_FILE"

    read -p "Enter Pod CIDR (default: $DEFAULT_POD_CIDR): " POD_CIDR
    POD_CIDR=${POD_CIDR:-$DEFAULT_POD_CIDR}
    echo "POD_CIDR=$POD_CIDR" >> "$CONFIG_FILE"

    read -p "Enter Service CIDR (default: $DEFAULT_SERVICE_CIDR): " SERVICE_CIDR
    SERVICE_CIDR=${SERVICE_CIDR:-$DEFAULT_SERVICE_CIDR}
    echo "SERVICE_CIDR=$SERVICE_CIDR" >> "$CONFIG_FILE"

    read -p "Install Cilium after k0s is up (y/n)? " INSTALL_CILIUM
    echo "INSTALL_CILIUM=$INSTALL_CILIUM" >> "$CONFIG_FILE"

    read -p "GitHub username for SSH key injection: " GITHUB_USER
    echo "GITHUB_USER=$GITHUB_USER" >> "$CONFIG_FILE"

    # Auto-discover or generate SSH key
    print_info "SSH key for cloud-config injection..."
    local SSH_DIR="$HOME/.ssh"
    local SSH_KEY
    local SSH_PUBKEY=""

    # Look for existing keys (prefer ed25519, then rsa)
    if [ -f "$SSH_DIR/id_ed25519.pub" ]; then
        SSH_KEY="$SSH_DIR/id_ed25519"
        print_info "Found Ed25519 key: $SSH_KEY"
    elif [ -f "$SSH_DIR/id_rsa.pub" ]; then
        SSH_KEY="$SSH_DIR/id_rsa"
        print_info "Found RSA key: $SSH_KEY"
    fi

    if [ -n "$SSH_KEY" ]; then
        read -p "Use this key? (y/n, default: y): " use_key
        if [ "${use_key:-y}" = "y" ]; then
            SSH_PUBKEY=$(cat "$SSH_KEY.pub")
        fi
    fi

    # No key found or user declined — offer to generate or paste
    if [ -z "$SSH_PUBKEY" ]; then
        read -p "No key selected. Generate a new one? (y/n, default: y): " gen_key
        if [ "${gen_key:-y}" = "y" ]; then
            mkdir -p "$SSH_DIR" 2>/dev/null
            chmod 700 "$SSH_DIR" 2>/dev/null
            ssh-keygen -t ed25519 -f "$SSH_DIR/id_ed25519_kairos" -N "" -C "kairos-cluster-key" 2>/dev/null
            if [ $? -eq 0 ] && [ -f "$SSH_DIR/id_ed25519_kairos.pub" ]; then
                SSH_PUBKEY=$(cat "$SSH_DIR/id_ed25519_kairos.pub")
                print_successful "Generated: $SSH_DIR/id_ed25519_kairos"
            else
                print_warning "Key generation failed."
                read -p "Paste your SSH public key manually: " SSH_PUBKEY
            fi
        else
            read -p "Paste your SSH public key manually (or leave blank to skip): " SSH_PUBKEY
        fi
    fi
    echo "SSH_PUBKEY='$SSH_PUBKEY'" >> "$CONFIG_FILE"

    # Remind user to upload to GitHub so the native github: mechanism works too
    if [ -n "$SSH_PUBKEY" ] && [ -n "$GITHUB_USER" ]; then
        echo ""
        print_info "For the native Kairos github:$GITHUB_USER key injection to work,"
        print_info "upload this public key to: https://github.com/settings/keys"
        echo -e "  ${GREEN}$SSH_PUBKEY${NC}"
        echo ""
        read -p "Press Enter to continue..."
    fi

    read -p "Hypervisor (proxmox/hyperv): " HYPERVISOR
    HYPERVISOR=${HYPERVISOR:-proxmox}
    echo "HYPERVISOR=$HYPERVISOR" >> "$CONFIG_FILE"

    # TODO: Proxmox VM ID range, ISO output path, registry for custom images

    print_successful "Config file $CONFIG_FILE created."
}

show_config_file() {
    if [ -f "$CONFIG_FILE" ]; then
        echo -e "${YELLOW}======== Config File Contents ========${NC}"
        cat "$CONFIG_FILE"
        echo -e "${YELLOW}=======================================${NC}"
    else
        print_error "Config file $CONFIG_FILE not found."
        read -p "Create one now? (y/n): " create_config
        [ "$create_config" = "y" ] && generate_config_file
    fi
}

ensure_config() {
    if [ ! -f "$CONFIG_FILE" ]; then
        print_error "Config file not found. Generate one first."
        read -p "Generate now? (y/n): " gen
        [ "$gen" = "y" ] && generate_config_file || return 1
    fi
    source "$CONFIG_FILE"
}

# -----------------------------------------------------------------------------
# Password hashing — Kairos v4.x requires SHA-512 crypt hashes, not cleartext
# -----------------------------------------------------------------------------
hash_password() {
    local plain="${1:-kairos}"
    if command -v openssl &>/dev/null; then
        openssl passwd -6 "$plain" 2>/dev/null || echo "$plain"
    elif command -v python3 &>/dev/null; then
        python3 -c "import crypt; print(crypt.crypt('$plain', crypt.mksalt(crypt.METHOD_SHA512)))" 2>/dev/null || echo "$plain"
    elif command -v python &>/dev/null; then
        python -c "import crypt; print(crypt.crypt('$plain', crypt.mksalt(crypt.METHOD_SHA512)))" 2>/dev/null || echo "$plain"
    else
        print_warning "No openssl or python found — password will be plaintext (Kairos may reject it)"
        echo "$plain"
    fi
}

# -----------------------------------------------------------------------------
# Cloud-config generation (the core new functionality)
# -----------------------------------------------------------------------------
# Generates the controller cloud-config file. This is what gets supplied to
# Kairos at install time (via WebUI, QR code, or manual-install).
#
# Reference: https://kairos.io/docs/reference/configuration/
# Covers: install, reset, upgrade, bind_mounts, grub_options, stages, bundles,
# k0s provider config, write_files (k0s.yaml).
generate_controller_cloudconfig() {
    print_info "Generating controller cloud-config ($CONTROLLER_CC_FILE)..."

    # Optional install block — enables zero-touch provisioning
    local INSTALL_BLOCK=""
    read -p "Enable auto-install (zero-touch, formats /dev/sda and reboots)? (y/n, default: n): " AUTO_INSTALL
    if [ "${AUTO_INSTALL:-n}" = "y" ]; then
        read -p "Install device (default: /dev/sda): " INSTALL_DEVICE
        INSTALL_DEVICE=${INSTALL_DEVICE:-/dev/sda}
        read -p "Config URL for remote config (optional, e.g. https://gist.../raw): " CONFIG_URL
        INSTALL_BLOCK="install:
  device: ${INSTALL_DEVICE}
  auto: true
  reboot: true
  grub_options:
    extra_cmdline: \"rd.neednet=1\""
        if [ -n "$CONFIG_URL" ]; then
            INSTALL_BLOCK="${INSTALL_BLOCK}
config_url: \"${CONFIG_URL}\""
        fi
    fi

    # Build SSH keys block (github key always, raw key as fallback if provided)
    local SSH_KEYS_BLOCK="      - github:${GITHUB_USER}"
    if [ -n "$SSH_PUBKEY" ]; then
        SSH_KEYS_BLOCK="${SSH_KEYS_BLOCK}"$'\n'"      - ${SSH_PUBKEY}"
    fi

    # Hash the password — Kairos v4.x needs SHA-512 crypt, not cleartext
    local USER_PASSWD=$(hash_password "kairos")
    print_info "Password hash: ${USER_PASSWD:0:20}..."

    # Compute hostname from controller IP (known at generation time)
    local CTRL_HOSTNAME="${CLUSTER_NAME}-ctrl-$(echo ${CONTROLLER_IP} | cut -d. -f4)"

    # Base64-encode script for compact embedding (avoids YAML indentation bloat)
    local SCRIPT_B64=$(base64 -w0 "$0" 2>/dev/null || base64 "$0" | tr -d '\n')

    cat > "$CONTROLLER_CC_FILE" << EOF
#cloud-config
# Controller node cloud-config for Kairos + k0s
# Supply this file during Kairos installation (WebUI / QR / manual-install)
# Reference: https://kairos.io/docs/reference/configuration/

hostname: ${CTRL_HOSTNAME}

users:
  - name: root
    passwd: ${USER_PASSWD}
    lock_passwd: false
    groups: [admin]
    ssh_authorized_keys:
${SSH_KEYS_BLOCK}

${INSTALL_BLOCK}

k0s:
  enabled: true
  args:
    - --config=${K0S_CONFIG_PATH}
    - --enable-worker

write_files:
  - path: ${K0S_CONFIG_PATH}
    permissions: "0644"
    content: |
      apiVersion: k0s.k0sproject.io/v1beta1
      kind: ClusterConfig
      metadata:
        name: ${CLUSTER_NAME}
      spec:
        api:
          address: ${CONTROLLER_IP}
          externalAddress: ${CONTROLLER_IP}
          port: 6443
          sans:
            - ${CONTROLLER_IP}
        network:
          provider: custom
          podCIDR: ${POD_CIDR}
          serviceCIDR: ${SERVICE_CIDR}
          kubeProxy:
            disabled: true
        storage:
          type: etcd
          etcd:
            peerAddress: ${CONTROLLER_IP}
        controllerManager: {}
        scheduler: {}
        telemetry:
          enabled: false
  - path: /root/kairos-cluster-manager.sh
    permissions: "0755"
    encoding: b64
    content: ${SCRIPT_B64}
  - path: /root/kairos_k0s_config.cfg
    permissions: "0644"
    content: |
      CONTROLLER_IP=${CONTROLLER_IP}
      WORKERS=(${WORKERS[@]})
      CLUSTER_NAME=${CLUSTER_NAME}
      POD_CIDR=${POD_CIDR}
      SERVICE_CIDR=${SERVICE_CIDR}
      INSTALL_CILIUM=${INSTALL_CILIUM}
      GITHUB_USER=${GITHUB_USER}
      SSH_PUBKEY='${SSH_PUBKEY}'
      HYPERVISOR=${HYPERVISOR}

# Persistent paths — survive reboots and OS upgrades (read-write bind mounts)
# k0s state and kubelet must persist on an immutable OS
bind_mounts:
  - /var/lib/k0s
  - /var/lib/k0s/kubelet

stages:
  boot:
    - name: "Update cluster manager script (every boot)"
      commands:
        - curl -sL https://raw.githubusercontent.com/Kube-Link/k0s_script/master/kairos_k0s_cluster_manager.sh -o /root/kairos-cluster-manager.sh
        - chmod +x /root/kairos-cluster-manager.sh
# Longhorn requirement
  boot.after:
    - name: "Enable iSCSI"
      commands:
        - systemctl enable iscsid
        - systemctl start iscsid
    - name: "Ensure k0s kubelet root dir exists"
      if: "[ ! -d /var/lib/k0s/kubelet ]"
      commands:
        - mkdir -p /var/lib/k0s/kubelet

# Reset behavior — what happens when kairos-agent reset is called
reset:
  reboot: true
  reset-persistent: false
  reset-oem: false

# Upgrade behavior — what happens when kairos-agent upgrade is called
upgrade:
  reboot: true

# Proxmox integration (only when running on Proxmox)
EOF

    # Conditionally add qemu-guest-agent bundle for Proxmox
    if [ "${HYPERVISOR:-proxmox}" = "proxmox" ]; then
        cat >> "$CONTROLLER_CC_FILE" << 'BUNDLEEOF'
bundles:
  - targets:
      - run://quay.io/kairos/community-bundles:qemu-guest-agent_latest
BUNDLEEOF
    fi

    print_successful "Controller cloud-config written to $CONTROLLER_CC_FILE"
    print_info "Next: boot the Kairos ISO on the controller, supply this file at install time."
    print_info "Validate with: docker run -ti -v \"\$PWD\":/test --entrypoint /usr/bin/kairos-agent --rm quay.io/kairos/hadron:v0.4.0-core-amd64-generic-${KAIROS_IMAGE_VERSION} validate /test/${CONTROLLER_CC_FILE}"
}

# Generates the worker cloud-config. Requires a token from the controller.
generate_worker_cloudconfig() {
    print_info "Generating worker cloud-config ($WORKER_CC_FILE)..."

    local WORKER_TOKEN="$1"
    if [ -z "$WORKER_TOKEN" ]; then
        print_error "No worker token provided. Run 'Generate Worker Token' first."
        return 1
    fi

    # Optional install block — enables zero-touch provisioning
    local INSTALL_BLOCK=""
    read -p "Enable auto-install (zero-touch, formats /dev/sda and reboots)? (y/n, default: n): " AUTO_INSTALL
    if [ "${AUTO_INSTALL:-n}" = "y" ]; then
        read -p "Install device (default: /dev/sda): " INSTALL_DEVICE
        INSTALL_DEVICE=${INSTALL_DEVICE:-/dev/sda}
        read -p "Config URL for remote config (optional, e.g. https://gist.../raw): " CONFIG_URL
        INSTALL_BLOCK="install:
  device: ${INSTALL_DEVICE}
  auto: true
  reboot: true
  grub_options:
    extra_cmdline: \"rd.neednet=1\""
        if [ -n "$CONFIG_URL" ]; then
            INSTALL_BLOCK="${INSTALL_BLOCK}
config_url: \"${CONFIG_URL}\""
        fi
    fi

    # Build SSH keys block (github key always, raw key as fallback if provided)
    local SSH_KEYS_BLOCK="      - github:${GITHUB_USER}"
    if [ -n "$SSH_PUBKEY" ]; then
        SSH_KEYS_BLOCK="${SSH_KEYS_BLOCK}"$'\n'"      - ${SSH_PUBKEY}"
    fi

    # Hash the password — Kairos v4.x needs SHA-512 crypt, not cleartext
    local USER_PASSWD=$(hash_password "kairos")

    # Base64-encode script for compact embedding
    local SCRIPT_B64=$(base64 -w0 "$0" 2>/dev/null || base64 "$0" | tr -d '\n')

    cat > "$WORKER_CC_FILE" << EOF
#cloud-config
# Worker node cloud-config for Kairos + k0s
# Reference: https://kairos.io/docs/reference/configuration/

hostname: ${CLUSTER_NAME}-node

users:
  - name: root
    passwd: ${USER_PASSWD}
    lock_passwd: false
    groups: [admin]
    ssh_authorized_keys:
${SSH_KEYS_BLOCK}

${INSTALL_BLOCK}

k0s-worker:
  enabled: true
  args:
    - --token-file ${K0S_TOKEN_FILE}

write_files:
  - path: ${K0S_TOKEN_FILE}
    permissions: "0644"
    content: |
      ${WORKER_TOKEN}
  - path: /root/kairos-cluster-manager.sh
    permissions: "0755"
    encoding: b64
    content: ${SCRIPT_B64}
  - path: /root/kairos_k0s_config.cfg
    permissions: "0644"
    content: |
      CONTROLLER_IP=${CONTROLLER_IP}
      WORKERS=(${WORKERS[@]})
      CLUSTER_NAME=${CLUSTER_NAME}
      POD_CIDR=${POD_CIDR}
      SERVICE_CIDR=${SERVICE_CIDR}
      INSTALL_CILIUM=${INSTALL_CILIUM}
      GITHUB_USER=${GITHUB_USER}
      SSH_PUBKEY='${SSH_PUBKEY}'
      HYPERVISOR=${HYPERVISOR}

# Persistent paths — survive reboots and OS upgrades (read-write bind mounts)
bind_mounts:
  - /var/lib/k0s
  - /var/lib/k0s/kubelet

stages:
  boot:
    - name: "Update cluster manager script (every boot)"
      commands:
        - curl -sL https://raw.githubusercontent.com/Kube-Link/k0s_script/master/kairos_k0s_cluster_manager.sh -o /root/kairos-cluster-manager.sh
        - chmod +x /root/kairos-cluster-manager.sh
# Longhorn requirement + set hostname
  initramfs:
    - name: "Set hostname from IP (predictable name)"
      commands:
        - |
          OCTET=\$(hostname -I | awk '{print \$1}' | cut -d. -f4)
          hostnamectl set-hostname ${CLUSTER_NAME}-node-\${OCTET}
  boot.after:
    - name: "Enable iSCSI"
      commands:
        - systemctl enable iscsid
        - systemctl start iscsid
    - name: "Ensure k0s kubelet root dir exists"
      if: "[ ! -d /var/lib/k0s/kubelet ]"
      commands:
        - mkdir -p /var/lib/k0s/kubelet

# Reset behavior
reset:
  reboot: true
  reset-persistent: false
  reset-oem: false

# Upgrade behavior
upgrade:
  reboot: true

# Proxmox integration (only when running on Proxmox)
EOF

    # Conditionally add qemu-guest-agent bundle for Proxmox
    if [ "${HYPERVISOR:-proxmox}" = "proxmox" ]; then
        cat >> "$WORKER_CC_FILE" << 'BUNDLEEOF'
bundles:
  - targets:
      - run://quay.io/kairos/community-bundles:qemu-guest-agent_latest
BUNDLEEOF
    fi

    print_successful "Worker cloud-config written to $WORKER_CC_FILE"
    print_info "Validate with: docker run -ti -v \"\$PWD\":/test --entrypoint /usr/bin/kairos-agent --rm quay.io/kairos/hadron:v0.4.0-core-amd64-generic-${KAIROS_IMAGE_VERSION} validate /test/${WORKER_CC_FILE}"
}

# -----------------------------------------------------------------------------
# Worker token generation
# -----------------------------------------------------------------------------
# Runs locally on the controller: `k0s token create --role=worker`.
# Run this directly on the controller node after SSHing in.
# The token is needed by generate_worker_cloudconfig() (run on management machine).
generate_worker_token() {
    print_info "Generating worker join token (runs locally on this node)..."

    if ! command -v k0s &>/dev/null; then
        print_error "k0s not found. Are you on the controller node?"
        return 1
    fi

    print_info "Running: k0s token create --role=worker"
    local token
    token=$(k0s token create --role=worker 2>&1)

    if [ -z "$token" ]; then
        print_error "Failed to create worker token. Is k0s running?"
        return 1
    fi

    print_successful "Worker token created."
    echo "$token"
    echo "$token" > .k0s_worker_token
    print_info "Token saved to .k0s_worker_token"
    print_info "Copy this token to your management machine for option 6 (Generate Worker Cloud-Config)."
}

# -----------------------------------------------------------------------------
# Controller join token — runs locally on the controller node.
# Generates `k0s token create --role=controller` for HA multi-controller setup.
# Run this directly on the first controller after SSHing in.
generate_controller_token() {
    print_info "Generating controller join token (runs locally on this node)..."

    if ! command -v k0s &>/dev/null; then
        print_error "k0s not found. Are you on the controller node?"
        return 1
    fi

    print_info "Running: k0s token create --role=controller"
    local token
    token=$(k0s token create --role=controller 2>&1)

    if [ -z "$token" ]; then
        print_error "Failed to create controller join token. Is k0s running?"
        return 1
    fi

    print_successful "Controller join token created."
    echo "$token"
    echo "$token" > .k0s_controller_token
    print_info "Token saved to .k0s_controller_token"
    print_info "Copy this token to your management machine for option 4 (Generate Controller Join Cloud-Config)."
}

# Generates a cloud-config for additional HA controllers that join the cluster.
# Same as the controller cloud-config but with the join token in /etc/k0s/token.
generate_controller_join_cloudconfig() {
    print_info "Generating controller join cloud-config ($CONTROLLER_JOIN_CC_FILE)..."

    local CTRL_TOKEN="$1"
    if [ -z "$CTRL_TOKEN" ]; then
        print_error "No controller join token provided. Run 'Generate Controller Join Token' first."
        return 1
    fi

    # Optional install block — enables zero-touch provisioning
    local INSTALL_BLOCK=""
    read -p "Enable auto-install (zero-touch, formats /dev/sda and reboots)? (y/n, default: n): " AUTO_INSTALL
    if [ "${AUTO_INSTALL:-n}" = "y" ]; then
        read -p "Install device (default: /dev/sda): " INSTALL_DEVICE
        INSTALL_DEVICE=${INSTALL_DEVICE:-/dev/sda}
        read -p "Config URL for remote config (optional, e.g. https://gist.../raw): " CONFIG_URL
        INSTALL_BLOCK="install:
  device: ${INSTALL_DEVICE}
  auto: true
  reboot: true
  grub_options:
    extra_cmdline: \"rd.neednet=1\""
        if [ -n "$CONFIG_URL" ]; then
            INSTALL_BLOCK="${INSTALL_BLOCK}
config_url: \"${CONFIG_URL}\""
        fi
    fi

    # Build SSH keys block
    local SSH_KEYS_BLOCK="      - github:${GITHUB_USER}"
    if [ -n "$SSH_PUBKEY" ]; then
        SSH_KEYS_BLOCK="${SSH_KEYS_BLOCK}"$'\n'"      - ${SSH_PUBKEY}"
    fi

    # Hash the password — Kairos v4.x needs SHA-512 crypt, not cleartext
    local USER_PASSWD=$(hash_password "kairos")

    # Base64-encode script for compact embedding
    local SCRIPT_B64=$(base64 -w0 "$0" 2>/dev/null || base64 "$0" | tr -d '\n')

    cat > "$CONTROLLER_JOIN_CC_FILE" << EOF
#cloud-config
# Additional controller node cloud-config for Kairos + k0s (HA join)
# The provider detects /etc/k0s/token and joins instead of init.
# Reference: https://kairos.io/docs/reference/configuration/

hostname: ${CLUSTER_NAME}-ctrl

users:
  - name: root
    passwd: ${USER_PASSWD}
    lock_passwd: false
    groups: [admin]
    ssh_authorized_keys:
${SSH_KEYS_BLOCK}

${INSTALL_BLOCK}

k0s:
  enabled: true
  args:
    - --config=${K0S_CONFIG_PATH}
    - --enable-worker

write_files:
  - path: ${K0S_CONFIG_PATH}
    permissions: "0644"
    content: |
      apiVersion: k0s.k0sproject.io/v1beta1
      kind: ClusterConfig
      metadata:
        name: ${CLUSTER_NAME}
      spec:
        api:
          address: ${CONTROLLER_IP}
          externalAddress: ${CONTROLLER_IP}
          port: 6443
        network:
          provider: custom
          podCIDR: ${POD_CIDR}
          serviceCIDR: ${SERVICE_CIDR}
          kubeProxy:
            disabled: true
        storage:
          type: etcd
        controllerManager: {}
        scheduler: {}
        telemetry:
          enabled: false
  - path: ${K0S_TOKEN_FILE}
    permissions: "0644"
    content: |
      ${CTRL_TOKEN}
  - path: /root/kairos-cluster-manager.sh
    permissions: "0755"
    encoding: b64
    content: ${SCRIPT_B64}
  - path: /root/kairos_k0s_config.cfg
    permissions: "0644"
    content: |
      CONTROLLER_IP=${CONTROLLER_IP}
      WORKERS=(${WORKERS[@]})
      CLUSTER_NAME=${CLUSTER_NAME}
      POD_CIDR=${POD_CIDR}
      SERVICE_CIDR=${SERVICE_CIDR}
      INSTALL_CILIUM=${INSTALL_CILIUM}
      GITHUB_USER=${GITHUB_USER}
      SSH_PUBKEY='${SSH_PUBKEY}'
      HYPERVISOR=${HYPERVISOR}
# Persistent paths
bind_mounts:
  - /var/lib/k0s
  - /var/lib/k0s/kubelet

stages:
  boot:
    - name: "Update cluster manager script (every boot)"
      commands:
        - curl -sL https://raw.githubusercontent.com/Kube-Link/k0s_script/master/kairos_k0s_cluster_manager.sh -o /root/kairos-cluster-manager.sh
        - chmod +x /root/kairos-cluster-manager.sh
# Set hostname and etcd peerAddress from this node's IP (not known until boot)
  initramfs:
    - name: "Set hostname and etcd peer address from IP"
      commands:
        - |
          IP=\$(hostname -I | awk '{print \$1}')
          OCTET=\$(echo \$IP | cut -d. -f4)
          hostnamectl set-hostname ${CLUSTER_NAME}-ctrl-\${OCTET}
          if [ -n "\$IP" ]; then
            sed -i "/^        storage:/a\\          etcd:\\n            peerAddress: \$IP" ${K0S_CONFIG_PATH}
          fi
  boot.after:
    - name: "Enable iSCSI"
      commands:
        - systemctl enable iscsid
        - systemctl start iscsid
    - name: "Ensure k0s kubelet root dir exists"
      if: "[ ! -d /var/lib/k0s/kubelet ]"
      commands:
        - mkdir -p /var/lib/k0s/kubelet

reset:
  reboot: true
  reset-persistent: false
  reset-oem: false

upgrade:
  reboot: true

# Proxmox integration (only when running on Proxmox)
EOF

    if [ "${HYPERVISOR:-proxmox}" = "proxmox" ]; then
        cat >> "$CONTROLLER_JOIN_CC_FILE" << 'BUNDLEEOF'
bundles:
  - targets:
      - run://quay.io/kairos/community-bundles:qemu-guest-agent_latest
BUNDLEEOF
    fi

    print_successful "Controller join cloud-config written to $CONTROLLER_JOIN_CC_FILE"
    print_info "Boot additional controllers with this config. They auto-join the HA control plane."
    print_info "Validate with: docker run -ti -v \"\$PWD\":/test --entrypoint /usr/bin/kairos-agent --rm quay.io/kairos/hadron:v0.4.0-core-amd64-generic-${KAIROS_IMAGE_VERSION} validate /test/${CONTROLLER_JOIN_CC_FILE}"
}

# -----------------------------------------------------------------------------
# Kairos image build
# -----------------------------------------------------------------------------
# Generates a Dockerfile that builds a Kairos standard image with k0s baked in,
# then (optionally) builds it and produces an ISO via AuroraBoot.
generate_kairos_dockerfile() {
    print_info "Generating Kairos Dockerfile ($KAIROS_DOCKERFILE)..."

    cat > "$KAIROS_DOCKERFILE" << EOF
# Build a Kairos standard image with k0s provider
# Uses Hadron as the base OS (minimal, musl + systemd, no package manager)
FROM ${KAIROS_INIT_IMAGE}:latest AS kairos-init

FROM ${KAIROS_BASE_IMAGE}:latest
ARG VERSION=${KAIROS_IMAGE_VERSION}

RUN --mount=type=bind,from=kairos-init,src=/kairos-init,dst=/kairos-init \
    /kairos-init -l debug -s install --version "\${VERSION}" --provider k0s --provider-k0s-version ${K0S_PROVIDER_VERSION} && \
    /kairos-init -l debug -s init --version "\${VERSION}"
EOF

    print_successful "Dockerfile written to $KAIROS_DOCKERFILE"
    print_info "Build with: docker build -t kairos-k0s:${KAIROS_IMAGE_VERSION} -f $KAIROS_DOCKERFILE ."
    print_info "Then create ISO with AuroraBoot (see reference/ for build script)."
}

# TODO: build_kairos_image() — orchestrate docker build + AuroraBoot ISO creation
# TODO: decide on ISO output path, registry push, version tagging strategy

# -----------------------------------------------------------------------------
# Cilium installation (adapted from k3s script — kubeconfig path differs)
# -----------------------------------------------------------------------------
install_cilium_cli() {
    print_info "Checking for Cilium CLI..."
    if [ ! -e "/usr/local/bin/cilium" ]; then
        CILIUM_CLI_VERSION=$(curl -s https://raw.githubusercontent.com/cilium/cilium-cli/main/stable.txt)
        CLI_ARCH=amd64
        curl -L --fail --remote-name-all \
            "https://github.com/cilium/cilium-cli/releases/download/${CILIUM_CLI_VERSION}/cilium-linux-${CLI_ARCH}.tar.gz"
        sudo tar xzvfC "cilium-linux-${CLI_ARCH}.tar.gz" /usr/local/bin
        rm "cilium-linux-${CLI_ARCH}.tar.gz"
        print_successful "Cilium CLI installed"
    else
        print_info "Cilium CLI already installed"
    fi
}

install_cilium() {
    print_info "Installing Cilium (k0s kubeconfig: $K0S_KUBECONFIG)..."
    install_cilium_cli

    # NOTE: k8sServiceHost points to the controller; k0s API port is 6443
    cilium install \
        --kubeconfig "$K0S_KUBECONFIG" \
        --set k8sServiceHost="${CONTROLLER_IP}" \
        --set k8sServicePort=6443 \
        --set kubeProxyReplacement=true \
        --set tunnelProtocol=geneve \
        --set loadBalancer.mode=dsr \
        --set loadBalancer.dsrDispatch=geneve \
        --set ipam.operator.clusterPoolIPv4PodCIDRList="${POD_CIDR}" \
        --set ipv4.enabled=true \
        --set enableIPv4Masquerade=true \
        --set ipMasqAgent.enable=false \
        --set routingMode=native \
        --set ipam.mode=cluster-pool \
        --set ipv4NativeRoutingCIDR="${POD_CIDR}" \
        --set autoDirectNodeRoutes=true \
        --set bpf.masquerade=true \
        --set bgpControlPlane.enabled=true \
        --set hubble.relay.enabled=false \
        --set hubble.enabled=false \
        --set hubble.ui.enabled=false \
        --set bgp.announce.loadbalancerIP=true

    cilium status --wait
    print_successful "Cilium installed"
}

# TODO: upgrade_cilium() — same as k3s version but with k0s kubeconfig path

# -----------------------------------------------------------------------------
# Node lifecycle (Kairos-specific)
# Kairos nodes are immutable — no package installs.
# Reset wipes the node back to a fresh state for re-provisioning.
# Runs locally — call this directly on the node you want to reset.
reset_node() {
    print_info "Resetting THIS Kairos node to fresh state..."
    print_warning "This will wipe k0s and all data on this node!"
    read -p "Are you sure? Type 'yes' to confirm: " confirm
    if [ "$confirm" != "yes" ]; then
        print_info "Aborted."
        return
    fi

    print_info "Running: kairos-agent reset --reboot"
    sudo kairos-agent reset --reboot
    print_successful "Node reset initiated — rebooting..."
}

# Kairos A/B upgrade: drains node, swaps active image, reboots, uncordons.
# TODO: implement — needs kubectl drain/uncordon + kairos-agent upgrade --source oci:<image>
kairos_rolling_upgrade() {
    print_info "Kairos rolling OS upgrade (A/B image swap)..."
    print_warning "TODO: not yet implemented."
    print_info "Flow: drain node → kairos-agent upgrade --source oci:<image> → reboot → uncordon"
    # Reuse drain/reboot scaffolding from k3s script, but replace apt/yum/dnf
    # with the image-swap command.
}

# -----------------------------------------------------------------------------
# Status checks
# -----------------------------------------------------------------------------
check_k0s_version() {
    print_info "Checking k0s version (local)..."
    if command -v k0s &>/dev/null; then
        k0s version
    else
        print_error "k0s not found on this node."
    fi
}

check_kairos_version() {
    print_info "Checking Kairos version (local)..."
    cat /etc/kairos-release 2>/dev/null || kairos-agent version 2>/dev/null || \
        print_error "Could not determine Kairos version."
}

check_script_version() {
    print_info "Local script version: ${SCRIPT_VERSION}"

    # Fetch VERSION file from repo to compare
    local remote_version
    remote_version=$(curl -s --connect-timeout 5 \
        "https://raw.githubusercontent.com/Kube-Link/k0s_script/master/VERSION" 2>/dev/null \
        | head -1 | tr -d '[:space:]')

    if [ -n "$remote_version" ]; then
        if [ "${SCRIPT_VERSION}" = "${remote_version}" ]; then
            print_successful "✓ Script is up-to-date (v${remote_version})"
        else
            print_warning "✗ Script is OUTDATED! Local: v${SCRIPT_VERSION} → Remote: v${remote_version}"
            print_info "A reboot will pull the latest version."
        fi
    else
        print_warning "Could not reach GitHub to check latest version."
    fi
    print_info "Source: https://github.com/Kube-Link/k0s_script/blob/master/kairos_k0s_cluster_manager.sh"
}

check_cluster_status() {
    print_info "Checking cluster status (local)..."
    if command -v k0s &>/dev/null; then
        k0s kubectl get nodes -o wide 2>/dev/null || \
            print_error "Cannot connect to cluster. Is k0s running?"
    else
        print_error "k0s not found on this node."
    fi
}

# -----------------------------------------------------------------------------
# BGP Configuration (ported from k3s script — Cilium BGP is distribution-agnostic)
# -----------------------------------------------------------------------------
# NOTE: The only difference from the k3s version is that kubectl commands run
# against the k0s kubeconfig. We set KUBECONFIG env var for all kubectl calls.

# Helper: run kubectl with the k0s kubeconfig
k0s_kubectl() {
    KUBECONFIG="$K0S_KUBECONFIG" kubectl "$@"
}

generate_bgp_config() {
    print_info "Generating Cilium BGP configuration files..."

    mkdir -p ./bgp_config

    read -p "Enter your cluster's ASN (default: 65001): " CLUSTER_ASN
    CLUSTER_ASN=${CLUSTER_ASN:-"65001"}

    read -p "Enter peer router's ASN (default: 65000): " PEER_ASN
    PEER_ASN=${PEER_ASN:-"65000"}

    read -p "Enter peer router's IP address: " PEER_IP
    if [ -z "$PEER_IP" ]; then
        print_error "Peer IP is required. Cannot continue."
        return 1
    fi

    read -p "Enter node hostnames (comma-separated): " NODE_HOSTNAMES_INPUT
    if [ -z "$NODE_HOSTNAMES_INPUT" ]; then
        print_error "Node hostnames are required. Cannot continue."
        return 1
    fi
    IFS=',' read -ra NODE_HOSTNAMES <<< "$NODE_HOSTNAMES_INPUT"

    NODE_SELECTOR_VALUES=""
    for hostname in "${NODE_HOSTNAMES[@]}"; do
        NODE_SELECTOR_VALUES+="          - $hostname"$'\n'
    done
    NODE_SELECTOR_VALUES=${NODE_SELECTOR_VALUES%$'\n'}

    read -p "Enter LoadBalancer IP pool start address: " LB_IP_START
    if [ -z "$LB_IP_START" ]; then
        print_error "LoadBalancer IP pool start address is required. Cannot continue."
        return 1
    fi

    read -p "Enter LoadBalancer IP pool end address: " LB_IP_END
    if [ -z "$LB_IP_END" ]; then
        print_error "LoadBalancer IP pool end address is required. Cannot continue."
        return 1
    fi

    cat > ./bgp_config/CiliumBGPClusterConfig.yaml << EOF
apiVersion: cilium.io/v2alpha1
kind: CiliumBGPClusterConfig
metadata:
  name: cilium-bgp
spec:
  bgpInstances:
    - localASN: $CLUSTER_ASN
      name: cluster
      peers:
        - name: unifi-udmpro
          peerASN: $PEER_ASN
          peerAddress: $PEER_IP
          peerConfigRef:
            name: cilium-peer
  nodeSelector:
    matchExpressions:
      - key: kubernetes.io/hostname
        operator: In
        values:
$NODE_SELECTOR_VALUES
EOF

    cat > ./bgp_config/CiliumBGPPeerConfig.yaml << EOF
apiVersion: cilium.io/v2alpha1
kind: CiliumBGPPeerConfig
metadata:
  name: cilium-peer
spec:
  ebgpMultihop: 1
  families:
  - advertisements:
      matchLabels:
        advertise: bgp
    afi: ipv4
    safi: unicast
  gracefulRestart:
    enabled: true
    restartTimeSeconds: 60
EOF

    cat > ./bgp_config/CiliumBGPAdvertisement.yaml << EOF
apiVersion: cilium.io/v2alpha1
kind: CiliumBGPAdvertisement
metadata:
  name: bgp-advertisements
  labels:
    advertise: bgp
spec:
  advertisements:
    - advertisementType: "Service"
      service:
        addresses:
          - LoadBalancerIP
      selector:
        matchExpressions:
          - { key: bgp, operator: In, values: [ external ] }
EOF

    cat > ./bgp_config/CiliumLoadBalancerIPPool.yaml << EOF
apiVersion: "cilium.io/v2alpha1"
kind: CiliumLoadBalancerIPPool
metadata:
  name: "first-pool"
spec:
  blocks:
    - start: "$LB_IP_START"
      stop: "$LB_IP_END"
EOF

    print_successful "BGP configuration files generated in ./bgp_config/ directory"

    if [ -f "$CONFIG_FILE" ]; then
        echo "CLUSTER_ASN=$CLUSTER_ASN" >> "$CONFIG_FILE"
        echo "PEER_ASN=$PEER_ASN" >> "$CONFIG_FILE"
        echo "PEER_IP=$PEER_IP" >> "$CONFIG_FILE"
        echo "NODE_HOSTNAMES=(${NODE_HOSTNAMES[@]})" >> "$CONFIG_FILE"
        echo "LB_IP_START=$LB_IP_START" >> "$CONFIG_FILE"
        echo "LB_IP_END=$LB_IP_END" >> "$CONFIG_FILE"
        print_info "BGP configuration saved to $CONFIG_FILE"
    fi
}

apply_bgp_config() {
    print_info "Applying BGP configuration to the cluster..."

    if ! command -v kubectl &> /dev/null; then
        print_error "kubectl not found. Cannot apply BGP configuration."
        return 1
    fi

    if [ ! -d "./bgp_config" ] || [ ! -f "./bgp_config/CiliumBGPClusterConfig.yaml" ]; then
        print_error "BGP configuration files not found. Generate them first."
        read -p "Generate BGP configuration now? (y/n): " generate_config
        [ "$generate_config" = "y" ] && generate_bgp_config || return 1
    fi

    print_info "Applying CiliumLoadBalancerIPPool..."
    k0s_kubectl apply -f ./bgp_config/CiliumLoadBalancerIPPool.yaml

    print_info "Applying CiliumBGPPeerConfig..."
    k0s_kubectl apply -f ./bgp_config/CiliumBGPPeerConfig.yaml

    print_info "Applying CiliumBGPAdvertisement..."
    k0s_kubectl apply -f ./bgp_config/CiliumBGPAdvertisement.yaml

    print_info "Applying CiliumBGPClusterConfig..."
    k0s_kubectl apply -f ./bgp_config/CiliumBGPClusterConfig.yaml

    print_successful "BGP configuration applied to the cluster"
    print_info "Run 'k0s_kubectl get ciliumloadbalancerippool,ciliumbgppeerconfig,ciliumbgpadvertisement,ciliumbgpclusterconfig' to verify"
}

generate_unifi_config() {
    print_info "Generating UniFi UDM Pro BGP configuration..."

    if [ -z "$CLUSTER_ASN" ] || [ -z "$PEER_ASN" ] || [ -z "$PEER_IP" ] || [ -z "$NODE_HOSTNAMES" ]; then
        if [ -f "$CONFIG_FILE" ]; then
            source "$CONFIG_FILE"
        else
            print_error "BGP configuration not found. Generate BGP configuration first."
            return 1
        fi
    fi

    NODE_IPS=()
    for hostname in "${NODE_HOSTNAMES[@]}"; do
        NODE_IP=$(k0s_kubectl get nodes "$hostname" -o jsonpath='{.status.addresses[?(@.type=="InternalIP")].address}' 2>/dev/null)
        if [ -z "$NODE_IP" ]; then
            read -p "Enter IP address for node $hostname: " NODE_IP
            if [ -z "$NODE_IP" ]; then
                print_error "Node IP is required. Skipping node $hostname."
                continue
            fi
        fi
        NODE_IPS+=("$NODE_IP")
    done

    NEIGHBOR_CONFIG=""
    for NODE_IP in "${NODE_IPS[@]}"; do
        NEIGHBOR_CONFIG+="neighbor $NODE_IP remote-as $CLUSTER_ASN"$'\n'
    done

    ADDRESS_FAMILY_CONFIG=""
    INDEX=0
    for NODE_IP in "${NODE_IPS[@]}"; do
        if [ $INDEX -eq 0 ]; then
            ADDRESS_FAMILY_CONFIG+="  # Explicitly advertise default route to controller"$'\n'
            ADDRESS_FAMILY_CONFIG+="  neighbor $NODE_IP activate"$'\n'
            ADDRESS_FAMILY_CONFIG+="  neighbor $NODE_IP default-originate"$'\n'
            ADDRESS_FAMILY_CONFIG+="  neighbor $NODE_IP soft-reconfiguration inbound"$'\n'
            ADDRESS_FAMILY_CONFIG+="  neighbor $NODE_IP route-map ALLOW-ALL in"$'\n'
            ADDRESS_FAMILY_CONFIG+="  neighbor $NODE_IP route-map ALLOW-ALL out"$'\n\n'
        else
            ADDRESS_FAMILY_CONFIG+="  # Standard peers (no default-originate)"$'\n'
            ADDRESS_FAMILY_CONFIG+="  neighbor $NODE_IP activate"$'\n'
            ADDRESS_FAMILY_CONFIG+="  neighbor $NODE_IP soft-reconfiguration inbound"$'\n'
            ADDRESS_FAMILY_CONFIG+="  neighbor $NODE_IP route-map ALLOW-ALL in"$'\n'
            ADDRESS_FAMILY_CONFIG+="  neighbor $NODE_IP route-map ALLOW-ALL out"$'\n\n'
        fi
        INDEX=$((INDEX + 1))
    done

    cat > ./bgp_config/unifi_udm_pro_frr.conf << EOF
router bgp $PEER_ASN
bgp router-id $PEER_IP

# Enable ECMP for multi-announce
bgp bestpath as-path multipath-relax
maximum-paths 4

# k0s nodes
${NEIGHBOR_CONFIG}
address-family ipv4 unicast
  # Optional: advertise UDM routes to k0s
  redistribute connected
  redistribute kernel

${ADDRESS_FAMILY_CONFIG}
exit-address-family
exit

route-map ALLOW-ALL permit 10
EOF

    print_successful "UniFi UDM Pro BGP configuration generated at ./bgp_config/unifi_udm_pro_frr.conf"
    print_info "Import this file into your UniFi UDM Pro's BGP configuration"
}

check_bgp_status() {
    print_info "Checking BGP status..."

    if ! command -v kubectl &> /dev/null; then
        print_error "kubectl not found. Cannot check BGP status."
        return 1
    fi

    print_info "Checking Cilium BGP resources..."
    k0s_kubectl get ciliumloadbalancerippool,ciliumbgppeerconfig,ciliumbgpadvertisement,ciliumbgpclusterconfig

    if command -v cilium &> /dev/null; then
        print_info "Checking detailed BGP status with Cilium CLI..."
        cilium bgp peers
    else
        print_info "Cilium CLI not found. For detailed BGP status, install the Cilium CLI."
    fi
}

manage_bgp() {
    echo -e "${YELLOW}======== BGP Configuration Management ========${NC}"
    echo "1. Generate BGP Configuration Files"
    echo "2. Apply BGP Configuration to Cluster"
    echo "3. Generate UniFi UDM Pro Configuration"
    echo "4. Check BGP Status"
    echo "5. Back to Main Menu"
    echo -e "${YELLOW}============================================${NC}"
    read -p "Enter your choice: " bgp_choice

    case $bgp_choice in
        1) generate_bgp_config ;;
        2) apply_bgp_config ;;
        3) generate_unifi_config ;;
        4) check_bgp_status ;;
        5) return ;;
        *) print_error "Invalid option. Returning to main menu." ;;
    esac
}

# -----------------------------------------------------------------------------
# FluxCD management (ported from k3s script — Flux is distribution-agnostic)
# -----------------------------------------------------------------------------
# NOTE: All kubectl/flux commands use KUBECONFIG=$K0S_KUBECONFIG. The flux CLI
# respects KUBECONFIG, so no wrapper needed — just export it before running.

check_fluxcd_status() {
    print_info "Checking FluxCD status..."

    if ! command -v kubectl &> /dev/null; then
        print_error "kubectl not found. Cannot check FluxCD status."
        return 1
    fi

    print_info "Checking FluxCD namespaces..."
    KUBECONFIG="$K0S_KUBECONFIG" kubectl get namespaces | grep flux-system

    print_info "Checking FluxCD controllers..."
    KUBECONFIG="$K0S_KUBECONFIG" kubectl get pods -n flux-system

    if command -v flux &> /dev/null; then
        print_info "Checking detailed FluxCD status with Flux CLI..."
        KUBECONFIG="$K0S_KUBECONFIG" flux get all
    else
        print_info "Flux CLI not found. For detailed status, install the Flux CLI."
    fi
}

add_fluxcd_controller() {
    print_info "Adding FluxCD controller..."

    if ! command -v kubectl &> /dev/null; then
        print_error "kubectl not found. Cannot continue with FluxCD installation."
        return 1
    fi

    if ! KUBECONFIG="$K0S_KUBECONFIG" kubectl cluster-info &> /dev/null; then
        print_error "Cannot connect to Kubernetes cluster. Check kubeconfig ($K0S_KUBECONFIG)."
        return 1
    fi

    if ! command -v flux &> /dev/null; then
        print_info "Flux CLI not found. Downloading and installing..."
        curl -s https://fluxcd.io/install.sh | sudo bash
        if [ $? -ne 0 ]; then
            print_error "Failed to install Flux CLI."
            return 1
        fi
    fi

    if ! KUBECONFIG="$K0S_KUBECONFIG" kubectl get namespace flux-system &> /dev/null; then
        print_info "flux-system namespace not found. Creating..."
        KUBECONFIG="$K0S_KUBECONFIG" kubectl create namespace flux-system
        if [ $? -ne 0 ]; then
            print_error "Failed to create flux-system namespace."
            return 1
        fi
    fi

    echo -e "${YELLOW}Available FluxCD Controllers:${NC}"
    echo "1. helm-controller"
    echo "2. image-reflector-controller"
    echo "3. image-automation-controller"
    echo "4. notification-controller"
    echo "5. Back to FluxCD Menu"
    read -p "Enter your choice: " controller_choice

    case $controller_choice in
        1)
            CONTROLLER_NAME="helm-controller"
            CRD_NAME="helmreleases.helm.toolkit.fluxcd.io"
            REQUIRED_CONTROLLERS="source-controller"
            ;;
        2)
            CONTROLLER_NAME="image-reflector-controller"
            CRD_NAME="imagerepositories.image.toolkit.fluxcd.io"
            ;;
        3)
            CONTROLLER_NAME="image-automation-controller"
            CRD_NAME="imageupdateautomations.image.toolkit.fluxcd.io"
            REQUIRED_CONTROLLERS="image-reflector-controller"
            ;;
        4)
            CONTROLLER_NAME="notification-controller"
            CRD_NAME="alerts.notification.toolkit.fluxcd.io"
            ;;
        5) return ;;
        *)
            print_error "Invalid option. Returning to FluxCD menu."
            return
            ;;
    esac

    if [ -n "$REQUIRED_CONTROLLERS" ]; then
        print_info "Checking for required controllers: $REQUIRED_CONTROLLERS"
        for req_controller in $REQUIRED_CONTROLLERS; do
            if ! KUBECONFIG="$K0S_KUBECONFIG" kubectl get deployment -n flux-system "$req_controller" &> /dev/null; then
                print_info "Required controller '$req_controller' not found. Installing it first..."
                if ! KUBECONFIG="$K0S_KUBECONFIG" flux install --components="$req_controller"; then
                    print_error "Failed to install required controller '$req_controller'"
                    return 1
                fi
                sleep 10
            fi
        done
    fi

    print_info "Installing $CONTROLLER_NAME..."

    if KUBECONFIG="$K0S_KUBECONFIG" kubectl get deployment -n flux-system "$CONTROLLER_NAME" &> /dev/null; then
        print_info "$CONTROLLER_NAME is already installed."
        read -p "Do you want to reinstall it? (y/n): " reinstall
        if [ "$reinstall" != "y" ]; then
            return
        fi

        print_info "Cleaning up existing resources..."
        KUBECONFIG="$K0S_KUBECONFIG" kubectl delete deployment -n flux-system "$CONTROLLER_NAME" --ignore-not-found
        KUBECONFIG="$K0S_KUBECONFIG" kubectl delete serviceaccount -n flux-system "$CONTROLLER_NAME" --ignore-not-found
        KUBECONFIG="$K0S_KUBECONFIG" kubectl delete clusterrole "$CONTROLLER_NAME" --ignore-not-found
        KUBECONFIG="$K0S_KUBECONFIG" kubectl delete clusterrolebinding "$CONTROLLER_NAME" --ignore-not-found

        if [ -n "$CRD_NAME" ]; then
            print_info "Removing existing CRD..."
            KUBECONFIG="$K0S_KUBECONFIG" kubectl delete crd "$CRD_NAME" --ignore-not-found
        fi

        print_info "Waiting for resources to be removed..."
        sleep 10
    fi

    MAX_RETRIES=3
    RETRY_COUNT=0
    SUCCESS=false

    while [ $RETRY_COUNT -lt $MAX_RETRIES ] && [ "$SUCCESS" = false ]; do
        print_info "Checking cluster resources..."
        KUBECONFIG="$K0S_KUBECONFIG" kubectl get nodes -o wide
        KUBECONFIG="$K0S_KUBECONFIG" kubectl get pods -A | grep -E "Running|Pending"

        print_info "Installing $CONTROLLER_NAME..."
        if KUBECONFIG="$K0S_KUBECONFIG" flux install --components="$CONTROLLER_NAME"; then
            SUCCESS=true
            print_successful "$CONTROLLER_NAME installed successfully"
        else
            RETRY_COUNT=$((RETRY_COUNT + 1))
            if [ $RETRY_COUNT -lt $MAX_RETRIES ]; then
                print_info "Installation failed. Retrying in 10 seconds... (Attempt $RETRY_COUNT of $MAX_RETRIES)"
                sleep 10
            fi
        fi
    done

    if [ "$SUCCESS" = false ]; then
        print_error "Failed to install $CONTROLLER_NAME after $MAX_RETRIES attempts"
        echo "1. Cluster has sufficient resources (CPU/Memory)"
        echo "2. Network connectivity to container registries"
        echo "3. Required CRDs are not conflicting"
        echo "4. RBAC permissions are correct"
        return 1
    fi

    print_info "Verifying installation..."
    sleep 10
    if KUBECONFIG="$K0S_KUBECONFIG" kubectl wait --for=condition=Ready pods -l app="$CONTROLLER_NAME" -n flux-system --timeout=60s; then
        print_successful "Installation verified successfully"
        print_info "Run 'kubectl get pods -n flux-system' to see all running controllers"
    else
        print_error "Installation verification failed"
        KUBECONFIG="$K0S_KUBECONFIG" kubectl get pods -n flux-system -l app="$CONTROLLER_NAME"
        KUBECONFIG="$K0S_KUBECONFIG" kubectl describe pods -n flux-system -l app="$CONTROLLER_NAME"
        return 1
    fi
}

remove_fluxcd_controller() {
    print_info "Removing FluxCD controller..."

    if ! command -v kubectl &> /dev/null; then
        print_error "kubectl not found. Cannot remove FluxCD controllers."
        return 1
    fi

    print_info "Checking FluxCD controllers..."
    KUBECONFIG="$K0S_KUBECONFIG" kubectl get deployments -n flux-system

    echo ""
    read -p "Enter the name of the controller to remove (e.g., helm-controller): " CONTROLLER_NAME

    if [ -z "$CONTROLLER_NAME" ]; then
        print_error "No controller name provided. Cannot continue."
        return 1
    fi

    read -p "Are you sure you want to remove $CONTROLLER_NAME? (y/n): " confirm_remove
    [ "$confirm_remove" != "y" ] && { print_info "Controller removal cancelled."; return; }

    print_info "Removing $CONTROLLER_NAME deployment..."
    KUBECONFIG="$K0S_KUBECONFIG" kubectl delete deployment -n flux-system "$CONTROLLER_NAME"

    print_info "Cleaning up $CONTROLLER_NAME resources..."
    KUBECONFIG="$K0S_KUBECONFIG" kubectl delete serviceaccount -n flux-system "$CONTROLLER_NAME" 2>/dev/null || true
    KUBECONFIG="$K0S_KUBECONFIG" kubectl delete clusterrole "$CONTROLLER_NAME" 2>/dev/null || true
    KUBECONFIG="$K0S_KUBECONFIG" kubectl delete clusterrolebinding "$CONTROLLER_NAME" 2>/dev/null || true

    print_successful "$CONTROLLER_NAME removed successfully"
}

upgrade_fluxcd() {
    print_info "Upgrading FluxCD..."

    if ! command -v flux &> /dev/null; then
        print_info "Flux CLI not found. Downloading and installing..."
        curl -s https://fluxcd.io/install.sh | sudo bash
    else
        print_info "Upgrading Flux CLI to the latest version..."
        curl -s https://fluxcd.io/install.sh | sudo bash
        print_successful "Flux CLI upgraded to the latest version"
    fi

    read -p "Enter specific FluxCD version to upgrade to (leave empty for latest): " FLUX_VERSION

    VERSION_FLAG=""
    [ -n "$FLUX_VERSION" ] && VERSION_FLAG="--version $FLUX_VERSION"

    print_info "Upgrading FluxCD controllers..."
    KUBECONFIG="$K0S_KUBECONFIG" flux install $VERSION_FLAG

    print_successful "FluxCD upgrade completed"
    print_info "Run 'flux get all' to verify the upgrade"
}

bootstrap_fluxcd() {
    print_info "Bootstrapping FluxCD with GitHub..."

    if ! command -v flux &> /dev/null; then
        print_info "Flux CLI not found. Downloading and installing..."
        curl -s https://fluxcd.io/install.sh | sudo bash
    fi

    read -p "Enter your GitHub owner (user/org): " GITHUB_OWNER
    read -p "Enter your GitHub repository: " GITHUB_REPO
    read -p "Enter branch to use (default: main): " GITHUB_BRANCH
    GITHUB_BRANCH=${GITHUB_BRANCH:-main}
    read -p "Enter path in repo for cluster config (default: cluster): " GITHUB_PATH
    GITHUB_PATH=${GITHUB_PATH:-cluster}
    read -p "Is this a personal repo? (y/n, default: y): " PERSONAL
    PERSONAL=${PERSONAL:-y}

    echo ""
    print_info "To authenticate, you need a GitHub Personal Access Token (PAT) with 'repo' and 'workflow' scopes."
    print_info "How to create a PAT:"
    echo "  1. Go to https://github.com/settings/tokens"
    echo "  2. Click 'Generate new token' (classic)"
    echo "  3. Set a name, expiration, and select 'repo' and 'workflow' scopes"
    echo "  4. Generate the token and copy it (you will not see it again!)"
    echo ""

    read -p "Enter your GitHub Personal Access Token: " GITHUB_TOKEN
    echo

    CMD="flux bootstrap github --owner=$GITHUB_OWNER --repository=$GITHUB_REPO --branch=$GITHUB_BRANCH --path=$GITHUB_PATH --token-auth --components=source-controller,kustomize-controller,notification-controller --components-extra=image-reflector-controller,image-automation-controller"
    [ "$PERSONAL" = "y" ] && CMD="$CMD --personal"

    export GITHUB_TOKEN="$GITHUB_TOKEN"
    export KUBECONFIG="$K0S_KUBECONFIG"

    eval "$CMD"

    print_successful "FluxCD bootstrap process completed."
}

manage_flux() {
    echo -e "${YELLOW}======== FluxCD Management ========${NC}"
    echo "1. Bootstrap FluxCD with GitHub"
    echo "2. Check FluxCD Status"
    echo "3. Add FluxCD Controller"
    echo "4. Remove FluxCD Controller"
    echo "5. Upgrade FluxCD"
    echo "6. Back to Main Menu"
    echo -e "${YELLOW}===================================${NC}"
    read -p "Enter your choice: " flux_choice

    case $flux_choice in
        1) bootstrap_fluxcd ;;
        2) check_fluxcd_status ;;
        3) add_fluxcd_controller ;;
        4) remove_fluxcd_controller ;;
        5) upgrade_fluxcd ;;
        6) return ;;
        *) print_error "Invalid option. Returning to main menu." ;;
    esac
}

# -----------------------------------------------------------------------------
# SSH key setup — finds or generates a key, saves public key to config for
# cloud-config injection (no ssh-copy-id needed — Kairos is immutable)
# -----------------------------------------------------------------------------
setup_ssh_keys() {
    print_info "SSH key setup for Kairos cluster..."

    # Determine SSH directory
    local CURRENT_USER=$(whoami 2>/dev/null || echo "$USER")
    local SSH_DIR
    if [ "$CURRENT_USER" = "root" ]; then
        SSH_DIR="/root/.ssh"
    else
        SSH_DIR="$HOME/.ssh"
    fi

    local SSH_KEY="$SSH_DIR/id_rsa"
    local SSH_PUB_KEY="$SSH_KEY.pub"

    print_info "Running as user: $CURRENT_USER"
    print_info "SSH directory: $SSH_DIR"

    # Check if SSH key already exists
    if [ -f "$SSH_KEY" ]; then
        print_info "SSH key already exists at $SSH_KEY"
        read -p "Use existing key? (y/n, default: y): " use_existing
        use_existing=${use_existing:-y}
        if [ "$use_existing" != "y" ]; then
            read -p "Enter a new key name (default: id_rsa_kairos): " key_name
            key_name=${key_name:-id_rsa_kairos}
            SSH_KEY="$SSH_DIR/$key_name"
            SSH_PUB_KEY="$SSH_KEY.pub"
        fi
    fi

    # Generate SSH key if it doesn't exist
    if [ ! -f "$SSH_KEY" ]; then
        print_info "Generating new SSH key pair..."
        mkdir -p "$SSH_DIR"
        chmod 700 "$SSH_DIR" 2>/dev/null

        read -p "Enter passphrase (leave empty for no passphrase): " passphrase
        if [ -z "$passphrase" ]; then
            ssh-keygen -t rsa -b 4096 -f "$SSH_KEY" -N "" -C "kairos-cluster-key"
        else
            ssh-keygen -t rsa -b 4096 -f "$SSH_KEY" -N "$passphrase" -C "kairos-cluster-key"
        fi

        if [ $? -eq 0 ]; then
            print_successful "SSH key generated at $SSH_KEY"
        else
            print_error "Failed to generate SSH key"
            return 1
        fi
    fi

    if [ ! -f "$SSH_PUB_KEY" ]; then
        print_error "Public key not found at $SSH_PUB_KEY"
        return 1
    fi

    local PUBLIC_KEY=$(cat "$SSH_PUB_KEY")
    print_successful "SSH public key:"
    echo -e "${GREEN}$PUBLIC_KEY${NC}"
    echo ""

    # Save to config file so cloud-config generation picks it up automatically
    if [ -f "$CONFIG_FILE" ]; then
        if grep -q "^SSH_PUBKEY=" "$CONFIG_FILE" 2>/dev/null; then
            sed -i "s|^SSH_PUBKEY=.*|SSH_PUBKEY='$PUBLIC_KEY'|" "$CONFIG_FILE"
        else
            echo "SSH_PUBKEY='$PUBLIC_KEY'" >> "$CONFIG_FILE"
        fi
        print_successful "Public key saved to $CONFIG_FILE"
    fi

    print_info "On Kairos, this key is injected via the cloud-config 'users.ssh_authorized_keys' section."
    echo ""
    read -p "Regenerate cloud-configs now to include this key? (y/n, default: y): " regen
    if [ "${regen:-y}" = "y" ]; then
        ensure_config || return 1
        generate_controller_cloudconfig
        if [ -f ".k0s_controller_token" ]; then
            generate_controller_join_cloudconfig "$(cat .k0s_controller_token)"
        fi
        if [ -f ".k0s_worker_token" ]; then
            generate_worker_cloudconfig "$(cat .k0s_worker_token)"
        else
            print_info "No worker token found — generate one (option 5) before regenerating worker cloud-config."
        fi
    fi
}

# -----------------------------------------------------------------------------
# Main menu
# -----------------------------------------------------------------------------
while true; do
    echo -e "\n${YELLOW}======== Kairos + k0s Cluster Management (v${SCRIPT_VERSION}) ========${NC}"
    echo "1.  Generate Config File (settings)"
    echo "2.  Generate Controller Cloud-Config (init)"
    echo "3.  Generate Controller Join Token (HA)"
    echo "4.  Generate Controller Join Cloud-Config (HA)"
    echo "5.  Generate Worker Token"
    echo "6.  Generate Worker Cloud-Config"
    echo "7.  Generate Kairos Dockerfile (image build)"
    echo "8.  Install Cilium"
    echo "9.  Manage FluxCD"
    echo "10. Manage BGP Configuration"
    echo "11. Check Versions (k0s / Kairos)"
    echo "12. Check Cluster Status"
    echo "13. Reset Node"
    echo "14. Rolling OS Upgrade (A/B)"
    echo "15. Show Config File"
    echo "16. Setup SSH Keys"
    echo "17. Exit"
    echo -e "${YELLOW}=================================================${NC}"
    read -p "Enter your choice: " choice

    case $choice in
        1) generate_config_file ;;
        2) ensure_config && generate_controller_cloudconfig ;;
        3) ensure_config && generate_controller_token ;;
        4) ensure_config && generate_controller_join_cloudconfig "$(cat .k0s_controller_token 2>/dev/null)" ;;
        5) ensure_config && generate_worker_token ;;
        6) ensure_config && generate_worker_cloudconfig "$(cat .k0s_worker_token 2>/dev/null)" ;;
        7) ensure_config && generate_kairos_dockerfile ;;
        8) ensure_config && install_cilium ;;
        9) manage_flux ;;
        10) manage_bgp ;;
        11) check_script_version; check_k0s_version; check_kairos_version ;;
        12) check_cluster_status ;;
        13) reset_node ;;
        14) kairos_rolling_upgrade ;;
        15) show_config_file ;;
        16) setup_ssh_keys ;;
        17) echo "Exiting..."; exit 0 ;;
        *) print_error "Invalid option." ;;
    esac
done
