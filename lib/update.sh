# shellcheck shell=bash
# update.sh: neue Releases erkennen, Hinweis im Hauptmenü, Selbst-Update (sshlobby update).
#
# Quelle ist das neueste GitHub-Release von UPDATE_REPO (Default Nikolai-Slsr/sshlobby):
# https://api.github.com/repos/<repo>/releases/latest liefert nur veröffentlichte Releases, keine
# Entwürfe, keine Vorabversionen und keine Tags ohne Release. Netzwerk nur über curl oder wget, nur HTTPS.
#
# Automatische Prüfung (UPDATE_CHECK=yes, Default): upd_auto beim Start des Menüs, höchstens einmal
# pro UPD_INTERVAL und im Hintergrund, damit der Login nicht wartet. Das Ergebnis steht in
# ~/.config/sshlobby/update-check (KEY=wert, nie als Shell-Code geladen):
#   checked=<epoch>  repo=<owner/name>  status=ok|err|pending  tag=<vX.Y.Z>  url=<Release-Seite>
# Das Hauptmenü liest nur diese Datei (upd_banner): neuere Version → Hinweiszeile und Taste u.
#
# sshlobby update [--check] [--yes] prüft sofort, lädt das Archiv des Release-Tags, prüft es (nur Dateien
# und Ordner unter einer Wurzel, Version im Archiv = Tag, Syntax) und führt dessen install.sh --update
# mit den Pfaden der laufenden Installation aus. Scheitert das, kommt der vorherige Programmstand zurück.
# Installiert wird nur auf ausdrücklichen Wunsch: Rückfrage, --yes oder Taste u.
# shellcheck disable=SC2034 # UPD_* lesen screens.sh, settings.sh und die Tests

UPD_FILE="$CONF_DIR/update-check"
UPD_INTERVAL=86400                                  # Sekunden zwischen zwei automatischen Prüfungen
UPD_API="https://api.github.com"
UPD_WEB="https://github.com"
UPD_RE_TAG='^[vV]?[0-9]+(\.[0-9]+){1,3}$'
UPD_RE_URL='^https://[A-Za-z0-9./_~%-]+$'
UPD_TAG="" UPD_LATEST="" UPD_URL="" UPD_ERR="" UPD_TOOL="" UPD_LIB="" UPD_BIN="" UPD_TMP=""
UPD_C_CHECKED=0 UPD_C_STATUS="" UPD_C_TAG="" UPD_C_URL=""

# a b → 0, wenn Version a neuer ist als b (Zahlenteile, ein führendes v zählt nicht)
ver_gt() {
  local -a x y; local i n a b
  IFS=. read -ra x <<< "${1#[vV]}"; IFS=. read -ra y <<< "${2#[vV]}"
  n=${#x[@]}; [ "${#y[@]}" -gt "$n" ] && n=${#y[@]}
  for ((i = 0; i < n; i++)); do
    a=${x[i]:-0} b=${y[i]:-0}
    [[ $a =~ ^[0-9]{1,9}$ && $b =~ ^[0-9]{1,9}$ ]] || return 1
    if ((10#$a > 10#$b)); then return 0; fi
    if ((10#$a < 10#$b)); then return 1; fi
  done
  return 1
}

# ─── Zustand (Cache) ───────────────────────────────────────────────────────
upd_state() { # Cache lesen → UPD_C_CHECKED UPD_C_STATUS UPD_C_TAG UPD_C_URL (leer, wenn er zu einem anderen Repo gehört)
  local k v repo=""
  UPD_C_CHECKED=0 UPD_C_STATUS="" UPD_C_TAG="" UPD_C_URL=""
  [ -r "$UPD_FILE" ] || return 0
  while IFS='=' read -r k v || [ -n "$k" ]; do
    case "$k" in
      checked) [[ $v =~ ^[0-9]{1,12}$ ]] && UPD_C_CHECKED=$v;;
      repo)    repo=$v;;
      status)  [[ $v =~ ^(ok|err|pending)$ ]] && UPD_C_STATUS=$v;;
      tag)     [[ $v =~ $UPD_RE_TAG ]] && UPD_C_TAG=$v;;
      url)     [[ $v =~ $UPD_RE_URL ]] && UPD_C_URL=$v;;
    esac
  done < "$UPD_FILE"
  [ "$repo" = "$UPDATE_REPO" ] || { UPD_C_CHECKED=0 UPD_C_STATUS="" UPD_C_TAG="" UPD_C_URL=""; }
  return 0
}

