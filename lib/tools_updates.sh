# shellcheck shell=bash
# tools_updates.sh: Werkzeug „Updates“.
# Anzeige: apt list --upgradable aus dem vorhandenen Paket-Cache (Alter wird angezeigt), Security-Updates
# getrennt, /var/run/reboot-required, laufender gegen neuesten installierten Kernel.
# Aktionen (nur nach Rückfrage): Paketlisten aktualisieren, Security-Updates oder alle Updates
# installieren (apt-get, behält geänderte Konfigdateien), Server neu starten (Hostname eintippen).
# Installationen laufen in einer tmux-Sitzung „sshlobby-apt“, wenn tmux da ist: Bricht die
# SSH-Verbindung ab, läuft apt weiter und die Sitzung lässt sich wieder öffnen.

# shellcheck disable=SC1111,SC2016 # „…“ gewollt, $-Ausdrücke in _UPD_SCRIPT laufen erst im apt-Skript
_upd_avail() { have apt; }

# → UPD_ALL UPD_SEC (Anzahl), UPD_SECPKG (Namen), UPD_AGE (Sekunden seit dem letzten apt update, -1 = unbekannt)
tl_updates() {
  local out newest
  UPD_ALL=0 UPD_SEC=0 UPD_SECPKG="" UPD_AGE=-1
  out=$(tq 60 apt list --upgradable | grep '/')
  if [ -n "$out" ]; then
    UPD_ALL=$(printf '%s\n' "$out" | grep -c .)
    UPD_SECPKG=$(printf '%s\n' "$out" | awk -F'[/ ]' '$2 ~ /security/ {print $1}')
    UPD_SEC=$(printf '%s\n' "$UPD_SECPKG" | grep -c .)
  fi
  newest=$(find "$(tp /var/lib/apt/lists)" -maxdepth 1 -type f -name '*Packages*' -printf '%T@\n' 2>/dev/null |
    sort -n | tail -n 1)
  [ -n "$newest" ] && UPD_AGE=$(( $(date +%s) - ${newest%.*} ))
  return 0
}
# → REBOOT_REQ (0|1), REBOOT_PKGS, KERNEL_RUN, KERNEL_NEW
tl_reboot() {
  local f; f=$(tp /var/run/reboot-required)
  REBOOT_REQ=0 REBOOT_PKGS=""
  if [ -e "$f" ]; then REBOOT_REQ=1; REBOOT_PKGS=$(tr '\n' ' ' < "$f.pkgs" 2>/dev/null); fi
  KERNEL_RUN=$(uname -r 2>/dev/null)
  KERNEL_NEW=$(find "$(tp /boot)" -maxdepth 1 -name 'vmlinuz-*' -printf '%f\n' 2>/dev/null | sed 's/^vmlinuz-//' | sort -V | tail -n 1)
}
tl_kernel_stale() { [ -n "$KERNEL_NEW" ] && [ -n "$KERNEL_RUN" ] && [ "$KERNEL_NEW" != "$KERNEL_RUN" ]; }

_upd_page() {
  local age_txt lvl
  tl_updates; tl_reboot
  tl_head "${TX[upd.head.packages]}"
  if [ "$UPD_AGE" -lt 0 ]; then age_txt=${TX[upd.unknown]}; lvl=warn
  else age_txt="$(rel_time $(( $(date +%s) - UPD_AGE )))"; lvl=$([ "$UPD_AGE" -gt 604800 ] && echo warn || echo ok); fi
  tl_kv "${TX[upd.lists]}" "$(t upd.lists.updated "$age_txt")" "$lvl"
  [ "$lvl" = warn ] && tl_dim "${TX[upd.lists.stale]}"
  tl_kv "${TX[upd.pending]}" "$UPD_ALL" "$([ "$UPD_ALL" -gt 0 ] && echo warn || echo ok)"
  tl_kv "${TX[upd.pending_sec]}" "$UPD_SEC" "$([ "$UPD_SEC" -gt 0 ] && echo err || echo ok)"
  if [ "$UPD_SEC" -gt 0 ]; then
    tl_head "${TX[upd.head.security]}"
    printf '%s\n' "$UPD_SECPKG" | awk '{ if (length(l) + length($0) > 94) { print "  " l; l = "" } l = l (l == "" ? "" : " ") $0 }
      END { if (l != "") print "  " l }'
  fi
  tl_head "${TX[upd.head.reboot]}"
  if [ "$REBOOT_REQ" = 1 ]; then tl_line warn "${TX[upd.reboot.required]}${REBOOT_PKGS:+: $REBOOT_PKGS}"
  else tl_line ok "${TX[upd.reboot.none]}"; fi
  tl_kv "${TX[upd.kernel.running]}" "${KERNEL_RUN:-?}"
  if tl_kernel_stale; then tl_kv "${TX[upd.kernel.installed]}" "$(t upd.kernel.newer "$KERNEL_NEW")" warn
  else tl_kv "${TX[upd.kernel.installed]}" "${KERNEL_NEW:-?}" ok; fi
  return 0
}
UPD_TMUX=${SSHLOBBY_APT_SESSION:-sshlobby-apt}   # Tests setzen einen eigenen Namen, nie die echte Sitzung
UPD_DONE="$CONF_DIR/apt-last"                     # „rc epoch“, sobald der Lauf in tmux fertig ist

