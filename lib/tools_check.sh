# shellcheck shell=bash
# tools_check.sh: Werkzeug „Server-Check“: eine Ampel über alle Bereiche (rein lesend).
# Nutzt die Datenfunktionen der anderen Werkzeuge (tl_*), jede Zeile führt per Auswahl ins
# zuständige Werkzeug. Reihenfolge: Fehler, Warnungen, dann alles in Ordnung.
# shellcheck disable=SC2034 # UI_* liest ui.sh

# → Zeilen "stufe|text|werkzeug-id"
_chk_collect() {
  local n pct mt ma st sf f p drv used total src pp cnt ip sum=0 nip=0 u v
  if have systemctl; then
    n=$(tl_failed_units | grep -c .)
    if [ "$n" -gt 0 ]; then tf v check.failed_units "$n" "$(tl_failed_units | cut -f1 | head -n 3 | paste -sd' ')"; echo "err|$v|services"
    else echo "ok|${TX[check.no_failed_units]}|services"; fi
  fi
  while IFS='|' read -r pct u _; do
    [ "$pct" -ge 80 ] && { tf v check.fs_full "$u" "$pct"; echo "$(tl_lvl "$pct" 80 90)|$v|storage"; }
  done < <(tl_df_rows)
  read -r mt ma st sf < <(tl_meminfo)
  if [ "${mt:-0}" -gt 0 ]; then
    pct=$(( (mt - ma) * 100 / mt ))
    tf v check.ram "$pct"; echo "$(tl_lvl "$pct" 80 90)|$v|sysinfo"
  fi
  if [ "${st:-0}" -gt 0 ]; then
    pct=$(( (st - sf) * 100 / st ))
    [ "$pct" -ge 60 ] && { tf v check.swap "$pct"; echo "$(tl_lvl "$pct" 60 90)|$v|sysinfo"; }
  fi
  if [ "$MODE" != docker ] && have incus; then
    while IFS='|' read -r p drv used total src; do
      [ "$total" -gt 0 ] || continue
      pct=$(( used * 100 / total ))
      tf v check.pool_full "$p" "$pct" "$(tl_human "$used")" "$(tl_human "$total")"; echo "$(tl_lvl "$pct" 75 90)|$v|storage"
    done < <(tl_pools)
    n=$(tl_snapshots | grep -c .)
    [ "$n" -gt 0 ] && { tf v check.snapshots "$n" "$(tl_snapshots | cut -d'|' -f1,2 | tr '|' / | head -n 3 | paste -sd' ')"; echo "warn|$v|storage"; }
  fi
  if [ "$MODE" != incus ] && { have docker || have incus; }; then
    n=$(tl_ctr_issues | grep -c .)
    if [ "$n" -gt 0 ]; then tf v check.ctr_issues "$n" "$(tl_ctr_issues | cut -d'|' -f2,3 | tr '|' / | sed 's|^/||' | head -n 3 | paste -sd' ')"
      echo "$(tl_ctr_issues | grep -q '^err' && echo err || echo warn)|$v|errlog"
    else echo "ok|${TX[check.no_ctr_issues]}|errlog"; fi
  fi
  if [ "$MODE" = docker ] && have docker; then
    n=$(tl_hygiene | awk -F'|' '$1 == "norestart" || $1 == "exited"' | grep -c .)
    [ "$n" -gt 0 ] && { tf v check.hygiene "$n"; echo "warn|$v|hygiene"; }
  fi
  if have apt; then
    tl_updates
    if [ "$UPD_SEC" -gt 0 ]; then tf v check.updates_sec "$UPD_ALL" "$UPD_SEC"; echo "err|$v|updates"
    elif [ "$UPD_ALL" -gt 0 ]; then tf v check.updates "$UPD_ALL"; echo "warn|$v|updates"
    else echo "ok|${TX[check.no_updates]}|updates"; fi
    [ "$UPD_AGE" -gt 604800 ] && echo "warn|${TX[check.lists_old]}|updates"
  fi
  tl_reboot
  if [ "$REBOOT_REQ" = 1 ] || tl_kernel_stale; then
    if [ -n "${KERNEL_NEW:-}" ]; then tf v check.reboot_kernel "$KERNEL_NEW"; else v=${TX[check.reboot]}; fi
    echo "warn|$v|updates"
  fi
  if have ss; then
    pp=$(tl_public_ports)
    [ -n "$pp" ] && { tf v check.public "$pp"; echo "warn|$v|ports"; }
  fi
  if tl_sshd; then
    [ "${SSHD[passwordauthentication]:-}" = yes ] && echo "err|${TX[check.sshd_password]}|security"
    [ "${SSHD[permitrootlogin]:-}" = yes ] && echo "err|${TX[check.sshd_root]}|security"
  fi
  if have journalctl; then
    while read -r cnt ip; do [ -n "$ip" ] && { sum=$((sum + cnt)); nip=$((nip + 1)); }; done < <(tl_ssh_fails)
    [ "$sum" -gt 0 ] && { tf v check.ssh_fails "$sum" "$nip"; echo "$([ "$sum" -gt 100 ] && echo warn || echo ok)|$v|security"; }
    n=$(tl_journal_errs | awk -F'\t' '{ s += $1 } END { print s + 0 }')
    [ "$n" -gt 0 ] && { tf v check.journal_errs "$n"; echo "warn|$v|errlog"; }
  fi
  return 0
}

_t_check() {
  local -a rows; local line lvl text id st nerr nwarn v
  while true; do
    # TUI: Lade-Hinweis, der mit dem fertigen Frame verschwindet (ui_note bliebe als Status stehen)
    if _ui_tui_on; then ui_loading "${TX[check.checking]}"; else ui_note info "${TX[check.checking]}$UI_SYM_ELL"; fi
    mapfile -t rows < <(_chk_collect | awk -F'|' '{ o = ($1 == "err" ? 1 : ($1 == "warn" ? 2 : 3)); print o "|" $0 }' | sort -t'|' -s -k1,1n | cut -d'|' -f2-)
    nerr=0 nwarn=0
    for line in "${rows[@]}"; do
      IFS='|' read -r lvl text id <<< "$line"
      case "$lvl" in err) st=err; nerr=$((nerr+1));; warn) st=warn; nwarn=$((nwarn+1));; *) st=run;; esac
      if tool_available "$id"; then ui_item item "$id" "$text" "${TOOL_TITLE[$id]}" "$st"
      else ui_item disabled "" "$text"; fi
    done
    [ ${#rows[@]} -gt 0 ] || ui_item disabled "" "${TX[check.nothing]}"
    if [ "$nerr" -gt 0 ]; then st=err; elif [ "$nwarn" -gt 0 ]; then st=warn; else st=run; fi
    tf v check.result_counts "$nerr" "$nwarn"; ui_info "${TX[check.result]}" "$v" "$st"
    UI_KEYS=("r|${TX[check.key_recheck]}")
    ui_menu "${TX[check.title]}" "${TX[check.sub]}"
    case "$UI_ACT" in
      select) tool_run "$UI_SEL";;
      key) ;;
      *) return 0;;
    esac
  done
}

tool_register check "${TX[check.title]}" "${TX[check.desc]}" "all" - _t_check 91
