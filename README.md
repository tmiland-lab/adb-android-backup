<div align="center">

# android-backup.sh

**Full-fidelity Android backup & restore over ADB — without the deprecated `adb backup`.**

App data, installed APKs, internal storage and system settings, back on the device *as it was*.

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)
[![Shell: Bash](https://img.shields.io/badge/shell-bash%204%2B-89e051.svg)](https://www.gnu.org/software/bash/)
[![Platform: Linux/macOS](https://img.shields.io/badge/host-Linux%20%7C%20macOS-informational.svg)](#requirements)
[![ADB](https://img.shields.io/badge/requires-adb%20%E2%89%A5%201.0.41-3DDC84.svg)](https://developer.android.com/tools/adb)
[![Root](https://img.shields.io/badge/full%20fidelity-rooted%20(Magisk%2FKernelSU)-orange.svg)](#rooted-vs-non-rooted)
[![PRs welcome](https://img.shields.io/badge/PRs-welcome-brightgreen.svg)](#contributing)

</div>

---

## Why this exists

Since **Android 12**, `adb backup` is effectively dead: the transport still exists but apps must
explicitly opt in with `android:allowBackup` + `android:debuggable`-era semantics, the `-shared`/`-system`
domains are neutered, and on most modern OEM builds `adb backup` returns an empty or partial archive
without erroring. `adb pull` of `/data/data` fails outright on a stock device (root-owned, SELinux).
And "cloud backup" is not a restore-to-as-was story.

This script takes the path that actually works:

1. ask the device for root (`su`),
2. have **the device itself** `tar` the data,
3. **stream** that tarball over the ADB channel straight into a host-side compressor,
4. on restore, stream it back and then put **ownership** (per-package uid map) and **SELinux contexts**
   (`restorecon`) back, reboot, and **re-verify after boot**.

No intermediate copies on the device, no `/sdcard/android-backup.tmp` that eats 2× the space, no
"restore finished" that silently skipped half the files.

```text
  host                                              device (rooted)
  ────                                              ───────────────
  adb exec-out su -c 'tar -cf - -C /data ...'  ◄────  tar  ──► /data/data, /data/user_de/0
        │                                                    ──► /data/app
        ▼  stream (one pass, no temp files on device)        ──► /data/media/0
   zstd | pv  ──►  appdata.tar.zst                       ──► /data/system, /data/misc
```

---

## Table of contents

- [Features](#features)
- [Requirements](#requirements)
- [Install](#install)
- [Quick start](#quick-start)
- [Usage](#usage)
  - [Commands](#commands)
  - [Backup options](#backup-options)
  - [Restore options](#restore-options)
  - [Examples](#examples)
- [What gets backed up](#what-gets-backed-up)
- [What the backup directory looks like](#what-the-backup-directory-looks-like)
- [How it works](#how-it-works)
  - [Backup pipeline](#backup-pipeline)
  - [Restore pipeline](#restore-pipeline)
- [Rooted vs non-rooted](#rooted-vs-non-rooted)
- [Restore safety: read this first](#restore-safety-read-this-first)
- [Verifying a restore](#verifying-a-restore)
- [Comparison](#comparison)
- [Troubleshooting](#troubleshooting)
- [FAQ](#faq)
- [Status & tested devices](#status--tested-devices)
- [Contributing](#contributing)
- [License](#license)

---

## Features

- **Full app data** — `/data/data` **and** `/data/user_de/0` (device-encrypted storage, where a lot of
  messaging/2FA state lives). Both are restored as a package.
- **Installed APKs** — `/data/app` with its directory layout, so updated/ side-loaded versions survive
  a wipe instead of falling back to the factory build.
- **Internal storage** — `/data/media/0` (what the user sees as `/sdcard`), including the app-specific
  `Android/data` and `Android/obb` trees that modern Android hides from the `shell` user.
- **System data** — `settings` (global/secure/system), contacts/telephony provider DBs, accounts,
  `packages.xml`, plus optional Wi-Fi/Bluetooth configs with `--with-misc`.
- **Byte-exact channel** — uses `adb exec-in` (verified with a SHA-256 probe) and falls back to
  `adb shell -T`; never gates success on `adb exec-out`'s exit code, which is always 0.
- **Integrity checked** — `SHA256SUMS` per archive, post-write archive listing/entry-count check, and
  a re-verification pass after a restore.
- **Ownership restored** — a package → uid map (`pm list packages -U`) is captured at backup time and
  applied at restore time, so apps don't wake up as the wrong uid.
- **SELinux restored** — `restorecon` over every restored tree, then a post-boot ownership/context
  fixup pass (`verify` command).
- **Non-root fallback** — no root? You still get APKs (`pm path` + `adb pull`) and internal storage,
  plus an optional legacy `adb backup` for Android ≤ 11.
- **Streams, never double-writes** — one pass from device to host; the compressor is chosen
  automatically (`zstd` → `gzip` → none) based on what's installed.
- **Safe preview** — `restore --dry-run` validates the archives, prints the plan and the write targets,
  and **touches nothing on the device** (not even `adb root`).
- **Skips the junk** — app caches (`cache/`, `code_cache/`) and compiled `oat` dirs are excluded by
  default; `--include-caches` / `--include-oat` bring them back.
- **Multi-device aware** — always pick your target with `-s SERIAL`; safe with a phone *and* a TV
  stick attached at the same time.
- **Snapshot metadata** — `backup-info.txt` + `meta/` (getprop, package list, uid map, df) so you know
  exactly what a directory is three months later.
- **Restore guards** — refuses to write system data across Android versions unless you pass `--force`;
  warns on cross-device restores.

---

## Requirements

**Host** (Linux/macOS, bash ≥ 4):

| Tool | Needed for | Notes |
|---|---|---|
| `adb` | everything | ≥ 1.0.41 (platform-tools 34+). `exec-in` support requires a recent adb. |
| `bash` 4+ | the script | uses arrays, `${var,,}`, `mapfile`-free parsing |
| `zstd` | preferred compressor | falls back to `gzip`, then to no compression |
| `gzip` | fallback compressor | nearly always present |
| `pv` | progress bars | optional; `--no-progress` also works |
| `sha256sum` | integrity | provided by coreutils |

**Device:**

- Android 7+ in practice; developed and validated against **Android 16 (SDK 36)**.
- **Root** (Magisk / KernelSU / APatch) for full fidelity — i.e. app data + internal storage.
- ADB debugging enabled and the host key authorized.
- Free space at least the size of the backup, wherever you write it.

The device side only uses what is already on the device: `tar` (toybox ≥ 0.8), `restorecon`,
`sha256sum`, `stat`, `find`. No Magisk modules and nothing to flash — the script pushes a small
on-device helper to `/data/local/tmp` when it needs one (`/data/local/tmp` is cleared on reboot).

---

## Install

```bash
git clone https://github.com/tmiland-lab/adb-android-backup.git
cd adb-android-backup
chmod +x android-backup.sh        # already executable in the repo
./android-backup.sh devices
```

Single file, no build step, no dependencies to vendor. Drop it in `~/.local/bin` if you want it on
`$PATH`.

---

## Quick start

```bash
# 1. See what's plugged in (phone + TV stick? pass -s)
./android-backup.sh devices

# 2. Back up everything of the connected device
./android-backup.sh backup -s RK8LOVXGAIDMOFK7 -o ~/phone-backup

# 3. Later: preview the restore (writes NOTHING, never runs `adb root`)
./android-backup.sh restore -i ~/phone-backup/... --dry-run

# 4. Actually restore it
./android-backup.sh restore -i ~/phone-backup/... -y
```

---

## Usage

```text
android-backup.sh <command> [options]
```

### Commands

| Command | What it does |
|---|---|
| `backup` | Backs up the connected device into an output directory. |
| `restore` | Restores a backup directory back onto the device (streamed, ownership + SELinux fixed, reboot, re-verify). |
| `verify` | Post-restore check: re-applies ownership from the uid map and `restorecon`s the restored trees. Safe to re-run. |
| `devices` | Lists connected devices (serial, state, model) and marks the rooted ones. |
| `help` | Full built-in help. |

### Backup options

| Option | Default | Description |
|---|---|---|
| `-s, --serial SERIAL` | only connected device | Target device. **Always pass this** when more than one device is attached. |
| `-o, --out DIR` | `./android-backup-<serial>-<date>` | Output directory. Refuses to write into a non-empty dir unless `--force`. |
| `-y, --yes` | off | Assume "yes" for confirmation prompts. |
| `--no-root` | off | Never try to use root (APK + internal storage only). |
| `--no-data` | off | Skip app data (`/data/data`, `/data/user_de/0`). |
| `--no-apks` | off | Skip installed APKs. |
| `--no-sdcard` | off | Skip internal storage (`/sdcard`). |
| `--no-system` | off | Skip system data (settings, accounts, `packages.xml`). |
| `--with-misc` | off | Also back up Wi-Fi/Bluetooth configs (root). |
| `--all-apks` | off | Non-root: also pull system app APKs (slower, mostly useless — they're reinstallable). |
| `--include-caches` | off | Don't skip app caches. |
| `--include-oat` | off | Don't skip compiled `oat` artifacts (bigger, makes the next boot slightly faster). |
| `--compress MODE` | `auto` | `auto` \| `gzip` \| `zstd` \| `none`. |
| `--legacy` | off | Non-root: additionally run the old `adb backup` (Android ≤ 11 only). |
| `--force` | off | Allow writing into a non-empty output directory. |
| `--no-progress` | off | Disable `pv` progress output. |
| `--no-verify` | off | Skip post-write archive verification (faster, less safe). |

### Restore options

| Option | Default | Description |
|---|---|---|
| `-i, --in DIR` | — | Backup directory to restore from (**required**). |
| `--only LIST` | all present | Comma list of `data,apks,system,misc,sdcard`. |
| `--dry-run` | off | Validate checksums + archives, print the plan and write targets, then exit. **Writes nothing to the device and never runs `adb root`.** |
| `--no-reboot` | off | Don't reboot after restoring (advanced; the device's data won't be consistent until it does). |
| `--no-force-stop` | off | Don't force-stop running apps before restoring their data. |
| `--no-verify` | off | Skip checksum + post-boot verification. |
| `--force` | off | Proceed despite an Android-version mismatch for system data. |
| `--legacy` | off | Also run `adb restore` if a legacy `.ab` is present. |
| `--no-progress` | off | Disable `pv` progress output. |

### Examples

```bash
# Full device, named output
./android-backup.sh backup -s ABC123 -o ~/backups/pixel

# Everything except the (huge) internal storage
./android-backup.sh backup -s ABC123 --no-sdcard

# Just app data, fastest useful snapshot
./android-backup.sh backup -s ABC123 --no-apks --no-sdcard --no-system

# No root on the device: APKs + internal storage only
./android-backup.sh backup -s ABC123 --no-root

# Non-compressed (fastest to write, biggest on disk)
./android-backup.sh backup -s ABC123 --compress none

# Preview a restore (safe, read-only)
./android-backup.sh restore -i ~/backups/pixel --dry-run

# Restore only internal storage
./android-backup.sh restore -i ~/backups/pixel --only sdcard

# Re-apply ownership + SELinux after restoring by hand
./android-backup.sh verify -s ABC123              # uses the uid map already on the device
./android-backup.sh verify -s ABC123 -i ~/backups/pixel   # re-push that backup's uid map first
```

---

## What gets backed up

| Domain | Archive | Paths | Root? |
|---|---|---|---|
| `data` | `appdata.tar.*` | `/data/data`, `/data/user_de/0` | **yes** |
| `apks` | `apks.tar.*` | `/data/app` | yes (non-root: `pm path` + `adb pull`) |
| `sdcard` | `sdcard.tar.*` | `/data/media/0` (`/sdcard`) | yes (non-root: `adb pull` of the shell-visible subset) |
| `system` | `system.tar.*` | `/data/system/users/0` (settings XMLs, accounts, runtime permissions), `/data/system_de/0`, `/data/system/packages.xml`, `/data/system/packages.list` | **yes** |
| `misc` | `misc.tar.*` | `/data/misc/wifi`, `/data/misc/apexdata/com.android.wifi`, `/data/misc/bluedroid`, `/data/misc/bluetooth` (`--with-misc`) | **yes** |

Excluded by default: `cache/` and `code_cache/` inside app data, and `oat/` under `/data/app`.
App data is tarred from an explicit include list of regular files, directories and symlinks — that
skips the odd unix socket in app data (which makes toybox `tar` abort the *entire* archive) and lets a
file that vanishes mid-read cost you one entry instead of the whole domain.

Ownership and SELinux are handled at restore time, not by trusting archive metadata: tar records the
numeric owner, the restore re-applies it from a freshly captured package → uid map (a reinstall or a
different build can hand the same package a different uid), and `restorecon -RF` re-labels contexts.
Archive metadata alone is not enough, which is exactly why a blind `tar -x` "restore" of `/data/data`
leaves you with apps that crash on launch.

---

## What the backup directory looks like

```text
android-backup-RK8LOVXGAIDMOFK7-20261017-113401/
├── appdata.tar.zst     # /data/data + /data/user_de/0
├── apks.tar.zst        # /data/app
├── system.tar.zst      # settings, accounts, packages.xml
├── sdcard.tar.zst      # internal storage (if not skipped)
├── SHA256SUMS          # sha256 of every archive (checked before restoring)
├── backup-info.txt     # tool version, serial, model, SDK, fingerprint, root, compressor
└── meta/
    ├── device.txt      # model/product/build/magisk info
    ├── getprop.txt     # full property dump
    ├── packages.txt    # pm list packages (+ -U)
    ├── uidmap.txt      # package -> uid, used to fix ownership on restore
    └── df.txt          # free space at backup time
```

The directory is self-describing and versioned: `backup-info.txt` is what makes
`restore --dry-run` able to tell you *"this backup is from SDK 35 and your device is SDK 36"* before
it writes a byte.

---

## How it works

### Backup pipeline

```text
1. detect device / root                    su -c id → uid=0
2. capture metadata                        getprop, pm list packages -U, df  → meta/
3. pick channel                            adb exec-in (SHA-256 probe) | adb shell -T
4. stream per domain                       device tar ──stdout──► host: zstd │ pv ► file
5. verify                                  tar -t (entry count) + SHA256SUMS
6. write backup-info.txt                   serial, model, SDK, fingerprint, compressor
```

Nothing is ever staged on the device: the tarball goes straight down the pipe, so a 100 GB
`/data/media` costs the device 0 bytes of scratch space.

### Restore pipeline

```text
1. verify SHA256SUMS                       host-side, before touching the device
2. push helper + uidmap                    to the device's temp dir (/data/local/tmp)
3. force-stop apps                         (skippable with --no-force-stop)
4. stream archives back                    host: file │ decompressor ──stdin──► device tar -x
5. fix ownership                           chown per the package→uid map captured at backup time
6. fix SELinux                             restorecon -RF on every restored tree
7. reboot                                  and wait for boot_completed
8. post-boot re-verify                     ownership drift check + fixup, reports what it fixed
```

`--dry-run` performs steps 1 and 8's *checks* only, prints the plan, and exits — with `adb root`
explicitly not attempted.

---

## Rooted vs non-rooted

| | Rooted (Magisk/KernelSU) | Non-rooted |
|---|---|---|
| App data (`/data/data`, `/data/user_de/0`) | ✅ full | ❌ (Android 12+ makes `adb backup` useless) |
| Installed APKs | ✅ `/data/app` incl. update/split layout | ✅ `pm path` + `adb pull` (per-package) |
| Internal storage | ✅ `/data/media/0` incl. `Android/data`, `Android/obb` | ⚠️ shell-visible subset only (`Android/data` is blocked) |
| System data | ✅ settings, accounts, `packages.xml` | ⚠️ none (or legacy `.ab` on ≤ 11) |
| Ownership/uid preserved | ✅ uid map + `chown` | ✅ app data isn't touched |
| SELinux contexts | ✅ `restorecon` | n/a |
| Legacy `adb backup` | not needed | optional `--legacy` (≤ Android 11) |

Root is detected by running `su -c id` and looking for `uid=0`
(Magisk reports `context=u:r:magisk:s0`). If the prompt needs approval on the device, the script says
so and waits.

---

## Restore safety: read this first

A restore **overwrites live data**. Read this before you run it.

- **`--dry-run` first, always.** It verifies the checksums, lists every archive and its target, and
  writes nothing. It never runs `adb root` or pushes anything to the device — the only thing it asks
  the device is which shell it already has.
- **The device must reboot** for restored app data to be usable (uid/context re-labelling has to
  happen at mount time). `--no-reboot` exists for scripts, not for a healthy device.
- **Restore onto the same device and same Android version.** System data (`settings` DB, `packages.xml`)
  is version-coupled; the script refuses cross-SDK system restores unless you pass `--force`.
- **Device-bound keys cannot be restored.** Android Keystore keys backed by the TEE (used by many
  banking, messaging and 2FA apps) never leave the device's keystore, and a backup does not contain a
  usable copy. Those apps may ask you to re-authenticate or re-enroll after a restore.
- **Not a full ROM backup.** Boot images, vendor partitions, `super`, EFS/modem partitions, `/data/misc/keystore`
  keys and the user's encryption key are out of scope by design. If you need those, take a TWRP/recovery
  image **in addition**.
- **Restoring `/data/app` does not bypass signature checks** — the APK still has to be installable
  (same signing key as installed state, same ABI). Usually fine, occasionally not.
- **Free space**: internal storage restore needs the data to already fit under `/data/media/0`.
- **Battery**: a 10 GB restore is a long, hot operation. Start with ≥ 50 %.

---

## Verifying a restore

`verify` is a first-class command, not an afterthought:

```bash
./android-backup.sh verify -s ABC123                      # uid map already on the device (from restore)
./android-backup.sh verify -s ABC123 -i ~/backups/pixel   # push that backup's meta/uidmap.txt first
```

It takes the uid map from the backup, walks the restored trees, and fixes:
ownership drifts (`chown -R <uid>:<uid>`), missing/incorrect SELinux contexts (`restorecon -RF`), and
reports a summary of what it corrected. The restore flow already runs this automatically after the
reboot; the command exists so you can run it again later, or on a device you restored by other means.

---

## Comparison

| | `adb backup` | `adb pull /data` | **android-backup.sh** | Recovery image (TWRP) |
|---|---|---|---|---|
| Works on Android 12+ | ❌ deprecated/neutered | ❌ permission denied | ✅ | ✅ |
| App data | ⚠️ only `allowBackup=true` apps | ❌ | ✅ all | ✅ |
| Device-encrypted data (`user_de`) | ❌ | ❌ | ✅ | ✅ |
| Installed APKs | ❌ | ⚠️ partial | ✅ | ✅ |
| Internal storage | ⚠️ shared only | ⚠️ shell-visible | ✅ | ✅ |
| Ownership / SELinux preserved | n/a | ❌ | ✅ | ✅ |
| Selective restore (`--only`) | ❌ | n/a | ✅ | ⚠️ |
| Root required | no | no (but useless) | for full fidelity | yes (custom recovery) |
| No on-device temp copy | ✅ | ❌ | ✅ (streamed) | n/a |
| Filesystem is unmounted (crash-consistent) | — | — | ❌ (live) | ✅ |

The honest gap: a recovery-image backup is *crash-consistent* because nothing is running; this script
reads a live filesystem. Backup while the device is idle and it is a non-issue in practice.

---

## Troubleshooting

| Symptom | Cause / fix |
|---|---|
| `more than one device/emulator` | Two devices attached. Pass `-s SERIAL` (see `./android-backup.sh devices`). |
| `adb: exec-in: closed` / channel probe fails | Old `adb` (< 1.0.41) or an odd USB hub. The script falls back to `adb shell -T` automatically. |
| `adbd cannot run as root in production builds` | Expected on stock. The script uses `su` via `exec-out`/`exec-in` instead of `adb root`. |
| `su` hangs | The Magisk/KernelSU approval dialog is on the device screen. Approve it (the script warns and waits). |
| `tar: ...phenotype.db-wal: No such file or directory` | A live SQLite WAL/SHM disappeared mid-read. Harmless — the base DB is captured. |
| `[device] note: tar has no --null support...` | Older toybox `tar` (Android 12 / toybox 0.8.4) lacks `--null`, so the include list is newline-separated instead of NUL-separated. Detected and handled automatically; only exotic filenames containing a newline are affected. |
| `appdata archive is empty or corrupt — aborting` | The stream was cut mid-transfer. Check the cable/port (data-capable, direct, no hub), retry into a fresh `-o` directory. The `SHA256SUMS` manifest catches short writes on the next run. |
| `refusing to write into non-empty output directory` | Use a fresh `-o` path or `--force`. |
| Restored app crashes / wrong permissions | Run `./android-backup.sh verify -s SERIAL -i BACKUPDIR`, then reboot. |
| Restored settings look stale | You restored system data across Android versions; that's what `--force` warned about. |
| `Android/data` missing from a non-root backup | Modern Android blocks the `shell` user from it. Root is required. |
| Backup is huge | Skip `/sdcard` (`--no-sdcard`), drop compiled artifacts (`--include-oat` is *off* by default), and use `--compress zstd`. |
| Restore is slow | Same pipe, but decompression + `restorecon` over tens of thousands of inodes. `--no-progress` shaves a bit; patience does the rest. |

Add `set -x`-style tracing by running with `bash -x ./android-backup.sh ...` — the script is written to
be debuggable (every user-visible step is logged with a `[*]`/`[!]`/`[x]` prefix).

---

## FAQ

**Is this basically `adb backup`?**
No. `adb backup` is the *Android Backup* transport the platform deprecated — it only sees apps that
opt in. This streams the real filesystem through `su`+`tar`, which is why it needs root.

**Why not `adb pull`?**
`adb pull` runs as the `shell` user. On a modern device `/data/data` is owned by each app's uid and
`/sdcard/Android/data` is restricted; `pull` gets `Permission denied` or silently nothing. Root + `tar`
sidesteps it, and streaming avoids writing a second copy on the device.

**Why `exec-in` instead of `shell -T` for the restore?**
`adb shell -T` is binary-safe but mangles some payloads on older adbd builds and its exit status is
sometimes lost; `adb exec-in` is a raw byte channel. The script probes both with a SHA-256 round-trip
and picks the good one.

**Why is `exec-out`'s exit code not used?**
Because `adb exec-out` always reports 0 locally even when the remote command exits non-zero — a known
adb behaviour. Success is gated on archive listing/entry counts and checksums instead.

**Does it back up `/data/media` (internal storage) even though the shell user can't see it?**
Yes, with root: it's read as `/data/media/0`, which is where `/sdcard` really lives.

**Can I restore to a different phone?**
It will run (with a warning). App data will mostly work for well-behaved apps, system data should not
be restored across models, and TEE-bound keys will not. Same-device restore is the supported path.

**Does it handle work profiles / multiple users?**
Per-user data under `/data/user/<n>` is captured for the spaces that exist, and `pm list packages -U`
returns comma-separated uids for work-profile copies; the uid parser takes the primary uid.

**Is my backup encrypted?**
No. It's a plain tarball of your app data. Encrypt the destination yourself (LUKS, `gocryptfs`, or a
`tar | age` pipe) — this script deliberately doesn't invent its own crypto.

**Can it run unattended?**
`-y` skips prompts, `--no-progress` quiets the UI, and the device-side `su` grant must already be
remembered. Do not run restores unattended.

---

## Status & tested devices

| Device | Android | Root | Backup | Restore |
|---|---|---|---|---|
| Xiaomi 14T Pro (`rothko`, 2407FPN8EG) | 16 / SDK 36 | Magisk v30.7 | ✅ verified (2.6 GB app data, 8.4 GB APKs, 12 MB system) | ⚠️ dry-run verified; full restore not yet executed on hardware |

**Honest status note:** the backup path has been run end-to-end against a real device and its archives
verified (`tar -t` entry counts + SHA-256). The restore path is implemented, `--dry-run`-validated, and
syntax/lint-clean, but a *full* real restore has not yet been executed on hardware — that is the next
validation step, and it is destructive by nature, so it needs a device you are willing to wipe. Treat
restores as beta until that test is recorded here.

---

## Contributing

Issues and PRs welcome. Ground rules:

- Keep it a **single bash file** — this is meant to be curl-able onto any machine with `adb`.
- `bash -n android-backup.sh && shellcheck -S warning android-backup.sh` must be clean.
- Never gate correctness on `adb exec-out`'s exit code.
- Anything user-visible goes through `info`/`warn`/`die` so the output stays greppable.

When reporting a device that doesn't work, include the output of
`./android-backup.sh devices` and `meta/device.txt` from a backup (redact serials as needed).

---

## License

[MIT](LICENSE) © 2026 Tommy Miland ([@tmiland](https://github.com/tmiland)).

Provided as-is. A backup/restore tool touches everything you own; test with `--dry-run`, keep more than
one copy, and read [Restore safety](#restore-safety-read-this-first) before you press Enter.
