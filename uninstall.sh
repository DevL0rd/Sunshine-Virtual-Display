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
    printf 'Run this uninstaller as the desktop user, not root. It will use sudo where needed.\n' >&2
    exit 1
fi
target_home="$HOME"
state_dir="$target_home/.local/state/sunshine-virtual-display"
backup_root="$state_dir/backups"
sunshine_config="$target_home/.config/sunshine/sunshine.conf"
original_sunshine="$state_dir/original-sunshine.json"
user_config="$target_home/.config/sunshine-virtual-display/config"
say() {
    printf '\n==> %s\n' "$*"
}
fail() {
    printf 'Error: %s\n' "$*" >&2
    exit 1
}
command -v sudo >/dev/null 2>&1 || fail 'sudo is required'
installed=0
for item in \
    "$target_home/.local/bin/sunshine-vdisplay-up" \
    "$target_home/.config/systemd/user/sunshine-virtual-display-init.service" \
    "$user_config" \
    "$original_sunshine" \
    /usr/local/lib/sunshine-virtual-display/rebuild-edid \
    /usr/local/lib/sunshine-virtual-display/gpu-clock \
    /etc/sudoers.d/sunshine-virtual-display-gpu-clock \
    /etc/sunshine-virtual-display/config \
    /usr/lib/firmware/edid/sunshine-virtual-display.bin \
    /etc/limine-entry-tool.d/91-sunshine-virtual-display.conf \
    /etc/mkinitcpio.conf.d/91-sunshine-virtual-display.conf; do
    if [[ -e "$item" ]]; then
        installed=1
        break
    fi
done
if ((installed == 0)); then
    printf 'Linux-Sunshine-Virtual-Display is already uninstalled.\n'
    exit 0
fi
sunshine_service=""
if [[ -r "$user_config" ]]; then
    sunshine_service="$(sed -n 's/^SUNSHINE_SERVICE=//p' "$user_config" | head -n 1)"
fi
if [[ -z "$sunshine_service" ]] && systemctl --user cat app-dev.lizardbyte.app.Sunshine.service >/dev/null 2>&1; then
    sunshine_service=app-dev.lizardbyte.app.Sunshine.service
elif [[ -z "$sunshine_service" ]] && systemctl --user cat sunshine.service >/dev/null 2>&1; then
    sunshine_service=sunshine.service
fi
say 'The managed virtual display, boot configuration, hooks, and services will be removed'
if ((dry_run)); then
    printf '\nDry run complete. Sunshine settings owned by this project would be restored and unrelated settings would remain untouched.\n'
    exit 0
fi
sudo -v
if ((snapshot)) && command -v snapper >/dev/null 2>&1 && sudo snapper -c root get-config >/dev/null 2>&1; then
    snapshot_number="$(sudo snapper -c root create --type single --cleanup-algorithm number --description 'Before Linux-Sunshine-Virtual-Display uninstall' --print-number)"
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
sudo chown -R "$(id -un):$(id -gn)" "$backup_dir"
if [[ -x "$target_home/.local/bin/sunshine-vdisplay-down" ]]; then
    runtime_dir="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/sunshine-virtual-display"
    install -d -m 700 "$runtime_dir"
    printf '1\n' > "$runtime_dir/session-count"
    "$target_home/.local/bin/sunshine-vdisplay-down" || true
fi
systemctl --user disable --now sunshine-virtual-display-init.service >/dev/null 2>&1 || true
systemctl --user stop sunshine-vdisplay-inhibit.service >/dev/null 2>&1 || true
if [[ -e "$original_sunshine" ]]; then
    python3 "$repo_dir/src/system/configure-sunshine.py" uninstall "$sunshine_config" "$original_sunshine" "$target_home"
fi
if [[ -n "$sunshine_service" ]]; then
    rm -f "$target_home/.config/systemd/user/$sunshine_service.d/virtual-display.conf"
    rmdir "$target_home/.config/systemd/user/$sunshine_service.d" 2>/dev/null || true
fi
rm -f "$target_home/.config/systemd/user/sunshine-virtual-display-init.service"
rm -f "$target_home/.local/bin/sunshine-vdisplay-bind-touchscreen"
rm -f "$target_home/.local/bin/sunshine-vdisplay-common"
rm -f "$target_home/.local/bin/sunshine-vdisplay-down"
rm -f "$target_home/.local/bin/sunshine-vdisplay-pick-mode"
rm -f "$target_home/.local/bin/sunshine-vdisplay-reset"
rm -f "$target_home/.local/bin/sunshine-vdisplay-up"
rm -f "$target_home/.config/sunshine-virtual-display/config" "$target_home/.config/sunshine-virtual-display/modes.txt"
rmdir "$target_home/.config/sunshine-virtual-display" 2>/dev/null || true
rm -f "$state_dir/pending-modes.txt" "$state_dir/pending-modes.lock" "$state_dir/learned-modes.txt" "$state_dir/reboot-required" "$state_dir/events.log"
sudo systemctl disable --now sunshine-vdisplay-edid.path >/dev/null 2>&1 || true
sudo rm -f /etc/systemd/system/sunshine-vdisplay-edid.path
sudo rm -f /etc/systemd/system/sunshine-vdisplay-edid.service
sudo rm -f /etc/limine-entry-tool.d/91-sunshine-virtual-display.conf
sudo rm -f /etc/mkinitcpio.conf.d/91-sunshine-virtual-display.conf
sudo rm -f /usr/lib/firmware/edid/sunshine-virtual-display.bin
sudo rm -f /usr/local/lib/sunshine-virtual-display/generate-edid.py
sudo rm -f /usr/local/lib/sunshine-virtual-display/rebuild-edid
sudo rm -f /usr/local/lib/sunshine-virtual-display/gpu-clock
sudo rm -f /etc/sudoers.d/sunshine-virtual-display-gpu-clock
sudo rm -f /etc/sunshine-virtual-display/config /etc/sunshine-virtual-display/modes.txt
sudo rm -f /var/lib/sunshine-virtual-display/modes.txt /var/lib/sunshine-virtual-display/sunshine-virtual-display.bin.new /var/lib/sunshine-virtual-display/edid-decode.txt
sudo rmdir /usr/local/lib/sunshine-virtual-display /etc/sunshine-virtual-display /var/lib/sunshine-virtual-display 2>/dev/null || true
if sudo grep -q 'sunshine-virtual-display.bin' /etc/default/limine; then
    sudo sed -i '\|sunshine-virtual-display.bin|d' /etc/default/limine
fi
if sudo grep -q 'sunshine-virtual-display.bin' /etc/mkinitcpio.conf; then
    sudo sed -i '/^FILES=/ s|/usr/lib/firmware/edid/sunshine-virtual-display.bin||g' /etc/mkinitcpio.conf
fi
sudo systemctl daemon-reload
systemctl --user daemon-reload
if command -v limine-mkinitcpio >/dev/null 2>&1; then
    sudo limine-mkinitcpio
else
    sudo mkinitcpio -P
fi
if [[ -n "$sunshine_service" ]] && systemctl --user is-active --quiet "$sunshine_service"; then
    systemctl --user restart "$sunshine_service"
fi
printf '\nUninstalled successfully. Reboot to remove the forced connector from the running session.\nBackup: %s\n' "$backup_dir"
