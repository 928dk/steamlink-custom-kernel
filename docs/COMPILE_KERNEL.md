# Compile Custom Kernel for Steam Link

This guide covers cross-compiling a Linux kernel for Valve Steam Link. Version
numbers here are examples: the deployed USB currently runs `5.10.228-steam`, and
current community images use `6.1.x`. Build and boot-test a specific version
before relying on it.

## Prerequisites

```bash
# Install build tools
sudo apt install build-essential git bc bison flex libssl-dev libelf-dev

# Install ARM cross-compiler (gcc for ARMv7 hard-float)
sudo apt install gcc-arm-linux-gnueabihf binutils-arm-linux-gnueabihf

# Or use ARM's official toolchain
# Download from: https://developer.arm.com/downloads/-/gnu-a
```

## Build Steps

### 1. Get Valve SDK (for config and toolchain)
```bash
git clone https://github.com/ValveSoftware/steamlink-sdk.git
cd steamlink-sdk
source setenv.sh
```

### 2. Download Kernel Source
```bash
# Get kernel 6.18 (or your desired version)
KERNEL_VERSION=6.18
wget https://cdn.kernel.org/pub/linux/kernel/v6.x/linux-${KERNEL_VERSION}.tar.xz
tar -xf linux-${KERNEL_VERSION}.tar.xz
cd linux-${KERNEL_VERSION}
```

### 3. Configure Environment
```bash
export ARCH=arm
export LOCALVERSION="-mrvl"
export CROSS_COMPILE=arm-linux-gnueabihf-
```

### 4. Get Base Config
```bash
# Use Valve's config or existing working config
wget https://heap.ovh/files/steamlink/5.10.32/config -O .config

# Or start from existing ARMv7 config
make ARCH=arm CROSS_COMPILE=arm-linux-gnueabihf- mrvl_defconfig

# Or customize
make ARCH=arm CROSS_COMPILE=arm-linux-gnueabihf- menuconfig
```

### 5. Key Config Options for Steam Link
```
CONFIG_MACH_BERLIN=y
CONFIG_MACH_BERLIN2=y
CONFIG_MACH_BERLIN2D=y
CONFIG_MACH_VALVE_STEAMLINK=y

# Networking
CONFIG_NET_ETHERNET=y
CONFIG_MWIFIEX=y
CONFIG_MWIFIEX_SDIO=y

# USB
CONFIG_USB=y
CONFIG_USB_EHCI_HCD=y
CONFIG_USB_OHCI_HCD=y

# Serial console (for debugging)
CONFIG_SERIAL_8250=y
CONFIG_SERIAL_8250_CONSOLE=y

# Filesystems
CONFIG_EXT3_FS=y
CONFIG_EXT4_FS=y
CONFIG_VFAT_FS=y

# Wireless (optional - has CVE-2019-6496!)
CONFIG_WIRELESS=y
```

### 6. Build
```bash
# Build kernel
make ARCH=arm CROSS_COMPILE=arm-linux-gnueabihf- -j$(nproc) zImage

# Build modules
make ARCH=arm CROSS_COMPILE=arm-linux-gnueabihf- -j$(nproc) modules

# Build device tree
make ARCH=arm CROSS_COMPILE=arm-linux-gnueabihf- dtbs
```

### 7. Output Files
- Kernel: `arch/arm/boot/zImage`
- DTB: `arch/arm/boot/dts/berlin2cd-valve-steamlink.dtb`
- Modules: `modules/`

### 8. Install to USB
```bash
# Copy kernel
cp arch/arm/boot/zImage /path/to/usb/boot/zImage-6.18-mrvl

# Copy DTB
cp arch/arm/boot/dts/berlin2cd-valve-steamlink.dtb /path/to/usb/boot/

# Copy modules
make ARCH=arm CROSS_COMPILE=arm-linux-gnueabihf- INSTALL_MOD_PATH=/path/to/usb modules_install
```

## Device Tree

