# shellcheck shell=bash
# Wizard page (comfort): find the printer/scanner (driverless IPP Everywhere / AirPrint / eSCL).
page_title() { echo "Find my printer"; }
page_run() {
  . "$SL_ROOT/files/comfort/comfort-lib.sh"
  wz_is_done comfort-printer && return 0
  local a scan
  a=$(cf_ask3 "Set up your printer now?

Most printers made in the last 10 years work without installing anything (\"driverless\" printing, the same thing iPhones use). HP printers also get HP's own driver, already installed.

Before you start: switch the printer on and make sure it's on the same Wi-Fi as this laptop (or plug in its USB cable). Tip: at home, the firewall lets the laptop see printers; on other networks it stays hidden on purpose." "Yes, find my printer")
  case $a in never) wz_done comfort-printer; return 0 ;; later) return 0 ;; esac
  if [ "$(cf_desktop)" = kde ]; then
    scan=Skanpage
    wz_info "The Printers settings open now.
  1. Click \"Add Printer\" (or \"Add\").
  2. Your printer should be listed under \"Network printers\" (look for \"IPP Everywhere\" or \"driverless\" in its name). Pick it and click Next/Finish.
  3. Print a test page.
Not listed? Type the printer's IP address (shown on the printer's screen or its network report) as: ipp://192.168.x.x/ipp/print
Scanning: open \"$scan\": it finds network scanners by itself."
    if cf_have kcmshell6; then kcmshell6 kcm_printer_manager >/dev/null 2>&1 &
    else systemsettings kcm_printer_manager >/dev/null 2>&1 & fi
  else
    scan="Document Scanner"
    wz_info "The Printers window opens now.
  1. Click \"+ Add\".
  2. Open \"Network Printer\": your printer should be listed (pick the \"driverless\" or \"IPP Everywhere\" entry when offered). Click Forward, then Apply.
  3. Print a test page.
Not listed? Use \"Enter URI\" with: ipp://192.168.x.x/ipp/print (the printer's IP address).
Scanning: open \"$scan\" (Simple Scan): it finds network scanners by itself."
    system-config-printer >/dev/null 2>&1 &
  fi
  wz_done comfort-printer
  return 0
}
