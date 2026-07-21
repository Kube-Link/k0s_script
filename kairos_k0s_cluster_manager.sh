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
KUBELET_ROOT_DIR="/var/lib/kubelet"
CONTROLLER_MANAGEMENT_KEY_PATH="${HOME}/.ssh/id_ed25519_k0s_controllers"

# Kairos image defaults
# TODO: decide on a base image tag strategy (pin to a release or track latest)
KAIROS_BASE_IMAGE="quay.io/kairos/hadron"        # Hadron base (musl + systemd)
KAIROS_INIT_IMAGE="quay.io/kairos/kairos-init"   # kairos-init tool
KAIROS_IMAGE_VERSION="v4.1.2"                   # TODO: make this configurable
K0S_PROVIDER_VERSION="latest"                   # k0s version baked into image

# Script version — bump manually when making changes; compared against VERSION file in repo
SCRIPT_VERSION="1.0.84"

# Flux bootstrap defaults. These are saved to the cluster config after the
# first interactive bootstrap so upgrades can reuse the exact same component set.
FLUX_DEFAULT_COMPONENTS=(source-controller kustomize-controller helm-controller notification-controller)
FLUX_DEFAULT_COMPONENTS_EXTRA=(image-reflector-controller image-automation-controller)

printf -v LONGHORN_MULTIPATH_BOOT_BLOCK '%s\n' \
'    - name: "Disable multipathd for Longhorn"' \
'      commands:' \
'        - |' \
'          for unit in multipathd.service multipathd.socket; do' \
'            systemctl disable --now "$unit" 2>/dev/null || true' \
'          done'

printf -v LONGHORN_DM_CRYPT_BOOT_BLOCK '%s\n' \
'    - name: "Load dm_crypt for Longhorn"' \
'      commands:' \
'        - |' \
'          mkdir -p /etc/modules-load.d' \
'          printf "%s\\n" dm_crypt > /etc/modules-load.d/longhorn.conf' \
'          if ! modprobe dm_crypt; then' \
'            echo "Longhorn requires the dm_crypt kernel module; it is missing from $(uname -r)." >&2' \
'            exit 1' \
'          fi'

printf -v LONGHORN_V2_BOOT_BLOCK '%s\n' \
'    - name: "Prepare Longhorn V2 Data Engine"' \
'      commands:' \
'        - |' \
'          set -eu' \
'          mkdir -p /etc/modules-load.d' \
'          printf "%s\\n" vfio_pci uio_pci_generic nvme_tcp > /etc/modules-load.d/longhorn-v2.conf' \
'          for module in vfio_pci uio_pci_generic nvme_tcp; do' \
'            if ! modprobe "$module"; then' \
'              echo "Longhorn V2 requires the $module kernel module; it is missing from $(uname -r)." >&2' \
'              exit 1' \
'            fi' \
'          done' \
'          hugepages=/sys/kernel/mm/hugepages/hugepages-2048kB/nr_hugepages' \
'          if [ ! -w "$hugepages" ]; then' \
'            echo "Longhorn V2 requires writable 2 MiB HugePages on $(uname -r)." >&2' \
'            exit 1' \
'          fi' \
'          if [ "$(cat "$hugepages")" -lt 1024 ]; then' \
'            echo 1024 > "$hugepages"' \
'          fi' \
'          if [ "$(cat "$hugepages")" -lt 1024 ]; then' \
'            echo "Longhorn V2 requires at least 2 GiB of 2 MiB HugePages." >&2' \
'            exit 1' \
'          fi' \
'          if systemctl is-active --quiet k0sworker.service; then' \
'            systemctl try-restart k0sworker.service' \
'          fi'

# Cluster defaults
DEFAULT_POD_CIDR="10.42.0.0/16"
DEFAULT_SERVICE_CIDR="10.96.0.0/12"
DEFAULT_CLUSTER_NAME="homelab"
WORKER_INSTALL_STATE_FILE=".kairos_worker_installs_submitted"
SCRIPT_UPDATE_URL="https://raw.githubusercontent.com/Kube-Link/k0s_script/master/kairos_k0s_cluster_manager.sh"
SAFE_SCRIPT_UPDATE_COMMAND="log=/var/log/kairos-cluster-manager-update.log; url=${SCRIPT_UPDATE_URL}; dest=/root/kairos-cluster-manager.sh; old=/root/kairos-cluster-manager.old.sh; tmp=/root/kairos-cluster-manager.sh.new; tmp_lf=/root/kairos-cluster-manager.sh.new.lf; updated=n; rm -f \"\$tmp\" \"\$tmp_lf\"; for attempt in 1 2 3 4 5 6 7 8 9 10 11 12; do echo \"\$(date -Iseconds 2>/dev/null || date) attempt \$attempt\" >> \"\$log\"; if curl -fsSL --connect-timeout 10 --max-time 60 \"\$url\" -o \"\$tmp\" >> \"\$log\" 2>&1; then tr -d '\r' < \"\$tmp\" > \"\$tmp_lf\" && mv \"\$tmp_lf\" \"\$tmp\"; if head -n 1 \"\$tmp\" | grep -qx '#!/bin/bash' && bash -n \"\$tmp\" >> \"\$log\" 2>&1; then new_version=\$(awk -F'\"' '/^SCRIPT_VERSION=/{print \$2; exit}' \"\$tmp\"); current_version=; if [ -f \"\$dest\" ]; then current_version=\$(tr -d '\r' < \"\$dest\" | awk -F'\"' '/^SCRIPT_VERSION=/{print \$2; exit}' 2>/dev/null); fi; cr=\$(printf '\r'); if [ -n \"\$new_version\" ] && [ -n \"\$current_version\" ] && [ \"\$new_version\" = \"\$current_version\" ]; then if [ -f \"\$dest\" ] && grep -q \"\$cr\" \"\$dest\"; then if mv \"\$tmp\" \"\$dest\" && chmod 0755 \"\$dest\"; then echo \"\$(date -Iseconds 2>/dev/null || date) normalized line endings for current version \$current_version\" >> \"\$log\"; updated=y; break; fi; else echo \"\$(date -Iseconds 2>/dev/null || date) already current version \$current_version; no replace needed\" >> \"\$log\"; updated=y; rm -f \"\$tmp\"; break; fi; fi; if [ -f \"\$dest\" ] && command -v cmp >/dev/null 2>&1 && cmp -s \"\$tmp\" \"\$dest\"; then echo \"\$(date -Iseconds 2>/dev/null || date) already current; no replace needed\" >> \"\$log\"; updated=y; rm -f \"\$tmp\"; break; fi; if [ -f \"\$dest\" ]; then if cp -p \"\$dest\" \"\$old\"; then echo \"\$(date -Iseconds 2>/dev/null || date) backed up \$dest to \$old\" >> \"\$log\"; else echo \"\$(date -Iseconds 2>/dev/null || date) backup failed; keeping existing \$dest\" >> \"\$log\"; rm -f \"\$tmp\"; break; fi; fi; if mv \"\$tmp\" \"\$dest\" && chmod 0755 \"\$dest\"; then echo \"\$(date -Iseconds 2>/dev/null || date) updated \$dest; previous copy is \$old\" >> \"\$log\"; updated=y; break; else echo \"\$(date -Iseconds 2>/dev/null || date) install failed\" >> \"\$log\"; if [ -f \"\$old\" ] && [ ! -f \"\$dest\" ]; then cp -p \"\$old\" \"\$dest\" && chmod 0755 \"\$dest\"; fi; fi; else echo \"\$(date -Iseconds 2>/dev/null || date) downloaded file failed validation\" >> \"\$log\"; fi; else echo \"\$(date -Iseconds 2>/dev/null || date) download failed\" >> \"\$log\"; fi; sleep 10; done; if [ \"\$updated\" != \"y\" ]; then echo \"\$(date -Iseconds 2>/dev/null || date) keeping existing \$dest\" >> \"\$log\"; fi; rm -f \"\$tmp\" \"\$tmp_lf\""

build_controller_k0s_args() {
    local include_token="${1:-false}"

    printf '    - --config=%s\n' "$K0S_CONFIG_PATH"
    if [ "$include_token" = "true" ]; then
        printf '    - --token-file=%s\n' "$K0S_TOKEN_FILE"
    fi

    if [ "${CONTROLLER_WORKER:-n}" = "y" ]; then
        printf '    - --enable-worker\n'
        printf '    - --kubelet-root-dir=/var/lib/kubelet\n'
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
                print_error "Duplicate IP in config: $node"
                return 1
            fi
        done
        seen+=("$node")
    done
}

is_ipv4_address() {
    local ip="$1"
    local octet
    local -a octets

    [[ "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || return 1
    IFS='.' read -ra octets <<< "$ip"
    for octet in "${octets[@]}"; do
        [ "$((10#$octet))" -le 255 ] || return 1
    done
}

is_ipv4_cidr() {
    local cidr="$1"
    local address="${cidr%/*}"
    local prefix="${cidr##*/}"

    [ "$address" != "$cidr" ] || return 1
    is_ipv4_address "$address" || return 1
    [[ "$prefix" =~ ^[0-9]+$ ]] || return 1
    [ "$((10#$prefix))" -ge 1 ] && [ "$((10#$prefix))" -le 32 ]
}

build_yaml_ip_list() {
    local indentation="$1"
    local excluded_ip="$2"
    shift 2
    local ip

    for ip in "$@"; do
        [ -n "$ip" ] || continue
        [ "$ip" = "$excluded_ip" ] && continue
        printf '%*s- %s\n' "$indentation" '' "$ip"
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
        for key in CONTROLLER_COUNT CONTROLLER_WORKER CONTROLLER_IP ADDITIONAL_CONTROLLERS WORKERS CLUSTER_NAME CONTROL_PLANE_VIP_CIDR CPLB_AUTH_PASS CPLB_VIRTUAL_ROUTER_ID POD_CIDR SERVICE_CIDR INSTALL_CILIUM GITHUB_USER SSH_PUBKEY; do
            if ! declare -p "$key" >/dev/null 2>&1; then
                echo "Missing required config key: $key"
                failed=1
            fi
        done
        valid_ipv4() {
            local ip="$1" octet
            local -a octets
            [[ "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || return 1
            IFS=. read -ra octets <<< "$ip"
            for octet in "${octets[@]}"; do
                [ "$((10#$octet))" -le 255 ] || return 1
            done
        }
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
        vip_cidr="${CONTROL_PLANE_VIP_CIDR:-}"
        vip_ip="${vip_cidr%/*}"
        vip_prefix="${vip_cidr##*/}"
        if [ "$vip_ip" = "$vip_cidr" ] || ! valid_ipv4 "$vip_ip" || ! [[ "$vip_prefix" =~ ^[0-9]+$ ]] || [ "$((10#${vip_prefix:-0}))" -lt 1 ] || [ "$((10#${vip_prefix:-0}))" -gt 32 ]; then
            echo "CONTROL_PLANE_VIP_CIDR must be a valid IPv4 CIDR, for example 172.20.1.10/24."
            failed=1
        fi
        for ip in "${CONTROLLER_IP:-}" "${ADDITIONAL_CONTROLLERS[@]}" "${WORKERS[@]}"; do
            if ! valid_ipv4 "$ip"; then
                echo "Invalid node IPv4 address: $ip"
                failed=1
            elif [ -n "$vip_ip" ] && [ "$vip_ip" = "$ip" ]; then
                echo "The control-plane VIP must not match a controller or worker IP: $vip_ip"
                failed=1
            fi
        done
        if ! [[ "${CPLB_AUTH_PASS:-}" =~ ^[A-Za-z0-9_-]{1,8}$ ]]; then
            echo "CPLB_AUTH_PASS must contain 1-8 letters, numbers, underscores, or hyphens."
            failed=1
        fi
        if ! [[ "${CPLB_VIRTUAL_ROUTER_ID:-}" =~ ^[0-9]+$ ]] || [ "$((10#${CPLB_VIRTUAL_ROUTER_ID:-0}))" -lt 1 ] || [ "$((10#${CPLB_VIRTUAL_ROUTER_ID:-0}))" -gt 255 ]; then
            echo "CPLB_VIRTUAL_ROUTER_ID must be between 1 and 255."
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
    local saved_flux_bootstrap_mode=""
    local saved_flux_github_owner=""
    local saved_flux_github_repository=""
    local saved_flux_github_branch=""
    local saved_flux_github_path=""
    local saved_flux_github_personal=""
    local -a saved_flux_components=()
    local -a saved_flux_components_extra=()

    if [ -f "$CONFIG_FILE" ] && source "$CONFIG_FILE" 2>/dev/null; then
        saved_flux_bootstrap_mode="${FLUX_BOOTSTRAP_MODE:-}"
        saved_flux_github_owner="${FLUX_GITHUB_OWNER:-}"
        saved_flux_github_repository="${FLUX_GITHUB_REPOSITORY:-}"
        saved_flux_github_branch="${FLUX_GITHUB_BRANCH:-}"
        saved_flux_github_path="${FLUX_GITHUB_PATH:-}"
        saved_flux_github_personal="${FLUX_GITHUB_PERSONAL:-}"
        if declare -p FLUX_COMPONENTS >/dev/null 2>&1; then
            saved_flux_components=("${FLUX_COMPONENTS[@]}")
        fi
        if declare -p FLUX_COMPONENTS_EXTRA >/dev/null 2>&1; then
            saved_flux_components_extra=("${FLUX_COMPONENTS_EXTRA[@]}")
        fi
    fi
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

    for item in "$CONTROLLER_IP" "${ADDITIONAL_CONTROLLERS[@]}" "${WORKERS[@]}"; do
        if ! is_ipv4_address "$item"; then
            print_error "Invalid node IPv4 address: $item"
            return 1
        fi
    done

    read -p "Enter cluster name (default: $DEFAULT_CLUSTER_NAME): " CLUSTER_NAME || return 1
    CLUSTER_NAME=${CLUSTER_NAME:-$DEFAULT_CLUSTER_NAME}
    CLUSTER_NAME=$(trim_value "$CLUSTER_NAME")

    print_info "The control-plane VIP must be unused and routable on the controller network."
    read -p "Enter control-plane VIP with CIDR (example: 172.20.1.10/24): " CONTROL_PLANE_VIP_CIDR || return 1
    CONTROL_PLANE_VIP_CIDR=$(trim_value "$CONTROL_PLANE_VIP_CIDR")
    if ! is_ipv4_cidr "$CONTROL_PLANE_VIP_CIDR"; then
        print_error "A valid IPv4 VIP with CIDR is required, for example 172.20.1.10/24."
        return 1
    fi

    local control_plane_vip_ip="${CONTROL_PLANE_VIP_CIDR%/*}"
    validate_unique_nodes "$CONTROLLER_IP" "${ADDITIONAL_CONTROLLERS[@]}" "${WORKERS[@]}" "$control_plane_vip_ip" || return 1

    local default_cplb_auth="${CLUSTER_NAME//[^[:alnum:]_-]/}"
    default_cplb_auth="${default_cplb_auth:0:8}"
    [ -n "$default_cplb_auth" ] || default_cplb_auth="k0scplb"
    read -p "Enter CPLB auth password (1-8 letters/numbers/_/-, default: ${default_cplb_auth}): " CPLB_AUTH_PASS || return 1
    CPLB_AUTH_PASS=${CPLB_AUTH_PASS:-$default_cplb_auth}
    CPLB_AUTH_PASS=$(trim_value "$CPLB_AUTH_PASS")
    if ! [[ "$CPLB_AUTH_PASS" =~ ^[A-Za-z0-9_-]{1,8}$ ]]; then
        print_error "CPLB auth password must contain 1-8 letters, numbers, underscores, or hyphens."
        return 1
    fi

    read -p "Enter CPLB virtual router ID (default: 51): " CPLB_VIRTUAL_ROUTER_ID || return 1
    CPLB_VIRTUAL_ROUTER_ID=${CPLB_VIRTUAL_ROUTER_ID:-51}
    CPLB_VIRTUAL_ROUTER_ID=$(trim_value "$CPLB_VIRTUAL_ROUTER_ID")
    if ! [[ "$CPLB_VIRTUAL_ROUTER_ID" =~ ^[0-9]+$ ]] || [ "$((10#$CPLB_VIRTUAL_ROUTER_ID))" -lt 1 ] || [ "$((10#$CPLB_VIRTUAL_ROUTER_ID))" -gt 255 ]; then
        print_error "CPLB virtual router ID must be between 1 and 255."
        return 1
    fi

    read -p "Enter Pod CIDR (default: $DEFAULT_POD_CIDR): " POD_CIDR || return 1
    POD_CIDR=${POD_CIDR:-$DEFAULT_POD_CIDR}
    POD_CIDR=$(trim_value "$POD_CIDR")

    read -p "Enter Service CIDR (default: $DEFAULT_SERVICE_CIDR): " SERVICE_CIDR || return 1
    SERVICE_CIDR=${SERVICE_CIDR:-$DEFAULT_SERVICE_CIDR}
    SERVICE_CIDR=$(trim_value "$SERVICE_CIDR")

    prompt_yn INSTALL_CILIUM "Auto-install Cilium before worker installation? (y/n, default: n): " "n" || return 1

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

    write_config_value "$tmp_config" "CONTROLLER_COUNT" "$CONTROLLER_COUNT"
    write_config_value "$tmp_config" "CONTROLLER_WORKER" "$CONTROLLER_WORKER"
    write_config_value "$tmp_config" "CONTROLLER_IP" "$CONTROLLER_IP"
    write_config_array "$tmp_config" "ADDITIONAL_CONTROLLERS" "${ADDITIONAL_CONTROLLERS[@]}"
    write_config_array "$tmp_config" "WORKERS" "${WORKERS[@]}"
    write_config_value "$tmp_config" "CLUSTER_NAME" "$CLUSTER_NAME"
    write_config_value "$tmp_config" "CONTROL_PLANE_VIP_CIDR" "$CONTROL_PLANE_VIP_CIDR"
    write_config_value "$tmp_config" "CPLB_AUTH_PASS" "$CPLB_AUTH_PASS"
    write_config_value "$tmp_config" "CPLB_VIRTUAL_ROUTER_ID" "$CPLB_VIRTUAL_ROUTER_ID"
    write_config_value "$tmp_config" "POD_CIDR" "$POD_CIDR"
    write_config_value "$tmp_config" "SERVICE_CIDR" "$SERVICE_CIDR"
    write_config_value "$tmp_config" "INSTALL_CILIUM" "$INSTALL_CILIUM"
    write_config_value "$tmp_config" "GITHUB_USER" "$GITHUB_USER"
    write_config_value "$tmp_config" "SSH_PUBKEY" "$SSH_PUBKEY"

    if [ -n "$saved_flux_bootstrap_mode" ]; then
        write_config_value "$tmp_config" "FLUX_BOOTSTRAP_MODE" "$saved_flux_bootstrap_mode"
        write_config_value "$tmp_config" "FLUX_GITHUB_OWNER" "$saved_flux_github_owner"
        write_config_value "$tmp_config" "FLUX_GITHUB_REPOSITORY" "$saved_flux_github_repository"
        write_config_value "$tmp_config" "FLUX_GITHUB_BRANCH" "$saved_flux_github_branch"
        write_config_value "$tmp_config" "FLUX_GITHUB_PATH" "$saved_flux_github_path"
        write_config_value "$tmp_config" "FLUX_GITHUB_PERSONAL" "$saved_flux_github_personal"
        write_config_array "$tmp_config" "FLUX_COMPONENTS" "${saved_flux_components[@]}"
        write_config_array "$tmp_config" "FLUX_COMPONENTS_EXTRA" "${saved_flux_components_extra[@]}"
    fi

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

show_kubeconfig() {
    if [ -f "$K0S_KUBECONFIG" ]; then
        echo -e "${YELLOW}======== k0s Kubeconfig (${K0S_KUBECONFIG}) ========${NC}"
        cat "$K0S_KUBECONFIG"
        echo -e "${YELLOW}===================================================${NC}"
    else
        print_error "k0s kubeconfig not found at ${K0S_KUBECONFIG}."
        print_info "This file exists only on a k0s controller node."
        print_info "To retrieve it remotely: scp user@<controller>:/var/lib/k0s/pki/admin.conf ~/.kube/config"
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
    local LONGHORN_BOOT_BLOCK=""
    if [ "${CONTROLLER_WORKER:-n}" = "y" ]; then
        LONGHORN_BOOT_BLOCK="${LONGHORN_MULTIPATH_BOOT_BLOCK}${LONGHORN_DM_CRYPT_BOOT_BLOCK}${LONGHORN_V2_BOOT_BLOCK}"
    fi
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

    # Controllers share a dedicated management key for status and maintenance checks.
    prepare_controller_management_key || true

    # Build SSH keys block (GitHub/user key plus the controller-management key)
    local SSH_KEYS_BLOCK="      - github:${GITHUB_USER}"
    if [ -n "$SSH_PUBKEY" ]; then
        SSH_KEYS_BLOCK="${SSH_KEYS_BLOCK}"$'\n'"      - ${SSH_PUBKEY}"
    fi
    if [ -n "$CONTROLLER_MANAGEMENT_PUBKEY" ]; then
        SSH_KEYS_BLOCK="${SSH_KEYS_BLOCK}"$'\n'"      - ${CONTROLLER_MANAGEMENT_PUBKEY}"
    fi

    # Hash the password — Kairos v4.x needs SHA-512 crypt, not cleartext
    local USER_PASSWD=$(hash_password "kairos")
    print_info "Password hash: ${USER_PASSWD:0:20}..."

    local CTRL_HOSTNAME="${CLUSTER_NAME}-ctrl-1"

    local CONTROL_PLANE_VIP_IP="${CONTROL_PLANE_VIP_CIDR%/*}"
    local CONTROLLER_API_SANS
    local CPLB_UNICAST_PEERS
    CONTROLLER_API_SANS=$(build_yaml_ip_list 12 "" "$CONTROLLER_IP" "${ADDITIONAL_CONTROLLERS[@]}" "$CONTROL_PLANE_VIP_IP")
    CPLB_UNICAST_PEERS=$(build_yaml_ip_list 20 "$CONTROLLER_IP" "$CONTROLLER_IP" "${ADDITIONAL_CONTROLLERS[@]}")

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
          port: 6443
          sans:
${CONTROLLER_API_SANS}
        network:
          provider: custom
          podCIDR: ${POD_CIDR}
          serviceCIDR: ${SERVICE_CIDR}
          kubeProxy:
            disabled: true
          controlPlaneLoadBalancing:
            enabled: true
            type: Keepalived
            keepalived:
              vrrpInstances:
                - virtualIPs:
                    - ${CONTROL_PLANE_VIP_CIDR}
                  authPass: "${CPLB_AUTH_PASS}"
                  virtualRouterID: ${CPLB_VIRTUAL_ROUTER_ID}
                  unicastSourceIP: ${CONTROLLER_IP}
                  unicastPeers:
${CPLB_UNICAST_PEERS}
          nodeLocalLoadBalancing:
            enabled: true
            type: EnvoyProxy
        storage:
          type: etcd
          etcd:
            peerAddress: ${CONTROLLER_IP}
        controllerManager: {}
        scheduler: {}
        telemetry:
          enabled: false
${CONTROLLER_MANAGEMENT_WRITE_FILES_BLOCK}
  - path: /usr/local/bin/kubectl
    permissions: "0755"
    content: |
      #!/bin/sh
      version="\$(k0s version 2>/dev/null | head -n 1 | sed 's/+k0s.*//')"
      if [ -x /var/lib/k0s/bin/kubectl ] && [ -r /var/lib/k0s/bin/kubectl.version ] && [ "\$(cat /var/lib/k0s/bin/kubectl.version)" = "\$version" ]; then
        exec /var/lib/k0s/bin/kubectl "\$@"
      fi
      exec k0s kubectl "\$@"
  - path: /usr/local/sbin/install-kubectl
    permissions: "0755"
    content: |
      #!/bin/sh
      set -u

      version="\$(k0s version 2>/dev/null | head -n 1 | sed 's/+k0s.*//')"
      case "\$version" in
        v[0-9]*.[0-9]*.[0-9]*) ;;
        *) echo "Unable to determine kubectl version from k0s: \$version"; exit 0 ;;
      esac

      case "\$(uname -m)" in
        x86_64|amd64) arch=amd64 ;;
        aarch64|arm64) arch=arm64 ;;
        *) echo "Unsupported kubectl architecture: \$(uname -m)"; exit 0 ;;
      esac

      dest=/var/lib/k0s/bin/kubectl
      marker=\${dest}.version
      mkdir -p /var/lib/k0s/bin /etc/bash_completion.d

      if [ -x "\$dest" ] && [ -r "\$marker" ] && [ "\$(cat "\$marker")" = "\$version" ]; then
        "\$dest" completion bash > /etc/bash_completion.d/kubectl 2>/dev/null || true
        exit 0
      fi

      rm -f /etc/bash_completion.d/kubectl
      tmp=/tmp/kubectl.download
      checksum=/tmp/kubectl.download.sha256
      trap 'rm -f "\$tmp" "\$checksum"' 0 HUP INT TERM
      url=https://dl.k8s.io/release/\${version}/bin/linux/\${arch}/kubectl

      if ! curl -fsSL "\$url" -o "\$tmp" || ! curl -fsSL "\${url}.sha256" -o "\$checksum"; then
        echo "Unable to download kubectl \$version; keeping k0s kubectl fallback."
        exit 0
      fi

      expected="\$(tr -d '[:space:]' < "\$checksum")"
      if [ -z "\$expected" ] || ! printf '%s  %s\n' "\$expected" "\$tmp" | sha256sum -c - >/dev/null 2>&1; then
        echo "kubectl checksum validation failed; keeping k0s kubectl fallback."
        exit 0
      fi

      if install -m 0755 "\$tmp" "\$dest"; then
        printf '%s\n' "\$version" > "\$marker"
        "\$dest" completion bash > /etc/bash_completion.d/kubectl 2>/dev/null || true
        echo "Installed kubectl \$version for shell completion."
      fi
  - path: /etc/profile.d/k0s-kubeconfig.sh
    permissions: "0644"
    content: |
      export KUBECONFIG=${K0S_KUBECONFIG}
      alias k=kubectl
      if [ -n "\${BASH_VERSION:-}" ]; then
        for completion in /usr/share/bash-completion/bash_completion /etc/bash_completion; do
          [ -r "\$completion" ] && . "\$completion"
        done
        for completion in /etc/bash_completion.d/k0s-compat /etc/bash_completion.d/k0s; do
          [ -r "\$completion" ] && source -- "\$completion"
        done
        if [ -s /etc/bash_completion.d/kubectl ]; then
          source -- /etc/bash_completion.d/kubectl
        elif [ -x /var/lib/k0s/bin/kubectl ]; then
          source <(/var/lib/k0s/bin/kubectl completion bash 2>/dev/null)
        fi
        type __start_kubectl >/dev/null 2>&1 && complete -o default -F __start_kubectl kubectl k
      fi
  - path: /root/.bashrc
    permissions: "0644"
    content: |
      if [ -r /etc/profile.d/k0s-kubeconfig.sh ]; then
        . /etc/profile.d/k0s-kubeconfig.sh
      fi
  - path: /root/.bash_profile
    permissions: "0644"
    content: |
      if [ -r "\$HOME/.bashrc" ]; then
        . "\$HOME/.bashrc"
      fi
  - path: /etc/bash_completion.d/k0s-compat
    permissions: "0644"
    content: |
      if ! type _get_comp_words_by_ref >/dev/null 2>&1; then
        _get_comp_words_by_ref() {
          local OPTIND opt cur_var prev_var words_var cword_var
          while getopts "n:" opt; do :; done
          shift \$((OPTIND - 1))
          while [ \$# -gt 0 ]; do
            case "\$1" in
              cur) cur_var=cur ;;
              prev) prev_var=prev ;;
              words) words_var=words ;;
              cword) cword_var=cword ;;
              *) ;;
            esac
            shift
          done
          [ -n "\$cur_var" ] && printf -v "\$cur_var" '%s' "\${COMP_WORDS[COMP_CWORD]}"
          if [ -n "\$prev_var" ]; then
            if [ "\$COMP_CWORD" -gt 0 ]; then
              printf -v "\$prev_var" '%s' "\${COMP_WORDS[COMP_CWORD-1]}"
            else
              printf -v "\$prev_var" '%s' ""
            fi
          fi
          if [ -n "\$words_var" ]; then
            local -n words_ref="\$words_var"
            words_ref=("\${COMP_WORDS[@]}")
          fi
          [ -n "\$cword_var" ] && printf -v "\$cword_var" '%s' "\$COMP_CWORD"
        }
      fi
      if ! type _init_completion >/dev/null 2>&1; then
        _init_completion() {
          local OPTIND opt
          COMPREPLY=()
          while getopts "n:e:o:i:s" opt; do :; done
          shift \$((OPTIND - 1))
          _get_comp_words_by_ref "\$@" cur prev words cword
        }
      fi
      if ! type __ltrim_colon_completions >/dev/null 2>&1; then
        __ltrim_colon_completions() { return 0; }
      fi
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
      CONTROL_PLANE_VIP_CIDR=${CONTROL_PLANE_VIP_CIDR}
      CPLB_AUTH_PASS=${CPLB_AUTH_PASS}
      CPLB_VIRTUAL_ROUTER_ID=${CPLB_VIRTUAL_ROUTER_ID}
      POD_CIDR=${POD_CIDR}
      SERVICE_CIDR=${SERVICE_CIDR}
      INSTALL_CILIUM=${INSTALL_CILIUM}
      GITHUB_USER=${GITHUB_USER}
      SSH_PUBKEY='${SSH_PUBKEY}'
      FLUX_BOOTSTRAP_MODE=${FLUX_BOOTSTRAP_MODE:-}
      FLUX_GITHUB_OWNER=${FLUX_GITHUB_OWNER:-}
      FLUX_GITHUB_REPOSITORY=${FLUX_GITHUB_REPOSITORY:-}
      FLUX_GITHUB_BRANCH=${FLUX_GITHUB_BRANCH:-}
      FLUX_GITHUB_PATH=${FLUX_GITHUB_PATH:-}
      FLUX_GITHUB_PERSONAL=${FLUX_GITHUB_PERSONAL:-}
      FLUX_COMPONENTS=(${FLUX_COMPONENTS[@]})
      FLUX_COMPONENTS_EXTRA=(${FLUX_COMPONENTS_EXTRA[@]})

