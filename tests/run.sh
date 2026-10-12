#!/usr/bin/env bash
# Testsuite für sshlobby. Läuft ohne root-Seiteneffekte:
# incus/docker/ssh/systemctl/journalctl/mutagen/hostname sind Stubs (tests/stubs), HOME, Bashrc
# und Installationsziele zeigen auf ein Wegwerf-Verzeichnis unter ${TMPDIR:-/tmp}.
# PATH enthält nur die Stubs und einzeln verlinkte Systemwerkzeuge (SYSBIN), echte docker-,
# incus-, systemctl- oder ssh-Binaries sind damit gar nicht erreichbar.
#   bash tests/run.sh            alle Tests
#   bash tests/run.sh b2 sigint  nur Tests, deren Name eines der Muster enthält
# Tests liegen in tests/test_*.sh (Funktionen t_*), Helfer in tests/lib.sh. Neue Bereiche:
# einfach eine weitere tests/test_<name>.sh anlegen, der Runner lädt sie automatisch.
# Ein Test meldet SKIP mit „skip <grund>“ (Exit-Code 77).
set -u

T=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ROOT=$(dirname "$T")
PD="$ROOT/sshlobby.sh"
BASE=$(mktemp -d "${TMPDIR:-/tmp}/sshlobby-test.XXXXXX") || exit 1
# Eigener tmux-Server pro Lauf: parallele Testläufe (z. B. mehrere Worktrees) stören sich nicht
export PD_TMUX_SOCK="sshlobby-test-$$"
trap 'tmux -L "$PD_TMUX_SOCK" kill-server 2>/dev/null; rm -rf "$BASE"' EXIT

# Isolierter PATH: Stubs zuerst, danach nur ausdrücklich verlinkte Werkzeuge
SYSBIN="$BASE/sysbin"; mkdir -p "$SYSBIN"
for c in bash sh env setsid jq awk sed grep cut tr sort head tail wc date mktemp mv cp cat rm rmdir \
         mkdir touch ln readlink dirname basename seq sleep timeout id install cmp find ls tput stty \
         uptime df ps free uniq tee chmod stat true false diff od xargs tac tmux shellcheck kill \
         printf test expr realpath comm paste nl yes mkfifo; do
  p=$(type -P "$c") && ln -s "$p" "$SYSBIN/$c"
done
export PATH="$T/stubs:$SYSBIN" LC_ALL=C.UTF-8 SSHLOBBY_LANG=de  # Tests prüfen die deutschen Texte
for c in docker incus systemctl ssh journalctl hostname; do
  [ "$(type -P "$c")" = "$T/stubs/$c" ] || { echo "ABBRUCH: $c ist nicht der Stub" >&2; exit 1; }
done
# Shells im Stub lassen stdin in Ruhe (wie am Terminal), nicht-interaktive incus exec lesen es leer
export STUB_TTY_INTERACTIVE=1
unset SSHLOBBY_SKIP SSHLOBBY_MODE SSHLOBBY_UI SSHLOBBY_LIB SSHLOBBY_EXAMPLES
PASS=0; FAIL=0; SKIP=0

# shellcheck source=tests/lib.sh
. "$T/lib.sh"
for f in "$T"/test_*.sh; do
  # shellcheck source=/dev/null
  . "$f"
done

for t in $(declare -F | awk '$3 ~ /^t_/ {print $3}'); do
  if [ $# -gt 0 ]; then
    m=0; for p in "$@"; do [[ "$t" == *"$p"* ]] && m=1; done; [ $m -eq 1 ] || continue
  fi
  setup
  msg=$( ( "$t" ) 2>&1 ); rc=$?
  if [ $rc -eq 0 ]; then
    PASS=$((PASS+1)); printf 'PASS  %s\n' "${t#t_}"
  elif [ $rc -eq 77 ]; then
    SKIP=$((SKIP+1)); printf 'SKIP  %s  (%s)\n' "${t#t_}" "$(tail -n1 <<< "$msg")"
  else
    FAIL=$((FAIL+1)); printf 'FAIL  %s\n' "${t#t_}"; printf '%s\n' "$msg" | tail -n 25 | sed 's/^/      /'
  fi
done
printf '\n%d bestanden, %d fehlgeschlagen, %d übersprungen\n' "$PASS" "$FAIL" "$SKIP"
[ "$FAIL" -eq 0 ]
