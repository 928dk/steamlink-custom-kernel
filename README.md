# Steam Link

Custom firmware and scripts for Valve Steam Link device.

## Hardware Specifications

| Component | Details |
|----------|---------|
| CPU | Marvell ARM Cortex-A9 (1 GHz, single-core) |
| RAM | 498 MB (MemTotal reported by the running kernel; the earlier "256 MB" claim was wrong) |
| Storage | 1 GB NAND flash |
| Network | Gigabit Ethernet, 802.11ac WiFi |
| Video | HDMI output |
| SoC | Marvell Armada 1500 (Berlin) |

## Projects

### 1. steamlink-debian
Convert Steam Link to run Debian GNU/Linux
- Repository: https://github.com/djmuted/steamlink-debian
- Runs Debian on USB stick, no NAND modification
- Works with external rootfs

### 2. steamlink-kexec
Boot alternate kernels using kexec
- Repository: https://github.com/mill1000/steamlink-kexec
- Requires cross-compilation toolchain
- Build on Ubuntu 16.04 with gcc-4.9-arm-linux-gnueabihf

### 3. archlinux-steamlink
Run Arch Linux ARM without touching NAND
- Repository: https://github.com/coderobe/archlinux-steamlink
- 23 stars
- Uses USB stick, safe method

### 4. steamlink-sdk
Official Valve SDK for development
- Repository: https://github.com/lukas2511/steamlink-sdk
- OpenGL ES 2.0, Qt 5.8, SDL 2.0 support
- GCC toolchain included

## Installation Methods

### Method 1: USB with Arch Linux ARM (Recommended)
1. Format 2GB+ USB stick with ext3 (not ext4 - no journal support)
2. Extract Arch Linux ARM rootfs
3. Enable SSH by placing `enable_ssh.txt` on USB
4. Chroot into USB and run kexec to boot custom kernel

### Method 2: Debian on USB
1. Download Debian image from steamlink-debian releases
2. Flash to USB with balenaEtcher
3. First boot requires LAN connection
4. No HDMI output until custom kernel loads

## Working Hardware
- UART serial console
- Temperature sensor (berlin2-adc)
- I2C (i2c-designware)
- Bluetooth (btmrl, btmrvl_sdio)
- WiFi (mwifiex)
- USB
- Ethernet

## Non-Working Hardware
- Suspend/resume/halt
- Video/audio output
- DMA controller
- NAND driver (requires special handling)

## Custom Kernel

The box runs **`6.1.115-steam`**, rebuilt from upstream linux 6.1.115 with the
options Tailscale's subnet router needs (`IP_ADVANCED_ROUTER`, `IP_MULTIPLE_TABLES`,
`NETFILTER_ADVANCED`, `NETFILTER_XT_TARGET/MATCH_CONNMARK`, `NF_TABLES`) and with the
compile-time command line back to *extensible* (`CONFIG_CMDLINE_EXTEND=y`,
`CONFIG_CMDLINE_FORCE` unset) — the shipped config forced it, which is why the
`log_buf_len=256K` in `run.sh` had no effect. `CONFIG_NETCONSOLE=y` (built-in) and
`CONFIG_LOG_BUF_SHIFT=17` restore a way to watch boot.

- Inputs, hash-pinned: `kernel/SOURCE.pin`, `kernel/config-6.1.115-steam.base`,
  `kernel/config-6.1.115-steam.delta`, `kernel/build.sh` (two clean builds with the same pinned identity →
  byte-identical `zImage`)
- Install/rollback: back up the stock `/boot` set and the modules, then write the
  new ones. The wrapper used for this is local tooling and is not published;
  `docs/COMPILE_KERNEL.md` sets out the same steps by hand.
- Bring-up and verification: `docs/COMPILE_KERNEL.md`
- Subnet routing verified end-to-end 2026-10-14: a phone on mobile data (Wi-Fi off)
  reached a host on the LAN subnet through this node's subnet route, the request
  arriving at that host from this box's own LAN address (post-MASQUERADE)

> This device does not return from `systemctl reboot` reliably — power it off and on.

## Build Environment
```bash
# Setup cross-compilation
export ARCH=arm
export LOCALVERSION=-mrvl
export CROSS_COMPILE=arm-linux-gnueabihf-

# Install dependencies
sudo apt-get install pkgconf libtool build-essential automake   libncurses5-dev gcc-4.9-arm-linux-gnueabihf
```

## Useful References
- https://heap.ovh/getting-linux-on-valve-steam-link.html
- https://github.com/lukas2511/steamlink-sdk
- https://forum.doozan.com/read.php?8,46664,page=1

## Notes
Steam Link was discontinued in 2020 but can run custom Linux firmware.
The device shares hardware with Google Chromecast (similar SoC).

## License

The kernel configuration, build script and documentation here are released under
the **GNU General Public License, version 2 only** (`SPDX-License-Identifier:
GPL-2.0-only`) — the same terms as the Linux kernel whose configuration they
document. The full text is in `LICENSE`.

Copyright (c) 2026 928dk

