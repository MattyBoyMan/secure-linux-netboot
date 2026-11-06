#!/bin/bash
# Secure Linux shared progress display. Source this file; do not execute it.
#
# Stable public API (also used by the rescue SSD backup tool):
#   sl_progress_start TOTAL_UNITS LABEL
#       Start a determinate display. Units are non-negative integers (bytes, files,
#       MiB, or weighted stage points). LABEL is beginner-readable text.
#   sl_progress_update DONE_UNITS
#       Show real completed work. Values are clamped to 0..TOTAL_UNITS.
#   sl_progress_done
#       Show 100% and finish the line. Call only after the work really succeeds.
#
# Indeterminate work (no honest total):
#   sl_progress_spinner_start LABEL
#   sl_progress_spinner_stop [COMPLETION_MESSAGE]
#       Start/stop a small animated loader. Always stop it after the command ends.
#       On a dumb or redirected terminal it prints plain lines and starts no process.
#
# The ETA is display-only: it must NEVER trigger or cancel work. It uses a simple
# moving average of the last five positive interval rates. Two samples are needed;
# before that the display says "working it out...". Estimates are capped at eight
# hours and longer waits say "more than 8 hours". There are no colour escapes.
# Unicode bars need a UTF locale and a non-dumb terminal; ASCII is the fallback.
# Redirected output, NO_COLOR and TERM=dumb all get plain one-line updates.
#
# The implementation deliberately uses POSIX-shell syntax so the Debian installer's
# busybox ash can also source it, although bash is the normal interpreter. Only the
# standard date, sleep, kill and wait commands are used. SL_PROGRESS_TEST_TIME and
# SL_PROGRESS_FORCE_INTERACTIVE are test hooks, not part of the public API.

_SL_PROGRESS_CAP_SECONDS=28800

_sl_progress_now() {
  if [ -n "${SL_PROGRESS_TEST_TIME:-}" ]; then
    printf '%s\n' "$SL_PROGRESS_TEST_TIME"
  else
    date +%s
  fi
}

_sl_progress_plain() {
  [ "${SL_PROGRESS_FORCE_INTERACTIVE:-0}" != 1 ] || return 1
  [ "${TERM:-dumb}" = dumb ] && return 0
  [ -t 1 ] || return 0
  return 1
}

_sl_progress_unicode() {
  [ "${TERM:-dumb}" != dumb ] || return 1
  case "${LC_ALL:-${LC_CTYPE:-${LANG:-}}}" in
    *UTF-8*|*UTF8*|*utf-8*|*utf8*) return 0 ;;
  esac
  return 1
}

_sl_progress_eta() {
  _SLP_ETA_TEXT='Estimated completion time: working it out...'
  [ "${_SLP_RATE_COUNT:-0}" -ge 2 ] || return 0
  [ "${_SLP_TOTAL:-0}" -gt 0 ] || return 0
  _slp_sum=0
  for _slp_rate in $_SLP_RATES; do _slp_sum=$((_slp_sum + _slp_rate)); done
  [ "$_slp_sum" -gt 0 ] || return 0
  _slp_average=$((_slp_sum / _SLP_RATE_COUNT))
  [ "$_slp_average" -gt 0 ] || return 0
  _slp_left=$((_SLP_TOTAL - _SLP_DONE))
  [ "$_slp_left" -gt 0 ] || { _SLP_ETA_TEXT='Estimated completion time: finishing now'; return 0; }
  _slp_seconds=$((_slp_left * 1000 / _slp_average))
  [ "$_slp_seconds" -ge 0 ] || _slp_seconds=0
  if [ "$_slp_seconds" -gt "$_SL_PROGRESS_CAP_SECONDS" ]; then
    _SLP_ETA_TEXT='Estimated completion time: more than 8 hours remaining'
  elif [ "$_slp_seconds" -lt 60 ]; then
    _SLP_ETA_TEXT="Estimated completion time: $_slp_seconds secs remaining"
  elif [ "$_slp_seconds" -lt 3600 ]; then
    _slp_minutes=$((_slp_seconds / 60))
    _slp_remainder=$((_slp_seconds % 60))
    if [ "$_slp_remainder" -eq 0 ]; then
      _SLP_ETA_TEXT="Estimated completion time: $_slp_minutes mins remaining"
    else
      _slp_word=mins; [ "$_slp_minutes" -ne 1 ] || _slp_word=min
      _SLP_ETA_TEXT="Estimated completion time: $_slp_minutes $_slp_word $_slp_remainder secs remaining"
    fi
  else
    _slp_hours=$((_slp_seconds / 3600))
    _slp_minutes=$((((_slp_seconds % 3600) + 30) / 60))
    if [ "$_slp_minutes" -eq 60 ]; then _slp_hours=$((_slp_hours + 1)); _slp_minutes=0; fi
    _SLP_ETA_TEXT="Estimated completion time: ${_slp_hours} hours ${_slp_minutes} mins remaining"
  fi
}

_sl_progress_bar() {
  _SLP_BAR=''
  _slp_width=24
  if [ "${_SLP_TOTAL:-0}" -gt 0 ]; then
    _slp_filled=$((_SLP_DONE * _slp_width / _SLP_TOTAL))
  else
    _slp_filled=0
  fi
  _slp_i=0
  while [ "$_slp_i" -lt "$_slp_width" ]; do
    if [ "$_slp_i" -lt "$_slp_filled" ]; then
      if _sl_progress_unicode; then _SLP_BAR="${_SLP_BAR}█"; else _SLP_BAR="${_SLP_BAR}#"; fi
    else
      if _sl_progress_unicode; then _SLP_BAR="${_SLP_BAR}░"; else _SLP_BAR="${_SLP_BAR}-"; fi
    fi
    _slp_i=$((_slp_i + 1))
  done
}

