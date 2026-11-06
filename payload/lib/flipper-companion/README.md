# Secure Linux Flipper Companion

A standard-library Python companion for a Flipper Zero running RogueMaster. It works locally and never publishes anything. On an installed Secure Linux machine, open **Flipper Zero Backup & Files** or run `secure-linux-flipper menu`; `secure-linux-flipper --help` lists the commands.

## Start safely

```sh
secure-linux-flipper status
secure-linux-flipper backup --sd /run/media/you/FLIPPER --dest "$HOME/FlipperBackups"
secure-linux-flipper verify "$HOME/FlipperBackups/flipper-YYYY..."
```

USB detection uses Flipper's known normal/DFU USB IDs and sysfs identification. SD detection lists mounted removable filesystems only: it cannot prove which mount belongs to the Flipper. Every operation requires an explicit `--sd` path.

Backups contain `manifest.json`, its SHA-256 sidecar, and a `files/` payload. Every regular file has a size and SHA-256. Full backups cover every regular file and empty directory; `--select` limits the scope. Symlinks and special files are refused rather than silently omitted. Restore verifies the entire backup before writing, never deletes unrelated RogueMaster files, and requires a complete safety backup plus confirmation before replacing differing files.

## RogueMaster stable updater

Start with the beginner menu's **Stable RogueMaster update (SD staging)** entry. It asks for an explicit SD mount, a computer backup destination, and a computer work destination. The equivalent commands are:

```sh
secure-linux-flipper rm-check --channel stable --json
secure-linux-flipper inventory --sd /run/media/you/FLIPPER --json
secure-linux-flipper rm-update --sd /run/media/you/FLIPPER \
  --backup-dir "$HOME/FlipperBackups" --work-dir "$HOME/FlipperReleases"
```

`rm-update` accepts only the latest public, non-draft, non-prerelease release from the official `RogueMaster/flipperzero-firmware-wPlugins` GitHub repository. It selects the complete TGZ rather than treating a source archive or Core 1 DFU file as a full update. Download and redirect hosts are restricted to approved GitHub/API asset hosts over authenticated HTTPS. The asset's expected size and SHA-256 must match the official GitHub API metadata before extraction. GitHub describes these asset digests as generated at upload and immutable. **This is asset authentication through GitHub metadata, not a publisher signature; no publisher signature asset was found in the researched release.**

The companion safely extracts the archive without `extractall`, rejecting traversal, absolute paths other than the resource archive's single `/` root, links, special files, duplicate/case-colliding paths, and excessive expansion. It requires `update.fuf` version 2, target 7, all referenced files, and matching loader/radio CRC32 fields. Resource `Manifest` sizes and MD5 values are checked as an additional upstream-format consistency check. MD5 is not the download authentication mechanism; the outer SHA-256 is. Option-bytes fields and every original bundle file are preserved verbatim in staging.

Official references used for this workflow:

- RogueMaster release API: `https://api.github.com/repos/RogueMaster/flipperzero-firmware-wPlugins/releases/latest`
- RogueMaster installation guide: `https://github.com/RogueMaster/flipperzero-firmware-wPlugins/blob/420/documentation/HowToInstall.md`
- GitHub release asset digest documentation: `https://github.blog/changelog/2025-06-03-releases-now-expose-digests-for-release-assets/`
- qFlipper CLI documentation: `https://github.com/flipperdevices/qFlipper/blob/dev/cli/README.md`
- Flipper recovery documentation: `https://docs.flipper.net/zero/basics/firmware-update/firmware-recovery`

### Firmware packages and SD resources are separate

The default `--method stage` does two visibly separate host-side jobs after review:

1. Merge the release's extracted SD resources into the selected card.
2. Stage the complete genuine update bundle at `update/RELEASE_TAG/` so the user can run its `update.fuf` on the Flipper.

Staging is not flashing. The companion never claims that internal firmware or radio was updated. Keep the Flipper powered and follow its on-device update prompts until the device reports completion. The on-device updater may process the resource manifest itself; its firmware/radio/resource behavior is outside the host's transactional control.