# Persistent paths — survive reboots and OS upgrades (read-write bind mounts)
# k0s state and kubelet must persist on an immutable OS
bind_mounts:
  - /var/lib/k0s
  - /var/lib/kubelet

stages:
  boot:
    - name: "Update cluster manager script safely"
      commands:
        - ${SAFE_SCRIPT_UPDATE_COMMAND}
${LONGHORN_BOOT_BLOCK}
# Longhorn requirement
  boot.after:
    - name: "Enable iSCSI"
      commands:
        - systemctl enable iscsid
        - systemctl start iscsid
    - name: "Ensure standard kubelet root dir exists"
      if: "[ ! -d /var/lib/kubelet ]"
      commands:
        - mkdir -p /var/lib/kubelet
    - name: "Configure controller shell defaults"
      commands:
        - mkdir -p /etc/profile.d /etc/bash_completion.d /usr/local/bin /usr/local/sbin
        - chmod 0755 /usr/local/bin/kubectl /usr/local/sbin/install-kubectl
        - k0s completion bash > /etc/bash_completion.d/k0s 2>/dev/null || true
        - /usr/local/sbin/install-kubectl

# Reset behavior — what happens when kairos-agent reset is called
reset:
  reboot: true
  reset-persistent: false
  reset-oem: false

# Upgrade behavior — what happens when kairos-agent upgrade is called
upgrade:
  reboot: true

EOF

    chmod 0600 "$CONTROLLER_CC_FILE" 2>/dev/null || true

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

    # Workers authorize the controller-management public key so controller-side
    # diagnostics can inspect their local kubelet configuration over SSH.
    prepare_controller_management_key || true

    # Build SSH keys block (github key, user key, and management public key)
    local SSH_KEYS_BLOCK="      - github:${GITHUB_USER}"
    if [ -n "$SSH_PUBKEY" ]; then
        SSH_KEYS_BLOCK="${SSH_KEYS_BLOCK}"$'\n'"      - ${SSH_PUBKEY}"
    fi
    if [ -n "$CONTROLLER_MANAGEMENT_PUBKEY" ]; then
        SSH_KEYS_BLOCK="${SSH_KEYS_BLOCK}"$'\n'"      - ${CONTROLLER_MANAGEMENT_PUBKEY}"
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
    - --kubelet-root-dir=/var/lib/kubelet

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
      CONTROL_PLANE_VIP_CIDR=${CONTROL_PLANE_VIP_CIDR}
      CPLB_AUTH_PASS=${CPLB_AUTH_PASS}
      CPLB_VIRTUAL_ROUTER_ID=${CPLB_VIRTUAL_ROUTER_ID}
      POD_CIDR=${POD_CIDR}
      SERVICE_CIDR=${SERVICE_CIDR}
      INSTALL_CILIUM=${INSTALL_CILIUM}
      GITHUB_USER=${GITHUB_USER}
      SSH_PUBKEY='${SSH_PUBKEY}'
      FLUX_BOOTSTRAP_MODE=${FLUX_BOOTSTRAP_MODE:-}
      FLUX_GITHUB_OWNER=${FLUX_GITHUB_OWNER:-}
      FLUX_GITHUB_REPOSITORY=${FLUX_GITHUB_REPOSITORY:-}
      FLUX_GITHUB_BRANCH=${FLUX_GITHUB_BRANCH:-}
      FLUX_GITHUB_PATH=${FLUX_GITHUB_PATH:-}
      FLUX_GITHUB_PERSONAL=${FLUX_GITHUB_PERSONAL:-}
      FLUX_COMPONENTS=(${FLUX_COMPONENTS[@]})
      FLUX_COMPONENTS_EXTRA=(${FLUX_COMPONENTS_EXTRA[@]})

# Persistent paths — survive reboots and OS upgrades (read-write bind mounts)
bind_mounts:
  - /var/lib/k0s
  - /var/lib/kubelet

stages:
  boot:
    - name: "Update cluster manager script safely"
      commands:
        - ${SAFE_SCRIPT_UPDATE_COMMAND}
${LONGHORN_MULTIPATH_BOOT_BLOCK}
${LONGHORN_DM_CRYPT_BOOT_BLOCK}
${LONGHORN_V2_BOOT_BLOCK}
  boot.after:
    - name: "Enable iSCSI"
      commands:
        - systemctl enable iscsid
        - systemctl start iscsid
    - name: "Ensure standard kubelet root dir exists"
      if: "[ ! -d /var/lib/kubelet ]"
      commands:
        - mkdir -p /var/lib/kubelet

# Reset behavior
reset:
  reboot: true
  reset-persistent: false
  reset-oem: false

# Upgrade behavior
upgrade:
  reboot: true

EOF

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

    local CONTROL_PLANE_VIP_IP="${CONTROL_PLANE_VIP_CIDR%/*}"
    local CONTROLLER_API_SANS
    local CPLB_UNICAST_PEERS
    CONTROLLER_API_SANS=$(build_yaml_ip_list 12 "" "$CONTROLLER_IP" "${ADDITIONAL_CONTROLLERS[@]}" "$CONTROL_PLANE_VIP_IP")
    CPLB_UNICAST_PEERS=$(build_yaml_ip_list 20 "$NODE_IP" "$CONTROLLER_IP" "${ADDITIONAL_CONTROLLERS[@]}")

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
    local LONGHORN_BOOT_BLOCK=""
    if [ "${CONTROLLER_WORKER:-n}" = "y" ]; then
        LONGHORN_BOOT_BLOCK="${LONGHORN_MULTIPATH_BOOT_BLOCK}${LONGHORN_DM_CRYPT_BOOT_BLOCK}${LONGHORN_V2_BOOT_BLOCK}"
    fi

    # Use the same dedicated management key on every controller.
    prepare_controller_management_key || true

    # Build SSH keys block
    local SSH_KEYS_BLOCK="      - github:${GITHUB_USER}"
    if [ -n "$SSH_PUBKEY" ]; then
        SSH_KEYS_BLOCK="${SSH_KEYS_BLOCK}"$'\n'"      - ${SSH_PUBKEY}"
    fi
    if [ -n "$CONTROLLER_MANAGEMENT_PUBKEY" ]; then
        SSH_KEYS_BLOCK="${SSH_KEYS_BLOCK}"$'\n'"      - ${CONTROLLER_MANAGEMENT_PUBKEY}"
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
          port: 6443
          sans:
${CONTROLLER_API_SANS}
        network:
          provider: custom
          podCIDR: ${POD_CIDR}
          serviceCIDR: ${SERVICE_CIDR}
          kubeProxy:
            disabled: true
          controlPlaneLoadBalancing:
            enabled: true
            type: Keepalived
            keepalived:
              vrrpInstances:
                - virtualIPs:
                    - ${CONTROL_PLANE_VIP_CIDR}
                  authPass: "${CPLB_AUTH_PASS}"
                  virtualRouterID: ${CPLB_VIRTUAL_ROUTER_ID}
                  unicastSourceIP: ${NODE_IP}
                  unicastPeers:
${CPLB_UNICAST_PEERS}
          nodeLocalLoadBalancing:
            enabled: true
            type: EnvoyProxy
        storage:
          type: etcd
          etcd:
            peerAddress: ${NODE_IP}
        controllerManager: {}
        scheduler: {}
        telemetry:
          enabled: false
${CONTROLLER_MANAGEMENT_WRITE_FILES_BLOCK}
  - path: /usr/local/bin/kubectl
    permissions: "0755"
    content: |
      #!/bin/sh
      version="\$(k0s version 2>/dev/null | head -n 1 | sed 's/+k0s.*//')"
      if [ -x /var/lib/k0s/bin/kubectl ] && [ -r /var/lib/k0s/bin/kubectl.version ] && [ "\$(cat /var/lib/k0s/bin/kubectl.version)" = "\$version" ]; then
        exec /var/lib/k0s/bin/kubectl "\$@"
      fi
      exec k0s kubectl "\$@"
  - path: /usr/local/sbin/install-kubectl
    permissions: "0755"
    content: |
      #!/bin/sh
      set -u

      version="\$(k0s version 2>/dev/null | head -n 1 | sed 's/+k0s.*//')"
      case "\$version" in
        v[0-9]*.[0-9]*.[0-9]*) ;;
        *) echo "Unable to determine kubectl version from k0s: \$version"; exit 0 ;;
      esac

      case "\$(uname -m)" in
        x86_64|amd64) arch=amd64 ;;
        aarch64|arm64) arch=arm64 ;;
        *) echo "Unsupported kubectl architecture: \$(uname -m)"; exit 0 ;;
      esac

      dest=/var/lib/k0s/bin/kubectl
      marker=\${dest}.version
      mkdir -p /var/lib/k0s/bin /etc/bash_completion.d

      if [ -x "\$dest" ] && [ -r "\$marker" ] && [ "\$(cat "\$marker")" = "\$version" ]; then
        "\$dest" completion bash > /etc/bash_completion.d/kubectl 2>/dev/null || true
        exit 0
      fi

      rm -f /etc/bash_completion.d/kubectl
      tmp=/tmp/kubectl.download
      checksum=/tmp/kubectl.download.sha256
      trap 'rm -f "\$tmp" "\$checksum"' 0 HUP INT TERM
      url=https://dl.k8s.io/release/\${version}/bin/linux/\${arch}/kubectl

      if ! curl -fsSL "\$url" -o "\$tmp" || ! curl -fsSL "\${url}.sha256" -o "\$checksum"; then
        echo "Unable to download kubectl \$version; keeping k0s kubectl fallback."
        exit 0
      fi

      expected="\$(tr -d '[:space:]' < "\$checksum")"
      if [ -z "\$expected" ] || ! printf '%s  %s\n' "\$expected" "\$tmp" | sha256sum -c - >/dev/null 2>&1; then
        echo "kubectl checksum validation failed; keeping k0s kubectl fallback."
        exit 0
      fi

      if install -m 0755 "\$tmp" "\$dest"; then
        printf '%s\n' "\$version" > "\$marker"
        "\$dest" completion bash > /etc/bash_completion.d/kubectl 2>/dev/null || true
        echo "Installed kubectl \$version for shell completion."
      fi
  - path: /etc/profile.d/k0s-kubeconfig.sh
    permissions: "0644"
    content: |
      export KUBECONFIG=${K0S_KUBECONFIG}
      alias k=kubectl
      if [ -n "\${BASH_VERSION:-}" ]; then
        for completion in /usr/share/bash-completion/bash_completion /etc/bash_completion; do
          [ -r "\$completion" ] && . "\$completion"
        done
        for completion in /etc/bash_completion.d/k0s-compat /etc/bash_completion.d/k0s; do
          [ -r "\$completion" ] && source -- "\$completion"
        done
        if [ -s /etc/bash_completion.d/kubectl ]; then
          source -- /etc/bash_completion.d/kubectl
        elif [ -x /var/lib/k0s/bin/kubectl ]; then
          source <(/var/lib/k0s/bin/kubectl completion bash 2>/dev/null)
        fi
        type __start_kubectl >/dev/null 2>&1 && complete -o default -F __start_kubectl kubectl k
      fi
  - path: /root/.bashrc
    permissions: "0644"
    content: |
      if [ -r /etc/profile.d/k0s-kubeconfig.sh ]; then
        . /etc/profile.d/k0s-kubeconfig.sh
      fi
  - path: /root/.bash_profile
    permissions: "0644"
    content: |
      if [ -r "\$HOME/.bashrc" ]; then
        . "\$HOME/.bashrc"
      fi
  - path: /etc/bash_completion.d/k0s-compat
    permissions: "0644"
    content: |
      if ! type _get_comp_words_by_ref >/dev/null 2>&1; then
        _get_comp_words_by_ref() {
          local OPTIND opt cur_var prev_var words_var cword_var
          while getopts "n:" opt; do :; done
          shift \$((OPTIND - 1))
          while [ \$# -gt 0 ]; do
            case "\$1" in
              cur) cur_var=cur ;;
              prev) prev_var=prev ;;
              words) words_var=words ;;
              cword) cword_var=cword ;;
              *) ;;
            esac
            shift
          done
          [ -n "\$cur_var" ] && printf -v "\$cur_var" '%s' "\${COMP_WORDS[COMP_CWORD]}"
          if [ -n "\$prev_var" ]; then
            if [ "\$COMP_CWORD" -gt 0 ]; then
              printf -v "\$prev_var" '%s' "\${COMP_WORDS[COMP_CWORD-1]}"
            else
              printf -v "\$prev_var" '%s' ""
            fi
          fi
          if [ -n "\$words_var" ]; then
            local -n words_ref="\$words_var"
            words_ref=("\${COMP_WORDS[@]}")
          fi
          [ -n "\$cword_var" ] && printf -v "\$cword_var" '%s' "\$COMP_CWORD"
        }
      fi
      if ! type _init_completion >/dev/null 2>&1; then
        _init_completion() {
          local OPTIND opt
          COMPREPLY=()
          while getopts "n:e:o:i:s" opt; do :; done
          shift \$((OPTIND - 1))
          _get_comp_words_by_ref "\$@" cur prev words cword
        }
      fi
      if ! type __ltrim_colon_completions >/dev/null 2>&1; then
        __ltrim_colon_completions() { return 0; }
      fi
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
      CONTROL_PLANE_VIP_CIDR=${CONTROL_PLANE_VIP_CIDR}
      CPLB_AUTH_PASS=${CPLB_AUTH_PASS}
      CPLB_VIRTUAL_ROUTER_ID=${CPLB_VIRTUAL_ROUTER_ID}
      POD_CIDR=${POD_CIDR}
      SERVICE_CIDR=${SERVICE_CIDR}
      INSTALL_CILIUM=${INSTALL_CILIUM}
      GITHUB_USER=${GITHUB_USER}
      SSH_PUBKEY='${SSH_PUBKEY}'
      FLUX_BOOTSTRAP_MODE=${FLUX_BOOTSTRAP_MODE:-}
      FLUX_GITHUB_OWNER=${FLUX_GITHUB_OWNER:-}
      FLUX_GITHUB_REPOSITORY=${FLUX_GITHUB_REPOSITORY:-}
      FLUX_GITHUB_BRANCH=${FLUX_GITHUB_BRANCH:-}
      FLUX_GITHUB_PATH=${FLUX_GITHUB_PATH:-}
      FLUX_GITHUB_PERSONAL=${FLUX_GITHUB_PERSONAL:-}
      FLUX_COMPONENTS=(${FLUX_COMPONENTS[@]})
      FLUX_COMPONENTS_EXTRA=(${FLUX_COMPONENTS_EXTRA[@]})
# Persistent paths
bind_mounts:
  - /var/lib/k0s
  - /var/lib/kubelet

stages:
  boot:
    - name: "Update cluster manager script safely"
      commands:
        - ${SAFE_SCRIPT_UPDATE_COMMAND}
${LONGHORN_BOOT_BLOCK}
  boot.after:
    - name: "Enable iSCSI"
      commands:
        - systemctl enable iscsid
        - systemctl start iscsid
    - name: "Ensure standard kubelet root dir exists"
      if: "[ ! -d /var/lib/kubelet ]"
      commands:
        - mkdir -p /var/lib/kubelet
    - name: "Configure controller shell defaults"
      commands:
        - mkdir -p /etc/profile.d /etc/bash_completion.d /usr/local/bin /usr/local/sbin
        - chmod 0755 /usr/local/bin/kubectl /usr/local/sbin/install-kubectl
        - k0s completion bash > /etc/bash_completion.d/k0s 2>/dev/null || true
        - /usr/local/sbin/install-kubectl

reset:
  reboot: true
  reset-persistent: false
  reset-oem: false

upgrade:
  reboot: true

EOF

    chmod 0600 "$OUTPUT_FILE" 2>/dev/null || true

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

ensure_cilium_before_worker_install() {
    cilium_requested || return 0

    if ! command -v k0s &>/dev/null; then
        print_warning "INSTALL_CILIUM=y, but k0s was not found on this machine."
        print_info "Run this worker install action from a controller, or install Cilium manually first."
        return 1
    fi

    if cilium_already_installed; then
        print_successful "Cilium is already installed."
        return 0
    fi

    print_info "INSTALL_CILIUM=y. Installing Cilium before worker install requests..."
    print_info "Status wait is skipped until workers join."
    install_cilium skip-wait
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

    ensure_cilium_before_worker_install || return 1

    if inject_cloudconfig_webinstaller "$(worker_cloudconfig_file_for_ip "$worker_ip")" "$worker_ip"; then
        mark_worker_install_submitted "$worker_ip"
    fi
}

