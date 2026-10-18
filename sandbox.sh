#!/usr/bin/env bash
# Coding-Sandbox: Start- und Steuerskript fuer macOS und Linux/WSL2.
# Laeuft auch mit dem alten bash 3.2 von macOS.
set -u

CALLER_PWD="$PWD"
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
cd "$DIR" || exit 1

# ---------------------------------------------------------------- Ausgabe
if [ -t 1 ]; then B=$'\e[1m'; R=$'\e[31m'; G=$'\e[32m'; Y=$'\e[33m'; N=$'\e[0m'; else B=; R=; G=; Y=; N=; fi
info() { printf '%s==>%s %s\n' "$B" "$N" "$*"; }
ok()   { printf '  %sOK%s    %s\n' "$G" "$N" "$*"; }
warn() { printf '  %sWARN%s  %s\n' "$Y" "$N" "$*"; }
bad()  { printf '  %sFEHLER%s %s\n' "$R" "$N" "$*"; }
die()  { printf '%sFehler:%s %s\n' "$R" "$N" "$*" >&2; exit 1; }

# ---------------------------------------------------------------- .env
if [ ! -f .env ]; then
  cp .env.example .env
  info "Neue .env aus .env.example angelegt - bei Bedarf anpassen (Proxy, Workspace)."
fi

# Einzelwert aus .env lesen (ohne die Datei als Shell-Code auszufuehren)
envval() {
  local v
  v="$(grep -E "^[[:space:]]*$1=" .env 2>/dev/null | tail -n1 | cut -d= -f2-)"
  v="${v%\"}"; v="${v#\"}"; v="${v%\'}"; v="${v#\'}"
  printf '%s' "${v:-${2:-}}"
}

NAME="$(envval SANDBOX_NAME coding-sandbox)"
DEFAULT_ENTRY="$(envval DEFAULT_ENTRY shell)"

OS="$(uname -s)"
IS_WSL=0
if [ "$OS" = "Linux" ] && grep -qiE 'microsoft|wsl' /proc/version 2>/dev/null; then IS_WSL=1; fi

# UID/GID fuer den Nutzer im Image = die des Hosts, damit Dateien in /work
# dem eigenen Nutzer gehoeren (macOS: meist 501/20, WSL2: meist 1000/1000).
HOST_UID="$(id -u)"; HOST_GID="$(id -g)"
# Als root (UID 0) laesst sich kein Nutzer "dev" anlegen - dann 1000
if [ "$HOST_UID" = "0" ]; then HOST_UID=1000; HOST_GID=1000; fi
export HOST_UID HOST_GID

# Git-Identitaet vom Host uebernehmen, wenn in .env nichts steht
if [ -z "$(envval GIT_USER_NAME)" ] && command -v git >/dev/null 2>&1; then
  GIT_USER_NAME="$(git config --global user.name 2>/dev/null || true)"; export GIT_USER_NAME
fi
if [ -z "$(envval GIT_USER_EMAIL)" ] && command -v git >/dev/null 2>&1; then
  GIT_USER_EMAIL="$(git config --global user.email 2>/dev/null || true)"; export GIT_USER_EMAIL
fi

# ---------------------------------------------------------------- Engine
# Docker (Desktop, Engine unter WSL2, Colima, Rancher Desktop, OrbStack).
# Eigenes Kommando per SANDBOX_COMPOSE moeglich, z. B. "podman compose".
DOCKER="${SANDBOX_DOCKER:-docker}"
if [ -n "${SANDBOX_COMPOSE:-}" ]; then
  COMPOSE="$SANDBOX_COMPOSE"
elif $DOCKER compose version >/dev/null 2>&1; then
  COMPOSE="$DOCKER compose"
elif command -v docker-compose >/dev/null 2>&1; then
  COMPOSE="docker-compose"
else
  COMPOSE=""
fi

need_engine() {
  command -v "$DOCKER" >/dev/null 2>&1 || die "'$DOCKER' nicht gefunden. Docker installieren (siehe README)."
  [ -n "$COMPOSE" ] || die "Docker Compose fehlt ('docker compose version' schlaegt fehl)."
  $DOCKER info >/dev/null 2>&1 || die "Docker laeuft nicht oder ist nicht erreichbar. Docker Desktop starten bzw. 'sudo service docker start'."
  # CPU-Grenze nicht hoeher als das, was die Engine hat (Docker Desktop
  # teilt oft nur 2 CPUs zu - sonst bricht der Start ab)
  local want have
  want="$(envval SANDBOX_CPUS 4)"; want="${want%%.*}"
  have="$($DOCKER info --format '{{.NCPU}}' 2>/dev/null)"
  case "$want$have" in *[!0-9]*|"") ;; *)
    if [ "$want" -gt "$have" ]; then SANDBOX_CPUS="$have"; export SANDBOX_CPUS; fi ;;
  esac
}

