# shellcheck shell=bash
# tools_resources.sh: Werkzeug „Container-Ressourcen“ (rein lesend).
# docker:  docker stats --no-stream des Hosts, sortiert nach RAM oder CPU; Auswahl öffnet den
#          Container-Screen.
# layered: Incus-CTs nach RAM (incus list JSON: Speicher, Swap, Disk, Limit); Auswahl zeigt
#          docker stats im CT.  incus: CT-Liste, Auswahl zeigt incus list des CTs.
# shellcheck disable=SC2034,SC2016 # UI_* liest ui.sh; jq-Programme in einfachen Anführungszeichen

RES_SORT=mem

_res_avail() {
  case "$MODE" in docker) have docker;; *) have incus;; esac
}

# docker stats eines Kontexts → "name|cpu%|ram-text|ram%|pids|ram-bytes", sortiert nach RES_SORT
_res_stats() { # kontext
  local key=6
  [ "$RES_SORT" = cpu ] && key=2
  dk "$1" stats --no-stream --format '{{json .}}' 2>/dev/null |
    jq -Rr "$TL_JQ_BYTES"' fromjson? | [.Name, (.CPUPerc | rtrimstr("%")), (.MemUsage | split(" / ")[0]),
      (.MemPerc | rtrimstr("%")), .PIDs, (.MemUsage | split(" / ")[0] | bytes | floor | tostring)] | join("|")' 2>/dev/null |
    sort -t'|' -k"$key","$key"gr
}

_res_header() { # Host-RAM und Swap als Infozeilen
  local mt ma st sf p
  read -r mt ma st sf < <(tl_meminfo)
  if [ "${mt:-0}" -gt 0 ]; then
    p=$(( (mt - ma) * 100 / mt ))
    ui_info "${TX[res.host_ram]}" "$(tl_human $(( (mt - ma) * 1024 ))) / $(tl_human $((mt * 1024))) ($p %)" "$(_res_mark "$p" 80 90)"
  fi
  if [ "${st:-0}" -gt 0 ]; then
    p=$(( (st - sf) * 100 / st ))
    ui_info "${TX[res.swap]}" "$(tl_human $(( (st - sf) * 1024 ))) / $(tl_human $((st * 1024))) ($p %)" "$(_res_mark "$p" 60 90)"
  fi
}
_res_mark() { case "$(tl_lvl "$1" "$2" "$3")" in ok) echo run;; *) tl_lvl "$1" "$2" "$3";; esac; }

_res_docker() { # kontext
  local ctx=$1 n cpu mem pct pids grp line v
  while true; do
    if [ -n "$ctx" ]; then tf v res.measuring_in "$ctx"; else v=${TX[res.measuring]}; fi
    ui_note info "$v"
    local -a rows=()
    mapfile -t rows < <(_res_stats "$ctx")
    [ -z "$ctx" ] && _res_header
    ui_info "${TX[res.sorting]}" "$([ "$RES_SORT" = cpu ] && echo CPU || echo RAM)"
    if [ ${#rows[@]} -eq 0 ]; then
      ui_item disabled "" "${TX[res.no_containers]}"
    fi
    for line in "${rows[@]}"; do
      IFS='|' read -r n cpu mem pct pids _ <<< "$line"
      ui_item item "c:$n" "$n" "RAM $(tl_pad "$mem" 10) $(tl_pad "($pct %)" 9) CPU $(tl_pad "$cpu %" 8) PIDs $pids" run
    done
    tf v res.key_sort "$([ "$RES_SORT" = cpu ] && echo RAM || echo CPU)"
    UI_KEYS=("s|$v" "r|${TX[res.key_remeasure]}")
    ui_menu "${TX[res.title]}" "${ctx:-${TX[res.host_docker]}} · docker stats"
    case "$UI_ACT" in
      key) [ "$UI_SEL" = s ] && { if [ "$RES_SORT" = cpu ]; then RES_SORT=mem; else RES_SORT=cpu; fi; };;
      select)
        n=${UI_SEL#c:}
        if [ -z "$ctx" ]; then
          dk_load ""; grp=$(dk_row "$n" | cut -d'|' -f6)
          [ -n "$grp" ] && [ "$grp" != "<no value>" ] || grp="-"
          screen_container "" "$grp" "$n"
        else
          screen_container "$ctx" "$ctx" "$n"
        fi;;
      *) return 0;;
    esac
  done
}

# incus list → "name|status|ram|swap|disk|limit|prozesse", nach RAM absteigend
_res_cts() {
  tq 20 incus list --format json |
    jq -r '.[]? | [.name, .status, (.state.memory.usage // 0), (.state.memory.swap_usage // 0),
      (.state.disk.root.usage // 0), (.config["limits.memory"] // ""), (.state.processes // 0)]
      | map(tostring) | join("|")' 2>/dev/null | sort -t'|' -k3,3nr
}

_res_incus() {
  local -a rows; local line n st ram swap disk lim procs rc
  while true; do
    mapfile -t rows < <(_res_cts)
    _res_header
    ui_item header "" "${TX[res.running_head]}" "" main
    for line in "${rows[@]}"; do
      IFS='|' read -r n st ram swap disk lim procs <<< "$line"
      [ "$st" = Running ] || continue
      ui_item item "ct:$n" "$n" "RAM $(tl_pad "$(tl_human "$ram")${lim:+ / $lim}" 15) Swap $(tl_pad "$(tl_human "$swap")" 7) Disk $(tl_pad "$(tl_human "$disk")" 7) ${TX[res.procs]} $procs" \
        "$([ "$swap" -gt 0 ] && echo warn || echo run)"
    done
    ui_item header "" "${TX[res.stopped_head]}" "" main
    for line in "${rows[@]}"; do
      IFS='|' read -r n st _ <<< "$line"
      [ "$st" = Running ] || ui_item item "ct:$n" "$n" "$st" stop
    done
    UI_KEYS=("r|${TX[res.key_reload]}")
    ui_menu "${TX[res.title]}" "${TX[res.sub_incus]}"
    case "$UI_ACT" in
      key) ;;
      select)
        n=${UI_SEL#ct:}
        if [ "$MODE" != layered ]; then ct_resources "$n"; continue; fi
        ct_load
        dk_ps "$n" '{{.Names}}' >/dev/null 2>&1; rc=$?
        if [ "$rc" -eq 0 ]; then _res_docker "$n"; else ui_msg warn "$n: $(dk_msg "$n" "$rc")."; fi;;
      *) return 0;;
    esac
  done
}

_t_resources() { if [ "$MODE" = docker ]; then _res_docker ""; else _res_incus; fi; }

tool_register resources "${TX[res.title]}" "${TX[res.desc]}" "all" _res_avail _t_resources 94