inject_all_workers() {
    if [ ${#WORKERS[@]} -eq 0 ]; then
        print_warning "No workers configured."
        return 0
    fi

    ensure_cilium_before_worker_install || return 1

    local worker_ip
    for worker_ip in "${WORKERS[@]}"; do
        if inject_cloudconfig_webinstaller "$(worker_cloudconfig_file_for_ip "$worker_ip")" "$worker_ip"; then
            mark_worker_install_submitted "$worker_ip"
        else
            return 1
        fi
    done
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
    local wait_mode="${1:-wait}"
    local control_plane_vip_ip="${CONTROL_PLANE_VIP_CIDR%/*}"
    local cilium_api_server_urls="https://${control_plane_vip_ip}:6443"
    local cilium_version

    print_info "Installing Cilium (k0s kubeconfig: $K0S_KUBECONFIG)..."
    install_cilium_cli

    cilium_version=$(get_latest_cilium_stable_version)
    if [ -n "$cilium_version" ]; then
        print_info "Using latest stable Cilium chart: ${cilium_version}"
    else
        print_warning "Could not determine the latest stable Cilium chart; using the Cilium CLI default."
    fi

    local install_args=(
        --kubeconfig "$K0S_KUBECONFIG"
        --set k8sServiceHost="${control_plane_vip_ip}"
        --set k8sServicePort=6443
        --set k8s.apiServerURLs="${cilium_api_server_urls}"
        --set kubeProxyReplacement=true
        --set tunnelProtocol=geneve
        --set loadBalancer.mode=dsr
        --set loadBalancer.dsrDispatch=geneve
        --set ipam.operator.clusterPoolIPv4PodCIDRList="${POD_CIDR}"
        --set ipv4.enabled=true
        --set enableIPv4Masquerade=true
        --set ipMasqAgent.enable=false
        --set routingMode=native
        --set ipam.mode=cluster-pool
        --set ipv4NativeRoutingCIDR="${POD_CIDR}"
        --set autoDirectNodeRoutes=true
        --set bpf.masquerade=true
        --set bgpControlPlane.enabled=true
        --set l2announcements.enabled=true
        --set k8sClientRateLimit.qps="${CILIUM_L2_CLIENT_QPS:-20}"
        --set k8sClientRateLimit.burst="${CILIUM_L2_CLIENT_BURST:-40}"
        --set hubble.relay.enabled=false
        --set hubble.enabled=false
        --set hubble.ui.enabled=false
        --set bgp.announce.loadbalancerIP=true
    )

    [ -n "$cilium_version" ] && install_args+=(--version "$cilium_version")

    [ "$wait_mode" = "skip-wait" ] && install_args+=(--wait=false)

    # Cilium uses the highly available control-plane VIP rather than one controller.
    if ! cilium install "${install_args[@]}"; then
        print_error "Cilium install failed."
        return 1
    fi

    if [ "$wait_mode" = "skip-wait" ]; then
        print_successful "Cilium install submitted."
        print_info "Cilium pods will become ready automatically when worker nodes join."
        return 0
    fi

    if ! cilium status --kubeconfig "$K0S_KUBECONFIG" --wait; then
        print_warning "Cilium was submitted, but status did not become ready yet."
        return 1
    fi
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
release_file_value() {
    local file="$1"
    local key="$2"

    [ -f "$file" ] || return 1
    sed -n "s/^${key}=//p" "$file" | head -n 1 | tr -d '"'
}

ensure_v_prefix() {
    local version="$1"

    [ -z "$version" ] && return 0
    case "$version" in
        v*) printf '%s\n' "$version" ;;
        *) printf 'v%s\n' "$version" ;;
    esac
}

version_tags_equal() {
    local left="$1"
    local right="$2"

    [ "$left" = "$right" ] || [ "${left#v}" = "${right#v}" ]
}

semver_numeric_part() {
    local value="$1"

    value="${value%%[^0-9]*}"
    [ -n "$value" ] || value=0
    printf '%d\n' "$((10#$value))"
}

semver_compare_identifiers() {
    local left="$1"
    local right="$2"
    local left_id
    local right_id
    local left_num
    local right_num

    while true; do
        if [ -z "$left" ] && [ -z "$right" ]; then
            echo 0
            return 0
        elif [ -z "$left" ]; then
            echo -1
            return 0
        elif [ -z "$right" ]; then
            echo 1
            return 0
        fi

        left_id="${left%%.*}"
        right_id="${right%%.*}"
        [ "$left_id" = "$left" ] && left="" || left="${left#*.}"
        [ "$right_id" = "$right" ] && right="" || right="${right#*.}"

        if [[ "$left_id" =~ ^[0-9]+$ ]] && [[ "$right_id" =~ ^[0-9]+$ ]]; then
            left_num=$((10#$left_id))
            right_num=$((10#$right_id))
            if [ "$left_num" -gt "$right_num" ]; then
                echo 1
                return 0
            elif [ "$left_num" -lt "$right_num" ]; then
                echo -1
                return 0
            fi
        elif [[ "$left_id" =~ ^[0-9]+$ ]]; then
            echo -1
            return 0
        elif [[ "$right_id" =~ ^[0-9]+$ ]]; then
            echo 1
            return 0
        elif [[ "$left_id" > "$right_id" ]]; then
            echo 1
            return 0
        elif [[ "$left_id" < "$right_id" ]]; then
            echo -1
            return 0
        fi
    done
}

semver_compare() {
    local left_raw="${1#v}"
    local right_raw="${2#v}"
    local left_build=""
    local right_build=""
    local left_version
    local right_version
    local left_core
    local right_core
    local left_pre=""
    local right_pre=""
    local left_major
    local left_minor
    local left_patch
    local right_major
    local right_minor
    local right_patch
    local left_value
    local right_value
    local result

    [[ "$left_raw" == *+* ]] && left_build="${left_raw#*+}"
    [[ "$right_raw" == *+* ]] && right_build="${right_raw#*+}"
    left_version="${left_raw%%+*}"
    right_version="${right_raw%%+*}"

    left_core="${left_version%%-*}"
    right_core="${right_version%%-*}"
    [[ "$left_version" == *-* ]] && left_pre="${left_version#*-}"
    [[ "$right_version" == *-* ]] && right_pre="${right_version#*-}"

    IFS=. read -r left_major left_minor left_patch _ <<< "$left_core"
    IFS=. read -r right_major right_minor right_patch _ <<< "$right_core"

    for part in major minor patch; do
        case "$part" in
            major)
                left_value=$(semver_numeric_part "$left_major")
                right_value=$(semver_numeric_part "$right_major")
                ;;
            minor)
                left_value=$(semver_numeric_part "$left_minor")
                right_value=$(semver_numeric_part "$right_minor")
                ;;
            patch)
                left_value=$(semver_numeric_part "$left_patch")
                right_value=$(semver_numeric_part "$right_patch")
                ;;
        esac

        if [ "$left_value" -gt "$right_value" ]; then
            echo 1
            return 0
        elif [ "$left_value" -lt "$right_value" ]; then
            echo -1
            return 0
        fi
    done

    if [ -z "$left_pre" ] && [ -n "$right_pre" ]; then
        echo 1
        return 0
    elif [ -n "$left_pre" ] && [ -z "$right_pre" ]; then
        echo -1
        return 0
    elif [ -n "$left_pre" ] || [ -n "$right_pre" ]; then
        result=$(semver_compare_identifiers "$left_pre" "$right_pre")
        [ "$result" != "0" ] && { echo "$result"; return 0; }
    fi

    if [ -n "$left_build" ] && [ -n "$right_build" ]; then
        result=$(semver_compare_identifiers "$left_build" "$right_build")
        [ "$result" != "0" ] && { echo "$result"; return 0; }
    fi

    echo 0
}

fetch_github_release_tags() {
    local repo="$1"
    local tags

    if [ "$repo" = "kairos-io/kairos" ]; then
        tags=$(curl -s --connect-timeout 5 --max-time 15 "https://api.github.com/repos/${repo}/tags?per_page=100" 2>/dev/null | github_tag_names)
        [ -n "$tags" ] && { printf '%s\n' "$tags"; return 0; }
    fi

    tags=$(curl -s --connect-timeout 5 --max-time 15 "https://api.github.com/repos/${repo}/releases?per_page=30" 2>/dev/null | github_release_tags)
    [ -n "$tags" ] && { printf '%s\n' "$tags"; return 0; }

    curl -s --connect-timeout 5 --max-time 15 "https://api.github.com/repos/${repo}/tags?per_page=100" 2>/dev/null | github_tag_names
}

print_release_lines() {
    local releases="$1"
    local limit="${2:-5}"
    local printed=0
    local version

    while IFS= read -r version; do
        [ -z "$version" ] && continue
        echo "   $version"
        printed=$((printed + 1))
        [ "$printed" -ge "$limit" ] && break
    done <<< "$releases"

    [ "$printed" -eq 0 ] && echo "   unavailable"
}

print_release_context() {
    local label="$1"
    local repo="$2"
    local current_version="$3"
    local releases
    local latest_version
    local version
    local compare_result
    local nearest_newer=""
    local previous_one=""
    local previous_two=""

    releases=$(fetch_github_release_tags "$repo")
    if [ -z "$releases" ]; then
        print_warning "Could not fetch ${label} releases from GitHub."
        return 0
    fi

    while IFS= read -r version; do
        [ -z "$version" ] && continue
        if [ -z "$latest_version" ] || [ "$(semver_compare "$version" "$latest_version")" -gt 0 ]; then
            latest_version="$version"
        fi
    done <<< "$releases"

    [ -n "$latest_version" ] && print_successful "Latest available ${label}: $latest_version"
    if [ -z "$current_version" ]; then
        print_info "Latest ${label} releases (last 5):"
        print_release_lines "$releases" 5
        return 0
    fi

    while IFS= read -r version; do
        [ -z "$version" ] && continue
        compare_result=$(semver_compare "$version" "$current_version")

        if [ "$compare_result" -gt 0 ]; then
            if [ -z "$nearest_newer" ] || [ "$(semver_compare "$version" "$nearest_newer")" -lt 0 ]; then
                nearest_newer="$version"
            fi
        elif [ "$compare_result" -lt 0 ]; then
            if [ -z "$previous_one" ] || [ "$(semver_compare "$version" "$previous_one")" -gt 0 ]; then
                if [ -n "$previous_one" ] && ! version_tags_equal "$version" "$previous_one"; then
                    previous_two="$previous_one"
                fi
                previous_one="$version"
            elif ! version_tags_equal "$version" "$previous_one" && { [ -z "$previous_two" ] || [ "$(semver_compare "$version" "$previous_two")" -gt 0 ]; }; then
                previous_two="$version"
            fi
        fi
    done <<< "$releases"

    print_info "Newer ${label} release:"
    if [ -z "$nearest_newer" ]; then
        echo "   none detected"
    else
        echo "   $nearest_newer"
    fi

    print_info "Previous ${label} releases:"
    if [ -z "$previous_one" ]; then
        echo "   none detected"
    else
        echo "   $previous_one"
        [ -n "$previous_two" ] && echo "   $previous_two"
    fi
}

version_kubectl() {
    local output
    local rc

    if command -v kubectl &>/dev/null; then
        output=$(KUBECONFIG="$K0S_KUBECONFIG" kubectl "$@" 2>/dev/null)
        rc=$?
        if [ "$rc" -eq 0 ]; then
            printf '%s\n' "$output"
            return 0
        fi
    fi

    if command -v k0s &>/dev/null; then
        k0s kubectl "$@"
        return $?
    fi

    return 127
}

get_k0s_running_version() {
    command -v k0s &>/dev/null || return 1
    k0s status 2>/dev/null | awk -F': ' '/^Version:/ { print $2; exit }'
}

get_k0s_binary_version() {
    command -v k0s &>/dev/null || return 1
    k0s version 2>/dev/null | head -n 1 | tr -d '[:space:]'
}

check_k0s_version() {
    print_info "Checking k0s version..."

    local running_version
    local binary_version
    local compare_version

    running_version=$(get_k0s_running_version)
    binary_version=$(get_k0s_binary_version)
    compare_version="${running_version:-$binary_version}"

    if [ -n "$running_version" ]; then
        print_successful "Running k0s version: $running_version"
    else
        print_warning "Running k0s version: not detected"
    fi

    if [ -n "$binary_version" ]; then
        if [ "$binary_version" != "$running_version" ]; then
            print_info "Local k0s binary version: $binary_version"
        fi
    else
        print_error "k0s not found on this node."
    fi

    print_release_context "k0s" "k0sproject/k0s" "$compare_version"
}

check_kairos_version() {
    print_info "Checking Kairos version..."

    local kairos_version
    local kairos_name
    local kairos_software_version
    local kairos_init_version

    kairos_version=$(release_file_value /etc/kairos-release KAIROS_VERSION)
    kairos_name=$(release_file_value /etc/kairos-release KAIROS_NAME)
    kairos_software_version=$(release_file_value /etc/kairos-release KAIROS_SOFTWARE_VERSION)
    kairos_init_version=$(release_file_value /etc/kairos-release KAIROS_INIT_VERSION)

    if [ -n "$kairos_version" ]; then
        print_successful "Running Kairos version: $kairos_version"
        [ -n "$kairos_name" ] && print_info "Kairos image: $kairos_name"
        [ -n "$kairos_software_version" ] && print_info "Embedded k0s version: $kairos_software_version"
        [ -n "$kairos_init_version" ] && print_info "Kairos init version: $kairos_init_version"
    elif command -v kairos-agent &>/dev/null; then
        kairos-agent version 2>/dev/null || print_error "Could not determine Kairos version."
    else
        print_error "Could not determine Kairos version."
    fi

    print_release_context "Kairos" "kairos-io/kairos" "$kairos_version"
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
            print_info "Choose 'Update Script Now' to apply it immediately."
        fi
    else
        print_warning "Could not reach GitHub to check latest version."
    fi
    print_info "Source: https://github.com/Kube-Link/k0s_script/blob/master/kairos_k0s_cluster_manager.sh"
}

update_script_now() {
    print_info "Updating cluster manager script now..."
    print_info "The validated download will replace /root/kairos-cluster-manager.sh and keep the previous copy as .old.sh."

    # Reuse the same validated A/B replacement command used during boot.
    eval "$SAFE_SCRIPT_UPDATE_COMMAND"

    if [ "${updated:-n}" != "y" ]; then
        print_error "Script update failed or was not completed."
        print_info "Update log: /var/log/kairos-cluster-manager-update.log"
        return 1
    fi

    print_successful "Script update completed."
    print_info "Restarting the script with the updated version..."
    exec /root/kairos-cluster-manager.sh
}

prepare_controller_management_key() {
    local key_dir
    local private_key_b64
    local public_key_b64

    CONTROLLER_MANAGEMENT_PUBKEY=""
    CONTROLLER_MANAGEMENT_WRITE_FILES_BLOCK=""
    key_dir=$(dirname "$CONTROLLER_MANAGEMENT_KEY_PATH")

    if ! command -v ssh-keygen &>/dev/null; then
        print_warning "ssh-keygen is unavailable; controller-to-controller VIP ownership checks will require SSH agent forwarding."
        return 1
    fi

    mkdir -p "$key_dir" || return 1
    chmod 0700 "$key_dir" 2>/dev/null || true

    if [ ! -s "$CONTROLLER_MANAGEMENT_KEY_PATH" ]; then
        if ! ssh-keygen -q -t ed25519 \
            -f "$CONTROLLER_MANAGEMENT_KEY_PATH" \
            -N "" \
            -C "${CLUSTER_NAME:-k0s}-controller-management"; then
            print_warning "Could not generate the controller-management SSH key."
            return 1
        fi
        print_successful "Generated dedicated controller-management SSH key: $CONTROLLER_MANAGEMENT_KEY_PATH"
    fi

    if [ ! -s "${CONTROLLER_MANAGEMENT_KEY_PATH}.pub" ]; then
        ssh-keygen -y -f "$CONTROLLER_MANAGEMENT_KEY_PATH" > "${CONTROLLER_MANAGEMENT_KEY_PATH}.pub" || return 1
    fi

    chmod 0600 "$CONTROLLER_MANAGEMENT_KEY_PATH" 2>/dev/null || true
    chmod 0644 "${CONTROLLER_MANAGEMENT_KEY_PATH}.pub" 2>/dev/null || true

    CONTROLLER_MANAGEMENT_PUBKEY=$(cat "${CONTROLLER_MANAGEMENT_KEY_PATH}.pub")
    private_key_b64=$(script_base64_lf "$CONTROLLER_MANAGEMENT_KEY_PATH")
    public_key_b64=$(script_base64_lf "${CONTROLLER_MANAGEMENT_KEY_PATH}.pub")
    CONTROLLER_MANAGEMENT_WRITE_FILES_BLOCK="  - path: /root/.ssh/id_ed25519_k0s_controllers
    permissions: \"0600\"
    encoding: b64
    content: ${private_key_b64}
  - path: /root/.ssh/id_ed25519_k0s_controllers.pub
    permissions: \"0644\"
    encoding: b64
    content: ${public_key_b64}"
}

ip_output_contains_address() {
    local address_output="$1"
    local target_ip="$2"

    printf '%s\n' "$address_output" | awk -v target="$target_ip" '
        {
            split($4, address, "/")
            if (address[1] == target) {
                found = 1
            }
        }
        END { exit found ? 0 : 1 }
    '
}

k0s_config_section_enabled() {
    local section="$1"

    awk -v section="$section" '
        index($0, section ":") {
            getline
            if ($0 ~ /^[[:space:]]*enabled:[[:space:]]*true[[:space:]]*$/) {
                found = 1
            }
            exit
        }
        END { exit found ? 0 : 1 }
    ' "$K0S_CONFIG_PATH"
}

check_control_plane_vip_status() {
    local vip_cidr="${CONTROL_PLANE_VIP_CIDR:-}"
    local vip_ip="${vip_cidr%/*}"
    local configured_controllers=("$CONTROLLER_IP" "${ADDITIONAL_CONTROLLERS[@]}")
    local local_address_output=""
    local local_controller_ip=""
    local controller_ip
    local controller_index=1
    local owner_count=0
    local checked_count=0
    local unavailable_count=0
    local owner_list=()
    local remote_address_output
    local remote_status
    local identity_file=""
    local candidate_key
    local vip_api_output
    local -a ssh_args

    print_info "Control-plane VIP / load balancing:"
    echo "Configured VIP: ${vip_cidr}"
    echo "VRRP router ID: ${CPLB_VIRTUAL_ROUTER_ID}"

    if [ -r "$K0S_CONFIG_PATH" ]; then
        if k0s_config_section_enabled "controlPlaneLoadBalancing" && \
           k0s_config_section_enabled "nodeLocalLoadBalancing" && \
           grep -Fq -- "- ${vip_cidr}" "$K0S_CONFIG_PATH" && \
           ! grep -Eq '^[[:space:]]*externalAddress:' "$K0S_CONFIG_PATH"; then
            print_successful "Local k0s config: CPLB enabled, NLLB enabled, VIP configured, externalAddress unset"
        else
            print_warning "Local k0s config does not contain the complete expected CPLB/NLLB configuration."
        fi
    else
        print_warning "Local k0s config not readable: $K0S_CONFIG_PATH"
    fi

    vip_api_output=$(k0s kubectl \
        --server="https://${vip_ip}:6443" \
        --request-timeout=5s get --raw=/readyz 2>&1)
    if [ $? -eq 0 ]; then
        vip_api_output=$(printf '%s' "$vip_api_output" | tr '\n' ' ')
        print_successful "VIP API ready${vip_api_output:+ (${vip_api_output})}"
    else
        print_warning "VIP API check failed for https://${vip_ip}:6443"
        echo "  $vip_api_output"
    fi

    if command -v ip &>/dev/null; then
        local_address_output=$(ip -4 -o addr show 2>/dev/null)
        for controller_ip in "${configured_controllers[@]}"; do
            if ip_output_contains_address "$local_address_output" "$controller_ip"; then
                local_controller_ip="$controller_ip"
                break
            fi
        done
    fi

    for candidate_key in "$CONTROLLER_MANAGEMENT_KEY_PATH" "$HOME/.ssh/id_ed25519_kairos" "$HOME/.ssh/id_ed25519" "$HOME/.ssh/id_rsa"; do
        if [ -r "$candidate_key" ]; then
            identity_file="$candidate_key"
            break
        fi
    done

    for controller_ip in "${configured_controllers[@]}"; do
        [ -n "$controller_ip" ] || continue

        if [ "$controller_ip" = "$local_controller_ip" ]; then
            checked_count=$((checked_count + 1))
            if ip_output_contains_address "$local_address_output" "$vip_ip"; then
                owner_list+=("${CLUSTER_NAME}-ctrl-${controller_index} (${controller_ip})")
                owner_count=$((owner_count + 1))
            fi
        elif command -v ssh &>/dev/null; then
            ssh_args=(
                -o BatchMode=yes
                -o ConnectTimeout=5
                -o StrictHostKeyChecking=accept-new
            )
            [ -n "$identity_file" ] && ssh_args=(-i "$identity_file" "${ssh_args[@]}")
            remote_address_output=$(ssh \
                "${ssh_args[@]}" \
                "root@${controller_ip}" \
                "ip -4 -o addr show 2>/dev/null" 2>/dev/null)
            remote_status=$?
            if [ "$remote_status" -eq 0 ]; then
                checked_count=$((checked_count + 1))
                if ip_output_contains_address "$remote_address_output" "$vip_ip"; then
                    owner_list+=("${CLUSTER_NAME}-ctrl-${controller_index} (${controller_ip})")
                    owner_count=$((owner_count + 1))
                fi
            else
                unavailable_count=$((unavailable_count + 1))
            fi
        else
            unavailable_count=$((unavailable_count + 1))
        fi
        controller_index=$((controller_index + 1))
    done

    if [ "$owner_count" -eq 1 ]; then
        print_successful "Current VIP owner: ${owner_list[0]}"
    elif [ "$owner_count" -gt 1 ]; then
        print_warning "Multiple controllers report owning the VIP: ${owner_list[*]}"
    elif [ "$checked_count" -gt 0 ]; then
        print_warning "No checked controller currently owns the configured VIP."
    else
        print_warning "VIP ownership could not be checked locally or over SSH."
    fi

    if [ "$unavailable_count" -gt 0 ]; then
        if [ "$owner_count" -gt 0 ]; then
            print_info "Remote ownership cross-check skipped for ${unavailable_count} controller(s) because SSH access is unavailable."
        else
            print_info "VIP ownership unavailable for ${unavailable_count} controller(s); API readiness remains the primary health check."
        fi
    fi
    echo ""
}

check_nllb_status() {
    local nllb_pods_output
    local nllb_ready_output
    local expected_count
    local ready_count
    local controller_endpoints
    local worker_nodes
    local worker_node
    local proxy_health

    print_info "Node-local load balancing (NLLB):"
    if k0s_config_section_enabled "nodeLocalLoadBalancing"; then
        print_successful "Configuration: enabled (EnvoyProxy)"
    else
        print_warning "NLLB is not enabled in the local k0s configuration."
    fi

    controller_endpoints=$(k0s kubectl -n default get endpointslices \
        -l kubernetes.io/service-name=kubernetes -o wide 2>&1)
    if [ $? -eq 0 ]; then
        print_info "Controller API endpoints available to NLLB:"
        echo "$controller_endpoints"
    else
        print_warning "Could not read the Kubernetes controller endpoints:"
        echo "$controller_endpoints"
    fi

    nllb_pods_output=$(k0s kubectl -n kube-system get pods \
        -l app.kubernetes.io/managed-by=k0s,app.kubernetes.io/component=nllb \
        -o wide 2>&1)
    if [ $? -eq 0 ]; then
        echo "$nllb_pods_output"
    else
        print_warning "Could not list NLLB pods:"
        echo "$nllb_pods_output"
        echo ""
        return 1
    fi

    expected_count=$(k0s kubectl get nodes --no-headers 2>/dev/null | awk 'NF { count++ } END { print count + 0 }')
    nllb_ready_output=$(k0s kubectl -n kube-system get pods \
        -l app.kubernetes.io/managed-by=k0s,app.kubernetes.io/component=nllb \
        -o 'custom-columns=NAME:.metadata.name,READY:.status.containerStatuses[0].ready,PHASE:.status.phase' \
        --no-headers 2>/dev/null)
    ready_count=$(printf '%s\n' "$nllb_ready_output" | awk '$2 == "true" && $3 == "Running" { count++ } END { print count + 0 }')

    if [ "$expected_count" -gt 0 ] && [ "$ready_count" -eq "$expected_count" ]; then
        print_successful "NLLB pods ready: ${ready_count}/${expected_count} (one per worker node)"
    else
        print_warning "NLLB pods ready: ${ready_count}/${expected_count} expected worker nodes"
    fi

    print_info "Worker proxy path health (API server -> Konnectivity/NLLB -> kubelet):"
    worker_nodes=$(k0s kubectl get nodes -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null)
    if [ -z "$worker_nodes" ]; then
        print_info "No worker nodes are registered yet."
    else
        while IFS= read -r worker_node; do
            [ -n "$worker_node" ] || continue
            proxy_health=$(k0s kubectl --request-timeout=5s \
                get --raw="/api/v1/nodes/${worker_node}/proxy/healthz" 2>&1)
            if [ $? -eq 0 ] && [ "$proxy_health" = "ok" ]; then
                print_successful "${worker_node}: proxy health ok"
            else
                print_warning "${worker_node}: proxy health failed"
                echo "  $proxy_health"
            fi
        done <<< "$worker_nodes"
    fi
    echo ""
}

check_cilium_connection_point() {
    local expected_host="${CONTROL_PLANE_VIP_CIDR%/*}"
    local expected_port="6443"
    local expected_url="https://${expected_host}:${expected_port}"
    local daemonset_hosts
    local daemonset_ports
    local operator_hosts
    local operator_ports
    local configured_urls
    local connection_mismatch="false"

    print_info "Cilium Kubernetes API connection point:"
    if ! k0s kubectl -n kube-system get daemonset cilium &>/dev/null; then
        print_info "Cilium is not installed yet."
        echo ""
        return 0
    fi

    print_info "Expected control-plane VIP: ${expected_url}"

    daemonset_hosts=$(k0s kubectl -n kube-system get daemonset cilium \
        -o 'jsonpath={.spec.template.spec.containers[*].env[?(@.name=="KUBERNETES_SERVICE_HOST")].value}' \
        2>/dev/null | tr ' ' '\n' | awk 'NF && !seen[$0]++ { if (value) value=value ","; value=value $0 } END { print value }')
    daemonset_ports=$(k0s kubectl -n kube-system get daemonset cilium \
        -o 'jsonpath={.spec.template.spec.containers[*].env[?(@.name=="KUBERNETES_SERVICE_PORT")].value}' \
        2>/dev/null | tr ' ' '\n' | awk 'NF && !seen[$0]++ { if (value) value=value ","; value=value $0 } END { print value }')

    if [ -n "$daemonset_hosts" ] && [ -n "$daemonset_ports" ]; then
        echo "Cilium agents: ${daemonset_hosts}:${daemonset_ports}"
        if [ "$daemonset_hosts" != "$expected_host" ] || [ "$daemonset_ports" != "$expected_port" ]; then
            connection_mismatch="true"
        fi
    else
        print_warning "Could not read the Kubernetes API endpoint from the Cilium DaemonSet."
        connection_mismatch="true"
    fi

    if k0s kubectl -n kube-system get deployment cilium-operator &>/dev/null; then
        operator_hosts=$(k0s kubectl -n kube-system get deployment cilium-operator \
            -o 'jsonpath={.spec.template.spec.containers[*].env[?(@.name=="KUBERNETES_SERVICE_HOST")].value}' \
            2>/dev/null | tr ' ' '\n' | awk 'NF && !seen[$0]++ { if (value) value=value ","; value=value $0 } END { print value }')
        operator_ports=$(k0s kubectl -n kube-system get deployment cilium-operator \
            -o 'jsonpath={.spec.template.spec.containers[*].env[?(@.name=="KUBERNETES_SERVICE_PORT")].value}' \
            2>/dev/null | tr ' ' '\n' | awk 'NF && !seen[$0]++ { if (value) value=value ","; value=value $0 } END { print value }')

        if [ -n "$operator_hosts" ] && [ -n "$operator_ports" ]; then
            echo "Cilium operator: ${operator_hosts}:${operator_ports}"
            if [ "$operator_hosts" != "$expected_host" ] || [ "$operator_ports" != "$expected_port" ]; then
                connection_mismatch="true"
            fi
        else
            print_warning "Could not read the Kubernetes API endpoint from the Cilium operator."
            connection_mismatch="true"
        fi
    fi

    configured_urls=$(k0s kubectl -n kube-system get configmap cilium-config \
        -o 'jsonpath={.data.k8s-api-server-urls}' 2>/dev/null)
    if [ -n "$configured_urls" ]; then
        echo "Cilium config: ${configured_urls}"
        if [ "$configured_urls" != "$expected_url" ]; then
            connection_mismatch="true"
        fi
    else
        print_warning "Cilium config does not expose k8s-api-server-urls."
        connection_mismatch="true"
    fi

    if [ "$connection_mismatch" = "false" ]; then
        print_successful "Cilium is using the configured control-plane VIP."
    else
        print_warning "Cilium's live Kubernetes API connection point does not fully match ${expected_url}."
    fi
    echo ""
}

ssh_read_kubelet_root_dir() {
    local node_ip="$1"
    local root_dir_command
    local remote_root_dir
    local candidate_key
    local remote_status
    local -a ssh_args

    SSH_READ_KUBELET_ROOT_ERROR=""
    root_dir_command="(ps -eo args 2>/dev/null; systemctl show k0sworker -p ExecStart --value 2>/dev/null; systemctl show k0scontroller -p ExecStart --value 2>/dev/null) | sed -n -e 's/.*--root-dir=\([^ ]*\).*/\1/p' -e 's/.*--kubelet-root-dir=\([^ ]*\).*/\1/p' | head -n 1"

    if ! command -v ssh &>/dev/null; then
        SSH_READ_KUBELET_ROOT_ERROR="ssh is not installed on the controller"
        return 1
    fi

    for candidate_key in "$CONTROLLER_MANAGEMENT_KEY_PATH" "$HOME/.ssh/id_ed25519_kairos" "$HOME/.ssh/id_ed25519" "$HOME/.ssh/id_rsa"; do
        [ -r "$candidate_key" ] || continue
        ssh_args=(
            -n
            -i "$candidate_key"
            -o BatchMode=yes
            -o ConnectTimeout=5
            -o StrictHostKeyChecking=accept-new
        )
        remote_root_dir=$(ssh "${ssh_args[@]}" "root@${node_ip}" "$root_dir_command" 2>/dev/null)
        remote_status=$?
        if [ "$remote_status" -eq 0 ] && [ -n "$remote_root_dir" ]; then
            printf '%s\n' "$remote_root_dir"
            return 0
        fi
    done

    ssh_args=(
        -n
        -o BatchMode=yes
        -o ConnectTimeout=5
        -o StrictHostKeyChecking=accept-new
    )
    remote_root_dir=$(ssh "${ssh_args[@]}" "root@${node_ip}" "$root_dir_command" 2>/dev/null)
    remote_status=$?
    if [ "$remote_status" -eq 0 ] && [ -n "$remote_root_dir" ]; then
        printf '%s\n' "$remote_root_dir"
        return 0
    fi

    if [ "$remote_status" -eq 0 ]; then
        SSH_READ_KUBELET_ROOT_ERROR="SSH succeeded, but no kubelet root-dir argument was found"
    else
        SSH_READ_KUBELET_ROOT_ERROR="SSH authentication or connectivity failed"
    fi
    return 1
}

check_kubelet_root_dir_status() {
    local node_names
    local node_name
    local node_ip
    local root_dir
    local local_addresses=""
    local local_root_dir
    local nodes_output

    print_info "Kubelet root directory (expected: ${KUBELET_ROOT_DIR}):"
    if ! command -v k0s &>/dev/null; then
        print_error "k0s not found on this node."
        return 1
    fi

    if command -v ip &>/dev/null; then
        local_addresses=$(ip -4 -o addr show 2>/dev/null)
    fi

    nodes_output=$(k0s kubectl get nodes -o wide 2>&1)
    if [ $? -ne 0 ]; then
        print_warning "Could not list nodes:"
        echo "$nodes_output"
        echo ""
        return 1
    fi

    node_names=$(k0s kubectl get nodes -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null)
    if [ -z "$node_names" ]; then
        print_info "No nodes are registered yet."
        echo ""
        return 0
    fi

    while IFS= read -r node_name; do
        [ -n "$node_name" ] || continue
        node_ip=$(k0s kubectl get node "$node_name" \
            -o jsonpath='{.status.addresses[?(@.type=="InternalIP")].address}' 2>/dev/null)
        root_dir=""
        SSH_READ_KUBELET_ROOT_ERROR=""

        if [ -n "$node_ip" ] && ip_output_contains_address "$local_addresses" "$node_ip"; then
            local_root_dir=$(
                (
                    ps -eo args 2>/dev/null
                    systemctl show k0sworker -p ExecStart --value 2>/dev/null
                    systemctl show k0scontroller -p ExecStart --value 2>/dev/null
                ) | sed -n \
                    -e 's/.*--root-dir=\([^ ]*\).*/\1/p' \
                    -e 's/.*--kubelet-root-dir=\([^ ]*\).*/\1/p' \
                | head -n 1
            )
            root_dir="$local_root_dir"
        elif [ -n "$node_ip" ]; then
            root_dir=$(ssh_read_kubelet_root_dir "$node_ip")
        fi

        if [ -z "$root_dir" ]; then
            if [ -n "$SSH_READ_KUBELET_ROOT_ERROR" ]; then
                print_warning "${node_name} (${node_ip}): ${SSH_READ_KUBELET_ROOT_ERROR}"
            else
                print_warning "${node_name} (${node_ip:-IP unknown}): kubelet root directory could not be read"
            fi
        elif [ "$root_dir" = "$KUBELET_ROOT_DIR" ]; then
            print_successful "${node_name} (${node_ip}): ${root_dir}"
        else
            print_warning "${node_name} (${node_ip}): ${root_dir} (expected ${KUBELET_ROOT_DIR})"
        fi
    done <<< "$node_names"
    echo ""
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

    check_control_plane_vip_status

    print_info "Configured controllers:"
    local configured_controllers=("$CONTROLLER_IP" "${ADDITIONAL_CONTROLLERS[@]}")
    local controller_index=1
    local controller_ip
    local controller_api_output
    local controller_api_status
    local controller_role

    for controller_ip in "${configured_controllers[@]}"; do
        [ -n "$controller_ip" ] || continue
        if [ "$controller_index" -eq 1 ]; then
            controller_role="primary"
        else
            controller_role="additional"
        fi

        controller_api_output=$(k0s kubectl \
            --server="https://${controller_ip}:6443" \
            --request-timeout=5s get --raw=/readyz 2>&1)
        controller_api_status=$?
        if [ "$controller_api_status" -eq 0 ]; then
            controller_api_output=$(printf '%s' "$controller_api_output" | tr '\n' ' ')
            print_successful "${CLUSTER_NAME}-ctrl-${controller_index} (${controller_ip}, ${controller_role}): API ready${controller_api_output:+ (${controller_api_output})}"
        else
            print_warning "${CLUSTER_NAME}-ctrl-${controller_index} (${controller_ip}, ${controller_role}): API check failed"
            echo "  $controller_api_output"
        fi
        controller_index=$((controller_index + 1))
    done
    echo ""

    print_info "etcd controller membership:"
    local etcd_members_output
    local etcd_member_list_status
    etcd_members_output=$(k0s etcd member-list 2>&1)
    etcd_member_list_status=$?
    if [ "$etcd_member_list_status" -eq 0 ]; then
        echo "$etcd_members_output"
        controller_index=1
        for controller_ip in "${configured_controllers[@]}"; do
            [ -n "$controller_ip" ] || continue
            if printf '%s\n' "$etcd_members_output" | grep -Fq "https://${controller_ip}:2380"; then
                print_successful "${CLUSTER_NAME}-ctrl-${controller_index} (${controller_ip}): etcd member present"
            else
                print_warning "${CLUSTER_NAME}-ctrl-${controller_index} (${controller_ip}): not found in etcd member list"
            fi
            controller_index=$((controller_index + 1))
        done
    else
        print_warning "Could not read etcd member list:"
        echo "$etcd_members_output"
    fi
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

    check_nllb_status

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
    check_cilium_connection_point

    if command -v cilium &>/dev/null; then
        print_info "Cilium status:"
        cilium status --kubeconfig "$K0S_KUBECONFIG" 2>/dev/null || print_info "Cilium CLI found but unable to get status."
    else
        if k0s kubectl get daemonset cilium -n kube-system &>/dev/null; then
            print_info "Cilium CLI not installed, but Cilium pods were found:"
            k0s kubectl get pods -n kube-system -l k8s-app=cilium -o wide 2>/dev/null
        else
            print_info "Cilium not detected yet. Run 'Manage Cilium' after the control plane is ready."
        fi
    fi
}

manage_cluster_status() {
    while true; do
        echo -e "${YELLOW}======== Cluster Status / Diagnostics ========${NC}"
        echo "1. Full Cluster Status"
        echo "2. Check Kubelet Root Directory"
        echo "3. Check Cilium API Connection Point"
        echo "4. Check NLLB / Worker Proxy Status"
        echo "5. Back to Main Menu"
        echo -e "${YELLOW}==============================================${NC}"
        if ! read -p "Enter your choice: " status_choice; then
            echo ""
            print_info "Input closed. Returning to main menu."
            return 0
        fi

        case "$status_choice" in
            1) check_cluster_status ;;
            2) check_kubelet_root_dir_status ;;
            3) check_cilium_connection_point ;;
            4) check_nllb_status ;;
            5) return 0 ;;
            "") continue ;;
            *) print_error "Invalid option." ;;
        esac
    done
}

