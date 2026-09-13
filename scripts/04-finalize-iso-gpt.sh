#!/usr/bin/env bash
# =============================================================================
# 04-finalize-iso-gpt.sh -- Finalise a chroot into a bootable ISO using
#                           a GPT partition table and a UEFI ESP image,
#                           with a protective MBR for compatibility.
# =============================================================================
# This recipe targets:
#   * UEFI firmware (the modern default).
#   * USB sticks dd-ed straight from the .iso, where the GPT lets the
#     firmware find the EFI System Partition.
#   * Optical media boot under UEFI (rare, but supported).
#
# Bootloader: GRUB EFI (grubx64.efi) inside an EFI System Partition image.
# Partition table: GPT, with a protective MBR (xorriso option
#                  -partition_offset 16 -appended_part_as_gpt).
#
# Why a separate recipe?
#   * GPT is the right answer on modern hardware: it survives 2 TB+ disks,
#     allows >4 primary partitions, and stores a UUID per partition.
#   * MBR-only ISOs do not boot natively under "pure UEFI" firmware (no CSM).
#   * We keep a fallback ISOLINUX stage too so the same ISO still boots on
#     a legacy BIOS box -- this is called a "hybrid" ISO.
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
source "${SCRIPT_DIR}/../config/build-helpers.sh"

require_root
require_cmd xorriso grub-mkstandalone mformat mmd mcopy mksquashfs

CHROOT="${1:?usage: $0 CHROOT FLAVOUR}"
FLAVOUR="${2:?usage: $0 CHROOT FLAVOUR}"
[[ -d "$CHROOT" ]] || die "Chroot $CHROOT does not exist"

print_banner
log_step "04-finalize-iso-gpt.sh: $FLAVOUR (-O${ACTIVE_OPT_LEVEL}) GPT/UEFI layout"

ISO_STAGE="${BUILD_ROOT}/iso-stage-${FLAVOUR}-gpt"
rm -rf "$ISO_STAGE"
mkdir -p "$ISO_STAGE"/{boot/grub,EFI/BOOT,isolinux,live}

# -----------------------------------------------------------------------------
# 1. Stage kernel + initrd + squashfs (identical to MBR recipe).
# -----------------------------------------------------------------------------
log_info "Extracting kernel and initrd from chroot"
KERNEL_FILE="$(find "$CHROOT/boot" -maxdepth 1 -name 'vmlinuz-*' | sort -V | tail -1)"
INITRD_FILE="$(find "$CHROOT/boot" -maxdepth 1 -name 'initrd.img-*' | sort -V | tail -1)"
[[ -f "$KERNEL_FILE" ]] || die "No vmlinuz-* found in $CHROOT/boot"
[[ -f "$INITRD_FILE" ]] || die "No initrd.img-* found in $CHROOT/boot"
cp "$KERNEL_FILE" "$ISO_STAGE/live/vmlinuz"
cp "$INITRD_FILE" "$ISO_STAGE/live/initrd.img"

log_info "Building filesystem.squashfs"
mksquashfs "$CHROOT" "$ISO_STAGE/live/filesystem.squashfs" \
    -comp zstd -Xcompression-level 19 \
    -noappend -no-progress \
    -e boot/grub -e proc -e sys -e dev/pts

# -----------------------------------------------------------------------------
# 2. GRUB configuration consumed by both the EFI and BIOS GRUB images.
# -----------------------------------------------------------------------------
# This grub.cfg is referenced by grub.efi (UEFI side) and by the BIOS
# GRUB embedded core image (legacy side).  Two boot entries: live + install.
cat > "$ISO_STAGE/boot/grub/grub.cfg" <<EOF
set default=0
set timeout=10

menuentry "Boot ${FLAVOUR} live system" {
    linux  /live/vmlinuz boot=live components quiet splash
    initrd /live/initrd.img
}

menuentry "Install to disk (debian2hd via grml-debootstrap)" {
    linux  /live/vmlinuz boot=live components debian2hd
    initrd /live/initrd.img
}
EOF

# -----------------------------------------------------------------------------
# 3. Build the EFI bootloader (BOOTX64.EFI) and pack it into a FAT image.
# -----------------------------------------------------------------------------
# Plan:
#   a. grub-mkstandalone bakes a single BOOTX64.EFI containing every module
#      it needs, plus an embedded grub.cfg that chains to /boot/grub/grub.cfg
#      on the ISO.
#   b. Format an ~10 MiB FAT image, lay /EFI/BOOT/BOOTX64.EFI inside it.
#      This image will be embedded as the El Torito EFI boot image.

EFI_IMG="${ISO_STAGE}/efiboot.img"
EFIBOOT_DIR="${BUILD_ROOT}/efiboot-${FLAVOUR}"
rm -rf "$EFIBOOT_DIR"
mkdir -p "$EFIBOOT_DIR/EFI/BOOT"