`--method qflipper` instead launches an already installed official qFlipper GUI after backup, review, and exact confirmation. Choose **Install from file**, select the verified `package.tgz` in the printed release directory, and wait for qFlipper and the Flipper to report completion. A process launch or exit status is never treated as flash success. qFlipper's CLI `firmware` command accepts Core 1 `.dfu` firmware only; using that file or `dfu-util -D` alone would omit the package's radio/updater/resources and is deliberately not offered as a full update.

### Backup, inventory, and conflict policies

Before the first SD write, the companion creates and verifies a **full** SD backup, saves its path in an atomic release journal, and creates `inventory.json`. Inventory records paths, sizes, SHA-256 values, and categories for FAP/FAL applications, BadUSB, scripts, app data/assets/manifests, sub-GHz, infrared, NFC, LF RFID, iButton, favourites, profiles/settings, dolphin/asset packs, and other files. Categories are organizational only: stock and custom files can share paths, so custom origin cannot be known. When a release is available, comparisons say `same_as_release`, `differs_from_release`, or `not_in_release`; they do not prove origin.

For full updates, `--resource-conflict` is:

- `abort` (default): refuse any differing existing resource or update-package payload before an SD write.
- `replace`: permit verified replacement after the original full backup. Files not touched by the package are not deleted.

`keep` is intentionally unavailable for full updates because the device-side updater may overwrite differing resources. For an SD-assets-only merge, use the cached release with no network access:

```sh
secure-linux-flipper rm-assets --release-dir "$HOME/FlipperReleases/RM_TAG" \
  --sd /run/media/you/FLIPPER --conflict abort
```

`rm-assets` supports `abort` (default), `keep` differing existing files, or `replace` them after backup. It copies only extracted resources—never `firmware.dfu`, `updater.bin`, `radio.bin`, or `update.fuf`—and never deletes unrelated files. It does not download third-party asset libraries.

RogueMaster's README currently suggests deleting `/ext/apps` before an update. **This companion deliberately does not implement or recommend that deletion**, because preserving user files is a safety requirement. Backups do not prove FAP compatibility: stock and custom FAPs may need rebuilding when firmware/API versions change. The existing `build-fap` ufbt/fbt workflows remain the supported way to build reviewed custom apps.

### Interrupted updates and rollback

Every copied resource and package payload is journaled. SD package files are first written to the companion-owned `update/.secure-linux-roguemaster-staging/`, verified, then atomically renamed when the final bundle directory is absent. If a final bundle already exists, files are compared and only approved replacements are made; extra files are not deleted. After an interruption, resume entirely from the verified cache and the **original pre-update backup**:

```sh
secure-linux-flipper rm-resume --release-dir "$HOME/FlipperReleases/RM_TAG" \
  --sd /run/media/you/FLIPPER --offline --resource-conflict replace
```

Resume always performs zero network calls, whether or not `--offline` is written. It revalidates the cached archive and extracted files, reconciles already-copied payloads, refuses unexpected post-backup changes, and never makes a new backup of a half-updated card. Use the same conflict policy approved for the interrupted operation.

```sh
secure-linux-flipper rm-rollback --release-dir "$HOME/FlipperReleases/RM_TAG" \
  --sd /run/media/you/FLIPPER --safety-backup "$HOME/FlipperSafety"
```

Rollback verifies the original backup, makes a fresh complete safety backup if current files differ, requires confirmation, and restores only manifest files. Unrelated additions, including files created after the original backup, may remain. **SD rollback is not internal firmware/radio rollback.** Reverting firmware requires a prior official verified package through the same update path. Flipper's documented qFlipper/DFU recovery route may erase dolphin level/settings/pairing data while preserving microSD contents; recovery is not represented as a normal companion update.

The mutable `420` source branch can be inspected with `rm-check --channel moving-head`, but automatic update refuses it. A branch head is not an immutable release package; advanced users must review and build source separately. `dfu-check --yes` runs only read-only `dfu-util -l` after confirmation, with no subprocess timeout. It never flashes or erases. `status` reports qFlipper, qFlipper CLI, and dfu-util detection separately.

## Device version check, explicit qFlipper update, and verified completion

Install the optional official `flipperzero_protobuf_py` package through a trusted Python package source if device-reported fields are required. Connect the Flipper over USB, explicitly select its mounted SD, then run:

