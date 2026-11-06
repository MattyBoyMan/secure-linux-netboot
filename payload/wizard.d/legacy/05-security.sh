# shellcheck shell=bash
# Initial protection review. Reuse the Control Centre's Recommended / Stricter / Custom page:
# its safe protections are pre-ticked, every switch can be changed, and nothing applies before Confirm.
page_title() { echo "Choose your protection level"; }
page_run() {
  wz_is_done security-profile && return 0
  [ -x "$SL_ROOT/bin/secure-linux-control-center" ] || return 0
  wz_info "Next, review your computer's protection.

Recommended is already selected: everyday protections are pre-ticked. Stricter is optional and also offers your configured VPN and security audit log. Custom keeps your current settings.

You can untick any available protection. The next window lists every change before you press Confirm; closing it changes nothing. Turning something off is shown as a reduction in protection, never hidden."
  if [ -n "${SL_WIZARD_ANSWERS:-}" ]; then
    printf 'RUN: %s\n' "$SL_ROOT/bin/secure-linux-control-center"
  else
    "$SL_ROOT/bin/secure-linux-control-center"
  fi
  wz_done security-profile
  return 0
}
