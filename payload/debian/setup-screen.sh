#!/bin/sh
# Secure Linux (Debian fallback): the beginner's setup screen of the DEBIAN installer.
# POSIX sh only: it runs in the Debian installer (busybox ash), which has no bash, no python, no lsblk.
#
#   sh setup-screen.sh start    from preseed/early_command: this computer, warnings, computer name, saved Wi-Fi
#   sh setup-screen.sh disk     from partman/early_command: which drive, backup check, ERASE, disk passphrase
#
# Every question waits for the person. Nothing times out. Cancelling restarts the computer and changes nothing.
# The passphrase is kept in memory only (handed to the installer with debconf-set): never written to the USB.
#
# Look and feel: the installer console is text-only, so this screen uses the boxed-panel style from
# docs/notes/ux-style-guide.md (plain ASCII only: the console cannot show colour or box-drawing
# characters). Every screen is a calm bordered panel; every question sits under it, unchanged.
#
# Files it uses (all in $SL_DIR, default /sl, unpacked from the Ventoy injection archive):
#   compat-check-min.sh   the hardware check (linux/hw/compat-check-min.sh)
#   eff-words.txt         the EFF short word list, 1296 words, for generated passphrases
#   wifi-records.txt      (optional) Wi-Fi networks saved from Windows by save-wifi.ps1
#   backups.txt           (optional) which computers were backed up (same records as the Fedora screen)
# What it leaves for the rest of the install (late.sh) in $SL_ST (default /tmp/sl-screen):
#   choices, distro, wifi-selected, wifi-record
# Test switches: SL_SYS (prefix for /sys and /proc), SL_NOTTY=1 (use stdin/stdout), SL_COMPAT_FIXTURE, SL_ARCH,
# SL_CANCEL_WAIT, SL_PAUSE, SL_DEBCONF_SET, SL_URANDOM.

LC_ALL=C; export LC_ALL
PHASE=${1:-start}
SYS=${SL_SYS:-}
DIR=${SL_DIR:-/sl}
ST=${SL_ST:-/tmp/sl-screen}
DS=${SL_DEBCONF_SET:-debconf-set}
URANDOM=${SL_URANDOM:-/dev/urandom}
umask 077
mkdir -p "$ST"

# ---------------------------------------------------------------- the screen (console 2 of the installer)
if [ -z "${SL_NOTTY:-}" ]; then
  TTY=${SL_TTY:-/dev/tty2}
  # No usable console: don't guess. The installer then asks its own questions (and confirms before erasing).
  [ -c "$TTY" ] || exit 0
  exec <"$TTY" >"$TTY" 2>&1
  chvt "${TTY#/dev/tty}" 2>/dev/null
fi

# ---------------------------------------------------------------- screen furniture (boxed panels, plain ASCII)
# A fixed 76-column panel: border line "+----...----+", content lines "|  text  |". Over-long dynamic
# text (a drive model name, a Wi-Fi name) is cut to fit rather than breaking the border.
clear_screen() { [ -n "${SL_NOTTY:-}" ] || printf '\033c'; }
rule() { echo "  +----------------------------------------------------------------------+"; }
row()  { printf '  |  %-70.70s|\n' "$1"; }
gap()  { row ""; }
header() {
  clear_screen
  echo "  +======================================================================+"
  printf '  |  %-70.70s|\n' "THE COMPLETE SECURE LINUX PACKAGE (Debian)"
  printf '  |  %-70.70s|\n' "$1"
  echo "  +======================================================================+"
  echo
}

cancel() {
  echo
  rule
  row "Cancelled. Nothing was changed."
  row "Remove the USB stick. This computer restarts in ${SL_CANCEL_WAIT:-15} seconds."
  rule
  sleep "${SL_CANCEL_WAIT:-15}"
  reboot -f
  exit 1
}
# Every choice needs an answer: Enter on its own just asks again
answer() {
  while true; do
    printf '  %s ' "$1"
    read -r REPLY_TEXT || cancel
    [ -n "$REPLY_TEXT" ] && return 0
  done
}
# Same, but Enter on its own accepts the suggestion in $2
answer_default() {
  printf '  %s [%s] ' "$1" "$2"
  read -r REPLY_TEXT || cancel
  [ -n "$REPLY_TEXT" ] || REPLY_TEXT=$2
}
secret() {   # secret "Prompt: "  -> REPLY_SECRET (not shown while typing)
  printf '  %s' "$1"
  stty -echo 2>/dev/null
  read -r REPLY_SECRET || { stty echo 2>/dev/null; cancel; }
  stty echo 2>/dev/null
  echo
}
junk_id() {   # firmware placeholders that are not real serial numbers / UUIDs
  s=$(printf '%s' "$1" | tr -cd 'A-Za-z0-9' | tr 'A-Z' 'a-z')
  case "$s" in ""|defaultstring|tobefilledbyoem|systemserialnumber|none|notapplicable|na|0123456789|123456789|chassisserialnumber|notspecified) return 0 ;; esac
  first=$(printf '%s' "$s" | cut -c1)
  [ -z "$(printf '%s' "$s" | tr -d "$first")" ] && return 0   # all the same character
  return 1
}
rd() { [ -r "$1" ] && head -n 1 "$1" 2>/dev/null | tr -d '\000'; }

