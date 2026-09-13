#!/usr/bin/env bash
# =============================================================================
# 01-extract-tasksel-lists.sh -- Resolve Debian task definitions to concrete
#                                package lists for the four ISO recipes
# =============================================================================
# Earlier approach (mmdebstrap chroot + tasksel --task-packages) broke because:
#   * mmdebstrap is not always available on Ubuntu build hosts
#   * tasksel --task-packages on Ubuntu returns Ubuntu packages, not Debian's
#   * The "standard" task is not a meta-package -- it means "Priority >= standard"
#
# This rewrite downloads and parses the Debian Packages index directly.
# No chroot, no network-accessible apt, no architecture mismatch.
#
# How each list is derived:
#
#   debian-base.list   -- All packages with Priority: required, important, or
#                         standard in Debian/trixie main.  This is exactly what
#                         tasksel's "standard" task installs.
#
#   debian-gnome.list  -- Recursive Depends + Recommends expansion of the
#                         task-gnome-desktop meta-package plus all standard-
#                         priority packages (standard is a subset of GNOME).
#
#   grml-base.list     -- Read directly from grml-live's git tree:
#                         templates/config/package_config/GRMLBASE
#
#   grml-gnome.list    -- Merge of GRMLBASE + GRML_FULL (from git) +
#                         debian-gnome.list.
#
# Output: packages-tasksel/<name>.list  (one package name per line, sorted)
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
log_step "01-extract-tasksel-lists.sh starting"

OUT_DIR="${PROJECT_ROOT}/packages-tasksel"
mkdir -p "$OUT_DIR"

PKGCACHE="${BUILD_ROOT}/debian-packages-index"
mkdir -p "$PKGCACHE"

# ---------------------------------------------------------------------------
# 1. Download and decompress the Debian trixie/main Packages index
# ---------------------------------------------------------------------------
PACKAGES_GZ="${PKGCACHE}/Packages.gz"
PACKAGES_TXT="${PKGCACHE}/Packages.txt"

log_info "Downloading Debian ${DEBIAN_SUITE}/main Packages index..."
curl -fsSL \
    "${DEBIAN_MIRROR}/dists/${DEBIAN_SUITE}/main/binary-${ARCH}/Packages.gz" \
    -o "$PACKAGES_GZ"
gunzip -f "$PACKAGES_GZ"    # writes Packages (no .gz); rename for clarity
mv "${PKGCACHE}/Packages" "$PACKAGES_TXT"
log_ok "Packages index: $(wc -l < "$PACKAGES_TXT") lines"

# ---------------------------------------------------------------------------
# 2. Python helper -- parses the Packages index once, then:
#    a) Extracts packages by Priority level      (for debian-base)
#    b) Recursively expands a meta-package's
#       Depends + Recommends                     (for debian-gnome)
# ---------------------------------------------------------------------------
HELPER_PY="${PKGCACHE}/resolve.py"
cat > "$HELPER_PY" << 'PYEOF'
#!/usr/bin/env python3
"""
Parse a Debian Packages index and resolve package lists.

Usage:
  resolve.py <Packages.txt> priority <required|important|standard>
      Emit all packages whose Priority is >= the given level.
      (required > important > standard in Debian priority ordering)

  resolve.py <Packages.txt> expand <pkg1> [pkg2 ...]
      Recursively expand the Depends+Recommends of the given packages,
      emitting a sorted unique list of every package reachable.
"""

import sys
import re
from collections import defaultdict

PRIORITY_ORDER = ["required", "important", "standard", "optional", "extra"]

def parse_packages(path):
    """Return a dict: name -> {'Priority': str, 'Depends': [str], 'Recommends': [str]}"""
    pkgs = {}
    current = {}
    with open(path, encoding="utf-8", errors="replace") as f:
        for raw in f:
            line = raw.rstrip("\n")
            if line == "":
                if "Package" in current:
                    pkgs[current["Package"]] = current
                current = {}
            elif line.startswith(" "):
                # Continuation -- we don't need multi-line values for our purpose
                pass
            elif ":" in line:
                k, _, v = line.partition(":")
                current[k.strip()] = v.strip()
    if "Package" in current:
        pkgs[current["Package"]] = current
    return pkgs

def dep_names(dep_str):
    """Extract bare package names from a Depends/Recommends value string.
    Handles:  pkg, pkg (>= ver), pkg | alt, ...
    Returns a flat list of all alternative names (we take the first alt).
    """
    names = []
    for clause in dep_str.split(","):
        # Take only the first alternative in an OR group
        first_alt = clause.split("|")[0]
        # Strip version constraint and arch qualifier
        m = re.match(r"\s*([a-zA-Z0-9_.+\-]+)", first_alt)
        if m:
            names.append(m.group(1))
    return names

def by_priority(pkgs, min_priority):
    cutoff = PRIORITY_ORDER.index(min_priority)
    result = set()
    for name, info in pkgs.items():
        prio = info.get("Priority", "optional").lower()
        if prio in PRIORITY_ORDER and PRIORITY_ORDER.index(prio) <= cutoff:
            result.add(name)
    return sorted(result)