# Ablauf für apt im Vordergrund: modus refresh|sec|all. Läuft in eigenem bash (ohne TX), die Texte
# setzt _upd_script davor (tx_sec tx_none tx_done tx_fail tx_reboot).
_UPD_SCRIPT='set -u
m=$1; export DEBIAN_FRONTEND=noninteractive
apt_() { apt-get -o DPkg::Lock::Timeout=120 -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold "$@"; }
echo "== apt-get update"; apt_ update; rc=$?
if [ "$rc" -eq 0 ] && [ "$m" = sec ]; then
  pk=$(apt list --upgradable 2>/dev/null | awk -F"[/ ]" "\$2 ~ /security/ {print \$1}")
  if [ -n "$pk" ]; then echo "== $tx_sec" $pk; apt_ -y install --only-upgrade $pk; rc=$?
  else echo "$tx_none"; fi
elif [ "$rc" -eq 0 ] && [ "$m" = all ]; then
  echo "== apt-get upgrade"; apt_ -y --with-new-pkgs upgrade; rc=$?
fi
echo; if [ "$rc" -eq 0 ]; then echo "$tx_done"; else printf -- "$tx_fail\n" "$rc"; fi
[ -e /var/run/reboot-required ] && printf -- "$tx_reboot\n" /var/run/reboot-required
exit "$rc"'
_upd_script() { # → _UPD_SCRIPT mit den Texten der gewählten Sprache davor
  printf 'tx_sec=%q tx_none=%q tx_done=%q tx_fail=%q tx_reboot=%q\n%s\n' "${TX[upd.run.security]}" \
    "${TX[upd.run.no_security]}" "${TX[upd.run.done]}" "${TX[upd.run.failed]}" "${TX[upd.run.reboot]}" "$_UPD_SCRIPT"
}

_upd_session() { have tmux && tmux has-session -t "$UPD_TMUX" 2>/dev/null; } # Sitzung da (läuft oder fertig)
_upd_running() { _upd_session && [ ! -e "$UPD_DONE" ]; }                       # apt läuft noch
_upd_done_rc() { local rc _; read -r rc _ < "$UPD_DONE" 2>/dev/null; printf '%s' "${rc:-?}"; }

