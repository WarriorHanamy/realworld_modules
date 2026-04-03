#!/usr/bin/env bash
#
# Setup Syncthing bidirectional sync between host and device
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"

CONFIG_DIR="${HOME}/.config/zuanfeng-sync"
SERVICE_NAME="zuanfeng-syncthing"

fn_nv_load_env
DEFAULT_DEVICE_IP="${DEVICE_IP}"
DEFAULT_DEVICE_USER="${DEVICE_USER}"
DEFAULT_SSH_KEY="${SSH_KEY}"
DEFAULT_SOURCE_FOLDER="${HOST_SOURCE_FOLDER}"
DEFAULT_DEVICE_TARGET_FOLDER="${DEVICE_TARGET_FOLDER}"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }
log_step() { echo -e "${BLUE}[STEP]${NC} $1"; }

check_ssh() {
    log_step "Testing SSH connection to ${DEVICE_USER}@${DEVICE_IP}..."
    if [[ ! -f "${SSH_KEY}" ]]; then
        log_error "SSH key not found: ${SSH_KEY}"
        return 1
    fi
    NV_SSH_EXTRA_OPTS=(-o BatchMode=yes -o ConnectTimeout=5)
    fn_nv_reset_ssh
    fn_nv_ensure_ssh
    if ! fn_nv_check_ssh; then
        log_warn "Cannot connect to ${DEVICE_USER}@${DEVICE_IP}, copying SSH key..."
        "${SCRIPT_DIR}/copy_ssh_key.sh"
        fn_nv_reset_ssh
        fn_nv_ensure_ssh
        if ! fn_nv_check_ssh; then
            log_error "SSH key copy succeeded but still cannot connect"
            return 1
        fi
    fi
    log_info "SSH connection OK"
}

install_syncthing_host() {
    log_step "Installing Syncthing on host..."
    if command -v syncthing &>/dev/null; then
        log_info "Syncthing already installed: $(syncthing --version 2>&1 | head -1)"
        return 0
    fi

    if command -v pacman &>/dev/null; then
        if command -v yay &>/dev/null; then
            yay -S --noconfirm syncthing
        else
            sudo pacman -S --noconfirm syncthing
        fi
    elif command -v apt &>/dev/null; then
        curl -fsSL https://syncthing.net/release-key.gpg | sudo tee /usr/share/keyrings/syncthing-archive-keyring.gpg >/dev/null
        echo "deb [signed-by=/usr/share/keyrings/syncthing-archive-keyring.gpg] https://apt.syncthing.net/ syncthing stable" | sudo tee /etc/apt/sources.list.d/syncthing.list
        sudo apt update
        sudo apt install -y syncthing
    else
        log_error "Unsupported package manager. Install syncthing manually."
        return 1
    fi
    log_info "Syncthing installed on host"
}

install_syncthing_device() {
    log_step "Installing Syncthing on device..."
    NV_SSH_EXTRA_OPTS=(-o BatchMode=yes -o ConnectTimeout=30)
    fn_nv_reset_ssh
    fn_nv_ensure_ssh
    
    if "${SSH_CMD[@]}" "command -v syncthing" &>/dev/null; then
        log_info "Syncthing already installed on device"
        return 0
    fi

    fn_nv_run_remote_sudo_bash "install -d -m 0755 /usr/share/keyrings /etc/apt/sources.list.d && curl -fsSL https://syncthing.net/release-key.gpg -o /usr/share/keyrings/syncthing-archive-keyring.gpg && printf '%s\n' 'deb [signed-by=/usr/share/keyrings/syncthing-archive-keyring.gpg] https://apt.syncthing.net/ syncthing stable' > /etc/apt/sources.list.d/syncthing.list && apt update && apt install -y syncthing"
    log_info "Syncthing installed on device"
}

