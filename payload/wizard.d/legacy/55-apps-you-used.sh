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

_au_show_installed() {   # profile-specific mapping, generated from the same reviewed TSV as the scan
  local profile=$1 text=""
  [ "$profile" = atomic ] && profile=full
  if cf_have python3 && [ -r "$CF_APP_DB" ]; then
    text=$(python3 "$SL_ROOT/setup-data/app-scan.py" installed --database "$CF_APP_DB" --profile "$profile" 2>/dev/null)
  fi
  if [ -n "$text" ]; then
    wz_info "Good news: the stick already covers almost everything. You do not need to find replacements yourself.

Here is what the familiar Windows and Mac apps become on this computer. Nothing on this page is installed without asking.

$text"
  elif [ "$profile" = lite ]; then
    wz_info "Microsoft Office  ->  LibreOffice Writer and Calc (installed)
Chrome  ->  LibreWolf (installed)
The heavy creative apps are left off this older computer because they would crawl."
  else
    wz_info "Microsoft Office  ->  LibreOffice (installed)
Photoshop  ->  GIMP      Lightroom  ->  Darktable      Illustrator  ->  Inkscape
Premiere  ->  Kdenlive   OneNote  ->  Joplin           uTorrent  ->  qBittorrent
Chrome  ->  LibreWolf (installed)"
  fi
}

_au_find_record() {   # first apps-*.json on the Secure Linux stick (or a test/advanced override)
  local f u=${USER:-$(id -un)}
  if [ -n "${SL_APP_SCAN_FILE:-}" ] && [ -f "$SL_APP_SCAN_FILE" ]; then printf '%s\n' "$SL_APP_SCAN_FILE"; return 0; fi
  for f in ${SL_APP_SCAN_DIR:+"$SL_APP_SCAN_DIR"/apps-*.json} \
           "$CF_R/run/media/$u"/*/linux-setup/scan/apps-*.json "$CF_R/run/media/$u"/*/scan/apps-*.json \
           "$CF_R/run/media/$u"/*/*/linux-setup/scan/apps-*.json "$CF_R/run/media/$u"/*/*/scan/apps-*.json \
           "$CF_R/media/$u"/*/linux-setup/scan/apps-*.json "$CF_R/media/$u"/*/scan/apps-*.json \
           "$CF_R/mnt"/*/linux-setup/scan/apps-*.json "$CF_R/mnt"/*/scan/apps-*.json \
           "$HOME/linux-setup/scan"/apps-*.json "$HOME/scan"/apps-*.json; do
    [ -f "$f" ] && { printf '%s\n' "$f"; return 0; }
  done
  return 1
}

_au_id_installed() {   # do not recommend something an earlier wizard page already installed
  cf_have flatpak && flatpak info --system "$1" >/dev/null 2>&1 && return 0
  cf_have rpm && rpm -q "$1" >/dev/null 2>&1 && return 0
  return 1
}

_au_optional_scan() {
  local M=$SL_ROOT/bin/secure-linux-migrate profile=$1 a record report tmp later=0
  local tag id old what why compare ptype debpkg rest value previous item keep
  local covered examples gaps rec_text mode
  local -a available=() selected=() preserved=()
  a=$(wz_choice "Scan the apps you used before (optional)

Most people can SKIP this: the stick already covers almost everything. The scan is only for spotting a favourite old app that might be missing.

It reads app names and publishers from a small record made on your old Windows PC or Mac. It never reads documents or passwords." \
    "Yes, look for my old app list" "Skip this - the stick already covers almost everything" "Not now (ask me next time)")
  case $a in
    Yes,*) ;;
    "Not now"*) return 1 ;;
    *) return 0 ;;                         # skip, cancel or an empty scripted answer: no pressure
  esac

  record=$(_au_find_record) || record=""
  if [ -z "$record" ]; then
    wz_info "No app list was found, so nothing needs doing here.

To make one on the old computer:
  Windows: plug in the stick and double-click SAVE-APPS.cmd.
  Mac: run save-apps-mac.sh from the stick in Terminal.

