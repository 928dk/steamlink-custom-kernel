#!/usr/bin/env bash
# =============================================================================
# Packet 181-steamlink-kernel-rebuild -- reproducible Steam Link kernel build
# =============================================================================
# Builds 6.1.115-steam from vanilla linux-6.1.115 + the shipped config + a
# recorded delta, using the cross toolchain shipped in the Valve steamlink-sdk.
#
# Why this is not `make ARCH=arm CROSS_COMPILE=... zImage` and nothing else:
#   * `make` re-evaluates several compiler probes (CONFIG_CC_VERSION_TEXT,
#     CONFIG_GCC_VERSION, CONFIG_AS_VFP_VMRS_FPINST, the CONFIG_CC_HAS_*
#     family) *every time it runs*.  Without CROSS_COMPILE on PATH+LD_LIBRARY_PATH
#     those probes silently use the x86 host compiler and rewrite them, which
#     changes recorded config values and can drop ARM-only capability symbols.
#   * The "-steam" release suffix lives in `make LOCALVERSION=-steam`, not in
#     the config; omit it and /lib/modules/6.1.115-steam stops matching.
#
# Usage:
#   ./build.sh                # resolve config, build, assert, package into out/
#   ./build.sh --clean        # make mrproper first, then a full rebuild
#   ./build.sh --config-only  # stop after config resolution + assertions
#
# The build identity embedded in the image (KBUILD_BUILD_*) is pinned below and
# can be overridden from the environment.  Artefacts land in $BUILD_ROOT/out/.
# Nothing touches the device.
# =============================================================================
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUILD_ROOT="${BUILD_ROOT:-$HOME/build/steamlink-kernel}"
SRC_DIR="${SRC_DIR:-$BUILD_ROOT/src}"
KSRC="${KSRC:-$SRC_DIR/linux-6.1.115}"
SDK="${SDK:-$BUILD_ROOT/steamlink-sdk}"
OUT="${OUT:-$BUILD_ROOT/out}"

KERNEL_VERSION=6.1.115
LOCALVERSION=-steam
RELEASE="${KERNEL_VERSION}${LOCALVERSION}"
SOURCE_URL=https://cdn.kernel.org/pub/linux/kernel/v6.x/linux-${KERNEL_VERSION}.tar.xz
SOURCE_SHA256=0fd8ba827e1f1888376d88fd1d1c80d707c587c75b0f18c26530824be437ba6f
BASE_SHA256=cc9a9833e70540498d1dbca7206e9a119e228f1dda06b8eb0408b1a591170eb0
SDK_COMMIT=31a376a3b4cfd26cf8c470c904529032608ae7ee
SDK_LD_LIBRARY_PATH="$SDK/toolchain/lib"

export ARCH=arm
export CROSS_COMPILE=armv7a-cros-linux-gnueabi-
export LC_ALL=C                     # the SDK toolchain crashes under some locales
export PATH="$SDK/toolchain/bin:$PATH"
export LD_LIBRARY_PATH="$SDK_LD_LIBRARY_PATH"
# Exported, not just a shell variable: it must reach EVERY make invocation.
# A first cut of this script forgot that, built release 6.1.115, and installed
# modules to /lib/modules/6.1.115 -- which would have broken `uname -r`, module
# loading and the initramfs.  Step 6b now asserts the release at artefact level.
export LOCALVERSION
# Pin the build identity.  Kernel 6.1 generates TWO UTS_VERSION headers --
#   init/utsversion-tmp.h           placeholder, force-included by version.o
#   include/generated/utsversion.h  final,     force-included by version-timestamp.o
# -- and both resolve to *empty strings* unless KBUILD_BUILD_VERSION and
# KBUILD_BUILD_TIMESTAMP reach make:
#   build-version   = $(or $(KBUILD_BUILD_VERSION),   $(build-version-auto))
#   build-timestamp = $(or $(KBUILD_BUILD_TIMESTAMP), $(build-timestamp-auto))
# version.o keeps only a weak placeholder linux_banner[] (nm: V); the real one
# comes from version-timestamp.o (nm: R).  Left unset, init_uts_ns.name.version
# reads "# PREEMPT " and every rebuild embeds a different date.  Pinning all
# four makes the banner meaningful and the artefact byte-reproducible, and it is
# how the deployed image was built (it reports "#1 PREEMPT Fri Nov  8
# 22:51:44 UTC 2024"); step 6c asserts the result.
export KBUILD_BUILD_USER="${KBUILD_BUILD_USER:-steamlink}"
export KBUILD_BUILD_HOST="${KBUILD_BUILD_HOST:-localhost}"
export KBUILD_BUILD_VERSION="${KBUILD_BUILD_VERSION:-1}"
export KBUILD_BUILD_TIMESTAMP="${KBUILD_BUILD_TIMESTAMP:-Wed Oct 14 00:00:00 UTC 2026}"

