#!/usr/bin/env bash
set -euo pipefail
repo_dir="$(cd "$(dirname "$0")" && pwd)"
dry_run=0
snapshot=1
for argument in "$@"; do
    case "$argument" in
        --dry-run) dry_run=1 ;;
        --no-snapshot) snapshot=0 ;;
        *) printf 'Unknown option: %s\n' "$argument" >&2; exit 2 ;;
    esac
done
if ((EUID == 0)); then
    printf 'Run this installer as the desktop user, not root. It will use sudo where needed.\n' >&2
    exit 1
fi
target_user="$(id -un)"
target_group="$(id -gn)"
target_home="$HOME"
state_dir="$target_home/.local/state/sunshine-virtual-display"
backup_root="$state_dir/backups"
sunshine_config="$target_home/.config/sunshine/sunshine.conf"
original_sunshine="$state_dir/original-sunshine.json"
firmware=/usr/lib/firmware/edid/sunshine-virtual-display.bin
say() {
    printf '\n==> %s\n' "$*"
}
fail() {
    printf 'Error: %s\n' "$*" >&2
    exit 1
}
command -v sudo >/dev/null 2>&1 || fail 'sudo is required'
command -v pacman >/dev/null 2>&1 || fail 'This installer currently supports Arch/CachyOS with pacman'
command -v sunshine >/dev/null 2>&1 || fail 'Sunshine must already be installed; this project does not install or update it'
command -v limine-mkinitcpio >/dev/null 2>&1 || fail 'limine-mkinitcpio-hook is required'
[[ -f /etc/default/limine ]] || fail 'Limine configuration was not found at /etc/default/limine'
packages=()
command -v python3 >/dev/null 2>&1 || packages+=(python)
command -v jq >/dev/null 2>&1 || packages+=(jq)
command -v kscreen-doctor >/dev/null 2>&1 || packages+=(libkscreen)
command -v kde-inhibit >/dev/null 2>&1 || packages+=(kde-cli-tools)
command -v edid-decode >/dev/null 2>&1 || packages+=(v4l-utils)
command -v flock >/dev/null 2>&1 || packages+=(util-linux)
requested_output="${VIRTUAL_OUTPUT:-}"
if [[ -z "$requested_output" && -r /etc/sunshine-virtual-display/config ]]; then
    requested_output="$(sed -n 's/^VIRTUAL_OUTPUT=//p' /etc/sunshine-virtual-display/config | head -n 1)"
fi
if [[ -z "$requested_output" && -r "$sunshine_config" ]]; then
    requested_output="$(sed -nE 's/^[[:space:]]*output_name[[:space:]]*=[[:space:]]*([^[:space:]]+).*$/\1/p' "$sunshine_config" | head -n 1)"
fi
if [[ -z "$requested_output" ]]; then
    requested_output="$(grep -hoE 'drm.edid_firmware=[A-Za-z0-9-]+:edid/sunshine-virtual-display.bin' /etc/default/limine /etc/limine-entry-tool.d/*.conf 2>/dev/null | head -n 1 | cut -d= -f2 | cut -d: -f1 || true)"