upd_newer() { upd_state; [ -n "$UPD_C_TAG" ] && ver_gt "$UPD_C_TAG" "$VERSION"; } # Cache kennt ein neueres Release

upd_save() { # status [tag url] → Cache atomar schreiben; ohne tag/url bleibt der bisherige Stand
  local tmp now
  printf -v now '%(%s)T' -1
  mkdir -p "$CONF_DIR" 2>/dev/null || return 1
  tmp=$(mktemp "$UPD_FILE.XXXXXX" 2>/dev/null) || return 1
  if printf 'checked=%s\nrepo=%s\nstatus=%s\ntag=%s\nurl=%s\n' "$now" "$UPDATE_REPO" "$1" \
       "${2-$UPD_C_TAG}" "${3-$UPD_C_URL}" > "$tmp" && mv "$tmp" "$UPD_FILE"; then
    return 0
  fi
  rm -f "$tmp"; return 1
}

upd_due() { # automatische Prüfung fällig?
  local now; printf -v now '%(%s)T' -1
  upd_state
  [ "$UPD_C_CHECKED" -gt "$now" ] && return 0               # Uhr wurde zurückgestellt
  [ $((now - UPD_C_CHECKED)) -ge "$UPD_INTERVAL" ]
}

# Start des Menüs: im Hintergrund prüfen, wenn eingeschaltet und fällig. Der Zeitpunkt wird vorher
# gespeichert (status=pending), damit parallele Logins nicht doppelt fragen und ein Fehlschlag erst
# nach UPD_INTERVAL wiederholt wird. Ohne beschreibbaren Config-Ordner wird gar nicht geprüft.
# Ohne Terminal (Pipe, Skript) weder Netz noch Datei, außer SSHLOBBY_UPDATE_CHECK=yes verlangt es.
upd_auto() {
  [ "$UPDATE_CHECK" = yes ] || return 0
  if ! { [ -t 0 ] && [ -t 1 ]; } && [ "${SSHLOBBY_UPDATE_CHECK:-}" != yes ]; then return 0; fi
  upd_due || return 0
  upd_save pending || return 0
  ( _upd_bg ) </dev/null >/dev/null 2>&1 &
  return 0
}
_upd_bg() { trap - EXIT INT TERM HUP WINCH; UPD_TIMEOUT=15 upd_fetch; } # Traps der TUI nicht erben

# ─── Netzwerk ──────────────────────────────────────────────────────────────
upd_get() { # url datei [api] [sekunden] → Exit-Code von curl/wget, 127 ohne beide (Werkzeug in UPD_TOOL)
  local -a h=()
  local max=${4:-${UPD_TIMEOUT:-30}}
  UPD_TOOL=""
  if have curl; then
    UPD_TOOL=curl
    [ "${3:-}" = api ] && h=(-H 'Accept: application/vnd.github+json')
    curl -fsSL --proto '=https' --proto-redir '=https' --connect-timeout 10 --max-time "$max" \
      -A "sshlobby/$VERSION" ${h[@]+"${h[@]}"} -o "$2" -- "$1" </dev/null
  elif have wget; then
    UPD_TOOL=wget
    [ "${3:-}" = api ] && h=(--header='Accept: application/vnd.github+json')
    timeout "$max" wget -q --https-only --timeout=10 -U "sshlobby/$VERSION" ${h[@]+"${h[@]}"} -O "$2" -- "$1" </dev/null
  else
    return 127
  fi
}

upd_neterr() { # exit-code von upd_get → UPD_ERR
  case "$UPD_TOOL:$1" in
    *:127)          UPD_ERR=${TX[update.err.tool]};;
    curl:22|wget:8) tf UPD_ERR update.err.http "$UPDATE_REPO";;
    *)              tf UPD_ERR update.err.net "$UPD_TOOL" "$1";;
  esac
}

