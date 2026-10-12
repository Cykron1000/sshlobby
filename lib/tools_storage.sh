# shellcheck shell=bash
# tools_storage.sh: Werkzeug „Speicherplatz“ (rein lesend, Aufräumen nur als Textvorschlag).
# Alle Modi: Dateisysteme (df), Journal-Größe. docker: docker system df, größte und ungenutzte
# Images, Volumes, Build-Cache. incus/layered: Storage-Pools (incus query …/resources, Loop-Datei-
# Pools hervorgehoben), Disk je CT und vorhandene Incus-Snapshots als Warnung.
# shellcheck disable=SC2016 # jq-Programme in einfachen Anführungszeichen

_sto_avail() { have df; }

# Storage-Pools → "name|treiber|belegt|gesamt|quelle"
tl_pools() {
  local p drv src used total
  have incus || return 0
  while IFS='|' read -r p drv src; do
    [ -n "$p" ] || continue
    read -r used total < <(tq 15 incus query "/1.0/storage-pools/$p/resources" |
      jq -r '"\(.space.used // 0) \(.space.total // 0)"' 2>/dev/null)
    printf '%s|%s|%s|%s|%s\n' "$p" "$drv" "${used:-0}" "${total:-0}" "$src"
  done < <(tq 15 incus query "/1.0/storage-pools?recursion=1" |
             jq -r '.[]? | "\(.name)|\(.driver)|\(.config.source // "")"' 2>/dev/null)
}
# Incus-Snapshots → "ct|snapshot|angelegt"
tl_snapshots() {
  have incus || return 0
  tq 20 incus list --format json |
    jq -r '.[]? | .name as $c | (.snapshots // [])[] | "\($c)|\(.name)|\(.created_at // "" | .[0:16] | sub("T"; " "))"' 2>/dev/null
}

# journalctl --disk-usage: „Archived and active journals take up X in the file system.“ → „X belegt“
_sto_journal_usage() {
  local l re='^Archived and active journals take up (.*) in the file system\.(.*)$'
  while IFS= read -r l || [ -n "$l" ]; do
    [[ $l =~ $re ]] && { tf l storage.journal.used "${BASH_REMATCH[1]}"; l+=${BASH_REMATCH[2]}; }
    printf '%s\n' "$l"
  done
}

_sto_page() {
  local p drv used total src pct n ct snap at
  tl_head "${TX[storage.head.fs]}"
  tl_df_page
  if have journalctl; then
    tl_head "Journal"
    tl_text "$(tq 10 journalctl --disk-usage | _sto_journal_usage)"
    tl_hint "journalctl --vacuum-size=500M"
  fi
  if [ "$MODE" != docker ]; then
    tl_head "${TX[storage.head.pools]}"
    n=0
    while IFS='|' read -r p drv used total src; do
      n=$((n+1))
      if [ "$total" -gt 0 ]; then pct=$(( used * 100 / total )); else pct=0; fi
      tl_line "$(tl_lvl "$pct" 75 90)" "$(tl_pad "$p" 14) $(tl_pad "$drv" 8) $(tl_human "$used") / $(tl_human "$total") ($pct %)"
      if [[ $src == *.img ]] || [[ $src == /var/lib/incus/disks/* ]]; then
        tl_dim "    $(t storage.pool.loop "$src")"
      fi
    done < <(tl_pools)
    [ "$n" -gt 0 ] || tl_dim "${TX[storage.pool.none]}"
    tl_head "${TX[storage.head.ct_disk]}"
    tq 20 incus list --format json | jq -r '.[]? | select(.state.disk.root.usage != null)
      | "\(.state.disk.root.usage)|\(.name)"' 2>/dev/null | sort -t'|' -k1,1nr | head -n 12 |
      while IFS='|' read -r used ct; do tl_text "$(tl_pad "$(tl_human "$used")" 8) $ct"; done
    tl_head "${TX[storage.head.snapshots]}"
    n=0
    while IFS='|' read -r ct snap at; do
      [ -n "$ct" ] || continue
      n=$((n+1)); tl_line warn "$(tl_pad "$ct/$snap" 30) $at"
    done < <(tl_snapshots)
    if [ "$n" -gt 0 ]; then
      tl_dim "${TX[storage.snap.hint]}"
      tl_hint "incus delete <ct>/<snapshot>"
    else
      tl_line ok "${TX[storage.none]}"
    fi
  fi
  if [ "$MODE" = docker ] && have docker; then
    tl_head "Docker (docker system df)"
    dk "" system df 2>/dev/null | sed 's/^/  /'
    _sto_docker_detail
  fi
  return 0
}

_sto_docker_detail() {
  local json use
  json=$(dk "" system df -v --format '{{json .}}' 2>/dev/null)
  [ -n "$json" ] || return 0
  tl_head "${TX[storage.head.images]}"
  jq -r "$TL_JQ_BYTES"' .Images[]? | [(.Size | bytes), "\(.Repository):\(.Tag)", .Size, (.Containers | tostring)] | @tsv' <<< "$json" 2>/dev/null |
    sort -t "$(printf '\t')" -k1,1gr | head -n 8 | while IFS=$'\t' read -r _ name size cnt; do
      [ "$name" = "<none>:<none>" ] && name=${TX[storage.img.noname]}
      if [ "$cnt" = 0 ]; then use=${TX[storage.img.unused]}; elif [ "$cnt" = 1 ]; then use=${TX[storage.container_one]}; else tf use storage.containers "$cnt"; fi
      tl_text "$(tl_pad "$size" 8) $(tl_pad "$name" 60) $use"
    done
  local unused dangling
  unused=$(jq -r '[.Images[]? | select(.Containers == "0" or .Containers == 0)] | length' <<< "$json" 2>/dev/null)
  dangling=$(jq -r '[.Images[]? | select(.Repository == "<none>" and (.Containers == "0" or .Containers == 0))] | length' <<< "$json" 2>/dev/null)
  tl_line "$([ "${unused:-0}" -gt 0 ] && echo warn || echo ok)" "$(t storage.img.summary "${unused:-0}" "${dangling:-0}")"
  [ "${dangling:-0}" -gt 0 ] && tl_hint "docker image prune   ${TX[storage.img.prune_dangling]}"
  [ "${unused:-0}" -gt 0 ] && tl_hint "docker image prune -a   ${TX[storage.img.prune_all]}"
  tl_head "${TX[storage.head.volumes]}"
  jq -r '.Volumes[]? | "\(.Size)|\(.Links)|\(.Name)"' <<< "$json" 2>/dev/null | while IFS='|' read -r size links name; do
    if [ "$links" = 0 ]; then use=${TX[storage.vol.orphan]}; elif [ "$links" = 1 ]; then use=${TX[storage.container_one]}; else tf use storage.containers "$links"; fi
    tl_text "$(tl_pad "$size" 8) $(tl_pad "$(tl_cut "$name" 40)" 40) $use"
  done
  local cache
  cache=$(dk "" system df 2>/dev/null | awk '/^Build Cache/ {print $(NF-1)}')
  if [ -n "$cache" ] && [ "$cache" != "0B" ]; then
    tl_line warn "$(t storage.cache "$cache")"; tl_hint "docker builder prune"
  fi
}

_t_storage() { ui_run_page "${TX[storage.title]}" _sto_page; }

tool_register storage "${TX[storage.title]}" "${TX[storage.desc]}" "all" _sto_avail _t_storage 95
