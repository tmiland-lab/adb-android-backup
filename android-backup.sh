#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
#
# android-backup.sh — full-fidelity Android backup & restore over ADB.
#
# Rooted device:
#   backup : app data (/data/data + /data/user_de/0), installed APKs (/data/app),
#            internal storage (/sdcard -> /data/media/0), and system data
#            (settings/accounts/packages.xml by default; Wi-Fi/BT configs with
#            --with-misc). Caches and compiled oat files are skipped by default.
#   restore: streams the archives back, fixes ownership (per-package uid map),
#            fixes SELinux contexts (restorecon), reboots, then re-verifies
#            ownership after boot and fixes any drift.
#
# Non-rooted device:
#   backup : APKs (pm path + adb pull) and internal storage. App data is not
#            reachable without root; on Android <= 11 an optional legacy
#            `adb backup` pass (--legacy) can capture some app data.
#
# Requires: bash 4+, adb (platform-tools), tar + gzip (or zstd) on the host,
#           root (Magisk/KernelSU) on the device for the full path.
#
# This tool only reads from the device during `backup`. `restore` overwrites
# data on the device — it asks for confirmation first.
set -euo pipefail

VERSION="1.0.0"
PROG="${0##*/}"
REMOTE_PATH="/data/local/tmp/adbbk_remote.sh"
UIDMAP_PATH="/data/local/tmp/adbbk_uidmap"

# ------------------------------------------------------------------ defaults
ADB_BIN="${ADB:-adb}"
SERIAL=""
OUT_DIR=""
IN_DIR=""
ONLY=""
COMPRESSOR="auto"     # auto|gzip|zstd|none
NO_ROOT=0
NO_SDCARD=0
NO_DATA=0
NO_APKS=0
NO_SYSTEM=0
WITH_MISC=0
ALL_APKS=0
INCLUDE_CACHES=0
INCLUDE_OAT=0
LEGACY=0
FORCE=0
ASSUME_YES=0
PROGRESS=1
VERIFY=1
NO_REBOOT=0
NO_FORCE_STOP=0

ROOT_KIND="none"      # none|su|adbd
ADB=()
ADB_STDIN=()
SELECTED=()
TMPDIR_=""

# ------------------------------------------------------------------- helpers
info() { printf '[*] %s\n' "$*" >&2; }
warn() { printf '[!] %s\n' "$*" >&2; }
die()  { printf '[x] %s\n' "$*" >&2; exit 1; }

cleanup() { [[ -n $TMPDIR_ && -d $TMPDIR_ ]] && rm -rf "$TMPDIR_"; return 0; }
trap cleanup EXIT

confirm() {
  [[ $ASSUME_YES == 1 ]] && return 0
  local a
  printf '%s [y/N] ' "$1" >&2
  read -r a || true
  [[ $a == y || $a == Y || $a == yes || $a == YES ]]
}