```sh
secure-linux-flipper rm-check-device --sd /run/media/you/FLIPPER
```

`rm-check-device` uses official protobuf `rpc_device_info()`/DEV-INFO for firmware version, build date, commit, API major/minor, origin fork/git, hardware target, and hardware UID. The raw UID is private to the operation. The latest stable tag and release date come from RogueMaster's official release API. `/ext/Manifest` `T:<unix>` is shown only as the **SD resource date**. DEV-INFO does not provide a true last-update timestamp, so that field remains unavailable. Different version/tag schemes are not arbitrarily ordered: an exact installed-version/latest-tag match sets `update_available` to false; every other case leaves it unavailable for review rather than claiming that an update is newer or older.

The menu entries **Check for RogueMaster Update** and **Download and Install Latest RogueMaster Update for Flipper Device** expose the explicit workflow. The command equivalent is:

```sh
secure-linux-flipper rm-install-latest --sd /run/media/you/FLIPPER \
  --work-dir "$HOME/FlipperReleases" --backup-dir "$HOME/FlipperBackups"
```

This downloads and verifies the immutable complete RogueMaster TGZ, creates and verifies the full SD backup, and launches official qFlipper. It returns `awaiting-user-qflipper`, never `100%` or flash success. In qFlipper, the user must choose **Install from file** and select the printed verified `package.tgz`. This GUI action is unavoidable with the researched official local-package interface. The companion never runs no-argument `qFlipper-cli` for RogueMaster because that route can select official stock firmware. It also does not substitute `qFlipper-cli firmware file.dfu`, `dfu-util -D`, or `core2fus`: Core1-only DFU is not a complete firmware/radio/resource update.

After qFlipper and the Flipper finish, reconnect the updated device and SD, then run:

```sh
secure-linux-flipper rm-verify --release-dir "$HOME/FlipperReleases/RM_TAG" \
  --sd /run/media/you/FLIPPER
```

Verification independently requires device firmware evidence matching the selected RogueMaster release and target 7, plus the expected size and SHA-256 of **every** journaled SD resource. Only then does overall progress become `100`, the active operation close, and successful timing history append. A failed check returns nonzero, records no success, and can be rerun after correcting the firmware/SD state. Download byte progress is measured; external qFlipper copy/flash progress remains indeterminate.

Timing profiles are stored locally under the computer-only timing root. Each computer receives a random UUID. Device IDs are HMAC-SHA256 pseudonyms derived from the raw UID with a local random 32-byte salt; raw UID, hostname, and SD paths are not stored in update history. Histories are independent for each computer/device pair and retain at most the last three fully verified updates. ETA low/high/median remaining times are shown only for phases with matching successful history. External qFlipper phases have no invented duration.

## Genuine stock animation restoration and custom builds

Official stock resources come only from `https://update.flipperzero.one/firmware/directory.json`, selecting target `f7` `resources_tgz` and `full_json` assets with directory-provided SHA-256 verification and safe extraction. To download the device-reported official version:

```sh
secure-linux-flipper stock-prepare --work-dir "$HOME/FlipperStock" --require-compatible
secure-linux-flipper stock-preview --stock-dir "$HOME/FlipperStock/OFFICIAL_VERSION" \
  --animations ANIMATION_NAME
```

Automatic stock restoration is intentionally strict. It re-reads DEV-INFO and requires exact Official Flipper Devices origin, version, hardware target 7, available API major/minor, and build-date equality with the official package. RogueMaster/stock API equivalence is not guessed; a RogueMaster-origin device is refused. A stock-looking third-party pack is not evidence of genuine stock resources.

```sh
secure-linux-flipper stock-restore --stock-dir "$HOME/FlipperStock/OFFICIAL_VERSION" \
  --sd /run/media/you/FLIPPER --animations ANIMATION_NAME \
  --backup-dir "$HOME/FlipperBackups"
secure-linux-flipper stock-rollback --journal "$HOME/FlipperStock/OFFICIAL_VERSION/restorations/JOURNAL.json" \
  --sd /run/media/you/FLIPPER --safety-backup "$HOME/FlipperSafety"
```

