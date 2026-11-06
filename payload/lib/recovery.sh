#!/bin/bash
# Durable, non-secret setup recovery journal. Source after lib/common.sh.
# The journal contains only fixed record names, stage basenames and SHA-256 hashes.
# It never contains profile/user choices, login names, Wi-Fi data, passwords or erase consent.

SL_RECOVERY_JOURNAL=${SL_RECOVERY_JOURNAL:-$SL_STATE/setup-journal}
SL_RECOVERY_ARTIFACT_DIR=${SL_RECOVERY_ARTIFACT_DIR:-$SL_STATE/setup-artifacts}
SL_RECOVERY_REASON=
SL_RECOVERY_CURRENT_STAGE=
SL_RECOVERY_CURRENT_HASH=
SL_RECOVERY_CURRENT_POLICY=restart-only
declare -a SL_RECOVERY_LINES=()
declare -a SL_RECOVERY_ARTIFACT_PATHS=()

sl_recovery_sync() { sync -f "$1" >/dev/null 2>&1 || sync; }

# sl_recovery_atomic_write PATH MODE < content
sl_recovery_atomic_write() {
  local path=$1 mode=$2 tmp="${1}.tmp.$$"
  mkdir -p "$(dirname "$path")" || return 1
  ( umask 077; cat > "$tmp" ) || { rm -f "$tmp"; return 1; }
  chmod "$mode" "$tmp" || { rm -f "$tmp"; return 1; }
  mv -f "$tmp" "$path" || { rm -f "$tmp"; return 1; }
  sl_recovery_sync "$path"
}

sl_recovery_empty_hash() { printf '' | sha256sum | cut -d' ' -f1; }

sl_recovery_valid_hash() { [[ ${1:-} =~ ^[0-9a-f]{64}$ ]]; }
sl_recovery_valid_stage() { [[ ${1:-} =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$ ]]; }

sl_recovery_journal_write() {
  local line
  {
    printf '%s\n' "${SL_RECOVERY_LINES[@]}"
  } | sl_recovery_atomic_write "$SL_RECOVERY_JOURNAL" 0600
}

# Parse without eval/source. Any unknown key, duplicate stage, misplaced running
# record or malformed hash invalidates the whole journal; no partial values survive.
sl_recovery_load() {
  SL_RECOVERY_LINES=()
  SL_RECOVERY_REASON=
  [ -f "$SL_RECOVERY_JOURNAL" ] && [ ! -L "$SL_RECOVERY_JOURNAL" ] || {
    SL_RECOVERY_REASON='The recovery journal is missing, not a regular file, or is a symbolic link.'
    return 1
  }
  local line n=0 kind stage status policy script_hash manifest_hash mode
  local seen_run=0 blocked=0
  declare -A seen=()
  while IFS= read -r line || [ -n "$line" ]; do
    n=$((n + 1)); [ "$n" -le 10000 ] || { SL_RECOVERY_REASON='The recovery journal is too large.'; return 1; }
    case "$line" in
      *PASSWORD*|*PASSPHRASE*|*WIFI_SSID*|*WIFI_PASSWORD*|*USERNAME*|*TARGET_DISK_ERASE*|*ERASE_CONSENT*)
        SL_RECOVERY_REASON='The recovery journal contains a forbidden secret or consent field.'
        return 1 ;;
    esac
    if [ "$n" -eq 1 ]; then
      [ "$line" = secure-linux-setup-journal-v1 ] || {
        SL_RECOVERY_REASON='The recovery journal has an unsupported header.'; return 1; }
      SL_RECOVERY_LINES+=("$line"); continue
    fi
    IFS='|' read -r kind stage status policy script_hash manifest_hash extra <<< "$line"
    case "$kind" in
      run)
        [ "$n" -eq 2 ] && [ "$seen_run" -eq 0 ] && [ -z "${extra:-}" ] || {
          SL_RECOVERY_REASON='The recovery journal has an invalid run record.'; return 1; }
        # run|active|install (the field names above are intentionally reused only locally)
        case "$stage" in active|failed) ;; *) SL_RECOVERY_REASON='The recovery journal run state is invalid.'; return 1 ;; esac
        case "$status" in install|repair) ;; *) SL_RECOVERY_REASON='The recovery journal run mode is invalid.'; return 1 ;; esac
        [ -z "${policy:-}" ] || { SL_RECOVERY_REASON='The recovery journal run record has extra fields.'; return 1; }
        seen_run=1 ;;
      stage)
        [ "$seen_run" -eq 1 ] && [ "$blocked" -eq 0 ] && [ -z "${extra:-}" ] || {
          SL_RECOVERY_REASON='The recovery journal has an invalid stage sequence.'; return 1; }
        sl_recovery_valid_stage "$stage" && sl_recovery_valid_hash "$script_hash" && sl_recovery_valid_hash "$manifest_hash" || {
          SL_RECOVERY_REASON='The recovery journal has an invalid stage name or hash.'; return 1; }
        case "$status" in running|completed|failed) ;; *) SL_RECOVERY_REASON='The recovery journal stage state is invalid.'; return 1 ;; esac
        case "$policy" in idempotent|restart-only) ;; *) SL_RECOVERY_REASON='The recovery journal stage policy is invalid.'; return 1 ;; esac
        [ -z "${seen[$stage]:-}" ] || { SL_RECOVERY_REASON='The recovery journal repeats a stage.'; return 1; }
        seen[$stage]=1
        [ "$status" = completed ] || blocked=1 ;;
      *) SL_RECOVERY_REASON='The recovery journal contains an unknown record.'; return 1 ;;
    esac
    SL_RECOVERY_LINES+=("$line")
  done < "$SL_RECOVERY_JOURNAL"
  [ "$seen_run" -eq 1 ] && [ "${#SL_RECOVERY_LINES[@]}" -ge 2 ] || {
    SL_RECOVERY_REASON='The recovery journal is incomplete.'; return 1; }
  return 0
}

