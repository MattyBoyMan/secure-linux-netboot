#!/usr/bin/env python3
"""The "your login" step of the network installer (netboot), as one reusable function.

The USB builder bakes a person's login name and password hash into the installer it writes.
A public installer file on the internet can hold neither, so the netboot installer asks for them
on the setup screen instead. This module turns the USB-style Fedora installer text
(templates/fedora.ks) into that asking version by making three exact-match changes:

  1. the baked-in "user ..." line becomes "%include /tmp/user.ks";
  2. the step count goes up by one;
  3. the "your login" step itself is added before the install plan is written.

Every change needs its anchor text to be in the file exactly once. If the template has moved on
and an anchor is missing (or there twice, or the step is already there), apply_account_step
stops with an AccountStepError and a plain message. It never guesses and never half-applies.

It is plain standard-library Python so the drive builder can use it on any computer.
The text keeps the placeholder __SHA512CRYPT_PY__, which the caller fills in with the
kit's pure-Python SHA-512 hasher (tests/sha512crypt.py).
"""
from __future__ import annotations

__all__ = ["AccountStepError", "apply_account_step", "ANCHOR_USER_LINE", "ANCHOR_STEP_COUNT", "ANCHOR_PLAN"]

STEP_MARKER = "# ---------------------------------------------------------------- netboot: your login account"

ANCHOR_USER_LINE = "user --name=__USERNAME__ --gecos=__FULLNAME__ --groups=wheel --iscrypted --password=__PASSWORD_HASH__"
ANCHOR_STEP_COUNT = '[ "$WIFI_STEP" = 1 ] && TOTAL=$((TOTAL + 1))'
ANCHOR_PLAN = "# ---------------------------------------------------------------- write the install plan (in memory only)"

_USER_LINE_NEW = "%include /tmp/user.ks   # netboot: the setup screen asks for the login name and password and writes this file"
_STEP_COUNT_NEW = (
    ANCHOR_STEP_COUNT + "\n"
    "TOTAL=$((TOTAL + 1))   # netboot: the account step (the login name and password are asked, never baked in)"
)

