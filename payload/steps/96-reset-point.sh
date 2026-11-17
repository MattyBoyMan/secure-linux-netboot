# shellcheck shell=bash
# 96-reset-point: remember this computer's first day, so "Reset this computer, keep my files" (bin/secure-linux-reset)
# knows later which apps were added after it. Owned by: movereset (P27). Sourced by setup.sh: never `exit`.
#   The reset point (lists of the app store apps, the programs installed on purpose and the optional-app choices,
#   in /var/lib/secure-linux/movereset/reset-point/) is written ONCE: at the end of the first setup that finished
#   without a failure. It is never rewritten, so a repair years later does not turn a changed computer into "day one".
#   If the first setup had a failure, a small note asks the next successful repair to write it instead.
#   Nothing here can make setup fail: every problem is a plain note, never a failure.
#   Atomic (image-based) computers get the app list too; their system image is never changed by a reset.
[ "$SL_MODE" = early ] && return 0
SL_STAGE_SKIPPABLE=1
sl_step "Remembering this computer's first day (for 'Reset this computer, keep my files')"
_rp96_lib="$SL_ROOT/files/movereset/movereset-lib.sh"
_rp96_want="$SL_STATE/movereset/reset-point.wanted"
if [ ! -f "$_rp96_lib" ]; then
  echo "The reset tools are not installed yet; the first day is remembered after the next repair."
else
  # shellcheck source=../files/movereset/movereset-lib.sh
  . "$_rp96_lib"
  if mr_point_exists; then
    echo "The reset point from $(mr_point_date) is kept as it is."
    rm -f "$_rp96_want"
  elif [ -s "$SL_FAILS" ]; then
    mkdir -p "$SL_STATE/movereset" && : > "$_rp96_want"
    echo "Setup is not finished yet, so the first day is remembered after the next successful repair."
  elif [ "$SL_MODE" = install ] || [ -f "$_rp96_want" ]; then
    if mr_make_point first-setup; then
      rm -f "$_rp96_want"
      echo "Reset point made: a later reset keeps the apps this computer has today."
    else
      mkdir -p "$SL_STATE/movereset" && : > "$_rp96_want"
      echo "The reset point could not be made this time; the next repair tries again."
    fi
  else
    echo "This computer was set up before reset points existed. A reset still gives fresh desktop settings and a repair."
    echo "To remember today's apps as the first day: secure-linux-reset point"
  fi
fi
unset _rp96_lib _rp96_want
return 0
