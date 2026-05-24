#!/usr/bin/env bash
# =============================================================================
# 03c-build-grml-base.sh -- grml base (GRMLBASE class only)
# =============================================================================

SELF="$(readlink -f "${BASH_SOURCE[0]}" 2>/dev/null || realpath "${BASH_SOURCE[0]}" 2>/dev/null || echo "${BASH_SOURCE[0]}")"
SCRIPT_DIR="$(dirname "$SELF")"
if   [[ -f "${SCRIPT_DIR}/config/common.sh" ]];    then COMMON_SH="${SCRIPT_DIR}/config/common.sh"
elif [[ -f "${SCRIPT_DIR}/../config/common.sh" ]]; then COMMON_SH="${SCRIPT_DIR}/../config/common.sh"
else echo "[ERR] Cannot find config/common.sh near ${SCRIPT_DIR}" >&2; exit 1; fi
# shellcheck source=../config/common.sh
source "$COMMON_SH"
BH="${SCRIPT_DIR}/../config/build-helpers.sh"
[[ -f "$BH" ]] || BH="${SCRIPT_DIR}/config/build-helpers.sh"
source "$BH"

require_root; require_cmd grml-live; print_banner
log_step "03c-build-grml-base.sh starting"

FLAVOUR="grml-base"
CLASSNAME="GRMLBASE"     # use grml-live's own GRMLBASE, no custom overlay needed
PKGLIST="${PROJECT_ROOT}/packages-tasksel/grml-base.list"
[[ -f "$PKGLIST" ]] || die "Missing ${PKGLIST} -- run scripts/01-extract-tasksel-lists.sh first"

# prepare_grml_config still injects the local-repo hook even for GRMLBASE.
CONFIGTREE="$(prepare_grml_config "$CLASSNAME" "$PKGLIST")"
# GRMLBASE + DEBIAN_TRIXIE,NO_ONLINE is the standard grml-small equivalent.
CHROOT="$(run_grml_live "$FLAVOUR" "$CONFIGTREE" "DEBIAN_TRIXIE,NO_ONLINE")"
log_ok "Chroot: ${CHROOT}"

LAYOUT="${ISO_LAYOUT:-mbr}"
case "$LAYOUT" in
    mbr)  "${SCRIPT_DIR}/04-finalize-iso-mbr.sh" "$CHROOT" "$FLAVOUR" ;;
    gpt)  "${SCRIPT_DIR}/04-finalize-iso-gpt.sh" "$CHROOT" "$FLAVOUR" ;;
    both) "${SCRIPT_DIR}/04-finalize-iso-mbr.sh" "$CHROOT" "$FLAVOUR"
          "${SCRIPT_DIR}/04-finalize-iso-gpt.sh" "$CHROOT" "$FLAVOUR" ;;
    *)    die "Unknown ISO_LAYOUT='${LAYOUT}'" ;;
esac
log_ok "03c-build-grml-base.sh finished."
