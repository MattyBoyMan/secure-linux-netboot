# shellcheck shell=bash
# Wizard page (experience): "Join your home fleet?" Lets the household's main computer (the fleet
# laptop) look after this PC over the home network. DEFAULT IS TO STAND ALONE: "No thanks" (or just
# skipping the page) changes nothing and needs nothing else set up. Joining runs the
# secure-linux-fleet-join helper, which explains and confirms every step itself.
page_title() { echo "Join your home fleet?"; }
page_run() {
  . "$SL_ROOT/files/comfort/comfort-lib.sh"
  wz_is_done fleet && return 0
  [ "$(sl_choice_get fleet_enrolled no)" = yes ] && { wz_done fleet; return 0; }   # joined already: don't ask again
  local a
  a=$(cf_ask3 "Join your home fleet?

If your household has a main computer running Secure Linux (the laptop that was set up first), it can look after this PC over your home network: check that it's healthy, install its updates, and - only if you say yes to it there - see its screen to help you.

Everything stays on your home network: no cloud company is involved, and no internet is needed for the day-to-day checks.

If there is no main computer, or you're not sure, choose \"No thanks\": this PC works perfectly on its own, and you can join later any time (Secure Linux Toolbox, or run: secure-linux-fleet-join)." "Join my fleet")
  case $a in
    never) cf_save_choice fleet no; wz_done fleet; return 0 ;;
    later) return 0 ;;   # ask again next login; nothing saved, nothing changed
  esac

  cf_save_choice fleet yes
  cf_terminal "$SL_ROOT/bin/secure-linux-fleet-join"
  if [ "$(sl_choice_get fleet_enrolled no)" = yes ]; then
    wz_info "Done: this PC has joined your home fleet.

On the main computer, \"secure-linux-fleet status\" now shows this PC. To undo it later: delete the 'secure-linux-fleet' line in ~/.ssh/authorized_keys and the file /etc/ssh/sshd_config.d/40-secure-linux-fleet.conf on this PC, then run 'secure-linux-fleet remove' followed by this PC's name on the main computer."
  else
    cf_save_choice fleet no
    wz_info "No problem: the enrolment was not finished, so nothing was changed. You can join any time by running: secure-linux-fleet-join"
  fi
  wz_done fleet
  return 0
}