# compose.local.yaml (optional, nicht im Git) ergaenzt compose.yaml um
# persoenliche Mounts, Ports usw.
compose() {
  if [ -f "$DIR/compose.local.yaml" ]; then
    $COMPOSE --project-directory "$DIR" -f "$DIR/compose.yaml" -f "$DIR/compose.local.yaml" --env-file "$DIR/.env" "$@"
  else
    $COMPOSE --project-directory "$DIR" -f "$DIR/compose.yaml" --env-file "$DIR/.env" "$@"
  fi
}

running() { [ "$($DOCKER inspect -f '{{.State.Running}}' "$NAME" 2>/dev/null)" = "true" ]; }

ensure_up() {
  need_engine
  if ! running; then
    info "Starte Sandbox '$NAME' (beim ersten Mal wird das Image gebaut, das dauert einige Minuten) ..."
    compose up -d || die "Start fehlgeschlagen."
  fi
  # Warten, bis entrypoint.sh durch ist (Vorlagen, AIE-Login)
  local i=0
  while [ $i -lt 90 ]; do
    $DOCKER exec "$NAME" test -f /tmp/.sandbox-ready 2>/dev/null && return 0
    sleep 1; i=$((i + 1))
  done
  warn "Startskript im Container noch nicht fertig - weiter mit './sandbox.sh logs'."
}

