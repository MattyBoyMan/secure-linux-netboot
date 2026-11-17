# shellcheck shell=bash
# 52-app-library: the optional apps from the App Library (contract C11). Sourced by setup.sh. Owned by: app-library.
# Installs the apps the catalogue marks "on" for this profile, plus the ones chosen in /etc/secure-linux/app-library.list.
# Only when online: with no internet an app waits (listed in skipped-apps, retried by a timer) and setup is NOT
# incomplete. Safe to run again: an app that is already installed is left alone (repair and the recovery journal).
[ "$SL_MODE" = early ] && return 0
SL_STAGE_SKIPPABLE=1
sl_step "Adding optional apps (only when online)"
_al52_tool=""
for _al52_t in "$SL_ROOT/bin/secure-linux-app-library" /usr/local/bin/secure-linux-app-library; do
  [ -r "$_al52_t" ] && { _al52_tool=$_al52_t; break; }
done
if [ -z "$_al52_tool" ]; then
  echo "The App Library tool is not installed yet; optional apps are skipped this time."
else
  SL_ROOT="$SL_ROOT" SL_ETC="$SL_ETC" SL_STATE="$SL_STATE" SL_LOGDIR="$SL_LOGDIR" SL_FAILS="$SL_FAILS" \
    bash "$_al52_tool" run || echo "The optional apps could not be checked this time. Secure Linux will try again later."
fi
unset _al52_tool _al52_t
return 0
