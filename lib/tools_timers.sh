# shellcheck shell=bash
# tools_timers.sh: Werkzeug „Timer & Cron“ (rein lesend).
# systemctl list-timers -o json (nächster und letzter Lauf, fehlgeschlagene Ziel-Units markiert),
# /etc/crontab, /etc/cron.d/*, crontab -l des aktuellen Benutzers, /etc/cron.{hourly,daily,…}.

_tim_avail() { have systemctl || have crontab || [ -d "$(tp /etc/cron.d)" ]; }

_tim_when() { # epoch-sekunden → "Mo 12.10. 22:30"
  if [ -z "$1" ] || [ "$1" = 0 ]; then printf '–'; return; fi
  date -d "@$1" '+%a %d.%m. %H:%M' 2>/dev/null || printf '%s' "$1"
}
_tim_left() { # epoch → "in 3 h"
  local d=$(( $1 - $(date +%s) ))
  if [ "$d" -lt 0 ]; then printf '%s' "${TX[timers.left.overdue]}"
  elif [ "$d" -lt 3600 ]; then t timers.left.min $((d / 60))
  elif [ "$d" -lt 172800 ]; then t timers.left.hours $((d / 3600))
  else t timers.left.days $((d / 86400)); fi
}

_tim_cron_file() { # datei mit-benutzerfeld(0|1): Jobs ohne Kommentare und Variablen
  awk -v u="$2" '/^[[:space:]]*(#|$)/ { next } /^[A-Za-z_][A-Za-z0-9_]*[[:space:]]*=/ { next }
    { if ($1 ~ /^@/) { s = $1; f = 2 } else { s = $1 " " $2 " " $3 " " $4 " " $5; f = 6 }
      who = ""; if (u == 1) { who = $f; f++ }
      cmd = ""; for (i = f; i <= NF; i++) cmd = cmd (cmd == "" ? "" : " ") $i
      printf "%-16s %-6s %s\n", s, who, cmd }' "$1" 2>/dev/null | cut -c1-120 | sed 's/^/  /'
}

_tim_page() {
  local nxt last unit act failed f d out rp=0
  if have systemctl; then
    tl_head "${TX[timers.head.systemd]}"
    failed=" $(tl_failed_units | cut -f1 | tr '\n' ' ') "
    while IFS='|' read -r nxt last unit act; do
      [ -n "$unit" ] || continue
      if [ "$nxt" = 0 ]; then out="$(tl_pad "–" 16) $(tl_pad "" 11)"
      else out="$(tl_pad "$(_tim_when "$nxt")" 16) $(tl_pad "$(_tim_left "$nxt")" 11)"; fi
      out+=" $(tl_pad "${unit%.timer}" 26) $(t timers.last "$(_tim_when "$last")")"
      if [[ $failed == *" $act "* ]]; then tl_line err "$out  $(t timers.failed "$act")"
      else tl_line "" "$out"; fi
    done < <(tq 15 systemctl list-timers --all -o json --no-pager |
      jq -r '.[]? | [((.next // 0) / 1000000 | floor), ((.last // 0) / 1000000 | floor), .unit, (.activates // "")]
        | map(tostring) | join("|")' 2>/dev/null | sort -t'|' -k1,1n | awk -F'|' '$1 != 0' ;
      tq 15 systemctl list-timers --all -o json --no-pager |
      jq -r '.[]? | select(.next == null) | ["0", ((.last // 0) / 1000000 | floor | tostring), .unit, (.activates // "")] | join("|")' 2>/dev/null)
  fi
  if have crontab; then
    tl_head "crontab -l ($(id -un 2>/dev/null || echo root))"
    out=$(tq 5 crontab -l)
    if [ -n "$out" ]; then printf '%s\n' "$out" > "${TMPDIR:-/tmp}/sshlobby-cron.$$"; _tim_cron_file "${TMPDIR:-/tmp}/sshlobby-cron.$$" 0; rm -f "${TMPDIR:-/tmp}/sshlobby-cron.$$"
    else tl_dim "${TX[timers.no_crontab]}"; fi
  fi
  f=$(tp /etc/crontab)
  if [ -r "$f" ]; then tl_head "/etc/crontab"; _tim_cron_file "$f" 1; fi
  for f in "$(tp /etc/cron.d)"/*; do
    [ -f "$f" ] || continue
    case "${f##*/}" in *.dpkg-*|.placeholder) continue;; esac
    tl_head "/etc/cron.d/${f##*/}"; _tim_cron_file "$f" 1
  done
  for d in hourly daily weekly monthly; do
    f=$(tp "/etc/cron.$d")
    [ -d "$f" ] || continue
    out=$(find "$f" -maxdepth 1 -type f ! -name '.placeholder' -printf '%f\n' 2>/dev/null | sort | paste -sd' ')
    [ -n "$out" ] || continue
    [ "$rp" = 1 ] || tl_head "${TX[timers.head.run_parts]}"
    rp=1; tl_kv "cron.$d" "$out"
  done
  return 0
}
_t_timers() { ui_run_page "${TX[timers.title]}" _tim_page; }

tool_register timers "${TX[timers.title]}" "${TX[timers.desc]}" "all" _tim_avail _t_timers 98