You'll need a Device Tree Blob (DTB) for Steam Link:
- File: `berlin2cd-valve-steamlink.dtb`
- Source: `arch/arm/boot/dts/berlin2cd-valve-steamlink.dts`

## Boot Parameters

The parameters that actually boot the deployed USB (from
`steamlink/factory_test/run.sh`) are:

```
root=/dev/sda1 rootwait rw init=/lib/systemd/systemd console=ttyS0,115200n8 usbcore.autosuspend=-1
```

Notes, reconciled against the working stick:
- **No `earlyprintk`.** It was in earlier drafts of this guide but is *not* on the
  deployed USB; keep it off unless you are deliberately debugging early boot.
- `console=ttyS0,115200n8` — the trailing `n8` (no parity, 8 bits) is present on
  the deployed stick.
- `init=/lib/systemd/systemd` — required; without it the initramfs does not hand
  off to systemd.
- `usbcore.autosuspend=-1` — disables USB autosuspend, which otherwise drops the
  boot USB mid-kexec.
- **The observed cmdline is the bootloader's *plus* the kernel's default.** The
  original djmuted kernel (`6.1.115-steam`, and the older `5.10.228-steam`) was built
  with `CONFIG_CMDLINE_FORCE=y`, so the `kexec --command-line` was dropped entirely
  and only the built-in string applied — `log_buf_len=256K` did nothing and the ring
  buffer sat at `LOG_BUF_SHIFT=14` (16 KiB, banner evicted). The kernel deployed since
  2026-10-14 (packet `181-steamlink-kernel-rebuild`) is built with
  `CONFIG_CMDLINE_EXTEND=y` and `LOG_BUF_SHIFT=17`, and still carries the same
  `CONFIG_CMDLINE`. The device now reports:

  ```
  root=/dev/sda1 rootwait rw init=/lib/systemd/systemd console=ttyS0,115200n8 usbcore.autosuspend=-1 log_buf_len=256K console=ttyS0,115200 root=/dev/sda1 rw rootwait init=/lib/systemd/systemd
  ```

  i.e. bootloader args first, then the built-in default — so `log_buf_len=256K` and
  `usbcore.autosuspend=-1` finally apply, and `dmesg` retains the banner. This is
  what makes the `--debug` variant meaningful.

For a debugging boot, `steamlink_update --debug` appends `debug loglevel=7`; that is
effective again now that the kernel is built without `CONFIG_CMDLINE_FORCE`.

## Reproducing our build (packet 181, 2026-10-14)

The deployed `6.1.115-steam` is the build described here, produced from
hash-pinned inputs and committed under `kernel/`:

| File | Role |
|------|------|
| `SOURCE.pin` | the measured pins: source tarball sha256, base config sha256 + line count, SDK commit, toolchain, and the `KBUILD_BUILD_*` identity |
| `config-6.1.115-steam.base` | the shipped config, byte-for-byte (sha256 `cc9a9833…`) |
| `config-6.1.115-steam.delta` | the reviewed option set; each block names the symptom it fixes |
| `build.sh` | fetch → verify → apply delta → `olddefconfig` → build → assert → emit `out/` |

Everything it consumes is hash-pinned:

| Input | Pin |
|-------|-----|
| `linux-6.1.115.tar.xz` | sha256 `0fd8ba827e1f1888376d88fd1d1c80d707c587c75b0f18c26530824be437ba6f` |
| base `config-6.1.115-steam` | sha256 `cc9a9833e70540498d1dbca7206e9a119e228f1dda06b8eb0408b1a591170eb0` (4014 lines) |
| `ValveSoftware/steamlink-sdk` | commit `31a376a3b4cfd26cf8c470c904529032608ae7ee` (`armv7a-cros-linux-gnueabi-` GCC 9.2.0, `LD_LIBRARY_PATH` = SDK `toolchain/lib`) |
| build identity | `KBUILD_BUILD_USER=steamlink`, `_HOST=<build host>`, `_VERSION=1`, `_TIMESTAMP=Wed Oct 14 00:00:00 UTC 2026` (all overridable via the environment; `build.sh` defaults `_HOST` to `localhost`, and the host used for the released image is not published) |