Restore previews selected metadata and any matching genuine PNG sources, verifies a full backup, copies only selected animations, and merges the external manifest while preserving custom and unselected entries. `.bm` frames otherwise receive metadata-only preview; no unverified decoder is used. Rollback verifies/restores the backup and removes only unchanged companion-added files; changed additions are retained. **Internal, blocking, and splash screens are firmware-compiled and are not restored by copying SD animations.**

Custom animations are built from reviewed PNG sources in `assets/dolphin/external/` with the source tree's real `./fbt dolphin_ext` command:

```sh
secure-linux-flipper animation-build --fbt-root /path/to/RogueMaster \
  --output "$HOME/CustomDolphin"
```

The command requires compatible official dolphin tooling and exactly one new/changed compiled output tree. Stale output, a failed build, missing PNG sources, or ambiguous output is refused; handmade `.bm` conversion is never substituted. Build success does not prove exact installed-firmware/source compatibility and does not write to SD or flash firmware.

## Favourites, key apps, and accessibility

```sh
secure-linux-flipper favourites --sd /run/media/you/FLIPPER \
  --entries /any/nfc/card.nfc /any/badusb/demo.txt --backup-dir "$HOME/FlipperBackups"
secure-linux-flipper apps-organize --sd /run/media/you/FLIPPER \
  --assignment KeyApps apps/USB/tool.fap --backup-dir "$HOME/FlipperBackups"
secure-linux-flipper accessibility
```

Favourites use firmware-supported `/ext/favorites.txt` with existing `/any/...` data/script targets after preview and full backup. Arbitrary FAP favourites are not assumed. Key-app organisation copies reviewed FAPs into curated `/ext/apps/<category>/` folders without deleting originals. RogueMaster keybinds live in internal `/int/.desktop_keybinds.txt`; configure them through RogueMaster **CFW Settings**, not by pretending an SD file wrote them.

Accessibility guidance covers qFlipper scaling, screen streaming/remote control, keyboard navigation, lefty mode, antialiasing, and DPI support where the installed qFlipper/platform provides them. The companion does not patch firmware apps, fonts, display settings, or accessibility services.

## Private backups

```sh
secure-linux-flipper backup --private --tool age --sd /run/media/you/FLIPPER \
  --dest "$HOME/FlipperBackups"
secure-linux-flipper restore --encrypted "$HOME/FlipperBackups/flipper-....tar.age" \
  --sd /run/media/you/FLIPPER --safety-backup "$HOME/FlipperSafety"
```

Install `age` or GnuPG through trusted distribution packages. Encryption prompts twice without displaying the passphrase. The passphrase is sent only to the tool's standard input; it is not accepted as a command option, placed in an environment variable, saved, or logged. Tool output is not relayed on failure because wrappers may echo secrets.

Plaintext exists only in a unique mode-0700 staging folder. Keep the default staging on the computer. Staging files are overwritten and removed where practical, but **Flash storage, SSDs, SD cards, and copy-on-write filesystems cannot be securely erased this way**. Use an encrypted computer disk and securely dispose of the whole device when required. Encrypted `.age`/`.gpg`/`.pgp` files are computer storage, never FAPs; the install workflow rejects them. Restore decrypts into protected staging first and only then copies verified plaintext files to the Flipper.

## Prepare or update Boot2Flipper

```sh
secure-linux-flipper prepare --destination both \
  --sd /run/media/you/FLIPPER --computer-dir "$HOME/FlipperPayload" \
  --fap "$HOME/Builds/boot2flipper.fap" \
  --ipxe-efi "$HOME/Downloads/ipxe.efi" --ipxe-lkrn "$HOME/Downloads/ipxe.lkrn" \
  --safety-backup "$HOME/FlipperSafety"
```

The companion uses `netboot/dist/flipper` when complete, otherwise `netboot/flipper`. It copies the existing `apps_data` and `badusb` payload, optionally adding the FAP and iPXE files. FAP/iPXE checks are size/signature sanity checks, not upstream authentication or proof of exact firmware compatibility. If files are omitted, the review says what remains missing. Existing unrelated files are preserved; every differing overwrite needs `--safety-backup` and `Confirm` (or an explicit `--yes` after review). `--destination computer` saves a computer-only mirror; `both` saves both copies with hashes.

## Custom apps, scripts, and automations

