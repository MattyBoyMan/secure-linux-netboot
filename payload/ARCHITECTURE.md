# Secure Linux: on-machine architecture

Everything that runs on an installed Fedora machine lives in `linux/`. The USB builder packs it into the installer and unpacks it to **`/usr/local/lib/secure-linux/`** (`$SL_ROOT`). Installed helpers live in `/usr/local/bin`; examples and menu launchers use names such as `secure-linux-ai`, not source-tree Python paths. Debian has a separate port under `debian/`.

## Layout

```text
linux/
  setup.sh                 orchestrator: sources steps/*.sh in name order
  lib/common.sh            shared shell helpers
  lib/                     native application and companion Python modules
  steps/NN-name.sh         one sourced file per setup area
  bin/secure-linux-*       installed command-line and graphical entry points
  wizard.d/                top-level five-screen pages and on-demand plug-ins
  files/<area>/...         desktop files, units and area-specific payloads
  rescue/                  scripts copied for SystemRescue use
  server/                  optional scripts run on a home server
  hw/                      detection, compatibility, health and repair modules
  asahi/                   Apple Silicon integration notes and helpers
  release.json             installed release record linked to canonical release.json
  build.conf               builder-written local settings; never commit secrets
```

`files/<area>/applications/*.desktop` installs to `/usr/share/applications/`; `autostart/*.desktop` installs to `/etc/xdg/autostart/`; `systemd/system/*` and `systemd/user/*` install to the corresponding `/etc/systemd/` directories. `enable-system.list` and `enable-user.list` name units to enable. Other files remain under `$SL_ROOT/files/<area>/` for their step.

A helper that needs root may re-run itself through `pkexec` so it works from a menu and from another helper. Helpers should support `--help`. Graphical native launchers include `secure-linux-control-center`, `secure-linux-activity`, `secure-linux-setup-hub`, `secure-linux-update-gui`, `secure-linux-home-server-gui`, `secure-linux-usb-creator-gui` and `secure-linux-usb-fixer-gui`.

## Setup areas and helper families

The historical owner table was a parallel-editing convention, not a runtime restriction. Current integration must review cross-area launchers and state rather than assuming the old lists are complete.

| Area | Steps and responsibilities | Representative helpers/files |
|---|---|---|
| Early/base/offline | `00-early.sh`, `03-offline-packs.sh`, `10-base.sh` install payloads and core packages | `secure-linux-offline-bundle`, generic `files/` installer |
| Hardware/health | `15-drivers.sh`, `60-hardware.sh`; detection, drivers, device software, health and repair | `secure-linux-drivers`, `-parts`, `-health`, `-repair`, `-diagnose`, `-toolbox`, USB helpers, `hw/` |
| Network/security | `20-network.sh`, `25-security.sh`; DNS, VPN, firewall and account/device protections | `secure-linux-dns`, `-vpn`, `-zone`, `-netguard`, `-control-center`, `-security-audit` |
| Updates/storage/finish | `30-updates.sh`, `35-storage.sh`, `90-finish.sh` | `secure-linux-check`, `-status`, `-update-now`, `-update-gui`, `-upgrade`, `-activity` |
| Applications/desktop | `40-apps-common.sh`, `50-apps-full.sh`, `70-desktop.sh`, `79-docker.sh` | AI, Setup Hub, native launchers, rootless Docker integration |
| Migration/comfort | `45-migration.sh`, `75-comfort.sh`; on-demand migration and personalisation | `secure-linux-migrate`, `-finish`, `-family`, `-tips`, `-explain`, `wizard.d/` plug-ins |
| Home Assistant/fleet | `76-homeassistant.sh` and optional server kit | `secure-linux-ha*`, `-home-server*`, `-pihole`, `-fleet*` |
| Experience | welcome, backups, battery, firmware, release and Flipper integration | `secure-linux-welcome`, `-backup-check`, `-backup`, `-backup-gui`, `-flipper`, `-release`; `secure-linux-backup copies|install-borg|offer-home` (the 3-2-1 view, BorgBackup on demand, one gentle offer of backups to the home server) |

