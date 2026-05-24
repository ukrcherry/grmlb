#!/usr/bin/env bash
# =============================================================================
# common.sh -- Shared library for the Debian/grml ISO build suite
# =============================================================================
# Sourced by every other script.  Defines:
#   1. Logging functions  (defined FIRST so they work even if later init fails)
#   2. Strict-mode options
#   3. Path variables (overridable from environment before sourcing)
#   4. The OPT_LEVELS array and helpers to apply it to builds
#   5. Sanity-check helpers
# =============================================================================

# =============================================================================
# SECTION 1 -- Logging helpers  (intentionally before set -euo so they always
#              exist even if sourcing aborts partway through)
# =============================================================================
if [[ -t 2 ]]; then
    _C_RED=$'\e[31m'; _C_YELLOW=$'\e[33m'; _C_GREEN=$'\e[32m'
    _C_BLUE=$'\e[34m'; _C_DIM=$'\e[2m'; _C_OFF=$'\e[0m'
else
    _C_RED=""; _C_YELLOW=""; _C_GREEN=""; _C_BLUE=""; _C_DIM=""; _C_OFF=""
fi

log_info()  { printf '%s[INFO]%s  %s\n'  "$_C_BLUE"   "$_C_OFF" "$*" >&2; }
log_ok()    { printf '%s[ OK ]%s  %s\n'  "$_C_GREEN"  "$_C_OFF" "$*" >&2; }
log_warn()  { printf '%s[WARN]%s  %s\n'  "$_C_YELLOW" "$_C_OFF" "$*" >&2; }
log_error() { printf '%s[ERR ]%s  %s\n'  "$_C_RED"    "$_C_OFF" "$*" >&2; }
log_step()  { printf '\n%s==>%s %s\n'    "$_C_GREEN"  "$_C_OFF" "$*" >&2; }
die()       { log_error "$*"; exit 1; }

# =============================================================================
# SECTION 2 -- Strict mode (after function defs so they're already available)
# =============================================================================
set -euo pipefail

# =============================================================================
# SECTION 3 -- Project-root detection (robust regardless of CWD or sudo)
# =============================================================================
# BASH_SOURCE[0] is the path to *this file* when sourced.
# We resolve it to an absolute path and derive PROJECT_ROOT from it.
_THIS_FILE="${BASH_SOURCE[0]}"
_THIS_FILE_ABS="$(readlink -f "$_THIS_FILE" 2>/dev/null \
    || realpath "$_THIS_FILE" 2>/dev/null \
    || echo "$_THIS_FILE")"
_THIS_DIR="$(dirname "$_THIS_FILE_ABS")"
# config/common.sh => project root is dirname(config/) = dirname(dirname(common.sh))
PROJECT_ROOT="${PROJECT_ROOT:-$(dirname "$_THIS_DIR")}"

# Sanity guard: warn if the layout looks wrong.
if [[ ! -d "${PROJECT_ROOT}/scripts" ]]; then
    log_warn "PROJECT_ROOT=${PROJECT_ROOT} has no scripts/ subdirectory."
    log_warn "If you moved the project, set PROJECT_ROOT explicitly."
fi

# =============================================================================
# SECTION 4 -- Path variables  (override any by exporting before sourcing)
# =============================================================================
BUILD_ROOT="${BUILD_ROOT:-/var/cache/iso-build}"
LOCAL_REPO_ROOT="${LOCAL_REPO_ROOT:-${BUILD_ROOT}/repo}"
CHROOT_ROOT="${CHROOT_ROOT:-${BUILD_ROOT}/chroots}"
ISO_OUT_DIR="${ISO_OUT_DIR:-${BUILD_ROOT}/iso-out}"
SOURCE_CACHE="${SOURCE_CACHE:-${BUILD_ROOT}/sources}"
# Where git clones of grml-live and grml-debootstrap live (used for reading
# their package_config files; the installed tools come from apt).
GRML_LIVE_SRC="${GRML_LIVE_SRC:-${BUILD_ROOT}/grml-live-src}"
GRML_DEBOOTSTRAP_SRC="${GRML_DEBOOTSTRAP_SRC:-${BUILD_ROOT}/grml-debootstrap-src}"

