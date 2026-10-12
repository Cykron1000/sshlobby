# shellcheck shell=bash
# setup.sh: Moduserkennung, Moduswahl für den Lauf und Setup-Screen.
# Reihenfolge der Moduswahl: --mode, SSHLOBBY_MODE, MODE aus der Config, sonst Erkennung.
# Ohne Config fragt nur das interaktive Menü am Terminal (Setup-Screen); ohne TTY, bei --list
# und --go wird still erkannt und nichts geschrieben (Login-Hook und Skripte blockieren nie).
# shellcheck disable=SC2034 # DET_* und MODE_SRC lesen cli.sh und Tests

# Erkennung → DET_INCUS DET_DOCKER (ok|down|missing), DET_NCT, DET_NDK, DET_LAYERED (erster CT
# mit erreichbarem Docker), DET_MODE. Alle Aufrufe nicht-interaktiv und mit Timeout.
setup_detect() {
  local json ct out
  DET_INCUS=missing DET_NCT=0 DET_DOCKER=missing DET_NDK=0 DET_LAYERED="" DET_MODE=docker
  if have incus; then
    if json=$(timeout 10 incus list --format json </dev/null 2>/dev/null) && [ -n "$json" ]; then
      DET_INCUS=ok
      DET_NCT=$(jq 'length' <<< "$json" 2>/dev/null) || DET_NCT=0
      while IFS= read -r ct; do
        [ -n "$ct" ] || continue
        if timeout 5 incus exec "$ct" -- docker ps -q </dev/null >/dev/null 2>&1; then DET_LAYERED=$ct; break; fi
      done < <(jq -r '.[] | select(.status=="Running") | .name' <<< "$json" 2>/dev/null)
    else
      DET_INCUS=down
    fi
  fi
  if have docker; then
    if out=$(timeout 10 docker ps -aq </dev/null 2>/dev/null); then
      DET_DOCKER=ok; DET_NDK=$(printf '%s\n' "$out" | grep -c .)
    else
      DET_DOCKER=down
    fi
  fi
  if [ -n "$DET_LAYERED" ]; then DET_MODE=layered
  elif [ "$DET_DOCKER" = ok ] && [ "$DET_NDK" -gt 0 ]; then DET_MODE=docker
  elif [ "$DET_INCUS" = ok ]; then DET_MODE=incus
  else DET_MODE=docker; fi
}

# Modus für diesen Lauf → MODE, MODE_SRC (arg|env|config|auto). Rückgabe 2 bei ungültigem Wert.
mode_resolve() { # [--mode-wert] [erkennen=1]
  if [ -n "${1:-}" ]; then MODE=$1 MODE_SRC=arg; return 0; fi
  if [ -n "${SSHLOBBY_MODE:-}" ]; then
    mode_valid "$SSHLOBBY_MODE" || { printf '%s\n' "$(t setup.err.bad_mode "$SSHLOBBY_MODE")" >&2; return 2; }
    MODE=$SSHLOBBY_MODE MODE_SRC=env; return 0
  fi
  if [ -n "$CFG_MODE" ]; then MODE=$CFG_MODE MODE_SRC=config; return 0; fi
  MODE_SRC=auto MODE=""
  [ "${2:-1}" = 1 ] || return 0
  setup_detect; MODE=$DET_MODE
}

_setup_state() { # ok|down|missing anzahl einheit
  case "$1" in
    ok) t setup.state.ok "$2" "$3";;
    down) printf '%s' "${TX[setup.state.down]}";;
    *) printf '%s' "${TX[setup.state.missing]}";;
  esac
}