CONFIG_ONLY=0
CLEAN=0
for arg in "$@"; do
  case "$arg" in
    --config-only) CONFIG_ONLY=1 ;;
    --clean)       CLEAN=1 ;;
    *) die "unknown argument: $arg (see the header for usage)" ;;
  esac
done

banner() { printf '\n=== %s ===\n' "$*"; }
die()    { printf 'FATAL: %s\n' "$*" >&2; exit 1; }

assert_sym() { # assert_sym <whole .config line> ; e.g. assert_sym CONFIG_X=y
  grep -qxF "$1" "$KSRC/.config" || die "config assertion failed: $1"
  printf '  ok  %s\n' "$1"
}

# -----------------------------------------------------------------------------
banner "0. toolchain + source + base-config pins"
[ -x "$SDK/toolchain/bin/${CROSS_COMPILE}gcc" ] || die "cross gcc not found under $SDK/toolchain/bin"
"${CROSS_COMPILE}gcc" --version | head -1 | grep -q "9\.2\.0" \
  || die "cross gcc is not 9.2.0 - the deployed kernel was built with 9.2.0"
printf '  ok  cross gcc %s\n' "$("${CROSS_COMPILE}gcc" -dumpversion)"

[ "$(git -C "$SDK" rev-parse HEAD)" = "$SDK_COMMIT" ] \
  || die "SDK is not at the pinned commit $SDK_COMMIT"
printf '  ok  steamlink-sdk @ %s\n' "$SDK_COMMIT"

BASE="$HERE/config-6.1.115-steam.base"
[ -f "$BASE" ] || die "missing base config $BASE (shipped config-6.1.115-steam)"
[ "$(sha256sum "$BASE" | cut -d' ' -f1)" = "$BASE_SHA256" ] \
  || die "base config sha256 mismatch - refusing to build from an unknown base"
printf '  ok  base config sha256 %s\n' "$BASE_SHA256"

if [ ! -d "$KSRC" ]; then
  banner "0b. fetching + extracting kernel source"
  mkdir -p "$SRC_DIR"
  TARBALL="$SRC_DIR/linux-${KERNEL_VERSION}.tar.xz"
  [ -f "$TARBALL" ] || curl -fL --retry 3 -o "$TARBALL" "$SOURCE_URL"
  echo "${SOURCE_SHA256}  ${TARBALL}" | sha256sum -c - || die "source tarball checksum mismatch"
  tar -C "$SRC_DIR" -xf "$TARBALL"
fi
[ -f "$KSRC/Makefile" ] || die "no kernel tree at $KSRC"

[ -f "$KSRC/Makefile" ] || die "no kernel tree at $KSRC"

if [ "$CLEAN" = 1 ]; then
  banner "0c. clean rebuild - clearing every object generated by an earlier run"
  # mrproper also drops .config, include/generated, .version and any *.o, so the
  # artefacts below come from a pristine tree: no chance of an object from an
  # earlier (differently-configured) run surviving into this image.
  make -C "$KSRC" mrproper >/dev/null
  printf '  ok  tree is pristine\n'
fi

# -----------------------------------------------------------------------------
banner "1. seed .config from the shipped config"
cp "$BASE" "$KSRC/.config.base"          # pristine copy, kept for diffing
cp "$BASE" "$KSRC/.config"

banner "2. apply delta + resolve non-interactively"
cat "$HERE/config-6.1.115-steam.delta" >> "$KSRC/.config"
make -C "$KSRC" olddefconfig

banner "3. review the diff base -> delta"
mkdir -p "$OUT"
# Read this output.  The only lines that are NOT part of the intended delta
# should be options that became *visible* thanks to the new parents and kept
# their default (n), plus CONFIG_PAHOLE_VERSION, which is a build-host probe
# and is inert here because DEBUG_INFO_BTF is off.
"$KSRC/scripts/diffconfig" "$KSRC/.config.base" "$KSRC/.config" | tee "$OUT/config-diff.txt"