# ---------------------------------------------------------------- this computer
VENDOR=$(rd "$SYS/sys/class/dmi/id/sys_vendor"); MODEL=$(rd "$SYS/sys/class/dmi/id/product_name")
SERIAL=$(rd "$SYS/sys/class/dmi/id/product_serial" | tr -d ' '); UUID=$(rd "$SYS/sys/class/dmi/id/product_uuid")
CPU=$(awk -F': *' '/^model name/{print $2; exit}' "$SYS/proc/cpuinfo" 2>/dev/null)
KB=$(awk '/^MemTotal:/{print $2; exit}' "$SYS/proc/meminfo" 2>/dev/null); KB=${KB:-0}
RAM_MB=$((KB / 1024))
RAM_TXT=$(awk -v m="$RAM_MB" 'BEGIN { printf "%.1f", m / 1024 }')
SID=$SERIAL; junk_id "$SID" && SID=""
UID_=$UUID;  junk_id "$UID_" && UID_=""

# ================================================================ phase "start"
if [ "$PHASE" = start ]; then

  # ---- hardware check (same rules as the Fedora screen; decides which Linux fits this computer)
  HW_STATUS=OK; HW_DISTRO=""; HW_REASON=""; HW_NEEDS_WIRED=0
  : > "$ST/hw-report.txt"
  if [ -f "$DIR/compat-check-min.sh" ]; then
    if [ -n "${SL_COMPAT_FIXTURE:-}" ]; then sh "$DIR/compat-check-min.sh" --fixture "$SL_COMPAT_FIXTURE" > "$ST/hw-raw.txt" 2>&1
    else sh "$DIR/compat-check-min.sh" > "$ST/hw-raw.txt" 2>&1; fi
    v=$(sed -n 's/^HW_STATUS=//p' "$ST/hw-raw.txt" | tail -n 1);        case "$v" in OK|NOTES|UNSUPPORTED) HW_STATUS=$v ;; esac
    v=$(sed -n 's/^HW_DISTRO=//p' "$ST/hw-raw.txt" | tail -n 1);        case "$v" in fedora|fedora-min|fedora-t2|asahi|debian-lite|debian-i386|unsupported) HW_DISTRO=$v ;; esac
    HW_REASON=$(sed -n 's/^HW_DISTRO_REASON=//p' "$ST/hw-raw.txt" | tail -n 1)
    v=$(sed -n 's/^HW_NEEDS_WIRED=//p' "$ST/hw-raw.txt" | tail -n 1);   case "$v" in 1) HW_NEEDS_WIRED=1 ;; esac
    grep -v '^HW_[A-Z_]*=' "$ST/hw-raw.txt" > "$ST/hw-report.txt"
  fi

  header "this computer"
  rule
  row "This computer:  $VENDOR $MODEL"
  row "Processor:      $CPU"
  row "Memory:         $RAM_TXT GB"
  rule
  echo
  [ -s "$ST/hw-report.txt" ] && { cat "$ST/hw-report.txt"; echo; }

  if [ "$HW_STATUS" = UNSUPPORTED ] || [ "$HW_DISTRO" = unsupported ] || [ "$HW_DISTRO" = asahi ]; then
    rule
    row "Sorry: this USB stick can't install Linux on this computer (see above)."
    rule
    cancel
  fi

  case "$HW_DISTRO" in
    fedora|fedora-t2)
      rule
      row "GOOD NEWS: this computer is strong enough for the main setup (Fedora)."
      gap
      row "You started the Debian entry, which is meant for older or smaller"
      row "computers. Debian works, but it has fewer apps and fewer protections"
      row "than the main setup."
      gap
      row "  Q = stop. Restart, and pick the 'SET UP THIS COMPUTER' (Fedora)"
      row "      entry in the USB menu"
      row "  D = go on with Debian anyway"
      rule
      echo
      while true; do
        answer "Type Q or D and press Enter:"
        case "$REPLY_TEXT" in [Qq]) cancel ;; [Dd]) break ;; esac
      done
      HW_DISTRO=debian-lite ;;
    fedora-min)
      rule
      row "GOOD NEWS: this computer can run the main setup (Fedora) with"
      row "its lightest desktop (LXQt)."
      gap
      row "You started the Debian entry, which is meant for computers that"
      row "can't run Fedora at all. This one can: its $RAM_TXT GB of memory is"
      row "enough for Fedora with the light desktop, which is the newer"
      row "system with more apps and more protections than Debian."
      gap
      row "  Q = stop. Restart, and pick the 'SET UP THIS COMPUTER' (Fedora)"
      row "      entry in the USB menu"
      row "  D = go on with Debian anyway"
      rule
      echo
      while true; do
        answer "Type Q or D and press Enter:"
        case "$REPLY_TEXT" in [Qq]) cancel ;; [Dd]) break ;; esac
      done
      HW_DISTRO=debian-lite ;;
  esac

  if [ -z "$HW_DISTRO" ]; then   # no hardware check on the stick: decide from the processor and memory
    if grep -q ' lm ' "$SYS/proc/cpuinfo" 2>/dev/null; then HW_DISTRO=debian-lite; else HW_DISTRO=debian-i386; fi
  fi
  # What THIS installer installs: the 32-bit installer (Debian 12) reports a 32-bit kernel
  ARCH=${SL_ARCH:-$(uname -m)}
  case "$ARCH" in i?86) INSTALLING=debian-i386 ;; *) INSTALLING=debian-lite ;; esac
  if [ "$INSTALLING" = debian-i386 ] && [ "$HW_DISTRO" = debian-lite ]; then
    rule
    row "This computer has a 64-bit processor, so it can run"
    row "the NEWER 64-bit Debian 13. You started the 32-bit entry"
    row "(Debian 12). 64-bit Debian 13 is supported for longer and"
    row "its web browser stays up to date for longer."
    gap
    row "  Q = stop. Restart, and pick the 64-bit Debian 13 entry in the USB menu"
    row "  D = go on with 32-bit Debian 12 anyway"
    rule
    echo
    while true; do
      answer "Type Q or D and press Enter:"
      case "$REPLY_TEXT" in [Qq]) cancel ;; [Dd]) break ;; esac
    done
  fi
  HW_DISTRO=$INSTALLING

  if [ "$HW_DISTRO" = debian-i386 ]; then
    header "32-bit computer: please read"
    rule
    row "This computer has an older, 32-BIT-only processor. The newest Debian"
    row "no longer comes in a 32-bit version, so this computer gets Debian 12"
    row "(the previous version)."
    gap
    row "What that means, honestly:"
    gap
    row "  + Debian 12 gets security updates until 30 June 2028"
    row "    (the Debian LTS team)."
    row "  + It runs well on old, slow PCs, with a light desktop (Xfce)."
    row "  - WEB BROWSERS ARE DROPPING 32-BIT. Debian still provides"
    row "    Firefox ESR for 32-bit today, but that can stop before 2028."
    row "    When it does, the browser (the part that meets the internet)"
    row "    no longer gets security fixes: the biggest risk on this PC."
    row "  - Some newer apps and websites will not run. There is no Flatpak"
    row "    (Flathub) for 32-bit."
    row "  - This computer will be best for light jobs: email, documents,"
    row "    music, video. Do banking and shopping on a newer device once"
    row "    browser updates stop."
    gap
    row "Another option for very old computers is antiX Linux"
    row "(antixlinux.com). It is offered here as an idea only: this USB"
    row "stick does not install it for you."
    rule
    echo
    while true; do
      answer "Type C to continue with Debian 12, or Q to stop:"
      case "$REPLY_TEXT" in [Cc]) break ;; [Qq]) cancel ;; esac
    done
  elif [ "$HW_STATUS" = NOTES ] || [ "$HW_NEEDS_WIRED" = 1 ]; then
    if [ "$HW_NEEDS_WIRED" = 1 ]; then
      rule
      row "This computer's Wi-Fi chip needs a driver that the installer may"
      row "not have: use a network cable (or phone USB tethering) for the install."
      rule
      echo
    fi
    while true; do
      answer "Type C to continue (Q to cancel):"
      case "$REPLY_TEXT" in [Cc]) break ;; [Qq]) cancel ;; esac
    done
  fi
  echo "$HW_DISTRO" > "$ST/distro"
  : > "$ST/choices"

  # ---- desktop: Xfce, or the even lighter LXQt below about 900 MB of memory
  DESKTOP=xfce
  TASK="standard, xfce-desktop"
  if [ "$RAM_MB" -gt 0 ] && [ "$RAM_MB" -lt 900 ]; then DESKTOP=lxqt; TASK="standard, lxqt-desktop"; fi
  "$DS" tasksel/first "$TASK"
  echo "desktop=$DESKTOP" >> "$ST/choices"
  echo "lite_auto_reboot=no" >> "$ST/choices"

  # ---- computer name
  HOST=$(printf '%s' "$MODEL" | tr 'A-Z' 'a-z' | sed 's/[^a-z0-9]\{1,\}/-/g; s/^-//; s/-$//' | cut -c1-24 | sed 's/-$//')
  junk_id "$MODEL" && HOST=""
  [ -n "$HOST" ] || HOST=secure-linux
  TAG=""
  for id in "$SERIAL" "$UUID"; do
    junk_id "$id" && continue
    TAG=$(printf '%s' "$id" | tr -cd 'A-Za-z0-9' | tr 'A-Z' 'a-z'); TAG=$(printf '%s' "$TAG" | awk '{ print substr($0, length($0) - 3) }')
    [ ${#TAG} -eq 4 ] && break
    TAG=""
  done
  [ -n "$TAG" ] || TAG=$(tr -dc 'a-z0-9' < "$URANDOM" 2>/dev/null | head -c 4)
  [ -n "$TAG" ] && HOST="$HOST-$TAG"
  header "name of this computer"
  rule
  row "This is the name the computer has on your home network (letters,"
  row "numbers and dashes only). Press Enter to accept the suggestion, or"
  row "type a different one."
  rule
  echo
  while true; do
    answer_default "Computer name:" "$HOST"
    NEWHOST=$(printf '%s' "$REPLY_TEXT" | tr 'A-Z' 'a-z')
    case "$NEWHOST" in ""|-*|*-|*[!a-z0-9-]*) echo "   Use only letters, numbers and dashes (not at the start or end)."; continue ;; esac
    [ ${#NEWHOST} -le 63 ] && break
    echo "   That's too long (63 letters at most)."
  done
  HOST=$NEWHOST
  "$DS" netcfg/get_hostname "$HOST"
  "$DS" netcfg/hostname "$HOST"
  echo "$HOST" > "$ST/hostname"

  # ---- internet connection: a live network cable first, then the Wi-Fi networks saved from Windows
  # (save-wifi.ps1). Honest limit of this installer (busybox: no iw, no nmcli, no python): it cannot
  # scan the air for Wi-Fi, so the choices below come from the networks saved from this computer's
  # Windows, and the screen says so. The installer's own network step prefers a cable, just like this.
  : > "$ST/wifi-selected"; rm -f "$ST/wifi-record"
  b64d() {   # b64d STRING -> the decoded bytes (busybox awk can do it; the installer has no base64 command)
    printf '%s' "$1" | awk 'BEGIN { c = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
        for (i = 1; i <= 64; i++) v[substr(c, i, 1)] = i - 1 }
      { n = length($0); bits = 0; acc = 0
        for (i = 1; i <= n; i++) {
          ch = substr($0, i, 1); if (ch == "=") break; if (!(ch in v)) continue
          acc = acc * 64 + v[ch]; bits += 6
          if (bits >= 8) { bits -= 8; p = 2 ^ bits; byte = int(acc / p); acc = acc - byte * p; if (byte > 0) printf "%c", byte }
        } }'
  }
  printable() { printf '%s' "$1" | tr -c '[:print:]' '?'; }
  cable_on() {   # a network cable is live right now (carrier up on any socket that is not loopback)
    for c in "$SYS"/sys/class/net/*/carrier; do
      [ -r "$c" ] || continue
      case "$c" in */lo/*) continue ;; esac
      [ "$(rd "$c")" = 1 ] && return 0
    done
    return 1
  }
  typed_network() {   # the person types a Wi-Fi name and password (the installer finishes anything missing)
    rule
    row "Type the Wi-Fi name exactly as it appears on your other devices."
    rule
    echo
    answer "Wi-Fi name:"
    TNAME=$REPLY_TEXT
    while true; do
      secret "Password (just Enter for an open network): "
      TPW=$REPLY_SECRET
      case "$TPW" in "") break ;; esac
      case "$TPW" in *[!\ -~]*) echo "   Only plain English-keyboard characters, please."; continue ;; esac
      [ ${#TPW} -ge 8 ] && [ ${#TPW} -le 63 ] && break
      echo "   Wi-Fi passwords are 8 to 63 characters. Try again (or Enter for open)."
    done
    "$DS" netcfg/wireless_essid "$TNAME"
    "$DS" netcfg/wireless_essid_again "$TNAME"
    if [ -n "$TPW" ]; then
      "$DS" netcfg/wireless_security_type wpa/wpa2
      "$DS" netcfg/wireless_wpa "$TPW"
      TPW=""
      rule
      printf '  |  %-70.70s|\n' "The installer will use '$TNAME'."
    else
      rule
      printf '  |  %-70.70s|\n' "The installer will use '$TNAME' (open network)."
    fi
    rule
    echo
  }
  REC=""
  if [ -f "$DIR/wifi-records.txt" ]; then
    S1=$(printf '%s' "$SID" | tr 'A-Z' 'a-z'); U1=$(printf '%s' "$UID_" | tr 'A-Z' 'a-z')
    REC=$(awk -F'|' -v s="$S1" -v u="$U1" 'NF == 6 && ($5 == "plain" || $5 == "enc1") {
            a = tolower($1); b = tolower($2); gsub(/ /, "", a); gsub(/ /, "", b)
            if ((s != "" && a == s) || (u != "" && b == u)) r = $5 "|" $6 } END { if (r != "") print r }' "$DIR/wifi-records.txt")
  fi
  # the home network's name, written by the builder (make-usb.ps1) into the payload
  HOME_SSID=""
  [ -f "$DIR/payload/build.conf" ] && HOME_SSID=$(sed -n 's/^HOME_WIFI_SSID=//p' "$DIR/payload/build.conf" | head -n 1)

  header "internet connection"
  NET_DONE=0
  while [ "$NET_DONE" -eq 0 ]; do

    # 1. a live cable wins, here and in the installer's own network step
    if cable_on; then
      rule
      row "A network cable is plugged in. The installer always uses a cable"
      row "when there is one (it is faster and surer than Wi-Fi), so there"
      row "is nothing to set up here."
      if [ -n "$REC" ]; then
        gap
        case "${REC%%|*}" in
          enc1)
            echo "$REC" > "$ST/wifi-record"
            row "Wi-Fi networks were saved from this computer's Windows,"
            row "protected with a PIN. The first start after the install asks"
            row "for the PIN and adds them; the install uses the network cable." ;;
          *)
            b64d "${REC#*|}" > "$ST/wifi-raw"; echo >> "$ST/wifi-raw"
            grep '|' "$ST/wifi-raw" > "$ST/wifi-bundle" || : > "$ST/wifi-bundle"
            rm -f "$ST/wifi-raw"
            n=$(grep -c . "$ST/wifi-bundle")
            if [ "$n" -gt 0 ]; then
              cp "$ST/wifi-bundle" "$ST/wifi-selected"
              row "The $n Wi-Fi network(s) saved from Windows will be added"
              row "to Linux too, so Wi-Fi works when the cable is unplugged."
            else
              row "The saved Wi-Fi networks can't be read, so they are skipped."
            fi
            rm -f "$ST/wifi-bundle" ;;
        esac
      fi
      rule
      echo
      NET_DONE=1
      continue
    fi

    # 2. no cable: work from the networks saved from this computer's Windows
    if [ -n "$REC" ]; then
      if [ "${REC%%|*}" = enc1 ]; then
        rule
        row "Wi-Fi networks were saved from this computer's Windows,"
        row "protected with a PIN. The installer can't open those. Right after"
        row "the install, the first start asks for the PIN and then which"
        row "networks to add. For the install itself, use a network cable"
        row "(or phone USB tethering)."
        gap
        row "  R = I just plugged in a cable: check again"
        row "  C = continue without a network"
        rule
        echo
        echo "$REC" > "$ST/wifi-record"
        while true; do
          answer "Type R or C (Q to cancel):"
          case "$REPLY_TEXT" in
            [Rr]) cable_on || { echo "   Still no cable. Check the plug at both ends."; continue; } ;;
            [Cc]) NET_DONE=1 ;;
            [Qq]) cancel ;;
          esac
          break
        done
        continue
      fi
      b64d "${REC#*|}" > "$ST/wifi-raw"; echo >> "$ST/wifi-raw"
      grep '|' "$ST/wifi-raw" > "$ST/wifi-bundle" || : > "$ST/wifi-bundle"
      rm -f "$ST/wifi-raw"
      : > "$ST/wifi-names"
      n=0
      while IFS='|' read -r s m p h; do
        n=$((n + 1))
        case "$m" in wpa-psk) lab=WPA2 ;; sae) lab=WPA3 ;; none) lab="open (no password)" ;; *) lab=$m ;; esac
        printf '%s|%s|%s\n' "$n" "$(printable "$(b64d "$s")" | tr '|' '/')" "$lab" >> "$ST/wifi-names"
      done < "$ST/wifi-bundle"
      if [ "$n" -eq 0 ]; then
        rm -f "$ST/wifi-bundle" "$ST/wifi-names"
        rule
        row "The saved Wi-Fi networks can't be read, so they are skipped."
        rule
        echo
        REC=""
      else
        rule
        row "No network cable is plugged in. This screen cannot scan for"
        row "Wi-Fi (this small installer has no scan tool), so it goes by"
        row "the $n network(s) saved from this computer's Windows:"
        gap
        while IFS='|' read -r i name sec; do printf '  |  %2s)  %-32.32s %-32.32s|\n' "$i" "$name" "$sec"; done < "$ST/wifi-names"
        rule
        echo
        # offer the home network (its name is in build.conf); otherwise the first saved one
        OFFER=1
        [ -n "$HOME_SSID" ] && OFFER=$(awk -F'|' -v h="$HOME_SSID" '$2 == h { print $1; f = 1; exit } END { if (!f) print 1 }' "$ST/wifi-names")
        OFFER_NAME=$(awk -F'|' -v i="$OFFER" '$1 == i { print $2 }' "$ST/wifi-names")
        rule
        printf '  |  %-70.70s|\n' "'$OFFER_NAME' is available. Do you want to connect to that"
        row "network automatically? (Y/N)"
        row "Type N to connect to a different network."
        rule
        echo
        CHOICE=""
        while true; do
          answer "Type Y or N (Q to cancel):"
          case "$REPLY_TEXT" in
            [Yy]) CHOICE=$OFFER; break ;;
            [Nn]) break ;;
            [Qq]) cancel ;;
          esac
        done
        if [ -z "$CHOICE" ]; then
          rule
          row "Which Wi-Fi network should the installer use?"
          gap
          while IFS='|' read -r i name sec; do printf '  |  %2s)  %-32.32s %-32.32s|\n' "$i" "$name" "$sec"; done < "$ST/wifi-names"
          printf '  |  %-70.70s|\n' "   T)  type one that is not listed"
          printf '  |  %-70.70s|\n' "   0)  none of these (a network cable, or the installer asks)"
          rule
          echo
          while true; do
            answer "Type the number (T to type one, 0 for none):"
            case "$REPLY_TEXT" in
              [Qq]) cancel ;;
              [Tt]) CHOICE=T; break ;;
              *[!0-9]*) continue ;;
              *) [ "$REPLY_TEXT" -le "$n" ] && { CHOICE=$REPLY_TEXT; break; } ;;
            esac
          done
        fi
        case "$CHOICE" in
          T)
            typed_network ;;
          0)
            rule
            row "No Wi-Fi for the installer. If you can, plug in a network"
            row "cable; otherwise the installer asks its own questions, and"
            row "Wi-Fi can be added after the install."
            rule
            echo ;;
          *)
            cp "$ST/wifi-bundle" "$ST/wifi-selected"
            ESSID=$(awk -F'|' -v i="$CHOICE" '$1 == i { print $2 }' "$ST/wifi-names")
            ULINE=$(sed -n "${CHOICE}p" "$ST/wifi-bundle")
            UM=$(printf '%s' "$ULINE" | cut -d'|' -f2)
            UPW=""
            USABLE=0
            if [ "$UM" = wpa-psk ]; then
              UPW=$(b64d "$(printf '%s' "$ULINE" | cut -d'|' -f3)")
              case "$UPW" in *[!\ -~]*|"") UPW="" ;;
                *) [ ${#UPW} -ge 8 ] && [ ${#UPW} -le 63 ] && USABLE=1 ;;
              esac
            fi
            if [ "$USABLE" -eq 1 ]; then
              "$DS" netcfg/wireless_essid "$ESSID"
              "$DS" netcfg/wireless_essid_again "$ESSID"
              "$DS" netcfg/wireless_security_type wpa/wpa2
              "$DS" netcfg/wireless_wpa "$UPW"
              UPW=""
              rule
              printf '  |  %-70.70s|\n' "The installer will use '$ESSID'."
            else
              rule
              printf '  |  %-70.70s|\n' "'$ESSID' will be added to Linux. The installer"
              row "may ask for its password itself in a moment."
            fi
            row "The $n Wi-Fi network(s) saved from Windows will be added to Linux."
            rule
            echo ;;
        esac
        rm -f "$ST/wifi-bundle" "$ST/wifi-names"
        NET_DONE=1
        continue
      fi
    fi

    # 3. nothing saved (or unreadable): suggest a cable, offer to type one, or let the installer ask
    rule
    row "No network cable is plugged in, and no Wi-Fi networks were saved"
    row "from this computer's Windows."
    gap
    row "A network cable is the easy option: the installer always uses a"
    row "cable when there is one. Plug one in, then type R."
    gap
    row "  R = I just plugged in a cable: check again"
    row "  T = type a Wi-Fi name and password"
    row "  C = continue without a network (the installer asks its own"
    row "      questions, and Wi-Fi can be added after the install)"
    rule
    echo
    while true; do
      answer "Type R, T or C (Q to cancel):"
      case "$REPLY_TEXT" in
        [Rr]) cable_on && break; echo "   Still no cable. Check the plug at both ends." ;;
        [Tt]) typed_network; NET_DONE=1; break ;;
        [Cc]) NET_DONE=1; break ;;
        [Qq]) cancel ;;
      esac
    done
  done
  sleep "${SL_PAUSE:-2}"

  header "installing"
  rule
  row "Next the Debian installer asks a few simple things (the keyboard, and"
  row "the password you will use to log in). Then this screen comes back to"
  row "ask which drive to use, and to set the disk-encryption passphrase."
  gap
  row "NOTHING is erased before you type ERASE."
  rule
  echo
  answer "Type C and press Enter to continue:"
  [ -n "${SL_NOTTY:-}" ] || chvt 1 2>/dev/null
  exit 0
fi

# ================================================================ phase "disk"
[ "$PHASE" = disk ] || { echo "Usage: $0 start|disk" >&2; exit 2; }
DISTRO=$(cat "$ST/distro" 2>/dev/null)
[ -n "$DISTRO" ] || DISTRO=debian-lite

# ---- which drive: internal drives of 8 GB or more; never USB drives, SD cards, optical or virtual disks
NAMES=""; COUNT=0
for d in "$SYS"/sys/block/*; do
  [ -d "$d" ] || continue
  n=${d##*/}
  case "$n" in loop*|ram*|zram*|sr*|fd*|dm-*|md*|nbd*|mmcblk*boot*|mmcblk*rpmb) continue ;; esac
  [ "$(rd "$d/removable")" = 0 ] || continue
  readlink -f "$d/device" 2>/dev/null | grep -q '/usb' && continue
  [ "$(rd "$d/device/type")" = SD ] && continue
  size=$(rd "$d/size"); size=${size:-0}
  [ "$size" -ge 16777216 ] 2>/dev/null || continue
  COUNT=$((COUNT + 1))
  if [ "$(rd "$d/queue/rotational")" = 0 ]; then kind=SSD; else kind=HDD; fi
  model=$(rd "$d/device/model" | sed 's/ *$//')
  parts=0; for p in "$d/$n"*; do [ -d "$p" ] && parts=$((parts + 1)); done
  fs=""
  if command -v blkid >/dev/null 2>&1 && [ "$parts" -gt 0 ]; then
    fs=$(blkid 2>/dev/null | grep "^/dev/$n" | sed 's/.*TYPE="\([^"]*\)".*/\1/' | sort -u | tr '\n' ' ')
  fi
  what=empty
  if [ "$parts" -gt 0 ]; then
    what="$parts partition(s)"
    case " $fs" in *" ntfs "*|*" BitLocker "*) what="Windows, $what" ;; esac
    case " $fs" in *" ext4 "*|*" btrfs "*|*" xfs "*|*" crypto_LUKS "*) what="Linux, $what" ;; esac
    [ -n "$fs" ] && what="$what: ${fs% }"
  fi
  printf '%s|%s|%s|%s|%s|%s\n' "$n" "$size" "$kind" "$model" "$what" "$COUNT" >> "$ST/drives"
