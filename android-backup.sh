#!/usr/bin/env bash

## Author: Tommy Miland (@tmiland) - Copyright (c) 2026

######################################################################
####                      android-backup.sh                       ####
####            Full-fidelity Android backup & restore            ####
####          over ADB: app data, APKs, internal storage          ####
####                    Maintained by @tmiland                    ####
######################################################################

#------------------------------------------------------------------------------#
#
# MIT License
#
# Copyright (c) 2026 Tommy Miland
#
# Permission is hereby granted, free of charge, to any person obtaining a copy
# of this software and associated documentation files (the "Software"), to deal
# in the Software without restriction, including without limitation the rights
# to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
# copies of the Software, and to permit persons to whom the Software is
# furnished to do so, subject to the following conditions:
#
# The above copyright notice and this permission notice shall be included in all
# copies or substantial portions of the Software.
#
# THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
# IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
# FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
# AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
# LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
# OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
# SOFTWARE.
#
#------------------------------------------------------------------------------#
#
# android-backup.sh — full-fidelity Android backup & restore over ADB, without
# the deprecated `adb backup`. Rooted (Magisk/KernelSU) devices are the primary
# target: archives are streamed from on-device `tar` over the ADB channel, and a
# restore puts ownership (per-package uid map) and SELinux contexts back.
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
# data on the device — it asks for confirmation first, and `restore --dry-run`
# validates the backup and prints the plan without writing anything at all.
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
DRY_RUN=0             # restore --dry-run: plan only, never touches the device

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
  -h, --help            Show this help
      --version         Print version and exit

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
      --dry-run         Validate + print the plan, then exit (writes nothing)
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
  ./android-backup.sh restore -i BACKUPDIR --dry-run    # safe: writes nothing
  ./android-backup.sh verify                            # re-check what restore wrote
  ./android-backup.sh verify -i BACKUPDIR               # ...and re-push its uid map first

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
      --dry-run)     DRY_RUN=1; shift ;;
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

detect_root() { # $1 = --read-only: never run `adb root` (used by --dry-run)
  ROOT_KIND=none
  [[ $NO_ROOT == 1 ]] && { info "root: disabled by --no-root"; return 0; }
  local u r
  u=$({ "${ADB[@]}" shell id -u 2>/dev/null || true; } | tr -d '\r')
  if [[ $u == 0 ]]; then ROOT_KIND=adbd; info "root: adbd is running as root"; return 0; fi
  if "${ADB[@]}" shell 'su -c id' 2>/dev/null | tr -d '\r' | grep -q 'uid=0'; then
    ROOT_KIND=su; info "root: su available"; return 0
  fi
  if [[ ${1:-} == --read-only ]]; then
    info "root: not available (dry run — 'adb root' not attempted)"
    return 0
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

root_out() { # binary stdout from a root command (stderr separate, rc propagated)
  # 'adb exec-out' merges the remote stderr into the stream and always returns
  # rc 0, which hides an on-device reader failure; 'adb shell -T' keeps stderr
  # separate and reports the real exit status (both are byte-exact).
  case $ROOT_KIND in
    adbd) "${ADB[@]}" shell -T "$1" ;;
    su)   "${ADB[@]}" shell -T "su -c '$1'" ;;
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

# --------------------------------------------------------------- compression
ext() {
  case $COMPRESSOR in
    zstd) echo ".tar.zst" ;;
    gzip) echo ".tar.gz" ;;
    none) echo ".tar" ;;
  esac
}

comp() {
  case $COMPRESSOR in
    zstd) zstd -q -T0 -3 -c ;;
    gzip) gzip -6 -c ;;
    none) cat ;;
  esac
}

decomp() { # $1 = archive file -> decompressed tar on stdout
  local f=$1
  [[ -f $f ]] || die "no such archive: $f"
  case $f in
    *.tar.zst) zstd -q -d -c < "$f" ;;
    *.tar.gz)  gzip -d -c < "$f" ;;
    *.tar)     cat -- "$f" ;;
    *) die "unknown archive type: $f" ;;
  esac
}

pick_compressor() {
  case $COMPRESSOR in
    auto)
      if command -v zstd >/dev/null 2>&1; then COMPRESSOR=zstd; else COMPRESSOR=gzip; fi ;;
    zstd) command -v zstd >/dev/null 2>&1 || die "zstd is not installed" ;;
  esac
  info "compressor: $COMPRESSOR"
}

# ------------------------------------------------------------------- remote
write_remote_helper() {
cat <<'REMOTE_HELPER_EOF'
#!/system/bin/sh
# adbbk_remote.sh — on-device helper for android-backup.sh. Runs as root.
# usage: sh adbbk_remote.sh <create|extract|verify|stop-apps> [kind] [flags]
set -u

log() { echo "[device] $*" >&2; }
ok()  { echo "ADBBK_OK"; }

TAR_STYLE=tar
if ! command -v tar >/dev/null 2>&1; then
  if command -v toybox >/dev/null 2>&1; then TAR_STYLE=toybox; else TAR_STYLE=busybox; fi
fi
tar_cmd() {
  case "$TAR_STYLE" in
    tar) tar "$@" ;;
    toybox) toybox tar "$@" ;;
    busybox) busybox tar "$@" ;;
  esac
}