# Setup-Screen: erkennen, Modus wählen, Config schreiben, Anzeigenamen und Beispiel-
# Beschreibungen anbieten. Rückgabe 0 gespeichert, 1 abgebrochen oder Fehler.
setup_run() {
  local m d
  ui_loading "${TX[setup.loading]}"
  setup_detect
  ui_info "Incus" "$(_setup_state "$DET_INCUS" "$DET_NCT" "${TX[setup.unit.cts]}")"
  ui_info "Docker" "$(t setup.info.docker_host "$(_setup_state "$DET_DOCKER" "$DET_NDK" "${TX[setup.unit.containers]}")")"
  if [ "$DET_INCUS" = ok ]; then
    if [ -n "$DET_LAYERED" ]; then ui_info "${TX[setup.info.docker_in_cts]}" "$(t setup.info.yes_example "$DET_LAYERED")"
    else ui_info "${TX[setup.info.docker_in_cts]}" "${TX[setup.info.no]}"; fi
  fi
  ui_info "${TX[setup.info.suggestion]}" "$DET_MODE"
  if [ "$CFG_EXISTS" = 1 ]; then ui_info "${TX[setup.info.config]}" "$CONF_FILE_SHOW${CFG_MODE:+ (MODE=$CFG_MODE)}"
  else ui_info "${TX[setup.info.config]}" "$(t setup.info.config_new "$CONF_FILE_SHOW")"; fi
  for m in docker incus layered; do
    d=$(setup_mode_desc "$m")
    if [ "$m" = "$DET_MODE" ]; then ui_item item "$m" "$m" "$d  ← ${TX[setup.detected]}" "" "$d"$'\t'"$(ui_cell p-info "${TX[setup.detected]}")"
    else ui_item item "$m" "$m" "$d" "" "$d"; fi
  done
  UI_PRESEL=${CFG_MODE:-$DET_MODE}
  ui_menu "${TX[setup.title]}" "${TX[setup.choose_mode]}"
  [ "$UI_ACT" = select ] || return 1
  if ! cfg_set MODE "$UI_SEL"; then ui_msg err "$(t setup.err.config_write "$CONF_FILE")"; return 1; fi
  CFG_MODE=$UI_SEL MODE=$UI_SEL MODE_SRC=config CFG_EXISTS=1
  setup_label
  setup_offer_descriptions
  ui_note ok "$(t setup.saved "$MODE" "$CONF_FILE")"
  return 0
}

setup_mode_desc() {
  case "$1" in
    docker|incus|layered) printf '%s' "${TX[setup.mode.$1]}";;
  esac
}

# Anzeigename für den Kopf (HOST_LABEL), vorbelegt mit dem aktuellen Wert (Default hostname -s).
# Nur eine Änderung wird geschrieben; leer, Abbruch oder EOF lassen alles, wie es ist.
setup_label() {
  local cur=$HOST_LABEL v
  ui_input "${TX[setup.label]}" "$cur" || return 0
  v=${UI_INPUT//|/}; v=${v#"${v%%[![:space:]]*}"}; v=${v%"${v##*[![:space:]]}"}; v=${v:0:40}
  [ -n "$v" ] && [ "$v" != "$cur" ] || return 0
  if cfg_set HOST_LABEL "$v"; then HOST_LABEL=$v; else ui_msg err "$(t setup.err.config_write "$CONF_FILE")"; fi
}

# Alle examples/descriptions.<name> zur Auswahl, die zum hostname -s passende vorausgewählt,
# „keine“ möglich. Ist die aktuelle Datei schon die passende, wird nicht gefragt.
setup_offer_descriptions() {
  local f name n pre=none none=${TX[setup.desc.none]} src lbl
  local -a files=()
  for f in "$PD_EXAMPLES"/descriptions.*; do [ -r "$f" ] && files+=("$f"); done
  [ ${#files[@]} -gt 0 ] || return 0
  src="$PD_EXAMPLES/descriptions.$PD_HOST"
  [ -r "$src" ] && cmp -s "$src" "$DESCRIPTIONS" 2>/dev/null && return 0
  if [ -e "$DESCRIPTIONS" ]; then
    ui_info "${TX[setup.desc.target]}" "$(t setup.desc.target_backup "$DESCRIPTIONS")"
    none=${TX[setup.desc.keep]}
  else
    ui_info "${TX[setup.desc.target]}" "$DESCRIPTIONS"
  fi
  ui_item header "" "${TX[setup.desc.section]}" "" main
  for f in "${files[@]}"; do
    name=${f##*/descriptions.}
    n=$(grep -c '^[^#][^|]*|' "$f")
    tf lbl setup.desc.entries "$n"
    if cmp -s "$f" "$DESCRIPTIONS" 2>/dev/null; then lbl+=", ${TX[setup.desc.already]}"
    elif [ "$name" = "$PD_HOST" ]; then lbl+="  ← $(t setup.desc.matches "$PD_HOST")"; pre="ex:$name"; fi
    ui_item item "ex:$name" "examples/descriptions.$name" "$lbl"
  done
  ui_item sep
  ui_item item none "${TX[setup.desc.none_label]}" "$none"
  UI_PRESEL=$pre
  ui_menu "${TX[setup.desc.title]}" "${TX[setup.desc.question]}"
  [ "$UI_ACT" = select ] && [ "$UI_SEL" != none ] || return 0
  src="$PD_EXAMPLES/descriptions.${UI_SEL#ex:}"
  cmp -s "$src" "$DESCRIPTIONS" 2>/dev/null && return 0
  mkdir -p "$CONF_DIR" || return 0
  [ -e "$DESCRIPTIONS" ] && cp -p "$DESCRIPTIONS" "$DESCRIPTIONS.bak"
  cp "$src" "$DESCRIPTIONS" && desc_load && ui_note ok "$(t setup.desc.imported "${UI_SEL#ex:}")"
}
