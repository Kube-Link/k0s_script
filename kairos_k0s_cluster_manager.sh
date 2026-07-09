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
SCRIPT_VERSION="1.0.31"

# Cluster defaults
DEFAULT_POD_CIDR="10.42.0.0/16"
DEFAULT_SERVICE_CIDR="10.96.0.0/12"
DEFAULT_CLUSTER_NAME="homelab"
WORKER_INSTALL_STATE_FILE=".kairos_worker_installs_submitted"
SCRIPT_UPDATE_URL="https://raw.githubusercontent.com/Kube-Link/k0s_script/master/kairos_k0s_cluster_manager.sh"
SAFE_SCRIPT_UPDATE_COMMAND="log=/var/log/kairos-cluster-manager-update.log; url=${SCRIPT_UPDATE_URL}; dest=/root/kairos-cluster-manager.sh; old=/root/kairos-cluster-manager.old.sh; tmp=/root/kairos-cluster-manager.sh.new; tmp_lf=/root/kairos-cluster-manager.sh.new.lf; updated=n; rm -f \"\$tmp\" \"\$tmp_lf\"; for attempt in 1 2 3 4 5 6 7 8 9 10 11 12; do echo \"\$(date -Iseconds 2>/dev/null || date) attempt \$attempt\" >> \"\$log\"; if curl -fsSL --connect-timeout 10 --max-time 60 \"\$url\" -o \"\$tmp\" >> \"\$log\" 2>&1; then tr -d '\r' < \"\$tmp\" > \"\$tmp_lf\" && mv \"\$tmp_lf\" \"\$tmp\"; if head -n 1 \"\$tmp\" | grep -qx '#!/bin/bash' && bash -n \"\$tmp\" >> \"\$log\" 2>&1; then new_version=\$(awk -F'\"' '/^SCRIPT_VERSION=/{print \$2; exit}' \"\$tmp\"); current_version=; if [ -f \"\$dest\" ]; then current_version=\$(tr -d '\r' < \"\$dest\" | awk -F'\"' '/^SCRIPT_VERSION=/{print \$2; exit}' 2>/dev/null); fi; cr=\$(printf '\r'); if [ -n \"\$new_version\" ] && [ -n \"\$current_version\" ] && [ \"\$new_version\" = \"\$current_version\" ]; then if [ -f \"\$dest\" ] && grep -q \"\$cr\" \"\$dest\"; then if mv \"\$tmp\" \"\$dest\" && chmod 0755 \"\$dest\"; then echo \"\$(date -Iseconds 2>/dev/null || date) normalized line endings for current version \$current_version\" >> \"\$log\"; updated=y; break; fi; else echo \"\$(date -Iseconds 2>/dev/null || date) already current version \$current_version; no replace needed\" >> \"\$log\"; updated=y; rm -f \"\$tmp\"; break; fi; fi; if [ -f \"\$dest\" ] && cmp -s \"\$tmp\" \"\$dest\"; then echo \"\$(date -Iseconds 2>/dev/null || date) already current; no replace needed\" >> \"\$log\"; updated=y; rm -f \"\$tmp\"; break; fi; if [ -f \"\$dest\" ]; then if cp -p \"\$dest\" \"\$old\"; then echo \"\$(date -Iseconds 2>/dev/null || date) backed up \$dest to \$old\" >> \"\$log\"; else echo \"\$(date -Iseconds 2>/dev/null || date) backup failed; keeping existing \$dest\" >> \"\$log\"; rm -f \"\$tmp\"; break; fi; fi; if mv \"\$tmp\" \"\$dest\" && chmod 0755 \"\$dest\"; then echo \"\$(date -Iseconds 2>/dev/null || date) updated \$dest; previous copy is \$old\" >> \"\$log\"; updated=y; break; else echo \"\$(date -Iseconds 2>/dev/null || date) install failed\" >> \"\$log\"; if [ -f \"\$old\" ] && [ ! -f \"\$dest\" ]; then cp -p \"\$old\" \"\$dest\" && chmod 0755 \"\$dest\"; fi; fi; else echo \"\$(date -Iseconds 2>/dev/null || date) downloaded file failed validation\" >> \"\$log\"; fi; else echo \"\$(date -Iseconds 2>/dev/null || date) download failed\" >> \"\$log\"; fi; sleep 10; done; if [ \"\$updated\" != \"y\" ]; then echo \"\$(date -Iseconds 2>/dev/null || date) keeping existing \$dest\" >> \"\$log\"; fi; rm -f \"\$tmp\" \"\$tmp_lf\""

build_controller_k0s_args() {
    local include_token="${1:-false}"

    printf '    - --config=%s\n' "$K0S_CONFIG_PATH"
    if [ "$include_token" = "true" ]; then
        printf '    - --token-file=%s\n' "$K0S_TOKEN_FILE"
    fi

    if [ "${CONTROLLER_WORKER:-n}" = "y" ]; then
        printf '    - --enable-worker\n'
        printf '    - --no-taints\n'
    fi
}

script_base64_lf() {
    local source_file="$1"

    tr -d '\r' < "$source_file" | base64 -w0 2>/dev/null || \
        tr -d '\r' < "$source_file" | base64 | tr -d '\n'
}

print_github_ssh_key_guide() {
    local github_user="$1"
    local public_key="$2"

    print_info "GitHub SSH key setup for Kairos:"
    echo "  1. Open: https://github.com/settings/keys"
    echo "  2. Click: New SSH key"
    echo "  3. Title: kairos-cluster-key (or your cluster name)"
    echo "  4. Key type: Authentication Key"
    echo "  5. Paste this public key and click Add SSH key:"
    echo -e "     ${GREEN}${public_key}${NC}"
    echo "  6. Optional local test, from a machine with the private key:"
    echo "     ssh -T git@github.com"
    echo ""
    print_info "The cloud-config uses github:${github_user}; the raw key is embedded as a fallback too."
}

trim_value() {
    local value="$1"
    value="${value#"${value%%[![:space:]]*}"}"
    value="${value%"${value##*[![:space:]]}"}"
    printf '%s' "$value"
}

prompt_yn() {
    local result_var="$1"
    local prompt="$2"
    local default="$3"
    local answer

    while true; do
        read -p "$prompt" answer || return 1
        answer=${answer:-$default}
        case "$answer" in
            y|Y|yes|YES) printf -v "$result_var" '%s' "y"; return 0 ;;
            n|N|no|NO) printf -v "$result_var" '%s' "n"; return 0 ;;
            *) print_error "Please answer y or n." ;;
        esac
    done
}

write_config_value() {
    local file="$1"
    local key="$2"
    local value="$3"

    printf '%s=' "$key" >> "$file"
    printf '%q\n' "$value" >> "$file"
}

write_config_array() {
    local file="$1"
    local key="$2"
    shift 2

    printf '%s=(' "$key" >> "$file"
    local value
    for value in "$@"; do
        printf ' %q' "$value" >> "$file"
    done
    printf ' )\n' >> "$file"
}

format_config_value_line() {
    local key="$1"
    local value="$2"
    local quoted

    printf -v quoted '%q' "$value"
    printf '%s=%s' "$key" "$quoted"
}

format_config_array_line() {
    local key="$1"
    shift
    local line="${key}=("
    local value
    local quoted

    for value in "$@"; do
        printf -v quoted '%q' "$value"
        line="${line} ${quoted}"
    done
    line="${line} )"
    printf '%s' "$line"
}

upsert_config_line() {
    local file="$1"
    local key="$2"
    local line="$3"
    local tmp_file="${file}.tmp.$$"

    if [ -f "$file" ] && grep -q "^${key}=" "$file" 2>/dev/null; then
        awk -v key="$key" -v line="$line" '
            BEGIN { replaced = 0 }
            $0 ~ "^" key "=" {
                if (!replaced) {
                    print line
                    replaced = 1
                }
                next
            }
            { print }
            END {
                if (!replaced) {
                    print line
                }
            }
        ' "$file" > "$tmp_file" && mv "$tmp_file" "$file"
    else
        printf '%s\n' "$line" >> "$file"
    fi
}

upsert_config_value() {
    local file="$1"
    local key="$2"
    local value="$3"

    upsert_config_line "$file" "$key" "$(format_config_value_line "$key" "$value")"
}

upsert_config_array() {
    local file="$1"
    local key="$2"
    shift 2

    upsert_config_line "$file" "$key" "$(format_config_array_line "$key" "$@")"
}

validate_unique_nodes() {
    local seen=()
    local node
    local existing

    for node in "$@"; do
        [ -z "$node" ] && continue
        for existing in "${seen[@]}"; do
            if [ "$node" = "$existing" ]; then
                print_error "Duplicate node IP in config: $node"
                return 1
            fi
        done
        seen+=("$node")
    done
}

