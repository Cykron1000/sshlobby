# shellcheck shell=bash
# Englische Oberfläche von Werkzeug-Registry, Fehler-Log, RAM/Disk, Server-Check, Container-Ressourcen
# und Container-Hygiene (Zeilenmodus). Helfer tt_nr aus test_tools_services.sh.
# shellcheck disable=SC2034 # TW/TN lesen die Helfer

# Werkzeug öffnen wie tt_open, aber den Werkzeuge-Eintrag sprachunabhängig suchen (Werkzeuge/Tools)
t1_open() { # titel eingabe-danach
  export SSHLOBBY_LANG=en PD_TOOLS_ROOT="$PD_FIX/tools/root"
  menu 'q\n'
  TW=$(awk 'match($0, /^ *[0-9]+\) (Werkzeuge|Tools)( |$)/) { s = $0; sub(/\).*/, "", s); gsub(/ /, "", s); print s; exit }' <<< "$OUT")
  [ -n "$TW" ] || die "kein Werkzeuge-Eintrag:\n$OUT"
  menu "$TW\nb\nq\n"; TN=$(tt_nr "$OUT" ") $1"); [ -n "$TN" ] || die "Werkzeug »$1« fehlt:\n$OUT"
  menu "$TW\n$TN\n$2"
}

t_i18n_tools1_registry_errlog_sysinfo_en() {
  conf "MODE=docker" "SSH_HOSTS=nas"; t1_open "Error log" '\nb\nq\n'; rc_is 20; no_err
  for t in "RAM / disk / top processes" "Other server (SSH)" "Server check" \
           "Container resources" "Settings"; do has "$OUT" ") $t"; done
  has "$OUT" "── Error log (journalctl -p err) ──"; has "$OUT" "Failed units"
  has "$OUT" "Errors in the last 24 h by unit"; has "$OUT" "(2 distinct messages)"
  has_re "$OUT" "✗ [a-z]+ +killed by the OOM killer \(memory limit\)"; has_re "$OUT" "! [a-z-]+ +[0-9]+ restarts since creation"
  has_re "$OUT" "exited with code 137 \(SIGKILL, often OOM or docker kill\)"; has "$OUT" "Last 40 error messages"
  hasnt "$OUT" "Fehlgeschlagene"; hasnt "$OUT" "verschiedene Meldungen"; hasnt "$OUT" "Neustarts"; hasnt "$OUT" "Modus, Start, Anzeige"
  t1_open "RAM / disk / top processes" '\nb\nq\n'; rc_is 20; no_err
  has "$OUT" "Memory and swap"; has_re "$OUT" "Swap used +1\.8G of 2\.0G \(90 %\)"; has "$OUT" "Top processes by RAM"
  hasnt "$OUT" "Arbeitsspeicher"; hasnt "$OUT" "belegt"; hasnt "$OUT" "Dateisysteme"
}

t_i18n_tools1_check_en() {
  t1_open "Server check" 'b\nb\nq\n'; rc_is 20; no_err
  has "$OUT" "┌─ Server check"; has_re "$OUT" "Result +● [1-9] errors · [0-9]+ warnings"
  has "$OUT" "Failed units (1): backup-nightly.service"; has "$OUT" "124 updates pending, 59 of them security"
  has "$OUT" "Storage pool default is 83 % full"; has "$OUT" "2 Incus snapshots present"; has "$OUT" "Select to open the tool"
  hasnt "$OUT" "Ergebnis"; hasnt "$OUT" "Updates offen"; hasnt "$OUT" "Auswahl öffnet"; hasnt "$OUT" "Prüfe den Server"
}

t_i18n_tools1_hygiene_resources_en() {
  conf "MODE=docker"
  t1_open "Container hygiene" '\nb\nq\n'; rc_is 20; no_err
  has "$OUT" "No project and no restart policy"; has "$OUT" "Stopped containers"; has "$OUT" "Random names"
  has "$OUT" "runs without Compose project and without restart policy"; has "$OUT" "has no name anymore (tag was reassigned)"
  has "$OUT" "Suggestion, not run: docker update --restart unless-stopped <name>   (or move it into a Compose project)"
  hasnt "$OUT" "Zufallsname"; hasnt "$OUT" "Gestoppte"; hasnt "$OUT" "Vorschlag"; hasnt "$OUT" "kein fester Tag"
  t1_open "Container resources" 's\nb\nb\nq\n'; rc_is 20; no_err
  has "$OUT" "Sort order RAM"; has "$OUT" "Sort order CPU"; has "$OUT" "Host Docker · docker stats"
  has "$OUT" "s) sort by CPU"; has "$OUT" "r) measure again"
  hasnt "$OUT" "Sortierung"; hasnt "$OUT" "sortieren"; hasnt "$OUT" "neu messen"
}