github_release_tags() {
    tr '{,' '\n' | sed -n 's/.*"tag_name":[[:space:]]*"\([^"]*\)".*/\1/p' | sed -n '/^v[0-9]/p'
}

github_tag_names() {
    tr '{,' '\n' | sed -n 's/.*"name":[[:space:]]*"\([^"]*\)".*/\1/p' | sed -n '/^v[0-9]/p'
}

# -----------------------------------------------------------------------------
# Cilium version / upgrade checks (ported from k3s script)
# -----------------------------------------------------------------------------
get_cilium_cli_version() {
    command -v cilium &>/dev/null || return 1
    cilium version 2>/dev/null | awk '/cilium-cli/ { print $2; exit }'
}

get_cilium_cluster_version() {
    local image
    local image_tail
    local version

    version_kubectl get daemonset cilium -n kube-system &>/dev/null || return 1
    image=$(version_kubectl get daemonset cilium -n kube-system -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null)
    [ -n "$image" ] || return 1

    image="${image%%@*}"
    image_tail="${image##*/}"
    [[ "$image_tail" == *:* ]] || return 1
    version="${image_tail##*:}"
    [ -n "$version" ] || return 1
    ensure_v_prefix "$version"
}

get_latest_cilium_stable_version() {
    local latest_version

    latest_version=$(curl -s --connect-timeout 5 --max-time 15 https://raw.githubusercontent.com/cilium/cilium/master/stable.txt 2>/dev/null | tr -d '[:space:]')
    [ -z "$latest_version" ] && latest_version=$(curl -s --connect-timeout 5 --max-time 15 https://api.github.com/repos/cilium/cilium/releases/latest 2>/dev/null | github_release_tags | head -n 1)
    printf '%s\n' "$latest_version"
}

check_cilium_version() {
    print_info "Checking Cilium version..."

    local cli_version
    local cluster_version
    local latest_version

    cli_version=$(get_cilium_cli_version)
    cluster_version=$(get_cilium_cluster_version)
    latest_version=$(get_latest_cilium_stable_version)

    if [ -n "$cluster_version" ]; then
        print_successful "Running Cilium version: $cluster_version"
    else
        print_warning "Running Cilium version: not detected in cluster"
    fi

    if [ -n "$cli_version" ]; then
        print_info "Local Cilium CLI version: $cli_version"
    else
        print_warning "Local Cilium CLI version: not installed"
    fi

    [ -n "$latest_version" ] && print_successful "Latest stable Cilium version: $latest_version"

    if [ -n "$cluster_version" ] && [ -n "$latest_version" ]; then
        if version_tags_equal "$cluster_version" "$latest_version"; then
            print_successful "Running Cilium matches the latest stable version."
        else
            print_info "Stable upgrade path: $cluster_version -> $latest_version"
        fi
    fi

    print_release_context "Cilium" "cilium/cilium" "$cluster_version"
}

get_flux_cli_version() {
    command -v flux &>/dev/null || return 1
    flux --version 2>/dev/null | head -n 1
}

get_flux_release_tag() {
    local cli_version
    local flux_version_output
    local release_version

    if command -v flux &>/dev/null; then
        flux_version_output=$(KUBECONFIG="$K0S_KUBECONFIG" flux version 2>/dev/null)
        release_version=$(printf '%s\n' "$flux_version_output" | awk -F': ' '/^distribution:/ { sub(/^flux-/, "", $2); print $2; exit }')
        [ -z "$release_version" ] && release_version=$(printf '%s\n' "$flux_version_output" | awk -F': ' '/^flux:/ { print $2; exit }')
    fi

    if [ -z "$release_version" ]; then
        cli_version=$(get_flux_cli_version)
        release_version=$(printf '%s\n' "$cli_version" | grep -Eo 'v?[0-9]+\.[0-9]+\.[0-9]+[^ ]*' | head -n 1)
    fi

    ensure_v_prefix "$release_version"
}

get_flux_controller_versions() {
    version_kubectl get namespace flux-system &>/dev/null || return 1
    version_kubectl get deployments -n flux-system -o jsonpath='{range .items[*]}{.metadata.name}{"="}{.spec.template.spec.containers[0].image}{"\n"}{end}' 2>/dev/null
}

print_flux_controller_versions() {
    local controller_versions="$1"
    local line
    local name
    local image
    local image_tail
    local version

    while IFS= read -r line; do
        [ -z "$line" ] && continue
        name="${line%%=*}"
        image="${line#*=}"
        image="${image%%@*}"
        image_tail="${image##*/}"
        if [[ "$image_tail" == *:* ]]; then
            version="${image_tail##*:}"
        else
            version="$image"
        fi
        [ -z "$version" ] && version="$image"
        echo "   ${name}: ${version}"
    done <<< "$controller_versions"
}

print_current_version_summary() {
    local k0s_running_version
    local kairos_version
    local cilium_cluster_version
    local flux_controller_versions

    k0s_running_version=$(get_k0s_running_version)
    kairos_version=$(release_file_value /etc/kairos-release KAIROS_VERSION)
    cilium_cluster_version=$(get_cilium_cluster_version)
    flux_controller_versions=$(get_flux_controller_versions)

    print_info "Current / running versions:"
    echo "   k0s: ${k0s_running_version:-not detected}"
    echo "   Kairos: ${kairos_version:-not detected}"
    echo "   Cilium: ${cilium_cluster_version:-not detected}"
    if [ -n "$flux_controller_versions" ]; then
        echo "   FluxCD controllers:"
        print_flux_controller_versions "$flux_controller_versions"
    else
        echo "   FluxCD: not detected"
    fi
    echo "   Script: v${SCRIPT_VERSION}"
}

check_fluxcd_version() {
    print_info "Checking FluxCD version..."

    local cli_version
    local release_version
    local controller_versions

    cli_version=$(get_flux_cli_version)
    release_version=$(get_flux_release_tag)
    controller_versions=$(get_flux_controller_versions)

    if [ -n "$controller_versions" ]; then
        print_successful "Running Flux controllers:"
        print_flux_controller_versions "$controller_versions"
    else
        print_warning "Running Flux controllers: not detected in cluster"
    fi

    if [ -n "$cli_version" ]; then
        print_info "Local Flux CLI version: $cli_version"
    else
        print_warning "Local Flux CLI version: not installed"
    fi

    if [ -n "$release_version" ]; then
        print_info "Flux release version used for comparison: $release_version"
    else
        print_info "Flux release comparison requires the Flux CLI version; showing latest releases only."
    fi

    print_release_context "FluxCD" "fluxcd/flux2" "$release_version"
}

list_available_versions() {
    local latest_cilium_stable

    echo -e "${YELLOW}======== Available Versions ========${NC}"
    print_current_version_summary
    echo ""

    # k0s versions
    print_info "Latest k0s Releases (Last 5):"
    print_release_lines "$(fetch_github_release_tags "k0sproject/k0s")" 5
    echo ""

    # Cilium versions
    print_info "Cilium Stable Version:"
    latest_cilium_stable=$(get_latest_cilium_stable_version)
    echo "   ${latest_cilium_stable:-unavailable}"
    echo ""
    print_info "Latest Cilium Releases (Last 5):"
    print_release_lines "$(fetch_github_release_tags "cilium/cilium")" 5
    echo ""

    # FluxCD versions
    print_info "Latest FluxCD Releases (Last 5):"
    print_release_lines "$(fetch_github_release_tags "fluxcd/flux2")" 5
    echo ""

    # Kairos versions
    print_info "Latest Kairos Releases (Last 5):"
    print_release_lines "$(fetch_github_release_tags "kairos-io/kairos")" 5

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

    local upgrade_args=(
        --kubeconfig "$K0S_KUBECONFIG"
        --reuse-values
        --set l2announcements.enabled=true
        --set k8sClientRateLimit.qps="${CILIUM_L2_CLIENT_QPS:-20}"
        --set k8sClientRateLimit.burst="${CILIUM_L2_CLIENT_BURST:-40}"
    )

    [ -n "$CILIUM_VERSION" ] && upgrade_args+=(--version "$CILIUM_VERSION")

    print_info "Upgrading Cilium in cluster and applying L2 announcement configuration..."
    if ! cilium upgrade "${upgrade_args[@]}"; then
        print_error "Cilium upgrade failed."
        return 1
    fi

    print_info "Waiting for Cilium to be ready..."
    if ! cilium status --kubeconfig "$K0S_KUBECONFIG" --wait; then
        print_warning "Cilium upgrade was submitted, but status did not become ready yet."
        return 1
    fi
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
apiVersion: cilium.io/v2
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
apiVersion: cilium.io/v2
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
apiVersion: cilium.io/v2
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
apiVersion: "cilium.io/v2"
kind: CiliumLoadBalancerIPPool
metadata:
  name: "first-pool"
spec:
  blocks:
    - start: "$LB_IP_START"
      stop: "$LB_IP_END"
EOF

    printf '%s\n' \
        'apiVersion: cilium.io/v2alpha1' \
        'kind: CiliumL2AnnouncementPolicy' \
        'metadata:' \
        '  name: l2-loadbalancer' \
        'spec:' \
        '  serviceSelector:' \
        '    matchExpressions:' \
        '      - { key: bgp, operator: In, values: [ external ] }' \
        '  loadBalancerIPs: true' \
        > ./bgp_config/CiliumL2AnnouncementPolicy.yaml

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

    if [ ! -d "./bgp_config" ] || \
        [ ! -f "./bgp_config/CiliumBGPClusterConfig.yaml" ] || \
        [ ! -f "./bgp_config/CiliumL2AnnouncementPolicy.yaml" ]; then
        print_error "BGP configuration files not found. Generate them first."
        read -p "Generate BGP configuration now? (y/n): " generate_config
        [ "$generate_config" = "y" ] && generate_bgp_config || return 1
    fi

    print_info "Applying CiliumLoadBalancerIPPool..."
    k0s_kubectl apply -f ./bgp_config/CiliumLoadBalancerIPPool.yaml

    print_info "Applying CiliumL2AnnouncementPolicy..."
    k0s_kubectl apply -f ./bgp_config/CiliumL2AnnouncementPolicy.yaml

    print_info "Applying CiliumBGPPeerConfig..."
    k0s_kubectl apply -f ./bgp_config/CiliumBGPPeerConfig.yaml

    print_info "Applying CiliumBGPAdvertisement..."
    k0s_kubectl apply -f ./bgp_config/CiliumBGPAdvertisement.yaml

    print_info "Applying CiliumBGPClusterConfig..."
    k0s_kubectl apply -f ./bgp_config/CiliumBGPClusterConfig.yaml

    print_successful "BGP configuration applied to the cluster"
    print_info "Run 'k0s_kubectl get ciliumloadbalancerippool,ciliuml2announcementpolicy,ciliumbgppeerconfig,ciliumbgpadvertisement,ciliumbgpclusterconfig' to verify"
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
    k0s_kubectl get ciliumloadbalancerippool,ciliuml2announcementpolicy,ciliumbgppeerconfig,ciliumbgpadvertisement,ciliumbgpclusterconfig

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

flux_array_contains() {
    local needle="$1"
    shift
    local value
    for value in "$@"; do
        [ "$value" = "$needle" ] && return 0
    done
    return 1
}

flux_join_csv() {
    local IFS=,
    printf '%s' "$*"
}

flux_load_bootstrap_settings() {
    if [ -f "$CONFIG_FILE" ]; then
        # The cluster config is already validated before normal workflows.
        # Loading it here also supports older configs without Flux keys.
        source "$CONFIG_FILE"
    fi

    if ! declare -p FLUX_COMPONENTS >/dev/null 2>&1 || [ "${#FLUX_COMPONENTS[@]}" -eq 0 ]; then
        FLUX_COMPONENTS=("${FLUX_DEFAULT_COMPONENTS[@]}")
    fi
    if ! declare -p FLUX_COMPONENTS_EXTRA >/dev/null 2>&1; then
        FLUX_COMPONENTS_EXTRA=("${FLUX_DEFAULT_COMPONENTS_EXTRA[@]}")
    fi

    FLUX_GITHUB_PERSONAL=${FLUX_GITHUB_PERSONAL:-y}
}

flux_save_bootstrap_settings() {
    if [ ! -f "$CONFIG_FILE" ]; then
        print_warning "Config file not found; Flux settings were not persisted."
        return 0
    fi

    upsert_config_value "$CONFIG_FILE" "FLUX_BOOTSTRAP_MODE" "${FLUX_BOOTSTRAP_MODE:-github}"
    upsert_config_value "$CONFIG_FILE" "FLUX_GITHUB_OWNER" "${FLUX_GITHUB_OWNER:-}"
    upsert_config_value "$CONFIG_FILE" "FLUX_GITHUB_REPOSITORY" "${FLUX_GITHUB_REPOSITORY:-}"
    upsert_config_value "$CONFIG_FILE" "FLUX_GITHUB_BRANCH" "${FLUX_GITHUB_BRANCH:-main}"
    upsert_config_value "$CONFIG_FILE" "FLUX_GITHUB_PATH" "${FLUX_GITHUB_PATH:-cluster}"
    upsert_config_value "$CONFIG_FILE" "FLUX_GITHUB_PERSONAL" "${FLUX_GITHUB_PERSONAL:-y}"
    upsert_config_array "$CONFIG_FILE" "FLUX_COMPONENTS" "${FLUX_COMPONENTS[@]}"
    upsert_config_array "$CONFIG_FILE" "FLUX_COMPONENTS_EXTRA" "${FLUX_COMPONENTS_EXTRA[@]}"
    print_successful "Flux bootstrap settings saved to $CONFIG_FILE (credentials were not saved)."
}

show_flux_bootstrap_settings() {
    flux_load_bootstrap_settings

    echo -e "${YELLOW}======== Saved Flux Bootstrap Settings ========${NC}"
    echo "Mode: ${FLUX_BOOTSTRAP_MODE:-not configured}"
    echo "GitHub owner: ${FLUX_GITHUB_OWNER:-not configured}"
    echo "Repository: ${FLUX_GITHUB_REPOSITORY:-not configured}"
    echo "Branch: ${FLUX_GITHUB_BRANCH:-main}"
    echo "Cluster path: ${FLUX_GITHUB_PATH:-cluster}"
    echo "Personal repository: ${FLUX_GITHUB_PERSONAL:-y}"
    echo "Components: $(flux_join_csv "${FLUX_COMPONENTS[@]}")"
    echo "Extra components: $(flux_join_csv "${FLUX_COMPONENTS_EXTRA[@]}")"
    echo "GitHub token: not stored"
    echo -e "${YELLOW}==============================================${NC}"
}

install_or_update_flux_cli() {
    local installer

    installer=$(mktemp "${TMPDIR:-/tmp}/flux-install.XXXXXX") || {
        print_error "Could not create a temporary file for the Flux CLI installer."
        return 1
    }

    print_info "Installing/updating the Flux CLI..."
    if ! curl -fsSL https://fluxcd.io/install.sh -o "$installer" || ! sudo bash "$installer"; then
        rm -f "$installer"
        print_error "Flux CLI installation/update failed."
        return 1
    fi
    rm -f "$installer"

    if ! command -v flux >/dev/null 2>&1; then
        print_error "Flux CLI is still not available in PATH."
        return 1
    fi
    print_successful "Flux CLI ready: $(flux --version 2>/dev/null | head -n 1)"
}

prompt_flux_component_selection() {
    local standard_selection
    local extra_selection
    local choice
    local -a choices

    echo ""
    print_info "Standard Flux controllers:"
    echo "  1. source-controller (required)"
    echo "  2. kustomize-controller (required)"
    echo "  3. helm-controller (recommended for HelmRelease resources)"
    echo "  4. notification-controller"
    echo "Current: $(flux_join_csv "${FLUX_COMPONENTS[@]}")"
    read -r -p "Select standard controllers by number, or press Enter to keep current: " standard_selection || return 1

    if [ -n "$standard_selection" ]; then
        if [[ "$standard_selection" =~ ^[Nn][Oo][Nn][Ee]$ || "$standard_selection" = "0" ]]; then
            FLUX_COMPONENTS=()
        else
            FLUX_COMPONENTS=()
            IFS=',' read -ra choices <<< "$standard_selection"
            for choice in "${choices[@]}"; do
                choice=$(trim_value "$choice")
                case "$choice" in
                    1) flux_array_contains source-controller "${FLUX_COMPONENTS[@]}" || FLUX_COMPONENTS+=(source-controller) ;;
                    2) flux_array_contains kustomize-controller "${FLUX_COMPONENTS[@]}" || FLUX_COMPONENTS+=(kustomize-controller) ;;
                    3) flux_array_contains helm-controller "${FLUX_COMPONENTS[@]}" || FLUX_COMPONENTS+=(helm-controller) ;;
                    4) flux_array_contains notification-controller "${FLUX_COMPONENTS[@]}" || FLUX_COMPONENTS+=(notification-controller) ;;
                    *) print_error "Invalid standard controller selection: $choice"; return 1 ;;
                esac
            done
        fi
    fi

    if ! flux_array_contains source-controller "${FLUX_COMPONENTS[@]}" || \
       ! flux_array_contains kustomize-controller "${FLUX_COMPONENTS[@]}"; then
        print_error "source-controller and kustomize-controller are required for Flux bootstrap."
        return 1
    fi

    if ! flux_array_contains helm-controller "${FLUX_COMPONENTS[@]}"; then
        local continue_without_helm
        prompt_yn continue_without_helm "Helm controller is not selected; HelmRelease resources will not reconcile. Continue? (y/n, default: n): " "n" || return 1
        [ "$continue_without_helm" = "y" ] || return 1
    fi

    print_info "Optional Flux controllers:"
    echo "  1. image-reflector-controller"
    echo "  2. image-automation-controller (requires image-reflector-controller)"
    echo "Current: $(flux_join_csv "${FLUX_COMPONENTS_EXTRA[@]}")"
    read -r -p "Select optional controllers by number, 'none', or press Enter to keep current: " extra_selection || return 1

    if [ -n "$extra_selection" ]; then
        if [[ "$extra_selection" =~ ^[Nn][Oo][Nn][Ee]$ || "$extra_selection" = "0" ]]; then
            FLUX_COMPONENTS_EXTRA=()
        else
            FLUX_COMPONENTS_EXTRA=()
            IFS=',' read -ra choices <<< "$extra_selection"
            for choice in "${choices[@]}"; do
                choice=$(trim_value "$choice")
                case "$choice" in
                    1) flux_array_contains image-reflector-controller "${FLUX_COMPONENTS_EXTRA[@]}" || FLUX_COMPONENTS_EXTRA+=(image-reflector-controller) ;;
                    2) flux_array_contains image-automation-controller "${FLUX_COMPONENTS_EXTRA[@]}" || FLUX_COMPONENTS_EXTRA+=(image-automation-controller) ;;
                    *) print_error "Invalid optional controller selection: $choice"; return 1 ;;
                esac
            done
        fi
    fi

    if flux_array_contains image-automation-controller "${FLUX_COMPONENTS_EXTRA[@]}" && \
       ! flux_array_contains image-reflector-controller "${FLUX_COMPONENTS_EXTRA[@]}"; then
        FLUX_COMPONENTS_EXTRA=(image-reflector-controller "${FLUX_COMPONENTS_EXTRA[@]}")
        print_info "image-reflector-controller was added because image automation requires it."
    fi
}