validate_config_file() {
    local file="$1"

    if [ ! -f "$file" ]; then
        print_error "Config file $file not found."
        return 1
    fi

    if ! bash -n "$file" 2>/dev/null; then
        print_error "Config file has shell syntax errors: $file"
        bash -n "$file"
        return 1
    fi

    local duplicate_keys
    duplicate_keys=$(awk -F= '/^[[:space:]]*[A-Z_][A-Z0-9_]*=/{key=$1; sub(/^[[:space:]]*/, "", key); count[key]++} END{for (key in count) if (count[key] > 1) print key}' "$file")
    if [ -n "$duplicate_keys" ]; then
        print_error "Config file has duplicate keys. Regenerate it with option 1."
        echo "$duplicate_keys"
        return 1
    fi

    local validation_output
    validation_output=$(bash -c '
        source "$1" || exit 1
        failed=0
        for key in CONTROLLER_COUNT CONTROLLER_WORKER CONTROLLER_IP ADDITIONAL_CONTROLLERS WORKERS CLUSTER_NAME POD_CIDR SERVICE_CIDR INSTALL_CILIUM GITHUB_USER SSH_PUBKEY HYPERVISOR; do
            if ! declare -p "$key" >/dev/null 2>&1; then
                echo "Missing required config key: $key"
                failed=1
            fi
        done
        case "${CONTROLLER_WORKER:-}" in
            y|n) ;;
            *) echo "CONTROLLER_WORKER must be y or n."; failed=1 ;;
        esac
        case "${INSTALL_CILIUM:-}" in
            y|n) ;;
            *) echo "INSTALL_CILIUM must be y or n."; failed=1 ;;
        esac
        if [ "${#ADDITIONAL_CONTROLLERS[@]}" -ne 2 ]; then
            echo "Exactly 2 additional controller IPs are required."
            failed=1
        fi
        if [ "${CONTROLLER_WORKER:-n}" = "n" ] && [ "${#WORKERS[@]}" -eq 0 ]; then
            echo "At least one worker IP is required when controllers are controller-only."
            failed=1
        fi
        exit "$failed"
    ' _ "$file" 2>&1)

    if [ $? -ne 0 ]; then
        print_error "Config file validation failed: $file"
        printf '%s\n' "$validation_output"
        return 1
    fi
}

# -----------------------------------------------------------------------------
# Config file (shell vars, consumed by this script — NOT the cloud-config)
# -----------------------------------------------------------------------------
generate_config_file() {
    print_info "Generating Kairos/k0s config file..."
    echo ""
    local tmp_config="${CONFIG_FILE}.tmp.$$"
    rm -f "$tmp_config"

    # --- Cluster topology ---
    # k0s etcd requires odd number of controllers; 3 is the practical HA choice
    CONTROLLER_COUNT=3

    print_info "Cluster topology (3-controller HA):"
    print_info "  Option A: 3 controllers + X workers  — dedicated control plane"
    print_info "  Option B: 3 controller+workers        — controllers also run pods"
    echo ""

    # --- Controller role ---
    prompt_yn CONTROLLER_WORKER "Enable worker role on controllers? (y/n, default: n): " "n" || return 1

    read -p "Enter primary controller IP: " CONTROLLER_IP || return 1
    CONTROLLER_IP=$(trim_value "$CONTROLLER_IP")
    if [ -z "$CONTROLLER_IP" ]; then
        print_error "Primary controller IP is required."
        return 1
    fi

    print_info "Enter the 2 additional HA controller IPs (these will join the cluster)."
    read -p "Additional controller IPs (comma-separated): " ADDITIONAL_INPUT || return 1
    IFS=',' read -ra ADDITIONAL_CONTROLLERS_RAW <<< "$ADDITIONAL_INPUT"
    ADDITIONAL_CONTROLLERS=()
    local item
    for item in "${ADDITIONAL_CONTROLLERS_RAW[@]}"; do
        item=$(trim_value "$item")
        [ -n "$item" ] && ADDITIONAL_CONTROLLERS+=("$item")
    done
    if [ "${#ADDITIONAL_CONTROLLERS[@]}" -ne 2 ]; then
        print_error "Exactly 2 additional controller IPs required for HA (3 total)."
        return 1
    fi

    if [ "$CONTROLLER_WORKER" = "y" ]; then
        WORKERS=()
        print_info "Controllers will run workloads — no separate workers needed."
    else
        read -p "Enter worker IPs (comma-separated): " WORKERS_INPUT || return 1
        IFS=',' read -ra WORKERS_RAW <<< "$WORKERS_INPUT"
        WORKERS=()
        for item in "${WORKERS_RAW[@]}"; do
            item=$(trim_value "$item")
            [ -n "$item" ] && WORKERS+=("$item")
        done
        if [ "${#WORKERS[@]}" -eq 0 ]; then
            print_error "At least one worker IP is required when controllers are controller-only."
            return 1
        fi
    fi

    validate_unique_nodes "$CONTROLLER_IP" "${ADDITIONAL_CONTROLLERS[@]}" "${WORKERS[@]}" || return 1

    read -p "Enter cluster name (default: $DEFAULT_CLUSTER_NAME): " CLUSTER_NAME || return 1
    CLUSTER_NAME=${CLUSTER_NAME:-$DEFAULT_CLUSTER_NAME}
    CLUSTER_NAME=$(trim_value "$CLUSTER_NAME")

    read -p "Enter Pod CIDR (default: $DEFAULT_POD_CIDR): " POD_CIDR || return 1
    POD_CIDR=${POD_CIDR:-$DEFAULT_POD_CIDR}
    POD_CIDR=$(trim_value "$POD_CIDR")

    read -p "Enter Service CIDR (default: $DEFAULT_SERVICE_CIDR): " SERVICE_CIDR || return 1
    SERVICE_CIDR=${SERVICE_CIDR:-$DEFAULT_SERVICE_CIDR}
    SERVICE_CIDR=$(trim_value "$SERVICE_CIDR")

    prompt_yn INSTALL_CILIUM "Auto-install Cilium after all workers are installed and registered? (y/n, default: n): " "n" || return 1

    read -p "GitHub username for SSH key injection: " GITHUB_USER || return 1
    GITHUB_USER=$(trim_value "$GITHUB_USER")

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
        prompt_yn use_key "Use this key? (y/n, default: y): " "y" || return 1
        if [ "$use_key" = "y" ]; then
            SSH_PUBKEY=$(cat "$SSH_KEY.pub")
        fi
    fi

    # No key found or user declined — offer to generate or paste
    if [ -z "$SSH_PUBKEY" ]; then
        prompt_yn gen_key "No key selected. Generate a new one? (y/n, default: y): " "y" || return 1
        if [ "$gen_key" = "y" ]; then
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
            read -p "Paste your SSH public key manually (or leave blank to skip): " SSH_PUBKEY || return 1
        fi
    fi

    # Remind user to upload to GitHub so the native github: mechanism works too
    if [ -n "$SSH_PUBKEY" ] && [ -n "$GITHUB_USER" ]; then
        echo ""
        print_github_ssh_key_guide "$GITHUB_USER" "$SSH_PUBKEY"
        echo ""
        read -p "Press Enter to continue..."
    fi

    read -p "Hypervisor (proxmox/hyperv): " HYPERVISOR || return 1
    HYPERVISOR=${HYPERVISOR:-proxmox}
    HYPERVISOR=$(trim_value "$HYPERVISOR")

    write_config_value "$tmp_config" "CONTROLLER_COUNT" "$CONTROLLER_COUNT"
    write_config_value "$tmp_config" "CONTROLLER_WORKER" "$CONTROLLER_WORKER"
    write_config_value "$tmp_config" "CONTROLLER_IP" "$CONTROLLER_IP"
    write_config_array "$tmp_config" "ADDITIONAL_CONTROLLERS" "${ADDITIONAL_CONTROLLERS[@]}"
    write_config_array "$tmp_config" "WORKERS" "${WORKERS[@]}"
    write_config_value "$tmp_config" "CLUSTER_NAME" "$CLUSTER_NAME"
    write_config_value "$tmp_config" "POD_CIDR" "$POD_CIDR"
    write_config_value "$tmp_config" "SERVICE_CIDR" "$SERVICE_CIDR"
    write_config_value "$tmp_config" "INSTALL_CILIUM" "$INSTALL_CILIUM"
    write_config_value "$tmp_config" "GITHUB_USER" "$GITHUB_USER"
    write_config_value "$tmp_config" "SSH_PUBKEY" "$SSH_PUBKEY"
    write_config_value "$tmp_config" "HYPERVISOR" "$HYPERVISOR"

    if ! validate_config_file "$tmp_config"; then
        print_error "New config failed validation. Existing $CONFIG_FILE was not changed."
        rm -f "$tmp_config"
        return 1
    fi

    mv "$tmp_config" "$CONFIG_FILE"

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

    validate_config_file "$CONFIG_FILE" || return 1
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

    local CTRL_HOSTNAME="${CLUSTER_NAME}-ctrl-1"

    local K0S_ARGS
    K0S_ARGS=$(build_controller_k0s_args false)

    # Base64-encode script for compact embedding (avoids YAML indentation bloat)
    local SCRIPT_B64=$(script_base64_lf "$0")

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
${K0S_ARGS}

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
      CONTROLLER_COUNT=${CONTROLLER_COUNT}
      CONTROLLER_IP=${CONTROLLER_IP}
      CONTROLLER_WORKER=${CONTROLLER_WORKER}
      ADDITIONAL_CONTROLLERS=(${ADDITIONAL_CONTROLLERS[@]})
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
    - name: "Update cluster manager script safely"
      commands:
        - ${SAFE_SCRIPT_UPDATE_COMMAND}
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
    print_info "Next: use main menu option 5 -> 1 to send this config to the primary controller installer."
}