```bash
cd ~/projects/Custom-Firmware/steamlink/kernel
./build.sh --clean          # idempotent; ~2 min, plus the tarball fetch on first run
```

`build.sh` exits non-zero when the tarball sha256, the base config sha256 or any of
its assertions do not hold. Outputs:

| Artefact | sha256 |
|----------|--------|
| `out/zImage` | `d0e9189e8f6a169b0bb79faf59bec9febe0c47df1a97bb84f7faf71dcd756c14` |
| `out/config-6.1.115-steam` | `7d4132e1f07186ed341800715c9a7ec0a1088c0645bfb59098d388eaad15bdea` |
| `out/root/lib/modules/6.1.115-steam/` | module tree (68 `.ko`; the 61 stock modules are all either present or folded into the image) |

Two independent `--clean` builds with the same pinned inputs and identity reproduce
a **byte-identical** `zImage` and config. `KBUILD_BUILD_HOST` is compiled into the
kernel banner, so the `zImage` hash below describes the released image: rebuilding
under a different identity changes that hash, while the resolved config hash is
unaffected. The identity used for the release is not published here.
The reason the original was not reproducible is that UTS_VERSION was left empty —
`KBUILD_BUILD_*` never reached `make`, and 6.1 splits the banner across two
generated headers. `build.sh` pins those variables for the same reason it exists.

### What the delta changes

Five review points, each tied to a symptom measured on the live device:

| Delta block | Effect |
|-------------|--------|
| `IP_ADVANCED_ROUTER=y`, `IP_MULTIPLE_TABLES=y` | policy routing exists → `ip rule show` works (was `Address family not supported by protocol`) |
| `NETFILTER_ADVANCED=y` + `NETFILTER_XT_TARGET/MATCH_CONNMARK=m` | tailscaled's CONNMARK rules load (was `Extension CONNMARK revision 0 not supported`) |
| `NF_TABLES=y` + `NFT_*` (`nft_ct`, `nft_nat`, `nft_masq`, `nft_log`, `nf_tables_inet`) | the nft backend works too, so `nft` is not a dead end |
| `CONFIG_CMDLINE_EXTEND=y` (FORCE off), `LOG_BUF_SHIFT=17` | kexec's command line is honored again → `log_buf_len=256K`, `log_buf_check`-style args work |
| `NETCONSOLE=y`; `PSTORE=y` (+ `PSTORE_RAM=m`, effort) | early boot is capturable over the wire; the ramoops store is compiled but needs a DTB node |

Deliberately **not** changed: the version string (`LOCALVERSION=-steam`,
`6.1.115`), `MWIFIEX*`/Wi-Fi (still as shipped), the DTB, `kexec_load.ko`, the
initramfs, and `IP_NF_*` legacy as the fallback path.

### Install and rollback

The wrapper used here is local tooling and is not published, but the job is small
and is the same over `ssh` to a running box or on a stick mounted on the build
host:

```bash
# 1. back up the stock set FIRST, onto the stick rather than onto the box:
#      /boot/{zImage,config-6.1.115-steam,initramfs-linux-steam.img}
#      and all 61 stock modules under /lib/modules/6.1.115-steam/
# 2. write the new artefacts in:
#      out/zImage                          -> /boot/zImage
#      out/config-6.1.115-steam            -> /boot/config-6.1.115-steam
#      out/root/lib/modules/6.1.115-steam/ -> /lib/modules/
# 3. refresh the module index against the target tree
#      (or use `depmod -b <root>` on a staged tree, as build.sh does):
depmod -a 6.1.115-steam
# 4. leave the DTB, /boot/kexec_load.ko and the initramfs untouched, then
#    power-cycle and check `uname -r` and `cat /proc/cmdline` (below).
#
# Rollback is step 1 in reverse: write the backed-up files back.
```