done
[ -f "$ST/drives" ] || : > "$ST/drives"
if [ "$COUNT" -eq 0 ]; then
  header "which drive?"
  rule
  row "This computer:  $VENDOR $MODEL"
  gap
  row "No internal drive of 8 GB or more was found, so nothing can be"
  row "installed."
  rule
  rm -f "$ST/drives"
  cancel
fi
PICK=1
if [ "$COUNT" -gt 1 ]; then
  # Suggest the biggest SSD (fast); otherwise the biggest drive. The person still has to type the number.
  BEST=$(awk -F'|' '$3 == "SSD" && $2 > m { m = $2; b = $6 } END { print b }' "$ST/drives")
  [ -n "$BEST" ] || BEST=$(awk -F'|' '$2 > m { m = $2; b = $6 } END { print b }' "$ST/drives")
  header "which drive?"
  rule
  row "This computer has more than one drive. Linux goes on ONE of them,"
  row "and that drive is erased. The others are not touched."
  gap
  while IFS='|' read -r n size kind model what idx; do
    printf '  |  %d)  /dev/%-10.10s %-24.24s %5s GB  %-3.3s|\n' "$idx" "$n" "${model:-unknown model}" $((size / 2097152)) "$kind"
    printf '  |  %-70.70s|\n' "       now contains: $what"
    gap
  done < "$ST/drives"
  row "Suggested: $BEST (SSDs are much faster than HDDs)."
  rule
  echo
  while true; do
    answer "Type the number of the drive to install on (Q to cancel):"
    case "$REPLY_TEXT" in [Qq]) rm -f "$ST/drives"; cancel ;; esac
    case "$REPLY_TEXT" in *[!0-9]*) continue ;; esac
    if [ "$REPLY_TEXT" -ge 1 ] && [ "$REPLY_TEXT" -le "$COUNT" ]; then PICK=$REPLY_TEXT; break; fi
  done
