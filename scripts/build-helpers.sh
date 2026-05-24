#!/usr/bin/env bash
# =============================================================================
# build-helpers.sh -- Shared functions used by scripts/03[a-d]-build-*.sh
# =============================================================================
# Sourced (never executed directly).  Assumes config/common.sh was already
# sourced by the calling script.
#
# GRML-LIVE FACTS (from reading the source at github.com/grml/grml-live):
#
#   CLI flags relevant to us:
#     -a ARCH          target architecture
#     -c CLASSES       comma-separated FAI class list
#     -C LOCAL_CONF    path to a grml-live.conf override file
#     -D GRML_FAI_CONFIG  path to the config tree (replaces default
#                          /usr/share/grml-live/config)
#     -F               force (no interactive prompts)
#     -g GRML_NAME     flavour name (used in ISO filenames)
#     -o OUTPUT        top-level output directory
#     -s SUITE         Debian suite (e.g. trixie)
#     -v VERSION       version string embedded in ISO
#
#   Output layout under $OUTPUT:
#     grml_chroot/     ← the built chroot (always this name, no flavour subdir)
#     grml_cd/         ← ISO staging area (syslinux, live/, etc.)
#     grml_isos/       ← final .iso files
#     grml_logs/       ← build logs
#
#   Config tree layout ($GRML_FAI_CONFIG):
#     package_config/<CLASS>   one package per non-comment line
#     scripts/<CLASS>/         executable hook scripts
#     hooks/<CLASS>/           FAI hooks (faibase, chboot, …)
#     env/<CLASS>              shell variable assignments (no "class/" dir!)
#     files/<CLASS>/           files to be copied verbatim into the chroot
#     debconf/<CLASS>          debconf preseeds
#
#   Custom classes:
#     Drop a file at package_config/<MYCLASS> with package names.
#     Optionally add env/<MYCLASS> for variable assignments.
#     No registration step needed -- just name it in the -c list.
# =============================================================================