Whatever tool does the copying, the order is the same: capture the *stock* `/boot/{zImage,config-6.1.115-steam,
initramfs-linux-steam.img}` + 61 modules into `/boot/stock-6.1.115-steam/`, verify the
kit, then write the new `zImage`, config and `/lib/modules/6.1.115-steam`, `depmod`,
and assert that the DTB / `kexec_load.ko` / initramfs are byte-identical to what they
were. Refuse to write when the backup cannot be made first.

> **Boot by power-cycling.** After the first install an orderly
> `systemctl reboot` left the box dark (the journal lists no boot between that
> shutdown and the next power-on), while a physical **power-off/on** came up
> normally — ~8.7 s kernel + ~65 s userspace. Until that is understood, treat
> `systemctl reboot` as unavailable on this box.

### Verifying on the device

```bash
uname -a                     # Linux steamlink 6.1.115-steam #1 PREEMPT … (ours)
cat /proc/cmdline            # must contain log_buf_len=256K (kexec args) AND the built-in
dmesg | head -1              # banner survives → ring buffer > the old 16 KiB
ip rule show                 # must list the fwmark rules (was: address family unsupported)
sudo journalctl -u tailscaled -b | grep -i connmark   # "enabling connmark-based …"
```

## Troubleshooting

### Kernel panic on boot
- Check kernel modules are built for correct kernel version
- Ensure initramfs includes necessary drivers

### Device is dark after a kernel change
- **Power-cycle before blaming the kernel.** On 2026-10-14 the new kernel was
  installed, then `systemctl reboot` left the box unreachable (the journal has no
  boot for it) — power-off/on brought it straight back.
- The stick holds the stock firmware's per-boot handoff log at
  `/steamlink/boot-logs/pre-kexec.log`, and the Debian journal
  (`journalctl --list-boots`) is authoritative for boots that reached userspace.
  If the journal has no entry and `uname -r` reports the new kernel after a
  power-cycle, the install was fine and the reboot path was the problem.
- Restore the stock kernel from the backup kept at
  `/boot/stock-6.1.115-steam/` (or from that directory on a pulled stick).

### The subnet router still will not forward
- `ip rule show` must list Tailscale's fwmark rules; if it reports `Address family
  not supported by protocol` you are not on the rebuilt kernel.
- `sudo journalctl -u tailscaled -b | grep -i connmark` — a working box logs
  `enabling connmark-based rp_filter workaround`.
- **The route cannot be tested from a same-subnet node.** Tailscale will not use a
  tailnet subnet route that is also on the same subnet as the node testing it: Tailscale
  treats the route as on-link, so a node with an address on each of two LAN subnets
  receives nothing at its tailnet address. Test from a node that is genuinely off
  this LAN subnet.
- **How to prove it end-to-end (method verified 2026-10-14).** Run a tiny logging
  HTTP listener on a LAN host that prints the client address it sees, then request
  it from an off-LAN client. A request that came *through* the router arrives
  MASQUERADEd, i.e. it shows the router's own LAN address (`198.51.100.10`); the
  same request from an on-LAN host shows that host's own address, so the peer
  address alone discriminates the two paths. Corroborate on the device with
  `sudo iptables -t nat -L ts-postrouting -vn` (MASQUERADE counter) and
  `sudo iptables -t filter -L ts-forward -vn` (packets arriving on `tailscale0`
  and being marked): the 2026-10-14 run moved `nat` `23/1407` -> `25/1527` and
  `fwd-in-marked` `53/5279` -> `62/6106` in the same second as the request.
- Fallback if Tailscale's rule set installs badly: it now *can* install, but
  `--netfilter-mode=off` plus a manual MASQUERADE works because policy routing
  exists again.

### No network
- Include Marvel WiFi drivers (mwifiex)
- Include ethernet driver (mv643xx_eth)

### USB not working
- Enable EHCI and OHCI HCD
- Check USB power settings

## Sources
- https://heap.ovh/getting-linux-on-valve-steam-link.html
- https://github.com/craw0967/steamlink-archlinux
- https://github.com/mill1000/steamlink-kexec
