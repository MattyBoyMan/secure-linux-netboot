# shellcheck shell=bash
# Wizard page (comfort): "Apps you used before" - maps the apps people know from Windows or a Mac to the
# open apps already installed here, and closes the remaining gaps with a question each:
#   email       (every profile)  Thunderbird or Betterbird, choice email_client  - skipped when one is
#                                already installed (the Debian setup always has Thunderbird, for example)
#   backups     (lite only)      Deja Dup, choice backup_gui     (full has Pika Backup already)
#   disk space  (lite only)      Baobab, choice disk_usage       (full has Filelight already)
#   USB/disks   (lite only)      GNOME Disks, choice disk_utility (format/wipe sticks, drive health)
# Every question can be postponed; the page is only marked done once nothing is left open.
page_title() { echo "Apps you used before"; }

_au_email_installed() {
  if cf_have flatpak; then
    flatpak info --system org.mozilla.Thunderbird >/dev/null 2>&1 && return 0
    flatpak info --system eu.betterbird.Betterbird >/dev/null 2>&1 && return 0
  fi
  cf_have thunderbird && return 0
  cf_have rpm && rpm -q thunderbird >/dev/null 2>&1 && return 0
  return 1
}
_au_email_name() {   # which one we found (for the "already installed" note)
  if cf_have flatpak && flatpak info --system eu.betterbird.Betterbird >/dev/null 2>&1; then echo "Betterbird"; else echo "Thunderbird"; fi
}

page_run() {
  . "$SL_ROOT/files/comfort/comfort-lib.sh"
  wz_is_done comfort-apps-used && return 0
  local M=$SL_ROOT/bin/secure-linux-migrate later=0 a profile
  profile=$(sl_profile)

  if [ "$profile" = lite ]; then
    wz_info "Here is what replaces the apps you might have used before:

  Microsoft Office  ->  LibreOffice Writer and Calc (installed)
  Chrome  ->  LibreWolf (installed): your bookmarks and passwords pages can bring your things across
  iCloud / Apple Photos  ->  Syncthing (installed): folders shared between your own devices, home network only
  OneDrive  ->  the \"Bring my stuff from Windows\" helper copies your files across once

The heavy creative apps (Photoshop-style editing and so on) are not on this computer: it is an older machine and they would crawl. The app store (GNOME Software) has lighter options any time you want one."
  else
    wz_info "Here is what replaces the apps you might have used before:

  Microsoft Office  ->  LibreOffice (installed; the Office page can add OnlyOffice, which looks even closer)
  Photoshop  ->  GIMP      Lightroom  ->  Darktable      Illustrator  ->  Inkscape
  Premiere  ->  Kdenlive   OneNote  ->  Joplin           uTorrent  ->  qBittorrent
  Chrome  ->  LibreWolf (installed, with your bookmarks and passwords brought across by the other pages)
  iCloud / Apple Photos  ->  Syncthing between your own devices, and Immich if you have the home server

All of those are already installed. Email is the one gap: that is the next question."
  fi

  # ---------------------------------------------------------------- email (the real gap)
  if _au_email_installed; then
    wz_info "Email is taken care of: $(_au_email_name) is already installed. Add your accounts in it once and it works like Outlook did."
  else
    a=$(wz_choice "Which email app would you like?

Both do email, calendars and contacts, and both can sign in to Gmail, Outlook.com, iCloud and everything in between. Your email password is typed into the app once; it never leaves this computer.

  Thunderbird: the classic, from Mozilla (who make Firefox).
  Betterbird: Thunderbird with extra fixes and small comforts, looked after by people from the Thunderbird community.

Fully encrypted email (the extra-private option): Tuta is the free encrypted service with its own app, already installed on full-power PCs. Proton Mail is just as respected; its free tier works in the browser at proton.me — its desktop app and its Thunderbird bridge need a paid plan, so free Proton + Thunderbird is not possible.

Webmail in the browser also works fine if you pick no app." \
      "Thunderbird (the classic)" "Betterbird (Thunderbird with extra fixes)" "Not now (ask me next time)" "No email app thanks")
    case "$a" in
      Thunderbird*) wz_root "$M" install email_client=thunderbird
                    wz_info "Thunderbird is installed. Open it from the app menu and add your email account; it walks you through." ;;
      Betterbird*)  wz_root "$M" install email_client=betterbird
                    wz_info "Betterbird is installed. Open it from the app menu and add your email account; it walks you through." ;;
      "No email app thanks") cf_save_choice email_client none ;;
      *) later=1 ;;
    esac
  fi

  # ---------------------------------------------------------------- lite-only extras (full has them already)
  if [ "$profile" = lite ]; then
    a=$(cf_ask3 "Backups: add the simple Backups app (Deja Dup)?

It makes automatic copies of your files to a USB drive, or to another computer at home over SSH. Nothing is sent to a company.

(The newer-laptop setup uses a different backup app; this one gets Deja Dup because it is much lighter.)" "Yes, add Backups")
    case $a in
      yes) wz_root "$M" install backup_gui=deja-dup
           wz_info "Backups (Deja Dup) is installed. Open it, choose a USB drive or a folder on another computer, and switch on the schedule. It never suggests an online account; your copies stay yours." ;;
      never) cf_save_choice backup_gui none ;;
      *) later=1 ;;
    esac

    a=$(cf_ask3 "Add Baobab, the picture of what is filling the disk?

It shows your folders as rings, biggest first, so you can see at a glance where the room went and what is safe to delete." "Yes, add Baobab")
    case $a in
      yes) wz_root "$M" install disk_usage=baobab ;;
      never) cf_save_choice disk_usage none ;;
      *) later=1 ;;
    esac

    a=$(cf_ask3 "Add the Disks app?

It formats or wipes USB sticks and shows each drive's health, with buttons instead of commands." "Yes, add Disks")
    case $a in
      yes) wz_root "$M" install disk_utility=gnome-disks ;;
      never) cf_save_choice disk_utility none ;;
      *) later=1 ;;
    esac
  fi

  [ "$later" = 0 ] && wz_done comfort-apps-used
  return 0
}
