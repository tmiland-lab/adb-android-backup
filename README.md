# android-backup.sh

Full-fidelity Android backup & restore over ADB.

The goal is *fidelity*: a backup should capture enough that a restore puts the
device back the way it was — app data, the installed APKs, internal storage,
and system data (settings, accounts, package state). Restores fix file
ownership and SELinux contexts so the restored data is usable, not just present.

```
backup  : app data (/data/data + /data/user_de/0)
          installed APKs (/data/app)
          internal storage (/sdcard -> /data/media/0)
          system data (settings, accounts, packages.xml; Wi-Fi/BT with --with-misc)
restore : stream archives back, fix ownership per-package uid map,
          restorecon SELinux contexts, reboot, re-verify after boot
```

App caches and compiled `oat` files are skipped by default (toggle with
`--include-caches` / `--include-oat`) so backups stay a sane size.

## Why not `adb backup`?

`adb backup` is effectively dead for full-fidelity work: it was neutered/removed
from Android 12+, it never captured `/sdcard` app data, and it only backs up apps
that opt in via `android:allowBackup`. It is kept here only as an optional extra
for Android ≤ 11 (`--legacy`).

This tool instead uses **root on the device** to stream `tar` over ADB. Root is
required on the device (Magisk/KernelSU) for the full path. Without it the tool
degrades to APKs + internal storage only and says so.

### How the transfer works

- Backup streams the on-device `tar` output to the host:
  `adb exec-in su -c "… tar -cf - …"`.
- `adb exec-in` was verified byte-exact (256 KiB round-trip sha256 match) and is
  preferred over `adb shell -T`; both propagate the remote exit code.
- `adb exec-out` is *not* used to gate success — it never propagates the remote
  exit code (it returns 0 even for `exit 7`). Success is gated on non-empty,
  listable archives and checksums instead.

## Requirements

Host:

- `bash` 4+
- `adb` (Android platform-tools)
- `tar`, and `gzip` **or** `zstd` (zstd preferred when present)
- `sha256sum` (coreutils)
- `pv` (optional, for progress)

Device:

- root (Magisk/KernelSU) for app data, system data, and `/sdcard` under root
- `tar` on the device (the toolbox/toybox `tar` is used; the tool checks for
  `--exclude` support and degrades gracefully if missing)

## Usage

```sh
./android-backup.sh backup
./android-backup.sh backup -o ~/phone-backup
./android-backup.sh backup --no-sdcard            # smaller, faster
./android-backup.sh restore -i android-backup-<serial>-<date>
./android-backup.sh restore -i BACKUPDIR --only sdcard
./android-backup.sh verify  -i BACKUPDIR          # re-check ownership/contexts
./android-backup.sh devices
./android-backup.sh help
```

More than one device can be attached — pass `-s SERIAL` (otherwise `adb`
errors with "more than one device/emulator").

### Common options

| Option | Meaning |
| --- | --- |
| `-s, --serial SERIAL` | Target device (default: the only connected one) |
| `-y, --yes` | Assume "yes" for confirmation prompts |
| `--no-root` | Never use root (APK + internal-storage mode) |

### Backup options

| Option | Meaning |
| --- | --- |
| `-o, --out DIR` | Output directory (default `./android-backup-<serial>-<date>`) |
| `--no-data` | Skip app data |
| `--no-apks` | Skip APK backup |
| `--no-sdcard` | Skip internal storage |
| `--no-system` | Skip system data (settings/accounts/packages.xml) |
| `--with-misc` | Also back up Wi-Fi/Bluetooth configs (root) |
| `--all-apks` | Non-root: pull system app APKs too |
| `--include-caches` | Do not skip app cache dirs |
| `--include-oat` | Do not skip compiled oat files (bigger, faster restore) |
| `--compress MODE` | `auto` \| `gzip` \| `zstd` \| `none` (default `auto`) |
| `--legacy` | Non-root: also run legacy `adb backup` (Android ≤ 11) |
| `--force` | Allow writing into a non-empty output directory |
| `--no-progress` | Disable `pv` progress output |
| `--no-verify` | Skip post-write archive verification |

### Restore options

| Option | Meaning |
| --- | --- |
| `-i, --in DIR` | Backup directory to restore from (required) |
| `--only LIST` | Comma list of `data,apks,system,misc,sdcard` |
| `--no-reboot` | Do not reboot after restoring |
| `--no-force-stop` | Do not force-stop apps before restoring data |
| `--no-verify` | Skip checksum + post-boot verification |
| `--force` | Proceed despite Android-version mismatch (system data) |
| `--legacy` | Also run `adb restore` on `legacy.ab` if present |
| `--no-progress` | Disable `pv` progress output |

## Backup layout

```
android-backup-<serial>-<date>/
├── backup-info.txt          # human-readable summary
├── SHA256SUMS               # checksums of the archives
├── appdata.tar.zst          # /data/data + /data/user_de/0   (root)
├── apks.tar.zst             # /data/app                       (root)
├── sdcard.tar.zst           # /data/media/0 == /sdcard        (root)
├── system.tar.zst           # settings/accounts/packages.xml  (root)
├── misc.tar.zst             # Wi-Fi/BT configs                (--with-misc)
├── legacy.ab                # legacy adb backup, Android <= 11 (--legacy)
├── apks/                    # non-root: directory of pulled APKs
└── meta/
    ├── device.txt           # serial, model, fingerprint, SDK, root, compressor
    ├── getprop.txt          # full device property dump
    ├── packages.txt         # pm list packages -f -U
    ├── uidmap.txt           # package -> uid map (drives restore ownership)
    └── df.txt               # /data and /sdcard sizes
```

Archives are `*.tar.zst`, `*.tar.gz`, or `*.tar` depending on the compressor.
`backup` only reads from the device.

## Restore caveats

- **`restore` overwrites data on the device.** It asks for confirmation first
  (skip with `-y`). Do not restore a backup from a different device or a
  substantially different ROM/Android version onto a device you care about.
- Ownership is fixed from `meta/uidmap.txt` (the package→uid map captured at
  backup time). Apps installed *after* the backup, or with changed uids, are
  handled by re-reading the live `pm list packages -U` on the device.
- Apps with a work-profile copy report comma-separated uids
  (`uid:6102,1106102`); the primary uid is used.
- SELinux contexts are restored with `restorecon`. On a `user` build the
  device may still apply per-boot context fixes.
- A reboot follows the restore so apps pick up their data; the tool then
  re-verifies ownership post-boot and fixes any drift (`verify`).
- If the backup's Android SDK differs from the device, restoring *system* data
  requires `--force` (settings/accounts schemas can differ across versions).

## Exit

`0` on success, non-zero on failure. `backup` only reads; `restore` and
`verify` modify the device.

## License

MIT (see `SPDX-License-Identifier` in the script header).
