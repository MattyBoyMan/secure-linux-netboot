# shellcheck shell=bash
# Wizard page (comfort): accessibility - only what the user picks. Per-user look settings are applied now;
# programs (Orca, OpenDyslexic, Live Captions) are installed through choice "accessibility".
page_title() { echo "Easier to see, hear and read"; }
page_run() {
  . "$SL_ROOT/files/comfort/comfort-lib.sh"
  wz_is_done comfort-a11y && return 0
  local desk list=() a mode M=$SL_ROOT/bin/secure-linux-migrate font size=12
  desk=$(cf_desktop)
  wz_yesno "Would you like to look at accessibility options? (Bigger text, a bigger pointer, high contrast, colour-blindness filters, a screen reader, a font for dyslexia and live captions.)

Most people can skip this. You can come back any time: app menu > \"Bring My Stuff from Windows\" > \"Easier to see, hear and read\"." || { wz_done comfort-a11y; return 0; }

  set_font() {   # set_font FAMILY SIZE   (KDE: every UI font; Xfce: the default font)
    if [ "$desk" = kde ]; then
      local spec="$1,$2,-1,5,400,0,0,0,0,0,0,0,0,0,0,1" small="$1,$(( $2 - 2 )),-1,5,400,0,0,0,0,0,0,0,0,0,0,1"
      cf_kconf kdeglobals General font "$spec"; cf_kconf kdeglobals General menuFont "$spec"
      cf_kconf kdeglobals General toolBarFont "$spec"; cf_kconf kdeglobals General smallestReadableFont "$small"
      cf_kconf kdeglobals WM activeFont "$spec"
      cf_kde_notify 2 0
    elif cf_have xfconf-query; then
      xfconf-query -c xsettings -p /Gtk/FontName -n -t string -s "$1 $2"
    fi
  }
  font="Noto Sans"
  if wz_yesno "Bigger text everywhere?"; then
    size=13
    if [ "$desk" = xfce ] && cf_have xfconf-query; then xfconf-query -c xsettings -p /Xft/DPI -n -t int -s 120
    else set_font "$font" "$size"; fi
  fi
  if wz_yesno "A bigger mouse pointer?"; then
    if [ "$desk" = kde ]; then cf_kconf kcminputrc Mouse cursorSize 48
    elif cf_have xfconf-query; then xfconf-query -c xsettings -p /Gtk/CursorThemeSize -n -t int -s 48; fi
  fi
  if wz_yesno "High contrast (white text on black, yellow highlights)?"; then
    if [ "$desk" = kde ] && cf_have plasma-apply-colorscheme; then plasma-apply-colorscheme SecureLinuxHighContrast >/dev/null 2>&1
    elif cf_have xfconf-query; then xfconf-query -c xsettings -p /Net/ThemeName -n -t string -s HighContrast; fi
  fi
  if [ "$desk" = kde ]; then
    a=$(wz_choice "Colour-blindness filter? It shifts colours so they're easier to tell apart." \
      "No filter" "Red-weak (protanopia)" "Green-weak (deuteranopia)" "Blue-weak (tritanopia)")
    case $a in Red*) mode=0 ;; Green*) mode=1 ;; Blue*) mode=2 ;; *) mode="" ;; esac
    if [ -n "$mode" ]; then
      cf_kconf kwinrc Plugins colorblindnesscorrectionEnabled true
      cf_kconf kwinrc Effect-colorblindnesscorrection Mode "$mode"
      cf_kwin_reconfigure
    fi
  fi
  wz_yesno "A screen reader (Orca) that reads out what's on the screen? It starts at every login; switch it off any time with Meta+Alt+S." && list+=(orca)
  wz_yesno "A font made for dyslexia (OpenDyslexic) as the screen font?" && list+=(dyslexia)
  wz_yesno "Live Captions: subtitles for any sound the laptop plays (videos, calls), made on this laptop, offline?" && list+=(captions)

  if [ ${#list[@]} -gt 0 ]; then
    local joined; joined=$(IFS=,; echo "${list[*]}")
    wz_info "Installing ${list[*]}. Your password is asked once."
    wz_root "$M" install "accessibility=$joined"
    if [[ " ${list[*]} " == *" orca "* ]]; then
      if [ "$desk" = kde ]; then cf_kconf kaccessrc ScreenReader Enabled true
      elif cf_have gsettings; then gsettings set org.gnome.desktop.a11y.applications screen-reader-enabled true 2>/dev/null; fi
      cf_have orca && { orca >/dev/null 2>&1 & }
    fi
    [[ " ${list[*]} " == *" dyslexia "* ]] && set_font "OpenDyslexic" "$(( size - 1 ))"
    [[ " ${list[*]} " == *" captions "* ]] && wz_info "Live Captions is in the app menu. Start it when you need subtitles; it works offline and English only."
  fi
  unset -f set_font
  wz_info "Done. Some changes (pointer size, fonts in apps that were already open) show fully after you log out and back in.

All of these are also in System Settings > Accessibility$([ "$desk" = kde ] && echo ' and Appearance')."
  wz_done comfort-a11y
  return 0
}
