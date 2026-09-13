#!/usr/bin/env bash
# =============================================================================
# 03a-build-debian-base.sh -- Debian base (tasksel "standard" task)
# =============================================================================
# Builds a live+installer ISO containing the packages from the Debian
# "standard" task (Priority >= standard).  grml-debootstrap is included so
# the user can install from the live environment to a real disk.
#
# Usage:
#   sudo scripts/03a-build-debian-base.sh
#   sudo ISO_LAYOUT=gpt scripts/03a-build-debian-base.sh
# =============================================================================

SELF="$(readlink -f "${BASH_SOURCE[0]}" 2>/dev/null || realpath "${BASH_SOURCE[0]}" 2>/dev/null || echo "${BASH_SOURCE[0]}")"
SCRIPT_DIR="$(dirname "$SELF")"
if   [[ -f "${SCRIPT_DIR}/config/common.sh" ]];    then COMMON_SH="${SCRIPT_DIR}/config/common.sh"
elif [[ -f "${SCRIPT_DIR}/../config/common.sh" ]]; then COMMON_SH="${SCRIPT_DIR}/../config/common.sh"
else echo "[ERR] Cannot find config/common.sh near ${SCRIPT_DIR}" >&2; exit 1; fi
# shellcheck source=../config/common.sh
source "$COMMON_SH"

# shellcheck source=../config/build-helpers.sh
BH="${SCRIPT_DIR}/../config/build-helpers.sh"
[[ -f "$BH" ]] || BH="${SCRIPT_DIR}/config/build-helpers.sh"
source "$BH"

require_root
require_cmd grml-live
print_banner
log_step "03a-build-debian-base.sh starting"

FLAVOUR="debian-base"
# Custom class name must be ALL_CAPS and not clash with grml-live's built-ins.
CLASSNAME="DEBIAN_BASE"
PKGLIST="${PROJECT_ROOT}/packages-tasksel/debian-base.list"
[[ -f "$PKGLIST" ]] || die "Missing ${PKGLIST} -- run scripts/01-extract-tasksel-lists.sh first"

# Prepare the config tree (prints its path to stdout).
CONFIGTREE="$(prepare_grml_config "$CLASSNAME" "$PKGLIST")"

# Build the chroot via grml-live.
# GRMLBASE provides the kernel, initrd, grml tooling, grml-debootstrap.
# DEBIAN_BASE adds our custom standard-task package list.
# DEBIAN_TRIXIE applies trixie-specific tweaks from the grml-live tree.
CHROOT="$(run_grml_live "$FLAVOUR" "$CONFIGTREE" "DEBIAN_TRIXIE,NO_ONLINE,${CLASSNAME}")"
log_ok "Chroot: ${CHROOT}"

# Finalise into a bootable ISO (MBR or GPT based on ISO_LAYOUT env var).
LAYOUT="${ISO_LAYOUT:-mbr}"
case "$LAYOUT" in
    mbr)  "${SCRIPT_DIR}/04-finalize-iso-mbr.sh" "$CHROOT" "$FLAVOUR" ;;
    gpt)  "${SCRIPT_DIR}/04-finalize-iso-gpt.sh" "$CHROOT" "$FLAVOUR" ;;
    both) "${SCRIPT_DIR}/04-finalize-iso-mbr.sh" "$CHROOT" "$FLAVOUR"
          "${SCRIPT_DIR}/04-finalize-iso-gpt.sh" "$CHROOT" "$FLAVOUR" ;;
    *)    die "Unknown ISO_LAYOUT='${LAYOUT}' (expected mbr|gpt|both)" ;;
esac

log_ok "03a-build-debian-base.sh finished."
