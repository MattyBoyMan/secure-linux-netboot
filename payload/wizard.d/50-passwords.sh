# shellcheck shell=bash
# Wizard page (comfort): Google Password Manager -> Bitwarden, then clean up Google. The first question
# also offers KeePassXC for people who want no cloud at all (passwords in one encrypted file on this PC).
page_title() { echo "Move your passwords to Bitwarden"; }

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
  local a marker csv dl M=$SL_ROOT/bin/secure-linux-migrate
  a=$(wz_choice "Move your saved passwords from Google to a password manager?

On Windows, Chrome kept your passwords in Google Password Manager. Here, Bitwarden keeps them: it's encrypted so that only you can read your vault, it's open source, and it works in LibreWolf and on your phone.

Prefer no cloud at all? KeePassXC keeps your passwords in one encrypted file on this PC only - no account, no company - and it can load the same Google file.

Either way it takes about 5 minutes:
  1. Download your passwords from Google (one file).
  2. Load that file into the password manager.
  3. Delete the file, and remove the passwords from Google." \
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

  marker=$(mktemp); touch "$marker"
  wz_info "Step 2 of 4: download your passwords from Google.

Your browser now opens Google Password Manager's settings.
  1. Sign in to Google if asked.
  2. Click \"Export passwords\", then \"Export\" (Google asks for your Google password again).
  3. A file called \"Google Passwords.csv\" lands in your Downloads folder.

Click OK once it has downloaded. (We spot the file by ourselves.)"
  wz_open "https://passwords.google.com/options"
  csv=$("$M" wait-csv 180 "$marker")
  rm -f "$marker"
  if [ -z "$csv" ]; then
    dl=$(xdg-user-dir DOWNLOAD 2>/dev/null || echo "$HOME/Downloads")
    csv=$(wz_input "We couldn't see the file in Downloads yet. If it's somewhere else, type its full path here (or leave this empty to stop for now):" "$dl/Google Passwords.csv")
    [ -n "$csv" ] && [ -f "$csv" ] || { wz_info "No problem: we'll ask again next time. Nothing has changed."; return 0; }
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
    "$M" shred "$csv" >/dev/null 2>&1
    wz_info "Done: the passwords file has been deleted.

Plain truth: this laptop has an SSD, and SSDs can keep old copies of data in places no delete command can reach. That's fine here because the whole disk is encrypted: without your disk password nobody can read any of it, including leftovers.

Never email that file to yourself or put it on a USB stick."
  else
    wz_info "No worries. The file is still in your Downloads folder: $csv

Try the import again, or ask for help. Once your passwords are in Bitwarden, open \"Bring My Stuff from Windows\" > \"Move your passwords\" again and we'll delete the file safely.

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