```sh
secure-linux-flipper install my_app.fap --kind fap --app-folder USB --destination sd \
  --sd /run/media/you/FLIPPER --safety-backup "$HOME/FlipperSafety"
secure-linux-flipper install my_script.txt --kind badusb --destination sd --sd /run/media/you/FLIPPER
secure-linux-flipper install my_automation/ --kind data --dest apps_data/my_app \
  --destination computer --computer-dir "$HOME/FlipperPayload"
```

Every mapping and source hash is printed for review. Directory installs include the source directory's name. The `data` workflow does not claim that arbitrary scripts/automations are executable by RogueMaster; the destination app must define and support their format. No source is run as part of installation.

Build only with an already installed selected toolchain:

```sh
secure-linux-flipper toolchain-status
secure-linux-flipper build-fap /path/to/app --tool ufbt --output "$HOME/Builds"
secure-linux-flipper build-fap /path/to/RogueMaster/applications_user/my_app \
  --tool fbt --fbt-root /path/to/RogueMaster --app-name my_app --output "$HOME/Builds"
```

`ufbt` requires `application.fam`. `fbt` requires the reviewed source to already be inside `applications_user/APP_NAME`; the companion does not silently alter a firmware checkout. Either toolchain may fetch dependencies. A newly created/changed FAP is required; stale artifacts are not presented as a successful build. Build success does not establish compatibility with the connected device's exact RogueMaster version. No publishing command exists.

## Larger-screen use

```sh
secure-linux-flipper qflipper --scale 1.5
secure-linux-flipper open-sd --sd /run/media/you/FLIPPER
```

The first command launches installed official qFlipper with Qt scaling (or `--flatpak`). Screen viewing and control depend on qFlipper and device support. **Ordinary FAPs execute on the Flipper, not as native Linux applications.** The second opens the explicitly selected SD in the desktop file manager.

## Version linkage after USB changes

`release.json` is the canonical, content-derived release manifest. The installed copy at `linux/release.json`, this companion's `version.json`, every saved USB master, and the final netboot render all carry the same release ID. The companion also pins hashes for every current source Flipper pack file (documentation, BadUSB scripts, configuration and helpers) plus the FAP workflow.

```sh
# On an installed machine, after reviewed source changes and deliberate stamping:
secure-linux-release stamp
# Regenerate affected USB/netboot/master outputs, then check every surface:
secure-linux-release check
secure-linux-flipper version --check
```

`secure-linux-flipper refresh-version --yes` remains available to relink payload hashes to an **already stamped and current** central release. It refuses stale source and cannot invent a manual replacement release label. Changed, missing, or untracked payload files fail the check; regeneration and deliberate restamping are required before old outputs can be called current.

## Desktop integration

The supplied desktop file is `linux/files/experience/applications/secure-linux-flipper.desktop`. Its installed menu label is **Flipper Zero Backup & Files**, and it launches `secure-linux-flipper`. The normal Secure Linux setup installs the executable and companion modules with the other experience helpers; no manual PATH or desktop-file installation is needed on that installed system. The companion also appears in **Secure Linux Welcome & Setup** under **Flipper Zero — Open qFlipper**.

## Limitations

- No physical Flipper, SD card, qFlipper session, firmware flash, DFU operation, real `fbt` custom-animation build, on-device animation display, FAP build, or real hardware netboot test is performed by the mocked test suite. The cached official TGZ was host-validated, but no device flashed it.
- Only the stable public RogueMaster release workflow is automatic. The moving source branch is inspection-only, and no publisher signature was found in the researched release.
- Mount ownership and exact RogueMaster/FAP compatibility cannot be inferred by this app; backups do not make an old FAP compatible with a new firmware/API.
- SD rollback cannot roll back internal firmware/radio, and files added after the original backup may remain.
- Full device-side resource behavior cannot be transactionally controlled by the host. Staging and qFlipper launch are not flash-success evidence.
- Multi-destination installs verify each copy but are not a transactional atomic operation across two independent filesystems.
- FAT filesystems do not preserve all Unix metadata; hashes and file contents are the integrity contract.
- Best-effort staging wipe is not guaranteed secure erasure, especially on Flash/copy-on-write storage.
