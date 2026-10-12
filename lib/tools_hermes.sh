# shellcheck shell=bash
# tools_hermes.sh: Werkzeug „Hermes-Instanzen“.
# Findet Hermes-Agent-Instanzen auf allen Ebenen: System (systemd), Docker auf dem Host und in jedem
# laufenden Incus-CT dessen systemd und Docker (System → Incus → Docker → Hermes).
# Eine Instanz ist ein Datenordner (HERMES_HOME) auf einer Ebene, Gateway und WebUI sind Bausteine
# dieser Instanz. Erkennung (Skript _HM_SCAN, läuft auf jeder Ebene per sh):
#   systemd  Units, deren ExecStart „hermes“ enthält. Daten: HERMES_HOME aus Environment, sonst
#            HOME bzw. Home des Unit-Users + /.hermes. Rolle webui, wenn der Unit-Name „webui“ enthält.
#   Docker   Image hermes-agent oder Entrypoint entrypoint-dispatch → Gateway (Cmd mit „gateway“)
#            bzw. Agent, Daten = Mount auf HERMES_HOME (Default /opt/data). Image hermes-webui oder
#            Cmd hermeswebui → WebUI, Daten = Mount auf …/.hermes. Hilfscontainer zählen nicht.
# Aus Config.Env wird nur HERMES_HOME gelesen, nie andere Variablen (dort stehen API-Keys).
# Instanz-Screen: Status, Doctor, Cron-Jobs, Profile, Logs, config.yaml (Geheimnisse maskiert),
# Speicherplatz, Shell, Hermes-CLI, Gateway/WebUI Restart/Stop/Start (mit Rückfrage), Update.
# shellcheck disable=SC1111,SC2016,SC2034 # „…“ gewollt, $-Ausdrücke in _HM_* laufen erst im Ziel-sh

declare -ga HM_KEYS=()
declare -gA HM_LAYER=() HM_KIND=() HM_DATA=() HM_NAME=() HM_GW=() HM_GWST=() HM_WEB=() HM_WEBST=()
declare -gA HM_EXE=() HM_HOME=() HM_IMG=() HM_PROJ=() HM_ID=() HM_IDX=()
# Schlüssel sind fortlaufend (h1, h2 …), weil „|“ im Menüwert nicht vorkommen darf. HM_ID[k] = „ebene|daten“
# identifiziert die Instanz über einen neuen Scan hinweg, HM_IDX[id] führt zurück auf den aktuellen Schlüssel.

_hm_avail() { have systemctl || have docker || have incus; }

