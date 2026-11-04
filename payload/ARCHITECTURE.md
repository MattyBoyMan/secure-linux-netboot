# Secure Linux: on-machine architecture

Everything that runs on the installed Fedora machine lives in this `linux/` folder.
The USB builder packs it into the installer; it is unpacked to **`/usr/local/lib/secure-linux/`**
(called `$SL_ROOT` below). Nothing here may assume another location.

## Layout

```
linux/
  setup.sh            orchestrator: runs steps/*.sh in name order (owned by: integrator)
  lib/common.sh       shared helpers every step and helper sources (owned by: integrator)
  steps/NN-name.sh    one file per area, sourced by setup.sh (owner listed below)
  bin/secure-linux-*  helper commands, all installed to /usr/local/bin. A helper that needs root re-runs
                      itself with `pkexec` (`[ "$(id -u)" -eq 0 ] || exec pkexec "$0" "$@"`) so it works from
                      menus and from other helpers. Every helper supports `--help`.
  files/<area>/...    per-area files, installed GENERICALLY by 00-early.sh (owners just drop files here):
                        files/<area>/applications/*.desktop   -> /usr/share/applications/
                        files/<area>/autostart/*.desktop      -> /etc/xdg/autostart/
                        files/<area>/systemd/system/*         -> /etc/systemd/system/
                        files/<area>/systemd/user/*           -> /etc/systemd/user/
                        files/<area>/enable-system.list       units to `systemctl enable` (one per line)
                        files/<area>/enable-user.list         units to `systemctl --global enable`
                        anything else stays in $SL_ROOT/files/<area>/ for that area's step to use
  rescue/             scripts copied to the USB stick for use from SystemRescue (not installed)
  server/             optional scripts the user runs on their home server (not installed)
  build.conf          WRITTEN BY THE USB BUILDER, never committed: key=value build settings
```

## Who owns what (only edit your own files)

| Owner | Steps | bin/ helpers | files/ |
|---|---|---|---|
| integrator | setup.sh, lib/common.sh | - | - |
| system | 00-early.sh, 10-base.sh, 30-updates.sh, 35-storage.sh, 90-finish.sh | secure-linux-check, -notify, -status, -status-gui, -terminal, -diag, -upgrade, -outside-apps | files/system/ |
| security | 20-network.sh, 25-security.sh | secure-linux-dns, -hotspot, -vpn, -zone, -recovery-key, -mok-remove, -tpm-pin, -fido2 | files/security/ |
| experience | 40-apps-common.sh, 50-apps-full.sh, 60-hardware.sh, 70-desktop.sh | secure-linux-welcome, -battery, -hwtest, -fleet, -ai, -backup-check | files/experience/, rescue/, server/ |
| comfort | 45-migration.sh, 75-comfort.sh | secure-linux-migrate, -emergency-kit, -tips, -explain, -family | files/comfort/, wizard.d/ |
| hardware | 15-drivers.sh | secure-linux-drivers (+ health, parts, repair: see next row) | files/hardware/, hw/ (detect.sh, compat-check.sh, compat-check-min.sh, mac/), asahi/, ../docs/COMPATIBILITY.md, ../tests/hardware/ |
| homeassistant | 76-homeassistant.sh | secure-linux-ha, -ha-setup, -ha-secure, -ha-learn | files/homeassistant/, wizard.d/80, ../server/homeassistant/, ../tests/homeassistant/ |
| health | (uses 15-drivers.sh) | secure-linux-health, -repair, -parts | rescue/, hw/health/, files/hardware/, ../tests/rescue/ |
| debian | (separate tree: ../debian/) | Debian port of lite setup; see ../debian/INTEGRATION.md | ../debian/, ../tests/debian/ |

## Welcome-wizard plug-in pages (wizard.d)

`secure-linux-welcome` (experience) runs its own pages, then every `$SL_ROOT/wizard.d/NN-name.sh` in order.
Each page file defines two bash functions and nothing else at top level:
- `page_title` prints a short title; `page_run` shows the page (use the `wz_*` helpers below) and returns 0.
The welcome provides these helpers to pages (experience implements them in secure-linux-welcome):
`wz_info "text"`, `wz_yesno "question"` (0 = yes), `wz_choice "question" opt1 opt2 ...` (prints the chosen option),
`wz_input "question" [default]`, `wz_open URL_or_file`, `wz_root CMD...` (runs a command as root via pkexec),
`wz_done KEY` / `wz_is_done KEY` (per-user completion marks so pages can be resumed or skipped).
Pages save system choices with `wz_root /usr/local/lib/secure-linux/bin/secure-linux-choice set KEY VALUE`
(experience provides `secure-linux-choice get|set`, a tiny pkexec-able wrapper around sl_choice_get/set).

## Contract for steps

- A step is a bash file **sourced** by setup.sh (`set -uo pipefail` already on; do not `exit`, use `return`).
- It must be **idempotent**: running twice changes nothing the second time. Check before acting
  (`sl_dnf_install`, `sl_flatpak_install` and `sl_write_file` already do).