fi
DLINE=$(awk -F'|' -v p="$PICK" '$6 == p' "$ST/drives")
rm -f "$ST/drives"
DISK=$(echo "$DLINE" | cut -d'|' -f1)
DISK_GB=$(( $(echo "$DLINE" | cut -d'|' -f2) / 2097152 ))
DISK_KIND=$(echo "$DLINE" | cut -d'|' -f3)
DISK_MODEL=$(echo "$DLINE" | cut -d'|' -f4)
DISK_WHAT=$(echo "$DLINE" | cut -d'|' -f5)

# ---- backup check
header "backup check"
rule
row "Drive: /dev/$DISK  $DISK_MODEL  ($DISK_GB GB $DISK_KIND)"
gap
FOUND=""
if [ -f "$DIR/backups.txt" ]; then
  for id in "$SID" "$UID_"; do
    [ -n "$id" ] || continue
    # awk, not grep -i -F: the lookup must work the same in every installer environment (some greps break on -i under LC_ALL=C)
    FOUND=$(ID=$id awk 'BEGIN { id = tolower(ENVIRON["ID"]) "|" } index(tolower($0), id) { last = $0 } END { if (last != "") print last }' "$DIR/backups.txt")
    [ -n "$FOUND" ] && break
  done
fi
if [ -n "$FOUND" ]; then
  if [ "$(echo "$FOUND" | cut -d'|' -f5)" = preflight ]; then row "Backup + pre-flight checks done on $(echo "$FOUND" | cut -d'|' -f3)"
  else row "A backup of this computer was made on $(echo "$FOUND" | cut -d'|' -f3)"; fi
  row "to $(echo "$FOUND" | cut -d'|' -f4)."
  rule
  echo
  answer "Type C and press Enter to continue:"