# Neuestes Release abfragen → UPD_TAG UPD_LATEST UPD_URL; Fehler: Text in UPD_ERR, Rückgabe 1.
# Schreibt den Cache in beiden Fällen (bei Fehlern bleibt das zuletzt bekannte Release stehen).
upd_fetch() {
  local tmp rc tag="" url=""
  UPD_TAG="" UPD_LATEST="" UPD_URL="" UPD_ERR=""
  upd_state
  tmp=$(mktemp "${TMPDIR:-/tmp}/sshlobby-release.XXXXXX") || { UPD_ERR=${TX[update.err.tmp]}; return 1; }
  upd_get "$UPD_API/repos/$UPDATE_REPO/releases/latest" "$tmp" api; rc=$?
  if [ "$rc" -ne 0 ]; then rm -f "$tmp"; upd_neterr "$rc"; upd_save err; return 1; fi
  IFS=$'\t' read -r tag url < <(jq -r '[(.tag_name // "" | tostring), (.html_url // "" | tostring)] | @tsv' "$tmp" 2>/dev/null)
  rm -f "$tmp"
  if ! [[ $tag =~ $UPD_RE_TAG ]]; then UPD_ERR=${TX[update.err.answer]}; upd_save err; return 1; fi
  [[ $url =~ $UPD_RE_URL ]] || url="$UPD_WEB/$UPDATE_REPO/releases/tag/$tag"
  UPD_TAG=$tag UPD_LATEST=${tag#[vV]} UPD_URL=$url
  upd_save ok "$tag" "$url"
  return 0
}

# ─── Installation ──────────────────────────────────────────────────────────
# Laufende Installation finden → UPD_LIB (Programmordner) und UPD_BIN (Starter-Symlink). Eine Kopie aus
# einem Quellordner (install.sh daneben) wird nie ersetzt: dort gilt git pull + ./install.sh.
upd_where() {
  local d=${PD_SELF%/*} c p
  UPD_LIB="" UPD_BIN=""
  if [ -e "$d/install.sh" ] || [ -e "$d/.git" ]; then tf UPD_ERR update.err.checkout "$d"; return 1; fi
  case "$d" in */sshlobby) ;; *) tf UPD_ERR update.err.location "$d"; return 1;; esac
  for c in "${PD_CALLED:-}" "$(type -P sshlobby 2>/dev/null)"; do
    if [ -z "$c" ] || [ ! -L "$c" ] || [ "$(readlink -f "$c")" != "$PD_SELF" ]; then continue; fi
    p=$(cd "$(dirname "$c")" 2>/dev/null && pwd) || continue
    UPD_BIN="$p/${c##*/}"; break
  done
  [ -n "$UPD_BIN" ] || { tf UPD_ERR update.err.launcher "$PD_SELF"; return 1; }
  UPD_LIB=$d
}

upd_precheck() { # darf und kann diese Installation sich ersetzen? (Ort, Starter, root)
  upd_where || return 1
  [ "$(id -u)" = 0 ] || { UPD_ERR=${TX[update.err.root]}; return 1; }
}

_upd_arcerr() { local m; tf m "$1" "${@:2}"; tf UPD_ERR update.err.archive "$m"; } # grund-key [args] → UPD_ERR

