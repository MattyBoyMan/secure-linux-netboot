# shellcheck shell=bash
# Wizard page (Debian): the honest 32-bit browser note, shown once on 32-bit computers. Nothing to decide.
page_title() { echo "Web browsers on a 32-bit computer"; }
page_run() {
  wz_is_done browser32-plugin && return 0
  sl_is_i386 || return 0
  wz_info "Your computer has a 32-bit processor. Web browsers are dropping 32-bit Linux. Debian still provides Firefox ESR for it today, but that can stop before $(sl_support_end). When it does, the browser stops getting security fixes.

Until then it updates itself. After that, do banking and shopping on a newer device and use this computer for light jobs: email, documents, music, video."
  wz_done browser32-plugin
  return 0
}
