#!/usr/bin/env bash
# =============================================================================
# 04-finalize-iso-mbr.sh -- Finalise a chroot into a bootable ISO using
#                           a legacy MBR partition table (BIOS boot only,
#                           with a hybrid MBR for USB-stick compatibility).
# =============================================================================
# This recipe targets:
#   * Legacy BIOS firmware (no UEFI required).
#   * USB sticks dd-ed straight from the .iso (isohybrid).
#   * Optical media (CD/DVD).
#
# Bootloader: ISOLINUX (= the SYSLINUX variant for ISO9660 media).
# Partition table: 0xEE-less MBR with a single bootable partition spanning
#                  the data area; xorriso adds the El Torito boot record so
#                  BIOS can find isolinux.
#
# The resulting .iso is also valid for `dd if=... of=/dev/sdX bs=4M`, the
# recommended USB write method for grml/Debian images.
#
# Caller passes: <chroot-dir> <flavour-name>
# Output: ${ISO_OUT_DIR}/<flavour>-mbr-O<lvl>.iso
# =============================================================================

SELF="$(readlink -f "${BASH_SOURCE[0]}" 2>/dev/null || realpath "${BASH_SOURCE[0]}" 2>/dev/null || echo "${BASH_SOURCE[0]}")"
SCRIPT_DIR="$(dirname "$SELF")"
# Find config/common.sh: works when this file lives in scripts/ AND when
# it lives in the project root itself (build-all.sh case).
if   [[ -f "${SCRIPT_DIR}/config/common.sh" ]];    then COMMON_SH="${SCRIPT_DIR}/config/common.sh"
elif [[ -f "${SCRIPT_DIR}/../config/common.sh" ]]; then COMMON_SH="${SCRIPT_DIR}/../config/common.sh"
else echo "[ERR] Cannot find config/common.sh near ${SCRIPT_DIR}" >&2; exit 1; fi
# shellcheck source=../config/common.sh
source "$COMMON_SH"
# shellcheck source=../config/build-helpers.sh
# (sourced for ACTIVE_OPT_LEVEL and the helpers it sets up)
source "${SCRIPT_DIR}/../config/build-helpers.sh"

require_root
require_cmd xorriso isohybrid mksquashfs

CHROOT="${1:?usage: $0 CHROOT FLAVOUR}"
FLAVOUR="${2:?usage: $0 CHROOT FLAVOUR}"
[[ -d "$CHROOT" ]] || die "Chroot $CHROOT does not exist"

print_banner
log_step "04-finalize-iso-mbr.sh: $FLAVOUR (-O${ACTIVE_OPT_LEVEL}) MBR layout"

# -----------------------------------------------------------------------------
# 1. Stage area for the ISO contents.
# -----------------------------------------------------------------------------
# The ISO root will look like:
#   /boot/grub/grub.cfg                <- chained from isolinux for fancy menus
#   /isolinux/isolinux.bin             <- main BIOS bootloader
#   /isolinux/isolinux.cfg             <- menu config
#   /isolinux/ldlinux.c32 ...          <- isolinux runtime modules
#   /live/vmlinuz                      <- copied from chroot's /boot
#   /live/initrd.img
#   /live/filesystem.squashfs          <- chroot, compressed
ISO_STAGE="${BUILD_ROOT}/iso-stage-${FLAVOUR}-mbr"
rm -rf "$ISO_STAGE"
mkdir -p "$ISO_STAGE"/{isolinux,live,boot/grub}

# -----------------------------------------------------------------------------
# 2. Copy bootloader runtime files.
# -----------------------------------------------------------------------------
# isolinux.bin and friends ship in /usr/lib/ISOLINUX and /usr/lib/syslinux.
# We copy a curated set: the minimum needed to display a graphical menu.
log_info "Staging ISOLINUX boot files"
cp /usr/lib/ISOLINUX/isolinux.bin                "$ISO_STAGE/isolinux/"
cp /usr/lib/syslinux/modules/bios/ldlinux.c32    "$ISO_STAGE/isolinux/"
cp /usr/lib/syslinux/modules/bios/menu.c32       "$ISO_STAGE/isolinux/"
cp /usr/lib/syslinux/modules/bios/vesamenu.c32   "$ISO_STAGE/isolinux/"
cp /usr/lib/syslinux/modules/bios/libcom32.c32   "$ISO_STAGE/isolinux/"
cp /usr/lib/syslinux/modules/bios/libutil.c32    "$ISO_STAGE/isolinux/"