# Generates the worker cloud-config. Requires a token from the controller.
# Parameters: $1 = worker token, $2 = worker node IP (optional), $3 = worker index (optional)
generate_worker_cloudconfig() {
    local WORKER_TOKEN="$1"
    local NODE_IP="$2"
    local NODE_INDEX="$3"

    if [ -z "$WORKER_TOKEN" ]; then
        print_error "No worker token provided."
        return 1
    fi

    local NODE_HOSTNAME
    local OUTPUT_FILE
    if [ -n "$NODE_IP" ]; then
        NODE_INDEX=${NODE_INDEX:-$(worker_index_for_ip "$NODE_IP")}
        if [ -z "$NODE_INDEX" ]; then
            print_error "Could not determine worker index for IP: ${NODE_IP}"
            return 1
        fi
        NODE_HOSTNAME="${CLUSTER_NAME}-wrkr-${NODE_INDEX}"
        OUTPUT_FILE="worker-cloud-config-${NODE_INDEX}.yaml"
    else
        NODE_HOSTNAME="${CLUSTER_NAME}-wrkr"
        OUTPUT_FILE="$WORKER_CC_FILE"
    fi

    print_info "Generating worker cloud-config for ${NODE_HOSTNAME} → ${OUTPUT_FILE}..."

    # Install block — auto-install with nousers:true REQUIRED for curl injection
    local INSTALL_BLOCK="install:
  device: auto
  auto: true
  poweroff: true
  nousers: true
  grub_options:
    extra_cmdline: \"rd.neednet=1\""

    # Build SSH keys block (github key always, raw key as fallback if provided)
    local SSH_KEYS_BLOCK="      - github:${GITHUB_USER}"
    if [ -n "$SSH_PUBKEY" ]; then
        SSH_KEYS_BLOCK="${SSH_KEYS_BLOCK}"$'\n'"      - ${SSH_PUBKEY}"
    fi

    # Hash the password — Kairos v4.x needs SHA-512 crypt, not cleartext
    local USER_PASSWD=$(hash_password "kairos")

    # Base64-encode script for compact embedding
    local SCRIPT_B64=$(script_base64_lf "$0")

    cat > "$OUTPUT_FILE" << EOF
#cloud-config
# Worker node cloud-config for Kairos + k0s
# Generated for: ${NODE_HOSTNAME}${NODE_IP:+ (}${NODE_IP}${NODE_IP:+)}
# Reference: https://kairos.io/docs/reference/configuration/

hostname: ${NODE_HOSTNAME}

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
      CONTROLLER_COUNT=${CONTROLLER_COUNT}
      CONTROLLER_IP=${CONTROLLER_IP}
      CONTROLLER_WORKER=${CONTROLLER_WORKER}
      ADDITIONAL_CONTROLLERS=(${ADDITIONAL_CONTROLLERS[@]})
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
    - name: "Update cluster manager script safely"
      commands:
        - ${SAFE_SCRIPT_UPDATE_COMMAND}
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
        cat >> "$OUTPUT_FILE" << 'BUNDLEEOF'
bundles:
  - targets:
      - run://quay.io/kairos/community-bundles:qemu-guest-agent_latest
BUNDLEEOF
    fi

    print_successful "Worker cloud-config written to ${OUTPUT_FILE}"
}