## Five-screen welcome contract

The default `secure-linux-welcome` journey is one information page (`00-about`, no question, before any choice) followed by exactly five question screens. The top-level files are:

| File | Guide/checker ID | Display title |
|---|---|---|
| `wizard.d/00-about.sh` | `00-about` | `Welcome — what your Secure Linux drive can and cannot do` (information only) |
| `wizard.d/00-core.sh` | `00-core` | None: titleless shared infrastructure |
| `wizard.d/01-system.sh` | `01-system` | `1 of 5 — Your recommended setup` |
| `wizard.d/02-identity.sh` | `02-identity` | `2 of 5 — You, Wi-Fi and passwords` |
| `wizard.d/03-apps-security.sh` | `03-apps-security` | `3 of 5 — Applications and protection` |
| `wizard.d/04-extras.sh` | `04-extras` | `4 of 5 — Optional extras` |
| `wizard.d/05-review.sh` | `05-review` | `5 of 5 — Review everything` |

The information page calls `sl_wizard_show about`; the five question page files call `sl_wizard_show system|identity|apps|extras|review`; they do **not** define `page_title`. Guide tooling therefore uses their shell stems as IDs and the guide must include both stems and display titles.

Nothing changes before the final review. Confirm starts enabled steps, Back returns to answers and closing cancels. There is no first-run countdown. Protection choices are **Recommended — everyday protection**, **Stricter — also VPN private mode and audit log**, and **Custom — keep current settings, then untick or tick below**.

`wizard.d/legacy/` and the numbered migration/comfort/server pages remain available on demand. In particular, legacy `05-security.sh` retains `Choose your protection level` but is not part of the five-screen journey. Use `secure-linux-welcome --page PAGE`, `secure-linux-migrate`, or the fixed journeys in `secure-linux-setup-hub`.

Built-in on-demand page IDs are `browser homewifi vpn battery recovery backup ai syncthing netguard hwtest tpmpin mok`. `--again`, `--status` and `--add-family-member` remain supported.

### Legacy plug-in helpers

Legacy plug-in pages that still use the old contract define `page_title` and `page_run`; do not apply that statement to the new top-level five screens. The welcome command supplies `wz_info`, `wz_yesno`, `wz_choice`, `wz_input`, `wz_open`, `wz_root`, `wz_done` and `wz_is_done` where used. System choices can be saved with `wz_root /usr/local/lib/secure-linux/bin/secure-linux-choice set KEY VALUE`.

## Native applications

- **Setup Hub** (`secure-linux-setup-hub`) opens thirteen fixed existing graphical journeys. It has no embedded web view or local server.
- **Control Centre** (`secure-linux-control-center`) owns reviewed preset/custom security changes and verifies the result. Fedora dependencies are `python3-gobject`, `gtk4`, `libadwaita`; Debian uses `python3-gi`, `gir1.2-gtk-4.0`, `gir1.2-adw-1`.
- **My Computer Activity** (`secure-linux-activity`) reads local metadata and opens only fixed existing tools. It does not capture packets, request network activity data, inspect browsing history or read document contents. HTML export follows preview and destination selection.
- **Private AI** (`secure-linux-ai`) dispatches GUI, scan/models/route, download/install/remove, chat, benchmark, frontend and Colibri workflows, while retaining documented legacy commands. Model fit gates and benchmark records are project data, not upstream quality or throughput guarantees.
- **Home & Server Helper** and **Pi-hole** use `linux/lib/` modules and physical entry points. unRAID operations manage an existing server over BatchMode SSH.
- **Flipper** uses `linux/lib/flipper-companion/`; its installed desktop entry is **Flipper Zero Backup & Files**.

## Contract for setup steps