prompt_flux_github_settings() {
    local input
    local use_saved=y

    flux_load_bootstrap_settings
    if [ -n "${FLUX_GITHUB_OWNER:-}" ] || [ -n "${FLUX_GITHUB_REPOSITORY:-}" ]; then
        prompt_yn use_saved "Use saved Flux GitHub settings? (y/n, default: y): " "y" || return 1
        if [ "$use_saved" = "n" ]; then
            FLUX_GITHUB_OWNER=""
            FLUX_GITHUB_REPOSITORY=""
            FLUX_GITHUB_BRANCH="main"
            FLUX_GITHUB_PATH="cluster"
        fi
    fi

    read -r -p "GitHub owner (user/org) [${FLUX_GITHUB_OWNER:-}]: " input || return 1
    FLUX_GITHUB_OWNER=$(trim_value "${input:-${FLUX_GITHUB_OWNER:-}}")
    [ -n "$FLUX_GITHUB_OWNER" ] || { print_error "GitHub owner is required."; return 1; }

    read -r -p "GitHub repository [${FLUX_GITHUB_REPOSITORY:-}]: " input || return 1
    FLUX_GITHUB_REPOSITORY=$(trim_value "${input:-${FLUX_GITHUB_REPOSITORY:-}}")
    [ -n "$FLUX_GITHUB_REPOSITORY" ] || { print_error "GitHub repository is required."; return 1; }

    read -r -p "Branch [${FLUX_GITHUB_BRANCH:-main}]: " input || return 1
    FLUX_GITHUB_BRANCH=$(trim_value "${input:-${FLUX_GITHUB_BRANCH:-main}}")

    read -r -p "Cluster path in repository [${FLUX_GITHUB_PATH:-cluster}]: " input || return 1
    FLUX_GITHUB_PATH=$(trim_value "${input:-${FLUX_GITHUB_PATH:-cluster}}")

    prompt_yn FLUX_GITHUB_PERSONAL "Is this a personal repository? (y/n, default: ${FLUX_GITHUB_PERSONAL:-y}): " "${FLUX_GITHUB_PERSONAL:-y}" || return 1
    prompt_flux_component_selection || return 1

    echo ""
    print_info "A GitHub PAT is used only for this command and is never saved in the config."
    if [ -n "${GITHUB_TOKEN:-}" ]; then
        FLUX_GITHUB_TOKEN="$GITHUB_TOKEN"
        print_info "Using GITHUB_TOKEN from the environment."
    else
        read -r -s -p "GitHub Personal Access Token: " FLUX_GITHUB_TOKEN || return 1
        echo ""
    fi
    [ -n "${FLUX_GITHUB_TOKEN:-}" ] || { print_error "A GitHub token is required for token-auth bootstrap."; return 1; }

    FLUX_BOOTSTRAP_MODE=github
}

prompt_flux_install_mode() {
    flux_load_bootstrap_settings
    if [ -n "${FLUX_BOOTSTRAP_MODE:-}" ]; then
        return 0
    fi

    echo ""
    print_info "No saved Flux installation mode was found."
    echo "1. GitHub bootstrap (recommended; Git is the source of truth)"
    echo "2. Direct cluster installation"
    read -r -p "Choose installation mode: " flux_mode_choice || return 1
    case "$flux_mode_choice" in
        1) FLUX_BOOTSTRAP_MODE=github ;;
        2) FLUX_BOOTSTRAP_MODE=direct ;;
        *) print_error "Invalid Flux installation mode."; return 1 ;;
    esac
}

flux_build_bootstrap_args() {
    local components_csv
    local components_extra_csv

    components_csv=$(flux_join_csv "${FLUX_COMPONENTS[@]}")
    components_extra_csv=$(flux_join_csv "${FLUX_COMPONENTS_EXTRA[@]}")
    FLUX_BOOTSTRAP_ARGS=(bootstrap github
        --owner "$FLUX_GITHUB_OWNER"
        --repository "$FLUX_GITHUB_REPOSITORY"
        --branch "$FLUX_GITHUB_BRANCH"
        --path "$FLUX_GITHUB_PATH"
        --token-auth
        --components "$components_csv")
    [ -n "$components_extra_csv" ] && FLUX_BOOTSTRAP_ARGS+=(--components-extra "$components_extra_csv")
    [ "$FLUX_GITHUB_PERSONAL" = "y" ] && FLUX_BOOTSTRAP_ARGS+=(--personal)
    [ -n "${FLUX_TARGET_VERSION:-}" ] && FLUX_BOOTSTRAP_ARGS+=(--version "$FLUX_TARGET_VERSION")
}

flux_build_install_args() {
    local components_csv
    local components_extra_csv

    components_csv=$(flux_join_csv "${FLUX_COMPONENTS[@]}")
    components_extra_csv=$(flux_join_csv "${FLUX_COMPONENTS_EXTRA[@]}")
    FLUX_INSTALL_ARGS=(install --components "$components_csv")
    [ -n "$components_extra_csv" ] && FLUX_INSTALL_ARGS+=(--components-extra "$components_extra_csv")
    [ -n "${FLUX_TARGET_VERSION:-}" ] && FLUX_INSTALL_ARGS+=(--version "$FLUX_TARGET_VERSION")
}

flux_print_bootstrap_summary() {
    echo -e "${YELLOW}======== Flux Configuration Summary ========${NC}"
    echo "Mode: ${FLUX_BOOTSTRAP_MODE}"
    if [ "$FLUX_BOOTSTRAP_MODE" = "github" ]; then
        echo "GitHub: ${FLUX_GITHUB_OWNER}/${FLUX_GITHUB_REPOSITORY}"
        echo "Branch: ${FLUX_GITHUB_BRANCH}"
        echo "Cluster path: ${FLUX_GITHUB_PATH}"
        echo "Personal repository: ${FLUX_GITHUB_PERSONAL}"
    fi
    echo "Controllers: $(flux_join_csv "${FLUX_COMPONENTS[@]}")"
    echo "Extra controllers: $(flux_join_csv "${FLUX_COMPONENTS_EXTRA[@]}")"
    echo "Target version: ${FLUX_TARGET_VERSION:-latest}"
    echo -e "${YELLOW}=============================================${NC}"
}

flux_migrate_cluster_resources() {
    print_warning "Flux custom resources must be migrated before a minor-version upgrade."
    print_info "This updates the live Flux resources in Kubernetes; it does not save a Git commit."
    prompt_yn confirm_flux_migrate "Run 'flux migrate' against the live cluster now? (y/n, default: y): " "y" || return 1
    [ "$confirm_flux_migrate" = "y" ] || { print_error "Flux upgrade cancelled before migration."; return 1; }

    if ! KUBECONFIG="$K0S_KUBECONFIG" flux migrate; then
        print_error "Flux resource migration failed. Controllers were not upgraded."
        return 1
    fi
    print_successful "Live Flux resources migrated."
}

flux_migrate_github_manifests() {
    local temp_dir
    local askpass_file
    local repo_dir
    local target_minor=""
    local -a migrate_args
    local confirm_git_push

    if ! command -v git >/dev/null 2>&1; then
        print_error "git is required to migrate the Flux manifests in GitHub."
        return 1
    fi

    print_info "The live cluster was migrated, but Git must also be updated so Flux does not restore deprecated APIs."
    prompt_yn migrate_git "Migrate the configured GitHub cluster manifests and push the change? (y/n, default: y): " "y" || return 1
    [ "$migrate_git" = "y" ] || {
        print_error "Git manifest migration was declined; Flux upgrade cancelled."
        return 1
    }

    temp_dir=$(mktemp -d "${TMPDIR:-/tmp}/flux-migrate.XXXXXX") || {
        print_error "Could not create a temporary directory for the Git migration."
        return 1
    }
    askpass_file="$temp_dir/git-askpass.sh"
    repo_dir="$temp_dir/repository"

    printf '%s\n' \
        '#!/bin/sh' \
        'case "$1" in' \
        '  *Username*) printf "%s\\n" "x-access-token" ;;' \
        '  *) printf "%s\\n" "$FLUX_GITHUB_TOKEN" ;;' \
        'esac' > "$askpass_file"
    chmod 0700 "$askpass_file"

    print_info "Cloning ${FLUX_GITHUB_OWNER}/${FLUX_GITHUB_REPOSITORY} temporarily..."
    if ! GIT_TERMINAL_PROMPT=0 GIT_ASKPASS="$askpass_file" \
         FLUX_GITHUB_TOKEN="$FLUX_GITHUB_TOKEN" \
         git clone --depth 1 --branch "$FLUX_GITHUB_BRANCH" \
         "https://github.com/${FLUX_GITHUB_OWNER}/${FLUX_GITHUB_REPOSITORY}.git" "$repo_dir"; then
        rm -rf "$temp_dir"
        print_error "Could not clone the configured Flux GitHub repository."
        return 1
    fi

    if [ ! -d "$repo_dir/$FLUX_GITHUB_PATH" ]; then
        rm -rf "$temp_dir"
        print_error "Configured Flux path does not exist in the repository: $FLUX_GITHUB_PATH"
        return 1
    fi

    migrate_args=(-f "$repo_dir/$FLUX_GITHUB_PATH" --yes)
    if [ -n "${FLUX_TARGET_VERSION:-}" ]; then
        target_minor=$(printf '%s' "$FLUX_TARGET_VERSION" | sed -E 's/^v?([0-9]+\.[0-9]+).*/\1/')
        if [[ "$target_minor" =~ ^[0-9]+\.[0-9]+$ ]]; then
            migrate_args+=(--version "$target_minor")
        fi
    fi

    print_info "Migrating Flux manifests under $FLUX_GITHUB_PATH..."
    if ! flux migrate "${migrate_args[@]}"; then
        rm -rf "$temp_dir"
        print_error "Flux Git manifest migration failed."
        return 1
    fi

    if git -C "$repo_dir" diff --quiet -- "$FLUX_GITHUB_PATH"; then
        print_successful "No Git manifest changes were required."
        rm -rf "$temp_dir"
        return 0
    fi

    echo ""
    print_info "Flux manifest changes to be committed:"
    git -C "$repo_dir" diff --stat -- "$FLUX_GITHUB_PATH"
    prompt_yn confirm_git_push "Commit and push these Flux manifest changes? (y/n, default: n): " "n" || {
        rm -rf "$temp_dir"
        return 1
    }
    if [ "$confirm_git_push" != "y" ]; then
        rm -rf "$temp_dir"
        print_error "Git manifest changes were not pushed; Flux upgrade cancelled."
        return 1
    fi

    if ! git -C "$repo_dir" add -- "$FLUX_GITHUB_PATH" || \
       ! git -C "$repo_dir" -c user.name="Flux Migration" \
           -c user.email="flux-migration@localhost" \
           commit -m "Migrate Flux resources for ${FLUX_TARGET_VERSION:-latest}" || \
       ! GIT_TERMINAL_PROMPT=0 GIT_ASKPASS="$askpass_file" \
           FLUX_GITHUB_TOKEN="$FLUX_GITHUB_TOKEN" \
           git -C "$repo_dir" push origin "$FLUX_GITHUB_BRANCH"; then
        rm -rf "$temp_dir"
        print_error "Could not commit and push the migrated Flux manifests."
        return 1
    fi

    rm -rf "$temp_dir"
    print_successful "Flux Git manifests migrated and pushed."
}

flux_verify_installation() {
    print_info "Checking Flux controllers after the operation..."
    if ! KUBECONFIG="$K0S_KUBECONFIG" flux check; then
        print_error "Flux verification failed."
        KUBECONFIG="$K0S_KUBECONFIG" kubectl get pods -n flux-system 2>/dev/null || true
        return 1
    fi

    if [ "$FLUX_BOOTSTRAP_MODE" = "github" ] && \
       KUBECONFIG="$K0S_KUBECONFIG" kubectl get kustomization.kustomize.toolkit.fluxcd.io flux-system -n flux-system &>/dev/null; then
        print_info "Reconciling flux-system..."
        if ! KUBECONFIG="$K0S_KUBECONFIG" flux reconcile ks flux-system --with-source; then
            print_error "flux-system reconciliation failed."
            return 1
        fi
    fi

    KUBECONFIG="$K0S_KUBECONFIG" kubectl get deployments -n flux-system 2>/dev/null || true
    print_successful "FluxCD operation verified."
}

setup_fluxcd() {
    while true; do
        echo -e "${YELLOW}======== FluxCD Setup ========${NC}"
        echo "1. New / Reconfigure GitHub Bootstrap"
        echo "2. Upgrade Existing FluxCD"
        echo "3. Show Saved Bootstrap Settings"
        echo "4. Back to FluxCD Menu"
        echo -e "${YELLOW}===============================${NC}"
        read -r -p "Enter your choice: " setup_choice || return

        case "$setup_choice" in
            1) bootstrap_fluxcd ;;
            2) upgrade_fluxcd ;;
            3) show_flux_bootstrap_settings ;;
            4) return ;;
            *) print_error "Invalid option." ;;
        esac
    done
}

bootstrap_fluxcd() {
    print_info "Interactive FluxCD GitHub bootstrap..."
    ensure_config || return 1
    flux_load_bootstrap_settings
    prompt_flux_github_settings || return 1
    flux_print_bootstrap_summary
    prompt_yn confirm_flux_bootstrap "Apply these Flux settings and update GitHub? (y/n, default: n): " "n" || return 1
    [ "$confirm_flux_bootstrap" = "y" ] || { print_info "Flux bootstrap cancelled."; return 0; }

    flux_save_bootstrap_settings
    install_or_update_flux_cli || return 1

    if ! KUBECONFIG="$K0S_KUBECONFIG" flux check --pre; then
        print_error "Flux preflight check failed. Bootstrap was not started."
        return 1
    fi

    flux_build_bootstrap_args
    print_info "Running GitHub bootstrap with the selected controllers..."
    if ! GITHUB_TOKEN="$FLUX_GITHUB_TOKEN" KUBECONFIG="$K0S_KUBECONFIG" flux "${FLUX_BOOTSTRAP_ARGS[@]}"; then
        print_error "Flux GitHub bootstrap failed."
        return 1
    fi

    flux_verify_installation
}

upgrade_fluxcd() {
    print_info "Interactive FluxCD upgrade..."
    ensure_config || return 1
    flux_load_bootstrap_settings
    prompt_flux_install_mode || return 1

    read -r -p "Target FluxCD version (leave empty for latest): " FLUX_TARGET_VERSION || return 1
    FLUX_TARGET_VERSION=$(trim_value "$FLUX_TARGET_VERSION")

    if [ "$FLUX_BOOTSTRAP_MODE" = "github" ]; then
        prompt_flux_github_settings || return 1
    else
        prompt_flux_component_selection || return 1
    fi

    flux_print_bootstrap_summary
    prompt_yn confirm_flux_upgrade "Continue with this FluxCD upgrade? (y/n, default: n): " "n" || return 1
    [ "$confirm_flux_upgrade" = "y" ] || { print_info "FluxCD upgrade cancelled."; return 0; }

    flux_save_bootstrap_settings
    install_or_update_flux_cli || return 1

    if ! KUBECONFIG="$K0S_KUBECONFIG" flux check --pre; then
        print_error "Flux preflight check failed. Upgrade was not started."
        return 1
    fi

    flux_migrate_cluster_resources || return 1

    if [ "$FLUX_BOOTSTRAP_MODE" = "github" ]; then
        flux_migrate_github_manifests || return 1
    fi

    if [ "$FLUX_BOOTSTRAP_MODE" = "github" ]; then
        flux_build_bootstrap_args
        print_info "Re-running the saved GitHub bootstrap configuration..."
        if ! GITHUB_TOKEN="$FLUX_GITHUB_TOKEN" KUBECONFIG="$K0S_KUBECONFIG" flux "${FLUX_BOOTSTRAP_ARGS[@]}"; then
            print_error "Flux GitHub bootstrap upgrade failed."
            return 1
        fi
    else
        flux_build_install_args
        print_info "Upgrading the direct Flux installation..."
        if ! KUBECONFIG="$K0S_KUBECONFIG" flux "${FLUX_INSTALL_ARGS[@]}"; then
            print_error "Direct Flux installation upgrade failed."
            return 1
        fi
    fi

    flux_verify_installation
}

manage_cilium() {
    echo -e "${YELLOW}======== Cilium Management ========${NC}"
    echo "1. Install Cilium (cluster)"
    echo "2. Upgrade Cilium (cluster)"
    echo "3. Install Cilium CLI (local only)"
    echo "4. Check Cilium Version"
    echo "5. Check Cilium Status"
    echo "6. Back to Main Menu"
    echo -e "${YELLOW}==================================${NC}"
    read -p "Enter your choice: " cilium_choice

    case $cilium_choice in
        1) ensure_config && install_cilium ;;
        2) upgrade_cilium ;;
        3) install_cilium_cli ;;
        4) check_cilium_version ;;
        5)
            if command -v cilium &>/dev/null; then
                cilium status --kubeconfig "$K0S_KUBECONFIG"
            else
                print_error "Cilium CLI not installed. Choose option 3 first."
            fi
            ;;
        6) return ;;
        *) print_error "Invalid option. Returning to main menu." ;;
    esac
}

manage_flux() {
    while true; do
        echo -e "${YELLOW}======== FluxCD Management ========${NC}"
        echo "1. Setup / Bootstrap / Upgrade FluxCD"
        echo "2. Check FluxCD Status"
        echo "3. Add FluxCD Controller"
        echo "4. Remove FluxCD Controller"
        echo "5. Back to Main Menu"
        echo -e "${YELLOW}===================================${NC}"
        read -r -p "Enter your choice: " flux_choice || return

        case $flux_choice in
            1) setup_fluxcd ;;
            2) check_fluxcd_status ;;
            3) add_fluxcd_controller ;;
            4) remove_fluxcd_controller ;;
            5) return ;;
            *) print_error "Invalid option." ;;
        esac
    done
}

