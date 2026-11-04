# shellcheck shell=bash
# Wizard page (comfort): game saves from the Windows backup (Ludusavi) and what Steam/Epic do by themselves.
page_title() { echo "Your games and saves"; }
page_run() {
  . "$SL_ROOT/files/comfort/comfort-lib.sh"
  wz_is_done comfort-games && return 0
  [ "$(sl_profile)" = full ] || { wz_done comfort-games; return 0; }
  local a src M=$SL_ROOT/bin/secure-linux-migrate
  a=$(cf_ask3 "Your games: most of them bring their own saves back.

  - Steam games with Steam Cloud (most): saves come back by themselves when you install the game in Steam.
  - Rocket League: your cars, items and rank live in your Epic account. Sign in (Steam, or Heroic for the Epic version) and they're all there.
  - Other games: your Windows backup has a \"Games\" folder with saves (Saved Games, My Games, LocalLow).

Install Ludusavi, a free tool that finds game saves, backs them up and puts them back?" "Yes, install Ludusavi")
  case $a in never) wz_done comfort-games; return 0 ;; later) return 0 ;; esac
  wz_root "$M" install game_saves=yes
  src=$(cf_find_backup)
  wz_info "Ludusavi is installed (app menu > Ludusavi).

How to bring an old save back:
  1. Install and start the game once in Steam (so it creates its folders), then quit it.
  2. Open Ludusavi, go to \"Backup mode\" and click \"Preview\". It lists your games and where each keeps its saves on this laptop (click a game to see the folder).
  3. Copy that game's files from your Windows backup (Games > Saved Games, My Games or LocalLow > the game's name) into that folder, replacing the new ones.
  (Ludusavi's \"Restore mode\" is for backups Ludusavi itself made, so it can't read the Windows copy directly.)
  4. From now on, use Ludusavi's \"Backup mode\" now and then, so your saves are safe.
$([ -n "$src" ] && printf '\nYour Windows backup: %s/Games' "$src")"
  flatpak run com.github.mtkennerly.ludusavi >/dev/null 2>&1 &
  [ -n "$src" ] && [ -d "$src/Games" ] && wz_open "$src/Games"
  wz_done comfort-games
  return 0
}