- A step is Bash **sourced** by `setup.sh`; do not `exit`, use `return`.
- It must be idempotent. Check before acting; `sl_dnf_install`, `sl_flatpak_install` and `sl_write_file` provide existing guards.
- Respect `SL_PROFILE` (`full`, `lite`, or `atomic`; the Min recommendation uses the lite profile with LXQt) and saved choices.
- Respect `SL_MODE`: `install` for first boot, `repair` for missing/reasserted configuration without overwriting user changes, and `early` inside the installer chroot. Only early-safe work may run without network or running systemd; enable units without `--now` in that mode.
- Report logical parts with `sl_step`. Record expected failures through the existing `try` mechanism rather than silently losing them.
- Atomic has no ordinary dnf transaction: use the established Flatpak and rpm-ostree paths or return early when a step cannot apply.

`setup.sh` runs with `set -u` only (no global pipefail) because existing `cmd | grep -q` checks rely on it.

## Shared state

| Path | Meaning |
|---|---|
| `/etc/secure-linux/profile` | `full`, `lite` or `atomic` |
| `/etc/secure-linux/user` | Main user's login name |
| `/etc/secure-linux/choices` | Key=value choices written by helpers and wizard pages |
| `/var/lib/secure-linux/alerts.d/<id>` | Active alert: title, message and action hint on three lines |
| `/var/lib/secure-linux/events.d/<id>` | One-off events acknowledged per user |
| `/var/lib/secure-linux/user-alerts/<user>/<id>` | Per-user three-line alerts |
| `/var/lib/secure-linux/health/` | Latest health reports |
| `/var/lib/secure-linux/parts/` | Parts-mapper state |
| `/var/lib/secure-linux/progress` | Setup progress, then `done|done|Setup finished` |
| `/var/lib/secure-linux/written/` | Checksums used by `sl_write_file` repair protection |
| `/var/log/secure-linux/setup.log` | Setup output |
| `/var/log/secure-linux/failures.log` | Failures from the latest run |

Native tools also use their own explicit state/journal files. Setup-App recovery state belongs to the Windows setup flow and must remain non-secret. Activity exports are user-reviewed HTML, not a background telemetry stream.

## Choice keys

`secure-linux-choice get|set|list` wraps the shared choice store. Existing keys include:

`vpn_mode` [private|home|off], `nord_killswitch` [no], `home_ssid` [build value or `-`], `battery_limit` [unset], `opensnitch` [profile-dependent], `immich_url` [build value], `server_health_url` [unset], `netguard_notify` [yes], `netguard_prompt_duration` [always|restart], `default_browser` [librewolf], `librewolf_keep_cookies` [no], `warp` [no], `backup_target` [usb|server|unset], `recovery_key_done` [no], `mok_removed` [no|pending|yes], `tpm_pin` [no], `ai_models` [selected models], `ollama_vulkan` [no], `lite_auto_reboot` [no], `privacy_countme_off` [yes], `syncthing_lan_only` [yes], `nord_autoconnect` [yes], `nord_lan_discovery` [yes], `nord_threat_protection` [yes], `family_dns` [no], `secureboot_intent` [on|off], `hibernate` [no|on-lid|sleep-then-hibernate], `ai_abliterated` [installer choice], `drm` [no], `power_tuning` [yes], `power_battery_saver` [yes], `welcome_done` [no], `parts_autoinstall` [yes|no].

Home Assistant keys include `ha_url`, `ha_local`, `ha_token_file` (a path, never the token), `ha_remote_mode`, `ha_ssh`, `ha_have_server`, `ha_esphome` and `ha_config_dir`. Fleet and application-selection keys are read by their respective steps. `SL_ETC`, `SL_STATE` and `SL_LOGDIR` have overridable defaults for isolated tests.

## Builder-provided settings

`build.conf` may provide `SL_USER`, `SL_FULLNAME`, `IMMICH_URL`, `HOME_WIFI_SSID`, `HOME_SUBNET`, `BUILD_DATE`, `FEDORA_VERSION`, `TIMEZONE`, `REGDOM`, and optional legacy model values `MODEL_FILE`, `MODEL_SHA256`, `MODEL_URL`. Treat this file as local and secret-bearing; do not commit it.

## Documentation and release boundary

