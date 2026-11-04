# shellcheck shell=bash
# Wizard page (comfort): Python (uv / conda envs from Windows), MATLAB or GNU Octave, Android Studio.
page_title() { echo "Study and coding tools"; }
page_run() {
  . "$SL_ROOT/files/comfort/comfort-lib.sh"
  wz_is_done comfort-study && return 0
  [ "$(sl_profile)" = full ] || { wz_done comfort-study; return 0; }
  local a M=$SL_ROOT/bin/secure-linux-migrate todo=() src envs=""
  a=$(cf_ask3 "Set up the study and coding tools you used on Windows?

We'll ask about three things, one at a time: Python (Anaconda), MATLAB and Android Studio." "Yes, let's go")
  case $a in never) wz_done comfort-study; return 0 ;; later) return 0 ;; esac

  # ---- Python
  src=$(cf_find_backup)
  [ -n "$src" ] && envs=$(find "$src" -maxdepth 4 \( -iname '*.yml' -o -iname '*.yaml' \) -print0 2>/dev/null | xargs -0 -r grep -l '^dependencies:' 2>/dev/null | head -20)
  a=$(wz_choice "Python: \"uv\" is already installed. It's the modern, fast way to make Python projects (uv init, uv add numpy, uv run).

You used Anaconda on Windows.$([ -n "$envs" ] && printf '\n\nWe found %s exported Anaconda environment(s) in your Windows backup.' "$(printf '%s\n' "$envs" | wc -l)")

Would you like conda too, to recreate your old environments?" \
    "Yes, install conda$([ -n "$envs" ] && echo ' and recreate my environments')" "No, uv is fine")
  case $a in Yes*) todo+=(conda=yes) ;; No*) cf_save_choice conda no ;; esac

  # ---- MATLAB
  a=$(wz_choice "MATLAB: two options (you can have both).
  - GNU Octave: free, open source, runs most MATLAB scripts (.m files) unchanged. Installs now.
  - Official MATLAB for Linux: uses your university/MathWorks licence. Fedora isn't officially supported by MathWorks but MATLAB usually runs fine; we'll show you the steps.
Tip: if your old Windows MATLAB is still activated, release that licence at mathworks.com > My Account > Licenses (deactivate the old computer)." \
    "GNU Octave" "Official MATLAB" "Both" "Neither")
  case $a in
    "GNU Octave") todo+=(matlab=octave) ;; "Both") todo+=(matlab=both) ;;
    "Official MATLAB") cf_save_choice matlab official ;; "Neither") cf_save_choice matlab none ;;
  esac

  # ---- Android Studio
  if wz_yesno "Android Studio: install it (with adb/fastboot so it can talk to your phone, and fast emulators)?

About 3 GB on first start (it downloads the Android SDK itself)."; then todo+=(android_dev=yes); else cf_save_choice android_dev no; fi

  if [ ${#todo[@]} -gt 0 ]; then
    wz_info "Installing: ${todo[*]//=*/}. Your password is asked once. This can take a few minutes."
    wz_root "$M" install "${todo[@]}"
  fi
  if [[ " ${todo[*]} " == *" conda=yes "* ]] && [ -n "$envs" ]; then
    wz_info "Now recreating your Anaconda environments in a window. Some Windows-only packages are skipped automatically; if one environment fails, the window says how to fix it."
    cf_terminal "$M" conda-envs "$src"
  fi
  case $(sl_choice_get matlab) in official|both)
    wz_info "Official MATLAB on Linux (about 15 minutes, needs your MathWorks account):
  1. Open the Terminal (Ctrl+Alt+T) and type, one line at a time:
       cd ~/Downloads
       wget https://www.mathworks.com/mpm/glnxa64/mpm
       chmod +x mpm
       ./mpm install --release=R2025b --destination=\$HOME/MATLAB --products MATLAB
     (Use the newest release name shown on mathworks.com, e.g. R2026a.)
  2. Start it with ~/MATLAB/bin/matlab and sign in to activate.
If it refuses to start on Fedora, the guide's MATLAB page shows the fallback: run it inside an Ubuntu container with Distrobox (BoxBuddy app)."
    wz_open "https://www.mathworks.com/help/install/ug/mpminstall.html" ;;
  esac
  [[ " ${todo[*]} " == *" android_dev=yes "* ]] && wz_info "Android Studio is in the app menu. Your phone: turn on Developer options > USB debugging, plug it in, and tap \"Allow\" on the phone. Log out and in once so the emulator speed-up applies."
  wz_done comfort-study
  return 0
}
