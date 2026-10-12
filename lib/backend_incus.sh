# shellcheck shell=bash
# backend_incus.sh: Incus-CTs (Modi incus und layered). Daten (ct_*) ohne Ausgabe, Aktionen
# laufen über die UI-Primitive (ui_run_fg, ui_run_task, ui_run_page, ui_msg).
# Nicht-interaktive incus-Aufrufe immer mit </dev/null: incus exec leitet stdin in den CT weiter
# und liest es dabei leer (gepipte oder vorgetippte Menüeingaben wären weg).
# shellcheck disable=SC2034,SC1111 # CTS_RAW lesen die Screens (SC1111: „…“ sind gewollte Anführungszeichen)

CTS_RAW=""

# Incus-CTs live → CTS_RAW (Zeilen "name,status,ip", sortiert). incus csv ist mehrdeutig
# (Fortsetzungszeilen), deshalb JSON + jq; IP = erste IPv4 an eth0.
ct_load() {
  CTS_RAW=$(incus list --format json </dev/null 2>/dev/null | jq -r \
    '.[] | [.name, .status, ([.state.network.eth0.addresses[]? | select(.family=="inet") | .address][0] // "-")] | @csv' \
    | tr -d '"' | sort -t, -k1,1)
}
ct_ip()     { printf '%s\n' "$CTS_RAW" | awk -F',' -v n="$1" '$1==n{print $3}'; }
ct_status() { printf '%s\n' "$CTS_RAW" | awk -F',' -v n="$1" '$1==n{print $2}'; }
ct_names()  { printf '%s\n' "$CTS_RAW" | awk -F',' '$1!=""{print $1}'; }
ct_exists() { [ -n "$(ct_status "$1")" ]; }
ct_running_count() { printf '%s\n' "$CTS_RAW" | grep -c ',Running,'; }

# ─── Aktionen ──────────────────────────────────────────────────────────────
# Shells: vorher prüfen statt Exit-Code danach auswerten (eine Shell endet mit dem Code des
# letzten Befehls, das ist kein Fehler).
ct_shell() { # ct
  local st; st=$(ct_status "$1")
  if [ "$st" != "Running" ]; then ui_msg err "$(t incus.not_running "$1" "${st:-${TX[incus.missing]}}")"; return 0; fi
  state_add_recent "$1" "-" ctshell
  ui_run_fg incus exec "$1" -- bash -l
}

ct_action() { # ct start|stop|restart
  local text
  case "$2" in
    start) tf text incus.action.start "$1";; stop) tf text incus.action.stop "$1";;
    restart) tf text incus.action.restart "$1";; *) return 1;;
  esac
  ui_run_task "$text" incus "$2" "$1"
}

ct_info()      { ui_run_page "incus info $1" incus info "$1"; }
ct_log()       { ui_run_page "$(t incus.log_of "$1")" incus info --show-log "$1"; }
ct_resources() { ui_run_page "$(t incus.resources_of "$1")" incus list "^$1\$" -c nsuNmMD4 --format table; }

ct_valid_name() { [[ "$1" =~ ^[a-zA-Z]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?$ ]]; }
ct_name_taken() { incus info "$1" </dev/null >/dev/null 2>&1; }
ct_images() { # lokale Images: "alias|beschreibung|größe" pro Zeile
  incus image list --format json </dev/null 2>/dev/null | jq -r \
    '.[] | [(.aliases[0].name // .fingerprint[:12]), (.properties.description // ""), (.size/1048576|floor|tostring)+" MiB"] | join("|")'
}
ct_launch() { ui_run_task "$(t incus.launch "$2" "$1")" incus launch "$1" "$2"; } # image name
