# shellcheck shell=bash
# tools_hygiene.sh: Werkzeug „Container-Hygiene“ (nur Modus docker, rein lesend).
# Einzelcontainer ohne Compose-Projekt und ohne Restart-Policy (überleben keinen Neustart),
# gestoppte Container, Zufallsnamen (docker run ohne --name), Images ohne festen Tag oder Namen.
# Aufräumen nur als Textvorschlag.

_hyg_avail() { have docker; }

# → Zeilen "kategorie|name|text" (kategorie: norestart exited random latest noname)
tl_hygiene() {
  local -a names
  dk_load ""
  [ "$DK_RC" -eq 0 ] && [ -n "$DK_ROWS" ] || return 0
  mapfile -t names < <(printf '%s\n' "$DK_ROWS" | cut -d'|' -f1 | grep .)
  { printf '%s\n' "$DK_ROWS"; echo "--"
    dk "" inspect --format '{{.Name}}|{{.HostConfig.RestartPolicy.Name}}' "${names[@]}" 2>/dev/null
  } | awk -F'|' -v t_norst="${TX[hyg.norestart]}" -v t_proj="${TX[hyg.project]}" -v t_pol="${TX[hyg.policy]}" \
      -v t_rnd="${TX[hyg.random]}" -v t_noname="${TX[hyg.noname]}" -v t_latest="${TX[hyg.latest]}" '
    $0 == "--" { x = 1; next }
    !x { st[$1] = $2; stat[$1] = $3; img[$1] = $4; proj[$1] = ($6 == "<no value>" ? "" : $6); order[++n] = $1; next }
    { nm = $1; sub(/^\//, "", nm); pol[nm] = $2 }
    END {
      for (i = 1; i <= n; i++) { c = order[i]; p = (c in pol) ? pol[c] : "?"
        if (proj[c] == "" && (p == "no" || p == "") && st[c] == "running")
          print "norestart|" c "|" t_norst
        if (st[c] == "exited" || st[c] == "created" || st[c] == "dead")
          print "exited|" c "|" stat[c] (proj[c] != "" ? " " sprintf(t_proj, proj[c]) : "") (p != "no" && p != "?" ? sprintf(t_pol, p) : "")
        if (proj[c] == "" && c ~ /^[a-z]+_[a-z]+$/) print "random|" c "|" t_rnd
        if (img[c] ~ /^[0-9a-f]+$/ && length(img[c]) >= 12) print "noname|" c "|" sprintf(t_noname, img[c])
        else if (img[c] !~ /:/ || img[c] ~ /:latest$/) print "latest|" c "|" sprintf(t_latest, img[c])
      } }'
}

_hyg_page() {
  local -A title=([norestart]="${TX[hyg.head_norestart]}" [exited]="${TX[hyg.head_exited]}" \
    [random]="${TX[hyg.head_random]}" [noname]="${TX[hyg.head_noname]}" [latest]="${TX[hyg.head_latest]}")
  local -A lvl=([norestart]=warn [exited]=warn [random]=warn [noname]=warn [latest]="")
  local rows k c t n=0 exited=""
  rows=$(tl_hygiene)
  if [ "$DK_RC" -ne 0 ]; then tl_line warn "$(dk_msg "" "$DK_RC")"; return 0; fi
  for k in norestart exited random noname latest; do
    tl_head "${title[$k]}"
    n=0
    while IFS='|' read -r _ c t; do
      n=$((n+1)); tl_line "${lvl[$k]}" "$(tl_pad "$c" 24) $t"
      [ "$k" = exited ] && exited+=" $c"
    done < <(printf '%s\n' "$rows" | awk -F'|' -v k="$k" '$1 == k')
    [ "$n" -gt 0 ] || tl_line ok "${TX[tools.none]}"
  done
  echo
  tl_dim "${TX[hyg.restart_note]}"
  tl_hint "docker update --restart unless-stopped <name>   ${TX[hyg.hint_restart]}"
  [ -n "$exited" ] && tl_hint "docker rm$exited   ${TX[hyg.hint_rm]}"
  return 0
}
_t_hygiene() { ui_run_page "${TX[hyg.title]}" _hyg_page; }

tool_register hygiene "${TX[hyg.title]}" "${TX[hyg.desc]}" "docker" _hyg_avail _t_hygiene 100
