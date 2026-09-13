#!/usr/bin/env bash
# =============================================================================
# 00-prepare-host.sh -- Install every build dependency on the Ubuntu/Debian host
# =============================================================================
# Run once per machine.  Idempotent: re-running is harmless.
#
# Usage (from any directory inside the project):
#       sudo ./scripts/00-prepare-host.sh
# or from the project root:
#       sudo ./00-prepare-host.sh  (via build-all.sh)
#
# What it does:
#   1. Finds and sources config/common.sh regardless of CWD.
#   2. apt-installs all packages needed by the rest of the suite.
#   3. Adds the grml apt repository so grml-live and grml-debootstrap can be
#      installed as normal .deb packages -- no "build from git" gymnastics.
#   4. Clones the grml-live git tree (read-only) into $BUILD_ROOT so that
#      01-extract-tasksel-lists.sh can read grml's package_config files.
#   5. Verifies that the key commands are now on PATH.
#
# NOTE: grml-live and grml-debootstrap are both available as standard Debian
# packages in trixie and in the grml apt repository.  We install them from
# apt because that is the supported, tested path.  Building them from source
# is unnecessary and error-prone on Ubuntu hosts.
# =============================================================================

# ---------------------------------------------------------------------------
# 0. Source common.sh with a foolproof path that works regardless of CWD or
#    how sudo was invoked.  We resolve our own location first, then walk to
#    config/common.sh from there.
# ---------------------------------------------------------------------------
SELF="$(readlink -f "${BASH_SOURCE[0]}" 2>/dev/null || realpath "${BASH_SOURCE[0]}" 2>/dev/null || echo "${BASH_SOURCE[0]}")"
SCRIPT_DIR="$(dirname "$SELF")"
# Find config/common.sh: works when this file lives in scripts/ AND when
# it lives in the project root itself (build-all.sh case).
if   [[ -f "${SCRIPT_DIR}/config/common.sh" ]];    then COMMON_SH="${SCRIPT_DIR}/config/common.sh"
elif [[ -f "${SCRIPT_DIR}/../config/common.sh" ]]; then COMMON_SH="${SCRIPT_DIR}/../config/common.sh"
else echo "[ERR] Cannot find config/common.sh near ${SCRIPT_DIR}" >&2; exit 1; fi
# shellcheck source=../config/common.sh
source "$COMMON_SH"

# From here on every log_* function and variable from common.sh is available.
require_root
print_banner
log_step "00-prepare-host.sh starting"

export DEBIAN_FRONTEND=noninteractive

# ---------------------------------------------------------------------------
# 1. Install the build toolchain from Ubuntu/Debian repos
# ---------------------------------------------------------------------------
log_info "Refreshing apt cache..."
apt-get update -qq

log_info "Installing build dependencies..."
# Packages are grouped by role and listed one-per-line for readability.
apt-get install -y --no-install-recommends \
    \
    `# --- bootstrap / chroot tooling ---` \
    debootstrap \
    mmdebstrap \
    schroot \
    \
    `# --- source-package building ---` \
    build-essential \
    debhelper \
    devscripts \
    dh-make \
    dpkg-dev \
    eatmydata \
    equivs \
    fakeroot \
    lintian \
    quilt \
    sbuild \
    \
    `# --- local apt repository ---` \
    reprepro \
    \
    `# --- ISO assembly ---` \
    dosfstools \
    grub-common \
    grub-efi-amd64-bin \
    grub-pc-bin \
    grub2-common \
    debian-archive-keyring \
    isolinux \
    mtools \
    squashfs-tools \
    syslinux-common \
    syslinux-utils \
    xorriso \
    \
    `# --- partition / disk tools ---` \
    gdisk \
    parted \
    \
    `# --- task extraction (01-extract...) ---` \
    tasksel \
    tasksel-data \
    \
    `# --- misc runtime ---` \
    ca-certificates \
    curl \
    git \
    jq \
    python3 \
    rsync \
    sudo \
    zsh

log_ok "Base build dependencies installed."

# ---------------------------------------------------------------------------
# 2. Add the grml apt repository and install grml-live + grml-debootstrap
# ---------------------------------------------------------------------------
# grml-live and grml-debootstrap are in Debian trixie's main archive.
# On Ubuntu hosts (where this script is most likely being run) they may not
# be present in the default repos, so we add grml's own repository.
GRML_APT_LIST="/etc/apt/sources.list.d/grml.sources"
GRML_KEYRING="/usr/share/keyrings/grml-archive-keyring.gpg"

if [[ ! -f "$GRML_KEYRING" ]]; then
    log_info "Fetching grml archive keyring..."
    curl -fsSL https://deb.grml.org/repo.key \
        | gpg --dearmor -o "$GRML_KEYRING"
fi

if [[ ! -f "$GRML_APT_LIST" ]]; then
    log_info "Adding grml apt repository..."
    cat > "$GRML_APT_LIST" <<EOF
# grml.org apt repository -- grml-live, grml-debootstrap, grml-keyring
Types: deb
URIs: https://deb.grml.org/
Suites: grml-stable
Components: main
Architectures: ${ARCH}
Signed-By: ${GRML_KEYRING}
EOF
    apt-get update -qq
fi

log_info "Installing grml-live and grml-debootstrap from apt..."
apt-get install -y --no-install-recommends \
    grml-live \
    grml-live-addons \
    grml-debootstrap

log_ok "grml-live and grml-debootstrap installed."

# ---------------------------------------------------------------------------
# 3. Clone the grml-live git repo (read-only) so we can read its
#    package_config files in 01-extract-tasksel-lists.sh
# ---------------------------------------------------------------------------
# We do NOT build from this clone -- we just need the source tree to read
# the GRMLBASE / GRML_FULL package lists which are text files in the repo.
clone_or_update() {
    local url="$1"
    local dest="$2"
    local tag="${3:-}"   # optional tag/branch; empty = master/main

    if [[ -d "${dest}/.git" ]]; then
        log_info "Updating existing checkout at ${dest}"
        git -C "$dest" fetch --all --tags --prune -q
    else
        log_info "Cloning ${url} -> ${dest}"
        git clone --depth=1 "$url" "$dest"
    fi

    if [[ -n "$tag" ]]; then
        log_info "Checking out ${tag} in ${dest}"
        git -C "$dest" checkout "$tag" -q
    else
        # Pull latest on the default branch.
        git -C "$dest" pull --ff-only -q 2>/dev/null || true
    fi
}

mkdir -p "$BUILD_ROOT"

clone_or_update \
    "https://github.com/grml/grml-live.git" \
    "$GRML_LIVE_SRC" \
    "${GRML_LIVE_TAG:-}"

clone_or_update \
    "https://github.com/grml/grml-debootstrap.git" \
    "$GRML_DEBOOTSTRAP_SRC" \
    "${GRML_DEBOOTSTRAP_TAG:-}"

# ---------------------------------------------------------------------------
# 4. Verify the key commands are now on PATH.
# ---------------------------------------------------------------------------
require_cmd \
    grml-live \
    grml-debootstrap \
    reprepro \
    xorriso \
    debootstrap \
    mmdebstrap \
    mksquashfs

log_ok "00-prepare-host.sh finished.  Host is ready."
