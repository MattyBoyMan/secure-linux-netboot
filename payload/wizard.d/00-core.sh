# shellcheck shell=bash
# Shared five-screen first-run wizard. Source after common.sh and the host wizard's UI helpers.
# Non-secret answers live in JSON in this process. Secrets have separate shell variables and are
# never added to SL_WIZARD_VALUES, review text, choice files, command logs or the setup journal.
[ -n "${SL_FIVE_WIZARD_LOADED:-}" ] && return 0
SL_FIVE_WIZARD_LOADED=1
SL_WIZARD_SCREEN_DIR=$SL_ROOT/wizard.d
SL_WIZARD_CONTEXT=${SL_WIZARD_CONTEXT:-{}}
SL_WIZARD_VALUES='{}'
SL_WIZARD_LAST='{}'
SL_WIZARD_SCREEN_COUNT=0
declare -A SL_WIZARD_SECRET=()

sl_wizard_get() { # sl_wizard_get KEY [DEFAULT]
  python3 -c 'import json,sys; print(json.load(sys.stdin).get(sys.argv[1],sys.argv[2]))' "${1}" "${2:-}" <<< "$SL_WIZARD_VALUES"
}
sl_wizard_list() { # sl_wizard_list KEY -> comma-separated allow-listed ids
  python3 -c 'import json,sys; v=json.load(sys.stdin).get(sys.argv[1],[]); print(",".join(v) if isinstance(v,list) else "")' "$1" <<< "$SL_WIZARD_VALUES"
}
sl_wizard_selected() { # sl_wizard_selected LIST_KEY VALUE
  python3 -c 'import json,sys; v=json.load(sys.stdin).get(sys.argv[1],[]); sys.exit(0 if sys.argv[2] in v else 1)' "$1" "$2" <<< "$SL_WIZARD_VALUES"
}
sl_wizard_yes() { [ "$(sl_wizard_get "$1" no)" = yes ] || [ "$(sl_wizard_get "$1" False)" = True ]; }