ensure_device_sudo() {
    log_step "Ensuring passwordless sudo on device..."
    NV_SSH_EXTRA_OPTS=(-o BatchMode=yes -o ConnectTimeout=30)
    fn_nv_reset_ssh
    fn_nv_ensure_ssh

    if "${SSH_CMD[@]}" "sudo -n true" &>/dev/null; then
        log_info "Passwordless sudo already enabled on device"
        return 0
    fi

    "${SCRIPT_DIR}/raise_sudoer.sh"

    fn_nv_reset_ssh
    fn_nv_ensure_ssh
    if "${SSH_CMD[@]}" "sudo -n true" &>/dev/null; then
        log_info "Passwordless sudo enabled on device"
        return 0
    fi

    log_error "Failed to enable passwordless sudo on device"
    return 1
}

ensure_device_route() {
    log_step "Ensuring route priority to ${HOST_IP} on device..."
    NV_SSH_EXTRA_OPTS=(-o BatchMode=yes -o ConnectTimeout=30)
    fn_nv_reset_ssh
    fn_nv_ensure_ssh

    if "${SSH_CMD[@]}" "ip route show exact ${HOST_IP}/32" 2>/dev/null | grep -q "${HOST_IP}"; then
        log_info "Route to ${HOST_IP} already exists on device"
        return 0
    fi

    local iface
    iface=$("${SSH_CMD[@]}" "ip -o link show | awk -F': ' '/l4tbr0|usb[0-9]/{print \$2}' | head -1" 2>/dev/null)

    if [[ -z "${iface}" ]]; then
        log_warn "Could not detect USB network interface on device, skipping route setup"
        return 0
    fi

    fn_nv_run_remote_sudo_bash "ip route add ${HOST_IP}/32 dev ${iface} metric 100" 2>/dev/null \
        || fn_nv_run_remote_sudo_bash "ip route replace ${HOST_IP}/32 dev ${iface} metric 100"

    if "${SSH_CMD[@]}" "ip route show ${HOST_IP}" 2>/dev/null | grep -q "${HOST_IP}"; then
        log_info "Route to ${HOST_IP} via ${iface} added (metric 100)"
    else
        log_warn "Failed to add route to ${HOST_IP}"
    fi
}

get_device_id() {
    local config_file="$1"
    if [[ ! -f "$config_file" ]]; then
        echo ""
        return
    fi
    grep -oP '(?<=<device id=")[^"]+' "$config_file" | head -1
}

generate_syncthing_config_host() {
    local target_home="$1"

    if syncthing generate --help >/dev/null 2>&1; then
        syncthing generate --home="${target_home}"
    else
        syncthing -generate="${target_home}"
    fi
}

generate_syncthing_config_device() {
    local target_home="$1"

    "${SSH_CMD[@]}" "if syncthing generate --help >/dev/null 2>&1; then syncthing generate --home='${target_home}'; else syncthing -generate='${target_home}'; fi"
}

setup_syncthing_host() {
    log_step "Configuring Syncthing on host..."
    
    mkdir -p "${HOME}/.config/syncthing"
    
    systemctl --user stop syncthing.service 2>/dev/null || true
    
    if [[ ! -f "${HOME}/.config/syncthing/config.xml" ]]; then
        generate_syncthing_config_host "${HOME}/.config/syncthing"
    fi
    
    local host_config="${HOME}/.config/syncthing/config.xml"
    local host_id
    host_id=$(get_device_id "$host_config")
    
    echo "Host Device ID: ${host_id}"
    echo "${host_id}" > "${CONFIG_DIR}/host-id.txt"
    
    log_info "Host Syncthing configured"
}

