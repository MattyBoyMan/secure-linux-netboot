# shellcheck shell=bash
# First page, before any choice: what the Secure Linux drive is, what it can and cannot do, which computers work and
# how a computer changes the result. Information only (no question, nothing stored); then the five question screens.
wizard_screen() {
  sl_wizard_show about
}
