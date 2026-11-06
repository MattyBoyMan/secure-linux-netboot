# shellcheck shell=bash
# Wizard page (homeassistant): tell the laptop where your Home Assistant lives, and (optionally) check how safe it is.
# Never asks for, or saves, a password or token (tokens have their own private-file command: secure-linux-ha token-set).
page_title() { echo "Home Assistant (smart home)"; }
page_run() {
  . "$SL_ROOT/files/homeassistant/ha-lib.sh"
  wz_is_done ha-wizard && return 0
  local have url found a mode val C=$SL_ROOT/bin/secure-linux-choice H=$SL_ROOT/bin
  wz_info "Home Assistant: the brain of a smart home

Home Assistant is free, private software that joins your lights, plugs, sensors and cameras (all brands) into one place and lets you make them work together, with no cloud company watching.

It runs on a small always-on computer at home, a home server (like the one running Immich). This laptop gets a \"Home Assistant\" window in the app menu, and your phone gets the Home Assistant app.

Skip this page if you're not into smart-home gadgets: nothing is installed that you have to use."

  have=$(wz_choice "Do you have a Home Assistant server?" \
    "Yes, it's already running" \
    "Not yet, but I'd like to set one up" \
    "Not now (ask me next time)" \
    "No thanks (don't ask again)")
  case $have in
    "Yes, it's already running") ;;
    "Not yet, but I'd like to set one up")
      wz_info "Great. Two ways, in plain terms:

  A) A small dedicated computer running Home Assistant OS (about A\$120 to A\$300). RECOMMENDED: easiest, updates and backups are one click.
  B) The home server you already have, running Home Assistant as a container. No new hardware, but more DIY (our kit does most of it).

The guide \"secure-linux-ha-setup\" walks you through either one, one step at a time, and asks before it does anything."
      if wz_yesno "Start the guided set-up now? (it opens in a window)"; then
        if command -v secure-linux-terminal >/dev/null 2>&1; then secure-linux-terminal "$H/secure-linux-ha-setup"; else "$H/secure-linux-ha-setup"; fi
      fi
      wz_done ha-wizard
      return 0 ;;
    "No thanks (don't ask again)") wz_root "$C" set ha_have_server no; wz_done ha-wizard; return 0 ;;
    *) return 0 ;;
  esac

  # They have one: find or type the address
  url=""
  if wz_yesno "Shall I look for it on your home network? (Home Assistant usually answers to homeassistant.local)"; then
    found=$(ha_discover)
    if [ -n "$found" ]; then
      wz_yesno "Found Home Assistant at $found. Use that address?" && url=$found
    else
      wz_info "I couldn't find it by name. That's common: some routers hide .local names. Type its address yourself next (look in your router's device list, or on the server)."
    fi
  fi
  if [ -z "$url" ]; then
    url=$(wz_input "Type your Home Assistant address, for example http://10.0.30.50:8123 or https://ha.home" "${HA_URL_DEFAULT}")
    url=$(printf '%s' "$url" | tr -d '[:space:]')
  fi
  if [ -z "$url" ] || ! ha_valid_url "$url"; then
    wz_info "That doesn't look like a web address (it should start with http:// or https://). We'll ask again next time."
    return 0
  fi
  wz_root "$C" set ha_url "$url"
  wz_root "$C" set ha_have_server yes
  wz_info "Saved. \"Home Assistant\" in your app menu now opens $url."

  # Practice copy on this laptop (off unless asked)
  if [ "$(sl_profile)" != lite ]; then
    if wz_yesno "Want a private PRACTICE copy of Home Assistant on this laptop too?

It's separate from your real one, reachable only from this laptop, switched off until you start it, and downloads about 1.5 GB the first time you start it. Perfect for trying automations safely."; then
      wz_root "$C" set ha_local yes
      wz_info "Done. After the next setup repair it's ready; start it any time with:  secure-linux-ha local start"
    else
      wz_root "$C" set ha_local no
    fi
  fi

  # How will they reach it from away?
  a=$(wz_choice "When you're away from home, how will you reach Home Assistant?" \
    "NordVPN Meshnet (best for you: you already pay for it)" \
    "Cloudflare Tunnel with a login rule" \
    "Nabu Casa (paid, simplest, funds Home Assistant)" \
    "I only use it at home" \
    "Not sure yet")
  mode=""
  case $a in
    NordVPN*) mode=meshnet ;; Cloudflare*) mode=cloudflare ;; Nabu*) mode=nabucasa ;; "I only"*) mode=none ;;
  esac
  case $mode in
    nabucasa) wz_info "Nabu Casa in plain terms: about US\$6.50 a month. Pros: very simple, works with Alexa and Google, and your money pays Home Assistant's developers. Cons: a monthly cost, and your connection passes through their servers (encrypted)." ;;
    meshnet) wz_info "Good choice. Meshnet links your phone and server privately, so nothing is opened on your router. The guide chapter \"Reach it from anywhere\" shows the 10-minute set-up. NEVER forward a port on your router for Home Assistant." ;;
    cloudflare) wz_info "Cloudflare Tunnel hides your server behind Cloudflare and Zero Trust Access puts a login (your email plus a code) in front of it. Free for a few users. The server kit explains the set-up. NEVER forward a port on your router for Home Assistant." ;;
    "") wz_info "No problem. Until you decide: never forward a port on your router for Home Assistant. Use it at home, or switch on Meshnet." ;;
  esac
  if [ -n "$mode" ]; then
    wz_root "$C" set ha_remote_mode "$mode"
    "$H/secure-linux-ha-secure" attest remote_mode "$mode" >/dev/null 2>&1
  fi

  if wz_yesno "Run the security check now? It gives your Home Assistant a grade from A to F with plain-English fixes. It only looks; it changes nothing."; then
    if command -v secure-linux-terminal >/dev/null 2>&1; then secure-linux-terminal --hold "$H/secure-linux-ha-secure" --guided; else "$H/secure-linux-ha-secure" --guided; fi
  fi
  wz_info "All set. Handy later:
  - Open it: \"Home Assistant\" in the app menu
  - Lessons: \"Home Assistant: Learn the Basics\"
  - Security check any time: secure-linux-ha-secure --guided
  - Ready-made automations: secure-linux-ha starter list"
  wz_done ha-wizard
  return 0
}
