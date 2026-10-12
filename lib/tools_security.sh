# shellcheck shell=bash
# tools_security.sh: Werkzeug „Sicherheits-Check“ (rein lesend).
# SSH-Fehlversuche der letzten 24 h (Anzahl, Top-IPs), letzte erfolgreiche Logins (journalctl,
# Kennungen sshd und sshd-session), sshd -T (PasswordAuthentication, PermitRootLogin …),
# öffentliche Ports (aus tools_ports.sh), unattended-upgrades, Neustart nötig.
# shellcheck disable=SC1111 # „…“ sind gewollte Anführungszeichen

_sec_avail() { have journalctl || have sshd; }

_sec_journal() { tq 30 journalctl --since "24 hours ago" -t sshd -t sshd-session -o short-iso --no-pager -q; }

# Fehlversuche → "anzahl ip" pro Zeile (häufigste zuerst); SSH_FAILS = Summe
tl_ssh_fails() {
  _sec_journal | awk '
    /Invalid user .* from / || /Failed (password|publickey|keyboard-interactive)/ || /authentication failure/ {
      for (i = 1; i < NF; i++) if ($(i + 1) == "port") { ip = $i; break }
      if (ip != "") n[ip]++; ip = "" }
    END { for (k in n) print n[k], k }' | sort -rn
}
tl_ssh_logins() { # letzte erfolgreiche Logins → "zeit|user|ip|methode"
  _sec_journal | awk '/Accepted / {
    for (i = 1; i <= NF; i++) { if ($i == "Accepted") m = $(i + 1); if ($i == "for") u = $(i + 1); if ($i == "from") ip = $(i + 1) }
    t = substr($1, 1, 16); sub("T", " ", t); print t "|" u "|" ip "|" m }' | tail -n 5
}
tl_sshd() { # → SSHD[key] aus sshd -T (root nötig), Rückgabe 1 ohne Daten
  local k v
  declare -gA SSHD=()
  have sshd || return 1
  while read -r k v; do [ -n "$k" ] && SSHD[$k]=$v; done < <(tq 10 sshd -T)
  [ ${#SSHD[@]} -gt 0 ]
}

_sec_page() {
  local n=0 sum=0 cnt ip t u m lvl f pp kn
  tl_head "${TX[sec.head.fails]}"
  while read -r cnt ip; do
    [ -n "$ip" ] || continue
    sum=$((sum + cnt)); n=$((n + 1))
    [ "$n" -le 5 ] && tl_text "$(printf '%5d' "$cnt")  $ip"
  done < <(tl_ssh_fails)
  if [ "$sum" -eq 0 ]; then tl_line ok "${TX[sec.none]}"
  else tl_line "$([ "$sum" -gt 100 ] && echo warn || echo "")" "$(t sec.fails.summary "$sum" "$n")"; fi
  tl_head "${TX[sec.head.logins]}"
  n=0
  while IFS='|' read -r t u ip m; do
    n=$((n + 1)); tl_text "$t  $(tl_pad "$u" 10) $(tl_pad "$ip" 18) $m"
  done < <(tl_ssh_logins)
  [ "$n" -gt 0 ] || tl_dim "${TX[sec.logins.none]}"
  tl_head "${TX[sec.head.sshd]}"
  if tl_sshd; then
    lvl=ok; [ "${SSHD[passwordauthentication]:-}" = yes ] && lvl=err
    tl_kv "PasswordAuthentication" "${SSHD[passwordauthentication]:-?}" "$lvl"
    lvl=ok; [ "${SSHD[kbdinteractiveauthentication]:-}" = yes ] && lvl=warn
    tl_kv "KbdInteractiveAuth" "${SSHD[kbdinteractiveauthentication]:-?}" "$lvl"
    case "${SSHD[permitrootlogin]:-}" in
      yes) lvl=err;; no) lvl=ok;; *) lvl="";;
    esac
    tl_kv "PermitRootLogin" "${SSHD[permitrootlogin]:-?}" "$lvl"
    tl_kv "Port" "${SSHD[port]:-?}"
  else
    tl_dim "${TX[sec.sshd.unavailable]}"
  fi
  if have ss; then
    tl_head "${TX[sec.head.ports]}"
    pp=$(tl_public_ports)
    if [ -n "$pp" ]; then tl_line warn "$pp"; tl_dim "$(t sec.ports.details "${TX[ports.title]}")"
    else tl_line ok "${TX[sec.none]}"; fi
  fi
  tl_head "${TX[sec.head.updates]}"
  f=$(tp /etc/apt/apt.conf.d/20auto-upgrades)
  if grep -qE 'Unattended-Upgrade +"1"' "$f" 2>/dev/null; then tl_line ok "${TX[sec.uu.active]}"
  elif [ -e "$(tp /etc/apt/apt.conf.d/50unattended-upgrades)" ]; then tl_line warn "${TX[sec.uu.off]}"
  else tl_line warn "${TX[sec.uu.missing]}"; fi
  tl_reboot
  if [ "$REBOOT_REQ" = 1 ] || tl_kernel_stale; then kn=""; [ -n "${KERNEL_NEW:-}" ] && tf kn sec.reboot.kernel "$KERNEL_NEW" "$KERNEL_RUN"
    tl_line warn "${TX[sec.reboot.needed]}${kn:+ $kn}"
  else tl_line ok "${TX[sec.reboot.none]}"; fi
  return 0
}
_t_security() { ui_run_page "${TX[sec.title]}" _sec_page; }

tool_register security "${TX[sec.title]}" "${TX[sec.desc]}" "all" _sec_avail _t_security 96
