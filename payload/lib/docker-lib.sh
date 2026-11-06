# shellcheck shell=bash
# Docker capability check, shared by the setup step and welcome page.
# Tests may provide measurements; a real install never sets these variables.
SL_DOCKER_MIN_RAM_MB=4096
SL_DOCKER_MIN_CPUS=2
SL_DOCKER_MIN_FREE_GB=20
SL_DOCKER_REASON=""
SL_DOCKER_RAM_MB=0
SL_DOCKER_CPUS=0
SL_DOCKER_FREE_GB=0

_sl_docker_number() { case "${1:-}" in ''|*[!0-9]*) return 1 ;; *) return 0 ;; esac; }

sl_docker_measurements() {
  SL_DOCKER_RAM_MB=${SL_TEST_DOCKER_RAM_MB:-}
  if ! _sl_docker_number "$SL_DOCKER_RAM_MB"; then
    SL_DOCKER_RAM_MB=$(awk '/^MemTotal:/ {printf "%d", $2 / 1024}' "${SL_TEST_PROC:-/proc}/meminfo" 2>/dev/null)
  fi
  SL_DOCKER_CPUS=${SL_TEST_DOCKER_CPUS:-}
  if ! _sl_docker_number "$SL_DOCKER_CPUS"; then
    SL_DOCKER_CPUS=$(getconf _NPROCESSORS_ONLN 2>/dev/null || nproc 2>/dev/null || echo 0)
  fi
  SL_DOCKER_FREE_GB=${SL_TEST_DOCKER_FREE_GB:-}
  if ! _sl_docker_number "$SL_DOCKER_FREE_GB"; then
    SL_DOCKER_FREE_GB=$(df -Pk "${SL_TEST_SYSROOT:-}/" 2>/dev/null | awk 'END {printf "%d", $4 / 1048576}')
  fi
  _sl_docker_number "$SL_DOCKER_RAM_MB" || SL_DOCKER_RAM_MB=0
  _sl_docker_number "$SL_DOCKER_CPUS" || SL_DOCKER_CPUS=0
  _sl_docker_number "$SL_DOCKER_FREE_GB" || SL_DOCKER_FREE_GB=0
}

sl_docker_check() {
  sl_docker_measurements
  SL_DOCKER_REASON=""
  case "$(sl_arch)" in
    x86_64|amd64|aarch64|arm64|s390x) ;;
    *) SL_DOCKER_REASON="Docker's official packages need a supported 64-bit computer; this one is $(sl_arch)." ; return 1 ;;
  esac
  [ "$SL_DOCKER_RAM_MB" -ge "$SL_DOCKER_MIN_RAM_MB" ] || {
    SL_DOCKER_REASON="Docker needs at least $SL_DOCKER_MIN_RAM_MB MB of memory; this computer has $SL_DOCKER_RAM_MB MB."; return 1; }
  [ "$SL_DOCKER_CPUS" -ge "$SL_DOCKER_MIN_CPUS" ] || {
    SL_DOCKER_REASON="Docker needs at least $SL_DOCKER_MIN_CPUS processor cores; this computer has $SL_DOCKER_CPUS."; return 1; }
  [ "$SL_DOCKER_FREE_GB" -ge "$SL_DOCKER_MIN_FREE_GB" ] || {
    SL_DOCKER_REASON="Docker needs at least $SL_DOCKER_MIN_FREE_GB GB of free storage; this computer has $SL_DOCKER_FREE_GB GB."; return 1; }
  return 0
}

sl_docker_report() {
  sl_docker_measurements
  printf 'This computer: %s MB memory, %s processor cores, %s GB free storage.\n' \
    "$SL_DOCKER_RAM_MB" "$SL_DOCKER_CPUS" "$SL_DOCKER_FREE_GB"
  printf 'Docker needs: at least %s MB memory, %s processor cores and %s GB free storage, on a supported 64-bit computer.\n' \
    "$SL_DOCKER_MIN_RAM_MB" "$SL_DOCKER_MIN_CPUS" "$SL_DOCKER_MIN_FREE_GB"
}
