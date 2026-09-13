#!/usr/bin/env bash
# =============================================================================
# 02-build-source-repo.sh  --  Rebuild packages from source at each opt-level
# =============================================================================
# USAGE:
#   sudo scripts/02-build-source-repo.sh packages-tasksel/debian-base.list
#   sudo OPT_LEVELS_STR="2 3" scripts/02-build-source-repo.sh packages-tasksel/debian-gnome.list
#
# WHAT THIS SCRIPT DOES
# ---------------------
# 1. Resolves the binary package names in the list to their *source* package
#    names using the Packages.txt cache written by 01-extract-tasksel-lists.sh.
#    (vim-common → vim,  whiptail → newt,  wamerican → scowl, …)
#
# 2. Adds a deb-src apt line so `apt-get source` can fetch .dsc files.
#
# 3. Creates one pbuilder chroot per optimisation level (Debian trixie, clean).
#    Build-deps are installed inside the chroot — no Ubuntu/Debian version
#    conflicts possible.
#
# 4. For each source package × opt-level: builds inside pbuilder, publishes
#    .debs to the per-level reprepro repo.  Failures are logged and skipped
#    (the ISO build later falls back to upstream binaries for those).
#
# RESUMABILITY
#   Re-run any time.  Successfully built (level, pkg) pairs are skipped
#   unless FORCE=1.
#
# ENV OVERRIDES
#   FORCE=1            rebuild even if marker exists
#   PARALLEL_PKGS=N    concurrent pbuilder runs (default 1)
#   KEEP_CHROOT=1      keep the pbuilder build place for debugging
# =============================================================================

SELF="$(readlink -f "${BASH_SOURCE[0]}" 2>/dev/null || realpath "${BASH_SOURCE[0]}" 2>/dev/null || echo "${BASH_SOURCE[0]}")"
SCRIPT_DIR="$(dirname "$SELF")"
if   [[ -f "${SCRIPT_DIR}/config/common.sh" ]];    then COMMON_SH="${SCRIPT_DIR}/config/common.sh"
elif [[ -f "${SCRIPT_DIR}/../config/common.sh" ]]; then COMMON_SH="${SCRIPT_DIR}/../config/common.sh"
else echo "[ERR] Cannot find config/common.sh near ${SCRIPT_DIR}" >&2; exit 1; fi
# shellcheck source=../config/common.sh
source "$COMMON_SH"

require_root
print_banner

PKG_LIST="${1:-}"
[[ -n "$PKG_LIST" && -f "$PKG_LIST" ]] || die "Usage: $0 <package-list-file>"
log_step "02-build-source-repo.sh  list=$(basename "$PKG_LIST")  levels=(${OPT_LEVELS[*]})"

PARALLEL_PKGS="${PARALLEL_PKGS:-1}"
MARKERS="${BUILD_ROOT}/markers"
FAILURES="${BUILD_ROOT}/failures"
WORK="${SOURCE_CACHE}/work"
PBUILDER_DIR="${BUILD_ROOT}/pbuilder"
mkdir -p "$MARKERS" "$WORK" "$PBUILDER_DIR"

# ---------------------------------------------------------------------------
# 0. Prerequisites
# ---------------------------------------------------------------------------
# Install pbuilder if missing (00-prepare-host.sh should have done this,
# but guard here so the script is self-contained).
if ! command -v pbuilder >/dev/null 2>&1; then
    log_info "Installing pbuilder..."
    apt-get install -y --no-install-recommends pbuilder debian-archive-keyring
fi
require_cmd pbuilder reprepro apt-get python3

# ---------------------------------------------------------------------------
# 1. Add deb-src lines so apt-get source can fetch .dsc files
# ---------------------------------------------------------------------------
APT_SRC_FILE="/etc/apt/sources.list.d/iso-build-deb-src.sources"
if [[ ! -f "$APT_SRC_FILE" ]]; then
    log_info "Adding deb-src entries for ${DEBIAN_SUITE}..."
    cat > "$APT_SRC_FILE" <<EOF
