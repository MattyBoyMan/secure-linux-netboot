# shellcheck shell=bash
# Wizard page (comfort): Google Password Manager -> Bitwarden, then clean up Google. The first question
# also offers KeePassXC for people who want no cloud at all (passwords in one encrypted file on this PC).
page_title() { echo "Move your passwords to Bitwarden"; }

_pw_valid_csv() {
  python3 - "$1" <<'PY'
import csv, sys
try:
    with open(sys.argv[1], encoding="utf-8-sig", newline="") as handle:
        header = next(csv.reader(handle))
    names = {name.strip().lower() for name in header}
    valid = "password" in names and bool(names & {"username", "login", "login_username", "user"})
except (OSError, StopIteration, csv.Error, UnicodeError):
    valid = False
sys.exit(0 if valid else 1)
PY
}

# KeePassXC: the no-cloud path. Installs it (choice keepassxc=yes) and shows how to load the same Google file.
_pw_keepassxc() {
  local M=$SL_ROOT/bin/secure-linux-migrate
  wz_root "$M" install keepassxc=yes
  wz_info "KeePassXC is installed: your passwords live in one encrypted file on this PC, and nowhere else.

To move your Google passwords across (about 5 minutes):
  1. The Google Password Manager settings open now: sign in, click \"Export passwords\", then \"Export\". A file called \"Google Passwords.csv\" lands in Downloads.
  2. Open KeePassXC, choose \"New database\" and give it a master password you will never forget (a short sentence works well). KeePassXC can NOT reset it for you. Keep the vault file it creates in your Documents folder.
  3. In KeePassXC: Database > Import, format \"Chrome (csv)\" (Google's export uses Chrome's format), and pick the file from Downloads.
  4. Delete the CSV from Downloads afterwards (it holds every password in plain text) and empty the Bin. The \"Move your passwords\" page can delete it safely for you next time, with the honest note about SSDs.

One honest trade-off: with no cloud, nothing syncs by itself. Syncthing (installed) can share the KeePassXC file with your other computers on the home network if you ever want that."
  wz_open "https://passwords.google.com/options"
  wz_done comfort-passwords
  return 0
}

page_run() {
  . "$SL_ROOT/files/comfort/comfort-lib.sh"
  wz_is_done comfort-passwords && return 0
  local a csv dl M=$SL_ROOT/bin/secure-linux-migrate
  a=$(wz_choice "Move your saved browser passwords to a password manager?

Already used the USB's 'Save my passwords and Wi-Fi only' tool? Plug that USB in: this page finds the export automatically, checks its format, and skips the old-browser export step.

Bitwarden keeps your passwords encrypted so only you can read your vault. It is open source and works in LibreWolf and on your phone. Your Bitwarden sign-in or unlock is always required; this page never uploads passwords by itself.

Prefer no cloud at all? KeePassXC keeps your passwords in one encrypted file on this PC only and can load the same Chrome or Edge file.

The guided route:
  1. Find your existing export, or help you export once.
  2. You load that file into the password manager and confirm it worked.
  3. The page deletes the readable CSV. Removing Google's old copy remains a separate, optional step." \
    "Yes, move my passwords (Bitwarden)" "Not now (ask me next time)" "No thanks" "KeePassXC instead (no cloud, a file only on this PC)")
  case $a in
    "No thanks") wz_done comfort-passwords; return 0 ;;
    "KeePassXC"*) _pw_keepassxc; return 0 ;;
    "Yes, move my passwords (Bitwarden)") ;;   # the Bitwarden path continues below
    *) return 0 ;;                             # Not now / window closed: ask again next time
  esac

  wz_info "Step 1 of 4: open Bitwarden and sign in.

Bitwarden opens now. If you don't have a Bitwarden account yet, click \"Create account\". Pick a long master password you will never forget (a short sentence works well). Bitwarden can NOT reset it for you.

