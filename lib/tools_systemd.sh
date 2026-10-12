# shellcheck shell=bash
# tools_systemd.sh: Werkzeug „systemd-Dienste“.
# Liste aller Services, gruppiert: Favoriten, Fehlgeschlagen, Eigene (Unit-Datei unter
# /etc/systemd/system oder /usr/local, also nicht vom Paketmanager), Laufend, Rest.
# Dienst-Screen: Status aus systemctl show, Logs, letzte Warnungen, status, Unit-Datei,
# Start/Restart/Stop/Enable/Disable. Ändernde Aktionen außer Start nur mit Rückfrage, bei Units,
# die die SSH-Sitzung oder sshlobby tragen, mit Warnung und eingetipptem Namen.
# Datenquellen: systemctl list-units -o json (ab systemd 252), list-unit-files, show.
# Favoriten: eigene Datei ~/.config/sshlobby/service-favorites (eine Unit pro Zeile).
# shellcheck disable=SC1111,SC2034 # „…“ sind gewollte Anführungszeichen, UI_* liest ui.sh

SVC_FAVS="$CONF_DIR/service-favorites"
declare -gA SVC_ACT=() SVC_SUB=() SVC_DESC=() SVC_PATH=()
declare -ga SVC_UNITS=()
declare -gA SVC_SH=()

_svc_avail() { have systemctl; }