Types: deb-src
URIs: ${DEBIAN_MIRROR}
Suites: ${DEBIAN_SUITE} ${DEBIAN_SUITE}-updates
Components: main contrib
Signed-By: /usr/share/keyrings/debian-archive-keyring.gpg
EOF
    apt-get update -qq
fi

# ---------------------------------------------------------------------------
# 2. Resolve binary package names → unique source package names
#    Uses the Packages.txt cache from 01-extract-tasksel-lists.sh
# ---------------------------------------------------------------------------
PACKAGES_TXT="${BUILD_ROOT}/debian-packages-index/Packages.txt"
SRC_LIST="${WORK}/source-packages.list"
mkdir -p "$WORK"

if [[ ! -f "$PACKAGES_TXT" ]]; then
    log_info "Packages.txt cache missing -- downloading..."
    mkdir -p "$(dirname "$PACKAGES_TXT")"
    curl -fsSL \
        "${DEBIAN_MIRROR}/dists/${DEBIAN_SUITE}/main/binary-${ARCH}/Packages.gz" \
        | gunzip > "$PACKAGES_TXT"
fi

log_info "Resolving binary→source names using $PACKAGES_TXT..."
python3 - "$PACKAGES_TXT" "$PKG_LIST" "$SRC_LIST" << 'PYEOF'
import sys

packages_file, binary_list_file, out_file = sys.argv[1:4]

# Parse the Packages index into a binary→source map.
# The "Source:" field is optional; when absent, source name == binary name.
# The field can be "srcname (version)" -- we discard the version.
bin_to_src = {}
current_pkg = None
current_src = None
with open(packages_file, encoding="utf-8", errors="replace") as f:
    for line in f:
        line = line.rstrip("\n")
        if line == "":
            if current_pkg:
                bin_to_src[current_pkg] = (current_src or current_pkg)
            current_pkg = current_src = None
        elif line.startswith("Package: "):
            current_pkg = line[9:].strip()
            current_src = None
        elif line.startswith("Source: "):
            # Strip optional version "(1.2.3)" from field value
            current_src = line[8:].strip().split()[0]
    if current_pkg:
        bin_to_src[current_pkg] = (current_src or current_pkg)

seen = set()
with open(binary_list_file) as inp, open(out_file, "w") as out:
    for line in inp:
        binary = line.strip()
        if not binary or binary.startswith("#"):
            continue
        src = bin_to_src.get(binary, binary)
        if src not in seen:
            seen.add(src)
            out.write(src + "\n")
PYEOF

log_ok "$(wc -l < "$SRC_LIST") unique source packages from $(wc -l < "$PKG_LIST") binary names"
log_info "Sample mappings (first 8):"
head -8 "$SRC_LIST" | while IFS= read -r s; do log_info "  $s"; done

# ---------------------------------------------------------------------------
# 3. Initialise per-level reprepro repositories
# ---------------------------------------------------------------------------
init_repo() {
    local lvl="$1"
    local repo="${LOCAL_REPO_ROOT}/O${lvl}"
    [[ -f "${repo}/conf/distributions" ]] && return 0
    log_info "Initialising reprepro repo -O${lvl}..."
    mkdir -p "${repo}/conf"
    cat > "${repo}/conf/distributions" <<EOF
Origin: iso-build
Label: iso-build
Codename: ${DEBIAN_SUITE}-O${lvl}
Suite: ${DEBIAN_SUITE}-O${lvl}
Architectures: ${ARCH} source
Components: main
Description: Debian ${DEBIAN_SUITE} rebuilt with -O${lvl}
EOF
    printf 'verbose\nbasedir %s\n' "$repo" > "${repo}/conf/options"
}
for lvl in $(opt_levels_iter); do init_repo "$lvl"; done

