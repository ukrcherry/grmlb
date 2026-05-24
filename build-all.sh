#!/usr/bin/env bash
# =============================================================================
# build-all.sh -- Top-level orchestrator
# =============================================================================
# Runs the entire pipeline end-to-end:
#   1. 00-prepare-host.sh        (one-shot, idempotent)
#   2. 01-extract-tasksel-lists.sh
#   3. 02-build-source-repo.sh   (called once per flavour list)
#   4. 03[a-d]-build-*.sh        (one of the four, or all)
#
# Usage:
#       sudo ./build-all.sh [flavour]                  [layout]
#                            ^^^^^^^^                    ^^^^^^
#                            debian-base | debian-gnome | grml-base | grml-gnome | all
#                                                          mbr | gpt | both
#
# Examples:
#       sudo ./build-all.sh                            # default: all flavours, MBR
#       sudo ./build-all.sh debian-base                # one flavour, MBR
#       sudo ./build-all.sh debian-gnome gpt           # GPT layout
#       sudo ./build-all.sh all both                   # everything, MBR + GPT
#       sudo OPT_LEVELS=(2 3) ./build-all.sh debian-base both
#
# Environment variables (see config/common.sh for the full list):
#       OPT_LEVELS=(0 1 2 3)    optimization levels to compile with
#       ACTIVE_OPT_LEVEL=2      which compiled set ends up in the ISO
#       BUILD_ROOT=/scratch/iso work directory
#       PARALLEL_PKGS=4         from-source builds run in parallel
#       DEBIAN_MIRROR=...       mirror used for source + binary fallback
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

require_root
print_banner
log_step "build-all.sh starting"

FLAVOUR_ARG="${1:-all}"
LAYOUT_ARG="${2:-mbr}"
export ISO_LAYOUT="$LAYOUT_ARG"

# Map flavour name -> (packagelist, scriptname) so we can iterate cleanly.
declare -A FLAVOUR_LIST=(
    [debian-base]="debian-base.list 03a-build-debian-base.sh"
    [debian-gnome]="debian-gnome.list 03b-build-debian-gnome.sh"
    [grml-base]="grml-base.list 03c-build-grml-base.sh"
    [grml-gnome]="grml-gnome.list 03d-build-grml-gnome.sh"
)

case "$FLAVOUR_ARG" in
    all)         FLAVOURS=(debian-base debian-gnome grml-base grml-gnome) ;;
    debian-base|debian-gnome|grml-base|grml-gnome) FLAVOURS=("$FLAVOUR_ARG") ;;
    *)  die "Unknown flavour '$FLAVOUR_ARG' (expected debian-base|debian-gnome|grml-base|grml-gnome|all)" ;;
esac

# -----------------------------------------------------------------------------
# 1. Host preparation (idempotent).
# -----------------------------------------------------------------------------
"${SCRIPT_DIR}/scripts/00-prepare-host.sh"

# -----------------------------------------------------------------------------
# 2. Extract tasksel lists if missing.
# -----------------------------------------------------------------------------
if [[ ! -f "${PROJECT_ROOT}/packages-tasksel/debian-base.list" ]]; then
    "${SCRIPT_DIR}/scripts/01-extract-tasksel-lists.sh"
fi

# -----------------------------------------------------------------------------
# 3. Build the from-source repos for each requested flavour.
# -----------------------------------------------------------------------------
# We rebuild the *union* of every flavour's package list once per
# optimization level.  Building in this order avoids re-fetching the same
# source packages twice.
log_step "From-source rebuild"
UNION_LIST="${BUILD_ROOT}/union-package-list.list"
: > "$UNION_LIST"
for flavour in "${FLAVOURS[@]}"; do
    read -r listname _ <<<"${FLAVOUR_LIST[$flavour]}"
    cat "${PROJECT_ROOT}/packages-tasksel/${listname}" >> "$UNION_LIST"
done
sort -u "$UNION_LIST" -o "$UNION_LIST"
log_info "Union list: $(wc -l < "$UNION_LIST") packages across ${#OPT_LEVELS[@]} opt-level(s)"

"${SCRIPT_DIR}/scripts/02-build-source-repo.sh" "$UNION_LIST"

# -----------------------------------------------------------------------------
# 4. Build each flavour's ISO(s).
# -----------------------------------------------------------------------------
for flavour in "${FLAVOURS[@]}"; do
    log_step "Building flavour: $flavour"
    read -r _ scriptname <<<"${FLAVOUR_LIST[$flavour]}"
    "${SCRIPT_DIR}/scripts/${scriptname}"
done

log_ok "build-all.sh finished.  ISOs are in $ISO_OUT_DIR"
ls -la "$ISO_OUT_DIR"/*.iso 2>/dev/null || true