_sl_progress_render() {
  if [ "${_SLP_TOTAL:-0}" -gt 0 ]; then
    _SLP_PERCENT=$((_SLP_DONE * 100 / _SLP_TOTAL))
  else
    _SLP_PERCENT=0
  fi
  _sl_progress_eta
  _sl_progress_bar
  if _sl_progress_plain; then
    printf '%s is %s%% completed [%s] %s\n' "$_SLP_LABEL" "$_SLP_PERCENT" "$_SLP_BAR" "$_SLP_ETA_TEXT"
  else
    printf '\r\033[K%s is %s%% completed [%s] %s' "$_SLP_LABEL" "$_SLP_PERCENT" "$_SLP_BAR" "$_SLP_ETA_TEXT"
  fi
}

sl_progress_start() {
  _SLP_TOTAL=${1:-0}
  _SLP_LABEL=${2:-Working}
  case $_SLP_TOTAL in ''|*[!0-9]*) printf 'sl_progress_start: TOTAL_UNITS must be a non-negative integer\n' >&2; return 2 ;; esac
  _SLP_DONE=0
  _SLP_RATES=''
  _SLP_RATE_COUNT=0
  _SLP_LAST_DONE=0
  _SLP_LAST_TIME=$(_sl_progress_now)
  _SLP_STARTED=$_SLP_LAST_TIME
  _sl_progress_render
}

sl_progress_update() {
  [ -n "${_SLP_STARTED:-}" ] || { printf 'sl_progress_update: call sl_progress_start first\n' >&2; return 2; }
  _slp_new=${1:-0}
  case $_slp_new in ''|*[!0-9]*) printf 'sl_progress_update: DONE_UNITS must be a non-negative integer\n' >&2; return 2 ;; esac
  [ "$_slp_new" -ge 0 ] || _slp_new=0
  [ "$_slp_new" -le "$_SLP_TOTAL" ] || _slp_new=$_SLP_TOTAL
  [ "$_slp_new" -ge "$_SLP_DONE" ] || _slp_new=$_SLP_DONE
  _slp_now=$(_sl_progress_now)
  _slp_dt=$((_slp_now - _SLP_LAST_TIME))
  _slp_dd=$((_slp_new - _SLP_DONE))
  if [ "$_slp_dt" -gt 0 ] && [ "$_slp_dd" -gt 0 ]; then
    # Milli-units per second keep integer shell arithmetic useful for slow copies.
    _slp_rate=$((_slp_dd * 1000 / _slp_dt))
    [ "$_slp_rate" -gt 0 ] || _slp_rate=1
    _SLP_RATES="${_SLP_RATES:+$_SLP_RATES }$_slp_rate"
    _SLP_RATE_COUNT=$((_SLP_RATE_COUNT + 1))
    if [ "$_SLP_RATE_COUNT" -gt 5 ]; then
      _slp_old=${_SLP_RATES%% *}
      _SLP_RATES=${_SLP_RATES#$_slp_old}
      _SLP_RATES=${_SLP_RATES# }
      _SLP_RATE_COUNT=5
    fi
    _SLP_LAST_TIME=$_slp_now
  fi
  # A same-second update still advances the real percentage; it simply does not
  # add a rate sample until a whole second has elapsed.
  _SLP_DONE=$_slp_new
  _sl_progress_render
}

sl_progress_done() {
  [ -n "${_SLP_STARTED:-}" ] || return 0
  if [ -n "${_SLP_SPINNER_PID:-}" ]; then sl_progress_spinner_stop >/dev/null 2>&1; fi
  if [ "$_SLP_TOTAL" -gt 0 ]; then
    _SLP_DONE=$_SLP_TOTAL
    _sl_progress_render
  else
    printf '%s is 100%% completed [########################] Estimated completion time: finished\n' "$_SLP_LABEL"
  fi
  _sl_progress_plain || printf '\n'
}

sl_progress_spinner_start() {
  _SLP_SPINNER_LABEL=${1:-Working}
  if [ -n "${_SLP_SPINNER_PID:-}" ]; then sl_progress_spinner_stop >/dev/null 2>&1; fi
  if _sl_progress_plain; then
    printf '%s...\n' "$_SLP_SPINNER_LABEL"
    return 0
  fi
  (
    trap 'exit 0' HUP INT TERM
    while :; do
      for _slp_frame in '|' '/' '-' '\'; do
        printf '\r\033[K%s %s' "$_slp_frame" "$_SLP_SPINNER_LABEL"
        sleep 0.2
      done
    done
  ) &
  _SLP_SPINNER_PID=$!
}

sl_progress_spinner_stop() {
  _slp_message=${1:-${_SLP_SPINNER_LABEL:-Working} finished}
  if [ -n "${_SLP_SPINNER_PID:-}" ]; then
    kill "$_SLP_SPINNER_PID" 2>/dev/null || true
    wait "$_SLP_SPINNER_PID" 2>/dev/null || true
    _SLP_SPINNER_PID=''
    printf '\r\033[K%s\n' "$_slp_message"
  else
    printf '%s\n' "$_slp_message"
  fi
}