# ---------------------------------------------------------------------------
# 4. Create pbuilder base chroot per opt-level
#    Each is a minimal Debian trixie environment.  Our local reprepro repo
#    is bind-mounted in at /srv/local-repo and pinned at priority 1001 via
#    a D-hook, so packages we already rebuilt are used as build-deps
#    for later packages.
# ---------------------------------------------------------------------------
create_base() {
    local lvl="$1"
    local base="${PBUILDER_DIR}/base-O${lvl}.tgz"
    [[ -f "$base" && "${FORCE:-0}" -ne 1 ]] && return 0
    log_info "Creating pbuilder base chroot -O${lvl}  (≈2 min)..."

    local hookdir="${PBUILDER_DIR}/hooks-O${lvl}"
    mkdir -p "$hookdir"

    # D-hook: runs after debootstrap inside the new chroot.
    # Injects our local-repo apt source + priority pin so builds inside
    # pbuilder prefer our rebuilt packages as build-deps.
    # shellcheck disable=SC2154
    cat > "${hookdir}/D01local-repo" <<HOOK
#!/bin/sh
set -e
mkdir -p /etc/apt/sources.list.d /etc/apt/preferences.d
cat > /etc/apt/sources.list.d/iso-build-local.sources <<EOF
Types: deb
URIs: file:///srv/local-repo
Suites: ${DEBIAN_SUITE}-O${lvl}
Components: main
Architectures: ${ARCH}
Trusted: yes
EOF
cat > /etc/apt/preferences.d/iso-build-local <<EOF
Package: *
Pin: release o=iso-build,l=iso-build
Pin-Priority: 1001
EOF
apt-get update -qq 2>/dev/null || true
HOOK
    chmod +x "${hookdir}/D01local-repo"

    local repo_path="${LOCAL_REPO_ROOT}/O${lvl}"
    mkdir -p "$repo_path" "${PBUILDER_DIR}/aptcache" "${PBUILDER_DIR}/results"

    # Write the pbuilderrc for this level.
    # We export the DEB_*FLAGS_APPEND vars so dpkg-buildpackage inside
    # pbuilder sees the correct -O flag.
    local rc="${PBUILDER_DIR}/pbuilderrc-O${lvl}"
    # Build the flag exports as a string first (opt_level_to_debenv returns
    # multi-line KEY="VALUE" pairs; we join them for inclusion in the rc file).
    local flag_exports
    flag_exports="$(opt_level_to_debenv "$lvl" | sed 's/^/export /')"
    cat > "$rc" <<RC
BASETGZ="${base}"
DISTRIBUTION="${DEBIAN_SUITE}"
MIRRORSITE="${DEBIAN_MIRROR}"
COMPONENTS="main contrib"
ARCHITECTURE="${ARCH}"
HOOKDIR="${hookdir}"
BINDMOUNTS="${repo_path}:/srv/local-repo"
BUILDRESULT="${PBUILDER_DIR}/results"
APTCACHE="${PBUILDER_DIR}/aptcache"
CCACHEDIR=""
export DEB_BUILD_OPTIONS="parallel=$(nproc) nocheck"
${flag_exports}
RC

    pbuilder --create \
        --configfile "$rc" \
        --debootstrapopts "--include=eatmydata,ca-certificates,doxygen" \
        2>&1 | grep -E "^(I:|[WE]:)" | grep -v "unsandboxed" || true

    log_ok "pbuilder base -O${lvl}: $base"
}
for lvl in $(opt_levels_iter); do create_base "$lvl"; done