setup_syncthing_device() {
    log_step "Configuring Syncthing on device..."
    NV_SSH_EXTRA_OPTS=(-o BatchMode=yes -o ConnectTimeout=30)
    fn_nv_reset_ssh
    fn_nv_ensure_ssh
    
    "${SSH_CMD[@]}" "mkdir -p ~/.config/syncthing"
    
    "${SSH_CMD[@]}" "systemctl --user stop syncthing.service 2>/dev/null || true"
    
    if ! "${SSH_CMD[@]}" "test -f ~/.config/syncthing/config.xml"; then
        generate_syncthing_config_device "~/.config/syncthing"
    fi
    
    local device_id
    device_id=$("${SSH_CMD[@]}" "grep -oP '(?<=<device id=\")[^\"]+' ~/.config/syncthing/config.xml | head -1")
    
    echo "Device ID: ${device_id}"
    echo "${device_id}" > "${CONFIG_DIR}/device-id.txt"
    
    log_info "Device Syncthing configured"
}

configure_sync() {
    log_step "Configuring bidirectional sync..."
    
    local host_config="${HOME}/.config/syncthing/config.xml"
    local host_id device_id
    
    host_id=$(cat "${CONFIG_DIR}/host-id.txt")
    device_id=$(cat "${CONFIG_DIR}/device-id.txt")
    
    local folder_id="zuanfeng-deploy"
    
    local temp_config="/tmp/syncthing-config-$$.xml"
    
    python3 << PYTHON_SCRIPT
import xml.etree.ElementTree as ET
import os

config_path = "${host_config}"
device_id = "${device_id}"
host_id = "${host_id}"
source_folder = "${HOST_SOURCE_FOLDER}"
folder_id = "${folder_id}"

ET.register_namespace('', 'http://syncthing.net/syncthing')

tree = ET.parse(config_path)
root = tree.getroot()

ns = {'st': 'http://syncthing.net/syncthing'}

devices = root.find('st:device', ns) is not None and root or ET.fromstring(ET.tostring(root))
device_section = root.find('st:device', ns)
if device_section is None:
    device_section = root.find('device')

existing = False
for dev in root.iter():
    if dev.tag.endswith('device') and dev.get('id') == device_id:
        existing = True
        break

if not existing:
    for elem in root:
        if elem.tag.endswith('device') and elem.get('id') == host_id:
            new_dev = ET.Element('device')
            new_dev.set('id', device_id)
            new_dev.set('name', 'jetson-device')
            new_dev.set('compression', 'metadata')
            new_dev.set('introducer', 'false')
            new_dev.set('skipIntroductionRemovals', 'false')
            new_dev.set('introducedBy', '')
            
            addr = ET.SubElement(new_dev, 'address')
            addr.text = 'dynamic'
            
            pausable = ET.SubElement(new_dev, 'pausable')
            pausable.text = 'true'
            
            autoAcceptFolders = ET.SubElement(new_dev, 'autoAcceptFolders')
            autoAcceptFolders.text = 'false'
            
            maxSendKbps = ET.SubElement(new_dev, 'maxSendKbps')
            maxSendKbps.text = '0'
            
            maxRecvKbps = ET.SubElement(new_dev, 'maxRecvKbps')
            maxRecvKbps.text = '0'
            
            maxRequestKiB = ET.SubElement(new_dev, 'maxRequestKiB')
            maxRequestKiB.text = '0'
            
            untrusted = ET.SubElement(new_dev, 'untrusted')
            untrusted.text = 'false'
            
            remoteGUIPort = ET.SubElement(new_dev, 'remoteGUIPort')
            remoteGUIPort.text = '0'
            
            root.insert(list(root).index(elem) + 1, new_dev)
            break

folder_existing = False
for folder in root.iter():
    if folder.tag.endswith('folder') and folder.get('id') == folder_id:
        folder_existing = True
        break

if not folder_existing:
    new_folder = ET.Element('folder')
    new_folder.set('id', folder_id)
    new_folder.set('label', 'zuanfeng-deploy')
    new_folder.set('path', source_folder)
    new_folder.set('type', 'sendreceive')
    new_folder.set('rescanIntervalS', '10')
    new_folder.set('fsWatcherEnabled', 'true')
    new_folder.set('fsWatcherDelayS', '2')
    new_folder.set('ignorePerms', 'false')
    new_folder.set('autoNormalize', 'true')
    
    filesystemtype = ET.SubElement(new_folder, 'filesystemType')
    filesystemtype.text = 'basic'
    
    minDiskFree = ET.SubElement(new_folder, 'minDiskFree')
    minDiskFree.set('unit', '%')
    minDiskFree.text = '1'
    
    versioning = ET.SubElement(new_folder, 'versioning')
    versioning.set('type', 'trashcan')
    cleanupIntervalS = ET.SubElement(versioning, 'cleanupIntervalS')
    cleanupIntervalS.text = '3600'
    params = ET.SubElement(versioning, 'param')
    params.set('key', 'keep')
    params.set('val', '2')
    
    copiers = ET.SubElement(new_folder, 'copiers')
    copiers.text = '0'
    pullers = ET.SubElement(new_folder, 'pullers')
    pullers.text = '0'
    hashers = ET.SubElement(new_folder, 'hashers')
    hashers.text = '0'
    order = ET.SubElement(new_folder, 'order')
    order.text = 'random'
    ignoreDelete = ET.SubElement(new_folder, 'ignoreDelete')
    ignoreDelete.text = 'false'
    scanProgressIntervalS = ET.SubElement(new_folder, 'scanProgressIntervalS')
    scanProgressIntervalS.text = '0'
    pullerPauseS = ET.SubElement(new_folder, 'pullerPauseS')
    pullerPauseS.text = '0'
    maxConflicts = ET.SubElement(new_folder, 'maxConflicts')
    maxConflicts.text = '-1'
    disableSparseFiles = ET.SubElement(new_folder, 'disableSparseFiles')
    disableSparseFiles.text = 'false'
    disableTempIndexes = ET.SubElement(new_folder, 'disableTempIndexes')
    disableTempIndexes.text = 'false'
    paused = ET.SubElement(new_folder, 'paused')
    paused.text = 'false'
    weakHashThresholdPct = ET.SubElement(new_folder, 'weakHashThresholdPct')
    weakHashThresholdPct.text = '25'
    markerName = ET.SubElement(new_folder, 'markerName')
    markerName.text = '.stfolder'
    copyOwnershipFromParent = ET.SubElement(new_folder, 'copyOwnershipFromParent')
    copyOwnershipFromParent.text = 'false'
    modTimeWindowS = ET.SubElement(new_folder, 'modTimeWindowS')
    modTimeWindowS.text = '0'
    
    for dev_id in [host_id, device_id]:
        device_elem = ET.SubElement(new_folder, 'device')
        device_elem.set('id', dev_id)
        device_elem.set('introducedBy', '')
        encryptionPassword = ET.SubElement(device_elem, 'encryptionPassword')
        encryptionPassword.text = ''
    
    root.append(new_folder)

options = root.find('st:options', ns)
if options is None:
    options = root.find('options')
if options is not None:
    for child in options:
        if child.tag.endswith('listenAddresses'):
            child.text = 'tcp://:22000, quic://:22000, dynamic+https://relays.syncthing.net/endpoint'
        if child.tag.endswith('globalAnnounceEnabled'):
            child.text = 'true'
        if child.tag.endswith('localAnnounceEnabled'):
            child.text = 'true'

tree.write('${temp_config}', xml_declaration=True, encoding='UTF-8')
PYTHON_SCRIPT
    
    if [[ -f "$temp_config" ]]; then
        cp "$temp_config" "$host_config"
        rm -f "$temp_config"
        log_info "Host config updated with device and folder"
    fi
    
    NV_SSH_EXTRA_OPTS=(-o BatchMode=yes -o ConnectTimeout=30)
    fn_nv_reset_ssh
    fn_nv_ensure_ssh
    
    local remote_device_id
    remote_device_id=$("${SSH_CMD[@]}" "grep -oP '(?<=<device id=\")[^\"]+' ~/.config/syncthing/config.xml | head -1")
    
    "${SSH_CMD[@]}" "mkdir -p ~/.config/syncthing"
    
    "${SSH_CMD[@]}" "python3 << 'REMOTEPYTHON'
import xml.etree.ElementTree as ET
import os

config_path = os.path.expanduser('~/.config/syncthing/config.xml')
host_id = '${host_id}'
device_id = '${remote_device_id}'
target_folder = '${DEVICE_TARGET_FOLDER}'
folder_id = '${folder_id}'

ET.register_namespace('', 'http://syncthing.net/syncthing')

tree = ET.parse(config_path)
root = tree.getroot()

existing = False
for dev in root.iter():
    if dev.tag.endswith('device') and dev.get('id') == host_id:
        existing = True
        break

if not existing:
    for elem in root:
        if elem.tag.endswith('device') and elem.get('id') == device_id:
            new_dev = ET.Element('device')
            new_dev.set('id', host_id)
            new_dev.set('name', 'host-machine')
            new_dev.set('compression', 'metadata')
            new_dev.set('introducer', 'false')
            new_dev.set('skipIntroductionRemovals', 'false')
            new_dev.set('introducedBy', '')
            
            addr = ET.SubElement(new_dev, 'address')
            addr.text = 'dynamic'
            
            pausable = ET.SubElement(new_dev, 'pausable')
            pausable.text = 'true'
            
            root.insert(list(root).index(elem) + 1, new_dev)
            break

folder_existing = False
for folder in root.iter():
    if folder.tag.endswith('folder') and folder.get('id') == folder_id:
        folder_existing = True
        break

if not folder_existing:
    new_folder = ET.Element('folder')
    new_folder.set('id', folder_id)
    new_folder.set('label', 'zuanfeng-deploy')
    new_folder.set('path', target_folder)
    new_folder.set('type', 'sendreceive')
    new_folder.set('rescanIntervalS', '10')
    new_folder.set('fsWatcherEnabled', 'true')
    new_folder.set('fsWatcherDelayS', '2')
    new_folder.set('ignorePerms', 'false')
    new_folder.set('autoNormalize', 'true')
    
    filesystemtype = ET.SubElement(new_folder, 'filesystemType')
    filesystemtype.text = 'basic'
    
    minDiskFree = ET.SubElement(new_folder, 'minDiskFree')
    minDiskFree.set('unit', '%')
    minDiskFree.text = '1'
    
    versioning = ET.SubElement(new_folder, 'versioning')
    versioning.set('type', 'trashcan')
    cleanupIntervalS = ET.SubElement(versioning, 'cleanupIntervalS')
    cleanupIntervalS.text = '3600'
    params = ET.SubElement(versioning, 'param')
    params.set('key', 'keep')
    params.set('val', '2')
    
    copiers = ET.SubElement(new_folder, 'copiers')
    copiers.text = '0'
    pullers = ET.SubElement(new_folder, 'pullers')
    pullers.text = '0'
    hashers = ET.SubElement(new_folder, 'hashers')
    hashers.text = '0'
    order = ET.SubElement(new_folder, 'order')
    order.text = 'random'
    ignoreDelete = ET.SubElement(new_folder, 'ignoreDelete')
    ignoreDelete.text = 'false'
    scanProgressIntervalS = ET.SubElement(new_folder, 'scanProgressIntervalS')
    scanProgressIntervalS.text = '0'
    pullerPauseS = ET.SubElement(new_folder, 'pullerPauseS')
    pullerPauseS.text = '0'
    maxConflicts = ET.SubElement(new_folder, 'maxConflicts')
    maxConflicts.text = '-1'
    disableSparseFiles = ET.SubElement(new_folder, 'disableSparseFiles')
    disableSparseFiles.text = 'false'
    disableTempIndexes = ET.SubElement(new_folder, 'disableTempIndexes')
    disableTempIndexes.text = 'false'
    paused = ET.SubElement(new_folder, 'paused')
    paused.text = 'false'
    weakHashThresholdPct = ET.SubElement(new_folder, 'weakHashThresholdPct')
    weakHashThresholdPct.text = '25'
    markerName = ET.SubElement(new_folder, 'markerName')
    markerName.text = '.stfolder'
    copyOwnershipFromParent = ET.SubElement(new_folder, 'copyOwnershipFromParent')
    copyOwnershipFromParent.text = 'false'
    modTimeWindowS = ET.SubElement(new_folder, 'modTimeWindowS')
    modTimeWindowS.text = '0'
    
    for dev_id in [device_id, host_id]:
        device_elem = ET.SubElement(new_folder, 'device')
        device_elem.set('id', dev_id)
        device_elem.set('introducedBy', '')
        encryptionPassword = ET.SubElement(device_elem, 'encryptionPassword')
        encryptionPassword.text = ''
    
    root.append(new_folder)

tree.write(os.path.expanduser('~/.config/syncthing/config.xml'), xml_declaration=True, encoding='UTF-8')
REMOTEPYTHON"
    
    log_info "Device config updated"
}

