# shellcheck shell=bash
# Wizard page (comfort): care calendar - renewal dates, PLUS the offer to update the computer's
# built-in software (BIOS and device firmware). The firmware offer lives on this existing page on
# purpose: the wizard's question budget allows no new page (docs/run/question-audit-*.md). It has its
# own done-key (comfort-firmware), so it is asked even when the reminder dates were declined, and it
# runs `fwupdmgr refresh` then `fwupdmgr update` in a window where the progress can be watched.
# Reminders use `secure-linux-care add KEY YYYY-MM-DD` (system engineer) or write
# ~/.config/secure-linux/care-dates directly.
page_title() { echo "Reminders before things run out"; }
page_run() {
  . "$SL_ROOT/files/comfort/comfort-lib.sh"

  # ---- part 1: renewal reminders (unchanged flow; wrapped so its early returns end only this part)
  care_reminders() {
    wz_is_done comfort-care && return 0
    local a item key label d n=0 bad=""
    a=$(cf_ask3 "Want a reminder before your subscriptions renew or your card expires?

We'll ask for a few dates (leave any blank to skip). You get a friendly notice 60, 30 and 7 days before. Nothing is sent anywhere: the dates stay on this laptop." "Yes, add reminders")
    case $a in never) wz_done comfort-care; return 0 ;; later) return 0 ;; esac

    # date in YYYY-MM-DD, DD/MM/YYYY (Australian) or MM/YY (card expiry = end of that month)
    to_iso() {
      local v=${1// /}
      if [[ $v =~ ^([0-9]{4})-([0-9]{1,2})-([0-9]{1,2})$ ]]; then printf '%04d-%02d-%02d' "${BASH_REMATCH[1]}" "$((10#${BASH_REMATCH[2]}))" "$((10#${BASH_REMATCH[3]}))"
      elif [[ $v =~ ^([0-9]{1,2})/([0-9]{1,2})/([0-9]{4})$ ]]; then printf '%04d-%02d-%02d' "${BASH_REMATCH[3]}" "$((10#${BASH_REMATCH[2]}))" "$((10#${BASH_REMATCH[1]}))"
      elif [[ $v =~ ^([0-9]{1,2})/([0-9]{2})$ ]]; then date -d "20${BASH_REMATCH[2]}-$(printf '%02d' "$((10#${BASH_REMATCH[1]}))")-01 +1 month -1 day" +%F 2>/dev/null
      else return 1; fi
    }
    for item in "nordvpn-renewal|NordVPN renews" "cloudflare-renewal|Cloudflare subscription renews" \
                "bitwarden-premium|Bitwarden Premium renews" "domain-renewal|Your domain name renews" \
                "card-expiry|Your bank card expires (MM/YY is fine)"; do
      key=${item%%|*}; label=${item#*|}
      d=$(wz_input "$label on (for example 18/03/2027, or leave blank):")
      [ -n "$d" ] || continue
      d=$(to_iso "$d") && date -d "$d" +%F >/dev/null 2>&1 || { bad="$bad $label;"; continue; }
      if cf_have secure-linux-care; then secure-linux-care add "$key" "$d" >/dev/null 2>&1 || { bad="$bad $label;"; continue; }
      else
        mkdir -p "$HOME/.config/secure-linux"; touch "$HOME/.config/secure-linux/care-dates"
        sed -i "/^$key=/d" "$HOME/.config/secure-linux/care-dates"; echo "$key=$d" >> "$HOME/.config/secure-linux/care-dates"
      fi
      n=$((n + 1))
    done
    unset -f to_iso
    if [ -n "$bad" ]; then wz_info "Saved $n reminder(s). We couldn't read these dates:$bad add them later with: secure-linux-care add NAME YYYY-MM-DD"
    else wz_info "Saved $n reminder(s). See them any time with: secure-linux-care list"; fi
    wz_done comfort-care
    return 0
  }
  care_reminders

  # ---- part 2: the computer's built-in software (BIOS and device firmware)
  # This laptop sat unused for years; old built-in software is a common cause of sleep and Wi-Fi
  # trouble. Offered once, on this existing page, so the wizard stays within its question budget.
  wz_is_done comfort-firmware && return 0
  cf_have fwupdmgr || { wz_done comfort-firmware; return 0; }   # nothing to offer on this machine
  local fw_q fw_a
  fw_q="Update the computer's built-in software (BIOS and device firmware)?

This computer sat unused for a long time, so its built-in software is probably old. Old versions are a common cause of sleep and Wi-Fi trouble, and the update fixes known security holes too.

What to expect: the update comes from the computer maker, it can take 15 minutes or more, and it shows its progress the whole time. The charger must be plugged in, and the update must not be interrupted: do not close the window, turn the computer off, or unplug it while it works. It may ask you to restart at the end."
  # (line continuation keeps the long question readable; it is the page's one extra question)
  fw_a=$(cf_ask3 \
    "$fw_q" "Yes, update now")
  case $fw_a in
    never) wz_done comfort-firmware; return 0 ;;
    later) return 0 ;;
  esac
  # The charger really must be in: a firmware update on battery can leave the computer unstartable.
  if declare -F exp_on_ac >/dev/null 2>&1 && ! exp_on_ac; then
    # L5 (2026-11-04): this page runs once; "we will ask again next time you log in" was not true.
    wz_info "The charger is not plugged in, so let's not start this yet.

Plug the charger in first: this kind of update must never run on battery. Once it is plugged in, open Secure Linux Status and press Fix it on the firmware line (\"Update firmware (BIOS, SSD)\")."
    return 0
  fi
  cf_terminal sh -c '
    echo "Step 1 of 2: getting the newest list of updates..."
    echo
    fwupdmgr refresh
    echo
    echo "Step 2 of 2: installing the updates..."
    echo
    fwupdmgr update
    rc=$?
    echo
    if [ "$rc" -eq 0 ]; then
      echo "All done. The built-in software is up to date."
      echo "If you were asked to restart, save your work and restart when it suits you."
    else
      echo "That did not finish, and that is fine: nothing was harmed."
      echo "You can do it later from the Status window: open Secure Linux Status"
      echo "and choose \"Update firmware (BIOS, SSD)\"."
    fi'
  wz_done comfort-firmware
  wz_info "The built-in software update has run in its own window.

If something did not finish, no harm done: you can do it later from the Status window (Secure Linux Status > Fix it > Update firmware)."
  return 0
}