# =============================================================================
# SECTION 5 -- Debian / grml release variables
# =============================================================================
DEBIAN_SUITE="${DEBIAN_SUITE:-trixie}"
DEBIAN_VERSION="${DEBIAN_VERSION:-13}"
DEBIAN_MIRROR="${DEBIAN_MIRROR:-http://deb.debian.org/debian}"
ARCH="${ARCH:-amd64}"

# =============================================================================
# SECTION 6 -- Optimization-flag array
# =============================================================================
# OPT_LEVELS is an indexed array of optimization level suffixes.
# Each element is the character(s) that follow -O in gcc's flag:
#   0, 1, 2, 3, s (size), g (debug-friendly), fast (aggressive/unsafe).
#
# Default = all four main levels.  Override BEFORE sourcing this file:
#
#     export OPT_LEVELS=(2)        # single level
#     export OPT_LEVELS=(0 2 3)    # skip -O1
#
# Bash does NOT export arrays across sudo/subshell boundaries reliably.
# Use the string form to pass levels through sudo:
#
#     sudo OPT_LEVELS_STR="2 3" ./build-all.sh
#
# Initialise OPT_LEVELS safely.
# We must NOT reference ${OPT_LEVELS[@]} before the variable is set because
# bash's set -u treats an uninitialized array as unbound even after
# "declare -ga" without an assignment.  The pattern ${var+_} (no dash) expands
# to "_" when var IS set (even to empty string), and to "" when it is unbound.
if [[ -n "${OPT_LEVELS_STR:-}" ]]; then
    # Sudo-safe string form wins when provided.
    read -ra OPT_LEVELS <<< "$OPT_LEVELS_STR"
elif [[ -z "${OPT_LEVELS+_}" ]]; then
    # OPT_LEVELS is completely unset -- apply the default.
    OPT_LEVELS=(0 1 2 3)
fi
# Now that OPT_LEVELS is definitely initialised, declare it as a global array.
declare -ga OPT_LEVELS

# Helper: print each optimization level on its own line for use in for loops.
opt_levels_iter() {
    printf '%s\n' "${OPT_LEVELS[@]}"
}

# Helper: emit DEB_*FLAGS_APPEND export lines for a given level.
# We use *_APPEND (not direct CFLAGS=) so Debian's hardening flags survive.
# gcc processes flags left-to-right and the last -O wins, so our appended
# value takes effect.
#
# Call it as:
#     eval "export $(opt_level_to_debenv "$lvl" | xargs)"
opt_level_to_debenv() {
    local lvl="$1"
    cat <<EOF
DEB_CFLAGS_APPEND="-O${lvl}"
DEB_CXXFLAGS_APPEND="-O${lvl}"
DEB_FCFLAGS_APPEND="-O${lvl}"
DEB_FFLAGS_APPEND="-O${lvl}"
DEB_OBJCFLAGS_APPEND="-O${lvl}"
DEB_OBJCXXFLAGS_APPEND="-O${lvl}"
EOF
}

# =============================================================================
# SECTION 7 -- Sanity-check helpers
# =============================================================================
require_root() {
    [[ "$(id -u)" -eq 0 ]] || die "This script must be run as root (sudo)."
}

require_cmd() {
    local missing=()
    for c in "$@"; do
        command -v "$c" >/dev/null 2>&1 || missing+=("$c")
    done
    if (( ${#missing[@]} )); then
        die "Missing required commands: ${missing[*]}.  Run scripts/00-prepare-host.sh first."
    fi
}

print_banner() {
    cat >&2 <<EOF
${_C_DIM}-----------------------------------------------------------------${_C_OFF}
  Build configuration
    PROJECT_ROOT      = ${PROJECT_ROOT}
    BUILD_ROOT        = ${BUILD_ROOT}
    DEBIAN_SUITE      = ${DEBIAN_SUITE}  (Debian ${DEBIAN_VERSION})
    ARCH              = ${ARCH}
    OPT_LEVELS        = (${OPT_LEVELS[*]})
${_C_DIM}-----------------------------------------------------------------${_C_OFF}
EOF
}

# =============================================================================
# SECTION 8 -- Eagerly create build directories
# =============================================================================
mkdir -p \
    "$BUILD_ROOT" \
    "$LOCAL_REPO_ROOT" \
    "$CHROOT_ROOT" \
    "$ISO_OUT_DIR" \
    "$SOURCE_CACHE"