elif [ "$DISK_WHAT" = empty ]; then
  row "This drive is empty (new or blank), so there is nothing to back up."
  rule
  echo
  answer "Type C and press Enter to continue:"
else
  row "!! NO BACKUP has been recorded for this computer. !!"
  gap
  row "Everything on its drive will be deleted. To back it up first:"
  gap
  row "  - Windows PC: start Windows, double-click BUILD-USB.cmd on this"
  row "    USB stick (linux-setup\kit) and answer y to the backup question."
  row "  - Any PC: restart, and choose Clonezilla from this USB stick's"
  row "    menu to save a full image of the drive to another drive."
  rule
  echo
  while true; do
    answer "Type B to stop and back up first, or C to continue WITHOUT a backup:"
    case "$REPLY_TEXT" in [Bb]) cancel ;; [Cc]) break ;; esac
  done
fi

# ---- erase confirmation
header "erase the drive"
rule
row "This drive will be COMPLETELY ERASED:"
gap
printf '  |  %-70.70s|\n' "  /dev/$DISK  $DISK_MODEL  ($DISK_GB GB $DISK_KIND)"
printf '  |  %-70.70s|\n' "  It contains now: $DISK_WHAT"
gap
row "Then Debian is installed with the light desktop and full-disk"
row "encryption, and the apps install by themselves."
rule
echo
answer "Type ERASE (in capitals) to continue, or anything else to cancel:"
[ "$REPLY_TEXT" = "ERASE" ] || cancel