def expand(pkgs, seeds, with_recommends=True):
    """BFS over Depends (+optionally Recommends) starting from seeds."""
    visited = set()
    queue = list(seeds)
    while queue:
        pkg = queue.pop(0)
        if pkg in visited:
            continue
        visited.add(pkg)
        info = pkgs.get(pkg, {})
        for field in (["Depends", "Recommends"] if with_recommends else ["Depends"]):
            for dep in dep_names(info.get(field, "")):
                if dep and dep not in visited:
                    queue.append(dep)
    return sorted(visited)

if __name__ == "__main__":
    if len(sys.argv) < 4:
        sys.exit(__doc__)
    packages_file = sys.argv[1]
    command = sys.argv[2]
    args = sys.argv[3:]

    pkgs = parse_packages(packages_file)

    if command == "priority":
        for p in by_priority(pkgs, args[0]):
            print(p)
    elif command == "expand":
        for p in expand(pkgs, args):
            print(p)
    else:
        sys.exit(f"Unknown command: {command}")
PYEOF
chmod +x "$HELPER_PY"

# ---------------------------------------------------------------------------
# 3. debian-base.list  -- Priority >= standard
# ---------------------------------------------------------------------------
log_info "Building debian-base.list (Priority: required + important + standard)..."
python3 "$HELPER_PY" "$PACKAGES_TXT" priority standard \
    | sort -u > "$OUT_DIR/debian-base.list"
log_ok "debian-base.list: $(wc -l < "$OUT_DIR/debian-base.list") packages"

# ---------------------------------------------------------------------------
# 4. debian-gnome.list  -- task-gnome-desktop expanded + standard base
# ---------------------------------------------------------------------------
log_info "Building debian-gnome.list (task-gnome-desktop recursively expanded)..."
# Expand task-gnome-desktop and task-desktop (its parent in tasksel terms).
# We also seed with task-standard (the Priority>=standard set already covers it
# but adding the explicit seeds ensures we don't miss anything).
python3 "$HELPER_PY" "$PACKAGES_TXT" expand \
    task-gnome-desktop task-desktop task-standard \
    | sort -u > "$OUT_DIR/debian-gnome-expanded.list"

# Union with the base standard packages (the GNOME task always implies the
# standard system).
sort -u \
    "$OUT_DIR/debian-base.list" \
    "$OUT_DIR/debian-gnome-expanded.list" \
    > "$OUT_DIR/debian-gnome.list"

rm -f "$OUT_DIR/debian-gnome-expanded.list"
log_ok "debian-gnome.list: $(wc -l < "$OUT_DIR/debian-gnome.list") packages"

# ---------------------------------------------------------------------------
# 5. grml-base.list  -- read from grml-live git tree
# ---------------------------------------------------------------------------
# grml-live stores package lists as plain text files under
#   templates/config/package_config/<CLASSNAME>
# Each non-comment, non-PACKAGE-directive line is a package name.
extract_grml_class() {
    local class="$1"
    local outfile="$2"

    # Try several candidate paths; grml-live has moved things around over time.
    local candidates=(
        "${GRML_LIVE_SRC}/templates/config/package_config/${class}"
        "${GRML_LIVE_SRC}/etc/grml/fai/config/package_config/${class}"
        "${GRML_LIVE_SRC}/config/package_config/${class}"
    )
    local found=""
    for f in "${candidates[@]}"; do
        [[ -f "$f" ]] && { found="$f"; break; }
    done

    if [[ -z "$found" ]]; then
        log_warn "Cannot find package_config for class '${class}' in ${GRML_LIVE_SRC}"
        log_warn "Searched: ${candidates[*]}"
        log_warn "Generating empty list -- run 00-prepare-host.sh to clone grml-live."
        touch "$outfile"
        return 0
    fi

    grep -vE '^[[:space:]]*(#|$)' "$found" \
        | grep -vE '^PACKAGE[[:space:]]' \
        | sort -u \
        > "$outfile"

    log_ok "grml class '${class}': $(wc -l < "$outfile") packages (from $found)"
}

log_info "Building grml-base.list from GRMLBASE class..."
extract_grml_class "GRMLBASE" "$OUT_DIR/grml-base.list"

# ---------------------------------------------------------------------------
# 6. grml-gnome.list  -- GRMLBASE + GRML_FULL + debian-gnome
# ---------------------------------------------------------------------------
log_info "Building grml-gnome.list..."
TMP_FULL=$(mktemp)
extract_grml_class "GRML_FULL" "$TMP_FULL"
sort -u \
    "$OUT_DIR/grml-base.list" \
    "$TMP_FULL" \
    "$OUT_DIR/debian-gnome.list" \
    > "$OUT_DIR/grml-gnome.list"
rm -f "$TMP_FULL"
log_ok "grml-gnome.list: $(wc -l < "$OUT_DIR/grml-gnome.list") packages"

# ---------------------------------------------------------------------------
# 7. Summary
# ---------------------------------------------------------------------------
log_step "Package list summary"
for f in "$OUT_DIR"/*.list; do
    printf '  %-32s %5d packages\n' "$(basename "$f")" "$(wc -l < "$f")" >&2
done

log_ok "01-extract-tasksel-lists.sh finished."