- It must respect `SL_PROFILE` (`full`, `lite`, or `atomic`) and the user's saved choices (`sl_choice_get`).
- It must respect `SL_MODE`:
  - `install`: first boot, everything.
  - `repair`: re-assert config, services and timers; install only what is missing; never re-download
    things that are already installed; never overwrite a file the user changed (sl_write_file handles
    this via a stored checksum of what we last wrote).
  - `early`: running inside the installer chroot (no network, no running systemd). Only `00-early.sh`
    does anything in this mode; it installs bin/ helpers, units, .desktop files and the autostart
    entry, using `systemctl enable` (never `--now`). Other steps must `return 0` when `SL_MODE=early`.
- Report progress with `sl_step "Short description"` at the start of each logical part.
- Wrap every command that may fail in `try` (records failures; never aborts the run).
- On the `atomic` profile there is no dnf: use `sl_flatpak_install` and `rpm-ostree` only;
  steps that cannot apply must `return 0` early.

## Shared state

| Path | Meaning |
|---|---|
| `/etc/secure-linux/profile` | full / lite / atomic |
| `/etc/secure-linux/user` | the main user's login name |
| `/etc/secure-linux/choices` | key=value, written by the welcome wizard and helpers (`sl_choice_get/set`) |
| `/var/lib/secure-linux/alerts.d/<id>` | one file per active alert: line 1 title, line 2 message, line 3 action hint. Producers create/remove their own ids. |
| `/var/lib/secure-linux/events.d/<id>` | one-off events (e.g. setup-finished). Shown once per user, then acknowledged. |
| `/var/lib/secure-linux/health/` (latest.txt, latest.json from secure-linux-health), `/var/lib/secure-linux/parts/` (parts mapper state), `skipped-apps` (`app|reason` lines) | health reports; alerts use ids `health-*`, `parts-pending`; events `parts-*` |
| `/var/lib/secure-linux/progress` | `N|TOTAL|text` while setup runs, `done|done|Setup finished` after |
| `/var/lib/secure-linux/written/` | checksums of files sl_write_file wrote (for repair mode) |
| `/var/log/secure-linux/setup.log`, `failures.log` | setup output; failures from the latest run only |

## Choice keys (wizard writes, steps read; default in brackets)

`vpn_mode` [private|home|off; unset = not chosen yet], `nord_killswitch` [no], `home_ssid` [build.conf HOME_WIFI_SSID],
`battery_limit` [unset], `opensnitch` [yes: on by default on full; on lite only if RAM >= 3 GB, daemon only; set `no` to switch off; no wizard question],
`immich_url` [build.conf IMMICH_URL; the home photo server address, read with sl_choice_get then sl_build_get],
`server_health_url` [unset; address of the server kit's backup-health.txt: `status=ok|error`, `last_backup=<ISO date>`],
`netguard_notify` [yes], `netguard_prompt_duration` [always|restart], `tpm_pin` [no], `default_browser` [librewolf], `librewolf_keep_cookies` [no],
`warp` [no], `backup_target` [unset], `recovery_key_done` [no], `mok_removed` [no], `tpm_pin` [no],
`ai_models` [qwen2.5-coder:7b,qwen2.5-coder:1.5b], `ollama_vulkan` [no], `lite_auto_reboot` [no],
`privacy_countme_off` [yes], `syncthing_lan_only` [yes],
`nord_autoconnect` [yes], `nord_lan_discovery` [yes], `nord_threat_protection` [yes], `family_dns` [no],
`mok_removed` [no|pending|yes], `home_ssid` (`-` = no home Wi-Fi), `secureboot_intent` [on|off, from the installer],
`hibernate` [no|on-lid|sleep-then-hibernate], `ai_abliterated` [yes|no, from the installer], `drm` [no],
`power_tuning` [yes], `power_battery_saver` [yes], `welcome_done` [no], `backup_target` [usb|server]

`parts_autoinstall` [yes|no; yes = hot-plugged devices get their free repo software installed], `ha_url` [http://homeassistant.local:8123], `ha_local` [no], `ha_token_file` [/etc/secure-linux/ha-token; path only, never the token], `ha_remote_mode` [unset: meshnet|wireguard|tailscale|cloudflare|nabucasa|none|portforward|other], `ha_ssh` [unset], `ha_have_server` [unset], `ha_esphome` [no], `ha_config_dir`. Full descriptions: ../docs/notes/homeassistant-choice-keys.md.

Per-user alerts: `/var/lib/secure-linux/user-alerts/<user>/<id>` (same 3-line format as alerts.d; written by user-level
helpers such as secure-linux-backup-check; shown by the notifier and status app).

## build.conf extra keys
`MODEL_FILE`, `MODEL_SHA256`, `MODEL_URL` (optional unfiltered AI model)

Shell note: setup.sh runs with `set -u` only (no pipefail), because `cmd | grep -q` checks are common.

## build.conf keys (from the USB builder)

`SL_USER`, `SL_FULLNAME`, `IMMICH_URL`, `HOME_WIFI_SSID`, `HOME_SUBNET` (e.g. 10.0.30.0/24, may be empty),
`BUILD_DATE`, `FEDORA_VERSION`, `TIMEZONE`, `REGDOM` (Wi-Fi country, e.g. AU)