# Produces one cloud-config per worker: worker-cloud-config-<index>.yaml
# If no WORKERS defined, produces a generic worker-cloud-config.yaml
generate_worker_token() {
    print_info "Generating worker join token + cloud-config..."

    local token
    if [ -s .k0s_worker_token ]; then
        token=$(cat .k0s_worker_token)
        print_info "Reusing existing worker token from .k0s_worker_token"
    else
        if ! command -v k0s &>/dev/null; then
            print_error "k0s not found. Are you on the controller node?"
            return 1
        fi

        print_info "Running: k0s token create --role=worker"
        token=$(k0s token create --role=worker 2>&1)

        if [ -z "$token" ]; then
            print_error "Failed to create worker token. Is k0s running?"
            return 1
        fi

        print_successful "Worker token created."
        echo "$token" > .k0s_worker_token
    fi

    if [ ${#WORKERS[@]} -eq 0 ]; then
        print_warning "No worker IPs defined in config — generating generic worker-cloud-config.yaml"
        generate_worker_cloudconfig "$token" ""
        print_info "Next: use main menu option 5 -> 6 to send this generic worker config to a custom installer target."
    else
        local generated_files=()
        local i
        for i in "${!WORKERS[@]}"; do
            generate_worker_cloudconfig "$token" "${WORKERS[$i]}" "$((i + 1))"
            generated_files+=("worker-cloud-config-$((i + 1)).yaml")
        done
        print_successful "All worker cloud-configs generated."
        print_info "Files: ${generated_files[*]}"
        print_info "Next: use main menu option 5 -> 4 for one worker, or option 5 -> 5 for all workers."
    fi
}

# -----------------------------------------------------------------------------
# Controller join token + cloud-config (HA) — runs on the first controller.
# Reuses an existing .k0s_controller_token if present; otherwise generates a new one.
# Produces one cloud-config per additional controller: controller-join-cloud-config-<index>.yaml
generate_controller_token() {
    print_info "Generating controller join token + cloud-config..."

    local token
    if [ -s .k0s_controller_token ]; then
        token=$(cat .k0s_controller_token)
        print_info "Reusing existing controller token from .k0s_controller_token"
    else
        if ! command -v k0s &>/dev/null; then
            print_error "k0s not found. Are you on the controller node?"
            return 1
        fi

        print_info "Running: k0s token create --role=controller"
        token=$(k0s token create --role=controller 2>&1)

        if [ -z "$token" ]; then
            print_error "Failed to create controller join token. Is k0s running?"
            return 1
        fi

        print_successful "Controller join token created."
        echo "$token" > .k0s_controller_token
    fi

    # Generate one config per additional controller IP
    if [ ${#ADDITIONAL_CONTROLLERS[@]} -eq 0 ]; then
        print_warning "No additional controller IPs defined in config — nothing to generate."
        return 0
    fi

    local i
    local generated_files=()
    for i in "${!ADDITIONAL_CONTROLLERS[@]}"; do
        generate_controller_join_cloudconfig "$token" "${ADDITIONAL_CONTROLLERS[$i]}" "$((i + 2))"
        generated_files+=("controller-join-cloud-config-$((i + 2)).yaml")
    done

    print_successful "All controller join cloud-configs generated."
    print_info "Files: ${generated_files[*]}"
    print_info "Next: use main menu option 5 -> 2 for one additional controller, or option 5 -> 3 for all additional controllers."
}

# Generates a cloud-config for one additional HA controller that joins the cluster.
# Called by generate_controller_token() once per additional controller IP.
# Parameters: $1 = join token, $2 = this node's IP address, $3 = controller index
generate_controller_join_cloudconfig() {
    local CTRL_TOKEN="$1"
    local NODE_IP="$2"
    local NODE_INDEX="$3"

    if [ -z "$CTRL_TOKEN" ]; then
        print_error "No controller join token provided."
        return 1
    fi
    if [ -z "$NODE_IP" ]; then
        print_error "No node IP provided (second argument required)."
        return 1
    fi

    NODE_INDEX=${NODE_INDEX:-$(controller_index_for_ip "$NODE_IP")}
    if [ -z "$NODE_INDEX" ]; then
        print_error "Could not determine controller index for IP: ${NODE_IP}"
        return 1
    fi

    local NODE_HOSTNAME="${CLUSTER_NAME}-ctrl-${NODE_INDEX}"

    local OUTPUT_FILE="controller-join-cloud-config-${NODE_INDEX}.yaml"

    local K0S_ARGS
    K0S_ARGS=$(build_controller_k0s_args true)

    print_info "Generating controller join cloud-config for ${NODE_HOSTNAME} (${NODE_IP}) → ${OUTPUT_FILE}..."

    # Install block — auto-install with nousers:true is REQUIRED for curl injection
    # nousers:true bypasses the Kairos agent v3.3+ admin-group validation
    local INSTALL_BLOCK="install:
  device: auto
  auto: true
  poweroff: true
  nousers: true
  grub_options:
    extra_cmdline: \"rd.neednet=1\""

    # Build SSH keys block
    local SSH_KEYS_BLOCK="      - github:${GITHUB_USER}"
    if [ -n "$SSH_PUBKEY" ]; then
        SSH_KEYS_BLOCK="${SSH_KEYS_BLOCK}"$'\n'"      - ${SSH_PUBKEY}"
    fi

    # Hash the password — Kairos v4.x needs SHA-512 crypt, not cleartext
    local USER_PASSWD=$(hash_password "kairos")

    # Base64-encode script for compact embedding
    local SCRIPT_B64=$(script_base64_lf "$0")

    cat > "$OUTPUT_FILE" << EOF
#cloud-config
# Additional controller node cloud-config for Kairos + k0s (HA join)
# Generated for: ${NODE_HOSTNAME} (${NODE_IP})
# The provider detects /etc/k0s/token and joins instead of init.
# Reference: https://kairos.io/docs/reference/configuration/

hostname: ${NODE_HOSTNAME}

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
${K0S_ARGS}

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
          address: ${NODE_IP}
          externalAddress: ${NODE_IP}
          port: 6443
          sans:
            - ${CONTROLLER_IP}
            - ${NODE_IP}
        network:
          provider: custom
          podCIDR: ${POD_CIDR}
          serviceCIDR: ${SERVICE_CIDR}
          kubeProxy:
            disabled: true
        storage:
          type: etcd
          etcd:
            peerAddress: ${NODE_IP}
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
      CONTROLLER_COUNT=${CONTROLLER_COUNT}
      CONTROLLER_IP=${CONTROLLER_IP}
      CONTROLLER_WORKER=${CONTROLLER_WORKER}
      ADDITIONAL_CONTROLLERS=(${ADDITIONAL_CONTROLLERS[@]})
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
    - name: "Update cluster manager script safely"
      commands:
        - ${SAFE_SCRIPT_UPDATE_COMMAND}
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
        cat >> "$OUTPUT_FILE" << 'BUNDLEEOF'
bundles:
  - targets:
      - run://quay.io/kairos/community-bundles:qemu-guest-agent_latest
BUNDLEEOF
    fi

    print_successful "Controller join cloud-config written to ${OUTPUT_FILE}"
    print_info "Installer target: http://${NODE_IP}:8080"
}

# -----------------------------------------------------------------------------
# Kairos Web Installer injection
# -----------------------------------------------------------------------------
normalize_installer_url() {
    local target="$1"
    target="${target%/}"

    case "$target" in
        http://*|https://*) echo "$target" ;;
        *:*) echo "http://${target}" ;;
        *) echo "http://${target}:8080" ;;
    esac
}

controller_join_cloudconfig_file_for_ip() {
    local node_ip="$1"
    local node_index
    node_index=$(controller_index_for_ip "$node_ip")
    if [ -n "$node_index" ]; then
        echo "controller-join-cloud-config-${node_index}.yaml"
    else
        echo "controller-join-cloud-config-unknown.yaml"
    fi
}

worker_cloudconfig_file_for_ip() {
    local node_ip="$1"
    local node_index
    node_index=$(worker_index_for_ip "$node_ip")
    if [ -n "$node_index" ]; then
        echo "worker-cloud-config-${node_index}.yaml"
    else
        echo "worker-cloud-config-unknown.yaml"
    fi
}

controller_index_for_ip() {
    local node_ip="$1"
    local i

    if [ "$node_ip" = "$CONTROLLER_IP" ]; then
        echo 1
        return 0
    fi

    for i in "${!ADDITIONAL_CONTROLLERS[@]}"; do
        if [ "$node_ip" = "${ADDITIONAL_CONTROLLERS[$i]}" ]; then
            echo "$((i + 2))"
            return 0
        fi
    done
}

worker_index_for_ip() {
    local node_ip="$1"
    local i

    for i in "${!WORKERS[@]}"; do
        if [ "$node_ip" = "${WORKERS[$i]}" ]; then
            echo "$((i + 1))"
            return 0
        fi
    done
}

worker_hostname_for_ip() {
    local node_ip="$1"
    local node_index
    node_index=$(worker_index_for_ip "$node_ip")
    if [ -n "$node_index" ]; then
        echo "${CLUSTER_NAME}-wrkr-${node_index}"
    else
        echo ""
    fi
}

join_by_comma() {
    local result=""
    local item
    for item in "$@"; do
        if [ -z "$result" ]; then
            result="$item"
        else
            result="${result}, ${item}"
        fi
    done
    echo "$result"
}

mark_worker_install_submitted() {
    local worker_ip="$1"
    [ -z "$worker_ip" ] && return 0

    touch "$WORKER_INSTALL_STATE_FILE"
    if ! grep -qx "$worker_ip" "$WORKER_INSTALL_STATE_FILE" 2>/dev/null; then
        echo "$worker_ip" >> "$WORKER_INSTALL_STATE_FILE"
    fi
}

count_submitted_worker_installs() {
    local count=0
    local worker_ip

    if [ ! -f "$WORKER_INSTALL_STATE_FILE" ]; then
        echo 0
        return 0
    fi

    for worker_ip in "${WORKERS[@]}"; do
        if grep -qx "$worker_ip" "$WORKER_INSTALL_STATE_FILE" 2>/dev/null; then
            count=$((count + 1))
        fi
    done

    echo "$count"
}

all_worker_installs_submitted() {
    [ ${#WORKERS[@]} -gt 0 ] || return 1
    [ "$(count_submitted_worker_installs)" -eq "${#WORKERS[@]}" ]
}

cilium_requested() {
    case "${INSTALL_CILIUM:-n}" in
        y|Y|yes|YES|true|TRUE) return 0 ;;
        *) return 1 ;;
    esac
}

cilium_already_installed() {
    command -v k0s &>/dev/null || return 1
    k0s kubectl get daemonset cilium -n kube-system &>/dev/null
}

all_configured_workers_registered() {
    command -v k0s &>/dev/null || return 1

    local worker_ip worker_name
    for worker_ip in "${WORKERS[@]}"; do
        worker_name=$(worker_hostname_for_ip "$worker_ip")
        if ! k0s kubectl get node "$worker_name" &>/dev/null; then
            return 1
        fi
    done

    return 0
}

print_worker_registration_status() {
    command -v k0s &>/dev/null || return 1

    local worker_ip worker_name status
    for worker_ip in "${WORKERS[@]}"; do
        worker_name=$(worker_hostname_for_ip "$worker_ip")
        status=$(k0s kubectl get node "$worker_name" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null)
        if [ -n "$status" ]; then
            echo "  ${worker_name} (${worker_ip}): registered, Ready=${status}"
        else
            echo "  ${worker_name} (${worker_ip}): not registered yet"
        fi
    done
}

wait_for_configured_workers_registered() {
    local timeout_seconds="${1:-1800}"
    local deadline=$((SECONDS + timeout_seconds))

    if ! command -v k0s &>/dev/null; then
        print_warning "k0s not found on this machine. Auto Cilium install must run from a controller."
        return 1
    fi

    print_info "Waiting for all configured workers to register with k0s..."
    print_info "Workers can be NotReady here; Cilium is what makes them Ready."
    while [ "$SECONDS" -lt "$deadline" ]; do
        print_worker_registration_status
        if all_configured_workers_registered; then
            print_successful "All configured workers are registered."
            return 0
        fi
        sleep 15
    done

    print_warning "Timed out waiting for workers to register."
    print_info "If the installers powered off after install, start the worker VMs and run Manage Cilium -> Install Cilium later."
    return 1
}

maybe_auto_install_cilium_after_worker_install() {
    cilium_requested || return 0

    if [ ${#WORKERS[@]} -eq 0 ]; then
        print_info "INSTALL_CILIUM=y, but no separate workers are configured."
        return 0
    fi

    if cilium_already_installed; then
        print_successful "Cilium is already installed."
        return 0
    fi

    local submitted_count
    submitted_count=$(count_submitted_worker_installs)
    if ! all_worker_installs_submitted; then
        print_info "INSTALL_CILIUM=y. Waiting until all worker installs are submitted before deploying Cilium (${submitted_count}/${#WORKERS[@]} submitted)."
        return 0
    fi

    print_successful "All configured worker install requests have been submitted (${submitted_count}/${#WORKERS[@]})."
    print_warning "Cilium will install only after the workers reboot and appear as k0s nodes."
    read -p "Wait for workers and install Cilium now? (y/n, default: y): " install_now
    install_now=${install_now:-y}
    if [ "$install_now" != "y" ]; then
        print_info "Auto install skipped. Later run Manage Cilium -> Install Cilium."
        return 0
    fi

    wait_for_configured_workers_registered 1800 || return 1

    if cilium_already_installed; then
        print_successful "Cilium is already installed."
        return 0
    fi

    print_info "Installing Cilium now..."
    install_cilium
}

inject_cloudconfig_webinstaller() {
    local preset_file="$1"
    local preset_target="$2"

    print_info "Injecting cloud-config into Kairos Web Installer..."

    if ! command -v curl &>/dev/null; then
        print_error "curl not found. Cannot submit to the web installer."
        return 1
    fi

    local cloud_config_file
    if [ -n "$preset_file" ]; then
        cloud_config_file="$preset_file"
        print_info "Cloud-config file: ${cloud_config_file}"
    else
        print_info "Available YAML files:"
        ls *.yaml 2>/dev/null || print_warning "No YAML files found in the current directory."

        read -p "Cloud-config file (default: ${CONTROLLER_CC_FILE}): " cloud_config_file
        cloud_config_file=${cloud_config_file:-$CONTROLLER_CC_FILE}
    fi

    if [ ! -f "$cloud_config_file" ]; then
        print_error "Cloud-config file not found: $cloud_config_file"
        return 1
    fi

    local default_target=""
    if [ -n "${CONTROLLER_IP:-}" ]; then
        default_target="http://${CONTROLLER_IP}:8080"
    fi

    local target
    if [ -n "$preset_target" ]; then
        target="$preset_target"
        print_info "Installer target: ${target}"
    elif [ -n "$default_target" ]; then
        read -p "Installer IP or URL (default: ${default_target}): " target
        target=${target:-$default_target}
    else
        read -p "Installer IP or URL (example: 172.20.1.1:8080): " target
    fi

    if [ -z "$target" ]; then
        print_error "No installer target provided."
        return 1
    fi

    local installer_url
    installer_url=$(normalize_installer_url "$target")

    local install_device
    read -p "Install device (default: auto): " install_device
    install_device=${install_device:-auto}

    local reboot_after
    read -p "Reboot after installation? (y/n, default: n): " reboot_after
    reboot_after=${reboot_after:-n}

    local poweroff_default="y"
    case "$reboot_after" in
        y|Y|yes|YES) poweroff_default="n" ;;
    esac

    local poweroff_after
    read -p "Power off after installation? (y/n, default: ${poweroff_default}): " poweroff_after
    poweroff_after=${poweroff_after:-$poweroff_default}

    print_info "Validating cloud-config against ${installer_url}/validate..."
    local validation_output
    validation_output=$(curl -sS -X POST -F "cloud-config=<${cloud_config_file}" "${installer_url}/validate" 2>&1)
    local validation_rc=$?
    if [ $validation_rc -ne 0 ]; then
        print_error "Validation request failed:"
        echo "$validation_output"
        return 1
    fi

    if [ -n "$validation_output" ]; then
        print_error "Installer validation failed:"
        echo "$validation_output"
        return 1
    fi

    print_successful "Cloud-config validated successfully."
    print_warning "This will install Kairos using:"
    print_warning "  URL: ${installer_url}/install"
    print_warning "  Config: ${cloud_config_file}"
    print_warning "  Device: ${install_device}"
    print_warning "  Reboot: ${reboot_after}"
    print_warning "  Power off: ${poweroff_after}"
    read -p "Type INSTALL to submit and start installation: " confirm_install
    if [ "$confirm_install" != "INSTALL" ]; then
        print_warning "Install cancelled."
        return 2
    fi

    local curl_args=(-X POST -F "cloud-config=<${cloud_config_file}" -F "installation-device=${install_device}")
    case "$reboot_after" in
        y|Y|yes|YES) curl_args+=(-F "reboot=on") ;;
    esac
    case "$poweroff_after" in
        y|Y|yes|YES) curl_args+=(-F "power-off=on") ;;
    esac

    print_info "Submitting install request..."
    if curl -S "${curl_args[@]}" "${installer_url}/install"; then
        print_successful "Install request submitted."
    else
        print_error "Install request failed."
        return 1
    fi
}

inject_one_additional_controller() {
    if [ ${#ADDITIONAL_CONTROLLERS[@]} -eq 0 ]; then
        print_warning "No additional controllers configured."
        return 0
    fi

    print_info "Additional controllers:"
    local i
    for i in "${!ADDITIONAL_CONTROLLERS[@]}"; do
        local ctrl_ip="${ADDITIONAL_CONTROLLERS[$i]}"
        echo "$((i + 1)). ${ctrl_ip} ($(controller_join_cloudconfig_file_for_ip "$ctrl_ip"))"
    done

    local selection ctrl_ip
    read -p "Select controller number or enter IP: " selection
    if [[ "$selection" =~ ^[0-9]+$ ]] && [ "$selection" -ge 1 ] && [ "$selection" -le ${#ADDITIONAL_CONTROLLERS[@]} ]; then
        ctrl_ip="${ADDITIONAL_CONTROLLERS[$((selection - 1))]}"
    else
        ctrl_ip="$selection"
    fi

    if [ -z "$ctrl_ip" ]; then
        print_error "No controller selected."
        return 1
    fi

    inject_cloudconfig_webinstaller "$(controller_join_cloudconfig_file_for_ip "$ctrl_ip")" "$ctrl_ip"
}

inject_all_additional_controllers() {
    if [ ${#ADDITIONAL_CONTROLLERS[@]} -eq 0 ]; then
        print_warning "No additional controllers configured."
        return 0
    fi

    local ctrl_ip
    for ctrl_ip in "${ADDITIONAL_CONTROLLERS[@]}"; do
        inject_cloudconfig_webinstaller "$(controller_join_cloudconfig_file_for_ip "$ctrl_ip")" "$ctrl_ip" || return 1
    done
}

inject_one_worker() {
    if [ ${#WORKERS[@]} -eq 0 ]; then
        print_warning "No workers configured."
        return 0
    fi

    print_info "Workers:"
    local i
    for i in "${!WORKERS[@]}"; do
        local worker_ip="${WORKERS[$i]}"
        echo "$((i + 1)). ${worker_ip} ($(worker_cloudconfig_file_for_ip "$worker_ip"))"
    done

    local selection worker_ip
    read -p "Select worker number or enter IP: " selection
    if [[ "$selection" =~ ^[0-9]+$ ]] && [ "$selection" -ge 1 ] && [ "$selection" -le ${#WORKERS[@]} ]; then
        worker_ip="${WORKERS[$((selection - 1))]}"
    else
        worker_ip="$selection"
    fi

    if [ -z "$worker_ip" ]; then
        print_error "No worker selected."
        return 1
    fi

    if inject_cloudconfig_webinstaller "$(worker_cloudconfig_file_for_ip "$worker_ip")" "$worker_ip"; then
        mark_worker_install_submitted "$worker_ip"
        maybe_auto_install_cilium_after_worker_install
    fi
}

inject_all_workers() {
    if [ ${#WORKERS[@]} -eq 0 ]; then
        print_warning "No workers configured."
        return 0
    fi

    local worker_ip
    for worker_ip in "${WORKERS[@]}"; do
        if inject_cloudconfig_webinstaller "$(worker_cloudconfig_file_for_ip "$worker_ip")" "$worker_ip"; then
            mark_worker_install_submitted "$worker_ip"
        else
            return 1
        fi
    done

    maybe_auto_install_cilium_after_worker_install
}

manage_web_installer() {
    while true; do
        local additional_controller_label="none configured"
        local worker_label="none configured"
        if [ ${#ADDITIONAL_CONTROLLERS[@]} -gt 0 ]; then
            additional_controller_label=$(join_by_comma "${ADDITIONAL_CONTROLLERS[@]}")
        fi
        if [ ${#WORKERS[@]} -gt 0 ]; then
            worker_label=$(join_by_comma "${WORKERS[@]}")
        fi

        echo -e "\n${YELLOW}======== Kairos Web Installer ========${NC}"
        echo "1. Install primary controller (${CONTROLLER_IP})"
        echo "2. Install one additional controller (${additional_controller_label})"
        echo "3. Install all additional controllers (${additional_controller_label})"
        echo "4. Install one worker (${worker_label})"
        echo "5. Install all workers (${worker_label})"
        echo "6. Custom YAML / installer target"
        echo "7. Back"
        echo -e "${YELLOW}======================================${NC}"
        read -p "Enter your choice: " web_choice

        case $web_choice in
            1) inject_cloudconfig_webinstaller "$CONTROLLER_CC_FILE" "$CONTROLLER_IP" ;;
            2) inject_one_additional_controller ;;
            3) inject_all_additional_controllers ;;
            4) inject_one_worker ;;
            5) inject_all_workers ;;
            6) inject_cloudconfig_webinstaller ;;
            7) return 0 ;;
            *) print_error "Invalid option." ;;
        esac
    done
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
        sudo tar xzvf "cilium-linux-${CLI_ARCH}.tar.gz" -C /usr/local/bin
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

    if ! command -v k0s &>/dev/null; then
        print_error "k0s not found on this node."
        return 1
    fi

    print_info "k0s status:"
    k0s status 2>/dev/null || print_warning "Unable to read k0s status."
    echo ""

    print_info "Kubernetes API readiness:"
    local api_ready
    api_ready=$(k0s kubectl get --raw=/readyz 2>&1)
    if [ $? -eq 0 ]; then
        print_successful "API readyz: ${api_ready}"
    else
        print_warning "API readyz failed:"
        echo "$api_ready"
    fi
    echo ""

    print_info "k0s kubectl get node:"
    local nodes_compact_output
    nodes_compact_output=$(k0s kubectl get node 2>&1)
    if [ $? -eq 0 ]; then
        echo "$nodes_compact_output"
    else
        print_warning "Could not list nodes:"
        echo "$nodes_compact_output"
    fi
    echo ""

    print_info "k0s kubectl get node -o wide:"
    local nodes_output
    nodes_output=$(k0s kubectl get node -o wide 2>&1)
    if [ $? -eq 0 ]; then
        echo "$nodes_output"
        local node_count
        node_count=$(echo "$nodes_output" | awk 'NR > 1 && NF { count++ } END { print count + 0 }')
        if [ "$node_count" -eq 0 ]; then
            print_info "No worker nodes are registered yet. This is expected for controller-only bootstrap before workers join."
        fi
    else
        print_warning "Could not list nodes:"
        echo "$nodes_output"
    fi
    echo ""

    print_info "Cluster pods:"
    local pods_output
    pods_output=$(k0s kubectl get pods -A -o wide 2>&1)
    if [ $? -eq 0 ]; then
        echo "$pods_output"
    else
        print_warning "Could not list pods:"
        echo "$pods_output"
    fi

    echo ""
    if command -v cilium &>/dev/null; then
        print_info "Cilium status:"
        cilium status 2>/dev/null || print_info "Cilium CLI found but unable to get status."
    else
        if k0s kubectl get daemonset cilium -n kube-system &>/dev/null; then
            print_info "Cilium CLI not installed, but Cilium pods were found:"
            k0s kubectl get pods -n kube-system -l k8s-app=cilium -o wide 2>/dev/null
        else
            print_info "Cilium not detected yet. Run 'Manage Cilium' after the control plane is ready."
        fi
    fi
}

github_release_tags() {
    sed -n 's/.*"tag_name":[[:space:]]*"\([^"]*\)".*/\1/p'
}

# -----------------------------------------------------------------------------
# Cilium version / upgrade checks (ported from k3s script)
# -----------------------------------------------------------------------------
check_cilium_version() {
    print_info "Checking current Cilium version..."

    if command -v cilium &>/dev/null; then
        local cli_version=$(cilium version 2>/dev/null | grep "cilium-cli" | awk '{print $2}')
        print_successful "Cilium CLI Version: $cli_version"

        # Check Cilium version in the cluster
        export KUBECONFIG="${K0S_KUBECONFIG}"
        if kubectl get pods -n kube-system -l k8s-app=cilium &>/dev/null; then
            local cilium_version=""

            # Try cilium version command
            cilium_version=$(cilium version 2>/dev/null | grep -E "cilium-daemon|daemon" | head -n1 | awk '{print $2}' | tr -d 'v')

            # Fallback: kubectl from DaemonSet
            if [ -z "$cilium_version" ] || [ "$cilium_version" = "unknown" ]; then
                cilium_version=$(kubectl get daemonset cilium -n kube-system -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null | cut -d':' -f2)
            fi

            if [ -n "$cilium_version" ] && [ "$cilium_version" != "unknown" ]; then
                [[ ! "$cilium_version" =~ ^v ]] && cilium_version="v$cilium_version"
                print_successful "Cilium Version (in cluster): $cilium_version"
            else
                print_warning "Cilium Version (in cluster): Unable to determine"
                cilium_version=""
            fi

            # Check latest stable
            print_info "Checking latest stable Cilium version..."
            local latest_version
            latest_version=$(curl -s https://raw.githubusercontent.com/cilium/cilium/master/stable.txt 2>/dev/null)
            [ -z "$latest_version" ] && latest_version=$(curl -s https://api.github.com/repos/cilium/cilium/releases/latest 2>/dev/null | github_release_tags | head -n 1)
            print_successful "Latest Stable Cilium Version: $latest_version"

            if [ -n "$cilium_version" ] && [ "$cilium_version" = "$latest_version" ]; then
                print_successful "You are running the latest stable version."
            elif [ -n "$cilium_version" ]; then
                print_info "An upgrade is available from $cilium_version to $latest_version"
            fi
        else
            print_info "Cilium CLI is installed, but Cilium is not detected in the cluster."
            local latest_version
            latest_version=$(curl -s https://raw.githubusercontent.com/cilium/cilium/master/stable.txt 2>/dev/null)
            [ -z "$latest_version" ] && latest_version=$(curl -s https://api.github.com/repos/cilium/cilium/releases/latest 2>/dev/null | github_release_tags | head -n 1)
            print_successful "Latest Stable Cilium Version: $latest_version"
        fi
    else
        print_error "Cilium CLI is not installed or not in PATH."
        local latest_version
        latest_version=$(curl -s https://raw.githubusercontent.com/cilium/cilium/master/stable.txt 2>/dev/null)
        [ -z "$latest_version" ] && latest_version=$(curl -s https://api.github.com/repos/cilium/cilium/releases/latest 2>/dev/null | github_release_tags | head -n 1)
        print_successful "Latest Stable Cilium Version: $latest_version"
    fi
}

check_fluxcd_version() {
    print_info "Checking FluxCD version..."

    if command -v flux &>/dev/null; then
        local cli_version=$(flux --version 2>/dev/null | head -1)
        print_successful "Flux CLI Version: $cli_version"
    else
        print_info "Flux CLI not installed locally."
    fi

    # Check cluster-side Flux version
    export KUBECONFIG="${K0S_KUBECONFIG}"
    if kubectl get namespace flux-system &>/dev/null; then
        local cluster_version
        cluster_version=$(kubectl get deployment -n flux-system source-controller -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null | cut -d':' -f2)
        if [ -n "$cluster_version" ]; then
            print_successful "FluxCD Version (in cluster): $cluster_version"
        fi

        local latest_version
        latest_version=$(curl -s https://api.github.com/repos/fluxcd/flux2/releases/latest 2>/dev/null | github_release_tags | head -n 1)
        [ -n "$latest_version" ] && print_info "Latest FluxCD Version: $latest_version"
    else
        print_info "FluxCD not detected in cluster."
    fi
}

list_available_versions() {
    echo -e "${YELLOW}======== Available Versions ========${NC}"

    # k0s versions
    print_info "Latest k0s Releases (Last 5):"
    curl -s https://api.github.com/repos/k0sproject/k0s/releases 2>/dev/null | \
        github_release_tags | head -n 5 | \
        while read -r version; do echo "   $version"; done
    echo ""

    # Cilium versions
    print_info "Cilium Stable Version:"
    curl -s https://raw.githubusercontent.com/cilium/cilium/master/stable.txt 2>/dev/null | xargs -I{} echo "   {}"
    echo ""
    print_info "Latest Cilium Releases (Last 5):"
    curl -s https://api.github.com/repos/cilium/cilium/releases 2>/dev/null | \
        github_release_tags | head -n 5 | \
        while read -r version; do echo "   $version"; done
    echo ""

    # FluxCD versions
    print_info "Latest FluxCD Releases (Last 5):"
    curl -s https://api.github.com/repos/fluxcd/flux2/releases 2>/dev/null | \
        github_release_tags | head -n 5 | \
        while read -r version; do echo "   $version"; done
    echo ""

    # Kairos versions
    print_info "Latest Kairos Releases (Last 5):"
    curl -s https://api.github.com/repos/kairos-io/kairos/releases 2>/dev/null | \
        github_release_tags | head -n 5 | \
        while read -r version; do echo "   $version"; done

    echo -e "${YELLOW}===================================${NC}"
}

check_versions() {
    while true; do
        echo -e "${YELLOW}======== Version Check ========${NC}"
        echo "1. Check k0s Version"
        echo "2. Check Kairos Version"
        echo "3. Check Cilium Version"
        echo "4. Check FluxCD Version"
        echo "5. Check Script Version"
        echo "6. List Available Versions"
        echo "7. Check All Versions"
        echo "8. Back to Main Menu"
        if ! read -p "Enter your choice: " check_choice; then
            echo ""
            print_info "Input closed. Returning to main menu."
            return 0
        fi

        case $check_choice in
            1) check_k0s_version ;;
            2) check_kairos_version ;;
            3) check_cilium_version ;;
            4) check_fluxcd_version ;;
            5) check_script_version ;;
            6) list_available_versions ;;
            7)
                check_k0s_version; echo ""
                check_kairos_version; echo ""
                check_cilium_version; echo ""
                check_fluxcd_version; echo ""
                check_script_version; echo ""
                read -p "Would you like to see all available versions? (y/n): " list_choice
                [ "$list_choice" = "y" ] && list_available_versions
                ;;
            8) return 0 ;;
            "") continue ;;
            *) print_error "Invalid option." ;;
        esac
    done
}

upgrade_cilium() {
    print_info "Upgrading Cilium..."

    if ! command -v cilium &>/dev/null; then
        print_info "Cilium CLI not found. Installing it first..."
        install_cilium_cli
    else
        print_info "Upgrading Cilium CLI to the latest version..."
        local CILIUM_CLI_VERSION
        CILIUM_CLI_VERSION=$(curl -s https://raw.githubusercontent.com/cilium/cilium-cli/main/stable.txt)
        local CLI_ARCH=amd64
        curl -L --fail --remote-name-all \
            "https://github.com/cilium/cilium-cli/releases/download/${CILIUM_CLI_VERSION}/cilium-linux-${CLI_ARCH}.tar.gz"
        sudo tar xzvf "cilium-linux-${CLI_ARCH}.tar.gz" -C /usr/local/bin
        rm "cilium-linux-${CLI_ARCH}.tar.gz"
        print_successful "Cilium CLI upgraded to $CILIUM_CLI_VERSION"
    fi

    read -p "Enter specific Cilium version to upgrade to (leave empty for latest): " CILIUM_VERSION

    local VERSION_FLAG=""
    [ -n "$CILIUM_VERSION" ] && VERSION_FLAG="--version $CILIUM_VERSION"

    print_info "Upgrading Cilium in cluster..."
    export KUBECONFIG="${K0S_KUBECONFIG}"
    cilium upgrade $VERSION_FLAG

    print_info "Waiting for Cilium to be ready..."
    cilium status --wait
    print_successful "Cilium upgrade completed."
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
        upsert_config_value "$CONFIG_FILE" "CLUSTER_ASN" "$CLUSTER_ASN"
        upsert_config_value "$CONFIG_FILE" "PEER_ASN" "$PEER_ASN"
        upsert_config_value "$CONFIG_FILE" "PEER_IP" "$PEER_IP"
        upsert_config_array "$CONFIG_FILE" "NODE_HOSTNAMES" "${NODE_HOSTNAMES[@]}"
        upsert_config_value "$CONFIG_FILE" "LB_IP_START" "$LB_IP_START"
        upsert_config_value "$CONFIG_FILE" "LB_IP_END" "$LB_IP_END"
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

manage_cilium() {
    echo -e "${YELLOW}======== Cilium Management ========${NC}"
    echo "1. Install Cilium"
    echo "2. Upgrade Cilium"
    echo "3. Check Cilium Version"
    echo "4. Check Cilium Status"
    echo "5. Back to Main Menu"
    echo -e "${YELLOW}==================================${NC}"
    read -p "Enter your choice: " cilium_choice

    case $cilium_choice in
        1) ensure_config && install_cilium ;;
        2) upgrade_cilium ;;
        3) check_cilium_version ;;
        4)
            if command -v cilium &>/dev/null; then
                cilium status
            else
                print_error "Cilium CLI not installed."
            fi
            ;;
        5) return ;;
        *) print_error "Invalid option. Returning to main menu." ;;
    esac
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
# Longhorn backup inventory and selective restore
# -----------------------------------------------------------------------------
longhorn_kubectl() {
    if command -v k0s &>/dev/null; then
        k0s kubectl "$@"
    elif command -v kubectl &>/dev/null; then
        KUBECONFIG="$K0S_KUBECONFIG" kubectl "$@"
    else
        print_error "kubectl/k0s not found. Cannot query the cluster."
        return 1
    fi
}

longhorn_require_cluster() {
    if ! longhorn_kubectl get namespace longhorn-system &>/dev/null; then
        print_error "longhorn-system namespace not found. Deploy Longhorn with Flux first."
        return 1
    fi

    if ! longhorn_kubectl get crd backupvolumes.longhorn.io &>/dev/null; then
        print_error "Longhorn BackupVolume CRD not found. Wait for Longhorn to finish installing."
        return 1
    fi

    return 0
}

longhorn_json_field() {
    local json="$1"
    local field="$2"

    printf '%s' "$json" | sed -n "s/.*\"${field}\":\"\([^\"]*\)\".*/\1/p"
}

longhorn_display_value() {
    local value="$1"
    if [ -n "$value" ] && [ "$value" != "<no value>" ]; then
        printf '%s' "$value"
    else
        printf '-'
    fi
}

sanitize_k8s_name() {
    local value="$1"
    value=$(printf '%s' "$value" | tr '[:upper:]_' '[:lower:]-')
    value=$(printf '%s' "$value" | sed 's/[^a-z0-9.-]/-/g; s/^[^a-z0-9]*//; s/[^a-z0-9]*$//')
    [ -n "$value" ] && printf '%s' "$value" || printf 'restored-volume'
}

bytes_to_k8s_quantity() {
    local bytes="$1"
    local gib=$((1024 * 1024 * 1024))

    if [ -z "$bytes" ] || ! printf '%s' "$bytes" | grep -Eq '^[0-9]+$'; then
        printf '1Gi'
    elif [ $((bytes % gib)) -eq 0 ]; then
        printf '%sGi' "$((bytes / gib))"
    else
        printf '%s' "$bytes"
    fi
}

longhorn_backup_volume_lines() {
    longhorn_kubectl get backupvolumes.longhorn.io -n longhorn-system -o go-template='{{range .items}}{{.metadata.name}}{{"\t"}}{{.spec.volumeName}}{{"\t"}}{{.status.lastBackupName}}{{"\t"}}{{.status.lastBackupAt}}{{"\t"}}{{.status.size}}{{"\t"}}{{.status.storageClassName}}{{"\t"}}{{with .status.labels}}{{index . "KubernetesStatus"}}{{end}}{{"\t"}}{{with .status.labels}}{{index . "longhorn.io/volume-access-mode"}}{{end}}{{"\n"}}{{end}}'
}

longhorn_list_backup_inventory() {
    longhorn_require_cluster || return 1

    print_info "Longhorn backup target:"
    longhorn_kubectl get backuptargets.longhorn.io -n longhorn-system 2>/dev/null || \
        print_warning "BackupTarget CR not found or not ready yet."
    echo ""

    print_info "Latest backup per Longhorn backup volume:"
    local lines=()
    mapfile -t lines < <(longhorn_backup_volume_lines 2>/dev/null)

    if [ "${#lines[@]}" -eq 0 ]; then
        print_warning "No Longhorn backup volumes found. Confirm the backup target is configured and synced."
        return 0
    fi

    printf '%-4s %-24s %-34s %-22s %-20s %-8s %s\n' "NO" "NAMESPACE" "PVC" "LAST_BACKUP" "LAST_BACKUP_AT" "ACCESS" "SOURCE_VOLUME"
    local index=1
    local line backup_volume source_volume last_backup last_backup_at size_bytes storage_class kstatus access_mode
    local namespace pvc
    for line in "${lines[@]}"; do
        IFS=$'\t' read -r backup_volume source_volume last_backup last_backup_at size_bytes storage_class kstatus access_mode <<< "$line"
        [ -z "$last_backup" ] && continue
        namespace=$(longhorn_json_field "$kstatus" "namespace")
        pvc=$(longhorn_json_field "$kstatus" "pvcName")
        printf '%-4s %-24s %-34s %-22s %-20s %-8s %s\n' \
            "$index" \
            "$(longhorn_display_value "$namespace")" \
            "$(longhorn_display_value "$pvc")" \
            "$last_backup" \
            "$(longhorn_display_value "$last_backup_at")" \
            "$(longhorn_display_value "$access_mode")" \
            "$source_volume"
        index=$((index + 1))
    done
}

longhorn_restore_status() {
    longhorn_require_cluster || return 1

    print_info "Longhorn volumes and restore state:"
    longhorn_kubectl get volumes.longhorn.io -n longhorn-system \
        -o custom-columns=VOLUME:.metadata.name,STATE:.status.state,ROBUSTNESS:.status.robustness,RESTORE_REQUIRED:.status.restoreRequired,SIZE:.spec.size,FROM_BACKUP:.spec.fromBackup
}

longhorn_wait_for_restore() {
    local volume_name="$1"
    local timeout_seconds="${2:-1800}"
    local deadline=$((SECONDS + timeout_seconds))

    print_info "Waiting for Longhorn restore to complete for volume: $volume_name"
    while [ "$SECONDS" -lt "$deadline" ]; do
        local restore_required state robustness
        restore_required=$(longhorn_kubectl get volumes.longhorn.io "$volume_name" -n longhorn-system -o jsonpath='{.status.restoreRequired}' 2>/dev/null)
        state=$(longhorn_kubectl get volumes.longhorn.io "$volume_name" -n longhorn-system -o jsonpath='{.status.state}' 2>/dev/null)
        robustness=$(longhorn_kubectl get volumes.longhorn.io "$volume_name" -n longhorn-system -o jsonpath='{.status.robustness}' 2>/dev/null)

        printf '  volume=%s state=%s robustness=%s restoreRequired=%s\n' \
            "$volume_name" \
            "$(longhorn_display_value "$state")" \
            "$(longhorn_display_value "$robustness")" \
            "$(longhorn_display_value "$restore_required")"

        if [ "$restore_required" = "false" ]; then
            print_successful "Restore completed for $volume_name."
            return 0
        fi

        sleep 10
    done

    print_warning "Timed out waiting for restore. You can check again from the Longhorn menu."
    return 1
}

longhorn_selective_restore() {
    longhorn_require_cluster || return 1

    local lines=()
    mapfile -t lines < <(longhorn_backup_volume_lines 2>/dev/null)
    if [ "${#lines[@]}" -eq 0 ]; then
        print_warning "No Longhorn backup volumes found. Confirm the backup target is configured and synced."
        return 0
    fi

    local backup_volumes=()
    local source_volumes=()
    local last_backups=()
    local last_backup_ats=()
    local size_bytes_values=()
    local storage_classes=()
    local namespaces=()
    local pvcs=()
    local pods=()
    local workloads=()
    local access_modes=()

    printf '%-4s %-24s %-34s %-22s %-20s %-8s %s\n' "NO" "NAMESPACE" "PVC" "LAST_BACKUP" "LAST_BACKUP_AT" "ACCESS" "SOURCE_VOLUME"
    local index=1
    local line backup_volume source_volume last_backup last_backup_at size_bytes storage_class kstatus access_mode
    local namespace pvc pod workload
    for line in "${lines[@]}"; do
        IFS=$'\t' read -r backup_volume source_volume last_backup last_backup_at size_bytes storage_class kstatus access_mode <<< "$line"
        [ -z "$last_backup" ] && continue

        namespace=$(longhorn_json_field "$kstatus" "namespace")
        pvc=$(longhorn_json_field "$kstatus" "pvcName")
        pod=$(longhorn_json_field "$kstatus" "podName")
        workload=$(longhorn_json_field "$kstatus" "workloadName")
        access_mode=${access_mode:-rwo}
        storage_class=${storage_class:-longhorn}

        backup_volumes+=("$backup_volume")
        source_volumes+=("$source_volume")
        last_backups+=("$last_backup")
        last_backup_ats+=("$last_backup_at")
        size_bytes_values+=("$size_bytes")
        storage_classes+=("$storage_class")
        namespaces+=("$namespace")
        pvcs+=("$pvc")
        pods+=("$pod")
        workloads+=("$workload")
        access_modes+=("$access_mode")

        printf '%-4s %-24s %-34s %-22s %-20s %-8s %s\n' \
            "$index" \
            "$(longhorn_display_value "$namespace")" \
            "$(longhorn_display_value "$pvc")" \
            "$last_backup" \
            "$(longhorn_display_value "$last_backup_at")" \
            "$(longhorn_display_value "$access_mode")" \
            "$source_volume"
        index=$((index + 1))
    done

    if [ "${#last_backups[@]}" -eq 0 ]; then
        print_warning "Backup volumes exist, but none have a latest backup recorded yet."
        return 0
    fi

    echo ""
    read -p "Select backup volume number to restore: " selection
    if ! printf '%s' "$selection" | grep -Eq '^[0-9]+$' || [ "$selection" -lt 1 ] || [ "$selection" -gt "${#last_backups[@]}" ]; then
        print_error "Invalid selection."
        return 1
    fi

    local selected=$((selection - 1))
    local selected_backup="${last_backups[$selected]}"
    local selected_source="${source_volumes[$selected]}"
    local selected_namespace="${namespaces[$selected]}"
    local selected_pvc="${pvcs[$selected]}"
    local selected_pod="${pods[$selected]}"
    local selected_workload="${workloads[$selected]}"
    local selected_access_mode="${access_modes[$selected]}"
    local selected_storage_class="${storage_classes[$selected]}"

    print_info "Selected backup:"
    echo "  Backup:        $selected_backup"
    echo "  Source volume: $selected_source"
    echo "  Namespace:     $(longhorn_display_value "$selected_namespace")"
    echo "  PVC:           $(longhorn_display_value "$selected_pvc")"
    echo "  Workload:      $(longhorn_display_value "$selected_workload")"
    echo "  Pod:           $(longhorn_display_value "$selected_pod")"
    echo "  Access mode:   $selected_access_mode"
    echo ""

    local backup_url volume_size
    backup_url=$(longhorn_kubectl get backups.longhorn.io "$selected_backup" -n longhorn-system -o jsonpath='{.status.url}' 2>/dev/null)
    volume_size=$(longhorn_kubectl get backups.longhorn.io "$selected_backup" -n longhorn-system -o jsonpath='{.status.volumeSize}' 2>/dev/null)
    if [ -z "$backup_url" ] || [ -z "$volume_size" ]; then
        print_error "Could not read backup URL/size from Backup CR: $selected_backup"
        print_info "Check that the new cluster has synced all backups from the backup target."
        return 1
    fi

    local default_volume_name
    if [ -n "$selected_namespace" ] && [ -n "$selected_pvc" ]; then
        default_volume_name=$(sanitize_k8s_name "${selected_namespace}-${selected_pvc}")
    else
        default_volume_name=$(sanitize_k8s_name "${selected_source}-restore")
    fi

    local restore_volume_name target_namespace target_pvc storage_class replicas pv_name access_mode_k8s storage_quantity
    read -p "Restored Longhorn volume name (default: ${default_volume_name}): " restore_volume_name
    restore_volume_name=${restore_volume_name:-$default_volume_name}
    restore_volume_name=$(sanitize_k8s_name "$restore_volume_name")

    read -p "Target PVC namespace (default: ${selected_namespace:-default}): " target_namespace
    target_namespace=${target_namespace:-${selected_namespace:-default}}
    target_namespace=$(sanitize_k8s_name "$target_namespace")

    read -p "Target PVC name (default: ${selected_pvc:-${restore_volume_name}-pvc}): " target_pvc
    target_pvc=${target_pvc:-${selected_pvc:-${restore_volume_name}-pvc}}
    target_pvc=$(sanitize_k8s_name "$target_pvc")

    read -p "StorageClass name (default: ${selected_storage_class:-longhorn}): " storage_class
    storage_class=${storage_class:-${selected_storage_class:-longhorn}}

    read -p "Longhorn replica count (default: 3): " replicas
    replicas=${replicas:-3}
    if ! printf '%s' "$replicas" | grep -Eq '^[0-9]+$' || [ "$replicas" -lt 1 ]; then
        print_error "Replica count must be a positive integer."
        return 1
    fi

    pv_name="$restore_volume_name"
    storage_quantity=$(bytes_to_k8s_quantity "$volume_size")
    if [ "$selected_access_mode" = "rwx" ]; then
        access_mode_k8s="ReadWriteMany"
    else
        access_mode_k8s="ReadWriteOnce"
        selected_access_mode="rwo"
    fi

    local file_prefix restore_manifest bind_manifest
    file_prefix=$(sanitize_k8s_name "${target_namespace}-${target_pvc}-${selected_backup}")
    restore_manifest="./longhorn-restore-${file_prefix}.yaml"
    bind_manifest="./longhorn-bind-${file_prefix}.yaml"

    cat > "$restore_manifest" << EOF
apiVersion: longhorn.io/v1beta2
kind: Volume
metadata:
  name: ${restore_volume_name}
  namespace: longhorn-system
spec:
  size: "${volume_size}"
  fromBackup: "${backup_url}"
  numberOfReplicas: ${replicas}
  frontend: blockdev
  dataEngine: v1
  accessMode: ${selected_access_mode}
EOF

    cat > "$bind_manifest" << EOF
apiVersion: v1
kind: PersistentVolume
metadata:
  name: ${pv_name}
spec:
  capacity:
    storage: ${storage_quantity}
  volumeMode: Filesystem
  accessModes:
    - ${access_mode_k8s}
  persistentVolumeReclaimPolicy: Retain
  storageClassName: ${storage_class}
  csi:
    driver: driver.longhorn.io
    fsType: ext4
    volumeAttributes:
      numberOfReplicas: "${replicas}"
      staleReplicaTimeout: "30"
    volumeHandle: ${restore_volume_name}
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: ${target_pvc}
  namespace: ${target_namespace}
spec:
  accessModes:
    - ${access_mode_k8s}
  storageClassName: ${storage_class}
  volumeName: ${pv_name}
  resources:
    requests:
      storage: ${storage_quantity}
EOF

    print_successful "Generated restore manifest: $restore_manifest"
    print_successful "Generated PV/PVC bind manifest: $bind_manifest"
    print_warning "Keep the application stopped until Longhorn restoreRequired=false."
    echo ""

    read -p "Apply the Longhorn Volume restore manifest now? Type RESTORE to continue: " confirm_restore
    if [ "$confirm_restore" != "RESTORE" ]; then
        print_info "Restore not applied. You can apply later with:"
        echo "  kubectl apply -f $restore_manifest"
        return 0
    fi

    longhorn_kubectl apply -f "$restore_manifest" || return 1
    print_successful "Restore requested for Longhorn volume: $restore_volume_name"
    echo ""

    read -p "Wait for restore and apply PV/PVC binding now? (y/n): " bind_now
    if [ "$bind_now" != "y" ]; then
        print_info "Check restore later with:"
        echo "  kubectl -n longhorn-system get volumes.longhorn.io $restore_volume_name -o jsonpath='{.status.restoreRequired}'"
        print_info "After restoreRequired=false, apply:"
        echo "  kubectl apply -f $bind_manifest"
        return 0
    fi

    longhorn_wait_for_restore "$restore_volume_name" 1800 || return 1

    if ! longhorn_kubectl get namespace "$target_namespace" &>/dev/null; then
        print_warning "Namespace $target_namespace does not exist."
        read -p "Create namespace $target_namespace now? (y/n): " create_namespace
        if [ "$create_namespace" = "y" ]; then
            longhorn_kubectl create namespace "$target_namespace" || return 1
        else
            print_info "Apply the bind manifest after the namespace exists:"
            echo "  kubectl apply -f $bind_manifest"
            return 0
        fi
    fi

    longhorn_kubectl apply -f "$bind_manifest" || return 1
    print_successful "PV/PVC binding applied."
    print_info "Start or reconcile the application only after the PVC is Bound:"
    echo "  kubectl -n $target_namespace get pvc $target_pvc"
}

manage_longhorn() {
    while true; do
        echo -e "${YELLOW}======== Longhorn Backup / Restore ========${NC}"
        echo "1. Check Longhorn backup target"
        echo "2. List backup inventory"
        echo "3. Selective restore latest backup"
        echo "4. Check restore / volume status"
        echo "5. Back to Main Menu"
        echo -e "${YELLOW}==========================================${NC}"
        read -p "Enter your choice: " longhorn_choice

        case $longhorn_choice in
            1)
                longhorn_require_cluster || continue
                longhorn_kubectl get backuptargets.longhorn.io -n longhorn-system
                ;;
            2) longhorn_list_backup_inventory ;;
            3) longhorn_selective_restore ;;
            4) longhorn_restore_status ;;
            5) return ;;
            "") continue ;;
            *) print_error "Invalid option." ;;
        esac
    done
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
        upsert_config_value "$CONFIG_FILE" "SSH_PUBKEY" "$PUBLIC_KEY"
        print_successful "Public key saved to $CONFIG_FILE"
    fi

    print_info "On Kairos, this key is injected via the cloud-config 'users.ssh_authorized_keys' section."
    echo ""
    read -p "Regenerate cloud-configs now to include this key? (y/n, default: y): " regen
    if [ "${regen:-y}" = "y" ]; then
        ensure_config || return 1
        generate_controller_cloudconfig
        if [ -f ".k0s_controller_token" ]; then
            generate_controller_token
        fi
        if [ -f ".k0s_worker_token" ]; then
            generate_worker_token
        else
            print_info "No worker token found — generate one (option 4) before regenerating worker cloud-config."
        fi
    fi
}