# Aktuelles Verzeichnis auf /work abbilden, wenn es im Workspace liegt
container_wd() {
  local ws here rel
  ws="$(envval WORKSPACE_DIR ./workspace)"
  case "$ws" in "~"*) ws="$HOME${ws#\~}" ;; esac
  case "$ws" in /*) ;; *) ws="$DIR/$ws" ;; esac
  ws="$(cd "$ws" 2>/dev/null && pwd -P)" || { echo /work; return; }
  here="$(cd "$CALLER_PWD" && pwd -P)"
  case "$here/" in
    "$ws"/*) rel="${here#"$ws"}"; echo "/work$rel" ;;
    *) echo /work ;;
  esac
}

dexec() {
  # dexec [-T] cmd...   (-T: ohne Terminal, z. B. fuer Pipes)
  local tty="-i"
  if [ "${1:-}" = "-T" ]; then shift; else [ -t 0 ] && [ -t 1 ] && tty="-it"; fi
  $DOCKER exec $tty -w "$(container_wd)" -e TERM="${TERM:-xterm-256color}" "$NAME" "$@"
}

# ---------------------------------------------------------------- Befehle
cmd_help() {
  cat <<EOF
${B}Coding-Sandbox${N} - Codex und opencode (AIE) im Container

  ./sandbox.sh                 Sandbox starten und hineinspringen (DEFAULT_ENTRY=$DEFAULT_ENTRY)
  ./sandbox.sh shell           Shell im Container
  ./sandbox.sh codex [args]    Codex starten
  ./sandbox.sh opencode [args] opencode starten
  ./sandbox.sh run <befehl>    beliebigen Befehl im Container ausfuehren

  ./sandbox.sh login codex           Anmeldung mit ChatGPT-Abo (Browser auf dem Host)
  ./sandbox.sh login codex --device  Anmeldung per Geraetecode (ohne Rueckleitung)
  ./sandbox.sh login opencode        AIE-Konfiguration neu holen (opencode auth login)
  ./sandbox.sh import-codex-auth [datei]  vorhandene ~/.codex/auth.json uebernehmen

  ./sandbox.sh status | logs | stop | restart
  ./sandbox.sh doctor          Selbsttest: Docker, Image, Netz, Anmeldungen
  ./sandbox.sh rebuild         Image neu bauen (nach Aenderung an .env/certs)
  ./sandbox.sh update          neueste Codex/opencode-Versionen einbauen
  ./sandbox.sh reseed          Vorlagen aus config/ neu einspielen
  ./sandbox.sh destroy         Container UND Volumes loeschen (Anmeldungen weg)
EOF
}

cmd_shell()    { ensure_up; dexec bash -l; }
cmd_codex()    { ensure_up; dexec codex "$@"; }
cmd_opencode() { ensure_up; dexec opencode "$@"; }
cmd_run() {
  [ "${1:-}" = "--" ] && shift
  [ $# -gt 0 ] || die "Aufruf: ./sandbox.sh run <befehl>"
  ensure_up; dexec "$@"
}

cmd_login() {
  local what="${1:-}"; shift || true
  case "$what" in
    codex)
      ensure_up
      if [ "${1:-}" = "--device" ]; then
        info "Geraetecode-Anmeldung. Voraussetzung: in ChatGPT unter Einstellungen > Sicherheit"
        info "\"Geraetecode-Anmeldung erlauben\" (bei Workspace-Konten: Admin) aktiviert."
        dexec codex login --device-auth
        return
      fi
      # Codex' Login-Server lauscht im Container nur auf 127.0.0.1:1455.
      # socat reicht den veroeffentlichten Port (Container-IP:1455) dorthin
      # durch, damit die Browser-Rueckleitung vom Host ankommt.
      local cip
      cip="$($DOCKER exec "$NAME" sh -c "hostname -I 2>/dev/null | awk '{print \$1}'")"
      [ -n "$cip" ] || die "Container-IP nicht ermittelbar."
      $DOCKER exec "$NAME" pkill -f 'socat TCP-LISTEN:1455' >/dev/null 2>&1 || true
      $DOCKER exec -d "$NAME" socat "TCP-LISTEN:1455,bind=$cip,reuseaddr,fork" TCP:127.0.0.1:1455
      info "Gleich erscheint ein Link. Ihn im Browser auf ${B}diesem Rechner${N} oeffnen und anmelden."
      info "Klappt die Rueckleitung nicht: ./sandbox.sh login codex --device"
      dexec codex login
      local rc=$?
      $DOCKER exec "$NAME" pkill -f 'socat TCP-LISTEN:1455' >/dev/null 2>&1 || true
      [ $rc -eq 0 ] && dexec -T codex login status
      return $rc
      ;;
    opencode|aie)
      ensure_up
      local url; url="$(envval AIE_AUTH_URL https://plugins.dev.aie.ai.t-systems.net)"
      dexec opencode auth login "$url"
      info "Danach im TUI: ${B}/connect${N} -> Provider waehlen -> API-Key eintragen."
      ;;
    *) die "Aufruf: ./sandbox.sh login codex [--device] | login opencode" ;;
  esac
}

cmd_import_codex_auth() {
  local src="${1:-$HOME/.codex/auth.json}"
  [ -f "$src" ] || die "Keine Datei $src. (Auf dem Mac liegt das Token evtl. im Schluesselbund - dann ./sandbox.sh login codex.)"
  ensure_up
  if $DOCKER exec "$NAME" test -s /home/dev/.codex/auth.json; then
    printf 'Im Container gibt es schon eine Anmeldung. Ueberschreiben? [j/N] '
    local a; read -r a; case "$a" in j|J|y|Y) ;; *) echo "Abgebrochen."; return 1 ;; esac
  fi
  $DOCKER exec -i "$NAME" sh -c 'umask 077; cat > /home/dev/.codex/auth.json' < "$src" \
    && info "Uebernommen." && dexec -T codex login status
}

cmd_status() {
  need_engine
  compose ps
  if running; then
    echo
    dexec -T sh -c 'printf "codex     %s\nopencode  %s\n" "$(codex --version 2>/dev/null)" "$(opencode --version 2>/dev/null)"'
  fi
}

cmd_doctor() {
  info "Host"
  ok "System: $OS$( [ $IS_WSL -eq 1 ] && echo ' (WSL2)')"
  if [ $IS_WSL -eq 1 ]; then
    case "$DIR" in /mnt/[a-z]/*) warn "Repo liegt auf dem Windows-Laufwerk ($DIR). Langsam und Rechteprobleme - besser nach ~/ klonen." ;; *) ok "Repo im Linux-Dateisystem" ;; esac
  fi
  case "$(envval WORKSPACE_DIR ./workspace)" in /mnt/[a-z]/*) [ $IS_WSL -eq 1 ] && warn "WORKSPACE_DIR liegt unter /mnt/... - langsam, besser ~/..." ;; esac

  info "Docker"
  if command -v "$DOCKER" >/dev/null 2>&1; then ok "$($DOCKER --version)"; else bad "$DOCKER fehlt"; return 1; fi
  if [ -n "$COMPOSE" ]; then ok "Compose: $COMPOSE"; else bad "Compose fehlt"; return 1; fi
  if $DOCKER info >/dev/null 2>&1; then ok "Engine erreichbar ($($DOCKER info --format '{{.OperatingSystem}}, {{.Architecture}}' 2>/dev/null))"; else bad "Engine nicht erreichbar"; return 1; fi
  if $DOCKER image inspect "$(envval SANDBOX_IMAGE coding-sandbox:local)" >/dev/null 2>&1; then ok "Image vorhanden"; else warn "Image noch nicht gebaut (passiert beim ersten Start)"; fi
  local certs; certs="$(ls certs/*.crt certs/*.pem 2>/dev/null | wc -l | tr -d ' ')"
  ok "Firmenzertifikate in certs/: $certs"
  [ -n "$(envval HTTPS_PROXY)" ] && ok "Proxy: $(envval HTTPS_PROXY)"

  info "Container"
  ensure_up
  local color=0; [ -t 1 ] && color=1
  $DOCKER exec -i -e SB_COLOR=$color "$NAME" bash -s <<'EOS'
if [ "$SB_COLOR" = 1 ]; then G=$'\e[32m'; Y=$'\e[33m'; R=$'\e[31m'; N=$'\e[0m'; else G=; Y=; R=; N=; fi
ok()   { printf '  %sOK%s    %s\n' "$G" "$N" "$*"; }
warn() { printf '  %sWARN%s  %s\n' "$Y" "$N" "$*"; }
bad()  { printf '  %sFEHLER%s %s\n' "$R" "$N" "$*"; }
ok "Nutzer $(id -un) ($(id -u):$(id -g)), node $(node --version)"
ok "codex $(codex --version 2>/dev/null | awk '{print $NF}'), opencode $(opencode --version 2>/dev/null)"
if [ -w /work ]; then ok "/work beschreibbar"
else bad "/work nicht beschreibbar: Workspace gehoert UID $(stat -c %u /work), Container-Nutzer hat $(id -u). Abhilfe: ./sandbox.sh rebuild"; fi
probe() { # name url
  local code; code="$(curl -sS -o /dev/null -m 15 -w '%{http_code}' "$2" 2>/tmp/probe.err)"
  if [ "$code" != "000" ]; then ok "Netz: $1 erreichbar (HTTP $code)"
  else bad "Netz: $1 nicht erreichbar - $(head -c 160 /tmp/probe.err)"; fi
}
probe "chatgpt.com (Codex)" https://chatgpt.com/
probe "AIE-Plugins" https://plugins.dev.aie.ai.t-systems.net/.well-known/opencode
probe "LLM Hub" https://llm-server.llmhub.t-systems.net/
if codex login status >/dev/null 2>&1; then ok "Codex: $(codex login status 2>&1 | head -n1)"
else warn "Codex nicht angemeldet -> ./sandbox.sh login codex"; fi
if grep -qs "plugins.dev.aie.ai.t-systems.net" ~/.local/share/opencode/auth.json; then ok "opencode: AIE-Konfiguration eingerichtet"
else warn "opencode: AIE-Konfiguration fehlt -> ./sandbox.sh login opencode"; fi
n="$(opencode auth list 2>/dev/null | grep -ciE 'api|oauth' || true)"
[ "${n:-0}" -gt 0 ] && ok "opencode: Zugangsdaten hinterlegt" || warn "opencode: noch keine Provider-Keys -> im TUI /connect"
EOS
}

cmd_rebuild() { need_engine; compose build "$@" && compose up -d --force-recreate && info "Neu gebaut und gestartet."; }

cmd_update() {
  need_engine
  info "Hole Basis-Image und neueste Agentenversionen ..."
  CACHE_BUST="$(date +%s)"; export CACHE_BUST
  compose build --pull && compose up -d --force-recreate && cmd_status
}

cmd_reseed() {
  ensure_up
  $DOCKER exec -e SEED_OVERWRITE=1 "$NAME" sh -c 'cp /opt/seed/codex/config.toml ~/.codex/config.toml && echo "config.toml neu eingespielt"'
}

cmd_destroy() {
  need_engine
  printf 'Container und alle Volumes (Anmeldungen, Einstellungen) von "%s" loeschen? [j/N] ' "$NAME"
  local a; read -r a
  case "$a" in j|J|y|Y) compose down -v --remove-orphans ;; *) echo "Abgebrochen." ;; esac
}

# ---------------------------------------------------------------- Verteiler
sub="${1:-}"; [ $# -gt 0 ] && shift
case "$sub" in
  "")
    case "$DEFAULT_ENTRY" in
      codex) cmd_codex ;; opencode) cmd_opencode ;; *) cmd_shell ;;
    esac ;;
  shell|sh|bash)   cmd_shell ;;
  codex)           cmd_codex "$@" ;;
  opencode|oc)     cmd_opencode "$@" ;;
  run|exec)        cmd_run "$@" ;;
  login|auth)      cmd_login "$@" ;;
  import-codex-auth) cmd_import_codex_auth "$@" ;;
  up|start)        ensure_up && info "Sandbox laeuft." ;;
  stop)            need_engine; compose stop ;;
  restart)         need_engine; compose restart && ensure_up ;;
  status|ps)       cmd_status ;;
  logs)            need_engine; compose logs --tail=100 "$@" ;;
  doctor|check)    cmd_doctor ;;
  rebuild|build)   cmd_rebuild "$@" ;;
  update)          cmd_update ;;
  reseed)          cmd_reseed ;;
  destroy)         cmd_destroy ;;
  help|-h|--help)  cmd_help ;;
  *)               die "Unbekannter Befehl '$sub'. ./sandbox.sh help" ;;
esac