RCON=restorecon
command -v restorecon >/dev/null 2>&1 || RCON=/system/bin/restorecon
rcon() { [ -x "$RCON" ] && "$RCON" "$@" ; return 0; }

# Canonical app-data root: on modern Android /data/data is a symlink to
# /data/user/0 (or vice versa) — tar the real directory, never the symlink.
REL="$(readlink -f /data/data 2>/dev/null)"
REL="${REL#/}"
[ -n "$REL" ] || REL="data/data"

EXCL_OK=1
if ! tar_cmd -cf /dev/null --exclude=zzz /data/local/tmp/adbbk_remote.sh >/dev/null 2>&1; then
  EXCL_OK=0
  log "note: this tar has no --exclude support; caches will be included"
fi

chown_map() {
  map=/data/local/tmp/adbbk_uidmap
  [ -s "$map" ] || { log "no uidmap pushed; skipping ownership fixup"; return 0; }
  n=0
  while read -r pkg uid; do
    case "$pkg" in ""|\#*) continue ;; esac
    case "$uid" in ""|*[!0-9]*) continue ;; esac
    for base in data/data data/user/0 data/user_de/0; do
      d="/$base/$pkg"
      [ -d "$d" ] || continue
      cu="$(stat -c %u "$d" 2>/dev/null)"
      if [ "$cu" != "$uid" ]; then
        chown -R "$uid:$uid" "$d" 2>/dev/null && n=$((n+1))
      fi
    done
  done < "$map"
  log "ownership fixup: $n package dirs chowned"
}

ctx_data() {
  for p in /data/data /data/user/0 /data/user_de/0; do
    [ -e "$p" ] && rcon -RF "$p" >/dev/null 2>&1
  done
  return 0
}

fix_apks() {
  [ -d /data/app ] || return 0
  chown -R system:system /data/app 2>/dev/null
  chmod 771 /data/app 2>/dev/null
  find /data/app -type d -exec chmod 755 {} + 2>/dev/null
  find /data/app -type f -exec chmod 644 {} + 2>/dev/null
  rcon -RF /data/app >/dev/null 2>&1
  return 0
}

case "${1:-}" in
create)
  kind="${2:-}"; flags="${3:-}"
  case "$kind" in
    data)
      # Build an explicit include list rather than handing tar the directories:
      # toybox tar aborts the WHOLE archive on a file type it cannot store (a
      # unix socket in app data did exactly that) and does not even name it.
      # Restricting the list to regular files, directories and symlinks both
      # skips those entries and lets tar survive an unreadable/vanished file.
      cd / || exit 1
      set --
      [ -d "$REL" ] && set -- "$REL"
      [ -d /data/user_de/0 ] && set -- "$@" data/user_de/0
      [ $# -gt 0 ] || { log "FATAL: no app-data roots found"; exit 1; }
      list=/data/local/tmp/adbbk_list
      case "${flags:-}" in
        *keepcache*)
          find "$@" \( -type f -o -type d -o -type l \) -print0 > "$list" 2>/dev/null ;;
        *)
          find "$@" \( -name cache -o -name code_cache \) -type d -prune -o \
                 \( -type f -o -type d -o -type l \) -print0 > "$list" 2>/dev/null ;;
      esac
      [ -s "$list" ] || { log "FATAL: app-data include list is empty"; exit 1; }
      tar_cmd --null --no-recursion -T "$list" -cf -
      ;;
    apks)
      ex=""
      if [ "$EXCL_OK" = 1 ]; then
        case "$flags" in
          *withoat*) ;;
          *) ex="--exclude=data/app/*/oat --exclude=data/app/*/*/oat" ;;
        esac
      fi
      cd / || exit 1
      tar_cmd -cf - $ex data/app
      ;;
    sdcard)
      cd /data/media/0 2>/dev/null || { log "FATAL: /data/media/0 not found"; exit 1; }
      tar_cmd -cf - .
      ;;
    system)
      cd / || exit 1
      set --
      for p in data/system/users/0 data/system_de/0 data/system/packages.xml data/system/packages.list; do
        [ -e "/$p" ] && set -- "$@" "$p"
      done
      [ $# -gt 0 ] || { log "FATAL: no system paths found"; exit 1; }
      tar_cmd -cf - "$@"
      ;;
    misc)
      cd / || exit 1
      set --
      for p in data/misc/apexdata/com.android.wifi data/misc/wifi data/misc/bluedroid data/misc/bluetooth; do
        [ -e "/$p" ] && set -- "$@" "$p"
      done
      [ $# -gt 0 ] || { log "FATAL: no wifi/bt configs found"; exit 1; }
      tar_cmd -cf - "$@"
      ;;
    *) log "FATAL: unknown kind '$kind'"; exit 2 ;;
  esac
  rc=$?
  if [ $rc -eq 0 ]; then log "create '$kind' finished"; else log "create '$kind' FAILED (rc=$rc)"; fi
  exit $rc
  ;;
