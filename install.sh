#!/usr/bin/env bash
# install.sh: installiert sshlobby (Programm nach LIB_DST, Starter BIN_DST, Bashrc-Auto-Start)
# Idempotent: mehrfaches Ausführen ist sicher, ein alter Hook-Block wird ersetzt.
# Migration von projdash (Vorgänger): alter Hook-Block wird an derselben Stelle ersetzt,
# ~/.config/projdash nach ~/.config/sshlobby kopiert (Original bleibt), alte Programmdateien entfernt.
# Pfade überschreibbar (z. B. für Tests): BIN_DST=… LIB_DST=… BASHRC=… CONF_DST=… OLD_BIN=… OLD_LIB=… OLD_CONF=…
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BIN_DST="${BIN_DST:-/usr/local/bin/sshlobby}"
LIB_DST="${LIB_DST:-/usr/local/lib/sshlobby}"
BASHRC="${BASHRC:-$HOME/.bashrc}"
CONF_DST="${CONF_DST:-$HOME/.config/sshlobby}"
OLD_BIN="${OLD_BIN:-/usr/local/bin/projdash}"
OLD_LIB="${OLD_LIB:-/usr/local/lib/projdash}"
OLD_CONF="${OLD_CONF:-$HOME/.config/projdash}"

if [ "$(id -u)" -ne 0 ]; then
  echo "Please run as root: sudo ./install.sh" >&2
  exit 1
fi
# Schutz vor Tippfehlern: LIB_DST wird beim Update geleert, darf also nur ein eigener Ordner sein
case "$LIB_DST" in
  */sshlobby) ;;
  *) echo "✗ LIB_DST must end in /sshlobby: $LIB_DST" >&2; exit 1;;
esac