# Units, deren Stop/Restart/Disable die SSH-Sitzung (und damit sshlobby) trennen kann
_svc_critical() {
  case "$1" in
    ssh.service|sshd.service|systemd-logind.service|dbus.service|dbus-broker.service|user@*.service|\
    user-runtime-dir@*.service|systemd-networkd.service|networking.service|NetworkManager.service|\
    tailscaled.service|wg-quick@*.service) return 0;;
  esac
  return 1
}
_svc_own() { [[ $1 == /etc/systemd/system/* || $1 == /usr/local/* ]]; } # Unit-Pfad → eigene Unit?

# Alle Services laden → SVC_UNITS (sortiert) und SVC_* je Unit
_svc_load() {
  local u load act sub desc state key val line
  SVC_UNITS=() SVC_ACT=() SVC_SUB=() SVC_DESC=() SVC_PATH=()
  while IFS=$'\t' read -r u load act sub desc; do
    [ -n "$u" ] || continue
    # nicht gefunden und nicht fehlgeschlagen: nur Verweise anderer Units, kein echter Dienst
    [ "$load" = not-found ] && [ "$act" != failed ] && continue
    SVC_ACT[$u]=$act SVC_SUB[$u]=$sub SVC_DESC[$u]=$desc
  done < <(tq 15 systemctl list-units --type=service --all -o json --no-pager |
             jq -r '.[]? | [.unit, .load, .active, .sub, .description] | @tsv' 2>/dev/null)
  # installierte, aber nicht geladene Services (z. B. disabled); Vorlagen und Aliase weglassen
  while read -r u state _; do
    [[ $u == *.service ]] || continue
    [[ $u == *@.service ]] || [ "$state" = alias ] && continue
    [ -n "${SVC_ACT[$u]+x}" ] && continue
    SVC_ACT[$u]=inactive SVC_SUB[$u]=dead SVC_DESC[$u]=""
  done < <(tq 15 systemctl list-unit-files --type=service --no-legend --no-pager)
  mapfile -t SVC_UNITS < <(printf '%s\n' "${!SVC_ACT[@]}" | LC_ALL=C sort -f)
  [ ${#SVC_UNITS[@]} -gt 0 ] || return 0
  # Unit-Pfad und Beschreibung (auch für nicht geladene) in einem Aufruf
  u=""
  while IFS= read -r line; do
    [ -n "$line" ] || { u=""; continue; }
    key=${line%%=*} val=${line#*=}
    case "$key" in
      Id) u=$val;;
      FragmentPath) [ -n "$u" ] && SVC_PATH[$u]=$val;;
      Description) [ -n "$u" ] && [ -z "${SVC_DESC[$u]:-}" ] && SVC_DESC[$u]=$val;;
    esac
  done < <(tq 20 systemctl show -p Id,Description,FragmentPath --no-pager -- "${SVC_UNITS[@]}")
}

_svc_group() { # unit → failed | own | run | rest
  local u=$1
  if [ "${SVC_ACT[$u]}" = failed ]; then echo failed
  elif _svc_own "${SVC_PATH[$u]:-}"; then echo own
  elif [ "${SVC_ACT[$u]}" = active ] && [ "${SVC_SUB[$u]}" != exited ]; then echo run
  else echo rest; fi
}
_svc_mark() { # unit → Markierung für ui_item
  case "${SVC_ACT[$1]}/${SVC_SUB[$1]}" in
    failed/*) echo err;;
    active/exited) echo stop;;
    active/*) echo run;;
    activating/*|deactivating/*|reloading/*) echo warn;;
    *) echo stop;;
  esac
}
_svc_item() { # unit
  local u=$1 st="${SVC_ACT[$1]}/${SVC_SUB[$1]}"
  ui_item item "svc:$u" "$(tl_cut "${u%.service}" 32)" "$(tl_pad "$st" 18) ${SVC_DESC[$u]:-}" "$(_svc_mark "$u")"
}
_svc_is_fav() { grep -qxF -- "$1" "$SVC_FAVS" 2>/dev/null; }
_svc_fav_toggle() { # unit (eigene Datei, atomar ersetzt)
  local tmp
  mkdir -p "$CONF_DIR" 2>/dev/null || return 0
  if _svc_is_fav "$1"; then
    tmp=$(mktemp "$SVC_FAVS.XXXXXX") || return 0
    grep -vxF -- "$1" "$SVC_FAVS" > "$tmp"; mv "$tmp" "$SVC_FAVS"
  else
    printf '%s\n' "$1" >> "$SVC_FAVS"
  fi
}

_t_services() {
  local u g n_fail=0 n_run=0 n_own=0 n_fav=0 v
  local -a failed=() own=() run=() rest=() favs=()
  _svc_load
  if [ ${#SVC_UNITS[@]} -eq 0 ]; then ui_msg err "${TX[svc.list.empty]}"; return 0; fi
  while true; do
    failed=() own=() run=() rest=() favs=()
    for u in "${SVC_UNITS[@]}"; do
      _svc_is_fav "$u" && favs+=("$u")
      g=$(_svc_group "$u")
      case "$g" in failed) failed+=("$u");; own) own+=("$u");; run) run+=("$u");; *) rest+=("$u");; esac
    done
    n_fail=${#failed[@]} n_own=${#own[@]} n_run=$(( ${#run[@]} )) n_fav=${#favs[@]}
    for u in "${own[@]}"; do [ "${SVC_ACT[$u]}" = active ] && [ "${SVC_SUB[$u]}" != exited ] && n_run=$((n_run+1)); done
    tf v svc.list.summary "${#SVC_UNITS[@]}" "$n_run" "$n_own"; ui_info "${TX[svc.list.services]}" "$v"
    if [ "$n_fail" -gt 0 ]; then ui_info "${TX[svc.list.failed]}" "$n_fail" err; else ui_info "${TX[svc.list.failed]}" "${TX[svc.list.failed_none]}" run; fi
    if [ "$n_fav" -gt 0 ]; then ui_item header "" "${TX[svc.group.favorites]}" "" fav; for u in "${favs[@]}"; do _svc_item "$u"; done; fi
    if [ "$n_fail" -gt 0 ]; then ui_item header "" "${TX[svc.list.failed]}" "" err; for u in "${failed[@]}"; do _svc_item "$u"; done; fi
    if [ "$n_own" -gt 0 ]; then ui_item header "" "${TX[svc.group.own]}" "" main; for u in "${own[@]}"; do _svc_item "$u"; done; fi
    if [ ${#run[@]} -gt 0 ]; then ui_item header "" "${TX[svc.group.running]}" "" main; for u in "${run[@]}"; do _svc_item "$u"; done; fi
    if [ ${#rest[@]} -gt 0 ]; then ui_item header "" "${TX[svc.group.rest]}" "" main; for u in "${rest[@]}"; do _svc_item "$u"; done; fi
    UI_KEYS=("r|${TX[svc.key.reload]}")
    ui_menu "${TX[svc.tool.title]}" "list-units + list-unit-files"
    case "$UI_ACT" in
      select) _svc_screen "${UI_SEL#svc:}"; _svc_load;;
      key) [ "$UI_SEL" = r ] && _svc_load;;
      *) return 0;;
    esac
  done
}

_svc_show() { # unit → SVC_SH[Key]
  local line
  SVC_SH=()
  while IFS= read -r line; do
    [[ $line == *=* ]] && SVC_SH[${line%%=*}]=${line#*=}
  done < <(tq 15 systemctl show --no-pager -p Id,Description,LoadState,ActiveState,SubState,MainPID,MemoryCurrent,NRestarts,UnitFileState,FragmentPath,DropInPaths,Result,ActiveEnterTimestamp,InactiveEnterTimestamp -- "$1")
}

_svc_screen() { # unit
  local u=$1 name=${1%.service} act sub since mem ufs path mark v
  while true; do
    _svc_show "$u"
    act=${SVC_SH[ActiveState]:-${TX[svc.info.unknown]}} sub=${SVC_SH[SubState]:-}
    if [ "$act" = active ] || [ "$act" = reloading ]; then since=${SVC_SH[ActiveEnterTimestamp]:-}
    else since=${SVC_SH[InactiveEnterTimestamp]:-}; fi
    case "$act/$sub" in failed/*) mark=err;; active/exited) mark=stop;; active/*) mark=run;; *) mark=stop;; esac
    mem=${SVC_SH[MemoryCurrent]:-}
    ufs=${SVC_SH[UnitFileState]:-} path=${SVC_SH[FragmentPath]:-}
    ui_info "${TX[svc.info.desc]}" "${SVC_SH[Description]:-}"
    v=""; [ -n "$since" ] && tf v svc.info.since "$since"
    ui_info "${TX[svc.info.status]}" "$act ($sub)${v:+ $v}" "$mark"
    [ "${SVC_SH[Result]:-success}" != success ] && ui_info "${TX[svc.info.result]}" "${SVC_SH[Result]}" err
    [ "${SVC_SH[MainPID]:-0}" != 0 ] && ui_info "${TX[svc.info.pid]}" "${SVC_SH[MainPID]}"
    [[ $mem =~ ^[0-9]+$ ]] && [ ${#mem} -lt 19 ] && ui_info "${TX[svc.info.memory]}" "$(tl_human "$mem")"
    if [ "${SVC_SH[NRestarts]:-0}" -gt 0 ] 2>/dev/null; then ui_info "${TX[svc.info.restarts]}" "${SVC_SH[NRestarts]}" warn
    else ui_info "${TX[svc.info.restarts]}" "${SVC_SH[NRestarts]:-0}"; fi
    ui_info "${TX[svc.info.autostart]}" "${ufs:-${TX[svc.info.unknown]}}"
    v=""; _svc_own "$path" && v="  ${TX[svc.info.own]}"
    ui_info "${TX[svc.info.unit_file]}" "${path:-–}$v"
    [ -n "${SVC_SH[DropInPaths]:-}" ] && ui_info "${TX[svc.info.dropins]}" "${SVC_SH[DropInPaths]}"
    _svc_critical "$u" && ui_info "${TX[svc.info.warning]}" "${TX[svc.info.critical]}" warn
    ui_item item logs "${TX[svc.item.logs]}" "${TX[svc.item.logs_desc]}"
    ui_item item errors "${TX[svc.item.errors]}" "journalctl -p warning -n 50"
    ui_item item status "systemctl status"
    ui_item item cat "${TX[svc.item.cat]}" "systemctl cat"
    if [ "$act" = active ] || [ "$act" = activating ] || [ "$act" = reloading ]; then
      ui_item item restart "${TX[svc.item.restart]}" "${TX[svc.item.confirm]}"
      ui_item item stop "${TX[svc.item.stop]}" "${TX[svc.item.confirm]}"
    else
      ui_item item start "${TX[svc.item.start]}"
      [ "$act" = failed ] && ui_item item restart "${TX[svc.item.restart]}" "${TX[svc.item.confirm]}"
    fi
    case "$ufs" in
      enabled|enabled-runtime) ui_item item disable "${TX[svc.item.disable]}" "${TX[svc.item.disable_desc]}";;
      disabled) ui_item item enable "${TX[svc.item.enable]}" "${TX[svc.item.enable_desc]}";;
    esac
    if _svc_is_fav "$u"; then tf v svc.key.fav_remove "$UI_SYM_FAV"; else tf v svc.key.fav_add "$UI_SYM_GONE"; fi
    UI_KEYS=("f|$v")
    ui_menu "$name" "${TX[svc.screen.subtitle]}"
    case "$UI_ACT" in
      back|quit|eof) return 0;;
      key) [ "$UI_SEL" = f ] && _svc_fav_toggle "$u";;
      select)
        case "$UI_SEL" in
          logs)   ui_run_fg _svc_follow "$u"; ui_check_rc $? "$(t svc.logs.what "$name")";;
          errors) ui_run_page "$(t svc.page.errors "$name")" journalctl -u "$u" -p warning -n 50 --no-pager;;
          status) ui_run_page "systemctl status $name" systemctl status --no-pager -l -n 20 -- "$u";;
          cat)    ui_run_page "$(t svc.page.unit_file "$name")" systemctl cat --no-pager -- "$u";;
          *)      _svc_do "$UI_SEL" "$u";;
        esac;;
    esac
  done
}

_svc_follow() { # unit (bis Ctrl-C)
  local rc
  journalctl -u "$1" -f -n 100; rc=$?
  printf '\n%s%s%s\n' "$C_GRY" "${TX[svc.logs.end]}" "$C_R"
  return "$rc"
}

_svc_do() { # aktion unit
  local a=$1 u=$2 name=${2%.service} q verb
  case "$a" in
    start)   q=""                                     verb=${TX[svc.verb.start]};;
    restart) tf q svc.confirm.restart "$name";        verb=${TX[svc.verb.restart]};;
    stop)    tf q svc.confirm.stop "$name";           verb=${TX[svc.verb.stop]};;
    enable)  tf q svc.confirm.enable "$name";         verb=${TX[svc.verb.enable]};;
    disable) tf q svc.confirm.disable "$name";        verb=${TX[svc.verb.disable]};;
    *) return 0;;
  esac
  if _svc_critical "$u" && [[ $a == restart || $a == stop || $a == disable ]]; then
    ui_note warn "$(t svc.critical.warn "$name")"
    ui_confirm "$(t svc.critical.confirm "$q")" || return 0
    ui_input "$(t svc.critical.type_name "$name")" || return 0
    if [ "$UI_INPUT" != "$name" ]; then ui_note info "${TX[svc.critical.aborted]}"; return 0; fi
  elif [ -n "$q" ]; then
    ui_confirm "$q" || return 0
  fi
  ui_run_task "$name: $verb" systemctl "$a" -- "$u"
}

tool_register services "${TX[svc.tool.title]}" "${TX[svc.tool.desc]}" "all" _svc_avail _t_services 92