usage() {
  cat <<'EOF'
Full-fidelity Android backup & restore over ADB.

Usage:
  android-backup.sh <command> [options]

Commands:
  backup            Back up the connected device
  restore           Restore a backup directory onto the connected device
  verify            Post-restore ownership/context check + fixup (root)
  devices           List connected devices
  help              Show this help

Common options:
  -s, --serial SERIAL   Target device (default: the only connected one)
  -y, --yes             Assume "yes" for confirmation prompts
      --no-root         Never try to use root (APK/storage-only mode)

backup options:
  -o, --out DIR         Output directory (default: ./android-backup-<serial>-<date>)
      --no-data         Skip app data
      --no-apks         Skip APK backup
      --no-sdcard       Skip internal storage (/sdcard)
      --no-system       Skip system data (settings/accounts/packages.xml)
      --with-misc       Also back up Wi-Fi/Bluetooth configs (root)
      --all-apks        Non-root: pull system app APKs too
      --include-caches  Do not skip app cache dirs
      --include-oat     Do not skip compiled oat files (bigger, faster restore)
      --compress MODE   auto|gzip|zstd|none   (default: auto)
      --legacy          Non-root: also run legacy `adb backup` (Android <= 11)
      --force           Allow writing into a non-empty output directory
      --no-progress     Disable pv progress output
      --no-verify       Skip post-write archive verification

restore options:
  -i, --in DIR          Backup directory to restore from (required)
      --only LIST       Comma list of: data,apks,system,misc,sdcard
      --no-reboot       Do not reboot after restoring
      --no-force-stop   Do not force-stop apps before restoring data
      --no-verify       Skip checksum + post-boot verification
      --force           Proceed despite Android-version mismatch (system data)
      --legacy          Also run `adb restore` on legacy.ab if present
      --no-progress     Disable pv progress output

Examples:
  ./android-backup.sh backup
  ./android-backup.sh backup --no-sdcard -o ~/phone-backup
  ./android-backup.sh restore -i android-backup-RK8LOVXGAIDMOFK7-20261016-120000
  ./android-backup.sh restore -i BACKUPDIR --only sdcard
  ./android-backup.sh verify -i BACKUPDIR

Full app-data fidelity requires root on the device (Magisk/KernelSU).
Without root the backup contains APKs + internal storage only.
EOF
}

# ----------------------------------------------------------------- arg parse
parse_args() {
  [[ $# -ge 1 ]] || { usage; exit 2; }
  COMMAND=$1; shift
  while [[ $# -gt 0 ]]; do
    case $1 in
      -s|--serial)   SERIAL=${2:?missing value for $1}; shift 2 ;;
      -o|--out)      OUT_DIR=${2:?missing value for $1}; shift 2 ;;
      -i|--in)       IN_DIR=${2:?missing value for $1}; shift 2 ;;
      --only)        ONLY=${2:?missing value for $1}; shift 2 ;;
      --compress)    COMPRESSOR=${2:?missing value for $1}; shift 2 ;;
      --no-root)     NO_ROOT=1; shift ;;
      --no-data)     NO_DATA=1; shift ;;
      --no-apks)     NO_APKS=1; shift ;;
      --no-sdcard)   NO_SDCARD=1; shift ;;
      --no-system)   NO_SYSTEM=1; shift ;;
      --with-misc)   WITH_MISC=1; shift ;;
      --all-apks)    ALL_APKS=1; shift ;;
      --include-caches) INCLUDE_CACHES=1; shift ;;
      --include-oat) INCLUDE_OAT=1; shift ;;
      --legacy)      LEGACY=1; shift ;;
      --force)       FORCE=1; shift ;;
      -y|--yes)      ASSUME_YES=1; shift ;;
      --no-progress) PROGRESS=0; shift ;;
      --no-verify)   VERIFY=0; shift ;;
      --no-reboot)   NO_REBOOT=1; shift ;;
      --no-force-stop) NO_FORCE_STOP=1; shift ;;
      -h|--help)     usage; exit 0 ;;
      --version)     printf '%s %s\n' "$PROG" "$VERSION"; exit 0 ;;
      *)             die "unknown option: $1 (see --help)" ;;
    esac
  done
  case $COMPRESSOR in auto|gzip|zstd|none) ;; *) die "bad --compress value: $COMPRESSOR" ;; esac
  ONLY=$(printf '%s' "$ONLY" | tr -d ' ')
  ONLY=${ONLY//storage/sdcard}
  if [[ -n $ONLY && ! $ONLY =~ ^(data|apks|system|misc|sdcard)(,(data|apks|system|misc|sdcard))*$ ]]; then
    die "--only accepts a comma list of: data,apks,system,misc,sdcard"
  fi
}

# ---------------------------------------------------------------------- main
main() {
  parse_args "$@"
  TMPDIR_=$(mktemp -d)
  case $COMMAND in
    backup)  cmd_backup ;;
    restore) cmd_restore ;;
    verify)  cmd_verify ;;
    devices) exec "$ADB_BIN" devices -l ;;
    help|-h|--help) usage ;;
    *) usage; exit 2 ;;
  esac
}

main "$@"