sl_recovery_new() {
  local mode=${1:-install}
  case "$mode" in install|repair) ;; *) mode=install ;; esac
  SL_RECOVERY_LINES=(secure-linux-setup-journal-v1 "run|active|$mode")
  mkdir -p "$SL_STATE" "$SL_RECOVERY_ARTIFACT_DIR" || return 1
  chmod 0700 "$SL_RECOVERY_ARTIFACT_DIR" 2>/dev/null || true
  sl_recovery_journal_write
}

sl_recovery_reset() {
  rm -f "$SL_RECOVERY_JOURNAL" "$SL_RECOVERY_JOURNAL.tmp."* 2>/dev/null || true
  rm -rf "$SL_RECOVERY_ARTIFACT_DIR"
  SL_RECOVERY_LINES=()
}

sl_recovery_record_index() {
  local wanted=$1 i line
  for i in "${!SL_RECOVERY_LINES[@]}"; do
    line=${SL_RECOVERY_LINES[$i]}
    case "$line" in stage\|"$wanted"\|*) printf '%s' "$i"; return 0 ;; esac
  done
  return 1
}

sl_recovery_manifest_path() { printf '%s/%s.manifest' "$SL_RECOVERY_ARTIFACT_DIR" "$1"; }

sl_recovery_manifest_write() {
  local stage=$1 path hash tmp
  local manifest; manifest=$(sl_recovery_manifest_path "$stage")
  mkdir -p "$SL_RECOVERY_ARTIFACT_DIR" || return 1
  : > "$SL_RECOVERY_ARTIFACT_DIR/.current.$$"
  for path in "${SL_RECOVERY_ARTIFACT_PATHS[@]}"; do
    [ -f "$path" ] && [ ! -L "$path" ] || return 1
    hash=$(sha256sum "$path" | cut -d' ' -f1) || return 1
    sl_recovery_valid_hash "$hash" || return 1
    printf '%s|%s\n' "$path" "$hash" >> "$SL_RECOVERY_ARTIFACT_DIR/.current.$$"
  done
  mv -f "$SL_RECOVERY_ARTIFACT_DIR/.current.$$" "$manifest" || return 1
  chmod 0600 "$manifest"; sl_recovery_sync "$manifest"
}

