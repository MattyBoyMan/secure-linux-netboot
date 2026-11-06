# shellcheck shell=bash
# Wizard page (comfort): Word/Excel/PowerPoint files - LibreOffice (installed), optional OnlyOffice, and
# Microsoft 365 on the web as an app-menu entry. The look-alike fonts are installed by step 45.
page_title() { echo "Word, Excel and PowerPoint files"; }
page_run() {
  . "$SL_ROOT/files/comfort/comfort-lib.sh"
  wz_is_done comfort-office && return 0
  local a M=$SL_ROOT/bin/secure-linux-migrate apps=$HOME/.local/share/applications lite_note="" lite=""
  if [ "$(sl_profile)" = lite ]; then
    lite=1
    lite_note="

(OnlyOffice is a big program, so it isn't offered on older computers. Microsoft 365 on the web works well there.)"
  fi
  a=$(wz_choice "Your Office documents open in LibreOffice, which is already installed.

We've also added free fonts that are exact stand-ins for Calibri and Cambria, so pages break in the same places. (Aptos, the newest Office font, has no exact twin: we use Carlito, which looks very close but lines can wrap slightly differently.)

Want something that looks even more like Word?
  - OnlyOffice: looks and lays out documents very much like Microsoft Office. Good for assignments you'll hand in as .docx.
  - Microsoft 365 on the web: the real Word/Excel/PowerPoint in a browser window (needs your Microsoft account and internet).
You can have both.$lite_note" \
    "LibreOffice is enough" "Add OnlyOffice" "Add Microsoft 365 (web)" "Add both")
  if [ -n "$lite" ]; then
    case $a in "Add OnlyOffice"|"Add both") a="Add Microsoft 365 (web)" ;; esac
  fi
  case $a in
    "Add OnlyOffice"|"Add both") wz_root "$M" install office=onlyoffice ;;
    "LibreOffice is enough") cf_save_choice office libreoffice ;;
    "") return 0 ;;
  esac
  case $a in
    "Add Microsoft 365 (web)"|"Add both")
      # An app window without browser bars (Chromium app mode if present, else a LibreWolf window)
      mkdir -p "$apps"
      cf_webapp_entry "Microsoft 365 (web)" "Word, Excel and PowerPoint online, in their own window" https://www.office.com \
        x-office-document "Office;" "word;excel;powerpoint;office;365;outlook;" > "$apps/secure-linux-web-microsoft365.desktop"
      wz_info "\"Microsoft 365 (web)\" is now in your app menu. Sign in with your Microsoft account the first time." ;;
  esac
  wz_done comfort-office
  return 0
}