# Ausgabe je Treffer:  S|unit|ActiveState|rolle|daten|ExecStart-Pfad
#                      D|container|status|rolle|daten (Host-Pfad der Ebene)|HERMES_HOME im Container|image|compose-projekt
_HM_SCAN='
if command -v systemctl >/dev/null 2>&1; then
  units=$( { systemctl list-units --type=service --all --no-legend --plain 2>/dev/null | awk "{print \$1}"
             systemctl list-unit-files --type=service --no-legend 2>/dev/null | awk "\$1 ~ /hermes/ {print \$1}"; } |
           grep "\.service$" | grep -v "@\.service$" | sort -u)
  [ -n "$units" ] && systemctl show -p Id,ActiveState,User,Environment,ExecStart --no-pager $units 2>/dev/null | awk "
    function flush(  n, e, i, home, hh, p, role) {
      if (id != \"\" && ex ~ /hermes/) {
        n = split(env, e, \" \"); home = \"\"; hh = \"\"
        for (i = 1; i <= n; i++) {
          if (e[i] ~ /^HERMES_HOME=/) home = substr(e[i], 13)
          else if (e[i] ~ /^HOME=/) hh = substr(e[i], 6)
        }
        if (hh == \"\") hh = (usr == \"\" || usr == \"root\") ? \"/root\" : \"/home/\" usr
        if (home == \"\") home = hh \"/.hermes\"
        role = (id ~ /webui/) ? \"webui\" : \"gateway\"
        p = ex; sub(/.*path=/, \"\", p); sub(/[ ;].*/, \"\", p)
        print \"S|\" id \"|\" act \"|\" role \"|\" home \"|\" p
      }
      id = \"\"; act = \"\"; usr = \"\"; env = \"\"; ex = \"\"
    }
    /^Id=/ {id = substr(\$0, 4)} /^ActiveState=/ {act = substr(\$0, 13)} /^User=/ {usr = substr(\$0, 6)}
    /^Environment=/ {env = substr(\$0, 13)} /^ExecStart=/ {ex = substr(\$0, 11)}
    /^\$/ {flush()} END {flush()}"
fi
if command -v docker >/dev/null 2>&1; then
  ids=$(docker ps -aq 2>/dev/null)
  [ -n "$ids" ] && docker inspect --format "{{.Name}}|{{.State.Status}}|{{.Config.Image}}|{{join .Config.Entrypoint \" \"}} {{join .Config.Cmd \" \"}}|{{range .Mounts}}{{.Source}}>{{.Destination}};{{end}}|{{range .Config.Env}}{{if ge (len .) 12}}{{if eq (slice . 0 12) \"HERMES_HOME=\"}}{{.}}{{end}}{{end}}{{end}}|{{index .Config.Labels \"com.docker.compose.project\"}}" $ids 2>/dev/null |
  awk -F"|" "{
    name = \$1; sub(/^\//, \"\", name); img = \$3; cmd = \$4; hh = \$6; sub(/^HERMES_HOME=/, \"\", hh); role = \"\"
    if (img ~ /hermes-webui/ || cmd ~ /hermeswebui/) role = \"webui\"
    else if (img ~ /hermes-agent/ || cmd ~ /entrypoint-dispatch/) role = (cmd ~ /gateway/) ? \"gateway\" : \"agent\"
    if (role == \"\") next
    if (role != \"webui\" && hh == \"\") hh = \"/opt/data\"
    data = \"\"; n = split(\$5, a, \";\")
    for (i = 1; i <= n; i++) {
      if (a[i] == \"\") continue
      s = a[i]; d = a[i]; sub(/>.*/, \"\", s); sub(/^[^>]*>/, \"\", d)
      if (role == \"webui\") { if (d ~ /\/\.hermes\$/) { data = s; hh = d } }
      else if (d == hh) data = s
    }
    print \"D|\" name \"|\" \$2 \"|\" role \"|\" data \"|\" hh \"|\" img \"|\" \$7
  }"
fi'

# Skript auf einer Ebene ausführen: ebene ("" = Host, sonst CT) skript [args…], stdin </dev/null
_hm_sh() {
  local l=$1 s=$2; shift 2
  if [ -z "$l" ]; then sh -c "$s" sh "$@" </dev/null
  else incus exec "$l" -- sh -c "$s" sh "$@" </dev/null; fi
}
_hm_sh_tty() { # wie _hm_sh, aber stdin am Terminal (Shell, CLI, Logs folgen)
  local l=$1 s=$2; shift 2
  if [ -z "$l" ]; then sh -c "$s" sh "$@"
  else incus exec "$l" -- sh -c "$s" sh "$@"; fi
}

_hm_add() { # ebene art daten name → Schlüssel in HM_K (legt die Instanz bei Bedarf an)
  local id="$1|$3"
  [ -n "$3" ] || id="$1|@$4"
  HM_K=${HM_IDX[$id]:-}
  if [ -z "$HM_K" ]; then
    HM_K="h$(( ${#HM_KEYS[@]} + 1 ))"
    HM_KEYS+=("$HM_K"); HM_ID[$HM_K]=$id HM_IDX[$id]=$HM_K
    HM_LAYER[$HM_K]=$1 HM_KIND[$HM_K]=$2 HM_DATA[$HM_K]=$3 HM_NAME[$HM_K]=$4
    HM_GW[$HM_K]="" HM_GWST[$HM_K]="" HM_WEB[$HM_K]="" HM_WEBST[$HM_K]=""
    HM_EXE[$HM_K]="" HM_HOME[$HM_K]="" HM_IMG[$HM_K]="" HM_PROJ[$HM_K]=""
  fi
}

_hm_parse() { # ebene < Scanner-Ausgabe
  local l=$1 t n st role data x6 img proj
  while IFS='|' read -r t n st role data x6 img proj; do
    case "$t" in
      S) _hm_add "$l" system "$data" "${n%.service}"
         if [ "$role" = webui ]; then HM_WEB[$HM_K]=$n HM_WEBST[$HM_K]=$st
         elif [ -z "${HM_GW[$HM_K]}" ] || [ "$st" = active ]; then
           HM_GW[$HM_K]=$n HM_GWST[$HM_K]=$st HM_NAME[$HM_K]=${n%.service} HM_EXE[$HM_K]=$x6
         fi;;
      D) _hm_add "$l" docker "$data" "$n"
         HM_KIND[$HM_K]=docker
         if [ "$role" = webui ]; then HM_WEB[$HM_K]=$n HM_WEBST[$HM_K]=$st
         elif [ -z "${HM_GW[$HM_K]}" ] || [ "$st" = running ]; then
           HM_GW[$HM_K]=$n HM_GWST[$HM_K]=$st HM_NAME[$HM_K]=$n HM_HOME[$HM_K]=$x6 HM_IMG[$HM_K]=$img HM_PROJ[$HM_K]=$proj
         fi;;
    esac
  done
}

# Alle Ebenen scannen: Host direkt, laufende CTs parallel (je max. 25 s)
hm_scan() {
  local tmp ct st _ i=0 f
  HM_KEYS=() HM_LAYER=() HM_KIND=() HM_DATA=() HM_NAME=() HM_GW=() HM_GWST=() HM_WEB=() HM_WEBST=()
  HM_EXE=() HM_HOME=() HM_IMG=() HM_PROJ=() HM_ID=() HM_IDX=() HM_CTS=""
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/sshlobby-hm.XXXXXX") || return 1
  _hm_parse "" < <(timeout 25 sh -c "$_HM_SCAN" </dev/null 2>/dev/null)
  if have incus && [ "${HERMES_SCAN_CTS:-yes}" = yes ]; then
    ct_load
    while IFS=, read -r ct st _; do
      if [ -z "$ct" ] || [ "$st" != Running ]; then continue; fi
      i=$((i + 1)); printf '%s\n' "$ct" > "$tmp/$i.name"
      timeout 25 incus exec "$ct" -- sh -c "$_HM_SCAN" </dev/null >"$tmp/$i.out" 2>/dev/null &
    done <<< "$CTS_RAW"
    wait
    for f in "$tmp"/*.name; do
      [ -e "$f" ] || continue
      ct=$(<"$f"); HM_CTS+="$ct "
      _hm_parse "$ct" < "${f%.name}.out"
    done
  fi
  rm -rf "$tmp"
}

# Anzeige-Hilfen
hm_where() { # schlüssel → „System“, „Docker“, „CT x › Docker“ …
  local l=${HM_LAYER[$1]} k=${TX[hermes.where.system]}
  [ "${HM_KIND[$1]}" = docker ] && k=Docker
  if [ -z "$l" ]; then printf '%s' "$k"; else printf 'CT %s › %s' "$l" "$k"; fi
}
_hm_st() { # zustand → run|stop|err|""
  case "$1" in active|running) echo run;; failed|dead|restarting) echo err;; "") echo "";; *) echo stop;; esac
}
hm_mark() { # schlüssel → Markierung der Instanz (Gateway zählt, sonst WebUI)
  local s; s=$(_hm_st "${HM_GWST[$1]}")
  [ -n "$s" ] || s=$(_hm_st "${HM_WEBST[$1]}")
  echo "${s:-stop}"
}
hm_summary() { # schlüssel → „Gateway läuft · WebUI läuft“
  local out=""
  [ -n "${HM_GW[$1]}" ] && out="Gateway ${HM_GWST[$1]}"
  [ -n "${HM_WEB[$1]}" ] && out+="${out:+ · }WebUI ${HM_WEBST[$1]}"
  printf '%s' "${out:-${TX[hermes.no_services]}}"
}

# ─── Werkzeug: Instanzliste ────────────────────────────────────────────────
_t_hermes() {
  local k last="" sub
  _ui_tui_on && ui_loading "${TX[hermes.list.searching]}"
  hm_scan
  while true; do
    if [ ${#HM_KEYS[@]} -eq 0 ]; then
      ui_item disabled "" "$(t hermes.list.none "${TX[hermes.where.system]}, Docker${HM_CTS:+, CTs $HM_CTS}")"
    fi
    last=""
    for k in "${HM_KEYS[@]}"; do
      if [ "${HM_LAYER[$k]}|${HM_KIND[$k]}" != "$last" ]; then
        last="${HM_LAYER[$k]}|${HM_KIND[$k]}"
        ui_item header "" "$(hm_where "$k")" "" main
      fi
      ui_item item "$k" "${HM_NAME[$k]}" "$(hm_summary "$k")  ${HM_DATA[$k]:-}" "$(hm_mark "$k")"
    done
    UI_KEYS=("r|${TX[hermes.list.rescan]}")
    tf sub hermes.list.found "${#HM_KEYS[@]}"
    [ -n "$HM_CTS" ] && sub+=", $(t hermes.list.cts_scanned "$HM_CTS")"
    ui_menu "${TX[hermes.title]}" "$sub"
    case "$UI_ACT" in
      select) _hm_screen "$UI_SEL";;
      key) [ "$UI_SEL" = r ] && { _ui_tui_on && ui_loading "${TX[hermes.list.searching]}"; hm_scan; };;
      *) return 0;;
    esac
  done
}

# ─── Instanz-Screen ────────────────────────────────────────────────────────
_hm_screen() { # schlüssel
  local k=$1 id=${HM_ID[$1]} l kind gw web name run
  while true; do
    k=${HM_IDX[$id]:-}   # nach einem neuen Scan kann der Schlüssel wechseln
    [ -n "$k" ] || return 0
    l=${HM_LAYER[$k]} kind=${HM_KIND[$k]} gw=${HM_GW[$k]} web=${HM_WEB[$k]} name=${HM_NAME[$k]}
    run=0; [ "$(_hm_st "${HM_GWST[$k]}")" = run ] && run=1
    ui_info "${TX[hermes.info.where]}" "$(hm_where "$k")${l:+ $(t hermes.info.incus_ct "$l")}"
    ui_info "${TX[hermes.info.data]}" "${HM_DATA[$k]:-${TX[hermes.info.unknown]}}${HM_HOME[$k]:+  $(t hermes.info.in_container "${HM_HOME[$k]}")}"
    [ -n "$gw" ] && ui_info "Gateway" "$gw: ${HM_GWST[$k]}" "$(_hm_st "${HM_GWST[$k]}")"
    [ -n "$web" ] && ui_info "WebUI" "$web: ${HM_WEBST[$k]}" "$(_hm_st "${HM_WEBST[$k]}")"
    [ -n "${HM_IMG[$k]}" ] && ui_info "Image" "${HM_IMG[$k]}"
    if [ "$kind" = system ] || [ "$run" = 1 ]; then
      ui_item header "" "Hermes" "" main
      ui_item item status "${TX[hermes.item.status]}" "hermes status"
      ui_item item doctor "${TX[hermes.item.doctor]}" "hermes doctor"
      ui_item item cron "${TX[hermes.item.cron]}" "hermes cron list"
      ui_item item profiles "${TX[hermes.item.profiles]}" "hermes profile list"
      ui_item item cli "${TX[hermes.item.cli]}" "${TX[hermes.item.cli_desc]}"
    fi
    ui_item header "" "${TX[hermes.head.files]}" "" main
    [ -n "$gw" ] && ui_item item glogs "${TX[hermes.item.glogs]}" "${TX[hermes.item.glogs_desc]}"
    if [ -n "${HM_DATA[$k]}" ]; then
      ui_item item errors "${TX[hermes.item.errors]}" "$(t hermes.item.log_desc logs/errors.log)"
      ui_item item agentlog "${TX[hermes.item.agentlog]}" "$(t hermes.item.log_desc logs/agent.log)"
      ui_item item config "${TX[hermes.item.config]}" "${TX[hermes.item.config_desc]}"
      ui_item item disk "${TX[hermes.item.disk]}" "${TX[hermes.item.disk_desc]}"
    fi
    ui_item item shell "${TX[hermes.item.shell]}" "$([ "$kind" = docker ] && echo "${TX[hermes.item.shell_container]}" || echo "${TX[hermes.item.shell_data]}")"
    ui_item header "" "${TX[hermes.head.control]}" "" main
    if [ -n "$gw" ]; then
      if [ "$run" = 1 ]; then
        ui_item item grestart "${TX[hermes.item.grestart]}" "${TX[hermes.item.confirm_desc]}" danger
        ui_item item gstop "${TX[hermes.item.gstop]}" "${TX[hermes.item.confirm_desc]}" danger
      else
        ui_item item gstart "${TX[hermes.item.gstart]}"
      fi
    fi
    if [ -n "$web" ]; then
      if [ "$(_hm_st "${HM_WEBST[$k]}")" = run ]; then ui_item item wrestart "${TX[hermes.item.wrestart]}" "${TX[hermes.item.confirm_desc]}" danger
      else ui_item item wstart "${TX[hermes.item.wstart]}"; fi
    fi
    if [ "$kind" = system ]; then ui_item item update "${TX[hermes.item.update]}" "${TX[hermes.item.update_desc]}" danger
    elif [[ ${HM_IMG[$k]} == */* ]]; then ui_item item pull "${TX[hermes.item.pull]}" "${TX[hermes.item.pull_desc]}"; fi
    ui_menu "$name" "Hermes · $(hm_where "$k")"
    case "$UI_ACT" in
      back|quit|eof) return 0;;
      select) _hm_do "$k" "$UI_SEL";;
    esac
  done
}

# Hermes-CLI im Kontext der Instanz: Docker → docker exec, System → hermes der Installation mit HERMES_HOME.
# Sichtbare Texte kommen als Argument mit (das sh auf der Ebene hat kein TX).
_HM_CLI='d=$1; x=$2; r=$3; m=$4; shift 4; h=""
for c in "$r${x%/*}/hermes" "$r/root/.local/bin/hermes" "$r/usr/local/bin/hermes"; do [ -x "$c" ] && { h=$c; break; }; done
[ -n "$h" ] || h=$(command -v hermes) || { echo "$m" >&2; exit 127; }
HERMES_HOME=$d exec "$h" "$@"'
_hm_cli() { # schlüssel args… (nicht interaktiv)
  local k=$1; shift
  if [ "${HM_KIND[$k]}" = docker ]; then dk "${HM_LAYER[$k]}" exec "${HM_GW[$k]}" hermes "$@"
  else _hm_sh "${HM_LAYER[$k]}" "$_HM_CLI" "${HM_DATA[$k]}" "${HM_EXE[$k]}" "${PD_TOOLS_ROOT:-}" "${TX[hermes.cli.not_found]}" "$@"; fi
}
_hm_cli_tty() { # schlüssel args… (interaktiv)
  local k=$1 t=-it; shift
  [ -t 0 ] || t=-i
  if [ "${HM_KIND[$k]}" = docker ]; then dk_tty "${HM_LAYER[$k]}" exec "$t" "${HM_GW[$k]}" hermes "$@"
  else _hm_sh_tty "${HM_LAYER[$k]}" "$_HM_CLI" "${HM_DATA[$k]}" "${HM_EXE[$k]}" "${PD_TOOLS_ROOT:-}" "${TX[hermes.cli.not_found]}" "$@"; fi
}

# Dateien im Datenordner (liegt auf der Ebene, also auch bei gestopptem Container lesbar).
# Letztes Argument: Format „(%s fehlt)“ aus TX, bei _HM_CONF davor die Maske (für sed escaped, _hm_sedrep).
_HM_TAIL='f=$1/logs/$2; [ -r "$f" ] || { printf -- "$3\n" "$f"; exit 0; }; tail -n 150 "$f"'
_HM_CONF='f=$1/config.yaml; [ -r "$f" ] || { printf -- "$3\n" "$f"; exit 0; }
sed -E "/:[[:space:]]*(true|false|null|~|[0-9.]+)[[:space:]]*(#.*)?\$/!s/^([[:space:]]*[A-Za-z0-9_.-]*([Kk][Ee][Yy]|[Tt][Oo][Kk][Ee][Nn]|[Ss][Ee][Cc][Rr][Ee][Tt]|[Pp][Aa][Ss][Ss][Ww]([Oo][Rr])?[Dd])[A-Za-z0-9_.-]*[[:space:]]*:[[:space:]]*)[^[:space:]#].*/\1$2/" "$f"'
_HM_DU='cd "$1" 2>/dev/null || { printf -- "$2\n" "$1"; exit 0; }; du -sh . 2>/dev/null; echo; du -sh ./* ./.[!.]* 2>/dev/null | sort -rh | head -n 20'
_hm_sedrep() { # text → für die Ersetzung in sed s/…/…/ escaped (\ & /)
  local s=${1//\\/\\\\}
  s=${s//&/\\&}; s=${s//\//\\/}
  printf '%s' "$s"
}
_HM_SHELL='cd "$1" 2>/dev/null || cd /; command -v bash >/dev/null && exec bash -l || exec sh -l'
_HM_JOURNAL='journalctl -u "$1" -f -n 100'

_hm_follow() { # befehl… (bis Ctrl-C)
  local rc
  "$@"; rc=$?
  printf '\n%s%s%s\n' "$C_GRY" "${TX[hermes.logs.ended]}" "$C_R"
  return "$rc"
}

_hm_svc() { # schlüssel komponente(gw|web) aktion
  local k=$1 l=${HM_LAYER[$1]} u
  if [ "$2" = gw ]; then u=${HM_GW[$k]}; else u=${HM_WEB[$k]}; fi
  if [ "${HM_KIND[$k]}" = docker ]; then dk_action "$l" "$3" "$u"
  elif [ -z "$l" ]; then ui_run_task "$u: $3" systemctl "$3" -- "$u"
  else ui_run_task "$u: $3" incus exec "$l" -- systemctl "$3" -- "$u"; fi
}

_hm_do() { # schlüssel aktion
  local k=$1 a=$2 l=${HM_LAYER[$1]} n=${HM_NAME[$1]} d=${HM_DATA[$1]}
  [ -z "$l" ] && d=$(tp "$d") # Host: Testwurzel (PD_TOOLS_ROOT) vor den Pfad, sonst unverändert
  case "$a" in
    status)   ui_run_page "hermes status: $n" _hm_cli "$k" status;;
    doctor)   ui_run_page "hermes doctor: $n" _hm_cli "$k" doctor;;
    cron)     ui_run_page "$(t hermes.page.cron "$n")" _hm_cli "$k" cron list;;
    profiles) ui_run_page "$(t hermes.page.profiles "$n")" _hm_cli "$k" profile list;;
    cli)      ui_run_fg _hm_cli_tty "$k"; ui_check_rc $? "$(t hermes.page.cli "$n")";;
    errors)   ui_run_page "errors.log: $n" _hm_sh "$l" "$_HM_TAIL" "$d" errors.log "${TX[hermes.file.missing]}";;
    agentlog) ui_run_page "agent.log: $n" _hm_sh "$l" "$_HM_TAIL" "$d" agent.log "${TX[hermes.file.missing]}";;
    config)   ui_run_page "config.yaml: $n" _hm_sh "$l" "$_HM_CONF" "$d" "$(_hm_sedrep "${TX[hermes.config.masked]}")" "${TX[hermes.file.missing]}";;
    disk)     ui_run_page "$(t hermes.page.disk "$n")" _hm_sh "$l" "$_HM_DU" "$d" "${TX[hermes.file.missing]}";;
    glogs)
      if [ "${HM_KIND[$k]}" = docker ]; then dk_logs "$l" "${HM_GW[$k]}"
      else ui_run_fg _hm_follow _hm_sh_tty "$l" "$_HM_JOURNAL" "${HM_GW[$k]}"; ui_check_rc $? "$(t hermes.page.logs "$n")"; fi;;
    shell)
      if [ "${HM_KIND[$k]}" = docker ]; then
        dk_preflight "$l" "${HM_GW[$k]:-${HM_WEB[$k]}}" || { ui_msg err "$PF_MSG"; return 0; }
        ui_run_fg dk_tty "$l" exec -it "${HM_GW[$k]:-${HM_WEB[$k]}}" sh -c "$DK_SHELL_CMD"
      elif [ -z "$l" ]; then ui_run_fg _pd_shell_in "$d"
      else ui_run_fg _hm_sh_tty "$l" "$_HM_SHELL" "$d"; fi;;
    grestart) ui_confirm "$(t hermes.confirm.grestart "$n")" && _hm_svc "$k" gw restart && _hm_refresh "$k";;
    gstop)    ui_confirm "$(t hermes.confirm.gstop "$n")" && _hm_svc "$k" gw stop && _hm_refresh "$k";;
    gstart)   _hm_svc "$k" gw start && _hm_refresh "$k";;
    wrestart) ui_confirm "$(t hermes.confirm.wrestart "$n")" && _hm_svc "$k" web restart && _hm_refresh "$k";;
    wstart)   _hm_svc "$k" web start && _hm_refresh "$k";;
    update)
      ui_confirm "$(t hermes.confirm.update "$n")" || return 0
      ui_run_fg _hm_update "$k";;
    pull)
      ui_confirm "$(t hermes.confirm.pull "${HM_IMG[$k]}")" || return 0
      ui_run_task "docker pull ${HM_IMG[$k]}" dk "$l" pull "${HM_IMG[$k]}" &&
        ui_msg info "${TX[hermes.pull.done]}"
      ;;
  esac
}

_hm_update() { # schlüssel (Vordergrund, Ausgabe sichtbar)
  local rc m
  _hm_cli_tty "$1" update; rc=$?
  tf m hermes.update.ended "$rc"
  printf '\n%s%s%s\n' "$C_GRY" "$m" "$C_R"
  ui_pause
}

_hm_refresh() { # schlüssel: Zustand nach einer Aktion neu einlesen (der Screen findet die Instanz über HM_ID)
  local k=$1 id=${HM_ID[$1]:-}
  _ui_tui_on && ui_loading "${TX[hermes.refreshing]}"
  hm_scan
  [ -n "${HM_IDX[$id]:-}" ] || ui_note warn "${TX[hermes.lost]}"
  return 0
}

tool_register hermes "${TX[hermes.title]}" "${TX[hermes.desc]}" "all" _hm_avail _t_hermes 93