banner "4. assert every requirement option is present"
assert_sym CONFIG_IP_ADVANCED_ROUTER=y                      # REQ-002
assert_sym CONFIG_IP_MULTIPLE_TABLES=y                      # REQ-002
assert_sym CONFIG_NETFILTER_ADVANCED=y                      # REQ-002
assert_sym CONFIG_NETFILTER_XT_TARGET_CONNMARK=m            # REQ-002
assert_sym CONFIG_NETFILTER_XT_MATCH_CONNMARK=m             # REQ-002
assert_sym CONFIG_NF_TABLES=y                               # REQ-002
assert_sym CONFIG_NF_TABLES_INET=y
assert_sym CONFIG_NF_TABLES_IPV4=y
assert_sym CONFIG_NF_TABLES_IPV6=y
assert_sym CONFIG_NFT_CT=m
assert_sym CONFIG_NFT_MASQ=m
assert_sym 'CONFIG_CMDLINE_EXTEND=y'                        # REQ-003
assert_sym '# CONFIG_CMDLINE_FORCE is not set'
assert_sym CONFIG_LOG_BUF_SHIFT=17
assert_sym CONFIG_NETCONSOLE=y                              # REQ-004
assert_sym CONFIG_NET_POLL_CONTROLLER=y
assert_sym CONFIG_PSTORE=y
assert_sym CONFIG_PSTORE_RAM=m
assert_sym CONFIG_USB_STORAGE=y                             # REQ-005b boot path
assert_sym CONFIG_BLK_DEV_SD=y
assert_sym CONFIG_EXT4_FS=y
assert_sym CONFIG_PXA168_ETH=y
assert_sym 'CONFIG_LOCALVERSION=""'                          # suffix comes from make
# NFR-S02 forbids *changing* the Wi-Fi state, so compare instead of assuming a
# value (the base config ships MWIFIEX=m, not "not set"), and confirm the
# driver's own hardware knob is absent: MWIFIEX is a module that stays unloaded
# (mlan0 is DOWN) rather than a built-in.
if ! diff <(grep -E '^CONFIG_MWIFIEX' "$KSRC/.config.base") <(grep -E '^CONFIG_MWIFIEX' "$KSRC/.config") >/dev/null; then
  die "the delta changed MWIFIEX state (NFR-S02 forbids it)"
fi
printf '  ok  MWIFIEX state unchanged from base\n'
grep -q '^# CONFIG_MWIFIEX is not set' "$KSRC/.config" && die "MWIFIEX unexpectedly disabled - out of scope"
printf '  ok  MWIFIEX is =m exactly as shipped\n'
grep -q '^# CONFIG_MODVERSIONS is not set' "$KSRC/.config" || die "MODVERSIONS must stay off"
printf '  ok  MODVERSIONS off\n'

[ "$(make -s -C "$KSRC" kernelrelease)" = "$RELEASE" ] \
  || die "release string is not $RELEASE"
printf '  ok  release string %s\n' "$RELEASE"

if [ "$CONFIG_ONLY" = 1 ]; then
  banner "config-only run complete"
  exit 0
fi

# -----------------------------------------------------------------------------
banner "5. build zImage + modules + dtbs ($(nproc) jobs)"
# zImage/modules are the deliverables; dtbs is built to prove the tree is
# consistent (the DTB itself is left untouched on the device by design).
make -C "$KSRC" -j"$(nproc)" zImage modules dtbs

banner "6. package artefacts into $OUT"
mkdir -p "$OUT"
cp "$KSRC/arch/arm/boot/zImage"                 "$OUT/zImage"
cp "$KSRC/.config"                              "$OUT/config-$RELEASE"
rm -rf "$OUT/root"
make -C "$KSRC" INSTALL_MOD_PATH="$OUT/root" INSTALL_MOD_STRIP=1 modules_install

# Generate the module index at build time and ship it inside the tree, exactly
# as the shipped image's own /lib/modules/6.1.115-steam does.  This is not a
# workaround for missing tooling: the device does have kmod 30, with
# /sbin/{modprobe,modinfo,insmod,rmmod,depmod} -> /bin/kmod, and its depmod
# works (verified against a throwaway copy).  Generating it here keeps the tree
# self-contained and the index reproducible off-device.  `depmod -b` uses the
# staged tree as its root and records root-relative paths, so the tree stays
# valid once copied to the stick; the binary indexes it writes use kmod's
# endian-neutral format (magic b007f457, index version 2), which kmod 30 reads.
depmod -b "$OUT/root" -a "$RELEASE"
MODDIR="$OUT/root/lib/modules/$RELEASE"
[ -s "$MODDIR/modules.dep" ] \
  || die "modules.dep was not generated - the packaged tree would be unusable on the device"

