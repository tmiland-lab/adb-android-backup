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

# -------------------------------------------------------------------- device
select_device() {
  command -v "$ADB_BIN" >/dev/null 2>&1 || die "adb not found in PATH (install Android platform-tools)"
  "$ADB_BIN" start-server >/dev/null 2>&1 || true
  if [[ -n $SERIAL ]]; then
    ADB=( "$ADB_BIN" -s "$SERIAL" )
    "${ADB[@]}" get-state >/dev/null 2>&1 || die "device '$SERIAL' is not connected (see: $PROG devices)"
    return 0
  fi
  local devs=() unauth
  mapfile -t devs < <("$ADB_BIN" devices | awk 'NR>1 && $2=="device" {print $1}')
  if [[ ${#devs[@]} -eq 0 ]]; then
    unauth=$("$ADB_BIN" devices | awk 'NR>1 && $2=="unauthorized" {print $1}' | head -n1)
    [[ -n $unauth ]] && die "device $unauth is unauthorized — accept the USB-debugging prompt on the device"
    die "no device connected (see: $PROG devices)"
  fi
  [[ ${#devs[@]} -eq 1 ]] || die "multiple devices connected: ${devs[*]} — pick one with -s SERIAL"
  SERIAL=${devs[0]}
  ADB=( "$ADB_BIN" -s "$SERIAL" )
  info "device: $SERIAL"
}

dev_getprop() {
  { "${ADB[@]}" shell getprop "$1" 2>/dev/null || true; } | tr -d '\r'
}

detect_root() {
  ROOT_KIND=none
  [[ $NO_ROOT == 1 ]] && { info "root: disabled by --no-root"; return 0; }
  local u r
  u=$({ "${ADB[@]}" shell id -u 2>/dev/null || true; } | tr -d '\r')
  if [[ $u == 0 ]]; then ROOT_KIND=adbd; info "root: adbd is running as root"; return 0; fi
  if "${ADB[@]}" shell 'su -c id' 2>/dev/null | tr -d '\r' | grep -q 'uid=0'; then
    ROOT_KIND=su; info "root: su available"; return 0
  fi
  r=$("${ADB[@]}" root 2>&1 || true)
  if grep -qi 'restarting adbd as root' <<< "$r"; then
    "${ADB[@]}" wait-for-device
    sleep 1
    u=$({ "${ADB[@]}" shell id -u 2>/dev/null || true; } | tr -d '\r')
    if [[ $u == 0 ]]; then ROOT_KIND=adbd; info "root: adbd restarted as root"; return 0; fi
  fi
  info "root: not available"
}

warm_root() {
  info "requesting root — approve the prompt on the device if one appears"
  local u
  u=$(root_run "id -u" 2>/dev/null || true)
  u=$(printf '%s' "$u" | tr -d '\r')
  [[ $u == 0 ]] || die "root shell did not return uid 0 (got '${u:-empty}')"
}

# ------------------------------------------------------------------ adb exec
root_run() { # run a remote command string as root, text stdout
  case $ROOT_KIND in
    adbd) "${ADB[@]}" shell "$1" ;;
    su)   "${ADB[@]}" shell "su -c '$1'" ;;
    none) die "root required for: $1" ;;
  esac
}

root_out() { # run a remote command string as root, binary stdout (adb exec-out)
  case $ROOT_KIND in
    adbd) "${ADB[@]}" exec-out "$1" ;;
    su)   "${ADB[@]}" exec-out "su -c '$1'" ;;
    none) die "root required for: $1" ;;
  esac
}

root_in() { # stream binary stdin to a root command string
  case $ROOT_KIND in
    adbd) "${ADB_STDIN[@]}" "$1" ;;
    su)   "${ADB_STDIN[@]}" "su -c '$1'" ;;
    none) die "root required for: $1" ;;
  esac
}

shell_in() { # stream binary stdin to a shell command string
  "${ADB_STDIN[@]}" "$1"
}

detect_stdin_channel() { # $1 = root|shell : pick exec-in / shell -T, verify with a binary probe
  local mode=$1 cand=() c f probe sha_l sha_r
  f=/data/local/tmp/adbbk_probe
  probe="$TMPDIR_/probe.bin"
  if "${ADB[@]}" exec-in </dev/null true >/dev/null 2>&1; then cand+=(exec-in); fi
  cand+=(shell-T)
  head -c 262144 /dev/urandom > "$probe"
  sha_l=$(sha256sum "$probe" | cut -d' ' -f1)
  for c in "${cand[@]}"; do
    case $c in
      exec-in) ADB_STDIN=( "${ADB[@]}" exec-in ) ;;
      shell-T) ADB_STDIN=( "${ADB[@]}" shell -T ) ;;
    esac
    if [[ $mode == root ]]; then
      if ! root_in "cat > $f" < "$probe" >/dev/null 2>&1; then
        warn "stdin channel '$c' failed the transfer probe"; continue
      fi
      sha_r=$(root_run "sha256sum $f 2>/dev/null || toybox sha256sum $f 2>/dev/null || busybox sha256sum $f 2>/dev/null" | tr -d '\r' | cut -d' ' -f1)
      root_run "rm -f $f" >/dev/null 2>&1 || true
    else
      if ! shell_in "cat > $f" < "$probe" >/dev/null 2>&1; then
        warn "stdin channel '$c' failed the transfer probe"; continue
      fi
      sha_r=$("${ADB[@]}" shell "sha256sum $f 2>/dev/null || toybox sha256sum $f 2>/dev/null || busybox sha256sum $f 2>/dev/null" | tr -d '\r' | cut -d' ' -f1)
      "${ADB[@]}" shell "rm -f $f" >/dev/null 2>&1 || true
    fi
    if [[ -n $sha_r && $sha_r == "$sha_l" ]]; then
      info "stdin channel: $c (256 KiB round-trip verified)"
      return 0
    fi
    warn "stdin channel '$c' corrupted data (local $sha_l, device $sha_r)"
  done
  die "no reliable binary stdin channel to the device (tried: ${cand[*]})"
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
