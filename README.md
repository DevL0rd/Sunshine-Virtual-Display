# Linux Sunshine Virtual Display

Linux Sunshine Virtual Display turns an unused NVIDIA connector into a dedicated headless display for Sunshine on KDE Plasma Wayland. A Moonlight client gets a display matching its requested size and frame rate while the currently connected physical screens are temporarily disabled, regardless of which monitor or laptop panel happens to be in use.

It is designed for CachyOS and Arch Linux systems using NVIDIA, Plasma 6, Sunshine, `mkinitcpio`, and Limine. The compact default mode bank covers common 1080p through 2K resolutions at 60 and 120 Hz. Other client resolutions and refresh rates are learned individually when requested.

## What it does

- Generates and validates an EDID with DisplayID timings, embeds it in the initramfs, and forces it onto an unused NVIDIA output at boot.
- Configures Sunshine for KMS capture, single-pass NVENC encoding, the virtual output, and automatic session hooks.
- Selects the closest advertised mode from `SUNSHINE_CLIENT_WIDTH`, `SUNSHINE_CLIENT_HEIGHT`, and `SUNSHINE_CLIENT_FPS` when a stream starts.
- Saves the live KScreen layout, enables only the virtual display during the stream, and restores the prior physical layout afterward.
- Waits for Sunshine's virtual touchscreen and maps it to the active virtual display through KWin.
- Handles changing docks and monitors generically instead of naming a particular laptop panel or external display.
- Keeps a multi-client reference count and inhibits sleep while streaming.
- Queues a previously unknown client mode, rebuilds the EDID safely, and records that a reboot is required before that exact mode can be used.
- Creates timestamped configuration backups and, when available, a Snapper snapshot before install, update, or uninstall.

## Important limits

This is not a dynamically resizable virtual framebuffer. NVIDIA's forced-EDID path exposes a finite collection of modes at boot. An arbitrary valid client resolution can be learned automatically, but the first connection uses the closest existing mode and the new exact mode becomes available after reboot.

The EDID generator accepts dimensions from 320 through 4095 pixels and refresh rates from 24 through 240 Hz. It encodes every configured mode as a DisplayID Type I detailed timing, whose wider pixel-clock field supports high-bandwidth modes that legacy EDID detailed timings cannot represent. The EDID 1.4 base block also contains the single preferred legacy timing required for standards compliance. Generated EDIDs are limited to NVIDIA's 2048-byte driver buffer so an oversized mode bank is rejected before it can replace a working firmware file.

HDR and VRR are not configured by this project. Changing between landscape and portrait is a resolution change; reconnect the Moonlight session so Sunshine's preparation hook can select the new mode.

## Requirements

- CachyOS or Arch Linux
- KDE Plasma 6 on Wayland
- NVIDIA proprietary driver with an unused physical connector
- Sunshine already installed as a user service
- Limine with `limine-mkinitcpio-hook`
- `sudo` access

The installer adds missing runtime packages from the normal repositories: `python`, `jq`, `libkscreen`, `kde-cli-tools`, `v4l-utils`, and `util-linux`. It does not install, update, replace, or uninstall Sunshine; your existing Sunshine package remains under its current package manager.

## Install

Run the installer as the desktop user:

```bash
git clone https://github.com/DevL0rd/Sunshine-Virtual-Display.git
cd Sunshine-Virtual-Display
./install.sh
```

The installer prefers an unused NVIDIA DisplayPort connector. To choose one explicitly:

```bash
VIRTUAL_OUTPUT=DP-3 ./install.sh
```

Reboot after the first install. The virtual connector should then appear in Plasma, remain disabled during ordinary use, and be enabled automatically for Sunshine sessions.

Preview the selected connector and required changes without modifying anything:

```bash
./install.sh --dry-run
```

## Update

The installer is also the updater. It preserves modes already learned on the machine, refreshes every managed file, reapplies the Sunshine integration, validates the EDID, and rebuilds the boot images:

```bash
git pull --ff-only
./install.sh
```

Repeated installation converges on the same configuration. Use `--no-snapshot` only when a new Snapper snapshot is not wanted.

## Uninstall

```bash
./uninstall.sh
```

The uninstaller disables the virtual display first, restores only the Sunshine keys that this project owns, removes its exact boot and service files, rebuilds the boot images, and leaves its timestamped backups in `~/.local/state/sunshine-virtual-display/backups`. It does not change the installed Sunshine package and is safe to run again after removal.

Use `./uninstall.sh --dry-run` to check whether the project is installed. Reboot afterward so the kernel stops forcing the connector.

## Modes and runtime state

The shipped mode bank is in `config/modes.txt`. Add valid `WIDTHxHEIGHT@HZ` lines there if you want them on every managed machine. A locally learned mode adds only the exact resolution and refresh rate requested. Learned modes are tracked separately in `~/.local/state/sunshine-virtual-display/learned-modes.txt` and merged into `/etc/sunshine-virtual-display/modes.txt` across installer updates.

Runtime events are written to `~/.local/state/sunshine-virtual-display/events.log`. A queued custom mode is stored in `pending-modes.txt`; after the privileged path service validates it and rebuilds the boot images, `reboot-required` appears in the same directory.

Relevant service status and logs:

```bash
systemctl --user status sunshine-virtual-display-init.service
sudo systemctl status sunshine-vdisplay-edid.path
journalctl --user -u app-dev.lizardbyte.app.Sunshine.service
sudo journalctl -u sunshine-vdisplay-edid.service
```

## Recovery

Installer backups live under `~/.local/state/sunshine-virtual-display/backups`. Snapper snapshots are also created by default when the root Snapper configuration exists. Snapshot boot entries are intentionally not modified by this project, so a pre-install snapshot remains a recovery path if the forced EDID prevents a normal boot.

## Security model

The user session may only submit strings matching the restricted mode syntax. The root rebuild service validates every request again, regenerates the complete EDID, verifies it with `edid-decode`, and only then replaces the firmware file and rebuilds the initramfs. No arbitrary user command or path is accepted by the privileged service.

## Project context

This project packages the Linux forced-EDID technique and Sunshine preparation hooks into a reversible setup for Plasma Wayland. For Sunshine itself, see the [Sunshine project](https://github.com/LizardByte/Sunshine) and its [configuration documentation](https://docs.lizardbyte.dev/projects/sunshine/latest/md_docs_2configuration.html).

## License

MIT