# Called by sl_write_file for system artifacts. Home, installer temporary files
# and recovery state itself are deliberately excluded from the manifests.
sl_recovery_artifact_add() {
  [ -n "$SL_RECOVERY_CURRENT_STAGE" ] || return 0
  local path=$1 existing
  case "$path" in
    /*) ;;
    *) return 0 ;;
  esac
  case "$path" in
    /home/*|/root/*|"$SL_RECOVERY_JOURNAL"*|"${SL_RECOVERY_JOURNAL%/*}/firstboot.done"|"$SL_RECOVERY_ARTIFACT_DIR"/*) return 0 ;;
    /tmp/*)
      # A recovery test's complete fake target may itself live under /tmp.
      # Track only that explicitly declared target, never real installer scratch.
      [ -n "${SL_RECOVERY_TEST_ROOT:-}" ] || return 0
      case "$path" in "$SL_RECOVERY_TEST_ROOT"/*) ;; *) return 0 ;; esac ;;
  esac
  case "$path" in *$'\n'*|*$'\r'*|*'|'*) return 1 ;; esac
  for existing in "${SL_RECOVERY_ARTIFACT_PATHS[@]}"; do [ "$existing" = "$path" ] && return 0; done
  SL_RECOVERY_ARTIFACT_PATHS+=("$path")
}

sl_recovery_stage_running() {
  local stage=$1 script=$2 idx
  sl_recovery_valid_stage "$stage" || return 1
  SL_RECOVERY_CURRENT_HASH=$(sha256sum "$script" | cut -d' ' -f1) || return 1
  sl_recovery_valid_hash "$SL_RECOVERY_CURRENT_HASH" || return 1
  SL_RECOVERY_CURRENT_STAGE=$stage
  SL_RECOVERY_CURRENT_POLICY=restart-only
  SL_RECOVERY_ARTIFACT_PATHS=()
  if idx=$(sl_recovery_record_index "$stage"); then
    SL_RECOVERY_LINES=("${SL_RECOVERY_LINES[@]:0:$idx}")
  elif [ "${#SL_RECOVERY_LINES[@]}" -gt 2 ]; then
    local last=$((${#SL_RECOVERY_LINES[@]} - 1))
    case "${SL_RECOVERY_LINES[$last]}" in
      stage\|*\|running\|*|stage\|*\|failed\|*) SL_RECOVERY_LINES=("${SL_RECOVERY_LINES[@]:0:$last}") ;;
    esac
  fi
  local empty; empty=$(sl_recovery_empty_hash)
  SL_RECOVERY_LINES+=("stage|$stage|running|restart-only|$SL_RECOVERY_CURRENT_HASH|$empty")
  sl_recovery_journal_write
}

sl_recovery_stage_finished() {
  local stage=$1 status=$2 policy=$3 manifest hash idx empty
  [ "$SL_RECOVERY_CURRENT_STAGE" = "$stage" ] || return 1
  case "$status" in completed|failed) ;; *) return 1 ;; esac
  case "$policy" in idempotent|restart-only) ;; *) return 1 ;; esac
  sl_recovery_manifest_write "$stage" || return 1
  manifest=$(sl_recovery_manifest_path "$stage")
  hash=$(sha256sum "$manifest" | cut -d' ' -f1) || return 1
  idx=$(sl_recovery_record_index "$stage") || return 1
  SL_RECOVERY_LINES[$idx]="stage|$stage|$status|$policy|$SL_RECOVERY_CURRENT_HASH|$hash"
  sl_recovery_journal_write || return 1
  SL_RECOVERY_CURRENT_STAGE=
  SL_RECOVERY_ARTIFACT_PATHS=()
}

sl_recovery_stage_completed() { sl_recovery_stage_finished "$1" completed "$2"; }
sl_recovery_stage_failed() { sl_recovery_stage_finished "$1" failed restart-only; }

# Set SL_RECOVERY_REASON and return success only when every check permits a skip.
sl_recovery_should_skip() {
  local stage=$1 script=$2 idx record kind name status policy script_hash manifest_hash extra
  SL_RECOVERY_REASON=
  idx=$(sl_recovery_record_index "$stage") || { SL_RECOVERY_REASON='No completed checkpoint exists; starting this stage.'; return 1; }
  record=${SL_RECOVERY_LINES[$idx]}
  IFS='|' read -r kind name status policy script_hash manifest_hash extra <<< "$record"
  [ "$status" = completed ] || { SL_RECOVERY_REASON='This stage was interrupted or failed; restarting it.'; return 1; }
  [ "$policy" = idempotent ] || { SL_RECOVERY_REASON='This stage is restart-only; it will not be blindly resumed.'; return 1; }
  local current manifest
  current=$(sha256sum "$script" | cut -d' ' -f1)
  [ "$current" = "$script_hash" ] || { SL_RECOVERY_REASON='The stage script changed; restarting the stage instead of skipping it.'; return 1; }
  manifest=$(sl_recovery_manifest_path "$stage")
  [ -f "$manifest" ] && [ ! -L "$manifest" ] || { SL_RECOVERY_REASON='The artifact manifest is missing; restarting the stage.'; return 1; }
  current=$(sha256sum "$manifest" | cut -d' ' -f1)
  [ "$current" = "$manifest_hash" ] || { SL_RECOVERY_REASON='The artifact manifest changed; restarting the stage.'; return 1; }
  [ -s "$manifest" ] || { SL_RECOVERY_REASON='There are no artifacts to validate; restarting the stage.'; return 1; }
  local path hash n=0
  declare -A paths=()
  while IFS='|' read -r path hash extra; do
    n=$((n + 1))
    case "$path" in /*) ;; *) SL_RECOVERY_REASON='The artifact manifest is invalid; restarting the stage.'; return 1 ;; esac
    [ -z "${extra:-}" ] && sl_recovery_valid_hash "$hash" && [ -z "${paths[$path]:-}" ] || {
      SL_RECOVERY_REASON='The artifact manifest is invalid; restarting the stage.'; return 1; }
    paths[$path]=1
    [ -f "$path" ] && [ ! -L "$path" ] || { SL_RECOVERY_REASON='A recorded artifact is missing; restarting the stage.'; return 1; }
    current=$(sha256sum "$path" | cut -d' ' -f1)
    [ "$current" = "$hash" ] || { SL_RECOVERY_REASON='A recorded artifact changed; restarting the stage.'; return 1; }
  done < "$manifest"
  [ "$n" -gt 0 ] || { SL_RECOVERY_REASON='There are no artifacts to validate; restarting the stage.'; return 1; }
  return 0
}

sl_recovery_mark_run_failed() {
  [ "${#SL_RECOVERY_LINES[@]}" -ge 2 ] || return 0
  local mode=${SL_RECOVERY_LINES[1]##*|}
  SL_RECOVERY_LINES[1]="run|failed|$mode"
  sl_recovery_journal_write
}

sl_recovery_finish() {
  rm -f "$SL_RECOVERY_JOURNAL"
  rm -rf "$SL_RECOVERY_ARTIFACT_DIR"
  SL_RECOVERY_LINES=()
}