# ---- encryption passphrase
# The EFF short word list 1 (1296 words), (c) Electronic Frontier Foundation, CC BY 3.0 US, https://www.eff.org/dice
# 5 words = about 52 bits, enough with LUKS's slow key derivation.
gen_passphrase() {   # 5 random words (unbiased: numbers >= 99792 are drawn again)
  [ -f "$DIR/eff-words.txt" ] || return 1
  [ "$(grep -c . "$DIR/eff-words.txt")" -eq 1296 ] || return 1
  # one batch of random digits, used 5 at a time (a fresh read each time would repeat itself with a fixed test source)
  DIG=$(tr -dc '0-9' < "$URANDOM" 2>/dev/null | head -c 400)
  PP=""
  i=0; pos=0
  while [ "$i" -lt 5 ]; do
    v=$(printf '%s' "$DIG" | cut -c$((pos + 1))-$((pos + 5)))
    pos=$((pos + 5))
    [ ${#v} -eq 5 ] || { DIG=""; return 1; }
    v=$(printf '%s' "$v" | sed 's/^0*//'); v=${v:-0}
    [ "$v" -lt 99792 ] || continue
    w=$(sed -n "$((v % 1296 + 1))p" "$DIR/eff-words.txt")
    [ -n "$w" ] || { DIG=""; return 1; }
    PP="${PP:+$PP }$w"
    i=$((i + 1))
  done
  DIG=""
  return 0
}
PW1=""
while [ -z "$PW1" ]; do
  header "encryption passphrase"
  rule
  row "Everything on this computer is encrypted. You type this passphrase"
  row "EVERY time the computer turns on. If it is lost or stolen, nobody can"
  row "read your files without it. If YOU lose it, your files are gone"
  row "forever: no reset."
  gap
  row "Write it on paper kept safe at home (never with the computer) AND"
  row "save it in a password manager. It's separate from your login password."
  gap
  row "  G = make one for me: 5 random words,"
  row "      e.g. 'tulip orbit canvas mango zebra'"
  row "      (recommended: strong and easy to type)"
  row "  O = I'll type my own (12 or more characters)"
  rule
  echo
  while true; do
    answer "Type G or O (Q to cancel):"
    case "$REPLY_TEXT" in [Gg]) MODE=gen; break ;; [Oo]) MODE=own; break ;; [Qq]) cancel ;; esac
  done
  if [ "$MODE" = gen ]; then
    if ! gen_passphrase; then
      echo "   Couldn't make one here. Please type your own."; MODE=own; sleep "${SL_PAUSE:-3}"
    else
      while true; do
        header "encryption passphrase"
        rule
        row "Your passphrase (5 words, small letters, one space between words):"
        rule
        echo
        echo "   +----------------------------------------------------------------+"
        echo "   |                                                                |"
        printf '   |     %-58s |\n' "$PP"
        echo "   |                                                                |"
        echo "   +----------------------------------------------------------------+"
        echo
        rule
        row "Write it down now, exactly. Then type it below to show it's right."
        row "(N = give me different words)"
        rule
        echo
        printf '   Type it: '; read -r TYPED || cancel
        if [ "$TYPED" = "$PP" ]; then PW1=$PP; break; fi
        case "$TYPED" in [Nn]) gen_passphrase; continue ;; esac
        echo "   That's not the same. Check your paper and try again."; sleep "${SL_PAUSE:-3}"
      done
      PP=""; TYPED=""
      clear_screen
    fi
  fi
  if [ "$MODE" = own ]; then
    echo
    rule
    row "Use only plain letters, numbers, spaces and symbols from an English"
    row "(US) keyboard: no accents or emoji. The power-on screen may use a"
    row "different keyboard layout from the one you are used to, so special"
    row "letters could become impossible to type."
    rule
    echo
    while true; do
      secret "Encryption passphrase: "; P1=$REPLY_SECRET
      secret "Type it again:         "; P2=$REPLY_SECRET
      if [ "$P1" != "$P2" ]; then echo "   They don't match. Try again."; echo; continue; fi
      if [ ${#P1} -lt 12 ]; then echo "   Too short: use at least 12 characters (4 words is easiest)."; echo; continue; fi
      case "$P1" in *[!\ -~]*) echo "   Only plain English-keyboard characters, please (no accents or emoji)."; echo; continue ;; esac
      break
    done
    PW1=$P1; P1=""; P2=""; REPLY_SECRET=""
  fi
done

# ---- hand everything to the installer (the passphrase stays in memory, in the installer's answer store)
"$DS" partman-auto/disk "/dev/$DISK"
"$DS" partman-auto/method crypto
"$DS" partman-crypto/passphrase "$PW1"
"$DS" partman-crypto/passphrase-again "$PW1"
PW1=""
"$DS" partman-lvm/device_remove_lvm true
"$DS" partman-md/device_remove_md true
"$DS" partman-lvm/confirm true
"$DS" partman-lvm/confirm_nooverwrite true
"$DS" partman-md/confirm true
"$DS" partman/confirm_nooverwrite true
"$DS" partman/confirm true
"$DS" partman-partitioning/confirm_write_new_label true
"$DS" partman/choose_partition finish
[ -d "$SYS/sys/firmware/efi" ] || "$DS" grub-installer/bootdev "/dev/$DISK"
echo "$DISK" > "$ST/disk"

header "installing"
rule
row "All set. Installing now: about 20-40 minutes, no more questions."
gap
row "When it finishes the computer TURNS OFF. Remove the USB stick, then"
row "turn it on, type your encryption passphrase, and log in. Apps keep"
row "installing in the background (the computer needs the internet for"
row "that) and a notice appears when everything is ready."
rule
sleep "${SL_PAUSE:-6}"
[ -n "${SL_NOTTY:-}" ] || chvt 1 2>/dev/null
exit 0
