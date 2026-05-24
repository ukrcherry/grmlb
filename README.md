# iso-build — Build Debian 13 installation ISOs from source, the grml way

A bash-only build suite that produces four flavours of installation ISO,
each rebuilt from upstream Debian sources at a configurable optimization
level, packaged using the grml live-system tooling.

## What gets built

| Flavour        | Package list source                                 | Approx ISO size |
| -------------- | --------------------------------------------------- | --------------- |
| `debian-base`  | tasksel `standard` task                             | ~600 MB         |
| `debian-gnome` | tasksel `gnome-desktop` task (+ standard)           | ~3 GB           |
| `grml-base`    | grml `GRMLBASE` class                               | ~700 MB         |
| `grml-gnome`   | `GRMLBASE` + `GRML_FULL` + tasksel `gnome-desktop`  | ~3.5 GB         |

Each flavour can be produced in **two layouts**:

- **MBR** — legacy BIOS, hybrid MBR for USB sticks. (`scripts/04-finalize-iso-mbr.sh`)
- **GPT** — UEFI primary, with a BIOS fallback. (`scripts/04-finalize-iso-gpt.sh`)

Each flavour can be **compiled at any subset of -O0 / -O1 / -O2 / -O3** by
setting the `OPT_LEVELS` array. Each level produces its own local apt
repository (`$BUILD_ROOT/repo/O0/`, `O1/`, `O2/`, `O3/`); the ISO is built
from whichever level you set as `ACTIVE_OPT_LEVEL` (default = highest).

## Honest expectations

Rebuilding **every** package the GNOME ISO ships (~1500 source packages)
**from scratch** at four optimization levels is roughly **5,000 package
builds**. On a modern 16-thread workstation that is **2–4 days of CPU time
per flavour** plus 60–100 GB of disk. The framework supports it, but in
practice you will want to either:

1. Constrain `OPT_LEVELS` to one level (e.g. `OPT_LEVELS=(2)`), and/or
2. Run the smaller flavours first to validate the pipeline.

The scripts are **resumable**: every `(level, package)` pair that finishes
successfully gets a marker file under `$BUILD_ROOT/markers/`, so a re-run
after a crash picks up where it left off.

## Quick start

```bash
# Clone or unzip this directory, then:
cd iso-build

# Build the smallest flavour with -O2 only, MBR layout
sudo OPT_LEVELS=(2) ./build-all.sh debian-base mbr

# Or all four flavours, both layouts, all four opt levels (looong run!)
sudo ./build-all.sh all both
```

ISOs land in `$BUILD_ROOT/iso-out/` (default
`/var/cache/iso-build/iso-out/`).

## Pipeline overview

```
build-all.sh
   ├── scripts/00-prepare-host.sh        # apt-installs build deps, clones grml repos
   ├── scripts/01-extract-tasksel-lists.sh
   │       ↳ writes packages-tasksel/{debian-base,debian-gnome,grml-base,grml-gnome}.list
   ├── scripts/02-build-source-repo.sh <list>
   │       ↳ for each opt-level in OPT_LEVELS, for each pkg in <list>:
   │             apt-get source pkg → dpkg-buildpackage → reprepro includedeb
   │       ↳ produces $BUILD_ROOT/repo/O{0,1,2,3}/
   ├── scripts/03a-build-debian-base.sh  ──╮
   ├── scripts/03b-build-debian-gnome.sh ──┤  these build a chroot via grml-live,
   ├── scripts/03c-build-grml-base.sh    ──┤  pinning the local repo above 1001
   ├── scripts/03d-build-grml-gnome.sh   ──╯
   │
   └── scripts/04-finalize-iso-{mbr,gpt}.sh   # called by 03* depending on ISO_LAYOUT
```

## The optimization-flag array

Defined in `config/common.sh`:

```bash
declare -ag OPT_LEVELS
if [[ -z "${OPT_LEVELS+x}" ]] || [[ "${#OPT_LEVELS[@]}" -eq 0 ]]; then
    OPT_LEVELS=(0 1 2 3)
fi
```

It is a normal bash indexed array, overridable from the environment:

```bash
export OPT_LEVELS=(2)            # one level only
export OPT_LEVELS=(0 2 3)        # skip -O1
export OPT_LEVELS=(s)            # -Os, optimise for size
```