It makes apps-COMPUTER.json in the stick's linux-setup/scan folder. Only app names and publishers are saved. Plug the stick in here and run this page again, or skip it: the stick already covers almost everything."
    a=$(wz_choice "Already made the JSON record somewhere else? Advanced users can type or paste its path." \
      "Type or paste an app-record path" "Skip the scan")
    case $a in
      Type*) record=$(wz_input "Where is the apps-COMPUTER.json file?" "/run/media/$USER/") ;;
      *) return 0 ;;
    esac
  else
    a=$(wz_choice "Found this app list:

$record

Use it, or choose another file?" "Use this app list" "Type or paste another path" "Skip the scan")
    case $a in
      Use*) ;;
      Type*) record=$(wz_input "Where is the apps-COMPUTER.json file?" "$record") ;;
      *) return 0 ;;
    esac
  fi
  if [ -z "$record" ] || [ ! -f "$record" ]; then
    wz_info "That app list could not be found. Nothing was installed. You can skip this safely or try again later."
    return 0
  fi
  [ "$profile" = atomic ] && profile=full
  tmp=$(mktemp -d); report=$tmp/report
  if ! python3 "$SL_ROOT/setup-data/app-scan.py" match --database "$CF_APP_DB" --record "$record" --profile "$profile" --format shell > "$report" 2>"$tmp/error"; then
    wz_info "That file is not a readable app list. Nothing was installed. You can make a fresh one with SAVE-APPS.cmd or save-apps-mac.sh, or skip this safely."
    rm -rf "$tmp"; return 0
  fi

  covered=0 examples="" gaps="" rec_text="" shown=0
  while IFS=$'\t' read -r tag id old what why compare ptype debpkg rest; do
    case $tag in
      SUMMARY) covered=$what ;;                 # fields: host, total, covered, recommendations, gaps, unknown
      COVERED)
        if [ "$shown" -lt 3 ]; then
          [ -n "$examples" ] && examples="$examples, "; examples="$examples$id"; shown=$((shown + 1))
        fi ;;
      GAP) gaps="$gaps
  $old: $what" ;;
      RECOMMEND)
        _au_id_installed "$id" && continue
        available+=("$id")
        rec_text="$rec_text

$what
  Replaces: $old
  Why this one: $why
  Compared with the old app: $compare" ;;
    esac
  done < "$report"
  [ ${#available[@]} -gt 0 ] || rec_text=""
  wz_info "Good news: $covered recognised apps are already covered.

A few examples: ${examples:-the everyday apps on your old computer}.

Nothing will be installed without your say-so.${gaps:+

Honest gaps - no good open equivalent is claimed for these:$gaps}${rec_text:+

Optional additions:$rec_text}"
  if [ ${#available[@]} -eq 0 ]; then rm -rf "$tmp"; return 0; fi

  mode=$(wz_choice "Which optional apps should be installed?

You can say yes or no to each one. Nothing is hidden in a bundle." \
    "Choose for each app (recommended)" "Install all of them" "Skip all of them")
  case $mode in
    Install*) selected=("${available[@]}") ;;
    Choose*)
      while IFS=$'\t' read -r tag id old what why compare ptype debpkg rest; do
        [ "$tag" = RECOMMEND ] || continue
        _au_id_installed "$id" && continue
        a=$(wz_choice "Add this app?

$what
Replaces: $old
Why this one: $why
Compared with the old app: $compare" "Yes, add it" "No, leave it out" "Ask me next time")
        case $a in
          Yes*) selected+=("$id") ;;
          Ask*) later=1 ;;
          *) ;;
        esac
      done < "$report" ;;
    *) ;;
  esac

  # Keep earlier extra choices that were not part of this scan. Unselected apps from THIS scan
  # are deliberately absent, so changing your mind and re-running cannot leave them installed by choice.
  previous=$(sl_choice_get extra_apps)
  for item in $previous; do
    [ "$item" = none ] && continue
    cf_extra_app_known "$item" || continue
    keep=yes
    for id in "${available[@]}"; do [ "$item" = "$id" ] && { keep=no; break; }; done
    [ "$keep" = yes ] && preserved+=("$item")
  done
  selected+=("${preserved[@]}")
  value=$(printf '%s\n' "${selected[@]}" | awk 'NF && !seen[$0]++' | paste -sd' ' -)
  [ -n "$value" ] || value=none
  if [ "$value" = none ]; then
    cf_save_choice extra_apps none
  else
    wz_info "Installing only the apps you picked. Your password is asked once; a failed app does not stop the others."
    wz_root "$M" install "extra_apps=$value" || wz_info "Some apps could not be installed just now. Your choices are saved, so Repair setup can try again."
  fi
  rm -rf "$tmp"
  [ "$later" = 0 ]
}

page_run() {
  . "$SL_ROOT/files/comfort/comfort-lib.sh"
  wz_is_done comfort-apps-used && return 0
  local M=$SL_ROOT/bin/secure-linux-migrate later=0 a profile
  profile=$(sl_profile)

  _au_show_installed "$profile"
  if [ "$profile" = lite ]; then
    wz_info "The short version: Microsoft Office  ->  LibreOffice Writer and Calc (installed).

The heavy creative apps are not on this older computer because they would crawl. The app store has lighter options later if you want one."
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

  # ------------------------------------------------------- optional old-app scan (skipping is complete)
  _au_optional_scan "$profile" || later=1
  [ "$later" = 0 ] && wz_done comfort-apps-used
  return 0
}