Leave Bitwarden open and click OK here."
  flatpak run com.bitwarden.desktop >/dev/null 2>&1 &

  dl=$(xdg-user-dir DOWNLOAD 2>/dev/null || echo "$HOME/Downloads")
  # Reuse the explicit Windows browser export first. Discovery never reads or uploads credentials;
  # the header-only check below merely rejects files that are not browser password exports.
  local candidate
  csv=
  for candidate in "$dl"/*.csv "$HOME/linux-setup/scan"/*.csv "$HOME/scan"/*.csv \
                   /run/media/"$USER"/*/linux-setup/scan/*/*.csv /run/media/"$USER"/*/linux-setup/scan/*.csv \
                   /run/media/"$USER"/*/scan/*.csv; do
    [ -f "$candidate" ] || continue
    _pw_valid_csv "$candidate" || continue
    csv=$candidate
    break
  done
  if [ -n "$csv" ]; then
    wz_info "Step 2 of 4: found your exported password file.

Found automatically: $csv

You do not need to export it again. Nothing has been uploaded. The app will check only the CSV header, then show you exactly how to import it into Bitwarden."
  else
    wz_info "Step 2 of 4: export your passwords once.

If you used the USB's 'Save my passwords and Wi-Fi only' tool, plug that USB in and run this page again: it will find the file for you.

Otherwise your browser opens Google Password Manager's settings:
  1. Sign in to Google if asked.
  2. Click \"Export passwords\", then \"Export\" (Google asks for your Google password again).
  3. A file called \"Google Passwords.csv\" lands in Downloads.

Click OK once it has downloaded, then choose that file in the next window."
    wz_open "https://passwords.google.com/options"
  fi
  # Native sessions get a cancellable picker instead of an invisible polling wait.
  # Scripted and specialist harnesses keep the established wz_input contract.
  local native_picker=0
  if [ -z "$csv" ] && declare -F _ui_tool >/dev/null && [ -z "${SL_WIZARD_ANSWERS:-}" ]; then
    case $(_ui_tool) in
      kdialog) csv=$(kdialog --title "Choose the exported password CSV" --getopenfilename "$dl" '*.csv'); native_picker=1 ;;
      zenity) csv=$(zenity --file-selection --title="Choose the exported password CSV" --filename="$dl/Google Passwords.csv" \
                       --file-filter='Password CSV files | *.csv' --file-filter='All files | *'); native_picker=1 ;;
    esac
  fi
  if [ -z "$csv" ] && [ "$native_picker" -eq 0 ]; then
    csv=$(wz_input "Type the exported CSV path (or leave empty to stop for now):" "$dl/Google Passwords.csv")
  fi
  [ -n "$csv" ] && [ -f "$csv" ] || { wz_info "No problem: we'll ask again next time. Nothing has changed."; return 0; }
  if ! _pw_valid_csv "$csv"; then
    wz_info "That file is not a recognised Chrome, Edge or Google password CSV. Nothing was imported or deleted. Choose the browser's Export passwords file instead."
    return 1
  fi

  wz_info "Step 3 of 4: load the file into Bitwarden.

Found it: $csv

In the Bitwarden app:
  1. Menu \"File\" > \"Import data\".
  2. Vault: \"My vault\". Folder: leave empty.
  3. File format: \"Chrome (csv)\" (Google's export uses Chrome's format).
  4. Click \"Select file\" (or \"Choose file\") and pick the file above, then \"Import data\".

You can also do this in the web vault (vault.bitwarden.com > Tools > Import data), same choices.

Click OK when the import has finished."
  if wz_yesno "Do your passwords show in Bitwarden now?

Scroll through \"My vault\": you should see your websites listed."; then
    if "$M" shred "$csv" >/dev/null 2>&1 && [ ! -e "$csv" ]; then
      wz_info "Done: the passwords file has been deleted.

Plain truth: this laptop has an SSD, and SSDs can keep old copies of data in places no delete command can reach. Whole-disk encryption protects those leftovers when the computer is off; it does not prove that overwritten blocks are physically erased.

Never email that file or copy it to shared cloud storage. If it came from the USB, keep that USB private until the verified import and deletion finish."
    else
      wz_info "The import finished, but the passwords file could NOT be deleted: $csv

Nothing is marked complete. Please close programs using the file, then choose 'Move your passwords' and try deletion again. Until then, the file still holds your passwords in plain text."
      return 1
    fi
  else
    wz_info "No worries. The readable password file is still here: $csv

Nothing was uploaded or deleted. Try the import again, or ask for help. Once your passwords are in Bitwarden, open Setup Hub > \"Move My Passwords from Chrome or Edge\" again and we'll find the same file and delete it after you confirm the import.

Please don't leave that file lying around: it holds all your passwords in plain text."
    return 0
  fi

  wz_info "Step 4 of 4: tidy up Google.

Your passwords are safe in Bitwarden, so Google doesn't need its copy. The Google Password Manager settings open now:
  1. Switch OFF \"Offer to save passwords\" (and \"Sign in automatically\").
  2. Near the bottom, choose \"Delete all Google Password Manager data\" and confirm.

On your Android phone: Settings > Passwords & accounts (or Google > Autofill) > Autofill service: choose Bitwarden, and turn off Google's password saving there too.

Install the Bitwarden extension in LibreWolf (addons.mozilla.org, search \"Bitwarden\") so it can fill in passwords for you."
  wz_open "https://passwords.google.com/options"
  wz_done comfort-passwords
  return 0
}