# -----------------------------------------------------------------------------
# Main menu
# -----------------------------------------------------------------------------
while true; do
    echo -e "\n${YELLOW}======== Kairos + k0s Cluster Management (v${SCRIPT_VERSION}) ========${NC}"
    echo "1.  Generate Config File (cluster settings)"
    echo "2.  Generate Controller Cloud-Config (first controller)"
    echo "3.  Generate Controller Join Token + Cloud-Config (additional controllers)"
    echo "4.  Generate Worker Token + Cloud-Config (worker nodes)"
    echo "5.  Kairos Web Installer (send config to installer)"
    echo "6.  Generate Kairos Dockerfile (image build)"
    echo "7.  Manage Cilium (install / upgrade / status)"
    echo "8.  Manage FluxCD"
    echo "9.  Manage Longhorn Backups / Restore"
    echo "10. Manage BGP Configuration"
    echo "11. Check Versions"
    echo "12. Check Cluster Status"
    echo "13. Reset Node"
    echo "14. Rolling OS Upgrade (A/B)"
    echo "15. Show Config File"
    echo "16. Exit"
    echo -e "${YELLOW}=================================================${NC}"
    if ! read -p "Enter your choice: " choice; then
        echo ""
        print_info "Input closed. Exiting..."
        exit 0
    fi

    case $choice in
        1) generate_config_file ;;
        2) ensure_config && generate_controller_cloudconfig ;;
        3) ensure_config && generate_controller_token ;;
        4) ensure_config && generate_worker_token ;;
        5) ensure_config && manage_web_installer ;;
        6) ensure_config && generate_kairos_dockerfile ;;
        7) manage_cilium ;;
        8) manage_flux ;;
        9) manage_longhorn ;;
        10) manage_bgp ;;
        11) check_versions ;;
        12) check_cluster_status ;;
        13) reset_node ;;
        14) kairos_rolling_upgrade ;;
        15) show_config_file ;;
        16) echo "Exiting..."; exit 0 ;;
        "") continue ;;
        *) print_error "Invalid option." ;;
    esac
done