# 1) Programm: sshlobby.sh + lib/ + lang/ + examples/ nach LIB_DST, Starter als Symlink
mkdir -p "$LIB_DST/lib" "$LIB_DST/lang" "$LIB_DST/examples" "$(dirname "$BIN_DST")"
rm -f "$LIB_DST"/lib/*.sh "$LIB_DST"/lang/*.txt "$LIB_DST"/examples/descriptions.* # umbenannte/entfernte Dateien nicht liegen lassen
install -m 0755 "$SCRIPT_DIR/sshlobby.sh" "$LIB_DST/sshlobby.sh"
install -m 0644 "$SCRIPT_DIR"/lib/*.sh "$LIB_DST/lib/"
install -m 0644 "$SCRIPT_DIR"/lang/*.txt "$LIB_DST/lang/"
install -m 0644 "$SCRIPT_DIR"/examples/descriptions.* "$LIB_DST/examples/"
ln -sfn "$LIB_DST/sshlobby.sh" "$BIN_DST"
echo "✓ sshlobby installed: $LIB_DST, launcher $BIN_DST"

# Abhängigkeiten prüfen (warnen, nicht abbrechen)
for tool in jq tput awk; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    echo "⚠ Warning: '$tool' not found, sshlobby needs it" >&2
  fi
done
if ! command -v incus >/dev/null 2>&1 && ! command -v docker >/dev/null 2>&1; then
  echo "⚠ Warning: neither incus nor docker found" >&2
fi

# 2) Config vom Vorgänger übernehmen (nur wenn es noch keine eigene gibt; Original bleibt liegen)
if [ -d "$OLD_CONF" ] && [ ! -e "$CONF_DST" ]; then
  mkdir -p "$(dirname "$CONF_DST")"
  cp -a "$OLD_CONF" "$CONF_DST"
  rm -f "$CONF_DST/apt-last" # gehört zur alten tmux-Sitzung
  echo "✓ Settings migrated: $OLD_CONF → $CONF_DST (original kept)"
fi

# 3) Bashrc-Hook: fehlt → anhängen, alt (auch projdash) → an gleicher Stelle ersetzen, aktuell → nichts tun
# Nur Exit-Code 20 (q) loggt aus; EOF, Absturz, s usw. landen in der Shell.
HOOK_START='# >>> sshlobby >>>'
HOOK_END='# <<< sshlobby <<<'
OLD_STARTS=$'# >>> sshlobby dashboard >>>\n# >>> projdash dashboard >>>'
OLD_ENDS=$'# <<< sshlobby dashboard <<<\n# <<< projdash dashboard <<<'
HOOK_BLOCK=$(cat <<'EOF'
# >>> sshlobby >>>
if [ -n "$PS1" ] && [ -t 0 ] && [ -t 1 ] && [ -z "$SSHLOBBY_SKIP" ] && [ "$SSH_TTY" ] && [[ $- == *i* ]] && ! [[ "${SSH_ORIGINAL_COMMAND:-}" ]]; then
  SSHLOBBY_SKIP=1 SSHLOBBY_LOGIN=1 sshlobby; [ $? -eq 20 ] && exit
fi
# <<< sshlobby <<<
EOF
)

touch "$BASHRC"
starts=$(printf '%s\n%s' "$HOOK_START" "$OLD_STARTS")
ends=$(printf '%s\n%s' "$HOOK_END" "$OLD_ENDS")
n_start=$(grep -cxF "$starts" "$BASHRC" || true)
n_end=$(grep -cxF "$ends" "$BASHRC" || true)
if [ "$n_start" != "$n_end" ]; then
  echo "✗ $BASHRC: hook block without end marker, please fix by hand" >&2
  exit 1
fi
had_hook=0; [ "$n_start" -gt 0 ] && had_hook=1
tmp=$(mktemp); trap 'rm -f "$tmp"' EXIT
HOOK_BLOCK="$HOOK_BLOCK" STARTS="$starts" ENDS="$ends" awk '
  BEGIN { n = split(ENVIRON["STARTS"], s, "\n"); for (i = 1; i <= n; i++) st[s[i]] = 1
          n = split(ENVIRON["ENDS"], e, "\n");   for (i = 1; i <= n; i++) en[e[i]] = 1 }
  ($0 in st) { skip = 1; if (!done) { print ENVIRON["HOOK_BLOCK"]; done = 1 }; next }
  skip       { if ($0 in en) skip = 0; next }
             { print }
  END        { if (!done) print ENVIRON["HOOK_BLOCK"] }' "$BASHRC" > "$tmp"

if cmp -s "$tmp" "$BASHRC"; then
  echo "✓ Bashrc hook is up to date"
else
  cat "$tmp" > "$BASHRC" # Inhalt ersetzen, Symlink/Rechte der Bashrc bleiben
  if [ "$had_hook" -eq 1 ]; then echo "✓ Bashrc hook updated: $BASHRC"
  else echo "✓ Auto-start hook added: $BASHRC"; fi
fi

# 4) Vorgänger projdash entfernen: Starter (Symlink in OLD_LIB oder Einzeldatei mit projdash-Kennung)
# und die bekannten Dateien in OLD_LIB. Kein rm -rf auf fremde Ordner.
if [ -L "$OLD_BIN" ] || { [ -f "$OLD_BIN" ] && grep -q 'projdash' "$OLD_BIN" 2>/dev/null; }; then
  rm -f "$OLD_BIN"; echo "✓ Removed predecessor launcher: $OLD_BIN"
fi
if [ -f "$OLD_LIB/projdash.sh" ]; then
  rm -f "$OLD_LIB/projdash.sh" "$OLD_LIB"/lib/*.sh "$OLD_LIB"/examples/descriptions.*
  rmdir "$OLD_LIB/lib" "$OLD_LIB/examples" "$OLD_LIB" 2>/dev/null || true
  echo "✓ Removed predecessor program: $OLD_LIB"
fi

echo
echo "Done. The dashboard starts on the next SSH login (first start asks for the mode)."
echo "Try it now:  sshlobby"
echo "Skip it:     SSHLOBBY_SKIP=1  (as a prefix or exported in the shell)"
