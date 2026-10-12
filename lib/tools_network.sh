# shellcheck shell=bash
# tools_network.sh: Werkzeug „Netzwerk & Zugänge“ (rein lesend), jeder Abschnitt nur, wenn
# vorhanden: Tailscale (tailscale status), cloudflared (Dienste und Ingress aus
# /etc/cloudflared/config.yml), Caddy-Sites aus /etc/caddy/Caddyfile, WireGuard (wg show all dump,
# private Schlüssel werden nie ausgegeben).

_net_caddyfile() { tp /etc/caddy/Caddyfile; }
_net_avail() { have tailscale || have cloudflared || have wg || [ -r "$(_net_caddyfile)" ]; }

_net_svc_state() { # muster → Zeilen "unit active/sub"
  have systemctl || return 0
  tq 10 systemctl list-units --all -o json --no-pager -- "$1" |
    jq -r '.[]? | select(.load != "not-found") | "\(.unit) \(.active)/\(.sub)"' 2>/dev/null
}
_net_svc_lines() { # muster
  local u st
  while read -r u st; do
    [ -n "$u" ] || continue
    case "$st" in active/running|active/exited) tl_line ok "$(tl_pad "$u" 28) $st";; failed/*) tl_line err "$(tl_pad "$u" 28) $st";; *) tl_line "" "$(tl_pad "$u" 28) $st";; esac
  done < <(_net_svc_state "$1")
}

_net_tailscale() {
  local out self
  out=$(tq 10 tailscale status)
  if [ -z "$out" ]; then tl_line warn "${TX[net.ts.empty]}"; return 0; fi
  self=$(printf '%s\n' "$out" | awk 'NF >= 4 && $1 !~ /^#/ {print; exit}')
  tl_kv "${TX[net.ts.self]}" "$(awk '{print $2 " " $1}' <<< "$self")"
  [[ $self == *"offers exit node"* ]] && tl_kv "${TX[net.ts.exit_node]}" "${TX[net.ts.exit_offered]}" ok
  [[ $self == *"exit node"* ]] || tl_kv "${TX[net.ts.exit_node]}" "${TX[net.ts.exit_not_offered]}"
  printf '%s\n' "$out" | awk 'NF >= 4 && $1 !~ /^#/ && NR > 1' | while read -r ip name _ os rest; do
    case "$rest" in
      offline*) tl_line dim "$(tl_pad "$name" 24) $(tl_pad "$ip" 16) $(tl_pad "$os" 7) $rest";;
      active*)  tl_line ok "$(tl_pad "$name" 24) $(tl_pad "$ip" 16) $(tl_pad "$os" 7) $(tl_cut "$rest" 40)";;
      *)        tl_line "" "$(tl_pad "$name" 24) $(tl_pad "$ip" 16) $(tl_pad "$os" 7) ${rest#-}";;
    esac
  done
  printf '%s\n' "$out" | awk '/^#[[:space:]]+- / { sub(/^#[[:space:]]+- /, ""); print }' |
    while IFS= read -r l; do tl_line warn "$l"; done
}

_net_cloudflared() {
  local f
  _net_svc_lines 'cloudflared*'
  for f in "$(tp /etc/cloudflared)"/*.yml "$(tp /etc/cloudflared)"/*.yaml; do
    [ -r "$f" ] || continue
    tl_dim "$(t net.cf.ingress "${f#"${PD_TOOLS_ROOT:-}"}")"
    awk -v fb="${TX[net.cf.fallback]}" '/hostname:/ { h = $NF } /service:/ { if (h != "") printf "    %s → %s\n", h, $NF; else printf "    %s → %s\n", fb, $NF; h = "" }' "$f"
  done
}

_net_caddy() {
  _net_svc_lines 'caddy*'
  # Site-Blöcke auf oberster Ebene: Adresse(n) und erstes reverse_proxy-Ziel bzw. file_server
  awk -v files="${TX[net.caddy.files]}" '{ line = $0; sub(/#.*/, "", line) }
    line ~ /^[[:space:]]*$/ { next }
    depth == 0 && line ~ /\{[[:space:]]*$/ {
      a = line; sub(/[[:space:]]*\{[[:space:]]*$/, "", a); gsub(/^[[:space:]]+/, "", a)
      site = (a != "" && a !~ /^\(/) ? a : ""; tgt = "" }
    depth == 1 && site != "" && tgt == "" && line ~ /^[[:space:]]*reverse_proxy/ { n = split(line, f, " "); tgt = "→ " f[2] }
    depth == 1 && site != "" && tgt == "" && line ~ /^[[:space:]]*file_server/ { tgt = files }
    { o = gsub(/\{/, "{", line); c = gsub(/\}/, "}", line); depth += o - c
      if (depth == 0 && site != "") { printf "    %s %s\n", site, tgt; site = "" } }' "$(_net_caddyfile)"
}

_net_wireguard() {
  local out
  out=$(tq 10 wg show all dump)
  if [ -z "$out" ]; then tl_dim "${TX[net.wg.none]}"; return 0; fi
  # Schnittstellenzeile: if privkey pubkey port fwmark (privkey NIE ausgeben)
  # Peerzeile: if pubkey psk endpoint allowed-ips handshake rx tx keepalive
  printf '%s\n' "$out" | awk -F'\t' -v now="$(date +%s)" '
    function hum(b) { if (b >= 1073741824) return sprintf("%.1fG", b / 1073741824); if (b >= 1048576) return sprintf("%.1fM", b / 1048576)
      if (b >= 1024) return sprintf("%.1fK", b / 1024); return b "B" }
    NF == 5 { printf "IF %s|%s\n", $1, $4; next }
    NF >= 9 { age = ($6 == 0) ? "never" : (now - $6 < 180 ? "ok" : int((now - $6) / 60))
      printf "PEER %s|%s|%s|%s|%s|%s\n", substr($2, 1, 8) "…", $4, $5, age, hum($7), hum($8) }' |
  while read -r kind rest; do
    if [ "$kind" = IF ]; then tl_kv "${TX[net.wg.interface]}" "$(t net.wg.if_port "${rest%%|*}" "${rest#*|}")"; continue; fi
    IFS='|' read -r key ep ips age rx tx <<< "$rest"
    local lvl=""
    case "$age" in
      ok) lvl=ok;; never) lvl=warn; age=${TX[net.wg.never]};; *) age=$(t net.wg.minutes "$age");;
    esac
    tl_line "$lvl" "$(t net.wg.peer "$key" "$(tl_pad "$ips" 18)" "$(tl_pad "$ep" 22)" "$(tl_pad "$age" 8)" "$rx" "$tx")"
  done
}

_net_page() {
  if have tailscale; then tl_head "Tailscale"; _net_tailscale; fi
  if have cloudflared; then tl_head "Cloudflare Tunnel (cloudflared)"; _net_cloudflared; fi
  if [ -r "$(_net_caddyfile)" ]; then tl_head "${TX[net.head.caddy]}"; _net_caddy; fi
  if have wg; then tl_head "WireGuard"; _net_wireguard; fi
  return 0
}
_t_network() { ui_run_page "${TX[net.title]}" _net_page; }

tool_register network "${TX[net.title]}" "${TX[net.desc]}" "all" _net_avail _t_network 99