_ACCOUNT_BLOCK = '''# ---------------------------------------------------------------- netboot: your login account
# (This block exists only in the netboot build.) The USB build bakes the login name and a password
# hash into the installer when the stick is made; a public file on the internet can hold neither,
# so the netboot installer asks here instead. The password is turned into a one-way SHA-512 crypt
# hash right away, with the kit's own pure-Python hasher (tests/sha512crypt.py - the installer's
# Python 3.13 has no crypt module, and openssl may not be in the installer image). Only the hash is
# written down (/tmp/user.ks); the typed password lives in shell variables that are cleared below,
# is never logged and never sent anywhere.
N=$((N + 1))
header "your login"
echo "   STEP $N of $TOTAL: your login"
echo
echo "   Make the login for this computer. The name appears on the login screen; the"
echo "   password is what you type to sign in (and for admin tasks with sudo)."
echo
while true; do
  answer "Your name (shown on the login screen):"
  NB_FULL=$REPLY_TEXT
  case "$NB_FULL" in *:*|*'"'*|*\\\\*) echo "   Please no colons, quotes or backslashes." ;; *) break ;; esac
done
while true; do
  answer "Login name (small letters, e.g. alex):"
  NB_USER=$(printf '%s' "$REPLY_TEXT" | tr 'A-Z' 'a-z')
  case "$NB_USER" in ''|*[!a-z0-9_-]*) echo "   Small letters, digits, '-' and '_' only."; continue ;; esac
  case "$NB_USER" in [a-z_]*) ;; *) echo "   The first character must be a small letter or '_'."; continue ;; esac
  [ ${#NB_USER} -le 32 ] || { echo "   32 characters at most."; continue; }
  break
done
echo
echo "   The password: 8 or more characters, plain English-keyboard letters, numbers"
echo "   and symbols only (no accents or emoji - some screens use a different keyboard"
echo "   layout, so special letters could become impossible to type)."
echo
while true; do
  printf '   Login password: '; read -rs NB_P1 || cancel; echo
  printf '   Type it again:  '; read -rs NB_P2 || cancel; echo
  if [ "$NB_P1" != "$NB_P2" ]; then echo "   They don't match. Try again."; NB_P1=""; NB_P2=""; continue; fi
  if [ ${#NB_P1} -lt 8 ]; then echo "   Too short: use at least 8 characters."; NB_P1=""; NB_P2=""; continue; fi
  if (LC_ALL=C; case "$NB_P1" in *[!\\ -~]*) exit 0 ;; *) exit 1 ;; esac); then
    echo "   Only plain English-keyboard characters, please (no accents or emoji)."; NB_P1=""; NB_P2=""; continue
  fi
  break
done
cat > /tmp/sl_sha512crypt.py <<'SHA512CRYPT_END'
__SHA512CRYPT_PY__
SHA512CRYPT_END
NB_SALT=$(od -An -N12 -tx1 /dev/urandom | tr -d ' \\n' | cut -c1-16)
NB_HASH=$(NB_PW=$NB_P1 NB_SALT=$NB_SALT python3 -c 'import os,sys; sys.path.insert(0,"/tmp"); from sl_sha512crypt import sha512_crypt; sys.stdout.write(sha512_crypt(os.environ["NB_PW"].encode(), os.environ["NB_SALT"].encode()))')
NB_P1=""; NB_P2=""; rm -f /tmp/sl_sha512crypt.py
case "$NB_HASH" in \\$6\\$????????????????\\$*) ;; *) echo "   Could not hash the password (the installer is missing python3)."; cancel ;; esac
umask 077
QFN=${NB_FULL//\\\\/\\\\\\\\}; QFN=${QFN//\\"/\\\\\\"}
printf 'user --name=%s --gecos="%s" --groups=wheel --iscrypted --password=%s\\n' "$NB_USER" "$QFN" "$NB_HASH" > /tmp/user.ks
printf 'sl_username=%s\\n' "$NB_USER" >> /tmp/secure-linux-choices
umask 022
NB_HASH=""; NB_SALT=""; NB_FULL=""

'''


class AccountStepError(ValueError):
    """The installer text does not look the way this step expects. The message says what and why."""


def _replace_once(text: str, old: str, new: str, what: str) -> str:
    found = text.count(old)
    if found != 1:
        raise AccountStepError(
            "templates/fedora.ks no longer matches the network-install render: %s "
            "(%d matches, expected 1). The installer template changed; update "
            "linux/lib/ks_account_step.py to match it." % (what, found)
        )
    return text.replace(old, new)


def apply_account_step(ks_text: str) -> str:
    """Return ks_text with the netboot "your login" step added. Raises AccountStepError on any drift."""
    if not isinstance(ks_text, str):
        raise AccountStepError("the installer text must be text, not %s" % type(ks_text).__name__)
    if STEP_MARKER in ks_text:
        raise AccountStepError("the 'your login' step is already in this installer text; it is added only once")
    # Check all three anchors before changing anything, so a failure never leaves a half-made result.
    for anchor, what in ((ANCHOR_USER_LINE, "user line"), (ANCHOR_STEP_COUNT, "step count"),
                         (ANCHOR_PLAN, "account step insertion point")):
        _replace_once(ks_text, anchor, anchor, what)
    ks_text = _replace_once(ks_text, ANCHOR_USER_LINE, _USER_LINE_NEW, "user line")
    ks_text = _replace_once(ks_text, ANCHOR_STEP_COUNT, _STEP_COUNT_NEW, "step count")
    ks_text = _replace_once(ks_text, ANCHOR_PLAN, _ACCOUNT_BLOCK + ANCHOR_PLAN, "account step insertion point")
    return ks_text
