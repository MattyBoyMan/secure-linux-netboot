# shellcheck shell=bash
# Wizard page (comfort): OneDrive -> ~/OneDrive-Archive (rclone), notes app (Obsidian or Joplin) and the
# notes vault -> ~/Vaults/NAME shared with the phone through Syncthing.
page_title() { echo "Copy your OneDrive and notes"; }
page_run() {
  . "$SL_ROOT/files/comfort/comfort-lib.sh"
  local a M=$SL_ROOT/bin/secure-linux-migrate vault name res dest

  # ---- OneDrive copy
  if ! wz_is_done comfort-onedrive; then
    a=$(cf_ask3 "Copy everything from your OneDrive onto this laptop?

Your files are copied into a folder called \"OneDrive-Archive\" in your home folder. Nothing is deleted from OneDrive, so you can check everything first and cancel the subscription later.

A window opens: sign in to Microsoft in your browser when asked, then let it copy (big OneDrives take hours; you can keep working). At the end it checks that every file arrived.

Good to know: OneNote notebooks and the \"Personal Vault\" can't be copied this way. Export OneNote pages from the OneNote app, and move Personal Vault files out of the vault first." "Yes, copy my OneDrive")
    case $a in
      never) wz_done comfort-onedrive ;;
      yes) cf_terminal "$M" onedrive all &
           wz_done comfort-onedrive ;;
    esac
  fi

  # ---- notes app + vault
  wz_is_done comfort-notes && return 0
  [ "$(sl_profile)" = lite ] && { wz_done comfort-notes; return 0; }
  a=$(wz_choice "Which notes app would you like?

You used Obsidian on Windows (with your notes \"vault\" in OneDrive).
  - Obsidian: exactly what you know. Free, but not open source.
  - Joplin: already installed, fully open source, can import an Obsidian vault (File > Import > \"MD - Markdown (Directory)\").
Your notes are plain text files either way, so you can switch any time." \
    "Obsidian (what I used before)" "Joplin (already here)" "Both" "Decide later")
  case $a in
    "Obsidian (what I used before)") wz_root "$M" install notes_app=obsidian ;;
    "Both") wz_root "$M" install notes_app=both ;;
    "Joplin (already here)") cf_save_choice notes_app joplin ;;
    *) return 0 ;;
  esac

  # find the vault: a folder with .obsidian in it (OneDrive copy, or the Windows backup)
  vault=""
  for res in "$HOME/OneDrive-Archive" "$(cf_find_backup)"; do
    [ -n "$res" ] && [ -d "$res" ] || continue
    vault=$(find "$res" -maxdepth 5 -type d -name .obsidian 2>/dev/null | head -1)
    [ -n "$vault" ] && { vault=${vault%/.obsidian}; break; }
  done
  if [ -z "$vault" ]; then
    wz_info "We'll set up your notes folder once your OneDrive copy has finished (the vault is in there).

When the copy window says it's done, open \"Bring My Stuff from Windows\" > \"Copy your OneDrive and notes\" again."
    return 0
  fi
  name=$(basename "$vault")
  name=$(wz_input "Found your notes vault: $vault

We copy it to a \"Vaults\" folder in your home, and share it with your phone through Syncthing (only over your home network). What should the folder be called?" "$name")
  [ -n "$name" ] || return 0
  res=$("$M" vault "$vault" "$name")
  dest=$(printf '%s\n' "$res" | tail -1)
  if printf '%s' "$res" | grep -q 'SYNCTHING: added'; then
    wz_info "Your notes are now in: $dest

Syncthing shares this folder. To get it on your phone:
  1. Install Syncthing on Android (\"Syncthing-Fork\" from F-Droid or the Play Store). iPhone: \"Möbius Sync\".
  2. In Syncthing on the laptop (app menu > Syncthing), click \"Add Remote Device\" and scan the phone's QR code (or the other way round).
  3. Share the \"$name (notes)\" folder with the phone, and accept it on the phone.
Then point Obsidian (or Joplin) on the phone at that folder."
  else
    wz_info "Your notes are now in: $dest

To share them with your phone, open Syncthing (app menu), click \"Add Folder\", choose this folder, and share it with your phone."
  fi
  case $(sl_choice_get notes_app) in
    obsidian|both) wz_info "In Obsidian, choose \"Open folder as vault\" and pick $dest." ;;
    *) wz_info "In Joplin: File > Import > \"MD - Markdown (Directory)\" and pick $dest." ;;
  esac
  wz_done comfort-notes
  return 0
}