extract)
  kind="${2:-}"
  rc=0
  case "$kind" in
    data)
      tar_cmd -xf - -C /; rc=$?
      chown_map
      ctx_data
      sync
      ;;
    apks)
      tar_cmd -xf - -C /; rc=$?
      fix_apks
      sync
      ;;
    sdcard)
      mkdir -p /data/media/0
      tar_cmd -xf - -C /data/media/0; rc=$?
      rcon -RF /data/media >/dev/null 2>&1
      sync
      ;;
    system)
      tar_cmd -xf - -C /; rc=$?
      chown -R system:system /data/system/users/0 /data/system_de/0 2>/dev/null
      [ -e /data/system/packages.xml ] && chown system:system /data/system/packages.xml 2>/dev/null
      rcon -RF /data/system/users/0 /data/system_de/0 >/dev/null 2>&1
      [ -e /data/system/packages.xml ] && rcon /data/system/packages.xml >/dev/null 2>&1
      sync
      ;;
    misc)
      tar_cmd -xf - -C /; rc=$?
      rcon -RF /data/misc >/dev/null 2>&1
      sync
      ;;
    *) log "FATAL: unknown kind '$kind'"; exit 2 ;;
  esac
  echo "ADBBK_RC=$rc"
  exit 0
  ;;
stop-apps)
  am kill-all >/dev/null 2>&1
  map=/data/local/tmp/adbbk_uidmap
  n=0
  if [ -s "$map" ]; then
    while read -r pkg uid; do
      case "$pkg" in ""|\#*) continue ;; esac
      case "$pkg" in android|com.android.systemui) continue ;; esac
      am force-stop "$pkg" >/dev/null 2>&1
      n=$((n+1))
    done < "$map"
  fi
  log "force-stopped $n packages"
  ok
  ;;
verify)
  i=0
  while [ $i -lt 600 ]; do
    if dumpsys user 2>/dev/null | grep -q RUNNING_UNLOCKED; then break; fi
    if ls /data/data/com.android.providers.settings >/dev/null 2>&1; then break; fi
    i=$((i+2))
    sleep 2
  done
  if [ $i -ge 600 ]; then log "WARN: timed out waiting for unlock; results may be partial"; fi

  live=/data/local/tmp/adbbk_live_uids
  pm list packages -U 2>/dev/null > "$live"
  fixed=0
  checked=0
  while read -r line; do
    case "$line" in package:*) ;; *) continue ;; esac
    rest="${line#package:}"
    uid="${rest##*uid:}"
    uid="${uid%%,*}"
    pkg="${rest% uid:*}"
    [ -n "$pkg" ] || continue
    case "$uid" in ""|*[!0-9]*) continue ;; esac
    for base in data/data data/user/0 data/user_de/0; do
      d="/$base/$pkg"
      [ -d "$d" ] || continue
      checked=$((checked+1))
      cu="$(stat -c %u "$d" 2>/dev/null)"
      if [ "$cu" != "$uid" ]; then
        chown -R "$uid:$uid" "$d" 2>/dev/null && fixed=$((fixed+1))
      fi
    done
  done < "$live"
  ctx_data
  rcon -RF /data/media /data/app >/dev/null 2>&1
  sync
  log "verify: checked $checked package dirs, fixed $fixed"
  echo "FIXED=$fixed CHECKED=$checked"
  ok
  ;;
*)
  log "usage: sh adbbk_remote.sh create|extract|verify|stop-apps [kind] [flags]"
  exit 2
  ;;
esac
REMOTE_HELPER_EOF
}

push_helper() {
  local f="$TMPDIR_/adbbk_remote.sh"
  write_remote_helper > "$f"
  "${ADB[@]}" push "$f" "$REMOTE_PATH" >/dev/null || die "failed to push on-device helper"
}

push_uidmap() {
  local src=""
  [[ -s "$IN_DIR/meta/uidmap.txt" ]] && src="$IN_DIR/meta/uidmap.txt"
  if [[ -z $src ]]; then
    warn "no uidmap in the backup — ownership fixup will be limited"
    return 0
  fi
  "${ADB[@]}" push "$src" "$UIDMAP_PATH" >/dev/null || warn "failed to push uidmap"
}

# ------------------------------------------------------------------ metadata
parse_uidmap() { sed -n 's/^package:\(.*\) uid:\([0-9][0-9]*\).*$/\1 \2/p'; }

