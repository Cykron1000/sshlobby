# shellcheck shell=bash
# Englische Oberfläche der Werkzeuge Ports, Speicherplatz, Netzwerk und Sicherheits-Check (Zeilenmodus).
# Helfer tt_nr aus test_tools_services.sh, before aus test_tools_pages.sh.
# shellcheck disable=SC2034 # TW/TN/PG lesen die Helfer

# Werkzeug öffnen wie tt_open, aber Menüeinträge sprachunabhängig suchen (Werkzeuge/Tools)
en_tool_open() { # titel eingabe-danach
  export SSHLOBBY_LANG=en PD_TOOLS_ROOT="$PD_FIX/tools/root"
  menu 'q\n'
  TW=$(awk 'match($0, /^ *[0-9]+\) (Werkzeuge|Tools)( |$)/) { s = $0; sub(/\).*/, "", s); gsub(/ /, "", s); print s; exit }' <<< "$OUT")
  [ -n "$TW" ] || die "kein Werkzeuge-Eintrag:\n$OUT"
  menu "$TW\nb\nq\n"; TN=$(tt_nr "$OUT" ") $1"); [ -n "$TN" ] || die "Werkzeug »$1« fehlt:\n$OUT"
  menu "$TW\n$TN\n$2"
  PG=$(awk -v h="── $1 ──" 'index($0, h) { f = 1 } f && /^ *([0-9]+|b)\) / { exit } f' <<< "$OUT")  # nur die Seite
  [ -n "$PG" ] || die "Seite »$1« fehlt:\n$OUT"
}

t_i18n_tools3_ports_storage_en() {
  conf "MODE=docker"
  en_tool_open "Ports & listeners" '\nb\nq\n'; rc_is 20; no_err
  before "$PG" "Publicly reachable" "Tailscale only"; before "$PG" "Private / Docker bridge" "localhost only"
  has "$PG" "11 public listeners: 8642/tcp hermes, 22/tcp sshd"; has "$PG" "bypass ufw"
  has_re "$PG" "tcp +172\.17\.0\.1:9100 +node_exporter +Container \(host network\) 0123456789ab"
  hasnt "$PG" "Öffentlich erreichbar"; hasnt "$PG" "öffentliche Listener"; hasnt "$PG" "Host-Netz"
  en_tool_open "Disk space" '\nb\nq\n'; rc_is 20; no_err
  has "$PG" "Filesystems"; has "$PG" "Largest images"; has_re "$PG" "2\.74GB +\(untagged\) +1 container$"; hasnt "$PG" " 1 containers"
  has_re "$PG" "nextcloud-dev:latest +unused"; has "$PG" "4 images without containers, 2 of them untagged"
  has "$PG" "Build cache: 4.842GB reclaimable"; has "$PG" "docker image prune   (untagged images only)"
  hasnt "$PG" "Dateisysteme"; hasnt "$PG" "ohne Namen"; hasnt "$PG" "freigebbar"; hasnt "$PG" "ungenutzt"
}
t_i18n_tools3_network_security_en() {
  en_tool_open "Network & access" '\nb\nq\n'; rc_is 20; no_err
  has_re "$PG" "This node +docker-host 100\.64\.0\.10"; has_re "$PG" "Exit node +offered"
  has "$PG" "files.example.org files"; has_re "$PG" "Interface +wg0 port 51820"
  has_re "$PG" "! Peer PeerTwoP… 10\.8\.0\.3/32 .*handshake never"
  hasnt "$PG" "Dieser Knoten"; hasnt "$PG" "Schnittstelle"; hasnt "$PG" "Dateien"; hasnt "$PG" "Handshake nie"
  en_tool_open "Security check" '\nb\nq\n'; rc_is 20; no_err
  has "$PG" "Failed SSH logins (24 h)"; has "$PG" "12 failed attempts from 7 addresses (top 5 above)"
  has "$PG" "Recent successful logins"; has "$PG" 'Details in the "Ports & listeners" tool'
  has "$PG" "✓ unattended-upgrades active"; has "$PG" "✓ no reboot required"
  hasnt "$PG" "Fehlversuche"; hasnt "$PG" "Neustart"; hasnt "$PG" "Öffentliche Ports"; hasnt "$PG" "Werkzeug „"
}