# -----------------------------------------------------------------------------
# Longhorn backup inventory and selective restore
# -----------------------------------------------------------------------------
longhorn_kubectl() {
    if command -v kubectl &>/dev/null; then
        KUBECONFIG="$K0S_KUBECONFIG" kubectl "$@"
    elif command -v k0s &>/dev/null; then
        k0s kubectl "$@"
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

# BackupVolume exposes only the latest backup. Backup CRs retain the
# individual point-in-time backups used for exact restore selection.
longhorn_backup_inventory_lines() {
    longhorn_kubectl get backups.longhorn.io -n longhorn-system \
        -o go-template='{{range .items}}{{.metadata.name}}{{"\t"}}{{.status.url}}{{"\t"}}{{.status.volumeSize}}{{"\t"}}{{.metadata.creationTimestamp}}{{"\t"}}{{.status.state}}{{"\n"}}{{end}}'
}

longhorn_backup_url_volume() {
    local backup_url="$1"
    printf '%s\n' "$backup_url" | sed -n 's/.*[?&]volume=\([^&]*\).*/\1/p'
}

longhorn_select_backup_for_volume() {
    local source_volume="$1"
    local preferred_backup="${2:-}"
    local candidates=() candidate
    local backup_name backup_url backup_size backup_created backup_state backup_volume
    local count selection index=1 default_index=1

    while IFS=$'\t' read -r backup_name backup_url backup_size backup_created backup_state; do
        [ -z "$backup_name" ] || [ -z "$backup_url" ] && continue
        backup_volume=$(longhorn_backup_url_volume "$backup_url")
        [ "$backup_volume" = "$source_volume" ] || continue
        candidates+=("$backup_name"$'\t'"$backup_url"$'\t'"$backup_size"$'\t'"$backup_created"$'\t'"$backup_state")
    done < <(longhorn_backup_inventory_lines 2>/dev/null)

    count=${#candidates[@]}
    if [ "$count" -eq 0 ]; then
        print_error "No retained backups were found for source volume: $source_volume"
        return 1
    fi
    if [ "$count" -gt 1 ]; then
        mapfile -t candidates < <(printf '%s\n' "${candidates[@]}" | sort -t $'\t' -k4,4r)
    fi

    print_info "Backups available for source volume: $source_volume"
    printf '%-4s %-30s %-24s %-12s %s\n' "NO" "BACKUP" "CREATED" "SIZE" "STATE"
    for candidate in "${candidates[@]}"; do
        IFS=$'\t' read -r backup_name backup_url backup_size backup_created backup_state <<< "$candidate"
        printf '%-4s %-30s %-24s %-12s %s\n' \
            "$index" "$backup_name" "$(longhorn_display_value "$backup_created")" \
            "$(longhorn_display_value "$backup_size")" "$(longhorn_display_value "$backup_state")"
        if [ -n "$preferred_backup" ] && [ "$backup_name" = "$preferred_backup" ]; then
            default_index=$index
        fi
        index=$((index + 1))
    done

    read -p "Select exact backup number (default: $default_index): " selection
    selection=${selection:-$default_index}
    if ! printf '%s' "$selection" | grep -Eq '^[0-9]+$' || \
        [ "$selection" -lt 1 ] || [ "$selection" -gt "${#candidates[@]}" ]; then
        print_error "Invalid backup selection."
        return 1
    fi

    candidate="${candidates[$((selection - 1))]}"
    IFS=$'\t' read -r LONGHORN_SELECTED_BACKUP \
        LONGHORN_SELECTED_BACKUP_URL \
        LONGHORN_SELECTED_BACKUP_SIZE \
        LONGHORN_SELECTED_BACKUP_AT \
        LONGHORN_SELECTED_BACKUP_STATE <<< "$candidate"
    LONGHORN_SELECTED_BACKUP_VOLUME="$source_volume"
    print_successful "Selected backup: $LONGHORN_SELECTED_BACKUP"
}

longhorn_backup_sources_for_pvc() {
    local target_namespace="$1"
    local target_pvc="$2"
    local line backup_volume source_volume last_backup last_backup_at size_bytes storage_class kstatus access_mode
    local namespace pvc

    while IFS=$'\t' read -r backup_volume source_volume last_backup last_backup_at size_bytes storage_class kstatus access_mode; do
        [ -z "$source_volume" ] && continue
        namespace=$(longhorn_json_field "$kstatus" "namespace")
        pvc=$(longhorn_json_field "$kstatus" "pvcName")
        if [ "$namespace" = "$target_namespace" ] && [ "$pvc" = "$target_pvc" ]; then
            printf '%s\t%s\t%s\t%s\t%s\n' "$source_volume" "$last_backup" "$last_backup_at" "$size_bytes" "${access_mode:-rwo}"
        fi
    done < <(longhorn_backup_volume_lines 2>/dev/null)
}

longhorn_select_latest_backup_for_volume() {
    local source_volume="$1"
    local preferred_backup="$2"
    local backup_name backup_url backup_size backup_created backup_state backup_volume

    LONGHORN_SELECTED_BACKUP=""
    LONGHORN_SELECTED_BACKUP_URL=""
    LONGHORN_SELECTED_BACKUP_SIZE=""
    LONGHORN_SELECTED_BACKUP_AT=""
    LONGHORN_SELECTED_BACKUP_STATE=""
    LONGHORN_SELECTED_BACKUP_VOLUME="$source_volume"

    [ -n "$preferred_backup" ] || return 1
    while IFS=$'\t' read -r backup_name backup_url backup_size backup_created backup_state; do
        [ -n "$backup_name" ] || continue
        backup_volume=$(longhorn_backup_url_volume "$backup_url")
        if [ "$backup_volume" = "$source_volume" ] && [ "$backup_name" = "$preferred_backup" ]; then
            LONGHORN_SELECTED_BACKUP="$backup_name"
            LONGHORN_SELECTED_BACKUP_URL="$backup_url"
            LONGHORN_SELECTED_BACKUP_SIZE="$backup_size"
            LONGHORN_SELECTED_BACKUP_AT="$backup_created"
            LONGHORN_SELECTED_BACKUP_STATE="$backup_state"
            return 0
        fi
    done < <(longhorn_backup_inventory_lines 2>/dev/null)

    return 1
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

longhorn_check_old_backup_target() {
    longhorn_require_cluster || return 1

    if ! longhorn_kubectl get backuptargets.longhorn.io -n longhorn-system &>/dev/null; then
        print_error "No Longhorn backup target is configured."
        print_info "Configure the old cluster's backup target first, then run the inventory sync."
        return 1
    fi

    print_info "Old backup target status:"
    longhorn_kubectl get backuptargets.longhorn.io -n longhorn-system \
        -o custom-columns=NAME:.metadata.name,URL:.spec.backupTarget,AVAILABLE:.status.available,STATE:.status.state
    echo ""

    local backup_volume_count backup_count
    backup_volume_count=$(longhorn_kubectl get backupvolumes.longhorn.io -n longhorn-system --no-headers 2>/dev/null | wc -l | tr -d ' ')
    backup_count=$(longhorn_kubectl get backups.longhorn.io -n longhorn-system --no-headers 2>/dev/null | wc -l | tr -d ' ')

    echo "Imported old backup volumes: ${backup_volume_count:-0}"
    echo "Imported old backups:        ${backup_count:-0}"
    if [ "${backup_volume_count:-0}" -gt 0 ] && [ "${backup_count:-0}" -gt 0 ]; then
        print_successful "Old backup inventory is available for restore."
    else
        print_warning "The target is configured, but the old backup inventory is not available yet."
        print_info "Use the Longhorn UI's sync action or wait for Longhorn to scan the backup target."
        return 1
    fi
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

longhorn_pvc_workloads() {
    local namespace="$1"
    local pvc_name="$2"
    local kind resource resource_name claims template_claim

    for kind in deployment statefulset daemonset; do
        while IFS= read -r resource; do
            [ -z "$resource" ] && continue
            resource_name="${resource#*/}"
            claims=$(longhorn_kubectl get "$resource" -n "$namespace" \
                -o jsonpath='{range .spec.template.spec.volumes[*]}{.persistentVolumeClaim.claimName}{"\n"}{end}' \
                2>/dev/null)
            if printf '%s\n' "$claims" | grep -Fxq -- "$pvc_name"; then
                printf '%s/%s\n' "$kind" "$resource_name"
                continue
            fi
            if [ "$kind" = "statefulset" ]; then
                while IFS= read -r template_claim; do
                    [ -z "$template_claim" ] && continue
                    case "$pvc_name" in
                        "${template_claim}-${resource_name}-"*)
                            printf '%s/%s\n' "$kind" "$resource_name"
                            break
                            ;;
                    esac
                done < <(longhorn_kubectl get "$resource" -n "$namespace" \
                    -o jsonpath='{range .spec.volumeClaimTemplates[*]}{.metadata.name}{"\n"}{end}' \
                    2>/dev/null)
            fi
        done < <(longhorn_kubectl get "$kind" -n "$namespace" -o name 2>/dev/null)
    done
}

longhorn_workload_pvcs() {
    local namespace="$1"
    local workload="$2"
    local kind="${workload%%/*}" claims template_claim pvc_name
    local selected_claims=()

    claims=$(longhorn_kubectl get "$workload" -n "$namespace" \
        -o jsonpath='{range .spec.template.spec.volumes[*]}{.persistentVolumeClaim.claimName}{"\n"}{end}' \
        2>/dev/null)
    while IFS= read -r pvc_name; do
        [ -z "$pvc_name" ] && continue
        if ! printf '%s\n' "${selected_claims[@]}" | grep -Fxq -- "$pvc_name"; then
            selected_claims+=("$pvc_name")
        fi
    done <<< "$claims"

    if [ "$kind" = "statefulset" ]; then
        while IFS= read -r template_claim; do
            [ -z "$template_claim" ] && continue
            while IFS= read -r pvc_name; do
                pvc_name="${pvc_name#*/}"
                case "$pvc_name" in
                    "${template_claim}-${workload#*/}-"*)
                        if ! printf '%s\n' "${selected_claims[@]}" | grep -Fxq -- "$pvc_name"; then
                            selected_claims+=("$pvc_name")
                        fi
                        ;;
                esac
            done < <(longhorn_kubectl get pvc -n "$namespace" -o name 2>/dev/null)
        done < <(longhorn_kubectl get "$workload" -n "$namespace" \
            -o jsonpath='{range .spec.volumeClaimTemplates[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null)
    fi
    printf '%s\n' "${selected_claims[@]}"
}

longhorn_namespace_pvc_names() {
    local namespace="$1"

    longhorn_kubectl get pvc -n "$namespace" \
        -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null
}

longhorn_find_flux_application() {
    local namespace="$1"
    local resource_name resource_namespace resource_target

    LONGHORN_FOUND_FLUX_KIND=""
    LONGHORN_FOUND_FLUX_NAME=""
    LONGHORN_FOUND_FLUX_NAMESPACE=""
    LONGHORN_FOUND_FLUX_SOURCE=""

    while IFS='|' read -r resource_name resource_namespace resource_target; do
        [ -n "$resource_name" ] || continue
        if [ "$resource_target" = "$namespace" ] || \
            { [ "$resource_target" = "-" ] && [ "$resource_name" = "$namespace" ]; }; then
            LONGHORN_FOUND_FLUX_KIND="kustomization"
            LONGHORN_FOUND_FLUX_NAME="$resource_name"
            LONGHORN_FOUND_FLUX_NAMESPACE="$resource_namespace"
            LONGHORN_FOUND_FLUX_SOURCE="kustomization/${resource_namespace}/${resource_name}"
            return 0
        fi
    done < <(longhorn_kubectl get kustomizations.kustomize.toolkit.fluxcd.io -A \
        -o 'go-template={{range .items}}{{.metadata.name}}|{{.metadata.namespace}}|{{if .spec.targetNamespace}}{{.spec.targetNamespace}}{{else}}-{{end}}{{"\n"}}{{end}}' \
        2>/dev/null)

    while IFS='|' read -r resource_name resource_namespace resource_target; do
        [ -n "$resource_name" ] || continue
        if [ "$resource_target" = "$namespace" ] || \
            { [ "$resource_target" = "-" ] && [ "$resource_namespace" = "$namespace" ]; }; then
            LONGHORN_FOUND_FLUX_KIND="helmrelease"
            LONGHORN_FOUND_FLUX_NAME="$resource_name"
            LONGHORN_FOUND_FLUX_NAMESPACE="$resource_namespace"
            LONGHORN_FOUND_FLUX_SOURCE="helmrelease/${resource_namespace}/${resource_name}"
            return 0
        fi
    done < <(longhorn_kubectl get helmreleases.helm.toolkit.fluxcd.io -A \
        -o 'go-template={{range .items}}{{.metadata.name}}|{{.metadata.namespace}}|{{if .spec.targetNamespace}}{{.spec.targetNamespace}}{{else}}-{{end}}{{"\n"}}{{end}}' \
        2>/dev/null)

    return 1
}

longhorn_discover_applications() {
    LONGHORN_APPLICATION_NAMESPACES=()
    LONGHORN_APPLICATION_NAMES=()
    LONGHORN_APPLICATION_WORKLOADS=()
    LONGHORN_APPLICATION_PVCS=()
    LONGHORN_APPLICATION_FLUX_SOURCES=()

    local namespace workload_lines pvc_names workloads_display pvc_display app_name flux_source
    while IFS= read -r namespace; do
        [ -n "$namespace" ] || continue
        case "$namespace" in
            default|kube-node-lease|kube-public|kube-system|flux-system|longhorn-system|nfs-csi)
                continue
                ;;
        esac

        workload_lines=$(longhorn_list_workloads_with_pvcs "$namespace")
        [ -n "$workload_lines" ] || continue
        pvc_names=$(longhorn_namespace_pvc_names "$namespace")
        [ -n "$pvc_names" ] || continue

        workloads_display=$(printf '%s\n' "$workload_lines" | awk -F '\t' \
            'BEGIN { separator = "" } { printf "%s%s", separator, $1; separator = ", " }')
        pvc_display=$(printf '%s\n' "$pvc_names" | awk \
            'BEGIN { separator = "" } { printf "%s%s", separator, $0; separator = ", " }')

        longhorn_find_flux_application "$namespace" || true
        app_name="${LONGHORN_FOUND_FLUX_NAME:-$namespace}"
        flux_source="${LONGHORN_FOUND_FLUX_SOURCE:-namespace/${namespace}}"

        LONGHORN_APPLICATION_NAMESPACES+=("$namespace")
        LONGHORN_APPLICATION_NAMES+=("$app_name")
        LONGHORN_APPLICATION_WORKLOADS+=("$workloads_display")
        LONGHORN_APPLICATION_PVCS+=("$pvc_display")
        LONGHORN_APPLICATION_FLUX_SOURCES+=("$flux_source")
    done < <(longhorn_kubectl get namespaces -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null)
}

longhorn_collect_application_workloads() {
    local namespace="$1"
    shift

    LONGHORN_RESTORE_WORKLOADS=()
    LONGHORN_RESTORE_WORKLOAD_REPLICAS=()
    LONGHORN_RESTORE_WORKLOAD_NAMESPACE="$namespace"
    LONGHORN_RESTORE_WORKLOADS_SCALED=n

    local pvc workload kind replicas known_workload already_present
    for pvc in "$@"; do
        while IFS= read -r workload; do
            [ -n "$workload" ] || continue
            already_present=n
            for known_workload in "${LONGHORN_RESTORE_WORKLOADS[@]}"; do
                if [ "$known_workload" = "$workload" ]; then
                    already_present=y
                    break
                fi
            done
            [ "$already_present" = "n" ] || continue

            kind="${workload%%/*}"
            if [ "$kind" = "deployment" ] || [ "$kind" = "statefulset" ]; then
                replicas=$(longhorn_kubectl get "$workload" -n "$namespace" \
                    -o jsonpath='{.spec.replicas}' 2>/dev/null)
                LONGHORN_RESTORE_WORKLOAD_REPLICAS+=("${replicas:-1}")
            else
                LONGHORN_RESTORE_WORKLOAD_REPLICAS+=("-")
            fi
            LONGHORN_RESTORE_WORKLOADS+=("$workload")
        done < <(longhorn_pvc_workloads "$namespace" "$pvc")
    done
}

longhorn_list_workloads_with_pvcs() {
    local namespace="$1" kind resource workload claims
    for kind in deployment statefulset daemonset; do
        while IFS= read -r resource; do
            [ -z "$resource" ] && continue
            workload="${resource#*/}"
            claims=$(longhorn_workload_pvcs "$namespace" "$resource" | tr '\n' ',' | sed 's/,$//')
            [ -n "$claims" ] && printf '%s/%s\t%s\n' "$kind" "$workload" "$claims"
        done < <(longhorn_kubectl get "$kind" -n "$namespace" -o name 2>/dev/null)
    done
}

longhorn_pvc_pods() {
    local namespace="$1"
    local pvc_name="$2"
    local pod claims

    while IFS= read -r pod; do
        [ -z "$pod" ] && continue
        claims=$(longhorn_kubectl get "$pod" -n "$namespace" \
            -o jsonpath='{range .spec.volumes[*]}{.persistentVolumeClaim.claimName}{"\n"}{end}' \
            2>/dev/null)
        if printf '%s\n' "$claims" | grep -Fxq -- "$pvc_name"; then
            printf '%s\n' "${pod#*/}"
        fi
    done < <(longhorn_kubectl get pods -n "$namespace" -o name 2>/dev/null)
}

longhorn_wait_for_pvc_pods_gone() {
    local namespace="$1"
    local pvc_name="$2"
    local timeout_seconds="${3:-180}"
    local deadline=$((SECONDS + timeout_seconds))

    while [ "$SECONDS" -lt "$deadline" ]; do
        local pods=()
        mapfile -t pods < <(longhorn_pvc_pods "$namespace" "$pvc_name")
        if [ "${#pods[@]}" -eq 0 ]; then
            print_successful "No pods are using PVC ${namespace}/${pvc_name}."
            return 0
        fi
        print_info "Waiting for PVC users to stop: ${pods[*]}"
        sleep 5
    done

    print_error "Pods are still using PVC ${namespace}/${pvc_name}."
    return 1
}

longhorn_wait_for_volume_detached() {
    local volume_name="$1"
    local timeout_seconds="${2:-180}"
    local deadline=$((SECONDS + timeout_seconds))

    while [ "$SECONDS" -lt "$deadline" ]; do
        local state
        state=$(longhorn_kubectl get volumes.longhorn.io "$volume_name" -n longhorn-system \
            -o jsonpath='{.status.state}' 2>/dev/null)
        if [ "$state" = "detached" ]; then
            print_successful "Longhorn volume ${volume_name} is detached."
            return 0
        fi
        if [ -z "$state" ]; then
            print_error "Longhorn volume ${volume_name} disappeared while waiting for detach."
            return 1
        fi
        print_info "Waiting for Longhorn volume ${volume_name} to detach (state: ${state})..."
        sleep 5
    done

    print_error "Timed out waiting for Longhorn volume ${volume_name} to detach."
    return 1
}

longhorn_wait_for_restore_detached() {
    local volume_name="$1"
    local timeout_seconds="${2:-1800}"
    local deadline=$((SECONDS + timeout_seconds))

    print_info "Waiting for restored volume ${volume_name} to finish..."
    while [ "$SECONDS" -lt "$deadline" ]; do
        local restore_required state robustness
        restore_required=$(longhorn_kubectl get volumes.longhorn.io "$volume_name" -n longhorn-system \
            -o jsonpath='{.status.restoreRequired}' 2>/dev/null)
        state=$(longhorn_kubectl get volumes.longhorn.io "$volume_name" -n longhorn-system \
            -o jsonpath='{.status.state}' 2>/dev/null)
        robustness=$(longhorn_kubectl get volumes.longhorn.io "$volume_name" -n longhorn-system \
            -o jsonpath='{.status.robustness}' 2>/dev/null)

        printf '  volume=%s state=%s robustness=%s restoreRequired=%s\n' \
            "$volume_name" \
            "$(longhorn_display_value "$state")" \
            "$(longhorn_display_value "$robustness")" \
            "$(longhorn_display_value "$restore_required")"

        if [ "$restore_required" = "false" ] && [ "$state" = "detached" ]; then
            print_successful "Restore completed and volume is detached."
            return 0
        fi

        if [ -z "$restore_required" ] && [ -z "$state" ]; then
            print_error "Restored Longhorn volume ${volume_name} could not be read."
            return 1
        fi
        sleep 10
    done

    print_error "Timed out waiting for restored volume ${volume_name}."
    return 1
}

longhorn_suspend_flux_resource() {
    local kind="$1"
    local name="$2"
    local namespace="$3"
    local suspended

    LONGHORN_FLUX_GUARDED_KINDS+=("$kind")
    LONGHORN_FLUX_GUARDED_NAMES+=("$name")
    LONGHORN_FLUX_GUARDED_NAMESPACES+=("$namespace")

    suspended=$(longhorn_kubectl get "$kind" "$name" -n "$namespace" -o jsonpath='{.spec.suspend}' 2>/dev/null)
    if [ "$suspended" = "true" ]; then
        print_successful "Flux ${kind} ${namespace}/${name} is already suspended."
        return 0
    fi

    print_info "Suspending Flux ${kind} ${namespace}/${name}..."
    if ! longhorn_kubectl patch "$kind" "$name" -n "$namespace" \
        --type merge -p '{"spec":{"suspend":true}}'; then
        print_error "Could not suspend Flux ${kind} ${namespace}/${name}."
        return 1
    fi
    suspended=$(longhorn_kubectl get "$kind" "$name" -n "$namespace" -o jsonpath='{.spec.suspend}' 2>/dev/null)
    if [ "$suspended" != "true" ]; then
        print_error "Flux ${kind} ${namespace}/${name} did not remain suspended."
        return 1
    fi

    LONGHORN_FLUX_CHANGED_KINDS+=("$kind")
    LONGHORN_FLUX_CHANGED_NAMES+=("$name")
    LONGHORN_FLUX_CHANGED_NAMESPACES+=("$namespace")
    print_successful "Flux ${kind} ${namespace}/${name} suspended."
}

longhorn_validate_flux_suspended() {
    local index suspended
    for ((index = 0; index < ${#LONGHORN_FLUX_GUARDED_NAMES[@]}; index++)); do
        suspended=$(longhorn_kubectl get "${LONGHORN_FLUX_GUARDED_KINDS[$index]}" \
            "${LONGHORN_FLUX_GUARDED_NAMES[$index]}" \
            -n "${LONGHORN_FLUX_GUARDED_NAMESPACES[$index]}" \
            -o jsonpath='{.spec.suspend}' 2>/dev/null)
        if [ "$suspended" != "true" ]; then
            print_error "Flux ${LONGHORN_FLUX_GUARDED_KINDS[$index]} ${LONGHORN_FLUX_GUARDED_NAMESPACES[$index]}/${LONGHORN_FLUX_GUARDED_NAMES[$index]} is no longer suspended."
            return 1
        fi
    done
    return 0
}

longhorn_suspend_application_flux_resources() {
    local namespace="$1"
    local line resource_name resource_namespace resource_target
    local matched=0

    while IFS='|' read -r resource_name resource_namespace resource_target; do
        [ -n "$resource_name" ] || continue
        if [ "$resource_target" = "$namespace" ] || \
            { [ "$resource_target" = "-" ] && [ "$resource_name" = "$namespace" ]; }; then
            longhorn_suspend_flux_resource kustomization "$resource_name" "$resource_namespace" || return 1
            matched=1
        fi
    done < <(longhorn_kubectl get kustomizations.kustomize.toolkit.fluxcd.io -A \
        -o 'go-template={{range .items}}{{.metadata.name}}|{{.metadata.namespace}}|{{if .spec.targetNamespace}}{{.spec.targetNamespace}}{{else}}-{{end}}{{"\n"}}{{end}}' \
        2>/dev/null)

    while IFS='|' read -r resource_name resource_namespace resource_target; do
        [ -n "$resource_name" ] || continue
        if [ "$resource_target" = "$namespace" ] || \
            { [ "$resource_target" = "-" ] && [ "$resource_namespace" = "$namespace" ]; }; then
            longhorn_suspend_flux_resource helmrelease "$resource_name" "$resource_namespace" || return 1
            matched=1
        fi
    done < <(longhorn_kubectl get helmreleases.helm.toolkit.fluxcd.io -A \
        -o 'go-template={{range .items}}{{.metadata.name}}|{{.metadata.namespace}}|{{if .spec.targetNamespace}}{{.spec.targetNamespace}}{{else}}-{{end}}{{"\n"}}{{end}}' \
        2>/dev/null)

    if [ "$matched" -eq 0 ]; then
        print_warning "No Flux Kustomization or HelmRelease was matched for namespace ${namespace}."
        prompt_yn flux_confirm \
            "Confirm no Flux resource manages this application and continue? (y/n, default: n): " \
            "n" || return 1
        [ "$flux_confirm" = "y" ] || {
            print_error "Restore cancelled because Flux ownership was not confirmed."
            return 1
        }
    fi

    longhorn_validate_flux_suspended
}

longhorn_resume_flux_resources() {
    local index suspended result=0
    for ((index = ${#LONGHORN_FLUX_CHANGED_NAMES[@]} - 1; index >= 0; index--)); do
        print_info "Resuming Flux ${LONGHORN_FLUX_CHANGED_KINDS[$index]} ${LONGHORN_FLUX_CHANGED_NAMESPACES[$index]}/${LONGHORN_FLUX_CHANGED_NAMES[$index]}..."
        if ! longhorn_kubectl patch "${LONGHORN_FLUX_CHANGED_KINDS[$index]}" \
            "${LONGHORN_FLUX_CHANGED_NAMES[$index]}" \
            -n "${LONGHORN_FLUX_CHANGED_NAMESPACES[$index]}" \
            --type merge -p '{"spec":{"suspend":false}}'; then
            print_error "Could not resume Flux resource."
            result=1
            continue
        fi
        suspended=$(longhorn_kubectl get "${LONGHORN_FLUX_CHANGED_KINDS[$index]}" \
            "${LONGHORN_FLUX_CHANGED_NAMES[$index]}" \
            -n "${LONGHORN_FLUX_CHANGED_NAMESPACES[$index]}" \
            -o jsonpath='{.spec.suspend}' 2>/dev/null)
        if [ "$suspended" = "true" ]; then
            print_error "Flux resource is still suspended."
            result=1
        else
            print_successful "Flux resource resumed."
        fi
    done
    return "$result"
}

longhorn_wait_for_flux_ready() {
    local index result=0
    for ((index = 0; index < ${#LONGHORN_FLUX_CHANGED_NAMES[@]}; index++)); do
        print_info "Waiting for Flux ${LONGHORN_FLUX_CHANGED_KINDS[$index]} ${LONGHORN_FLUX_CHANGED_NAMESPACES[$index]}/${LONGHORN_FLUX_CHANGED_NAMES[$index]} to become Ready..."
        if longhorn_kubectl wait "${LONGHORN_FLUX_CHANGED_KINDS[$index]}" \
            "${LONGHORN_FLUX_CHANGED_NAMES[$index]}" \
            -n "${LONGHORN_FLUX_CHANGED_NAMESPACES[$index]}" \
            --for=condition=Ready --timeout=180s; then
            print_successful "Flux resource is Ready."
        else
            print_error "Flux resource did not become Ready within 180 seconds."
            result=1
        fi
    done
    return "$result"
}

longhorn_restore_workloads() {
    local index workload kind replicas result=0
    if [ "${LONGHORN_RESTORE_WORKLOADS_SCALED:-n}" != "y" ]; then
        return 0
    fi

    for ((index = 0; index < ${#LONGHORN_RESTORE_WORKLOADS[@]}; index++)); do
        workload="${LONGHORN_RESTORE_WORKLOADS[$index]}"
        kind="${workload%%/*}"
        replicas="${LONGHORN_RESTORE_WORKLOAD_REPLICAS[$index]}"
        if [ "$kind" = "deployment" ] || [ "$kind" = "statefulset" ]; then
            if [ "$replicas" != "-" ] && [ "$replicas" -gt 0 ]; then
                if longhorn_kubectl scale "$workload" -n "$LONGHORN_RESTORE_WORKLOAD_NAMESPACE" --replicas="$replicas"; then
                    print_successful "Restored ${workload} replica count to ${replicas}."
                else
                    print_error "Could not restore replica count for ${workload}."
                    result=1
                fi
            fi
        fi
    done
    return "$result"
}

longhorn_validate_flux_pause() {
    local namespace="$1"
    local pvc_name="$2"
    local resource_label="${3:-PVC}"
    local kustomization_name kustomization_namespace helmrelease_name helmrelease_namespace
    local selected_flux_resource=n
    LONGHORN_FLUX_GUARDED_KINDS=()
    LONGHORN_FLUX_GUARDED_NAMES=()
    LONGHORN_FLUX_GUARDED_NAMESPACES=()
    LONGHORN_FLUX_CHANGED_KINDS=()
    LONGHORN_FLUX_CHANGED_NAMES=()
    LONGHORN_FLUX_CHANGED_NAMESPACES=()

    local has_kustomizations=n has_helmreleases=n
    longhorn_kubectl get crd kustomizations.kustomize.toolkit.fluxcd.io &>/dev/null && has_kustomizations=y
    longhorn_kubectl get crd helmreleases.helm.toolkit.fluxcd.io &>/dev/null && has_helmreleases=y
    if [ "$has_kustomizations" = "n" ] && [ "$has_helmreleases" = "n" ]; then
        print_info "Flux Kustomization and HelmRelease CRDs not detected."
        return 0
    fi

    print_info "Flux resources currently installed:"
    if [ "$has_kustomizations" = "y" ]; then
        longhorn_kubectl get kustomizations.kustomize.toolkit.fluxcd.io -A \
            -o 'custom-columns=KIND:.kind,NAMESPACE:.metadata.namespace,NAME:.metadata.name,SUSPENDED:.spec.suspend' \
            2>/dev/null || true
    fi
    if [ "$has_helmreleases" = "y" ]; then
        longhorn_kubectl get helmreleases.helm.toolkit.fluxcd.io -A \
            -o 'custom-columns=KIND:.kind,NAMESPACE:.metadata.namespace,NAME:.metadata.name,SUSPENDED:.spec.suspend' \
            2>/dev/null || true
    fi

    read -p "Flux Kustomization managing ${resource_label} ${namespace}/${pvc_name} (blank if none): " kustomization_name
    if [ -n "$kustomization_name" ]; then
        read -p "Flux Kustomization namespace (default: flux-system): " kustomization_namespace
        kustomization_namespace=${kustomization_namespace:-flux-system}
        if ! longhorn_kubectl get kustomization "$kustomization_name" -n "$kustomization_namespace" &>/dev/null; then
            print_error "Flux Kustomization ${kustomization_namespace}/${kustomization_name} was not found."
            return 1
        fi
        longhorn_suspend_flux_resource kustomization "$kustomization_name" "$kustomization_namespace" || return 1
        selected_flux_resource=y
    fi

    read -p "Flux HelmRelease managing ${resource_label} ${namespace}/${pvc_name} (blank if none): " helmrelease_name
    if [ -n "$helmrelease_name" ]; then
        read -p "Flux HelmRelease namespace (default: ${namespace}): " helmrelease_namespace
        helmrelease_namespace=${helmrelease_namespace:-$namespace}
        if ! longhorn_kubectl get helmrelease "$helmrelease_name" -n "$helmrelease_namespace" &>/dev/null; then
            print_error "Flux HelmRelease ${helmrelease_namespace}/${helmrelease_name} was not found."
            return 1
        fi
        longhorn_suspend_flux_resource helmrelease "$helmrelease_name" "$helmrelease_namespace" || return 1
        selected_flux_resource=y
    fi

    if [ "$selected_flux_resource" = "n" ]; then
        print_warning "No Flux resource was selected for ${resource_label} ${namespace}/${pvc_name}."
        prompt_yn flux_confirm "Confirm Flux does not manage this app/PVC? (y/n): " "n" || return 1
        [ "$flux_confirm" = "y" ] || { print_error "Restore cancelled because Flux was not suspended."; return 1; }
    fi

    longhorn_validate_flux_suspended
}

longhorn_select_backup_source_for_pvc() {
    local target_namespace="$1"
    local target_pvc="$2"
    local candidates=() all_lines=() line
    local source_volume latest_backup last_backup_at source_size storage_class kstatus access_mode
    local count selection index=1 selected

    mapfile -t candidates < <(longhorn_backup_sources_for_pvc "$target_namespace" "$target_pvc")
    count=${#candidates[@]}
    if [ "$count" -eq 0 ]; then
        while IFS=$'\t' read -r backup_volume source_volume latest_backup last_backup_at source_size storage_class kstatus access_mode; do
            [ -z "$source_volume" ] || [ -z "$latest_backup" ] && continue
            all_lines+=("$source_volume"$'\t'"$latest_backup"$'\t'"$last_backup_at"$'\t'"$source_size"$'\t'"${access_mode:-rwo}")
        done < <(longhorn_backup_volume_lines 2>/dev/null)
        candidates=("${all_lines[@]}")
        count=${#candidates[@]}
    fi
    if [ "$count" -eq 0 ]; then
        print_error "No old-cluster backup source matches $target_namespace/$target_pvc."
        return 1
    fi
    if [ "$count" -gt 1 ]; then
        print_info "Multiple old-cluster backup sources match $target_namespace/$target_pvc:"
        printf '%-4s %-36s %-28s %s\n' "NO" "SOURCE_VOLUME" "LATEST_BACKUP" "LAST_BACKUP_AT"
        for line in "${candidates[@]}"; do
            IFS=$'\t' read -r source_volume latest_backup last_backup_at source_size access_mode <<< "$line"
            printf '%-4s %-36s %-28s %s\n' "$index" "$source_volume" "$latest_backup" "$last_backup_at"
            index=$((index + 1))
        done
        read -p "Select source volume number: " selection
        if ! printf '%s' "$selection" | grep -Eq '^[0-9]+$' || [ "$selection" -lt 1 ] || [ "$selection" -gt "$count" ]; then
            print_error "Invalid source volume selection."
            return 1
        fi
        selected="${candidates[$((selection - 1))]}"
    else
        selected="${candidates[0]}"
    fi
    IFS=$'\t' read -r LONGHORN_SELECTED_SOURCE_VOLUME LONGHORN_SELECTED_LATEST_BACKUP \
        LONGHORN_SELECTED_SOURCE_BACKUP_AT LONGHORN_SELECTED_SOURCE_SIZE \
        LONGHORN_SELECTED_SOURCE_ACCESS_MODE <<< "$selected"
}

longhorn_set_pv_reclaim_policy() {
    local pv_name="$1"
    local reclaim_policy="$2"
    local current_policy

    current_policy=$(longhorn_kubectl get pv "$pv_name" \
        -o jsonpath='{.spec.persistentVolumeReclaimPolicy}' 2>/dev/null)
    if [ "$current_policy" = "$reclaim_policy" ]; then
        return 0
    fi

    print_info "Setting PV ${pv_name} reclaim policy to ${reclaim_policy}..."
    if ! longhorn_kubectl patch pv "$pv_name" --type merge \
        -p "{\"spec\":{\"persistentVolumeReclaimPolicy\":\"${reclaim_policy}\"}}"; then
        print_error "Could not set PV ${pv_name} reclaim policy to ${reclaim_policy}."
        return 1
    fi

    current_policy=$(longhorn_kubectl get pv "$pv_name" \
        -o jsonpath='{.spec.persistentVolumeReclaimPolicy}' 2>/dev/null)
    if [ "$current_policy" != "$reclaim_policy" ]; then
        print_error "PV ${pv_name} reclaim policy is ${current_policy:-unknown}, expected ${reclaim_policy}."
        return 1
    fi
}

longhorn_validate_existing_pv_pvc_binding() {
    local namespace="$1"
    local pvc_name="$2"
    local pv_name="$3"
    local volume_handle="$4"
    local pv_phase pvc_phase bound_handle bound_pv claim_namespace claim_name

    if ! longhorn_kubectl get pv "$pv_name" &>/dev/null || \
        ! longhorn_kubectl get pvc "$pvc_name" -n "$namespace" &>/dev/null; then
        return 1
    fi

    pv_phase=$(longhorn_kubectl get pv "$pv_name" -o jsonpath='{.status.phase}' 2>/dev/null)
    pvc_phase=$(longhorn_kubectl get pvc "$pvc_name" -n "$namespace" \
        -o jsonpath='{.status.phase}' 2>/dev/null)
    bound_pv=$(longhorn_kubectl get pvc "$pvc_name" -n "$namespace" \
        -o jsonpath='{.spec.volumeName}' 2>/dev/null)
    bound_handle=$(longhorn_kubectl get pv "$pv_name" \
        -o jsonpath='{.spec.csi.volumeHandle}' 2>/dev/null)
    claim_namespace=$(longhorn_kubectl get pv "$pv_name" \
        -o jsonpath='{.spec.claimRef.namespace}' 2>/dev/null)
    claim_name=$(longhorn_kubectl get pv "$pv_name" \
        -o jsonpath='{.spec.claimRef.name}' 2>/dev/null)

    [ "$pv_phase" = "Bound" ] && [ "$pvc_phase" = "Bound" ] && \
        [ "$bound_pv" = "$pv_name" ] && [ "$bound_handle" = "$volume_handle" ] && \
        [ "$claim_namespace" = "$namespace" ] && [ "$claim_name" = "$pvc_name" ]
}

longhorn_restore_batch_volume() {
    local index="$1"
    local namespace="$LONGHORN_RESTORE_WORKLOAD_NAMESPACE"
    local pvc="${LONGHORN_BATCH_PVCS[$index]}"
    local pv="${LONGHORN_BATCH_PVS[$index]}"
    local handle="${LONGHORN_BATCH_HANDLES[$index]}"
    local backup="${LONGHORN_BATCH_BACKUPS[$index]}"
    local url="${LONGHORN_BATCH_URLS[$index]}"
    local size="${LONGHORN_BATCH_SIZES[$index]}"
    local replicas="${LONGHORN_BATCH_REPLICAS[$index]}"
    local engine="${LONGHORN_BATCH_ENGINES[$index]}"
    local access="${LONGHORN_BATCH_ACCESS_MODES[$index]}"
    local prefix state_file manifest restored_handle restored_phase
    local original_reclaim_policy

    original_reclaim_policy=$(longhorn_kubectl get pv "$pv" \
        -o jsonpath='{.spec.persistentVolumeReclaimPolicy}' 2>/dev/null)
    original_reclaim_policy=${original_reclaim_policy:-Delete}

    prefix=$(sanitize_k8s_name "$namespace-$pvc-$backup")
    state_file="./longhorn-existing-restore-$prefix.state"
    manifest="./longhorn-existing-restore-$prefix.yaml"
    {
        echo "created_at=$(date -Iseconds 2>/dev/null || date)"
        echo "namespace=$namespace"
        echo "pvc=$pvc"
        echo "pv=$pv"
        echo "volume_handle=$handle"
        echo "backup=$backup"
        echo "backup_source=${LONGHORN_BATCH_SOURCES[$index]}"
        echo "backup_url=$url"
        echo "backup_size=$size"
        echo "replicas=$replicas"
        echo "data_engine=$engine"
        echo "access_mode=$access"
        echo "original_reclaim_policy=$original_reclaim_policy"
    } > "$state_file"
    longhorn_kubectl get pvc "$pvc" -n "$namespace" -o yaml >> "$state_file" 2>/dev/null || true
    longhorn_kubectl get pv "$pv" -o yaml >> "$state_file" 2>/dev/null || true

    cat > "$manifest" << EOF
apiVersion: longhorn.io/v1beta2
kind: Volume
metadata:
  name: $handle
  namespace: longhorn-system
spec:
  size: "$size"
  fromBackup: "$url"
  numberOfReplicas: $replicas
  frontend: blockdev
  dataEngine: $engine
  accessMode: $access
EOF

    print_info "Restoring $namespace/$pvc from $backup..."
    if ! longhorn_set_pv_reclaim_policy "$pv" Retain; then
        print_error "Restore stopped before deleting volume ${handle}; PV/PVC binding was preserved."
        print_info "State record: $state_file"
        return 1
    fi
    if ! longhorn_kubectl delete volume "$handle" -n longhorn-system --wait=true --timeout=180s; then
        print_error "Could not delete the existing Longhorn volume ${handle}."
        print_warning "PV ${pv} was left with reclaim policy Retain for manual recovery."
        return 1
    fi
    if longhorn_kubectl get volume "$handle" -n longhorn-system &>/dev/null; then
        print_error "The old Longhorn volume still exists: $handle"
        print_warning "PV ${pv} was left with reclaim policy Retain for manual recovery."
        return 1
    fi
    if ! longhorn_validate_existing_pv_pvc_binding "$namespace" "$pvc" "$pv" "$handle"; then
        print_error "The PV/PVC binding did not remain Bound for $namespace/$pvc after deleting the old volume."
        print_warning "PV ${pv} was left with reclaim policy Retain for manual recovery."
        print_info "State record: $state_file"
        return 1
    fi
    if ! longhorn_kubectl apply -f "$manifest"; then
        print_error "Could not apply the restore manifest for ${namespace}/${pvc}."
        print_warning "PV ${pv} was left with reclaim policy Retain for manual recovery."
        return 1
    fi
    longhorn_wait_for_restore_detached "$handle" 1800 || return 1
    restored_handle=$(longhorn_kubectl get pv "$pv" -o jsonpath='{.spec.csi.volumeHandle}' 2>/dev/null)
    restored_phase=$(longhorn_kubectl get pvc "$pvc" -n "$namespace" -o jsonpath='{.status.phase}' 2>/dev/null)
    if [ "$restored_handle" != "$handle" ] || [ "$restored_phase" != "Bound" ] || \
        ! longhorn_validate_existing_pv_pvc_binding "$namespace" "$pvc" "$pv" "$handle"; then
        print_error "PV/PVC validation failed after restoring $namespace/$pvc."
        print_warning "PV ${pv} was left with reclaim policy Retain for manual recovery."
        print_info "State record: $state_file"
        return 1
    fi
    if ! longhorn_set_pv_reclaim_policy "$pv" "$original_reclaim_policy"; then
        print_error "${namespace}/${pvc} data was restored, but PV ${pv} reclaim policy could not be returned to ${original_reclaim_policy}."
        print_info "State record: $state_file"
        return 1
    fi
    print_successful "Restored and validated $namespace/$pvc -> $pv -> $handle"
}

longhorn_restore_application_pvcs_impl() {
    longhorn_check_old_backup_target || return 1

    longhorn_discover_applications
    if [ "${#LONGHORN_APPLICATION_NAMESPACES[@]}" -eq 0 ]; then
        print_error "No installed application with deployed PVC-backed workloads was found."
        return 1
    fi

    print_info "Installed applications with PVC-backed workloads:"
    printf '%-4s %-24s %-18s %-6s %-34s %s\n' \
        "NO" "APPLICATION" "NAMESPACE" "PVCS" "PVC NAMES" "FLUX SOURCE"
    local application_index=0 pvc_count
    for ((application_index = 0; application_index < ${#LONGHORN_APPLICATION_NAMESPACES[@]}; application_index++)); do
        pvc_count=$(printf '%s\n' "${LONGHORN_APPLICATION_PVCS[$application_index]}" | awk -F ', ' '{ print NF }')
        printf '%-4s %-24s %-18s %-6s %-34s %s\n' \
            "$((application_index + 1))" \
            "${LONGHORN_APPLICATION_NAMES[$application_index]}" \
            "${LONGHORN_APPLICATION_NAMESPACES[$application_index]}" \
            "$pvc_count" \
            "${LONGHORN_APPLICATION_PVCS[$application_index]}" \
            "${LONGHORN_APPLICATION_FLUX_SOURCES[$application_index]}"
    done

    local selection
    read -p "Select application number: " selection
    if ! printf '%s' "$selection" | grep -Eq '^[0-9]+$' || \
        [ "$selection" -lt 1 ] || [ "$selection" -gt "${#LONGHORN_APPLICATION_NAMESPACES[@]}" ]; then
        print_error "Invalid application selection."
        return 1
    fi

    local selected_index=$((selection - 1))
    local application_name="${LONGHORN_APPLICATION_NAMES[$selected_index]}"
    local namespace="${LONGHORN_APPLICATION_NAMESPACES[$selected_index]}"
    local application_workloads="${LONGHORN_APPLICATION_WORKLOADS[$selected_index]}"
    local application_pvcs="${LONGHORN_APPLICATION_PVCS[$selected_index]}"
    local flux_source="${LONGHORN_APPLICATION_FLUX_SOURCES[$selected_index]}"
    local target_pvcs=()
    mapfile -t target_pvcs < <(longhorn_namespace_pvc_names "$namespace")
    if [ "${#target_pvcs[@]}" -eq 0 ]; then
        print_error "Application namespace $namespace has no PVCs."
        return 1
    fi

    print_info "Selected application: ${application_name}"
    echo "  Namespace:             ${namespace}"
    echo "  Flux source:           ${flux_source}"
    echo "  PVC-backed workloads:  ${application_workloads}"
    echo "  PVCs to inspect:       ${application_pvcs}"
    echo ""

    LONGHORN_BATCH_PVCS=()
    LONGHORN_BATCH_PVS=()
    LONGHORN_BATCH_HANDLES=()
    LONGHORN_BATCH_BACKUPS=()
    LONGHORN_BATCH_SOURCES=()
    LONGHORN_BATCH_URLS=()
    LONGHORN_BATCH_SIZES=()
    LONGHORN_BATCH_REPLICAS=()
    LONGHORN_BATCH_ENGINES=()
    LONGHORN_BATCH_ACCESS_MODES=()

    local plan_pvcs=() plan_pvs=() plan_sources=() plan_backups=() plan_backup_ats=() plan_sizes=() plan_statuses=()
    local preflight_failed=n
    local pvc phase pv driver handle current_size current_replicas current_engine current_access
    local source_volume latest_backup last_backup_at source_size access_mode
    local backup_match_count backup_matches=() backup_match
    local plan_pv plan_source plan_backup plan_backup_at plan_size plan_status

    for pvc in "${target_pvcs[@]}"; do
        plan_pv="-"
        plan_source="-"
        plan_backup="-"
        plan_backup_at="-"
        plan_size="-"
        plan_status="READY"

        phase=$(longhorn_kubectl get pvc "$pvc" -n "$namespace" -o jsonpath='{.status.phase}' 2>/dev/null)
        pv=$(longhorn_kubectl get pvc "$pvc" -n "$namespace" -o jsonpath='{.spec.volumeName}' 2>/dev/null)
        plan_pv="${pv:--}"
        if [ "$phase" != "Bound" ] || [ -z "$pv" ]; then
            plan_status="NOT BOUND"
            preflight_failed=y
            plan_pvcs+=("$pvc")
            plan_pvs+=("$plan_pv")
            plan_sources+=("$plan_source")
            plan_backups+=("$plan_backup")
            plan_backup_ats+=("$plan_backup_at")
            plan_sizes+=("$plan_size")
            plan_statuses+=("$plan_status")
            continue
        fi

        driver=$(longhorn_kubectl get pv "$pv" -o jsonpath='{.spec.csi.driver}' 2>/dev/null)
        if [ "$driver" != "driver.longhorn.io" ]; then
            plan_status="NOT LONGHORN"
            preflight_failed=y
            plan_pvcs+=("$pvc")
            plan_pvs+=("$plan_pv")
            plan_sources+=("$plan_source")
            plan_backups+=("$plan_backup")
            plan_backup_ats+=("$plan_backup_at")
            plan_sizes+=("$plan_size")
            plan_statuses+=("$plan_status")
            continue
        fi

        handle=$(longhorn_kubectl get pv "$pv" -o jsonpath='{.spec.csi.volumeHandle}' 2>/dev/null)
        if [ -z "$handle" ] || ! longhorn_kubectl get volume "$handle" -n longhorn-system &>/dev/null; then
            plan_status="LONGHORN VOLUME MISSING"
            preflight_failed=y
            plan_pvcs+=("$pvc")
            plan_pvs+=("$plan_pv")
            plan_sources+=("$plan_source")
            plan_backups+=("$plan_backup")
            plan_backup_ats+=("$plan_backup_at")
            plan_sizes+=("$plan_size")
            plan_statuses+=("$plan_status")
            continue
        fi

        current_size=$(longhorn_kubectl get volume "$handle" -n longhorn-system -o jsonpath='{.spec.size}' 2>/dev/null)
        current_replicas=$(longhorn_kubectl get volume "$handle" -n longhorn-system -o jsonpath='{.spec.numberOfReplicas}' 2>/dev/null)
        current_engine=$(longhorn_kubectl get volume "$handle" -n longhorn-system -o jsonpath='{.spec.dataEngine}' 2>/dev/null)
        current_access=$(longhorn_kubectl get volume "$handle" -n longhorn-system -o jsonpath='{.spec.accessMode}' 2>/dev/null)
        current_replicas=${current_replicas:-3}
        current_engine=${current_engine:-v1}
        current_access=${current_access:-rwo}
        plan_size="${current_size:--}"

        mapfile -t backup_matches < <(longhorn_backup_sources_for_pvc "$namespace" "$pvc")
        backup_match_count=${#backup_matches[@]}
        if [ "$backup_match_count" -eq 0 ]; then
            plan_status="MISSING BACKUP"
            preflight_failed=y
        elif [ "$backup_match_count" -gt 1 ]; then
            plan_status="AMBIGUOUS BACKUP SOURCE"
            preflight_failed=y
        else
            backup_match="${backup_matches[0]}"
            IFS=$'\t' read -r source_volume latest_backup last_backup_at source_size access_mode <<< "$backup_match"
            plan_source="${source_volume:--}"
            plan_backup="${latest_backup:--}"
            plan_backup_at="${last_backup_at:--}"
            if [ -z "$source_volume" ] || [ -z "$latest_backup" ]; then
                plan_status="MISSING LAST BACKUP"
                preflight_failed=y
            elif ! longhorn_select_latest_backup_for_volume "$source_volume" "$latest_backup"; then
                plan_status="BACKUP NOT RETAINED"
                preflight_failed=y
            elif [ -z "$LONGHORN_SELECTED_BACKUP_URL" ] || [ -z "$LONGHORN_SELECTED_BACKUP_SIZE" ]; then
                plan_status="INVALID BACKUP RECORD"
                preflight_failed=y
            elif printf '%s' "$LONGHORN_SELECTED_BACKUP_SIZE" | grep -Eq '^[0-9]+$' && \
                printf '%s' "$current_size" | grep -Eq '^[0-9]+$' && \
                [ "$LONGHORN_SELECTED_BACKUP_SIZE" -ne "$current_size" ]; then
                plan_status="BACKUP SIZE MISMATCH"
                preflight_failed=y
            else
                LONGHORN_BATCH_PVCS+=("$pvc")
                LONGHORN_BATCH_PVS+=("$pv")
                LONGHORN_BATCH_HANDLES+=("$handle")
                LONGHORN_BATCH_BACKUPS+=("$LONGHORN_SELECTED_BACKUP")
                LONGHORN_BATCH_SOURCES+=("$source_volume")
                LONGHORN_BATCH_URLS+=("$LONGHORN_SELECTED_BACKUP_URL")
                LONGHORN_BATCH_SIZES+=("$LONGHORN_SELECTED_BACKUP_SIZE")
                LONGHORN_BATCH_REPLICAS+=("$current_replicas")
                LONGHORN_BATCH_ENGINES+=("$current_engine")
                LONGHORN_BATCH_ACCESS_MODES+=("${access_mode:-rwo}")
            fi
        fi

        plan_pvcs+=("$pvc")
        plan_pvs+=("$plan_pv")
        plan_sources+=("$plan_source")
        plan_backups+=("$plan_backup")
        plan_backup_ats+=("$plan_backup_at")
        plan_sizes+=("$plan_size")
        plan_statuses+=("$plan_status")
    done

    print_info "PVC restore preflight (latest retained backup per PVC):"
    printf '%-30s %-38s %-32s %-24s %-16s %s\n' \
        "PVC" "PV" "SOURCE_VOLUME" "LAST_BACKUP" "LAST_BACKUP_AT" "STATUS"
    local plan_index
    for ((plan_index = 0; plan_index < ${#plan_pvcs[@]}; plan_index++)); do
        printf '%-30s %-38s %-32s %-24s %-16s %s\n' \
            "${plan_pvcs[$plan_index]}" \
            "${plan_pvs[$plan_index]}" \
            "${plan_sources[$plan_index]}" \
            "${plan_backups[$plan_index]}" \
            "${plan_backup_ats[$plan_index]}" \
            "${plan_statuses[$plan_index]}"
    done

    if [ "$preflight_failed" = "y" ]; then
        print_error "Restore stopped. Every PVC must be READY before any workload or volume is changed."
        return 1
    fi

    print_successful "All ${#target_pvcs[@]} application PVCs have a retained latest backup."
    read -p "Type RESTORE to suspend Flux, stop PVC-owning workloads, and restore all listed PVCs: " confirm_restore
    [ "$confirm_restore" = "RESTORE" ] || return 2

    longhorn_collect_application_workloads "$namespace" "${LONGHORN_BATCH_PVCS[@]}"
    local running=n pods=() workload kind daemonset_ready
    for pvc in "${LONGHORN_BATCH_PVCS[@]}"; do
        mapfile -t pods < <(longhorn_pvc_pods "$namespace" "$pvc")
        [ "${#pods[@]}" -gt 0 ] && running=y
    done
    if [ "$running" = "y" ]; then
        for workload in "${LONGHORN_RESTORE_WORKLOADS[@]}"; do
            kind="${workload%%/*}"
            if [ "$kind" = "daemonset" ]; then
                daemonset_ready=$(longhorn_kubectl get "$workload" -n "$namespace" \
                    -o jsonpath='{.status.numberReady}' 2>/dev/null)
                if printf '%s' "$daemonset_ready" | grep -Eq '^[1-9][0-9]*$'; then
                    print_error "DaemonSet $workload is running; stop it manually before continuing."
                    return 1
                fi
            fi
        done
    fi

    longhorn_suspend_application_flux_resources "$namespace" || return 1
    if [ "$running" = "y" ]; then
        for ((plan_index = 0; plan_index < ${#LONGHORN_RESTORE_WORKLOADS[@]}; plan_index++)); do
            workload="${LONGHORN_RESTORE_WORKLOADS[$plan_index]}"
            kind="${workload%%/*}"
            if [ "$kind" = "deployment" ] || [ "$kind" = "statefulset" ]; then
                longhorn_kubectl scale "$workload" -n "$namespace" --replicas=0 || return 1
                LONGHORN_RESTORE_WORKLOADS_SCALED=y
            fi
        done
        for pvc in "${LONGHORN_BATCH_PVCS[@]}"; do
            longhorn_wait_for_pvc_pods_gone "$namespace" "$pvc" 180 || return 1
        done
    fi

    longhorn_validate_flux_suspended || return 1
    local restore_index
    for ((restore_index = 0; restore_index < ${#LONGHORN_BATCH_PVCS[@]}; restore_index++)); do
        longhorn_wait_for_volume_detached "${LONGHORN_BATCH_HANDLES[$restore_index]}" 180 || return 1
        longhorn_restore_batch_volume "$restore_index" || return 1
    done
    LONGHORN_RESTORE_TARGET_NAMESPACE="$namespace"
    LONGHORN_RESTORE_TARGET_PVC="${LONGHORN_BATCH_PVCS[0]}"
    print_successful "All ${#LONGHORN_BATCH_PVCS[@]} application PVCs were restored and validated."
}

longhorn_restore_application_pvcs() {
    LONGHORN_FLUX_GUARDED_KINDS=()
    LONGHORN_FLUX_GUARDED_NAMES=()
    LONGHORN_FLUX_GUARDED_NAMESPACES=()
    LONGHORN_FLUX_CHANGED_KINDS=()
    LONGHORN_FLUX_CHANGED_NAMES=()
    LONGHORN_FLUX_CHANGED_NAMESPACES=()
    LONGHORN_RESTORE_WORKLOADS=()
    LONGHORN_RESTORE_WORKLOAD_REPLICAS=()
    LONGHORN_RESTORE_WORKLOAD_NAMESPACE=""
    LONGHORN_RESTORE_TARGET_NAMESPACE=""
    LONGHORN_RESTORE_TARGET_PVC=""
    LONGHORN_RESTORE_WORKLOADS_SCALED=n

    longhorn_restore_application_pvcs_impl
    local restore_result=$?
    if [ "$restore_result" -eq 2 ]; then
        print_info "Application PVC batch restore cancelled before any changes."
        return 0
    fi
    local cleanup_result=0
    longhorn_restore_workloads || cleanup_result=1
    if ! longhorn_resume_flux_resources; then
        cleanup_result=1
    elif ! longhorn_wait_for_flux_ready; then
        cleanup_result=1
    fi
    if [ "$restore_result" -eq 0 ] && [ "$cleanup_result" -eq 0 ]; then
        print_info "Verify the application after Flux reconciliation:"
        echo "  kubectl -n ${LONGHORN_RESTORE_TARGET_NAMESPACE:-<namespace>} get pvc"
        echo "  kubectl -n ${LONGHORN_RESTORE_TARGET_NAMESPACE:-<namespace>} get pods -o wide"
        print_successful "Application PVC batch restore completed without changing app manifests."
    elif [ "$cleanup_result" -ne 0 ]; then
        print_error "Batch restore cleanup was incomplete. Check workload replicas and Flux suspension state manually."
    elif [ "$restore_result" -ne 0 ]; then
        print_error "Application PVC batch restore did not complete. Not all PVCs were restored."
        print_info "Review the restore state files and Longhorn volume status before retrying."
    fi
    [ "$restore_result" -eq 0 ] && [ "$cleanup_result" -eq 0 ]
}

longhorn_restore_into_existing_pvc_impl() {
    longhorn_check_old_backup_target || return 1

    print_info "Select the source application/volume to restore:"
    local lines=()
    mapfile -t lines < <(longhorn_backup_volume_lines 2>/dev/null)
    local backup_volumes=() source_volumes=() last_backups=() last_backup_ats=()
    local size_bytes_values=() namespaces=() pvcs=() access_modes=()
    local index=1 line backup_volume source_volume last_backup last_backup_at size_bytes storage_class kstatus access_mode
    local source_namespace source_pvc

    printf '%-4s %-20s %-30s %-22s %-20s %-8s %s\n' "NO" "SOURCE NS" "SOURCE PVC" "LAST_BACKUP" "LAST_BACKUP_AT" "ACCESS" "SOURCE_VOLUME"
    for line in "${lines[@]}"; do
        IFS=$'\t' read -r backup_volume source_volume last_backup last_backup_at size_bytes storage_class kstatus access_mode <<< "$line"
        [ -z "$last_backup" ] && continue
        source_namespace=$(longhorn_json_field "$kstatus" "namespace")
        source_pvc=$(longhorn_json_field "$kstatus" "pvcName")
        backup_volumes+=("$backup_volume")
        source_volumes+=("$source_volume")
        last_backups+=("$last_backup")
        last_backup_ats+=("$last_backup_at")
        size_bytes_values+=("$size_bytes")
        namespaces+=("$source_namespace")
        pvcs+=("$source_pvc")
        access_modes+=("${access_mode:-rwo}")
        printf '%-4s %-20s %-30s %-22s %-20s %-8s %s\n' \
            "$index" \
            "$(longhorn_display_value "$source_namespace")" \
            "$(longhorn_display_value "$source_pvc")" \
            "$last_backup" \
            "$(longhorn_display_value "$last_backup_at")" \
            "$(longhorn_display_value "${access_mode:-rwo}")" \
            "$source_volume"
        index=$((index + 1))
    done

    if [ "${#last_backups[@]}" -eq 0 ]; then
        print_error "The old backup target is reachable, but no usable latest backups were imported."
        return 1
    fi

    local selection selected selected_backup selected_source selected_backup_size selected_access_mode
    read -p "Select backup number: " selection
    if ! printf '%s' "$selection" | grep -Eq '^[0-9]+$' || [ "$selection" -lt 1 ] || [ "$selection" -gt "${#last_backups[@]}" ]; then
        print_error "Invalid backup selection."
        return 1
    fi
    selected=$((selection - 1))
    selected_backup="${last_backups[$selected]}"
    selected_source="${source_volumes[$selected]}"
    selected_backup_size="${size_bytes_values[$selected]}"
    selected_access_mode="${access_modes[$selected]}"
    longhorn_select_backup_for_volume "$selected_source" "$selected_backup" || return 1
    selected_backup="$LONGHORN_SELECTED_BACKUP"
    local backup_url="$LONGHORN_SELECTED_BACKUP_URL"
    selected_backup_size="$LONGHORN_SELECTED_BACKUP_SIZE"
    if [ -z "$backup_url" ] || [ -z "$selected_backup_size" ]; then
        print_error "Could not read the selected backup URL or exact byte size."
        return 1
    fi

    local target_namespace target_pvc pvc_phase pv_name pv_handle pv_driver original_reclaim_policy
    local pvc_storage_class pvc_access_mode pv_capacity current_volume_size current_volume_state
    read -p "Target PVC namespace (default: ${namespaces[$selected]:-default}): " target_namespace
    target_namespace=${target_namespace:-${namespaces[$selected]:-default}}
    read -p "Target PVC name (default: ${pvcs[$selected]}): " target_pvc
    target_pvc=${target_pvc:-${pvcs[$selected]}}
    LONGHORN_RESTORE_TARGET_NAMESPACE="$target_namespace"
    LONGHORN_RESTORE_TARGET_PVC="$target_pvc"
    if [ -z "$target_pvc" ]; then
        print_error "A target PVC name is required."
        return 1
    fi

    if ! longhorn_kubectl get namespace "$target_namespace" &>/dev/null; then
        print_error "Target namespace does not exist: $target_namespace"
        return 1
    fi
    if ! longhorn_kubectl get pvc "$target_pvc" -n "$target_namespace" &>/dev/null; then
        print_error "Target PVC does not exist: ${target_namespace}/${target_pvc}"
        print_info "Use 'Restore as a new PVC' for an application that is not deployed yet."
        return 1
    fi

    pvc_phase=$(longhorn_kubectl get pvc "$target_pvc" -n "$target_namespace" -o jsonpath='{.status.phase}' 2>/dev/null)
    pv_name=$(longhorn_kubectl get pvc "$target_pvc" -n "$target_namespace" -o jsonpath='{.spec.volumeName}' 2>/dev/null)
    pvc_storage_class=$(longhorn_kubectl get pvc "$target_pvc" -n "$target_namespace" -o jsonpath='{.spec.storageClassName}' 2>/dev/null)
    pvc_access_mode=$(longhorn_kubectl get pvc "$target_pvc" -n "$target_namespace" -o jsonpath='{.spec.accessModes[0]}' 2>/dev/null)
    if [ "$pvc_phase" != "Bound" ] || [ -z "$pv_name" ]; then
        print_error "Target PVC is not Bound: ${target_namespace}/${target_pvc} (phase: ${pvc_phase:-unknown})"
        return 1
    fi
    if ! longhorn_kubectl get pv "$pv_name" &>/dev/null; then
        print_error "The PVC references a missing PV: $pv_name"
        return 1
    fi

    pv_handle=$(longhorn_kubectl get pv "$pv_name" -o jsonpath='{.spec.csi.volumeHandle}' 2>/dev/null)
    pv_driver=$(longhorn_kubectl get pv "$pv_name" -o jsonpath='{.spec.csi.driver}' 2>/dev/null)
    pv_capacity=$(longhorn_kubectl get pv "$pv_name" -o jsonpath='{.spec.capacity.storage}' 2>/dev/null)
    original_reclaim_policy=$(longhorn_kubectl get pv "$pv_name" \
        -o jsonpath='{.spec.persistentVolumeReclaimPolicy}' 2>/dev/null)
    original_reclaim_policy=${original_reclaim_policy:-Delete}
    if [ "$pv_driver" != "driver.longhorn.io" ] || [ -z "$pv_handle" ]; then
        print_error "Target PV is not a Longhorn CSI PV: $pv_name"
        return 1
    fi
    if ! longhorn_kubectl get volumes.longhorn.io "$pv_handle" -n longhorn-system &>/dev/null; then
        print_error "The PV points to a missing Longhorn volume: $pv_handle"
        return 1
    fi

    current_volume_size=$(longhorn_kubectl get volume "$pv_handle" -n longhorn-system -o jsonpath='{.spec.size}' 2>/dev/null)
    current_volume_state=$(longhorn_kubectl get volume "$pv_handle" -n longhorn-system -o jsonpath='{.status.state}' 2>/dev/null)
    local current_volume_access_mode current_volume_replicas current_volume_engine
    current_volume_access_mode=$(longhorn_kubectl get volume "$pv_handle" -n longhorn-system -o jsonpath='{.spec.accessMode}' 2>/dev/null)
    current_volume_replicas=$(longhorn_kubectl get volume "$pv_handle" -n longhorn-system -o jsonpath='{.spec.numberOfReplicas}' 2>/dev/null)
    current_volume_engine=$(longhorn_kubectl get volume "$pv_handle" -n longhorn-system -o jsonpath='{.spec.dataEngine}' 2>/dev/null)
    current_volume_access_mode=${current_volume_access_mode:-rwo}
    current_volume_replicas=${current_volume_replicas:-3}
    current_volume_engine=${current_volume_engine:-v1}

    print_info "Existing application storage:"
    echo "  Workload PVC:       ${target_namespace}/${target_pvc}"
    echo "  PVC phase:          $pvc_phase"
    echo "  PV:                 $pv_name"
    echo "  Longhorn handle:    $pv_handle"
    echo "  Longhorn state:     $current_volume_state"
    echo "  StorageClass:       $(longhorn_display_value "$pvc_storage_class")"
    echo "  Access mode:        $(longhorn_display_value "$pvc_access_mode")"
    echo "  PV capacity:        $(longhorn_display_value "$pv_capacity")"
    echo "  Current volume size: $(longhorn_display_value "$current_volume_size")"
    echo "  Backup size:        $(longhorn_display_value "$selected_backup_size") bytes"
    echo "  Backup source:      $selected_source"
    echo "  Selected backup:    $selected_backup"
    echo ""

    local workloads=() pods=()
    mapfile -t workloads < <(longhorn_pvc_workloads "$target_namespace" "$target_pvc")
    mapfile -t pods < <(longhorn_pvc_pods "$target_namespace" "$target_pvc")
    if [ "${#workloads[@]}" -eq 0 ]; then
        print_error "No Deployment, StatefulSet, or DaemonSet declares this PVC."
        print_info "The application may not be deployed yet. Use 'Restore as a new PVC' instead."
        return 1
    fi
    print_info "Workloads declaring the PVC: ${workloads[*]}"
    if [ "${#pods[@]}" -gt 0 ]; then
        print_warning "Pods currently using the PVC: ${pods[*]}"
    else
        print_successful "No running pods currently use the PVC."
    fi

    longhorn_validate_flux_pause "$target_namespace" "$target_pvc" || return 1

    local workload_replicas=() workload kind replicas
    for workload in "${workloads[@]}"; do
        kind="${workload%%/*}"
        if [ "$kind" = "daemonset" ]; then
            if [ "${#pods[@]}" -gt 0 ]; then
                print_error "DaemonSet ${workload} still uses the PVC. Stop it manually before continuing."
                return 1
            fi
            workload_replicas+=("-")
            continue
        fi
        replicas=$(longhorn_kubectl get "$workload" -n "$target_namespace" -o jsonpath='{.spec.replicas}' 2>/dev/null)
        workload_replicas+=("${replicas:-1}")
    done
    LONGHORN_RESTORE_WORKLOADS=("${workloads[@]}")
    LONGHORN_RESTORE_WORKLOAD_REPLICAS=("${workload_replicas[@]}")
    LONGHORN_RESTORE_WORKLOAD_NAMESPACE="$target_namespace"
    LONGHORN_RESTORE_WORKLOADS_SCALED=n

    if [ "${#pods[@]}" -gt 0 ]; then
        prompt_yn scale_down "Scale the listed Deployment/StatefulSet workloads to zero now? (y/n): " "n" || return 1
        [ "$scale_down" = "y" ] || { print_error "Restore cancelled while pods are still using the PVC."; return 1; }
        LONGHORN_RESTORE_WORKLOADS_SCALED=y
        for workload in "${workloads[@]}"; do
            kind="${workload%%/*}"
            if [ "$kind" = "deployment" ] || [ "$kind" = "statefulset" ]; then
                longhorn_kubectl scale "$workload" -n "$target_namespace" --replicas=0 || return 1
            fi
        done
        longhorn_wait_for_pvc_pods_gone "$target_namespace" "$target_pvc" 180 || return 1
    fi

    longhorn_wait_for_volume_detached "$pv_handle" 180 || return 1
    if printf '%s' "$selected_backup_size" | grep -Eq '^[0-9]+$' && printf '%s' "$current_volume_size" | grep -Eq '^[0-9]+$' && [ "$selected_backup_size" -ne "$current_volume_size" ]; then
        print_error "Backup size does not match the existing volume size."
        print_info "Existing: ${current_volume_size} bytes; backup: ${selected_backup_size} bytes."
        print_info "Use the standard new-volume restore path for a size change."
        return 1
    fi

    local state_prefix state_file restore_manifest
    state_prefix=$(sanitize_k8s_name "${target_namespace}-${target_pvc}-${selected_backup}")
    state_file="./longhorn-existing-restore-${state_prefix}.state"
    restore_manifest="./longhorn-existing-restore-${state_prefix}.yaml"
    {
        echo "created_at=$(date -Iseconds 2>/dev/null || date)"
        echo "namespace=$target_namespace"
        echo "pvc=$target_pvc"
        echo "pv=$pv_name"
        echo "volume_handle=$pv_handle"
        echo "backup=$selected_backup"
        echo "backup_source=$selected_source"
        echo "backup_url=$backup_url"
        echo "backup_size=$selected_backup_size"
        echo "replicas=$current_volume_replicas"
        echo "data_engine=$current_volume_engine"
        echo "access_mode=$current_volume_access_mode"
        echo "storage_class=$pvc_storage_class"
        echo "original_reclaim_policy=$original_reclaim_policy"
    } > "$state_file"
    longhorn_kubectl get pvc "$target_pvc" -n "$target_namespace" -o yaml >> "$state_file" 2>/dev/null || true
    longhorn_kubectl get pv "$pv_name" -o yaml >> "$state_file" 2>/dev/null || true

    cat > "$restore_manifest" << EOF
apiVersion: longhorn.io/v1beta2
kind: Volume
metadata:
  name: ${pv_handle}
  namespace: longhorn-system
spec:
  size: "${selected_backup_size}"
  fromBackup: "${backup_url}"
  numberOfReplicas: ${current_volume_replicas}
  frontend: blockdev
  dataEngine: ${current_volume_engine}
  accessMode: ${current_volume_access_mode}
EOF

    print_warning "The empty Longhorn volume ${pv_handle} will be deleted and replaced with the selected old backup."
    print_warning "The existing PV/PVC are expected to remain unchanged and continue pointing to ${pv_handle}."
    echo "  State record:   $state_file"
    echo "  Restore file:   $restore_manifest"
    echo "  Existing PV:    $pv_name"
    echo "  Existing PVC:   ${target_namespace}/${target_pvc}"
    echo ""
    read -p "Type REPLACE to delete the empty volume and restore the old backup: " replace_confirm
    if [ "$replace_confirm" != "REPLACE" ]; then
        print_info "Restore cancelled before changing the cluster."
        return 0
    fi

    longhorn_validate_flux_suspended || return 1

    if ! longhorn_set_pv_reclaim_policy "$pv_name" Retain; then
        print_error "Restore stopped before deleting volume ${pv_handle}; PV/PVC binding was preserved."
        print_info "State record: $state_file"
        return 1
    fi
    if ! longhorn_kubectl delete volume "$pv_handle" -n longhorn-system --wait=true --timeout=180s; then
        print_error "Could not delete the existing empty Longhorn volume. Nothing was restored."
        print_warning "PV ${pv_name} was left with reclaim policy Retain for manual recovery."
        return 1
    fi
    if longhorn_kubectl get volume "$pv_handle" -n longhorn-system &>/dev/null; then
        print_error "The old Longhorn volume still exists. Restore was not attempted."
        print_warning "PV ${pv_name} was left with reclaim policy Retain for manual recovery."
        return 1
    fi
    if ! longhorn_validate_existing_pv_pvc_binding "$target_namespace" "$target_pvc" "$pv_name" "$pv_handle"; then
        print_error "The existing PV/PVC binding did not remain Bound after volume deletion."
        print_warning "PV ${pv_name} was left with reclaim policy Retain for manual recovery."
        print_info "Use the saved state record to recover the binding: $state_file"
        return 1
    fi

    if ! longhorn_kubectl apply -f "$restore_manifest"; then
        print_error "Could not apply the restore manifest for ${target_namespace}/${target_pvc}."
        print_warning "PV ${pv_name} was left with reclaim policy Retain for manual recovery."
        return 1
    fi
    print_successful "Restore requested using the existing PV volume handle: $pv_handle"
    longhorn_wait_for_restore_detached "$pv_handle" 1800 || return 1

    local restored_handle restored_phase
    restored_handle=$(longhorn_kubectl get pv "$pv_name" -o jsonpath='{.spec.csi.volumeHandle}' 2>/dev/null)
    restored_phase=$(longhorn_kubectl get pvc "$target_pvc" -n "$target_namespace" -o jsonpath='{.status.phase}' 2>/dev/null)
    if [ "$restored_handle" != "$pv_handle" ] || [ "$restored_phase" != "Bound" ] || \
        ! longhorn_validate_existing_pv_pvc_binding "$target_namespace" "$target_pvc" "$pv_name" "$pv_handle"; then
        print_error "PV/PVC validation failed after restore."
        echo "  PV handle: $restored_handle"
        echo "  PVC phase: $restored_phase"
        print_warning "PV ${pv_name} was left with reclaim policy Retain for manual recovery."
        print_info "The saved state record is available at: $state_file"
        return 1
    fi
    if ! longhorn_set_pv_reclaim_policy "$pv_name" "$original_reclaim_policy"; then
        print_error "Storage data was restored, but PV ${pv_name} reclaim policy could not be returned to ${original_reclaim_policy}."
        print_info "The saved state record is available at: $state_file"
        return 1
    fi
    print_successful "Existing PV/PVC binding is intact: ${target_namespace}/${target_pvc} -> ${pv_name} -> ${pv_handle}"
    print_successful "Storage restore completed; cleanup will restore workloads and Flux reconciliation."
    return 0
}

longhorn_restore_into_existing_pvc() {
    LONGHORN_FLUX_GUARDED_KINDS=()
    LONGHORN_FLUX_GUARDED_NAMES=()
    LONGHORN_FLUX_GUARDED_NAMESPACES=()
    LONGHORN_FLUX_CHANGED_KINDS=()
    LONGHORN_FLUX_CHANGED_NAMES=()
    LONGHORN_FLUX_CHANGED_NAMESPACES=()
    LONGHORN_RESTORE_WORKLOADS=()
    LONGHORN_RESTORE_WORKLOAD_REPLICAS=()
    LONGHORN_RESTORE_WORKLOAD_NAMESPACE=""
    LONGHORN_RESTORE_TARGET_NAMESPACE=""
    LONGHORN_RESTORE_TARGET_PVC=""
    LONGHORN_RESTORE_WORKLOADS_SCALED=n

    longhorn_restore_into_existing_pvc_impl
    local restore_result=$?
    local cleanup_result=0

    if ! longhorn_restore_workloads; then
        cleanup_result=1
    fi
    if ! longhorn_resume_flux_resources; then
        cleanup_result=1
    elif ! longhorn_wait_for_flux_ready; then
        cleanup_result=1
    fi

    if [ "$restore_result" -eq 0 ] && [ "$cleanup_result" -eq 0 ]; then
        print_info "Verify the application after Flux reconciliation:"
        echo "  kubectl -n ${LONGHORN_RESTORE_TARGET_NAMESPACE:-<namespace>} get pvc ${LONGHORN_RESTORE_TARGET_PVC:-<pvc-name>}"
        echo "  kubectl -n ${LONGHORN_RESTORE_TARGET_NAMESPACE:-<namespace>} get pods -o wide"
        print_successful "Application storage restore finished without changing the application PVC name or manifest."
    elif [ "$cleanup_result" -ne 0 ]; then
        print_error "Restore cleanup was incomplete. Check workload replicas and Flux suspension state manually."
    fi
    [ "$restore_result" -eq 0 ] && [ "$cleanup_result" -eq 0 ]
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

    longhorn_select_backup_for_volume "$selected_source" "$selected_backup" || return 1
    selected_backup="$LONGHORN_SELECTED_BACKUP"
    local backup_url="$LONGHORN_SELECTED_BACKUP_URL"
    local volume_size="$LONGHORN_SELECTED_BACKUP_SIZE"
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
        echo "1. Check old backup target and inventory"
        echo "2. List backup inventory"
        echo "3. Restore entire application (all PVCs)"
        echo "4. Restore into existing application PVC (single)"
        echo "5. Restore as a new PVC (single)"
        echo "6. Check restore / volume status"
        echo "7. Back to Main Menu"
        echo -e "${YELLOW}==========================================${NC}"
        read -p "Enter your choice: " longhorn_choice

        case $longhorn_choice in
            1) longhorn_check_old_backup_target ;;
            2) longhorn_list_backup_inventory ;;
            3) longhorn_restore_application_pvcs ;;
            4) longhorn_restore_into_existing_pvc ;;
            5) longhorn_selective_restore ;;
            6) longhorn_restore_status ;;
            7) return ;;
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
    echo "1.  Generate Config File (cluster settings + HA VIP)"
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
    echo "12. Cluster Status / Diagnostics"
    echo "13. Reset Node"
    echo "14. Rolling OS Upgrade (A/B)"
    echo "15. Update Script Now (no reboot)"
    echo "16. Show Config File"
    echo "17. Cat Kubeconfig"
    echo "18. Exit"
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
        12) ensure_config && manage_cluster_status ;;
        13) reset_node ;;
        14) kairos_rolling_upgrade ;;
        15) update_script_now ;;
        16) show_config_file ;;
        17) show_kubeconfig ;;
        18) echo "Exiting..."; exit 0 ;;
        "") continue ;;
        *) print_error "Invalid option." ;;
    esac
done