save_meta() {
  local d="$OUT_DIR/meta"
  info "collecting device metadata"
  { "${ADB[@]}" shell getprop 2>/dev/null || true; } | tr -d '\r' > "$d/getprop.txt"
  { "${ADB[@]}" shell pm list packages -f -U 2>/dev/null || true; } | tr -d '\r' > "$d/packages.txt"
  { "${ADB[@]}" shell pm list packages -U 2>/dev/null || true; } | tr -d '\r' | parse_uidmap > "$d/uidmap.txt"
  { "${ADB[@]}" shell df -h /data /sdcard 2>/dev/null || true; } | tr -d '\r' > "$d/df.txt"
  {
    echo "tool=android-backup.sh $VERSION"
    echo "created=$(date -Iseconds)"
    echo "device_serial=$SERIAL"
    echo "device_model=$(dev_getprop ro.product.model)"
    echo "device_name=$(dev_getprop ro.product.name)"
    echo "android_release=$(dev_getprop ro.build.version.release)"
    echo "sdk=$(dev_getprop ro.build.version.sdk)"
    echo "fingerprint=$(dev_getprop ro.build.fingerprint)"
    echo "root=$ROOT_KIND"
    echo "compressor=$COMPRESSOR"
  } > "$d/device.txt"
}

write_info() {
  local f="$OUT_DIR/backup-info.txt" x
  {
    echo "# android-backup.sh backup"
    sed -n 's/^/ /p' "$OUT_DIR/meta/device.txt"
    echo "contents:"
    for x in appdata apks sdcard system misc; do
      [[ -f "$OUT_DIR/$x$(ext)" ]] && echo "  $x$(ext)"
    done
    [[ -d $OUT_DIR/apks ]] && echo "  apks/ (directory of pulled APKs)"
    [[ -f $OUT_DIR/legacy.ab ]] && echo "  legacy.ab"
  } > "$f"
  (
    cd "$OUT_DIR" || exit 0
    for x in *.tar.zst *.tar.gz *.tar legacy.ab; do
      [[ -f $x ]] && sha256sum "$x"
    done
  ) > "$OUT_DIR/SHA256SUMS" || true
}

verify_archive() { # $1 = file, $2 = label
  [[ $VERIFY == 1 ]] || { info "  verification skipped (--no-verify)"; return 0; }
  local f=$1 label=$2 n sz rc=0
  # Capture the tarball reader's own status too: a truncated tar lists some
  # entries before failing, so a bare entry count would wrongly pass it.
  n=$(decomp "$f" | tar -tf - 2>/dev/null | wc -l | tr -d ' ') || rc=$?
  if [[ $rc != 0 || -z ${n:-} || $n -lt 1 ]]; then
    rm -f "$f"
    die "archive for $label is empty or corrupt — aborting"
  fi
  sz=$(du -h "$f" | cut -f1)
  info "  $label: $(basename "$f") — $sz, $n entries"
}

verify_sums() {
  [[ $VERIFY == 1 && -f $IN_DIR/SHA256SUMS ]] || return 0
  info "verifying archive checksums"
  ( cd "$IN_DIR" && sha256sum -c --quiet SHA256SUMS >/dev/null ) || die "checksum mismatch — backup files are corrupt"
}

# -------------------------------------------------------------------- backup
bk_root_archive() { # $1 = kind, $2 = remote create cmd, $3 = label
  local kind=$1 rcmd=$2 label=$3
  local f
  f="$OUT_DIR/$1$(ext)"
  info "backing up $label"
  local rc=0
  if [[ $PROGRESS == 1 ]] && command -v pv >/dev/null 2>&1; then
    root_out "$rcmd" | pv -f -b -t | comp > "$f" || rc=$?
  else
    root_out "$rcmd" | comp > "$f" || rc=$?
  fi
  # The archive itself is the source of truth: verify_archive rejects a
  # truncated or empty one. A non-zero rc is advisory — the on-device reader
  # can report individual files it could not read while still finishing.
  verify_archive "$f" "$label"
  [[ $rc == 0 ]] || warn "$label: some entries could not be read (see above); the archive itself verified"
}

bk_sdcard_nonroot() {
  local f
  f="$OUT_DIR/sdcard$(ext)"
  if "${ADB[@]}" shell "command -v tar" >/dev/null 2>&1; then
    info "backing up internal storage (/sdcard)"
    if [[ $PROGRESS == 1 ]] && command -v pv >/dev/null 2>&1; then
      if ! "${ADB[@]}" shell -T "cd /sdcard && tar -cf - ." | pv -f -b -t | comp > "$f"; then
        rm -f "$f"; die "backup of /sdcard failed (see errors above)"
      fi
    else
      if ! "${ADB[@]}" shell -T "cd /sdcard && tar -cf - ." | comp > "$f"; then
        rm -f "$f"; die "backup of /sdcard failed (see errors above)"
      fi
    fi
    verify_archive "$f" "internal storage"
  else
    warn "no tar on the device — falling back to 'adb pull' (slow)"
    mkdir -p "$OUT_DIR/sdcard"
    "${ADB[@]}" pull -a /sdcard/. "$OUT_DIR/sdcard/" || die "adb pull of /sdcard failed"
    info "  pulled $(find "$OUT_DIR/sdcard" -type f 2>/dev/null | wc -l | tr -d ' ') files"
  fi
}