# ---------------------------------------------------------------------------
# 5. Build one source package at one opt-level
# ---------------------------------------------------------------------------
build_one() {
    local lvl="$1"
    local src="$2"
    local marker="${MARKERS}/O${lvl}__${src}.done"

    if [[ -f "$marker" && "${FORCE:-0}" -ne 1 ]]; then
        log_info "[O${lvl}] $src already built -- skipping"
        return 0
    fi

    log_step "[O${lvl}] $src"

    local work="${WORK}/O${lvl}/${src}"
    rm -rf "$work"; mkdir -p "$work"
    pushd "$work" >/dev/null

    mkdir -p "${FAILURES}/O${lvl}"
    local logfile="${FAILURES}/O${lvl}/${src}.log"

    # ---- 5a. Fetch source --------------------------------------------------
    if ! apt-get source --only-source "$src" >"$logfile" 2>&1; then
        log_warn "[O${lvl}] $src: no source package found -- skipping"
        popd >/dev/null; return 0
    fi
    local dsc; dsc="$(find . -maxdepth 1 -name '*.dsc' | head -1)"
    if [[ -z "$dsc" ]]; then
        log_warn "[O${lvl}] $src: apt-get source produced no .dsc -- skipping"
        popd >/dev/null; return 0
    fi

    # ---- 5b. Build inside pbuilder chroot ----------------------------------
    local rc="${PBUILDER_DIR}/pbuilderrc-O${lvl}"
    local results="${PBUILDER_DIR}/results"
    # Clear previous results for this source so we don't re-publish stale debs.
    find "$results" -maxdepth 1 \( -name '*.deb' -o -name '*.buildinfo' -o -name '*.changes' \) \
        -delete 2>/dev/null || true

    local pb_opts=()
    [[ "${KEEP_CHROOT:-0}" -eq 1 ]] && pb_opts+=(--preserve-buildplace)

    if ! pbuilder --build \
            --configfile "$rc" \
            "${pb_opts[@]}" \
            "$dsc" >> "$logfile" 2>&1; then
        log_error "[O${lvl}] $src FAILED  (log: $logfile)"
        echo "$src" >> "${FAILURES}/O${lvl}/FAILED.list"
        popd >/dev/null; return 0  # non-fatal: keep going
    fi

    # ---- 5c. Publish to reprepro -------------------------------------------
    local repo="${LOCAL_REPO_ROOT}/O${lvl}"
    local added=0
    for deb in "$results"/*.deb; do
        [[ -f "$deb" ]] || continue
        reprepro -b "$repo" includedeb "${DEBIAN_SUITE}-O${lvl}" "$deb" \
            >> "$logfile" 2>&1 && added=$((added+1))
    done
    if [[ $added -gt 0 ]]; then
        touch "$marker"
        log_ok "[O${lvl}] $src  →  $added .deb(s) published"
    else
        log_warn "[O${lvl}] $src: build OK but no .debs published (check $logfile)"
    fi

    popd >/dev/null
    rm -rf "$work"
}

# Export everything build_one needs when called from xargs subshells
export -f build_one log_info log_warn log_error log_ok log_step die \
           opt_level_to_debenv opt_levels_iter
export PROJECT_ROOT BUILD_ROOT LOCAL_REPO_ROOT SOURCE_CACHE WORK MARKERS FAILURES
export DEBIAN_SUITE DEBIAN_MIRROR ARCH PBUILDER_DIR FORCE KEEP_CHROOT
export _C_RED _C_YELLOW _C_GREEN _C_BLUE _C_DIM _C_OFF

# ---------------------------------------------------------------------------
# 6. Main loop: levels × packages
# ---------------------------------------------------------------------------
TOTAL=$(wc -l < "$SRC_LIST")
log_step "Building ${TOTAL} source packages × ${#OPT_LEVELS[@]} level(s)"

for lvl in $(opt_levels_iter); do
    log_step "=== Optimization level -O${lvl} ==="
    mkdir -p "${FAILURES}/O${lvl}"
    # Clear failure list at the start of each run so re-runs don't double-count.
    rm -f "${FAILURES}/O${lvl}/FAILED.list"
    # --halt=never keeps going after individual failures.
    xargs -P "$PARALLEL_PKGS" \
          -a "$SRC_LIST" \
          -I{} \
          bash -c 'build_one "$0" "$1"' "$lvl" "{}"
done

# ---------------------------------------------------------------------------
# 7. Summary
# ---------------------------------------------------------------------------
log_step "Build complete"
NFAILED=0
for lvl in $(opt_levels_iter); do
    flist="${FAILURES}/O${lvl}/FAILED.list"
    # Deduplicate in case a package somehow appears more than once.
    [[ -f "$flist" ]] && sort -u "$flist" -o "$flist"
    if [[ -f "$flist" && -s "$flist" ]]; then
        n=$(wc -l < "$flist")
        NFAILED=$((NFAILED + n))
        log_warn "-O${lvl}: $n failure(s)  (logs in ${FAILURES}/O${lvl}/)"
        sed 's/^/    /' "$flist" >&2
    else
        log_ok  "-O${lvl}: all packages built"
    fi
done
[[ $NFAILED -gt 0 ]] && \
    log_warn "Total: $NFAILED package(s) failed -- ISO will use upstream binaries for these"
log_ok "02-build-source-repo.sh finished."