_upd_run() { # modus: im Vordergrund, wenn möglich in tmux (überlebt Verbindungsabbruch)
  local f rc cl
  if have tmux && [ -t 0 ] && [ -z "${TMUX:-}" ]; then
    f=$(mktemp "${TMPDIR:-/tmp}/sshlobby-apt.XXXXXX") || return 1
    _upd_script > "$f"
    # beendete Sitzung vom letzten Mal (wartet nur noch auf Enter) schließen, Fertig-Markierung zurücksetzen
    _upd_session && [ -e "$UPD_DONE" ] && tmux kill-session -t "$UPD_TMUX" 2>/dev/null
    rm -f "$UPD_DONE"; mkdir -p "$CONF_DIR"
    cl=${TX[upd.run.close]}; cl=${cl//\'/\'\\\'\'}   # für '…' im sh von tmux
    tmux new-session -s "$UPD_TMUX" "bash '$f' '$1'; rc=\$?; echo \"\$rc \$(date +%s)\" > '$UPD_DONE'; rm -f '$f'; printf '\n%s' '$cl'; read -r _; exit \$rc"
    rc=$?
  else
    bash -c "$(_upd_script)" bash "$1"; rc=$?
    ui_pause
  fi
  return "$rc"
}

_upd_docker_note() { # Hinweis, wenn Docker-Pakete im Update sind
  tq 60 apt list --upgradable | grep -qE '^(docker-ce|docker-ce-cli|containerd\.io|docker\.io|containerd)/' &&
    ui_note warn "${TX[upd.docker_note]}"
  return 0
}

_t_updates() {
  local h age lvl
  while true; do
    tl_updates; tl_reboot
    if [ "$UPD_AGE" -lt 0 ]; then age=${TX[upd.unknown]}; else age="$(rel_time $(( $(date +%s) - UPD_AGE )))"; fi
    if [ "$UPD_SEC" -gt 0 ]; then lvl=err; elif [ "$UPD_ALL" -gt 0 ]; then lvl=warn; else lvl=ok; fi
    ui_info "${TX[upd.info.pending]}" "$(t upd.info.pending_val "$UPD_ALL" "$UPD_SEC")" "$lvl"
    ui_info "${TX[upd.lists]}" "$(t upd.lists.updated "$age")" "$([ "$UPD_AGE" -ge 0 ] && [ "$UPD_AGE" -le 604800 ] && echo ok || echo warn)"
    if [ "$REBOOT_REQ" = 1 ] || tl_kernel_stale; then ui_info "${TX[upd.head.reboot]}" "$(t upd.info.reboot "${KERNEL_RUN:-?}" "${KERNEL_NEW:-?}")" warn; fi
    if _upd_running; then ui_item item attach "${TX[upd.item.attach_running]}" "$(t upd.item.attach_running_desc "$UPD_TMUX")"
    elif _upd_session; then ui_item item attach "${TX[upd.item.attach_done]}" "$(t upd.item.attach_done_desc "$(_upd_done_rc)")"; fi
    ui_item item show "${TX[upd.item.show]}" "${TX[upd.item.show_desc]}"
    ui_item item list "${TX[upd.item.list]}" "apt list --upgradable"
    ui_item item refresh "${TX[upd.item.refresh]}" "apt-get update"
    [ "$UPD_SEC" -gt 0 ] && ui_item item sec "${TX[upd.item.sec]}" "$(t upd.item.sec_desc "$UPD_SEC")"
    [ "$UPD_ALL" -gt 0 ] && ui_item item all "${TX[upd.item.all]}" "${TX[upd.item.all_desc]}"
    if [ "$REBOOT_REQ" = 1 ] || tl_kernel_stale; then ui_item item reboot "${TX[upd.item.reboot]}" "${TX[upd.item.reboot_desc]}" danger; fi
    ui_menu "${TX[upd.title]}" "apt"
    case "$UI_ACT" in
      back|quit|eof) return 0;;
      select)
        case "$UI_SEL" in
          attach)  ui_run_fg tmux attach -t "$UPD_TMUX";;
          show)    ui_run_page "${TX[upd.title]}" _upd_page;;
          list)    ui_run_page "apt list --upgradable" apt list --upgradable;;
          refresh) ui_run_fg _upd_run refresh;;
          sec)     _upd_running && { ui_msg warn "$(t upd.busy "$UPD_TMUX")"; continue; }
                   _upd_docker_note
                   ui_confirm "$(t upd.confirm.sec "$UPD_SEC")" && ui_run_fg _upd_run sec;;
          all)     _upd_running && { ui_msg warn "$(t upd.busy "$UPD_TMUX")"; continue; }
                   _upd_docker_note
                   ui_confirm "$(t upd.confirm.all "$UPD_ALL")" && ui_run_fg _upd_run all;;
          reboot)
            h=$(hostname 2>/dev/null)
            ui_note warn "${TX[upd.reboot.warn]}"
            ui_confirm "$(t upd.reboot.confirm "${h:-?}")" || continue
            ui_input "$(t upd.reboot.type_host "$h")" || continue
            if [ -z "$h" ] || [ "$UI_INPUT" != "$h" ]; then ui_note info "${TX[upd.reboot.cancelled]}"; continue; fi
            ui_run_task "${TX[upd.head.reboot]}" systemctl reboot;;
        esac;;
    esac
  done
}

tool_register updates "${TX[upd.title]}" "${TX[upd.desc]}" "all" _upd_avail _t_updates 97
