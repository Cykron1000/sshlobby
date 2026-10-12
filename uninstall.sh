#!/usr/bin/env bash
# uninstall.sh: entfernt sshlobby
#   ./uninstall.sh          Programm, Starter und Bashrc-Hook entfernen
#   ./uninstall.sh --purge  zusätzlich Konfiguration (~/.config/sshlobby) löschen
# Pfade überschreibbar (z. B. für Tests): BIN_DST=… LIB_DST=… BASHRC=… ./uninstall.sh
set -euo pipefail

BIN_DST="${BIN_DST:-/usr/local/bin/sshlobby}"
LIB_DST="${LIB_DST:-/usr/local/lib/sshlobby}"
BASHRC="${BASHRC:-$HOME/.bashrc}"
CONF_DST="${CONF_DST:-$HOME/.config/sshlobby}"
HOOK_START='# >>> sshlobby >>>'
HOOK_END='# <<< sshlobby <<<'

if [ "$(id -u)" -ne 0 ]; then
  echo "Please run as root: sudo ./uninstall.sh [--purge]" >&2
  exit 1
fi
case "$LIB_DST" in
  */sshlobby) ;;
  *) echo "✗ LIB_DST must end in /sshlobby: $LIB_DST" >&2; exit 1;;
esac

# 1) Starter (Symlink oder alte v1-Datei) und Programm. Nur eigene Dateien löschen, kein rm -rf.
if [ -L "$BIN_DST" ] || [ -f "$BIN_DST" ]; then
  rm -f "$BIN_DST"
  echo "✓ Removed: $BIN_DST"
else
  echo "– $BIN_DST was not installed"
fi
if [ -f "$LIB_DST/sshlobby.sh" ]; then
  rm -f "$LIB_DST/sshlobby.sh" "$LIB_DST"/lib/*.sh "$LIB_DST"/lang/*.txt "$LIB_DST"/examples/descriptions.*
  rmdir "$LIB_DST/lib" "$LIB_DST/lang" "$LIB_DST/examples" 2>/dev/null || true
  if rmdir "$LIB_DST" 2>/dev/null; then echo "✓ Removed: $LIB_DST"
  else echo "– $LIB_DST contains other files, folder kept"; fi
fi

# 2) Bashrc-Hook-Block entfernen, hängende Leerzeilen am Dateiende glätten
if ! grep -qxF "$HOOK_START" "$BASHRC" 2>/dev/null; then
  echo "– No bashrc hook found"
elif ! grep -qxF "$HOOK_END" "$BASHRC"; then
  echo "✗ $BASHRC: hook block without end marker, left untouched (please remove by hand)" >&2
else
  tmp=$(mktemp); trap 'rm -f "$tmp"' EXIT
  awk -v s="$HOOK_START" -v e="$HOOK_END" '
    $0==s { skip=1; next }
    skip  { if ($0==e) skip=0; next }
    /^$/  { blank++; next }
          { while (blank > 0) { print ""; blank-- }; print }' "$BASHRC" > "$tmp"
  cat "$tmp" > "$BASHRC" # Inhalt ersetzen, Symlink/Rechte der Bashrc bleiben
  echo "✓ Bashrc hook removed"
fi

# 3) Config (optional)
if [ "${1:-}" = "--purge" ]; then
  rm -rf "$CONF_DST"
  echo "✓ Settings deleted: $CONF_DST"
else
  [ -d "$CONF_DST" ] && echo "– Settings kept: $CONF_DST (favorites, history; delete with --purge)"
fi

echo "Done."
