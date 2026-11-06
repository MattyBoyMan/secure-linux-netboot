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
| Experience | welcome, backups, battery, firmware, release and Flipper integration | `secure-linux-welcome`, `-backup-check`, `-flipper`, `-release` |

## Five-screen welcome contract

The default `secure-linux-welcome` journey is exactly five visible screens. The top-level files are:

| File | Guide/checker ID | Display title |
|---|---|---|
| `wizard.d/00-core.sh` | `00-core` | None: titleless shared infrastructure |
| `wizard.d/01-system.sh` | `01-system` | `1 of 5 — Your recommended setup` |
| `wizard.d/02-identity.sh` | `02-identity` | `2 of 5 — You, Wi-Fi and passwords` |
| `wizard.d/03-apps-security.sh` | `03-apps-security` | `3 of 5 — Applications and protection` |
| `wizard.d/04-extras.sh` | `04-extras` | `4 of 5 — Optional extras` |
| `wizard.d/05-review.sh` | `05-review` | `5 of 5 — Review everything` |

The five visible page files call `sl_wizard_show system|identity|apps|extras|review`; they do **not** define `page_title`. Guide tooling therefore uses their shell stems as IDs and the guide must include both stems and display titles.

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