setup_gui_access() {
    log_step "Configuring GUI access..."
    
    local host_config="${HOME}/.config/syncthing/config.xml"
    
    if grep -q '127.0.0.1:8384' "$host_config"; then
        sed -i 's|<address>127.0.0.1:8384</address>|<address>0.0.0.0:8384</address>|g' "$host_config"
        log_info "Host GUI accessible on all interfaces (port 8384)"
    fi
    
    NV_SSH_EXTRA_OPTS=(-o BatchMode=yes -o ConnectTimeout=30)
    fn_nv_reset_ssh
    fn_nv_ensure_ssh
    
    "${SSH_CMD[@]}" "sed -i 's|<address>127.0.0.1:8384</address>|<address>0.0.0.0:8384</address>|g' ~/.config/syncthing/config.xml 2>/dev/null || true"
    
    log_info "GUI access configured"
}

configure_device_ufw() {
    log_step "Configuring UFW on device (allow all on l4tbr0, wlP1p1s0, docker0)..."
    NV_SSH_EXTRA_OPTS=(-o BatchMode=yes -o ConnectTimeout=30)
    fn_nv_reset_ssh
    fn_nv_ensure_ssh

    fn_nv_run_remote_sudo_bash "apt install -y ufw" 2>/dev/null || true

    "${SSH_CMD[@]}" "sudo ufw status | grep -q 'Status: active'" 2>/dev/null
    local was_active=$?

    fn_nv_run_remote_sudo_bash "ufw allow in on l4tbr0 comment 'syncthing-usb' && ufw allow in on wlP1p1s0 comment 'syncthing-wifi' && ufw allow in on docker0 comment 'docker' && ufw allow 22/tcp comment 'ssh'" 2>/dev/null

    if [[ $was_active -ne 0 ]]; then
        log_info "Enabling UFW..."
        fn_nv_run_remote_sudo_bash "ufw --force enable"
    else
        fn_nv_run_remote_sudo_bash "ufw reload"
    fi

    fn_nv_run_remote_sudo_bash "ufw status verbose"
    log_info "Device UFW configured"
}