fi
if [[ -z "$requested_output" ]]; then
    candidates=()
    for status_file in /sys/class/drm/card*-*/status; do
        [[ -r "$status_file" && "$(<"$status_file")" == disconnected ]] || continue
        connector_dir="${status_file%/status}"
        card="$(basename "$connector_dir")"
        card="${card%%-*}"
        driver="$(basename "$(readlink -f "/sys/class/drm/$card/device/driver" 2>/dev/null || true)")"
        [[ "$driver" == nvidia ]] || continue
        connector="$(basename "$connector_dir" | sed -E 's/^card[0-9]+-//')"
        [[ "$connector" == DP-* ]] && candidates=("$connector" "${candidates[@]}") || candidates+=("$connector")
    done
    ((${#candidates[@]})) || fail 'No disconnected NVIDIA connector was found; set VIRTUAL_OUTPUT explicitly'
    requested_output="${candidates[0]}"
fi
connector_path=""
for candidate in /sys/class/drm/card*-"$requested_output"; do
    [[ -e "$candidate" ]] || continue
    card="$(basename "$candidate")"
    card="${card%%-*}"
    driver="$(basename "$(readlink -f "/sys/class/drm/$card/device/driver" 2>/dev/null || true)")"
    if [[ "$driver" == nvidia ]]; then
        connector_path="$candidate"
        break
    fi
done
[[ -n "$connector_path" ]] || fail "$requested_output is not an NVIDIA DRM connector"
if systemctl --user cat app-dev.lizardbyte.app.Sunshine.service >/dev/null 2>&1; then
    sunshine_service=app-dev.lizardbyte.app.Sunshine.service
elif systemctl --user cat sunshine.service >/dev/null 2>&1; then
    sunshine_service=sunshine.service
else
    fail 'No Sunshine user service was found'
fi
say "Virtual connector: $requested_output"
say "Sunshine service: $sunshine_service"
if ((${#packages[@]})); then
    say "Missing packages: ${packages[*]}"
fi
if ((dry_run)); then
    printf '\nDry run complete. Installation would update the managed virtual-display files, rebuild both Limine initramfs entries, and preserve existing custom modes. Sunshine itself would not be installed or updated.\n'
    exit 0
fi
sudo -v
if ((${#packages[@]})); then
    sudo pacman -S --needed --noconfirm "${packages[@]}"
fi
if ((snapshot)) && command -v snapper >/dev/null 2>&1 && sudo snapper -c root get-config >/dev/null 2>&1; then
    snapshot_number="$(sudo snapper -c root create --type single --cleanup-algorithm number --description 'Before Linux-Sunshine-Virtual-Display install or update' --print-number)"
    say "Created Snapper snapshot $snapshot_number"
fi
timestamp="$(date +%Y%m%d-%H%M%S)"
backup_dir="$backup_root/$timestamp-$$"
install -d -m 700 "$backup_dir"
[[ -f "$sunshine_config" ]] && cp -a "$sunshine_config" "$backup_dir/sunshine.conf"
[[ -f "$target_home/.config/sunshine/apps.json" ]] && cp -a "$target_home/.config/sunshine/apps.json" "$backup_dir/apps.json"
for item in /etc/default/limine /etc/mkinitcpio.conf /boot/limine.conf; do
    [[ -f "$item" ]] || continue
    sudo cp -a "$item" "$backup_dir/$(tr '/' '-' <<< "${item#/}")"
done
sudo chown -R "$target_user:$target_group" "$backup_dir"
work_dir="$(mktemp -d /tmp/linux-sunshine-vdisplay.XXXXXX)"
trap 'rm -rf "$work_dir"' EXIT
existing_install=0
if [[ -e /usr/local/lib/sunshine-virtual-display/rebuild-edid || -e "$target_home/.local/bin/sunshine-vdisplay-up" ]]; then
    existing_install=1
fi
learned_modes="$state_dir/learned-modes.txt"
if [[ -r "$learned_modes" ]]; then
    cat "$learned_modes" > "$work_dir/observed-modes.txt"
elif [[ -r "$state_dir/events.log" ]]; then
    sed -nE 's/.*request=([0-9]{3,4}x[0-9]{3,4}@[0-9]{2,3}([.][0-9]+)?).*/\1/p' "$state_dir/events.log" > "$work_dir/observed-modes.txt"
else
    : > "$work_dir/observed-modes.txt"
fi
awk 'NR == FNR { defaults[$0] = 1; next } NF && !defaults[$0] && !seen[$0]++' "$repo_dir/config/modes.txt" "$work_dir/observed-modes.txt" > "$work_dir/learned-modes.txt"
{
    cat "$repo_dir/config/modes.txt"
    cat "$work_dir/learned-modes.txt"
} | awk 'NF && !seen[$0]++' > "$work_dir/modes.txt"
python3 "$repo_dir/src/system/generate-edid.py" "$work_dir/modes.txt" "$work_dir/sunshine-virtual-display.bin"
edid-decode --check "$work_dir/sunshine-virtual-display.bin" > "$work_dir/edid-check.txt"
install -d -m 755 "$target_home/.local/bin"
install -d -m 700 "$target_home/.config/sunshine-virtual-display" "$state_dir"
install -m 755 "$repo_dir"/src/user/sunshine-vdisplay-* "$target_home/.local/bin/"
printf 'VIRTUAL_OUTPUT=%q\nSTATE_DIR=%q\nSUNSHINE_SERVICE=%q\n' "$requested_output" "$state_dir" "$sunshine_service" > "$work_dir/user-config"
install -m 600 "$work_dir/user-config" "$target_home/.config/sunshine-virtual-display/config"
install -m 600 "$work_dir/modes.txt" "$target_home/.config/sunshine-virtual-display/modes.txt"
install -m 600 "$work_dir/learned-modes.txt" "$learned_modes"
touch "$state_dir/pending-modes.txt" "$state_dir/pending-modes.lock"
chmod 600 "$learned_modes" "$state_dir/pending-modes.txt" "$state_dir/pending-modes.lock"
adopt=()
if ((existing_install)) && [[ ! -e "$original_sunshine" ]]; then
    adopt+=(--adopt-existing)
fi
python3 "$repo_dir/src/system/configure-sunshine.py" install "$sunshine_config" "$original_sunshine" "$target_home" "$requested_output" "${adopt[@]}"
install -d -m 755 "$target_home/.config/systemd/user/$sunshine_service.d"
install -m 644 "$repo_dir/systemd/user/sunshine-virtual-display-init.service" "$target_home/.config/systemd/user/sunshine-virtual-display-init.service"
install -m 644 "$repo_dir/systemd/user/sunshine-service-dropin.conf" "$target_home/.config/systemd/user/$sunshine_service.d/virtual-display.conf"
printf 'TARGET_USER=%q\nTARGET_GROUP=%q\nTARGET_HOME=%q\nVIRTUAL_OUTPUT=%q\n' "$target_user" "$target_group" "$target_home" "$requested_output" > "$work_dir/system-config"
sed "s|@STATE_DIR@|$state_dir|g" "$repo_dir/systemd/system/sunshine-vdisplay-edid.path.in" > "$work_dir/sunshine-vdisplay-edid.path"
printf 'KERNEL_CMDLINE[default]+=" drm.edid_firmware=%s:edid/sunshine-virtual-display.bin video=%s:e"\n' "$requested_output" "$requested_output" > "$work_dir/limine-dropin"
printf 'FILES+=(/usr/lib/firmware/edid/sunshine-virtual-display.bin)\n' > "$work_dir/mkinitcpio-dropin"
sudo install -d -m 755 /usr/local/lib/sunshine-virtual-display /etc/sunshine-virtual-display /usr/lib/firmware/edid /var/lib/sunshine-virtual-display /etc/limine-entry-tool.d /etc/mkinitcpio.conf.d
sudo install -m 755 "$repo_dir/src/system/generate-edid.py" /usr/local/lib/sunshine-virtual-display/generate-edid.py
sudo install -m 755 "$repo_dir/src/system/rebuild-edid" /usr/local/lib/sunshine-virtual-display/rebuild-edid
sudo install -m 644 "$work_dir/system-config" /etc/sunshine-virtual-display/config
sudo install -m 644 "$work_dir/modes.txt" /etc/sunshine-virtual-display/modes.txt
sudo install -m 644 "$work_dir/sunshine-virtual-display.bin" "$firmware"
sudo install -m 644 "$work_dir/limine-dropin" /etc/limine-entry-tool.d/91-sunshine-virtual-display.conf
sudo install -m 644 "$work_dir/mkinitcpio-dropin" /etc/mkinitcpio.conf.d/91-sunshine-virtual-display.conf
sudo install -m 644 "$work_dir/sunshine-vdisplay-edid.path" /etc/systemd/system/sunshine-vdisplay-edid.path
sudo install -m 644 "$repo_dir/systemd/system/sunshine-vdisplay-edid.service" /etc/systemd/system/sunshine-vdisplay-edid.service
if sudo grep -q 'sunshine-virtual-display.bin' /etc/default/limine; then
    sudo sed -i '\|sunshine-virtual-display.bin|d' /etc/default/limine
fi
if sudo grep -q 'sunshine-virtual-display.bin' /etc/mkinitcpio.conf; then
    sudo sed -i '/^FILES=/ s|/usr/lib/firmware/edid/sunshine-virtual-display.bin||g' /etc/mkinitcpio.conf
fi
sudo systemctl daemon-reload
sudo systemctl enable --now sunshine-vdisplay-edid.path
systemctl --user daemon-reload
systemctl --user enable sunshine-virtual-display-init.service
sudo limine-mkinitcpio
if [[ "$(<"$connector_path/status")" == connected ]]; then
    systemctl --user restart "$sunshine_service"
    say 'Sunshine restarted with the updated configuration'
else
    say 'Sunshine was left running because the forced connector becomes available only after reboot'
fi
printf '\nInstalled or updated successfully. Reboot to activate a newly configured EDID.\nBackup: %s\n' "$backup_dir"