# archiv ziel → entpackt ohne die oberste Ordnerebene. Erlaubt sind nur reguläre Dateien und Ordner
# unter einer gemeinsamen Wurzel: keine absoluten Pfade, kein .., keine Links, keine Geräte.
upd_unpack() {
  local list names top n
  if ! list=$(tar -tvzf "$1" 2>/dev/null) || ! names=$(tar -tzf "$1" 2>/dev/null) || [ -z "$names" ]; then
    _upd_arcerr update.err.archive.read; return 1
  fi
  top=${names%%/*}
  if ! [[ $top =~ ^[A-Za-z0-9._-]+$ ]] || [ "$top" = . ] || [ "$top" = .. ] \
     || awk '{ t = substr($1, 1, 1); if (t != "-" && t != "d") bad = 1 } END { exit !bad }' <<< "$list" \
     || grep -qE '(^|/)\.\.(/|$)' <<< "$names" \
     || awk -v p="$top/" 'index($0, p) != 1 { bad = 1 } END { exit !bad }' <<< "$names"; then
    _upd_arcerr update.err.archive.paths; return 1
  fi
  if ! mkdir -p "$2" || ! tar -xzf "$1" -C "$2" --strip-components=1 --no-same-owner 2>/dev/null; then
    _upd_arcerr update.err.archive.read; return 1
  fi
  for n in sshlobby.sh install.sh lib/core.sh; do
    [ -f "$2/$n" ] || { _upd_arcerr update.err.archive.files; return 1; }
  done
  [ -d "$2/lang" ] || { _upd_arcerr update.err.archive.files; return 1; }
}

upd_restore() { # sicherung → vorherigen Programmstand und Starter zurückholen
  [ -n "$UPD_LIB" ] && [ -f "$1/sshlobby.sh" ] || return 1
  rm -rf "${UPD_LIB:?}/lib" "${UPD_LIB:?}/lang" "${UPD_LIB:?}/examples" "${UPD_LIB:?}/sshlobby.sh"
  cp -a "$1/." "$UPD_LIB/" && ln -sfn "$UPD_LIB/sshlobby.sh" "$UPD_BIN"
}

# tag → installiert dieses Release über die laufende Installation. Fortschritt auf stdout, Fehler in
# UPD_ERR. Der Arbeitsordner (Archiv, Sicherung) verschwindet danach immer.
upd_install() {
  local rc
  upd_precheck || return 1
  UPD_TMP=$(mktemp -d "${TMPDIR:-/tmp}/sshlobby-update.XXXXXX") || { UPD_TMP=""; UPD_ERR=${TX[update.err.tmp]}; return 1; }
  _upd_install "$1" "$UPD_TMP"; rc=$?
  rm -rf "$UPD_TMP"; UPD_TMP=""
  [ "$rc" -eq 0 ] && upd_save ok "$1" "${UPD_URL:-$UPD_C_URL}"
  return "$rc"
}

_upd_install() { # tag arbeitsordner
  local tag=$1 tmp=$2 new=${1#[vV]} rc v f oldint bad
  t update.step.download "$tag"; printf '\n'
  upd_get "$UPD_WEB/$UPDATE_REPO/archive/refs/tags/$tag.tar.gz" "$tmp/release.tar.gz" "" 300; rc=$?
  [ "$rc" -eq 0 ] || { upd_neterr "$rc"; return 1; }
  printf '%s\n' "${TX[update.step.check]}"
  upd_unpack "$tmp/release.tar.gz" "$tmp/src" || return 1
  v=$(sed -n 's/^VERSION="\([^"]*\)".*$/\1/p' "$tmp/src/sshlobby.sh" | head -n 1)
  [ "$v" = "$new" ] || { _upd_arcerr update.err.archive.version "$tag" "${v:-?}"; return 1; }
  for f in "$tmp/src/sshlobby.sh" "$tmp/src/install.sh" "$tmp/src"/lib/*.sh; do
    bash -n "$f" 2>/dev/null || { _upd_arcerr update.err.archive.syntax "${f#"$tmp/src/"}"; return 1; }
  done
  # Sicherung nur für diesen Lauf (liegt im Arbeitsordner und verschwindet mit ihm)
  if ! mkdir "$tmp/prev" || ! cp -a "$UPD_LIB/." "$tmp/prev/"; then UPD_ERR=${TX[update.err.tmp]}; return 1; fi
  t update.step.install "$UPD_LIB"; printf '\n'
  # Ctrl-C darf die Installation nicht mittendrin abbrechen (dauert unter einer Sekunde)
  oldint=$(trap -p INT); trap '' INT
  env -u SSHLOBBY_LIB -u SSHLOBBY_LANGDIR LIB_DST="$UPD_LIB" BIN_DST="$UPD_BIN" bash "$tmp/src/install.sh" --update </dev/null; rc=$?
  bad=""
  if [ "$rc" -eq 0 ]; then                      # startet die neue Version und meldet sie sich richtig?
    v=$(env -u SSHLOBBY_LIB -u SSHLOBBY_LANGDIR "$UPD_BIN" --version 2>/dev/null </dev/null)
    [ "$v" = "sshlobby $new" ] || bad=${v:-?}
  fi
  if [ "$rc" -ne 0 ] || [ -n "$bad" ]; then
    if ! upd_restore "$tmp/prev"; then tf UPD_ERR update.err.restore "$rc"
    elif [ -n "$bad" ]; then tf UPD_ERR update.err.verify "$bad" "$new"
    else tf UPD_ERR update.err.install "$rc"; fi
    rc=1
  fi
  if [ -n "$oldint" ]; then eval "$oldint"; else trap - INT; fi
  [ "$rc" -eq 0 ]
}

# ─── Hauptmenü, Einstellungen ──────────────────────────────────────────────
upd_banner() { # Hauptmenü: Hinweiszeile und Taste u, wenn ein neueres Release bekannt ist
  [ "$UPDATE_CHECK" = yes ] && upd_newer || return 0
  local v; tf v update.banner.text "$VERSION"
  ui_info "${TX[update.banner.label]}" $'\001'"p-warn"$'\002'"sshlobby ${UPD_C_TAG#[vV]}"$'\t'"$v"
  UI_KEYS+=("u|${TX[update.key]}")
}

# Taste u im Hauptmenü, „Jetzt prüfen“ in den Einstellungen: frisch prüfen, nachfragen, installieren,
# danach mit der neuen Version neu starten (gleiche Argumente).
upd_tui() {
  ui_loading "${TX[update.checking_short]}"
  if ! upd_fetch; then ui_msg err "$UPD_ERR"; return 0; fi
  if ! ver_gt "$UPD_LATEST" "$VERSION"; then ui_msg ok "$(t update.uptodate "$VERSION")"; return 0; fi
  if ! upd_precheck; then ui_msg warn "$(t update.available "$UPD_LATEST" "$VERSION")"$'\n'"$UPD_ERR"; return 0; fi
  ui_confirm "$(t update.confirm "$UPD_LATEST")" || return 0
  ui_run_fg _upd_tui_run || return 0
  ui_cleanup
  exec bash "$PD_SELF" "${PD_ARGV[@]}"
}
_upd_tui_run() {
  local rc=0
  printf '\n'
  t update.available "$UPD_LATEST" "$VERSION"; printf '\n'
  if upd_install "$UPD_TAG"; then
    ui_note ok "$(t update.done "$VERSION" "$UPD_LATEST")"
    ui_note info "${TX[update.restart]}"
  else
    ui_note err "$UPD_ERR"; rc=1
  fi
  ui_pause
  return "$rc"
}

# ─── sshlobby update [--check] [--yes] ─────────────────────────────────────
cli_update() { # nur_prüfen(0|1) ohne_rückfrage(0|1) → Exit-Code 0, 1 oder PD_EXIT_UPDATE
  t update.checking "$UPDATE_REPO"; printf '\n'
  if ! upd_fetch; then printf 'sshlobby: %s\n' "$UPD_ERR" >&2; return 1; fi
  if ! ver_gt "$UPD_LATEST" "$VERSION"; then t update.uptodate "$VERSION"; printf '\n'; return 0; fi
  t update.available "$UPD_LATEST" "$VERSION"; printf '\n'
  t update.notes "$UPD_URL"; printf '\n'
  [ "$1" = 1 ] && return "$PD_EXIT_UPDATE"
  if ! upd_precheck; then printf 'sshlobby: %s\n' "$UPD_ERR" >&2; return 1; fi
  if [ "$2" != 1 ] && ! ui_confirm "$(t update.confirm "$UPD_LATEST")"; then
    printf '%s\n' "${TX[update.declined]}"; return "$PD_EXIT_UPDATE"
  fi
  # Abbruch (Ctrl-C, Verbindung weg) während des Downloads: Arbeitsordner trotzdem entfernen
  trap '[ -n "${UPD_TMP:-}" ] && rm -rf "$UPD_TMP"' EXIT
  trap 'exit 130' INT TERM HUP
  if upd_install "$UPD_TAG"; then t update.done "$VERSION" "$UPD_LATEST"; printf '\n'; return 0; fi
  printf 'sshlobby: %s\n' "$UPD_ERR" >&2
  return 1
}