# ACTIVE_OPT_LEVEL: which compiled opt-level's repo gets embedded in the ISO.
# Defaults to the last (highest) element in OPT_LEVELS.
if [[ -z "${ACTIVE_OPT_LEVEL+_}" ]]; then
    last_idx=$(( ${#OPT_LEVELS[@]} - 1 ))
    ACTIVE_OPT_LEVEL="${OPT_LEVELS[$last_idx]}"
fi

# ---------------------------------------------------------------------------
# prepare_grml_config CLASSNAME PKGLIST
# ---------------------------------------------------------------------------
# Creates a custom grml-live config tree at $BUILD_ROOT/grml-config-<class>/
# by copying the stock tree from the installed grml-live and overlaying:
#   * package_config/<CLASSNAME>  ← from $PKGLIST
#   * env/<CLASSNAME>             ← minimal var file
#   * scripts/<CLASSNAME>/10-local-repo  ← injects our reprepro apt source
#
# Prints the path of the prepared config tree on stdout.
prepare_grml_config() {
    local classname="$1"   # e.g. DEBIAN_BASE, GRML_GNOME
    local pkglist="$2"     # absolute path to the package list file

    # Locate the installed stock config tree.
    local stock
    if   [[ -d /usr/share/grml-live/config ]]; then
        stock=/usr/share/grml-live/config
    elif [[ -d "${GRML_LIVE_SRC}/config" ]]; then
        stock="${GRML_LIVE_SRC}/config"
    else
        die "Cannot find grml-live stock config tree.  Run 00-prepare-host.sh."
    fi

    local custom="${BUILD_ROOT}/grml-config-${classname}"
    log_info "Preparing grml-live config at ${custom}"

    rm -rf "$custom"
    cp -a "$stock" "$custom"

    # ---- ensure bootstrap-keyring entries are real files, not broken symlinks ----
    # minifai.py uses Path.exists() which returns False for broken symlinks.
    # The stock config tree has symlinks -> /usr/share/keyrings/debian-archive-keyring.gpg
    # which requires debian-archive-keyring to be installed.  We copy the real
    # bytes here so the build works even if that package was installed after
    # the initial cp, and to guard against race conditions.
    local gpg_keyring="/usr/share/keyrings/debian-archive-keyring.gpg"
    if [[ -f "$gpg_keyring" ]]; then
        local kb="${custom}/bootstrap-keyring"
        for link in "${kb}"/DEBIAN_*; do
            [[ -L "$link" && ! -e "$link" ]] && cp --remove-destination "$gpg_keyring" "$link"
        done
        # Also ensure our custom class has an entry (minifai needs at least one hit).
        [[ ! -f "${kb}/${classname}" ]] && cp "$gpg_keyring" "${kb}/${classname}"
    else
        die "debian-archive-keyring not installed -- run: apt-get install debian-archive-keyring"
    fi

    # ---- package list for our custom class ---------------------------------
    # Prepend the arch-specific kernel package so 16-depmod finds a real
    # /boot/vmlinuz-* to run depmod on.  GRML_FULL/GRML_SMALL already include
    # this; for our Debian-based custom classes we add it here.
    {
        echo "PACKAGES install"
        echo "linux-image-amd64"
        echo ""
        cat "$pkglist"
    } > "${custom}/package_config/${classname}"

    # ---- env file (variable assignments read by grml-live hooks) -----------
    # No "class/" directory exists in the grml-live config tree.
    # Variable overrides go into env/<CLASSNAME>.
    mkdir -p "${custom}/env"
    cat > "${custom}/env/${classname}" <<EOF
# Environment for ${classname} build (-O${ACTIVE_OPT_LEVEL})
TIMEZONE=Etc/UTC
EOF

    # ---- hook: inject local reprepro repo before package installation ------
    # Scripts under scripts/<CLASS>/ are executed inside the chroot after
    # bootstrap.  Naming it "10-local-repo" ensures it runs early.
    mkdir -p "${custom}/scripts/${classname}"
    cat > "${custom}/scripts/${classname}/10-local-repo" <<HOOK
#!/bin/sh
# Injected by iso-build: add the locally rebuilt apt repository so
# packages built with -O${ACTIVE_OPT_LEVEL} are preferred over upstream.
set -e
mkdir -p /etc/apt/sources.list.d /etc/apt/preferences.d

# The local repo is bind-mounted at /srv/local-repo by grml-live's
# MIRROR_DIRECTORY / EXTRA_BIND_MOUNTS mechanism (set in grml-live.conf).
cat > /etc/apt/sources.list.d/iso-build-local.sources <<EOF
Types: deb
URIs: file:///srv/local-repo
Suites: ${DEBIAN_SUITE}-O${ACTIVE_OPT_LEVEL}
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
    chmod +x "${custom}/scripts/${classname}/10-local-repo"

    # Return the path so the caller can capture it.
    echo "$custom"
}

# ---------------------------------------------------------------------------
# run_grml_live FLAVOUR CONFIGTREE CLASSES
# ---------------------------------------------------------------------------
# Wraps grml-live with the correct flags.  Returns the path of the finished
# chroot on stdout so the calling script can post-process it.
run_grml_live() {
    local flavour="$1"    # human name, used in output dir and ISO filename
    local configtree="$2" # path returned by prepare_grml_config
    local classes="$3"    # comma-separated class list, e.g. GRMLBASE,DEBIAN_BASE

    # grml-live always places its output under $OUTPUT/grml_chroot (fixed name).
    local output="${ISO_OUT_DIR}/${flavour}-O${ACTIVE_OPT_LEVEL}"
    mkdir -p "$output"

    # grml-live.conf override file — sets variables that can't be passed as flags.
    local conf="${BUILD_ROOT}/grml-live-${flavour}.conf"
    local local_repo_path="${LOCAL_REPO_ROOT}/O${ACTIVE_OPT_LEVEL}"

    cat > "$conf" <<EOF
# grml-live local config for flavour=${flavour}, -O${ACTIVE_OPT_LEVEL}
# Generated by iso-build/config/build-helpers.sh -- do not edit by hand.

# Debian suite and mirror
SUITE="${DEBIAN_SUITE}"
BOOTSTRAP_MIRROR="${DEBIAN_MIRROR}"

# Local repo is injected via the 10-local-repo hook script in scripts/<CLASS>/.
EOF

    log_info "Running grml-live: flavour=${flavour} classes=${classes}"
    log_info "  Output: ${output}"
    log_info "  Config: ${configtree}"

    # grml-live flags:
    #   -F        force (skip interactive prompts)
    #   -a ARCH   target architecture
    #   -s SUITE  Debian suite
    #   -c CLASSES comma-separated class list
    #   -D PATH   path to the FAI config tree (our custom one)
    #   -C PATH   path to a grml-live.conf override file
    #   -g NAME   grml flavour name (used in ISO name)
    #   -o PATH   top-level output directory
    #   -v VER    version string
    local grml_log="${output}/grml-live-build.log"
    mkdir -p "$output"

    # Remove any stale chroot from a previous failed run.
    # mmdebstrap fails with "File exists" if /dev/console etc. are already
    # present from an earlier attempt.  Wipe only the chroot subdir, not
    # the whole output tree (that would delete the log of the previous run).
    local stale_chroot="${output}/grml_chroot"
    if [[ -d "$stale_chroot" ]]; then
        log_warn "Removing stale chroot at ${stale_chroot}"
        # Some bind-mounts may still be active; try to unmount them first.
        for mp in proc sys dev/pts dev; do
            mountpoint -q "${stale_chroot}/${mp}" 2>/dev/null &&                 umount -l "${stale_chroot}/${mp}" 2>/dev/null || true
        done
        rm -rf "$stale_chroot"
    fi

    # Redirect grml-live output to a log file.
    # CRITICAL: we use $() to capture this function's stdout as the chroot path.
    # If grml-live's verbose output leaks into stdout it gets captured too,
    # producing a multi-megabyte string that exceeds ARG_MAX when passed as $1
    # to the 04-finalize-iso-*.sh scripts ("Argument list too long").
    log_info "grml-live log: ${grml_log}"
    grml-live \
        -F \
        -a "$ARCH" \
        -s "$DEBIAN_SUITE" \
        -c "$classes" \
        -D "$configtree" \
        -C "$conf" \
        -g "$flavour" \
        -o "$output" \
        -v "1.0" \
        >"$grml_log" 2>&1 || {
            log_error "grml-live failed -- last 30 lines of ${grml_log}:"
            tail -30 "$grml_log" >&2
            die "grml-live exited non-zero for flavour=${flavour}"
        }

    # grml-live puts the chroot at $OUTPUT/grml_chroot (fixed name, no flavour subdir).
    local chroot="${output}/grml_chroot"
    [[ -d "$chroot" ]] || die "grml-live finished but no chroot at ${chroot}"
    # Print ONLY the path -- this line is what CHROOT=$(...) captures.
    echo "$chroot"
}

# ---------------------------------------------------------------------------
# cleanup_grml_mounts CHROOT
# ---------------------------------------------------------------------------
# Called from traps in the 03* scripts to ensure bind-mounts are released
# even if the script aborts early.
cleanup_grml_mounts() {
    local chroot="${1:-}"
    [[ -d "$chroot" ]] || return 0
    for mp in srv/local-repo proc sys dev/pts dev; do
        if mountpoint -q "${chroot}/${mp}" 2>/dev/null; then
            umount "${chroot}/${mp}" 2>/dev/null || true
        fi
    done
}