pull_apks() {
  local dest="$OUT_DIR/apks" flags=(-3) p pkg_paths f n=0 fails=0
  [[ $ALL_APKS == 1 ]] && flags=()
  mkdir -p "$dest"
  info "backing up APKs (pm path + adb pull)"
  local pkgs=()
  mapfile -t pkgs < <({ "${ADB[@]}" shell pm list packages "${flags[@]}" 2>/dev/null || true; } | tr -d '\r' | sed -n 's/^package://p' | sort)
  [[ ${#pkgs[@]} -gt 0 ]] || { warn "no packages found"; return 0; }
  for p in "${pkgs[@]}"; do
    pkg_paths=$({ "${ADB[@]}" shell pm path "$p" 2>/dev/null || true; } | tr -d '\r' | sed -n 's/^package://p')
    if [[ -z $pkg_paths ]]; then warn "  $p: no apk path reported"; fails=$((fails+1)); continue; fi
    mkdir -p "$dest/$p"
    local ok=1
    while IFS= read -r f; do
      [[ -n $f ]] || continue
      if ! "${ADB[@]}" pull "$f" "$dest/$p/$(basename "$f")" >/dev/null 2>&1; then
        warn "  $p: failed to pull $(basename "$f")"; ok=0
      fi
    done <<< "$pkg_paths"
    if [[ $ok == 1 ]]; then n=$((n+1)); else fails=$((fails+1)); fi
  done
  info "  pulled APKs for $n packages ($fails failed)"
}

bk_legacy() {
  local sdk
  sdk=$(dev_getprop ro.build.version.sdk)
  if [[ ${sdk:-0} -ge 31 ]]; then
    warn "Android SDK ${sdk}: 'adb backup' was removed/neutered in Android 12+ — this will likely produce an empty file"
    confirm "Run legacy adb backup anyway?" || return 0
  fi
  info "legacy adb backup — set a password (or none) and tap 'Back up my data' on the device screen"
  if ! "${ADB[@]}" backup -apk -shared -all -f "$OUT_DIR/legacy.ab"; then
    warn "legacy adb backup failed"
    return 0
  fi
  if [[ -s $OUT_DIR/legacy.ab ]]; then
    info "  legacy.ab: $(du -h "$OUT_DIR/legacy.ab" | cut -f1)"
  else
    warn "legacy.ab is empty (device refused or app disallows backup)"
  fi
}

cmd_backup() {
  select_device
  detect_root
  local sdk model ts done_any=0
  sdk=$(dev_getprop ro.build.version.sdk)
  model=$(dev_getprop ro.product.model)
  info "device: ${model:-unknown} (Android SDK ${sdk:-?}), root: $ROOT_KIND"

  if [[ $ROOT_KIND == none && $NO_DATA == 0 ]]; then
    warn "no root — app data will NOT be backed up (APKs + internal storage only)"
    warn "  on Android <= 11 you can additionally use --legacy for adb backup"
  fi

  ts=$(date +%Y%m%d-%H%M%S)
  OUT_DIR=${OUT_DIR:-"android-backup-${SERIAL}-${ts}"}
  if [[ -d $OUT_DIR && $FORCE == 0 ]] && [[ -n $(ls -A "$OUT_DIR" 2>/dev/null || true) ]]; then
    die "output directory '$OUT_DIR' is not empty (use --force to overwrite)"
  fi
  mkdir -p "$OUT_DIR/meta"
  info "backup directory: $OUT_DIR"

  pick_compressor
  save_meta

  if [[ $ROOT_KIND != none ]]; then
    warm_root
    push_helper
    if [[ $NO_DATA == 0 ]]; then
      local dflags=""
      [[ $INCLUDE_CACHES == 1 ]] && dflags="keepcache"
      bk_root_archive appdata "sh $REMOTE_PATH create data $dflags" "app data (/data/data, /data/user_de/0)"
      done_any=1
    fi
    if [[ $NO_APKS == 0 ]]; then
      local aflags=""
      [[ $INCLUDE_OAT == 1 ]] && aflags="withoat"
      bk_root_archive apks "sh $REMOTE_PATH create apks $aflags" "installed APKs (/data/app)"
      done_any=1
    fi
    if [[ $NO_SDCARD == 0 ]]; then
      bk_root_archive sdcard "sh $REMOTE_PATH create sdcard" "internal storage (/sdcard)"
      done_any=1
    fi
    if [[ $NO_SYSTEM == 0 ]]; then
      bk_root_archive system "sh $REMOTE_PATH create system" "system data (settings, accounts, packages.xml)"
      done_any=1
    fi
    if [[ $WITH_MISC == 1 ]]; then
      bk_root_archive misc "sh $REMOTE_PATH create misc" "Wi-Fi/Bluetooth configs"
      done_any=1
    fi
  else
    if [[ $NO_APKS == 0 ]]; then pull_apks; done_any=1; fi
    if [[ $NO_SDCARD == 0 ]]; then bk_sdcard_nonroot; done_any=1; fi
  fi
  if [[ $LEGACY == 1 ]]; then bk_legacy; done_any=1; fi

  write_info
  [[ $done_any == 1 ]] || warn "nothing was backed up (all parts disabled?)"
  info "backup complete: $OUT_DIR"
  info "restore with: $PROG restore -i '$OUT_DIR'"
}

# ------------------------------------------------------------------- restore
first_existing() {
  local f
  for f in "$@"; do
    [[ -e $f ]] && { printf '%s\n' "$f"; return 0; }
  done
  return 1
}

collect_archives() {
  SELECTED=()
  local only=$ONLY a
  add() { # $1 kind, $2 path
    local kind=$1 path=$2
    [[ -n $path ]] || return 0
    if [[ -n $only ]] && [[ ",$only," != *",$kind,"* ]]; then return 0; fi
    SELECTED+=( "$kind|$path" )
  }
  a=$(first_existing "$IN_DIR/appdata.tar.zst" "$IN_DIR/appdata.tar.gz" "$IN_DIR/appdata.tar" || true)
  add data "$a"
  a=$(first_existing "$IN_DIR/apks.tar.zst" "$IN_DIR/apks.tar.gz" "$IN_DIR/apks.tar" || true)
  add apks "$a"
  a=$(first_existing "$IN_DIR/system.tar.zst" "$IN_DIR/system.tar.gz" "$IN_DIR/system.tar" || true)
  add system "$a"
  a=$(first_existing "$IN_DIR/misc.tar.zst" "$IN_DIR/misc.tar.gz" "$IN_DIR/misc.tar" || true)
  add misc "$a"
  a=$(first_existing "$IN_DIR/sdcard.tar.zst" "$IN_DIR/sdcard.tar.gz" "$IN_DIR/sdcard.tar" || true)
  add sdcard "$a"
  [[ -d $IN_DIR/sdcard ]] && add sdcarddir "$IN_DIR/sdcard"
  [[ -d $IN_DIR/apks ]] && add apkdir "$IN_DIR/apks"
  return 0
}

check_compat() {
  local f="$IN_DIR/backup-info.txt" sdk model cur has_sys=0 e
  [[ -f $f ]] || { warn "no backup-info.txt in $IN_DIR (unknown provenance — continuing)"; return 0; }
  sdk=$(sed -n 's/^ *sdk=//p' "$f" | head -n1)
  model=$(sed -n 's/^ *device_model=//p' "$f" | head -n1)
  cur=$(dev_getprop ro.build.version.sdk)
  if [[ -n $sdk && -n $cur && $sdk != "$cur" ]]; then
    warn "backup was taken on Android SDK $sdk; this device is SDK $cur"
    for e in "${SELECTED[@]}"; do [[ ${e%%|*} == system ]] && has_sys=1; done
    if [[ $has_sys == 1 && $FORCE == 0 ]]; then
      die "refusing to restore system data across Android versions (use --force if you really mean it)"
    fi
  fi
  if [[ -n $model && $model != "$(dev_getprop ro.product.model)" ]]; then
    warn "backup is from '$model'; this device is '$(dev_getprop ro.product.model)' — cross-device restore"
  fi
}

human_size() { # bytes -> human-readable (awk only, no extra dependencies)
  awk -v b="${1:-0}" 'BEGIN {
    split("B KiB MiB GiB TiB", u, " "); i = 1
    while (b >= 1024 && i < 5) { b /= 1024; i++ }
    printf (i == 1 ? "%.0f %s\n" : "%.1f %s\n"), b, u[i]
  }'
}

restore_target_for() { # $1 = kind -> where a restore would write it
  case $1 in
    data)      printf '/data/data + /data/user_de/0' ;;
    apks)      printf '/data/app' ;;
    apkdir)    printf 'APKs via adb install-multiple' ;;
    sdcard)    printf '/data/media/0 (internal storage)' ;;
    sdcarddir) printf '/sdcard (internal storage, adb push)' ;;
    system)    printf 'settings, accounts, packages.xml' ;;
    misc)      printf 'Wi-Fi / Bluetooth configs' ;;
    *)         printf 'device' ;;
  esac
}

