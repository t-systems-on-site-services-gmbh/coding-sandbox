#!/usr/bin/env bash
# Startlogik der Sandbox. Laeuft als Nutzer "dev" bei jedem Containerstart.
# Fehler hier duerfen den Start nicht verhindern, daher kein "set -e".
set -u

log() { printf '[sandbox] %s\n' "$*"; }
READY=/tmp/.sandbox-ready
rm -f "$READY"

# ---------------------------------------------------------------- Vorlagen
# config/codex/config.toml -> ~/.codex/config.toml (nur wenn noch keine da ist,
# oder immer bei SEED_OVERWRITE=1)
seed() {
  local src="$1" dst="$2"
  [ -f "$src" ] || return 0
  if [ ! -f "$dst" ] || [ "${SEED_OVERWRITE:-0}" = "1" ]; then
    mkdir -p "$(dirname "$dst")"
    cp "$src" "$dst"
    log "Vorlage uebernommen: $dst"
  fi
}
if command -v codex >/dev/null 2>&1; then
  seed /opt/seed/codex/config.toml "$HOME/.codex/config.toml"
  seed /opt/seed/codex/AGENTS.md   "$HOME/.codex/AGENTS.md"
fi

# ---------------------------------------------------------------- Git
if [ -n "${GIT_USER_NAME:-}" ] && [ -z "$(git config --global user.name 2>/dev/null)" ]; then
  git config --global user.name "$GIT_USER_NAME"
fi
if [ -n "${GIT_USER_EMAIL:-}" ] && [ -z "$(git config --global user.email 2>/dev/null)" ]; then
  git config --global user.email "$GIT_USER_EMAIL"
fi
git config --global init.defaultBranch main
# Bind-Mounts gehoeren je nach Host einem anderen Nutzer (macOS): kein
# "dubious ownership" innerhalb der Sandbox
git config --global --get-all safe.directory 2>/dev/null | grep -qx '\*' \
  || git config --global --add safe.directory '*'
if command -v gh >/dev/null 2>&1 && gh auth status >/dev/null 2>&1; then
  gh auth setup-git >/dev/null 2>&1 || true
fi

# ---------------------------------------------------------------- opencode/AIE
# Entspricht "opencode auth login https://plugins.dev.aie.ai.t-systems.net".
# Der Schritt laedt nur die AIE-Konfiguration (Provider, Modelle); die
# eigentlichen API-Keys traegt der Nutzer spaeter im TUI per /connect ein.
aie_logged_in() {
  local f="$HOME/.local/share/opencode/auth.json"
  [ -f "$f" ] && grep -qF "${AIE_AUTH_URL%/}" "$f"
}
if [ "${AIE_AUTO_LOGIN:-1}" = "1" ] && command -v opencode >/dev/null 2>&1 && ! aie_logged_in; then
  log "Richte AIE-Konfiguration fuer opencode ein ($AIE_AUTH_URL) ..."
  if timeout 60 opencode auth login "$AIE_AUTH_URL" </dev/null >/tmp/aie-login.log 2>&1 && aie_logged_in; then
    log "AIE-Konfiguration eingerichtet."
  else
    log "AIE-Login nicht moeglich (Netz/Proxy?). Spaeter: ./sandbox.sh login opencode"
    log "Details: /tmp/aie-login.log"
  fi
fi

touch "$READY"
exec "$@"