# Embedded grub.cfg: just chain to the real one on the ISO.
cat > "$EFIBOOT_DIR/grub-embedded.cfg" <<'EOF'
search --set=root --file /boot/grub/grub.cfg
configfile /boot/grub/grub.cfg
EOF

log_info "Building standalone GRUB EFI binary"
grub-mkstandalone \
    --format=x86_64-efi \
    --output="$EFIBOOT_DIR/EFI/BOOT/BOOTX64.EFI" \
    --modules="part_gpt part_msdos fat iso9660 normal configfile linux echo \
               all_video test multiboot multiboot2 search sleep gzio lvm \
               chain efifwsetup efinet read ls cat png jpeg help font" \
    "boot/grub/grub.cfg=$EFIBOOT_DIR/grub-embedded.cfg"

# Create a FAT12 image just big enough to hold BOOTX64.EFI (10 MiB is
# safely oversized for one ~10 MB EFI binary).  mformat's -i tells it to
# operate on a regular file rather than a real device.
log_info "Packing EFI image $EFI_IMG"
truncate -s 10M "$EFI_IMG"
mkfs.vfat -F 12 -n EFIBOOT "$EFI_IMG" >/dev/null
mmd  -i "$EFI_IMG" ::/EFI ::/EFI/BOOT
mcopy -i "$EFI_IMG" "$EFIBOOT_DIR/EFI/BOOT/BOOTX64.EFI" ::/EFI/BOOT/BOOTX64.EFI

# Also stage BOOTX64.EFI for fallback (some firmwares look directly in the
# ISO 9660 file tree at /EFI/BOOT/BOOTX64.EFI).
cp "$EFIBOOT_DIR/EFI/BOOT/BOOTX64.EFI" "$ISO_STAGE/EFI/BOOT/BOOTX64.EFI"

# -----------------------------------------------------------------------------
# 4. BIOS GRUB image (so the same ISO still boots on legacy hardware).
# -----------------------------------------------------------------------------
# We do NOT use isolinux on the GPT recipe -- doing so requires fiddly
# cooperation between syslinux and the GPT layout.  GRUB BIOS is simpler and
# already a dependency we have.
log_info "Building BIOS GRUB core image"
grub-mkstandalone \
    --format=i386-pc \
    --output="$ISO_STAGE/boot/grub/core.img" \
    --install-modules="linux normal iso9660 biosdisk memdisk search tar ls" \
    --modules="linux normal iso9660 biosdisk search" \
    --locales="" --fonts="" \
    "boot/grub/grub.cfg=$EFIBOOT_DIR/grub-embedded.cfg"

# Concatenate the BIOS boot stub (cdboot.img) with our core.img to produce
# the El Torito BIOS boot image.
cat /usr/lib/grub/i386-pc/cdboot.img \
    "$ISO_STAGE/boot/grub/core.img" \
    > "$ISO_STAGE/boot/grub/bios.img"

# -----------------------------------------------------------------------------
# 5. Assemble the ISO with xorriso, requesting GPT.
# -----------------------------------------------------------------------------
# Key options for the GPT layout:
#   -append_partition 2 0xef efiboot.img    appends the FAT image as a
#                                           partition entry of type EF
#                                           (= EFI System Partition)
#   -appended_part_as_gpt                   says to use GPT instead of MBR
#                                           for that appended partition
#   -partition_offset 16                    leaves room for a protective MBR
#                                           and the primary GPT header
#   -isohybrid-gpt-basdat                   advertises the basic data
#                                           partition in the protective MBR
#   --grub2-mbr is intentionally NOT used -- it conflicts with
#   --appended_part_as_gpt on recent xorriso.
ISO_OUT="${ISO_OUT_DIR}/${FLAVOUR}-gpt-O${ACTIVE_OPT_LEVEL}.iso"
log_info "Writing ISO: $ISO_OUT"

xorriso -as mkisofs \
    -volid "${FLAVOUR^^}_O${ACTIVE_OPT_LEVEL}" \
    -joliet -rational-rock \
    \
    `# ---- BIOS El Torito ------------------------------------------------` \
    -b boot/grub/bios.img \
        -no-emul-boot \
        -boot-load-size 4 \
        -boot-info-table \
        --grub2-boot-info \
        --grub2-mbr /usr/lib/grub/i386-pc/boot_hybrid.img \
    \
    `# ---- UEFI El Torito ------------------------------------------------` \
    -eltorito-alt-boot \
    -e --interval:appended_partition_2:all:: \
        -no-emul-boot \
    \
    `# ---- GPT layout ----------------------------------------------------` \
    -append_partition 2 0xef "$EFI_IMG" \
    -appended_part_as_gpt \
    -iso_mbr_part_type 0x00 \
    -partition_offset 16 \
    \
    -o "$ISO_OUT" \
    "$ISO_STAGE"

log_ok "GPT/UEFI ISO ready: $ISO_OUT"
ls -la "$ISO_OUT"