banner "6b. assert the release is baked into the artefacts (not just the make var)"
[ "$(cat "$KSRC/include/config/kernel.release")" = "$RELEASE" ] \
  || die "include/config/kernel.release is not $RELEASE"
printf '  ok  include/config/kernel.release = %s\n' "$RELEASE"
# The zImage is compressed, so its banner is not greppable; a module's vermagic
# is the honest artefact-level check.  It must match the STOCK modules exactly,
# because MODVERSIONS is off and vermagic equality is the whole ABI contract.
BUILT_VM="$(modinfo -F vermagic "$MODDIR/kernel/net/netfilter/xt_connmark.ko")"
printf '  built   %s\n' "$BUILT_VM"
case "$BUILT_VM" in "$RELEASE "*) : ;; *) die "built vermagic does not carry $RELEASE" ;; esac
printf '  ok  built vermagic carries %s\n' "$RELEASE"
# Check EVERY module, not a sample: a rebuild that only partially picks up a
# changed release string (stale objects) is exactly the failure mode a single
# sample can miss.
BAD=0
while IFS= read -r ko; do
  vm="$(modinfo -F vermagic "$ko" 2>/dev/null || echo MISSING)"
  case "$vm" in "$RELEASE "*) : ;; *) printf '  BAD  %s -> %s\n' "$ko" "$vm"; BAD=$((BAD+1)) ;; esac
done < <(find "$MODDIR" -name '*.ko')
[ "$BAD" -eq 0 ] || die "$BAD module(s) do not carry vermagic '$RELEASE '"
printf '  ok  all %s modules carry vermagic %s\n' "$(find "$MODDIR" -name '*.ko' | wc -l)" "$RELEASE"
STOCK_REF="$BUILD_ROOT/stock/modules/xt_mark.ko"
if [ -f "$STOCK_REF" ]; then
  STOCK_VM="$(modinfo -F vermagic "$STOCK_REF")"
  printf '  stock   %s  (%s)\n' "$STOCK_VM" "$(basename "$STOCK_REF")"
  [ "$BUILT_VM" = "$STOCK_VM" ] \
    || die "vermagic differs from the stock module - ABI mismatch"
  printf '  ok  vermagic is byte-identical to the stock module\n'
else
  printf '  note  no stock reference module at %s - vermagic compared to the release string only\n' "$STOCK_REF"
fi

banner "6c. assert the embedded build identity is the pinned one"
# Both UTS_VERSION headers must now agree; if they do not, the placeholder from
# init/utsversion-tmp.h leaked into version.o and `uname -v` would disagree with
# the /proc/version banner.  (version.o holds the weak linux_banner, so it is the
# string here -- not the linked one -- that proves the headers were consistent.)
V_BANNER="$(strings -a "$KSRC/init/version.o" | grep -m1 'Linux version')"
T_BANNER="$(strings -a "$KSRC/init/version-timestamp.o" | grep -m1 'Linux version')"
printf '  version.o           %s\n' "$V_BANNER"
printf '  version-timestamp.o %s\n' "$T_BANNER"
[ "$V_BANNER" = "$T_BANNER" ] \
  || die "the two UTS_VERSION headers disagree - KBUILD_BUILD_VERSION/TIMESTAMP did not reach every make"
case "$T_BANNER" in *"#$KBUILD_BUILD_VERSION"*) : ;; *) die "banner lacks build number #$KBUILD_BUILD_VERSION" ;; esac
case "$T_BANNER" in *"$KBUILD_BUILD_TIMESTAMP"*) : ;; *) die "banner lacks the pinned timestamp" ;; esac
case "$T_BANNER" in *"$KBUILD_BUILD_USER@$KBUILD_BUILD_HOST"*) : ;; *) die "banner lacks the pinned builder" ;; esac
printf '  ok  both objects agree on #%s, %s@%s and the pinned timestamp\n' \
  "$KBUILD_BUILD_VERSION" "$KBUILD_BUILD_USER" "$KBUILD_BUILD_HOST"

banner "7. artefact hashes"
( cd "$OUT" && sha256sum zImage "config-$RELEASE" )
printf '\nmodules installed under %s\n' "$MODDIR"
printf 'module count: %s\n' "$(find "$MODDIR" -name '*.ko' | wc -l)"
banner "done"
