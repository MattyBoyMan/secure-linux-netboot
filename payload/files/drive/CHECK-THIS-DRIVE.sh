#!/bin/sh
# CHECK THIS DRIVE - is this Secure Linux drive still exactly as it was made?
#
# How to use it: open a terminal in this drive's top folder and type   sh CHECK-THIS-DRIVE.sh
# (on a Secure Linux or other Linux computer; a Mac works too when python3 is installed).
#
# It only READS the drive: nothing is written, changed or "fixed". It runs the drive's own checker,
# linux-setup/linux/bin/secure-linux-check-drive, which checks the Secure Linux files against the signed
# release and every other file against the drive's own file list. Answer: 0 = good, 2 = problem.
# (Contract C5. The drive builders copy this file from the kit's linux/files/drive/ to the drive's top.)
set -u

here=$(CDPATH= cd -- "$(dirname -- "$0")" 2>/dev/null && pwd -P) || here=
if [ -z "$here" ] || [ ! -d "$here" ]; then
  echo "RESULT: PROBLEM - I could not find the drive this file is on. Open a terminal in the drive's top folder and type: sh CHECK-THIS-DRIVE.sh"
  exit 2
fi
checker="$here/linux-setup/linux/bin/secure-linux-check-drive"
if [ ! -f "$checker" ]; then
  echo "RESULT: PROBLEM - this drive's checking tool is missing (linux-setup/linux/bin/secure-linux-check-drive)."
  echo "The drive is not complete. Make it again with the drive builder. Nothing on the drive was changed."
  exit 2
fi
python=
for name in python3 python; do
  if command -v "$name" >/dev/null 2>&1 && "$name" -c 'import sys; sys.exit(0 if sys.version_info >= (3, 8) else 1)' >/dev/null 2>&1; then
    python=$name
    break
  fi
done
if [ -z "$python" ]; then
  echo "RESULT: PROBLEM - this computer has no Python 3, so the drive could not be checked here."
  echo "Run this check on a Secure Linux computer (Python 3 is always installed there). Nothing on the drive was changed."
  exit 2
fi
# -B and PYTHONDONTWRITEBYTECODE: Python must not leave __pycache__ folders on the drive.
PYTHONDONTWRITEBYTECODE=1 "$python" -B "$checker" --drive "$here" "$@"
answer=$?
case "$answer" in
  0) exit 0 ;;
  64) exit 64 ;;
  *) exit 2 ;;
esac
