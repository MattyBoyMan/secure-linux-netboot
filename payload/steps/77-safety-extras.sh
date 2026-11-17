# shellcheck shell=bash
# 77-safety-extras: open a file or link safely (throw-away sandbox), travel mode and the panic lock. Owned by: safety.
# Sourced by setup.sh. Safe to run again (repair): files already in place are left alone.
#   The three tools, their menu entries, the travel-mode start-up service, the home server folder's travel-mode
#   check (files/safety/systemd/system/media-homeserver.*.d/) and the password prompts
#   (files/system/polkit/org.securelinux.safety.policy) are installed by 00-early.sh like every other area.
#   This step adds what 00-early does not: the sandbox program (bubblewrap), the network helper for links (passt),
#   the "Open Safely" entry in the
#   file manager's right-click menu, and the keyboard shortcut for the panic lock (Meta+Ctrl+L, KDE).
[ "$SL_MODE" = early ] && return 0
sl_step "Adding the safety tools (open safely, travel mode, panic lock)"
_sf77_d=${SL_TEST_SYSROOT:-}
# bubblewrap is the small free program that builds the sandbox. It usually comes with Flatpak already; this only
# adds it when it is missing (online first, then the verified offline copy). The atomic setup cannot add packages
# here (sl_dnf_install skips there), so on atomic the sandbox says plainly when bubblewrap is missing.
if [ ! -x "$_sf77_d/usr/bin/bwrap" ]; then
  sl_dnf_install bubblewrap || echo "The sandbox program could not be added this time. Secure Linux will try again in the next repair."
fi
# passt (its program pasta) gives a link opened safely a network of its own that reaches the internet only, never the
# home network or this computer's own programs (check C4 F6). Without it the sandbox opens files but not links.
if [ ! -x "$_sf77_d/usr/bin/pasta" ]; then
  sl_dnf_install passt || echo "The network helper for opening links safely could not be added this time. Secure Linux will try again in the next repair."
fi
# atomic: /usr is read-only, so the extras go below /usr/local/share (KDE looks there too)
if sl_is_atomic; then _sf77_share=/usr/local/share; else _sf77_share=/usr/share; fi
sl_install_file "$SL_ROOT/files/safety/kde/secure-linux-open-safely.desktop" \
  "$_sf77_d$_sf77_share/kio/servicemenus/secure-linux-open-safely.desktop" 0755 \
  || echo "FAILED: install the Open Safely menu entry" | tee -a "$SL_FAILS" >&2
sl_install_file "$SL_ROOT/files/safety/applications/secure-linux-panic-lock.desktop" \
  "$_sf77_d$_sf77_share/kglobalaccel/secure-linux-panic-lock.desktop" 0644 \
  || echo "FAILED: install the panic lock shortcut" | tee -a "$SL_FAILS" >&2
unset _sf77_d _sf77_share
return 0