enable_services() {
    log_step "Enabling Syncthing services..."
    
    systemctl --user enable syncthing.service
    systemctl --user restart syncthing.service
    sleep 2
    
    if systemctl --user is-active --quiet syncthing.service; then
        log_info "Host Syncthing service started"
    else
        log_error "Host Syncthing service failed to start"
        journalctl --user -u syncthing.service --no-pager -n 20
        return 1
    fi
    
    NV_SSH_EXTRA_OPTS=(-o BatchMode=yes -o ConnectTimeout=30)
    fn_nv_reset_ssh
    fn_nv_ensure_ssh
    
    "${SSH_CMD[@]}" "systemctl --user enable syncthing.service && systemctl --user restart syncthing.service"
    sleep 2
    
    log_info "Device Syncthing service started"
}

show_status() {
    echo ""
    echo "=========================================="
    echo -e "${GREEN}Syncthing Bidirectional Sync Setup Complete${NC}"
    echo "=========================================="
    echo ""
    echo "Sync folders:"
    echo "  Host:   ${HOST_SOURCE_FOLDER}"
    echo "  Device: ${DEVICE_USER}@${DEVICE_IP}:${DEVICE_TARGET_FOLDER}"
    echo ""
    echo "Web UI:"
    echo "  Host:   http://localhost:8384"
    echo "  Device: http://${DEVICE_IP}:8384"
    echo ""
    echo "Commands:"
    echo "  Host status:   systemctl --user status syncthing"
    echo "  Host logs:     journalctl --user -u syncthing -f"
    echo "  Device status: ${SCRIPT_DIR}/device-status.sh"
    echo ""
    echo "First time setup:"
    echo "  1. Open http://localhost:8384 on host"
    echo "  2. Open http://${DEVICE_IP}:8384 on device"
    echo "  3. Add each device to the other's device list"
    echo "  4. Share the 'zuanfeng-deploy' folder with the other device"
    echo ""
}