Guide sources are outside `linux/` in `guide/src/chapters/`, `guide/data/pages*.json` and `guide/data/apps-*.json`. Regenerate `guide/data/pages-chapters.json` with `node guide/tools/pack-chapters.mjs` and `guide/START-HERE.html` with `build-guide.ps1`. Update `guide/tools/coverage-map.json` for physical commands, top-level/legacy wizard IDs and every desktop menu label.

`secure-linux-release stamp` is a deliberate source-linking action, not a substitute for rebuilding outputs. `secure-linux-release check` compares the canonical source record, installed record, Flipper hashes, rendered netboot output and selected saved masters. Documentation work must not relabel generated outputs or claim physical verification.

## Updates, versions and release checking (added with the 2026-11 build)

| Piece | What it is | Where |
|---|---|---|
| `secure-linux-kit-update` | `check`, `apply`, `undo` and `status`. Fetches only files whose SHA-256 differs, checks each one, then swaps. A tree lock makes two runs at once wait, then exit 75. `--set debian|flipper|netboot --tree DIR` keeps the Debian, Flipper and network-install files from their own signed lists. | `linux/bin/secure-linux-kit-update` |
| `secure-linux-kit-update-auto` | Runs a few minutes after start-up and once a day (`secure-linux-kit-update-auto.timer`). In signed mode it applies a newer release by itself, refreshes helpers, menus and timers, syncs the saved master and leaves one note per release (`events.d/kit-update-done-<id>`, `kit-update-ready-<id>`). `undo` goes back and writes a hold so the same release is not installed again. `set --online yes|no --auto-apply yes|no --channel stable|testing --mirror FOLDER`. | `linux/bin/secure-linux-kit-update-auto`, `/etc/secure-linux/kit-update.conf` |
| `secure-linux-release-verify` | `status` lists trusted and withdrawn keys. `check` verifies a release: `release.json` and `payload-files.json` with detached signatures against the public keys in `share/secure-linux-release-keys/*.asc`. Exit 0 verified, 1 refused, 2 usage, 3 not set up yet (bridge mode: callers keep their old behaviour). The signed channel record and the signed release history are verified the same way. | `linux/bin/secure-linux-release-verify` |
| `secure-linux-versions` | The Versions screen: `--text`, `--json` or a window. Buttons run `secure-linux-update-now`, `secure-linux-kit-update-auto undo`, `secure-linux-whats-new --gui`, `secure-linux-explain --update`, and `secure-linux-kit-update-auto set`. Reading uses no network. | `linux/bin/secure-linux-versions`, `linux/lib/versions_model.py`, `linux/lib/versions_gtk.py` |
| `secure-linux-whats-new` | Shows the note in `files/release-notes/release-notes.json` for the release that was just installed. Reads only the kit folder. | `linux/bin/secure-linux-whats-new` |
| `secure-linux-kit-share` | `start`, `stop`, `status`, plus `serve`, `find` and `network` run by the system. Serves this computer's signed release record, file list, channel record and release history, read-only, on the home network only. Peers are listed in `/run/secure-linux/kit-peers.json`. | `linux/bin/secure-linux-kit-share`, `linux/files/kitshare/` |
| `secure-linux-master-sync` | `run` and `status` only. Brings the saved master (the root-owned store behind the drive builder) up to this computer's release. Asks for a password through `pkexec`. | `linux/bin/secure-linux-master-sync` |
| `secure-linux-boot-rollback` | `status`, `check`, `on`, `off`, `refresh`, `keep`, `newest`, `tidy`. Adds "go back to an earlier day" lines to the boot menu on Btrfs with Snapper. The normal start stays first and default. | `linux/bin/secure-linux-boot-rollback`, `linux/files/bootrollback/`, step `32-boot-rollback.sh` |

## Drives, copies and checks

