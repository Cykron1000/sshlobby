# shellcheck shell=bash
# Release-Prüfung, Hinweis im Hauptmenü, sshlobby update und install.sh --update (lib/update.sh).
# Kein Netz: curl und wget sind Stubs (tests/stubs/curl), die Antworten aus $W/rel liefern (rel_json,
# rel_tar). Installationen landen wie in test_install.sh nur in Pfaden unter $W (inst_env), und
# real_sum prüft, dass eine echte Installation unter /usr/local unberührt bleibt.
# shellcheck disable=SC2015,SC2034,SC1111 # „a && b || die“ ist in Tests gewollt; RC/OUT lesen die Helfer

UPD_CUR=$(sed -n 's/^VERSION="\(.*\)"$/\1/p' "$ROOT/sshlobby.sh")

rel_json() { # tag → $W/rel/latest.json (Antwort von releases/latest), Stub zeigt auf $W/rel
  mkdir -p "$W/rel"; export STUB_UPDATE_DIR="$W/rel"
  printf '{"tag_name":"%s","html_url":"https://github.com/Nikolai-Slsr/sshlobby/releases/tag/%s","draft":false}\n' \
    "$1" "$1" > "$W/rel/latest.json"
}
rel_src() { # tag [version-im-archiv] → Release-Quellordner aus dem Arbeitsstand in $W/relsrc/sshlobby-<v> (Pfad in REL)
  local v=${2:-${1#v}}
  REL="$W/relsrc/sshlobby-${1#v}"; rm -rf "$REL"; mkdir -p "$REL" "$W/rel"
  cp -r "$ROOT/sshlobby.sh" "$ROOT/install.sh" "$ROOT/uninstall.sh" "$ROOT/lib" "$ROOT/lang" "$ROOT/examples" "$REL/"
  sed -i "s/^VERSION=\".*\"$/VERSION=\"$v\"/" "$REL/sshlobby.sh"
}
rel_pack() { local tag=$1; shift; (cd "$W/relsrc" && tar -czf "$W/rel/$tag.tar.gz" "$@" "sshlobby-${tag#v}") 2>/dev/null; } # tag [tar-optionen/namen] → Archiv wie bei GitHub
rel_tar() { rel_src "$@"; rel_pack "$1"; } # tag [version-im-archiv]
upd_cache() { # tag [alter-in-sekunden] [repo] → Cache wie nach einer erfolgreichen Prüfung
  printf 'checked=%s\nrepo=%s\nstatus=ok\ntag=%s\nurl=https://github.com/x/y/releases/tag/%s\n' \
    "$(( $(date +%s) - ${2:-60} ))" "${3:-Nikolai-Slsr/sshlobby}" "$1" "$1" > "$CONF/update-check"
}
wait_file_has() { # datei zeile → wartet bis zu 5 s, bis die Datei die Zeile enthält
  local i; for ((i=0; i<50; i++)); do grep -qxF -- "$2" "$1" 2>/dev/null && return 0; sleep 0.1; done
  die "$1 ohne »$2«:\n$(cat "$1" 2>&1)"
}
curl_calls() { grep -c '^== curl$' "$STUB_LOG" 2>/dev/null || true; }
# Stand einer echten Installation auf dieser Maschine (Kanarienvogel: Tests dürfen sie nie ändern)
real_sum() { { readlink /usr/local/bin/sshlobby; find /usr/local/lib/sshlobby -type f -exec sha256sum {} +; } 2>/dev/null | sort; }

# sshlobby nach $W installieren und alle Pfade, die install.sh --update später benutzt, auf $W umbiegen
upd_inst() {
  [ "$(id -u)" = 0 ] || skip "install.sh braucht root"
  mkdir -p "$W/bin" "$W/tmp"; [ -e "$W/bashrc" ] || : > "$W/bashrc"
  inst || die "install: $(cat "$W/iout")"
  export BASHRC="$W/bashrc" CONF_DST="$HOME/.config/sshlobby" OLD_BIN="$W/old/bin/projdash" \
         OLD_LIB="$W/old/lib/projdash" OLD_CONF="$HOME/.config/projdash" TMPDIR="$W/tmp"
}
# Installiertes sshlobby über den Starter: upd_run "<eingabe>" [args…] → OUT ERR RC
upd_run() {
  local in=$1; shift
  printf '%b' "$in" | env --default-signal=INT setsid -w "$W/bin/sshlobby" "$@" > "$W/out" 2> "$W/err"; RC=$?
  OUT=$(<"$W/out"); ERR=$(<"$W/err")
}
inst_version() { "$W/bin/sshlobby" --version 2>&1; }
tmp_empty() { [ -z "$(ls -A "$W/tmp")" ] || die "Arbeitsordner liegen geblieben: $(ls -A "$W/tmp")"; }

# ─── Versionen, CLI ────────────────────────────────────────────────────────
t_update_ver_gt() {
  local out
  out=$(bash -c 'CONF_DIR=/nonexistent; . "$1/lib/update.sh"
    for p in "3.0.1 3.0.0" "v3.0.10 3.0.9" "3.1 3.0.9" "4.0.0 3.99.99" "3.0.0.1 3.0.0" "3.0.0 3.0.0" "3.0 3.0.0" \
             "3.0.0 3.0.1" "v2.9.9 3.0.0" "x 1" "1.0.0 1.0.x"; do
      set -- $p; if ver_gt "$1" "$2"; then printf "%s>%s " "$1" "$2"; fi
    done' _ "$ROOT")
  eq "$out" "3.0.1>3.0.0 v3.0.10>3.0.9 3.1>3.0.9 4.0.0>3.99.99 3.0.0.1>3.0.0 "
}

t_update_cli_args() {
  local a
  for a in "--check" "--yes" "-y" "--list --check" "update --list" "update foo" "update update"; do
    # shellcheck disable=SC2086 # Wortzerlegung gewollt: mehrere Argumente
    cli $a; rc_is 2; has "$ERR" "Usage: sshlobby"
  done
  cli --help; rc_is 0; has "$OUT" "update [--check] [--yes]"; has "$OUT" "Exit-Codes update: 0 aktuell oder aktualisiert"
  [ ! -e "$STUB_LOG" ] || ! grep -q '^== curl' "$STUB_LOG" || die "Netzabfrage bei falschen Argumenten"
}

t_update_check_cli() {                              # --check: neuer, gleich, älter; Cache und abgefragte URL
  rel_json v9.9.9
  cli update --check; rc_is 3; no_err
  has "$OUT" "Suche nach einem neuen Release von Nikolai-Slsr/sshlobby"
  has "$OUT" "Neues Release: sshlobby 9.9.9 (installiert: $UPD_CUR)"
  has "$OUT" "Änderungen: https://github.com/Nikolai-Slsr/sshlobby/releases/tag/v9.9.9"
  logged "https://api.github.com/repos/Nikolai-Slsr/sshlobby/releases/latest" || die "API-URL:\n$(cat "$STUB_LOG")"
  logged "=https" || die "curl ohne --proto =https"
  wait_file_has "$CONF/update-check" "tag=v9.9.9"; wait_file_has "$CONF/update-check" "status=ok"
  rel_json "v$UPD_CUR"; cli update --check; rc_is 0; has "$OUT" "sshlobby $UPD_CUR ist aktuell."
  rel_json v2.0.0; cli update --check; rc_is 0; has "$OUT" "ist aktuell"         # nie ein Downgrade anbieten
  rel_json V9.9.9; cli --update --check; rc_is 3; has "$OUT" "sshlobby 9.9.9"   # auch als Option, Tag mit V
}

t_update_check_errors() {                           # Netzfehler, 404, Unsinn, kein curl/wget; Cache behält das Release
  upd_cache v9.9.9 90000
  export STUB_UPDATE_RC=6
  cli update --check; rc_is 1; has "$ERR" "GitHub nicht erreichbar (curl, Exit-Code 6)"
  wait_file_has "$CONF/update-check" "status=err"; wait_file_has "$CONF/update-check" "tag=v9.9.9"
  unset STUB_UPDATE_RC
  mkdir -p "$W/rel"; export STUB_UPDATE_DIR="$W/rel"                            # kein latest.json: HTTP 404
  cli update --check; rc_is 1; has "$ERR" "kein Release in Nikolai-Slsr/sshlobby oder Anfragelimit"
  echo '<html>rate limit</html>' > "$W/rel/latest.json"
  cli update --check; rc_is 1; has "$ERR" "Unerwartete Antwort von GitHub"
  printf '{"tag_name":"v1.0; rm -rf /","html_url":"javascript:x"}' > "$W/rel/latest.json"
  cli update --check; rc_is 1; has "$ERR" "Unerwartete Antwort"
  printf '[1,2]' > "$W/rel/latest.json"; cli update --check; rc_is 1; has "$ERR" "Unerwartete Antwort"
  # html_url, die keine saubere https-URL ist, wird durch die Release-Seite ersetzt
  printf '{"tag_name":"v9.9.9","html_url":"http://evil.example/x y"}' > "$W/rel/latest.json"
  cli update --check; rc_is 3; has "$OUT" "Änderungen: https://github.com/Nikolai-Slsr/sshlobby/releases/tag/v9.9.9"
  path_without curl                                                              # nur wget
  rel_json v9.9.9; : > "$STUB_LOG"
  cli update --check; rc_is 3; grep -qx '== wget' "$STUB_LOG" || die "wget nicht benutzt"; logged "--https-only" || die "wget ohne --https-only"
  unset STUB_UPDATE_DIR; cli update --check; rc_is 1; has "$ERR" "(wget, Exit-Code 4)"
  rm -rf "${W:?}/bin"; path_without curl wget
  cli update --check; rc_is 1; has "$ERR" "fehlt curl oder wget"
}

t_update_repo_config() {                            # UPDATE_REPO: eigenes Repo, ungültige Werte ignoriert
  conf "MODE=docker" "UPDATE_REPO=someone/fork"; rel_json v9.9.9
  cli update --check; rc_is 3; logged "https://api.github.com/repos/someone/fork/releases/latest" || die "Repo aus der Config nicht benutzt"
  grep -qx "repo=someone/fork" "$CONF/update-check" || die "Cache ohne Repo"
  local bad
  for bad in "../../etc" "a/b/c" "x y/z" "-x/y" "x/-y" ""; do
    conf "MODE=docker" "UPDATE_REPO=$bad"; : > "$STUB_LOG"; cli update --check
    logged "https://api.github.com/repos/Nikolai-Slsr/sshlobby/releases/latest" \
      || die "ungültiges UPDATE_REPO »$bad« nicht ignoriert:\n$(cat "$STUB_LOG")"
  done
  conf "MODE=docker" "UPDATE_REPO=..evil/x"; : > "$STUB_LOG"; cli update --check
  logged "https://api.github.com/repos/Nikolai-Slsr/sshlobby/releases/latest" || die "UPDATE_REPO mit .. nicht ignoriert"
}

# ─── Hinweis im Hauptmenü, automatische Prüfung ────────────────────────────
t_update_banner_line() {                            # nur bei neuerem Release, eingeschalteter Prüfung und passendem Repo
  conf "MODE=docker"; export SSHLOBBY_UPDATE_CHECK=yes
  upd_cache v9.9.9
  menu 'q\n'; rc_is 20; no_err
  has "$OUT" "Neue Version sshlobby 9.9.9  installiert ist $UPD_CUR · Taste u oder: sshlobby update"
  has "$OUT" "u) Update installieren"
  sleep 0.3; eq "$(curl_calls)" 0 "Abfragen trotz frischem Cache"
  upd_cache "v$UPD_CUR"; menu 'q\n'; rc_is 20; hasnt "$OUT" "Neue Version"; hasnt "$OUT" "u) Update"
  upd_cache v1.0.0;      menu 'q\n'; hasnt "$OUT" "Neue Version"
  upd_cache v9.9.9 60 someone/fork; menu 'q\n'; hasnt "$OUT" "Neue Version"        # Cache eines anderen Repos
  upd_cache v9.9.9; conf "MODE=docker" "UPDATE_CHECK=no"; unset SSHLOBBY_UPDATE_CHECK
  menu 'q\n'; rc_is 20; hasnt "$OUT" "Neue Version"
  conf "MODE=docker"; export SSHLOBBY_UPDATE_CHECK=no                              # Umgebung vor Config
  menu 'q\n'; hasnt "$OUT" "Neue Version"
  printf 'checked=x\nrepo=Nikolai-Slsr/sshlobby\ntag=v9.9.9; reboot\nurl=javascript:alert(1)\n' > "$CONF/update-check"
  export SSHLOBBY_UPDATE_CHECK=yes; unset STUB_UPDATE_DIR                           # kaputter Cache: kein Hinweis
  menu 'q\n'; rc_is 20; no_err; hasnt "$OUT" "Neue Version"
}

t_update_auto_background() {                        # fällig: genau eine Prüfung im Hintergrund, danach der Hinweis
  conf "MODE=docker"; export SSHLOBBY_UPDATE_CHECK=yes; rel_json v9.9.9
  menu 'q\n'; rc_is 20; no_err
  wait_file_has "$CONF/update-check" "status=ok"; wait_file_has "$CONF/update-check" "tag=v9.9.9"
  eq "$(curl_calls)" 1 "Abfragen"
  menu 'q\n'; rc_is 20; has "$OUT" "sshlobby 9.9.9"
  sleep 0.5; eq "$(curl_calls)" 1 "zweite Abfrage am selben Tag"
  upd_cache v9.9.9 90000                                                           # älter als ein Tag: wieder fällig
  menu 'q\n'; local i; for ((i=0; i<50; i++)); do [ "$(curl_calls)" = 2 ] && break; sleep 0.1; done
  eq "$(curl_calls)" 2 "Abfragen nach einem Tag"
  wait_file_has "$CONF/update-check" "status=ok"
  export STUB_UPDATE_RC=6; upd_cache v9.9.9 90000                                  # Fehlschlag: Release bleibt bekannt
  menu 'q\n'; wait_file_has "$CONF/update-check" "status=err"; grep -qx "tag=v9.9.9" "$CONF/update-check" || die "Release vergessen"
  menu 'q\n'; has "$OUT" "sshlobby 9.9.9"
  ! ls "$CONF"/update-check.* >/dev/null 2>&1 || die "Temp-Dateien im Config-Ordner: $(ls "$CONF")"
}

t_update_auto_off_and_cli_only() {                  # UPDATE_CHECK=no, kein Terminal und --list/--go/--settings fragen nie
  conf "MODE=docker" "UPDATE_CHECK=no"; unset SSHLOBBY_UPDATE_CHECK; rel_json v9.9.9
  menu 'q\n'; rc_is 20
  conf "MODE=docker"                                # eingeschaltet, aber ohne Terminal (Pipe): nichts
  menu 'q\n'; rc_is 20
  export SSHLOBBY_UPDATE_CHECK=yes
  cli --list; rc_is 0; menu 'b\n' --settings; rc_is 0; cli --go Nextcloud; rc_is 0
  sleep 0.5
  [ ! -e "$CONF/update-check" ] || die "Cache angelegt: $(cat "$CONF/update-check")"
  eq "$(curl_calls)" 0 "Abfragen"
}

# ─── Installation ──────────────────────────────────────────────────────────
t_update_refuses_checkout() {                       # aus einem Quellordner (install.sh daneben): nie ersetzen
  [ "$(id -u)" = 0 ] || skip "braucht root"
  rel_json v9.9.9; rel_tar v9.9.9
  cli update --yes; rc_is 1; has "$OUT" "Neues Release: sshlobby 9.9.9"; has "$ERR" "Quellordner ($ROOT)"
  ! grep -q 'archive/refs/tags' "$STUB_LOG" || die "trotzdem heruntergeladen"
  conf "MODE=docker"; export SSHLOBBY_UPDATE_CHECK=yes; upd_cache v9.9.9          # Taste u: Hinweis statt Installation
  menu 'u\n\nq\n'; rc_is 20; has "$OUT" "Quellordner"; hasnt "$OUT" "jetzt installieren"
}

t_update_install_e2e() {                            # Download, Prüfung, install.sh --update, Version, Hook bleibt
  local before; before=$(real_sum)
  printf '# vorher\n' > "$W/bashrc"; upd_inst; cp "$W/bashrc" "$W/bashrc.1"
  rel_json v9.9.9; rel_tar v9.9.9
  upd_run '' update --yes; rc_is 0; no_err
  has "$OUT" "Lade v9.9.9"; has "$OUT" "Prüfe das Archiv"; has "$OUT" "Installiere nach $W/lib/sshlobby"
  has "$OUT" "Bashrc hook is up to date"; has "$OUT" "Done: sshlobby 9.9.9 installed."
  has "$OUT" "sshlobby aktualisiert: $UPD_CUR → 9.9.9"
  logged "https://github.com/Nikolai-Slsr/sshlobby/archive/refs/tags/v9.9.9.tar.gz" || die "Archiv-URL:\n$(cat "$STUB_LOG")"
  eq "$(inst_version)" "sshlobby 9.9.9"; [ -L "$W/bin/sshlobby" ] || die "Starter ist kein Symlink mehr"
  cmp -s "$W/bashrc" "$W/bashrc.1" || die "Bashrc verändert:\n$(diff "$W/bashrc.1" "$W/bashrc")"
  diff -r "$REL/lib" "$W/lib/sshlobby/lib" >/dev/null || die "Module nicht aus dem Release"
  tmp_empty; wait_file_has "$CONF/update-check" "tag=v9.9.9"
  upd_run '' update --check; rc_is 0; has "$OUT" "sshlobby 9.9.9 ist aktuell."
  eq "$(real_sum)" "$before" "echte Installation unter /usr/local verändert"
}

t_update_install_no_hook_added() {                  # ohne Login-Hook: Update legt keinen an; alter Hook wird ersetzt
  printf '# nur das\n' > "$W/bashrc"; upd_inst
  printf '# nur das\n' > "$W/bashrc"
  rel_json v9.9.9; rel_tar v9.9.9
  upd_run '' update -y; rc_is 0; has "$OUT" "none added"; eq "$(cat "$W/bashrc")" "# nur das"
  printf '%s\n' "$OLD_HOOK" > "$W/bashrc"; rel_json v9.9.10; rel_tar v9.9.10
  upd_run '' update --yes; rc_is 0; has "$OUT" "Bashrc hook updated"
  grep -qxF '# >>> sshlobby >>>' "$W/bashrc" && ! grep -q projdash "$W/bashrc" || die "alter Hook nicht ersetzt:\n$(cat "$W/bashrc")"
}

t_update_declined_and_not_root() {
  upd_inst; rel_json v9.9.9; rel_tar v9.9.9
  upd_run 'n\n' update; rc_is 3; has "$OUT" "sshlobby 9.9.9 jetzt installieren? [j/N]"; has "$OUT" "Nicht installiert"
  upd_run '' update; rc_is 3                                                       # EOF zählt als Nein
  eq "$(inst_version)" "sshlobby $UPD_CUR"; ! grep -q 'archive/refs/tags' "$STUB_LOG" || die "trotz Nein geladen"
  mkdir -p "$W/fake"
  # shellcheck disable=SC2016 # $1 und $@ expandieren erst im Fake-id
  printf '#!/bin/sh\n[ "$1" = -u ] && { echo 1000; exit 0; }\nexec %s "$@"\n' "$(type -P id)" > "$W/fake/id"
  chmod +x "$W/fake/id"
  local p=$PATH; export PATH="$W/fake:$PATH"                                      # id -u meldet 1000
  upd_run '' update --yes; export PATH=$p; rc_is 1; has "$ERR" "braucht root: sudo sshlobby update"
  eq "$(inst_version)" "sshlobby $UPD_CUR"
}

t_update_bad_archives() {                           # Archivprüfung: jedes Problem → nichts installiert
  local before; before=$(real_sum)
  upd_inst; rel_json v9.9.9
  cp -a "$W/lib/sshlobby" "$W/orig"
  bad() { upd_run '' update --yes; rc_is 1; has "$ERR" "$1"; has "$ERR" "Nichts installiert"
          diff -r "$W/orig" "$W/lib/sshlobby" >/dev/null || die "Installation verändert ($1)"; tmp_empty; }
  rel_tar v9.9.9 9.9.8;                                             bad "Release v9.9.9 enthält Version 9.9.8"
  rel_src v9.9.9; ln -s /etc/passwd "$REL/lib/zz.sh"; rel_pack v9.9.9;  bad "unsichere Einträge"
  rel_src v9.9.9; echo x > "$W/relsrc/extra"
  rel_pack v9.9.9 --transform 's,^extra$,sshlobby-9.9.9/../evil,' -C "$W/relsrc" extra;  bad "unsichere Einträge"
  rel_src v9.9.9; rel_pack v9.9.9 --transform 's,^extra$,/tmp/evil,' -P -C "$W/relsrc" extra; bad "unsichere Einträge"
  rel_src v9.9.9; mkdir -p "$W/relsrc/zweite"; echo x > "$W/relsrc/zweite/f"
  rel_pack v9.9.9 -C "$W/relsrc" zweite;                            bad "unsichere Einträge"
  rel_src v9.9.9; rm "$REL/install.sh"; rel_pack v9.9.9;            bad "install.sh, lib/ oder lang/ fehlt"
  rel_src v9.9.9; echo 'f() {' >> "$REL/lib/ui.sh"; rel_pack v9.9.9; bad "Syntaxfehler in lib/ui.sh"
  echo 'kein gzip' > "$W/rel/v9.9.9.tar.gz";                        bad "Archiv nicht lesbar"
  rm -f "$W/rel/v9.9.9.tar.gz"; upd_run '' update --yes; rc_is 1; has "$ERR" "GitHub meldet einen Fehler"
  eq "$(real_sum)" "$before" "echte Installation unter /usr/local verändert"
}

t_update_install_fails_restores() {                 # install.sh scheitert oder installiert Falsches → alter Stand zurück
  upd_inst; rel_json v9.9.9; cp -a "$W/lib/sshlobby" "$W/orig"
  rel_src v9.9.9
  # shellcheck disable=SC2016 # $LIB_DST expandiert erst im Release-install.sh
  printf '#!/bin/bash\nrm -f "$LIB_DST"/lib/*.sh "$LIB_DST/sshlobby.sh"\nexit 7\n' > "$REL/install.sh"; rel_pack v9.9.9
  upd_run '' update --yes; rc_is 1; has "$ERR" "install.sh ist fehlgeschlagen (Exit-Code 7)"; has "$ERR" "wiederhergestellt"
  diff -r "$W/orig" "$W/lib/sshlobby" || die "alter Stand nicht wiederhergestellt"
  eq "$(inst_version)" "sshlobby $UPD_CUR"; tmp_empty
  rel_src v9.9.9
  # shellcheck disable=SC2016
  printf '#!/bin/bash\ncp -r "$(dirname "$0")"/lib "$LIB_DST/"\nsed -i "s/^VERSION=.*/VERSION=\\"0.0.1\\"/" "$LIB_DST/sshlobby.sh"\n' > "$REL/install.sh"
  rel_pack v9.9.9
  upd_run '' update --yes; rc_is 1; has "$ERR" "meldet sich sshlobby mit „sshlobby 0.0.1“ statt Version 9.9.9"
  diff -r "$W/orig" "$W/lib/sshlobby" || die "alter Stand nicht wiederhergestellt"
  eq "$(inst_version)" "sshlobby $UPD_CUR"
}

t_update_key_u_line() {                             # Taste u: prüfen, nachfragen, installieren, neue Version startet
  upd_inst; conf "MODE=docker"; export SSHLOBBY_UPDATE_CHECK=yes
  rel_json v9.9.9; rel_tar v9.9.9; upd_cache v9.9.9
  upd_run 'u\nn\nq\n'; rc_is 20; has "$OUT" "sshlobby 9.9.9 jetzt installieren? [j/N]"     # Nein: nichts passiert
  eq "$(inst_version)" "sshlobby $UPD_CUR"
  upd_run 'u\nj\n\nq\n'; rc_is 20; no_err
  has "$OUT" "u) Update installieren"; has "$OUT" "sshlobby aktualisiert: $UPD_CUR → 9.9.9"
  has "$OUT" "startet mit der neuen Version neu"
  has "$OUT" "v9.9.9 · Modus docker"                                              # neu gestartet, neue Version
  eq "$(inst_version)" "sshlobby 9.9.9"
  local after; after=$(awk '/v9\.9\.9 · Modus docker/ { f = 1 } f' <<< "$OUT")
  hasnt "$after" "Neue Version"; hasnt "$after" "u) Update"                       # danach kein Hinweis mehr
}

t_install_update_flag() {                           # install.sh --update direkt, unbekannte Argumente
  mkdir -p "$W/bin"; printf '# nur das\n' > "$W/bashrc"
  safe_paths "$ROOT/install.sh"
  env "${INST_ENV[@]}" bash "$ROOT/install.sh" --update > "$W/iout" 2>&1 || die "install --update: $(cat "$W/iout")"
  has "$(cat "$W/iout")" "none added"; eq "$(cat "$W/bashrc")" "# nur das"
  [ -x "$W/bin/sshlobby" ] && [ -f "$W/lib/sshlobby/lib/update.sh" ] && [ -f "$W/lib/sshlobby/lang/update.txt" ] || die "Programm unvollständig"
  rm -rf "${W:?}/bin" "${W:?}/lib"; mkdir -p "$W/bin"
  env "${INST_ENV[@]}" bash "$ROOT/install.sh" --bogus > "$W/iout" 2>&1; eq $? 2 "Exit-Code bei unbekanntem Argument"
  [ ! -e "$W/lib/sshlobby" ] || die "trotz falschem Argument installiert"
  env "${INST_ENV[@]}" bash "$ROOT/install.sh" --help > "$W/iout" 2>&1; eq $? 0; has "$(cat "$W/iout")" "Usage"
}

# ─── Einstellungen, TUI, Englisch ──────────────────────────────────────────
t_update_settings() {                               # Gruppe sshlobby-Updates: Schalter, Stand, Jetzt prüfen
  conf "MODE=docker"; unset SSHLOBBY_UPDATE_CHECK
  menu 'b\n' --settings; rc_is 0; no_err                                          # --settings startet keine Prüfung
  has "$OUT" "SSHLOBBY-UPDATES"; has_re "$OUT" "Nach neuen Releases suchen +an · noch nie geprüft"
  has_re "$OUT" "Jetzt prüfen +github.com/Nikolai-Slsr/sshlobby"
  [ ! -e "$CONF/update-check" ] || die "Einstellungen haben geprüft"
  upd_cache "v$UPD_CUR" 120                       # frisch: das Hauptmenü startet unten keine Hintergrundprüfung
  st_item "Nach neuen Releases suchen"; local sw=$ST
  menu "e\n$sw\nb\nq\n"; rc_is 20; cfg_has "UPDATE_CHECK=no"; has_re "$OUT" "Nach neuen Releases suchen +aus"
  menu "e\n$sw\nb\nq\n"; cfg_has "UPDATE_CHECK=yes"
  rel_json "v$UPD_CUR"; st_item "Jetzt prüfen"; local now=$ST
  menu "e\n$now\n\nb\nq\n"; rc_is 20; no_err; has "$OUT" "sshlobby $UPD_CUR ist aktuell."
  has_re "$OUT" "Nach neuen Releases suchen +an · geprüft gerade eben"
  export STUB_UPDATE_RC=6
  menu "e\n$now\n\nb\nq\n"; rc_is 20; has "$OUT" "GitHub nicht erreichbar"; has_re "$OUT" "an · letzte Prüfung fehlgeschlagen"
  unset STUB_UPDATE_RC; rel_json v9.9.9
  menu "e\n$now\n\nb\nq\n"; rc_is 20; has "$OUT" "Quellordner"                       # Kopie aus dem Repo: nur Hinweis
  has_re "$OUT" "sshlobby 9.9.9 installieren +github.com/Nikolai-Slsr/sshlobby"
}

t_update_tui_banner() {                             # TUI: Hinweiszeile mit Pill unter der Breadcrumb, Taste u in der Fußzeile
  conf "MODE=docker"; upd_cache v9.9.9
  tui_start SSHLOBBY_UPDATE_CHECK=yes; tui_wait "Neue Version"
  local s; s=$(tui_screen)
  has "$s" "sshlobby 9.9.9"; has "$s" "installiert ist $UPD_CUR · Taste u oder: sshlobby update"
  has "$s" "u Update installieren"
  [ "$(sed -n 4p <<< "$s" | grep -c 'Neue Version')" = 1 ] || die "Hinweis nicht in Zeile 4:\n$s"
  tui_keys q; tui_rc 20
}

t_update_tui_auto_check() {                         # echter Weg: Terminal, Standard-Config, keine Umgebung → Prüfung, r zeigt den Hinweis
  conf "MODE=docker"; rel_json v9.9.9
  tui_start "SSHLOBBY_UPDATE_CHECK=" "STUB_UPDATE_DIR=$W/rel"; tui_wait "COMPOSE-PROJEKTE"
  wait_file_has "$CONF/update-check" "status=ok"; wait_file_has "$CONF/update-check" "tag=v9.9.9"
  eq "$(curl_calls)" 1 "Abfragen"
  tui_keys r; tui_wait "Neue Version"; tui_wait "sshlobby 9.9.9"
  tui_keys q; tui_rc 20
}

t_update_tui_key_u() {                              # TUI: u → Rückfrage → Ausgabe auf dem normalen Bildschirm → Neustart als 9.9.9
  upd_inst; conf "MODE=docker"; rel_json v9.9.9; rel_tar v9.9.9; upd_cache v9.9.9
  local PD="$W/bin/sshlobby"                        # tui_start startet den installierten Starter
  tui_start SSHLOBBY_UPDATE_CHECK=yes "STUB_UPDATE_DIR=$W/rel" "BASHRC=$BASHRC" "CONF_DST=$CONF_DST" \
    "OLD_BIN=$OLD_BIN" "OLD_LIB=$OLD_LIB" "OLD_CONF=$OLD_CONF" "TMPDIR=$TMPDIR"
  tui_wait "Neue Version"
  tui_keys u; tui_wait "sshlobby 9.9.9 jetzt installieren?"
  tui_keys j; tui_wait "sshlobby aktualisiert: $UPD_CUR → 9.9.9" 10; tui_wait "[Enter] weiter"
  tui_keys Enter; tui_wait "v9.9.9" 10; tui_gone "Neue Version"
  eq "$(inst_version)" "sshlobby 9.9.9"
  tui_keys q; tui_rc 20                             # Exit-Code kommt vom neu gestarteten Prozess
  tmp_empty
}

t_i18n_update_en() {                                # englische Texte von CLI, Hinweis und Einstellungen
  export SSHLOBBY_LANG=en; rel_json v9.9.9
  local w de=("Suche" "Neues Release" "Änderungen" "installiert" "Neue Version" "Taste" "prüfen" "Nach neuen")
  cli update --check; rc_is 3
  has "$OUT" "Looking for a new release of Nikolai-Slsr/sshlobby"; has "$OUT" "New release: sshlobby 9.9.9 (installed: $UPD_CUR)"
  has "$OUT" "Release notes: https://github.com/"
  for w in "${de[@]}"; do hasnt "$OUT" "$w"; done
  conf "MODE=docker"; export SSHLOBBY_UPDATE_CHECK=yes; upd_cache v9.9.9
  menu 'q\n'; rc_is 20; has "$OUT" "New version sshlobby 9.9.9  installed: $UPD_CUR · key u or: sshlobby update"
  has "$OUT" "u) install update"
  for w in "${de[@]}"; do hasnt "$OUT" "$w"; done
  menu 'b\n' --settings; rc_is 0; has "$OUT" "SSHLOBBY UPDATES"; has_re "$OUT" "Look for new releases +on · checked [0-9]+ min ago"
  has_re "$OUT" "Install sshlobby 9.9.9 +github.com/"
  for w in "${de[@]}"; do hasnt "$OUT" "$w"; done
  export STUB_UPDATE_RC=6; cli update --check; rc_is 1; has "$ERR" "GitHub not reachable (curl, exit code 6)"
}