How a level is applied to a build: the helper `opt_level_to_debenv()` (also
in `config/common.sh`) emits the `DEB_*FLAGS_APPEND` variables that
`dpkg-buildpackage` reads. Using `_APPEND` instead of overriding `CFLAGS`
preserves Debian's hardening defaults
(`-fstack-protector-strong`, `-D_FORTIFY_SOURCE=3`, etc.).

```bash
eval "export $(opt_level_to_debenv 2 | xargs)"
# now dpkg-buildpackage will pass -O2 *in addition to* the maintainer's flags;
# gcc honours the last -O on the command line, so ours wins.
```

## File / directory layout

```
iso-build/
├── README.md                        ← you are here
├── build-all.sh                     ← top-level orchestrator
├── config/
│   ├── common.sh                    ← logging, paths, OPT_LEVELS, helpers
│   └── build-helpers.sh             ← shared chroot/grml-live functions
├── scripts/
│   ├── 00-prepare-host.sh
│   ├── 01-extract-tasksel-lists.sh
│   ├── 02-build-source-repo.sh
│   ├── 03a-build-debian-base.sh
│   ├── 03b-build-debian-gnome.sh
│   ├── 03c-build-grml-base.sh
│   ├── 03d-build-grml-gnome.sh
│   ├── 04-finalize-iso-mbr.sh       ← MBR / legacy-BIOS recipe
│   └── 04-finalize-iso-gpt.sh       ← GPT / UEFI recipe
└── packages-tasksel/                ← populated by 01-extract-tasksel-lists.sh
    ├── debian-base.list
    ├── debian-gnome.list
    ├── grml-base.list
    └── grml-gnome.list
```

## Boot-time install flow

The resulting ISO is a **live system** that ships `grml-debootstrap`. Two
boot menu entries are configured in both 04-finalize-iso scripts:

1. *Boot live system* — drops you at a shell / GDM where you can poke
   around.
2. *Install to disk* — passes `debian2hd` on the kernel command line; on
   first boot, grml's autoconfig sees that boot option and runs
   `grml-debootstrap` interactively to install Debian to a real disk. See
   `man grml-debootstrap` for the full set of `debian2hd=...` parameters
   that can be used to make the install fully unattended.

## Useful environment variables

| Variable             | Default                       | Purpose                                       |
| -------------------- | ----------------------------- | --------------------------------------------- |
| `OPT_LEVELS`         | `(0 1 2 3)`                   | Optimization levels to compile with           |
| `ACTIVE_OPT_LEVEL`   | last element of `OPT_LEVELS`  | Which compiled set lands in the ISO           |
| `BUILD_ROOT`         | `/var/cache/iso-build`        | Top-level work area                           |
| `DEBIAN_SUITE`       | `trixie`                      | Debian release (must be `trixie` for D13)     |
| `DEBIAN_MIRROR`      | `http://deb.debian.org/debian`| APT mirror                                    |
| `ARCH`               | `amd64`                       | Target architecture                           |
| `PARALLEL_PKGS`      | `1`                           | Concurrent rebuilds inside an opt-level       |
| `ISO_LAYOUT`         | `mbr`                         | `mbr`, `gpt`, or `both`                       |
| `FORCE`              | `0`                           | Set to `1` to ignore done-markers             |
| `KEEP_TMP`           | `0`                           | Keep the throwaway tasksel-extract chroot     |

## Hardware/disk requirements

- **CPU**: any x86_64; more cores = faster (rebuilds are fully parallel).
- **RAM**: 8 GB minimum; 16 GB+ recommended for GNOME because LLVM and
  WebKit both need ~6 GB peak.
- **Disk**: at least 80 GB free under `$BUILD_ROOT`; for full GNOME at
  4 opt levels, plan 200 GB.

## Troubleshooting

- *"package X has no source available"* — usually a transitional or
  arch:all virtual package. The script logs a warning and skips.
- *isohybrid: command not found* — install `syslinux-utils`.
- *xorriso: appended_part_as_gpt unrecognised* — the GPT recipe wants
  xorriso ≥ 1.5; on Ubuntu 22.04 LTS you may need a backport.
- *grml-live fails inside chroot with "no such suite"* — confirm
  `02-build-source-repo.sh` finished cleanly and produced
  `$BUILD_ROOT/repo/O<lvl>/dists/<suite>-O<lvl>/Release`.

## Licence

The scripts in this directory are released under the same terms as
grml-live and grml-debootstrap themselves: GPL-2+. The Debian source
packages they fetch and rebuild are subject to their respective licences.
