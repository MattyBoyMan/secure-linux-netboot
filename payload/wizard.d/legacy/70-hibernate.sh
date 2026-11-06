# shellcheck shell=bash
# Wizard page (comfort): hibernation and its Secure Boot trade-off. The work is done by the system
# engineer's secure-linux-hibernate (enable on-lid|sleep-then-hibernate / disable); it saves choice hibernate.
# The page follows choice secureboot_intent (on|off, asked by the installer): it tells the user what was
# already decided there and only asks if they want something different.
page_title() { echo "Sleep or hibernate"; }
page_run() {
  . "$SL_ROOT/files/comfort/comfort-lib.sh"
  wz_is_done comfort-hibernate && return 0
  [ "$(sl_profile)" = full ] || return 0
  cf_have secure-linux-hibernate || return 0
  local a sb="" intent now H=secure-linux-hibernate intro=""
  intent=$(sl_choice_get secureboot_intent)
  now=$($H wanted 2>/dev/null)
  if mokutil --sb-state 2>/dev/null | grep -qi 'SecureBoot enabled'; then sb=on; fi
  case $intent in
    off) intro="When you installed, you chose to switch Secure Boot OFF, so closing the lid hibernates (this is already set up$([ "$sb" = on ] && echo ' as soon as Secure Boot is switched off in the BIOS'))."
         [ "$now" = on-lid ] || [ "$now" = sleep-then-hibernate ] || intro="When you installed, you chose to switch Secure Boot OFF, which allows hibernation." ;;
    on)  intro="When you installed, you chose to keep Secure Boot ON, so closing the lid puts the laptop to sleep. Hibernation is possible only if you switch Secure Boot off, so think about it before changing this." ;;
  esac
  a=$(wz_choice "What should happen when you close the lid?${intro:+

$intro}

  - Sleep (now): wakes instantly, but slowly uses battery (a few % per hour), and the disk stays unlocked in memory.
  - Hibernate: saves everything to the encrypted disk and switches fully off. Uses no battery, and the disk password is needed to wake up. Waking takes about 20 seconds.
  - Sleep, then hibernate after 30 minutes: quick for short breaks, safe for long ones.

The catch: Fedora only allows hibernation when Secure Boot is switched OFF (with it on, the system refuses, to stop anyone tampering with the saved memory). Switching Secure Boot off keeps your disk fully encrypted; you lose protection against someone secretly changing the laptop's start-up files while it's out of your hands. At home that's a small risk; when travelling it matters more.$([ "$sb" = on ] && printf '\n\nSecure Boot is ON on this laptop right now: choosing hibernate shows you how to switch it off (one BIOS setting).')" \
    "Just sleep (keep Secure Boot on)" "Hibernate when I close the lid" "Sleep, then hibernate after 30 minutes")
  case $a in
    Just*)
      cf_save_choice hibernate no
      "$H" active >/dev/null 2>&1 && cf_terminal "$H" disable ;;
    Hibernate*) cf_terminal "$H" enable on-lid ;;
    Sleep*)     cf_terminal "$H" enable sleep-then-hibernate ;;
    *) return 0 ;;
  esac
  wz_done comfort-hibernate
  return 0
}