show_help() {
    cat << EOF
Usage: $0 [OPTIONS]

Setup Syncthing bidirectional sync between host and device.

Options:
    -h, --help                     Show this help message
    --device-ip IP                 Override DEVICE_IP
    --device-user USER             Override DEVICE_USER
    --ssh-key PATH                 Override SSH_KEY
    --source-folder PATH           Override HOST_SOURCE_FOLDER
    --device-target-folder PATH    Override DEVICE_TARGET_FOLDER
    --uninstall                    Remove Syncthing services
EOF
}

uninstall() {
    log_step "Stopping Syncthing services..."
    systemctl --user stop syncthing.service 2>/dev/null || true
    systemctl --user disable syncthing.service 2>/dev/null || true
    
    NV_SSH_EXTRA_OPTS=(-o BatchMode=yes -o ConnectTimeout=30)
    fn_nv_reset_ssh
    fn_nv_ensure_ssh
    "${SSH_CMD[@]}" "systemctl --user stop syncthing.service 2>/dev/null || true"
    "${SSH_CMD[@]}" "systemctl --user disable syncthing.service 2>/dev/null || true"
    
    log_info "Syncthing services stopped (configs preserved)"
    log_info "To fully remove: rm -rf ~/.config/syncthing"
}

main() {
    local do_uninstall=0

    while [[ $# -gt 0 ]]; do
        case $1 in
            -h|--help)
                show_help
                exit 0
                ;;
            --device-ip)
                DEVICE_IP="$2"
                shift 2
                ;;
            --device-user)
                DEVICE_USER="$2"
                shift 2
                ;;
            --ssh-key)
                SSH_KEY="$2"
                shift 2
                ;;
            --source-folder)
                HOST_SOURCE_FOLDER="$2"
                shift 2
                ;;
            --device-target-folder)
                DEVICE_TARGET_FOLDER="$2"
                shift 2
                ;;
            --uninstall)
                do_uninstall=1
                shift
                ;;
            *)
                log_error "Unknown option: $1"
                show_help
                exit 1
                ;;
        esac
    done

    if [[ "$do_uninstall" -eq 1 ]]; then
        uninstall
        exit 0
    fi

    fn_nv_reset_ssh
    mkdir -p "$CONFIG_DIR"
    
    echo "Setting up bidirectional sync with Syncthing"
    echo "Source: ${HOST_SOURCE_FOLDER}"
    echo "Target: ${DEVICE_USER}@${DEVICE_IP}:${DEVICE_TARGET_FOLDER}"
    echo ""

    check_ssh
    ensure_device_sudo
    ensure_device_route
    install_syncthing_host
    install_syncthing_device
    setup_syncthing_host
    setup_syncthing_device
    configure_sync
    setup_gui_access
    configure_device_ufw
    enable_services
    show_status
}

main "$@"
