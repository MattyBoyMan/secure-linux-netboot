# shellcheck shell=bash
# Wizard page (comfort): loose ends from Windows - video projects, Adobe, MATLAB licence.
page_title() { echo "Loose ends from Windows"; }
page_run() {
  . "$SL_ROOT/files/comfort/comfort-lib.sh"
  wz_is_done comfort-before && return 0
  local missing=() a
  wz_yesno "Did you export your Clipchamp videos and projects before switching?" || missing+=(clipchamp)
  wz_yesno "Did you export your CapCut projects (or finished videos)?" || missing+=(capcut)
  wz_yesno "Did you cancel (or move) any Adobe subscription you no longer need?" || missing+=(adobe)
  wz_yesno "Did you release your MATLAB licence from the old Windows install?" || missing+=(matlab)
  if [ ${#missing[@]} -eq 0 ]; then
    wz_info "Brilliant: nothing left behind."
    wz_done comfort-before; return 0
  fi
  local text="No stress: here's how to sort each one from this laptop."
  for a in "${missing[@]}"; do
    case $a in
      clipchamp) text+="

Clipchamp: projects live in your Microsoft account online. Sign in at clipchamp.com in the browser (Clipchamp works in Chromium-based browsers: use Ungoogled Chromium here), open each project and Export it as an MP4. For new videos, use Kdenlive (installed): it's free and does everything Clipchamp did, and more." ;;
      capcut) text+="

CapCut: there's no Linux app. Projects synced to CapCut's cloud open at capcut.com in the browser; export them as MP4 there. Local-only projects were copied by the Windows backup into the \"CapCut-Projects\" folder, but they can only be opened by CapCut itself. For new videos, Kdenlive is the closest match (templates and effects work differently)." ;;
      adobe) text+="

Adobe: cancel at account.adobe.com > Plans (annual plans can have an early-cancellation fee: Adobe's page shows it before you confirm). Replacements already installed: GIMP and Krita (Photoshop), Inkscape (Illustrator), Darktable (Lightroom), Kdenlive (Premiere)." ;;
      matlab) text+="

MATLAB: sign in at mathworks.com > My Account > Licenses, open your licence, and \"Deactivate\" the old Windows computer. Then activate on this laptop (see \"Study and coding tools\")." ;;
    esac
  done
  wz_info "$text"
  a=$(wz_choice "Open the websites now?" "Yes, open them" "No, later")
  if [ "$a" = "Yes, open them" ]; then
    for a in "${missing[@]}"; do
      case $a in
        clipchamp) wz_open "https://app.clipchamp.com" ;; capcut) wz_open "https://www.capcut.com" ;;
        adobe) wz_open "https://account.adobe.com/plans" ;; matlab) wz_open "https://www.mathworks.com/mwaccount/" ;;
      esac
    done
  fi
  wz_done comfort-before
  return 0
}