sl_wizard_scan() {
  local profile login full ssid wifi_saved=0 docker_ok=0 docker_reason="" encryption="" app_report="" app_json='{"recommendations":[],"gaps":[]}'
  local security_json='{}' backend=${SL_WIZARD_SECURITY_BACKEND:-$SL_ROOT/lib/control-center-backend.py}
  profile=$(sl_profile); login=${USER:-$(sl_user)}
  full=$(getent passwd "$login" 2>/dev/null | cut -d: -f5 | cut -d, -f1); full=${full:-$login}
  if declare -F current_ssid >/dev/null; then ssid=$(current_ssid); else ssid=$(nmcli -t -f active,ssid dev wifi 2>/dev/null | sed -n 's/^yes://p' | head -1); fi
  { [ -s "$SL_STATE/wifi-record" ] || [ -s "$SL_STATE/wifi-staged" ]; } && wifi_saved=1
  if [ -r "$SL_ROOT/lib/docker-lib.sh" ]; then
    . "$SL_ROOT/lib/docker-lib.sh"
    if sl_docker_check; then docker_ok=1; else docker_reason=$SL_DOCKER_REASON; fi
  fi
  if command -v lsblk >/dev/null 2>&1 && lsblk -rno FSTYPE 2>/dev/null | grep -q crypto_LUKS; then
    encryption="Encrypted system disk detected. The recovery-key step is recommended; disk and erase decisions stay in the installer."
  else
    encryption="No encrypted system disk was detected. Encryption and any erase decision remain explicit installer gates; this wizard never changes a disk."
  fi
  if [ -r "$SL_ROOT/setup-data/app-scan.py" ] && [ -r "$SL_ROOT/setup-data/app-equivalents.tsv" ]; then
    local record="" f u=${USER:-$(id -un)}
    if [ -n "${SL_APP_SCAN_FILE:-}" ] && [ -f "$SL_APP_SCAN_FILE" ]; then record=$SL_APP_SCAN_FILE; else
      for f in ${SL_APP_SCAN_DIR:+"$SL_APP_SCAN_DIR"/apps-*.json} "$HOME/linux-setup/scan"/apps-*.json "$HOME/scan"/apps-*.json \
               "/run/media/$u"/*/linux-setup/scan/apps-*.json "/run/media/$u"/*/scan/apps-*.json; do
        [ -f "$f" ] && { record=$f; break; }
      done
    fi
    if [ -n "$record" ]; then
      app_report=$(python3 "$SL_ROOT/setup-data/app-scan.py" match --database "$SL_ROOT/setup-data/app-equivalents.tsv" \
        --record "$record" --profile "${profile/atomic/full}" --format shell 2>/dev/null || true)
    fi
  fi
  app_json=$(SL_WIZARD_APP_REPORT=$app_report python3 -c 'import json,os
r=[]; g=[]
for line in os.environ.get("SL_WIZARD_APP_REPORT","").splitlines():
 p=line.split("\t")
 if len(p)>5 and p[0]=="RECOMMEND": r.append({"id":p[1],"label":p[3]+" — replaces "+p[2]})
 if len(p)>3 and p[0]=="GAP": g.append(p[2]+": "+p[3])
print(json.dumps({"recommendations":r,"gaps":g}))')
  if [ -r "$backend" ]; then security_json=$(python3 "$backend" status 2>/dev/null || echo '{}'); fi
  SL_WIZARD_CONTEXT=$(SL_SCAN_DISTRO=${SL_WIZARD_DISTRO:-fedora} SL_SCAN_PROFILE=$profile SL_SCAN_LOGIN=$login SL_SCAN_FULL=$full SL_SCAN_SSID=$ssid \
    SL_SCAN_WIFI_SAVED=$wifi_saved SL_SCAN_DOCKER_OK=$docker_ok SL_SCAN_DOCKER_REASON=$docker_reason \
    SL_SCAN_ENCRYPTION=$encryption SL_SCAN_APP=$app_json SL_SCAN_SECURITY=$security_json python3 -c 'import json,os
try: app=json.loads(os.environ["SL_SCAN_APP"])
except Exception: app={"recommendations":[],"gaps":[]}
try: sec=json.loads(os.environ["SL_SCAN_SECURITY"])
except Exception: sec={}
features=[]
for name,raw in sec.get("features",{}).items():
 if raw.get("manageable") and (raw.get("can_disable") or not raw.get("supported")): features.append(name)
if not features: features=["firewall","opensnitch","dns","updates","clamav","fail2ban","screen_lock","vpn","auditd"]
ram=os.environ.get("SL_TEST_RAM_GB","")
summary="System profile, current Wi-Fi, old-app record, encryption and hardware capabilities checked without a question."
if ram: summary+=" Memory: "+ram+" GB."
print(json.dumps({"distro":os.environ["SL_SCAN_DISTRO"],"profile":os.environ["SL_SCAN_PROFILE"],"login":os.environ["SL_SCAN_LOGIN"],"full_name":os.environ["SL_SCAN_FULL"],"ssid":os.environ["SL_SCAN_SSID"],"wifi_saved":os.environ["SL_SCAN_WIFI_SAVED"]=="1","docker_ok":os.environ["SL_SCAN_DOCKER_OK"]=="1","docker_reason":os.environ["SL_SCAN_DOCKER_REASON"],"encryption":os.environ["SL_SCAN_ENCRYPTION"],"app_recommendations":app["recommendations"],"app_gaps":app["gaps"],"security_features":features,"scan_summary":summary}))')
}

sl_wizard_review() {
  python3 -c 'import json,os,sys
v=json.load(sys.stdin); lines=[]
try: context=json.loads(os.environ.get("SL_WIZARD_CONTEXT","{}"))
except Exception: context={}
labels={"browser":"Private browser and desktop settings","apps":"Applications and old-app gap-fill","security":"Protection","backup":"Backup setup","recovery":"Disk recovery key","battery":"Battery charge limit","hardware":"Hardware health check"}
if context.get("distro")=="debian": labels.pop("battery",None)
steps=v.get("steps",[])
lines.append("RECOMMENDED SYSTEM AND STEPS")
for key,label in labels.items(): lines.append(("  ON  " if key in steps else "  OFF ")+label)
lines+=["","ACCOUNT AND MIGRATION","  Name: "+str(v.get("full_name","")),"  Login: "+str(v.get("login",""))+" (unchanged)","  Login password: "+("change requested; value not shown" if v.get("password_changed") else "keep current"),"  Wi-Fi: "+str(v.get("wifi_mode","skip"))]
if context.get("distro")!="debian": lines+=["  Password migration: "+str(v.get("password_manager","none")),"  Bookmarks: "+str(bool(v.get("bookmarks",False)))]
lines+=["","APPLICATIONS AND PROTECTION"]
if context.get("distro")=="debian": lines.append("  Included apps: browser, email, office, video and password manager")
else:
 for key in ("email_client","office","notes_app"): lines.append("  "+key.replace("_"," ")+": "+str(v.get(key,"")))
for key in ("backup_target","security_profile"): lines.append("  "+key.replace("_"," ")+": "+str(v.get(key,"")))
lines.append("  Old-app additions: "+(", ".join(v.get("extra_apps",[])) or "none"))
for name,label in (("firewall","Firewall"),("opensnitch","App network protection"),("dns","Secure DNS"),("vpn","VPN private mode"),("updates","Security updates"),("clamav","Virus scans"),("fail2ban","Login protection"),("screen_lock","Screen lock"),("auditd","Audit log"),("usbguard","USBGuard")):
 if name in context.get("security_features",[]) or name in v.get("security",[]): lines.append(("  ON  " if name in v.get("security",[]) else "  OFF (reduction) ")+label)
lines+=["","OPTIONAL EXTRAS"]
extra=False
for key in sorted(v):
 if key in {"home_assistant","docker","display_scale","hibernate","matlab"} and v[key] not in {None,"none","no","100",""}: lines.append("  "+key.replace("_"," ")+": "+str(v[key])); extra=True
 elif key in {"local_ai","flipper","fleet","drm","game_saves","android_dev","conda","extras_tools","extras_apps","onedrive","photos","printer","emergency","family","tips"} and v[key] is True: lines.append("  ON  "+key.replace("_"," ")); extra=True
 elif key in {"meetings","accessibility"} and v[key]: lines.append("  "+key+": "+", ".join(v[key])); extra=True
if not extra: lines.append("  None — every optional tool remains available later.")
lines+=["","Secrets are never shown here or written to the setup journal. Specialist account sign-ins, firmware, recovery and disk safety prompts remain explicit."]
print("\n".join(lines))' <<< "$SL_WIZARD_VALUES"
}

sl_wizard_store() {
  local action
  action=$(python3 -c 'import json,sys; print(json.load(sys.stdin).get("__action",""))' <<< "$SL_WIZARD_LAST") || return 1
  SL_WIZARD_ACTION=$action
  [ -z "$action" ] || return 0
  # A later screen must not clear secrets or password_changed stored by the identity screen.
  # Revisiting identity with blank fields still explicitly clears them.
  local k
  for k in password password_confirm wifi_pin; do
    if python3 -c 'import json,sys; sys.exit(0 if sys.argv[1] in json.load(sys.stdin) else 1)' "$k" <<< "$SL_WIZARD_LAST"; then
      SL_WIZARD_SECRET[$k]=$(python3 -c 'import json,sys; print(json.load(sys.stdin).get(sys.argv[1],""))' "$k" <<< "$SL_WIZARD_LAST") || return 1
    fi
  done
  SL_WIZARD_VALUES=$(SL_WIZARD_OLD_VALUES=$SL_WIZARD_VALUES python3 -c 'import json,os,sys
new=json.load(sys.stdin); old=json.loads(os.environ.get("SL_WIZARD_OLD_VALUES","{}")); new.pop("__action",None)
if "password" in new: old["password_changed"]=bool(new["password"])
for key in ("password","password_confirm","wifi_pin"): new.pop(key,None)
old.update(new); print(json.dumps(old,ensure_ascii=False))' <<< "$SL_WIZARD_LAST") || return 1
}

sl_wizard_show() { # sl_wizard_show SCREEN_KEY — exactly one screen per page
  SL_WIZARD_SCREEN_COUNT=$((SL_WIZARD_SCREEN_COUNT + 1))
  SL_WIZARD_REVIEW=$(sl_wizard_review)
  export SL_WIZARD_CONTEXT SL_WIZARD_VALUES SL_WIZARD_REVIEW
  SL_WIZARD_LAST=$(python3 "$SL_WIZARD_SCREEN_DIR/wizard-screen.py" "$1")
  sl_wizard_store
}

sl_wizard_root() { wz_root "$@"; }

sl_wizard_apply_identity() {
  local full login pw=${SL_WIZARD_SECRET[password]:-}
  full=$(sl_wizard_get full_name "$USER"); login=$(sl_wizard_get login "$USER")
  [ "$(sl_wizard_get password_changed no)" = yes ] || [ "$full" != "$(getent passwd "$login" 2>/dev/null | cut -d: -f5 | cut -d, -f1)" ] || return 0
  printf '%s\n' "$pw" | pkexec "$SELF" --set-identity "$login" "$full"
  SL_WIZARD_SECRET[password]=""; SL_WIZARD_SECRET[password_confirm]=""
}

sl_wizard_apply_choices() {
  local M=$SL_ROOT/bin/secure-linux-migrate todo=() value office
  [ -x "$M" ] || return 0
  if sl_wizard_selected steps apps; then
    todo+=("email_client=$(sl_wizard_get email_client thunderbird)")
    office=$(sl_wizard_get office libreoffice); [ "$office" = both ] && office=onlyoffice
    todo+=("office=$office" "notes_app=$(sl_wizard_get notes_app joplin)")
    value=$(sl_wizard_list extra_apps); todo+=("extra_apps=${value//,/ }")
    [ -n "$value" ] || todo[${#todo[@]}-1]="extra_apps=none"
    if [ "$(sl_profile)" = lite ]; then todo+=("backup_gui=deja-dup" "disk_usage=baobab" "disk_utility=gnome-disks"); fi
  fi
  [ "$(sl_wizard_get password_manager none)" = keepassxc ] && todo+=("keepassxc=yes")
  value=$(sl_wizard_list meetings); [ -n "$value" ] && todo+=("meetings=$value")
  value=$(sl_wizard_list accessibility); [ -n "$value" ] && todo+=("accessibility=$value")
  sl_wizard_yes game_saves && todo+=("game_saves=yes")
  sl_wizard_yes android_dev && todo+=("android_dev=yes")
  sl_wizard_yes conda && todo+=("conda=yes")
  sl_wizard_yes extras_tools && todo+=("extras_tools=yes")
  sl_wizard_yes extras_apps && todo+=("extras_apps=yes")
  value=$(sl_wizard_get matlab none); [ "$value" != none ] && todo+=("matlab=$value")
  [ ${#todo[@]} -gt 0 ] && sl_wizard_root "$M" install "${todo[@]}" || true
  value=$(sl_wizard_get display_scale 100); [ "$value" = 100 ] || {
    mkdir -p "$HOME/.config/secure-linux"; printf '%s\n' "$value" > "$HOME/.config/secure-linux/display-scale"
    CF_FIRST_LOGIN_DELAY=0 bash "$SL_ROOT/files/comfort/first-login.sh" --force scale >/dev/null 2>&1 || true; }
  value=$(sl_wizard_get hibernate no); [ "$value" = no ] || {
    sl_wizard_root "$SL_ROOT/bin/secure-linux-choice" set hibernate "$value" || true
    ui_terminal "$SL_ROOT/bin/secure-linux-hibernate" enable "$value"; }
  sl_wizard_yes drm && sl_wizard_root "$SL_ROOT/bin/secure-linux-choice" set drm yes || true
}

sl_wizard_apply_security() {
  sl_wizard_selected steps security || return 0
  local backend=${SL_WIZARD_SECURITY_BACKEND:-$SL_ROOT/lib/control-center-backend.py} feature desired features
  [ -r "$backend" ] || return 0
  features=$(python3 -c 'import json,sys; v=json.load(sys.stdin); print(" ".join(v.get("security_features",[])))' <<< "$SL_WIZARD_CONTEXT")
  for feature in $features; do
    if sl_wizard_selected security "$feature"; then desired=on; else desired=off; fi
    python3 "$backend" apply "$feature" "$desired" >/dev/null || echo "Protection step could not be verified: $feature" >&2
  done
}

sl_wizard_apply_builtin() {
  local target host url
  if sl_wizard_selected steps browser; then
    want default_browser librewolf; want librewolf_keep_cookies yes
    bash "$SL_EXP/user-setup.sh" browser librewolf >/dev/null 2>&1 || true
    bash "$SL_EXP/user-setup.sh" librewolf-prefs yes >/dev/null 2>&1 || true
  fi
  if sl_wizard_selected steps battery && "$SL_BIN/secure-linux-battery" supported >/dev/null 2>&1; then "$SL_BIN/secure-linux-battery" limit 80 || true; fi
  if sl_wizard_selected steps backup; then
    target=$(sl_wizard_get backup_target usb); want backup_target "$target"
    if [ "$target" = server ]; then
      url=$(sl_choice_get immich_url); [ -n "$url" ] || url=$(sl_build_get IMMICH_URL); host=$(printf '%s' "$url" | sed -E 's#^[a-zA-Z]+://##; s#[/:].*##')
      printf 'ssh://%s@%s/~/backups/%s\n' "$USER" "$host" "$(hostname 2>/dev/null || echo laptop)" > "$USTATE/backup-server-url"
    fi
    [ "$target" = later ] || bg flatpak run org.gnome.World.PikaBackup
  fi
  if sl_wizard_selected steps recovery && command -v secure-linux-recovery-key >/dev/null 2>&1; then ui_terminal secure-linux-recovery-key; fi
  if sl_wizard_selected steps hardware && command -v secure-linux-health >/dev/null 2>&1; then secure-linux-health --gui || true; fi
  case $(sl_wizard_get wifi_mode skip) in
    home) command -v secure-linux-zone >/dev/null 2>&1 && secure-linux-zone set-home || true ;;
    saved) printf '%s\n' "${SL_WIZARD_SECRET[wifi_pin]:-}" | pkexec "$SELF" --wifi-saved || true; SL_WIZARD_SECRET[wifi_pin]="" ;;
  esac
  case $(sl_wizard_get password_manager none) in
    bitwarden) bg flatpak run com.bitwarden.desktop; wz_open "https://passwords.google.com/options" ;;
  esac
  if sl_wizard_yes bookmarks; then "$SL_ROOT/bin/secure-linux-migrate" bookmarks || true; fi
}

sl_wizard_apply_extras() {
  local mode url C=$SL_ROOT/bin/secure-linux-choice
  if sl_wizard_yes local_ai; then
    want ai_models "qwen2.5-coder:7b,qwen2.5-coder:1.5b"; bg ui_terminal secure-linux-ai setup
  fi
  mode=$(sl_wizard_get home_assistant none)
  case $mode in
    existing|practice)
      url=$(sl_wizard_get ha_url "")
      case $url in http://*|https://*) sl_wizard_root "$C" set ha_url "$url" || true; sl_wizard_root "$C" set ha_have_server yes || true ;; *) return 1 ;; esac
      [ "$mode" = practice ] && sl_wizard_root "$C" set ha_local yes || true ;;
    guided) bg ui_terminal "$SL_ROOT/bin/secure-linux-ha-setup" ;;
  esac
  if [ "$(sl_wizard_get docker no)" = yes ]; then
    # The setup step owns installation and repeats sl_docker_check before changing repositories/packages.
    sl_wizard_root "$C" set docker yes || return 1
    sl_wizard_root "$SL_ROOT/setup.sh" --repair || return 1
  fi
  sl_wizard_yes fleet && ui_terminal "$SL_ROOT/bin/secure-linux-fleet-join" || true
  sl_wizard_yes flipper && bg "$SL_ROOT/bin/secure-linux-flipper" qflipper --yes || true
  sl_wizard_yes onedrive && bg ui_terminal "$SL_ROOT/bin/secure-linux-migrate" onedrive all || true
  sl_wizard_yes photos && bg ui_terminal "$SL_ROOT/bin/secure-linux-migrate" page photos || true
  if sl_wizard_yes printer; then
    if command -v system-config-printer >/dev/null 2>&1; then bg system-config-printer; else bg systemsettings kcm_printer_manager; fi
  fi
  sl_wizard_yes emergency && bg "$SL_ROOT/bin/secure-linux-emergency-kit" --open || true
  sl_wizard_yes family && ui_terminal "$SL_ROOT/bin/secure-linux-family" --wizard children || true
  sl_wizard_yes tips && "$SL_ROOT/bin/secure-linux-tips" --on >/dev/null 2>&1 || true
}

sl_wizard_apply() {
  sl_wizard_apply_identity || return 1
  # A distro hook must implement every route exposed by its renderer; it is not a no-op fallback.
  if declare -F sl_wizard_distro_apply >/dev/null; then sl_wizard_distro_apply || return 1; flush; return; fi
  sl_wizard_apply_choices || return 1
  sl_wizard_apply_security || return 1
  sl_wizard_apply_builtin || return 1
  sl_wizard_apply_extras || return 1
  flush
}

sl_wizard_run() {
  local index=1 action page
  sl_wizard_scan
  while [ "$index" -ge 1 ] && [ "$index" -le 5 ]; do
    case $index in
      1) page=01-system.sh ;; 2) page=02-identity.sh ;; 3) page=03-apps-security.sh ;;
      4) page=04-extras.sh ;; 5) page=05-review.sh ;;
    esac
    unset -f wizard_screen
    . "$SL_WIZARD_SCREEN_DIR/$page" || return 1
    declare -F wizard_screen >/dev/null || return 1
    wizard_screen || return 1
    action=$SL_WIZARD_ACTION
    case $action in
      cancel) return 1 ;;
      back) index=$((index - 1)); [ "$index" -ge 1 ] || index=1 ;;
      *) index=$((index + 1)) ;;
    esac
  done
  [ "$(sl_wizard_get confirm False)" = True ] || return 1
  sl_wizard_apply
}