| Piece | What it is |
|---|---|
| `secure-linux-usb-creator` | Plug-ins in `linux/lib/usbc_*.py`: generations (`master-undo`, `master-prune`), seal (`seal-personal`), live (`live-addon`) and refresh (`refresh-master`). Every plug-in checks the exact serial phrase before a disk write and refuses internal and non-removable disks. |
| `secure-linux-usb-multi` | Several drives at once from the saved master, each fully checked. |
| `secure-linux-drive-test` | Fake-capacity and bad-block test. Erases the drive. |
| `secure-linux-check-drive` | Read-only check of a drive: the Secure Linux files against the signed list, shared files by size and SHA-256, per-drive files only noted. Launched from `CHECK-THIS-DRIVE.sh` (POSIX sh). Exit 0 good, 2 problem, 64 usage. |
| `secure-linux-usb-fixer` | `check-drive` and `repair-drive`. Repair puts back shared files and never writes per-drive files or the persistence file. |
| Passport | `SECURE-LINUX-DRIVE-FILES.json` (shared and per-drive lists, `linux/setup-data/drive-per-drive-files.txt`) and `SECURE-LINUX-DRIVE-PASSPORT.json` with a plain text twin, written at the end of a verified portable copy. A master never keeps either. |
| Live drive | `linux/lib/usbc_live.py` adds the Fedora KDE live image (checked with Fedora's signed CHECKSUM through `gpgv`), a boot menu line and a per-drive persistence file. `linux/lib/live-session/secure-linux-live-session` is the read-only helper inside the live system. |
| NOMAD | `nomad/` holds the offline library kit. `nomad/anywhere/drive-root/` holds the starters for the top of the drive (`START-NOMAD.cmd`, `START-NOMAD.command`, `START-NOMAD-LINUX.sh`) and the plain-text pages. Apple M-chip Macs cannot start from the drive. The no-restart way runs under the host system and is less secure than starting from the drive. |

## Safety, home network and everyday helpers

| Command | Purpose |
|---|---|
| `secure-linux-panic-lock` | Locks the screen, closes the home server folder, drops cached administrator credentials and clears the clipboard. Never asks for a password. |
| `secure-linux-travel` | `on`, `off`, `status`, `boot`. Keeps the home server folder closed, switches Bluetooth and SSH off and uses random hardware addresses. Everything is put back by `off`. |
| `secure-linux-sandbox` | `open FILE`, `link URL`, `check`. A bubblewrap sandbox with no network and no view of the home folder, deleted on exit. |
| `secure-linux-if-stolen` | Checklist, serial number and an "if found" lock-screen message. There is no remote lock or wipe; the tool says so. |
| `secure-linux-leak-check` | k-anonymity password check: only the first five characters of a SHA-1 leave the computer. |
| `secure-linux-network-devices` | Lists devices on the home network and flags new ones. Local only. |
| `secure-linux-attack-shield` | CrowdSec blocklist in three modes (`receive`, `local`, `share`). Off until `setup`. `panic-off` removes every block. |
| `secure-linux-daily-summary` | One line about backups, updates, disk and security from results other helpers already wrote. |
| `secure-linux-which-app` | Suggests one free app for a task, from `setup-data/task-apps.tsv` and `setup-data/app-equivalents.tsv`. |
| `secure-linux-veracrypt-install` | Adds VeraCrypt from the maker's package after a SHA-256 check. `when` explains VeraCrypt, Cryptomator and the disk lock. |
| `secure-linux-move-setup` | `pack`, `check`, `unpack`, `install-apps`. Passwords, keys and browser data never move. |
| `secure-linux-reset` | `plan`, `status`, `settings`, `system`, `undo-settings`, `undo-apps`, `point`. Reset point made by step `96-reset-point.sh`. |
| `secure-linux-phone-backup` | `check`, `backup`, `list`, `open`, `mirror`. Locked backups through `age` or `gpg`; scrcpy download is pinned by SHA-256. |
| `secure-linux-home-share` | The owner's home server folder, ready at home. Its address and password are never in the kit or on a drive. |
| `secure-linux-remote-access` | An own WireGuard door (`setup`, `add`, `remove`, `off`, `forget`) with a guard that keeps added devices from reaching other home devices. |
| `secure-linux-media-server` | Front door to the Jellyfin setup script. Home network only. |
| `secure-linux-live-health` | Netdata, local only, anonymous statistics off, never connected to Netdata Cloud. |
| `secure-linux-app-library` | The Optional apps catalogue from `setup-data/apps.d/*.tsv`, run by step `52-app-library.sh`. |
| `secure-linux-offline-library`, `secure-linux-translate-languages` | Offline Kiwix libraries and language files. Never automatic; size shown first. |
| `secure-linux-tv-cleanup` | Hides apps on a Chromecast or Google TV over adb, with a saved state and `undo`. |
| `secure-linux-ai-web`, `secure-linux-voice`, `secure-linux-server-apps`, `secure-linux-ntfy` | The AI chat page, the voice helper, the home-server app engine and the phone notification helper. |

## Every command, by family

Full names, so this file can be searched. `tests/guidecover` checks that every file in `linux/bin/` is named here.

| Family | Commands |
|---|---|
| Updates and releases | `secure-linux-kit-update`, `secure-linux-kit-update-auto`, `secure-linux-kit-share`, `secure-linux-release`, `secure-linux-release-verify`, `secure-linux-versions`, `secure-linux-whats-new`, `secure-linux-update-now`, `secure-linux-update-gui`, `secure-linux-upgrade`, `secure-linux-master-sync`, `secure-linux-boot-rollback` |
| Drives | `secure-linux-usb-creator`, `secure-linux-usb-creator-gui`, `secure-linux-usb-fixer`, `secure-linux-usb-fixer-gui`, `secure-linux-usb-multi`, `secure-linux-drive-test`, `secure-linux-check-drive`, `secure-linux-offline-bundle`, `secure-linux-offline-library`, `secure-linux-translate-languages` |
| Health and repair | `secure-linux-check`, `secure-linux-health`, `secure-linux-hwtest`, `secure-linux-hwtest-marker`, `secure-linux-diag`, `secure-linux-diagnose`, `secure-linux-repair`, `secure-linux-status`, `secure-linux-status-gui`, `secure-linux-toolbox`, `secure-linux-drivers`, `secure-linux-firmware`, `secure-linux-battery`, `secure-linux-hibernate`, `secure-linux-parts`, `secure-linux-daily-summary`, `secure-linux-live-health`, `secure-linux-notify` |
| Network and security | `secure-linux-dns`, `secure-linux-hotspot`, `secure-linux-vpn`, `secure-linux-zone`, `secure-linux-netguard`, `secure-linux-attack-shield`, `secure-linux-network-devices`, `secure-linux-security-audit`, `secure-linux-control-center`, `secure-linux-recovery-key`, `secure-linux-tpm-pin`, `secure-linux-mok-remove`, `secure-linux-fido2`, `secure-linux-leak-check`, `secure-linux-sandbox`, `secure-linux-panic-lock`, `secure-linux-travel`, `secure-linux-if-stolen`, `secure-linux-veracrypt-install` |
| Backups and moving | `secure-linux-backup`, `secure-linux-backup-gui`, `secure-linux-backup-check`, `secure-linux-phone-backup`, `secure-linux-move-setup`, `secure-linux-reset`, `secure-linux-migrate`, `secure-linux-emergency-kit` |
| Home and server | `secure-linux-home-server`, `secure-linux-home-server-gui`, `secure-linux-home-share`, `secure-linux-server-apps`, `secure-linux-media-server`, `secure-linux-pihole`, `secure-linux-remote-access`, `secure-linux-ntfy`, `secure-linux-fleet`, `secure-linux-fleet-join`, `secure-linux-ha`, `secure-linux-ha-learn`, `secure-linux-ha-secure`, `secure-linux-ha-setup`, `secure-linux-tv-cleanup`, `secure-linux-flipper` |
| Everyday | `secure-linux-welcome`, `secure-linux-setup-hub`, `secure-linux-finish`, `secure-linux-ready`, `secure-linux-choice`, `secure-linux-care`, `secure-linux-family`, `secure-linux-tips`, `secure-linux-explain`, `secure-linux-which-app`, `secure-linux-app-library`, `secure-linux-outside-apps`, `secure-linux-terminal`, `secure-linux-activity` |
| AI | `secure-linux-ai`, `secure-linux-ai-web`, `secure-linux-voice` |