# Boot menu.  "live" entry boots the live system; "install" jumps straight to
# grml-debootstrap by setting the kernel cmdline `debian2hd`.  See the
# grml-debootstrap(8) page for the full set of debian2hd boot options.
cat > "$ISO_STAGE/isolinux/isolinux.cfg" <<EOF
DEFAULT vesamenu.c32
PROMPT 0
TIMEOUT 100
MENU TITLE ${FLAVOUR} (${DEBIAN_SUITE}, -O${ACTIVE_OPT_LEVEL})

LABEL live
    MENU LABEL Boot ${FLAVOUR} live system
    MENU DEFAULT
    KERNEL /live/vmlinuz
    APPEND initrd=/live/initrd.img boot=live components quiet splash

LABEL install
    MENU LABEL Install to disk (debian2hd via grml-debootstrap)
    KERNEL /live/vmlinuz
    APPEND initrd=/live/initrd.img boot=live components debian2hd
EOF

# -----------------------------------------------------------------------------
# 3. Copy kernel + initrd from chroot.
# -----------------------------------------------------------------------------
# grml-live's chroot keeps these under /boot.  There may be multiple kernel
# versions installed; we pick the highest by `sort -V`.
log_info "Extracting kernel and initrd from chroot"
KERNEL_FILE="$(find "$CHROOT/boot" -maxdepth 1 -name 'vmlinuz-*' | sort -V | tail -1)"
INITRD_FILE="$(find "$CHROOT/boot" -maxdepth 1 -name 'initrd.img-*' | sort -V | tail -1)"
[[ -f "$KERNEL_FILE" ]] || die "No vmlinuz-* found in $CHROOT/boot"
[[ -f "$INITRD_FILE" ]] || die "No initrd.img-* found in $CHROOT/boot"
cp "$KERNEL_FILE" "$ISO_STAGE/live/vmlinuz"
cp "$INITRD_FILE" "$ISO_STAGE/live/initrd.img"

# -----------------------------------------------------------------------------
# 4. Compress the chroot into a SquashFS.
# -----------------------------------------------------------------------------
# zstd compression: best speed/ratio trade-off in 2025.  Level 19 cuts ~12%
# off vs xz on a typical Debian rootfs while decompressing 4x faster.
log_info "Building filesystem.squashfs (this is the slowest step, ~5-30 min)"
mksquashfs "$CHROOT" "$ISO_STAGE/live/filesystem.squashfs" \
    -comp zstd -Xcompression-level 19 \
    -noappend -no-progress \
    -e boot/grub -e proc -e sys -e dev/pts

# -----------------------------------------------------------------------------
# 5. Build the ISO with xorriso.
# -----------------------------------------------------------------------------
# Key xorriso options:
#   -as mkisofs              compatible-mode invocation
#   -isohybrid-mbr ...        embed isohdpfx.bin so isohybrid works
#   -c isolinux/boot.cat      El Torito boot catalog
#   -b isolinux/isolinux.bin  El Torito bootable image (BIOS)
#   -no-emul-boot, -boot-load-size 4, -boot-info-table
#                             classic isolinux flags
#   -isohybrid-gpt-basdat     omitted on purpose: this is the MBR recipe
ISO_OUT="${ISO_OUT_DIR}/${FLAVOUR}-mbr-O${ACTIVE_OPT_LEVEL}.iso"
log_info "Writing ISO: $ISO_OUT"

xorriso -as mkisofs \
    -volid "${FLAVOUR^^}_O${ACTIVE_OPT_LEVEL}" \
    -joliet -rational-rock \
    -isohybrid-mbr /usr/lib/ISOLINUX/isohdpfx.bin \
    -c isolinux/boot.cat \
    -b isolinux/isolinux.bin \
        -no-emul-boot \
        -boot-load-size 4 \
        -boot-info-table \
    -o "$ISO_OUT" \
    "$ISO_STAGE"

# Belt-and-braces: run isohybrid again so the 0x80 boot flag is set on the
# right entry; xorriso's -isohybrid-mbr does this on most versions, but the
# explicit call costs nothing.
isohybrid "$ISO_OUT"

log_ok "MBR ISO ready: $ISO_OUT"
ls -la "$ISO_OUT"