# Read-only preview of a restore. Prints the plan and reports blockers. It
# never writes to the device, never force-stops apps and never runs `adb root`
# (so it cannot leave adbd running as root). Returns 1 if the plan has a
# blocker, 0 otherwise.
dry_run_restore() { # $1 = 1 when the selection needs root on the device
  local need_root=${1:-0} e kind path bytes total=0 n=0 blockers=0 i
  local -a steps=()

  detect_root --read-only

  info "dry run — nothing will be written to the device"
  printf '\n  source : %s\n' "$IN_DIR" >&2
  printf '  device : %s (Android SDK %s), root: %s\n' \
    "$(dev_getprop ro.product.model)" "$(dev_getprop ro.build.version.sdk)" \
    "$ROOT_KIND" >&2
  printf '\n  %-8s %-30s %10s  %s\n' DOMAIN ARCHIVE SIZE TARGET >&2
  printf '  %s\n' \
    "---------------------------------------------------------------------------" >&2
  for e in "${SELECTED[@]}"; do
    kind=${e%%|*}; path=${e#*|}
    if [[ -f $path ]]; then
      bytes=$(stat -c %s -- "$path" 2>/dev/null || stat -f %z -- "$path" 2>/dev/null || printf 0)
      printf '  %-8s %-30s %10s  %s\n' "$kind" "$(basename -- "$path")" \
        "$(human_size "$bytes")" "$(restore_target_for "$kind")" >&2
    elif [[ -d $path ]]; then
      bytes=$(du -sk -- "$path" 2>/dev/null | cut -f1)
      bytes=$(( ${bytes:-0} * 1024 ))
      printf '  %-8s %-30s %10s  %s\n' "$kind" "$(basename -- "$path")/" \
        "$(human_size "$bytes")" "$(restore_target_for "$kind")" >&2
    else
      warn "no such archive for '$kind' ($path) — it would be skipped"
      continue
    fi
    total=$((total + bytes)); n=$((n + 1))
  done
  printf '  %s\n' \
    "---------------------------------------------------------------------------" >&2
  printf '  %s in %s item(s)\n\n' "$(human_size "$total")" "$n" >&2

  if [[ $VERIFY == 1 ]]; then
    steps+=("verify SHA256SUMS against the archives")
  else
    steps+=("skip checksum verification (--no-verify)")
  fi
  if [[ $need_root == 1 ]]; then
    steps+=("push the on-device helper and the package->uid map")
    [[ $NO_FORCE_STOP == 0 ]] && steps+=("force-stop running apps")
  fi
  for e in "${SELECTED[@]}"; do
    kind=${e%%|*}; path=${e#*|}
    steps+=("extract $kind from $(basename -- "$path") into $(restore_target_for "$kind")")
  done
  [[ $need_root == 1 ]] && steps+=("fix ownership (uid map) and SELinux contexts (restorecon)")
  if [[ $NO_REBOOT == 0 ]]; then
    steps+=("reboot and wait for boot to complete")
    [[ $need_root == 1 && $VERIFY == 1 ]] && steps+=("post-boot ownership check + fixup")
  else
    steps+=("skip the reboot (--no-reboot)")
  fi

  info "a real restore would, in order:"
  for (( i = 0; i < ${#steps[@]}; i++ )); do
    printf '    %2d. %s\n' "$((i + 1))" "${steps[$i]}" >&2
  done

  if [[ $need_root == 1 && $ROOT_KIND == none ]]; then
    warn "BLOCKER: this selection needs root (app data / APKs / system data) and no root shell is available"
    blockers=$((blockers + 1))
  fi
  if [[ $LEGACY == 1 && -f $IN_DIR/legacy.ab ]]; then
    warn "note: the legacy adb restore (legacy.ab) would also run and prompt on the device screen"
  fi
  printf '\n' >&2
  if (( blockers )); then
    warn "dry run finished with $blockers blocker(s) — a real restore would fail"
    return 1
  fi
  info "dry run complete — the device was not modified"
  return 0
}

show_plan() {
  local e kind path
  info "restore plan for $SERIAL:"
  for e in "${SELECTED[@]}"; do
    kind=${e%%|*}; path=${e#*|}
    printf '    %-9s %s\n' "$kind" "$(basename "$path")" >&2
  done
}

extract_entry() { # $1 = kind, $2 = path
  local kind=$1 path=$2 out rc_out
  case $kind in
    apkdir)
      install_apks_dir "$path"
      return 0 ;;
    sdcarddir)
      info "restoring internal storage (adb push)"
      "${ADB[@]}" push "$path/." /sdcard/ || die "push of /sdcard failed"
      return 0 ;;
  esac
  info "restoring $kind from $(basename "$path")"
  if [[ $kind == sdcard && $ROOT_KIND == none ]]; then
    if ! out=$(decomp "$path" | shell_in "cd /sdcard && { tar -xf -; echo ADBBK_RC=\$?; }"); then
      die "restore of $kind failed"
    fi
  else
    if ! out=$(decomp "$path" | root_in "sh $REMOTE_PATH extract $kind"); then
      die "restore of $kind failed"
    fi
  fi
  rc_out=$(printf '%s\n' "$out" | sed -n 's/.*ADBBK_RC=\([0-9][0-9]*\).*/\1/p' | tail -n1)
  if [[ -z ${rc_out:-} ]]; then
    warn "$kind: on-device helper did not report a result — check the output above"
  elif [[ $rc_out != 0 ]]; then
    warn "$kind: on-device extraction reported errors (rc=$rc_out) — check the output above"
  fi
}

install_apks_dir() {
  local dir=$1 pkg name out ok=0 fail=0
  local failed=() files=()
  info "installing APKs from $dir"
  for pkg in "$dir"/*/; do
    pkg=${pkg%/}
    name=$(basename "$pkg")
    mapfile -t files < <(find "$pkg" -maxdepth 1 -name '*.apk' | sort)
    [[ ${#files[@]} -gt 0 ]] || continue
    if [[ ${#files[@]} -eq 1 ]]; then
      if out=$("${ADB[@]}" install -r -d -t "${files[0]}" 2>&1); then ok=$((ok+1)); else
        fail=$((fail+1)); failed+=("$name")
        warn "  $name: $(printf '%s' "$out" | tail -n1 | tr -d '\r')"
      fi
    else
      if out=$("${ADB[@]}" install-multiple -r -d -t "${files[@]}" 2>&1); then ok=$((ok+1)); else
        fail=$((fail+1)); failed+=("$name")
        warn "  $name: $(printf '%s' "$out" | tail -n1 | tr -d '\r')"
      fi
    fi
  done
  info "  installed: $ok, failed: $fail"
  return 0
}

do_force_stop() {
  [[ $NO_FORCE_STOP == 1 ]] && return 0
  [[ $ROOT_KIND == none ]] && return 0
  info "stopping apps to avoid file locks during restore"
  root_run "sh $REMOTE_PATH stop-apps" >/dev/null 2>&1 || warn "force-stop step failed (continuing)"
}

wait_boot() {
  local i=0
  while (( i < 300 )); do
    if [[ $(dev_getprop sys.boot_completed) == 1 ]]; then info "device booted"; return 0; fi
    sleep 3; i=$((i+3))
  done
  warn "boot did not complete within 300s — continuing anyway"
}

stage2_verify() {
  local out fixed
  info "post-boot check — unlock the device now if it is locked (waiting up to 10 min)"
  push_helper >/dev/null 2>&1 || true
  if ! out=$(root_run "sh $REMOTE_PATH verify" | tr -d '\r'); then
    warn "post-boot verification failed (see errors above)"
    return 0
  fi
  fixed=$(printf '%s\n' "$out" | sed -n 's/.*FIXED=\([0-9][0-9]*\).*/\1/p' | tail -n1)
  case ${fixed:-} in
    ""|0) info "ownership/contexts verified — nothing to fix" ;;
    *)
      warn "fixed ownership/contexts for $fixed package dirs — rebooting once more for a clean start"
      "${ADB[@]}" reboot >/dev/null 2>&1 || true
      ;;
  esac
}

cmd_restore() {
  [[ -n $IN_DIR ]] || die "restore requires -i DIR (the backup directory)"
  [[ -d $IN_DIR ]] || die "no such directory: $IN_DIR"
  select_device

  collect_archives
  [[ ${#SELECTED[@]} -gt 0 ]] || die "no restorable archives found in $IN_DIR (expected appdata.tar.*, apks.tar.*, sdcard.tar.* and/or apks/)"

  local need_root=0 e kind
  for e in "${SELECTED[@]}"; do
    kind=${e%%|*}
    case $kind in data|system|misc|apks) need_root=1 ;; esac
  done

  check_compat
  verify_sums

  # --dry-run: preview only. detect_root --read-only never runs `adb root`, and
  # nothing below this point is reached, so the device is left untouched.
  if [[ $DRY_RUN == 1 ]]; then
    if dry_run_restore "$need_root"; then exit 0; else exit 1; fi
  fi

  detect_root
  if [[ $need_root == 1 && $ROOT_KIND == none ]]; then
    die "this backup contains app data / APK / system archives, which need root on the device"
  fi

  show_plan
  confirm "Restore the above onto this device? Existing data will be overwritten." || { info "aborted"; exit 0; }

  if [[ $ROOT_KIND != none ]]; then
    warm_root
    push_helper
    push_uidmap
    detect_stdin_channel root
    do_force_stop
  else
    detect_stdin_channel shell
  fi

  for e in "${SELECTED[@]}"; do
    extract_entry "${e%%|*}" "${e#*|}"
  done

  if [[ $LEGACY == 1 && -f $IN_DIR/legacy.ab ]]; then
    warn "legacy adb restore — confirm the restore prompt on the device screen"
    "${ADB[@]}" restore "$IN_DIR/legacy.ab" || warn "legacy adb restore failed"
  fi

  if [[ $NO_REBOOT == 0 ]]; then
    info "rebooting device"
    "${ADB[@]}" reboot || die "reboot failed"
    "${ADB[@]}" wait-for-device
    wait_boot
    if [[ $ROOT_KIND != none && $VERIFY == 1 ]]; then stage2_verify; fi
  else
    info "skipped reboot (--no-reboot)"
    info "reboot the device, then optionally run: $PROG verify -i '$IN_DIR'"
  fi
  info "restore finished"
}

# -------------------------------------------------------------------- verify
cmd_verify() {
  select_device
  detect_root
  [[ $ROOT_KIND != none ]] || die "verify requires root on the device"
  warm_root
  push_helper
  [[ -n $IN_DIR ]] && push_uidmap
  info "waiting for device unlock (unlock it now if it is locked)"
  local out
  if ! out=$(root_run "sh $REMOTE_PATH verify" | tr -d '\r'); then
    die "verify failed"
  fi
  info "device reports: $(printf '%s' "$out" | tr '\n' ' ')"
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
