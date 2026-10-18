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
  if [ "${INSTALL_CODEX:-$(envval INSTALL_CODEX true)}" != "true" ] && [ "${INSTALL_OPENCODE:-$(envval INSTALL_OPENCODE true)}" != "true" ]; then
    die "INSTALL_CODEX und INSTALL_OPENCODE sind in der .env beide aus - mindestens eines auf true setzen."
  fi
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

# Ist ein Werkzeug im Image? Sonst mit Hinweis auf den Schalter abbrechen.
need_tool() { # need_tool codex|opencode
  $DOCKER exec "$NAME" sh -c "command -v $1" >/dev/null 2>&1 && return 0
  local sw=INSTALL_CODEX; [ "$1" = opencode ] && sw=INSTALL_OPENCODE
  die "$1 ist in diesem Image nicht installiert. In der .env $sw=true setzen, dann ./sandbox.sh rebuild."
}

# ---------------------------------------------------------------- Befehle
cmd_help() {
  cat <<EOF
${B}Coding-Sandbox${N} - Codex und/oder opencode (AIE) im Container

  ./sandbox.sh                 Sandbox starten und hineinspringen (DEFAULT_ENTRY=$DEFAULT_ENTRY)
  ./sandbox.sh shell           Shell im Container
  ./sandbox.sh codex [args]    Codex starten
  ./sandbox.sh opencode [args] opencode starten
  ./sandbox.sh run <befehl>    beliebigen Befehl im Container ausfuehren

  ./sandbox.sh login codex           Anmeldung mit ChatGPT-Abo (Browser auf dem Host)
  ./sandbox.sh login codex --device  Anmeldung per Geraetecode (ohne Rueckleitung)
  ./sandbox.sh login opencode        AIE-Konfiguration neu holen (opencode auth login)
  ./sandbox.sh import-codex-auth [datei]  vorhandene ~/.codex/auth.json uebernehmen

  ./sandbox.sh auto codex|opencode "Auftrag"  unbeaufsichtigter Lauf im Hintergrund
               Optionen: -f auftrag.md   -t 4h (Zeitgrenze)   -m modell
  ./sandbox.sh jobs            alle Laeufe mit Status
  ./sandbox.sh log [lauf]      Protokoll ansehen bzw. live verfolgen
  ./sandbox.sh attach [lauf]   in die laufende Sitzung schalten (Strg-b d)
  ./sandbox.sh kill-job <lauf> Lauf abbrechen

  ./sandbox.sh status | logs | stop | restart
  ./sandbox.sh doctor          Selbsttest: Docker, Image, Netz, Anmeldungen
  ./sandbox.sh rebuild         Image neu bauen (nach Aenderung an .env/certs)
  ./sandbox.sh update          neueste Codex/opencode-Versionen einbauen
  ./sandbox.sh reseed          Vorlagen aus config/ neu einspielen
  ./sandbox.sh destroy         Container UND Volumes loeschen (Anmeldungen weg)
EOF
}

cmd_shell()    { ensure_up; dexec bash -l; }
cmd_codex()    { ensure_up; need_tool codex; dexec codex "$@"; }
cmd_opencode() { ensure_up; need_tool opencode; dexec opencode "$@"; }
cmd_run() {
  [ "${1:-}" = "--" ] && shift
  [ $# -gt 0 ] || die "Aufruf: ./sandbox.sh run <befehl>"
  ensure_up; dexec "$@"
}

cmd_login() {
  local what="${1:-}"; shift || true
  case "$what" in
    codex)
      ensure_up; need_tool codex
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
      ensure_up; need_tool opencode
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
  ensure_up; need_tool codex
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
    dexec -T sh -c '
      command -v codex    >/dev/null && printf "codex     %s\n" "$(codex --version)"
      command -v opencode >/dev/null && printf "opencode  %s\n" "$(opencode --version)"
      true'
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
HAS_CODEX=0; command -v codex >/dev/null 2>&1 && HAS_CODEX=1
HAS_OC=0; command -v opencode >/dev/null 2>&1 && HAS_OC=1
[ $HAS_CODEX = 1 ] && ok "codex $(codex --version 2>/dev/null | awk '{print $NF}')" || ok "codex nicht installiert (INSTALL_CODEX=false)"
[ $HAS_OC = 1 ] && ok "opencode $(opencode --version 2>/dev/null)" || ok "opencode nicht installiert (INSTALL_OPENCODE=false)"
if [ -w /work ]; then ok "/work beschreibbar"
else bad "/work nicht beschreibbar: Workspace gehoert UID $(stat -c %u /work), Container-Nutzer hat $(id -u). Abhilfe: ./sandbox.sh rebuild"; fi
probe() { # name url
  local code; code="$(curl -sS -o /dev/null -m 15 -w '%{http_code}' "$2" 2>/tmp/probe.err)"
  if [ "$code" != "000" ]; then ok "Netz: $1 erreichbar (HTTP $code)"
  else bad "Netz: $1 nicht erreichbar - $(head -c 160 /tmp/probe.err)"; fi
}
if [ $HAS_CODEX = 1 ]; then
  probe "chatgpt.com (Codex)" https://chatgpt.com/
  if codex login status >/dev/null 2>&1; then ok "Codex: $(codex login status 2>&1 | head -n1)"
  else warn "Codex nicht angemeldet -> ./sandbox.sh login codex"; fi
fi
if [ $HAS_OC = 1 ]; then
  probe "AIE-Plugins" https://plugins.dev.aie.ai.t-systems.net/.well-known/opencode
  probe "LLM Hub" https://llm-server.llmhub.t-systems.net/
  if grep -qs "plugins.dev.aie.ai.t-systems.net" ~/.local/share/opencode/auth.json; then ok "opencode: AIE-Konfiguration eingerichtet"
  else warn "opencode: AIE-Konfiguration fehlt -> ./sandbox.sh login opencode"; fi
  n="$(opencode auth list 2>/dev/null | grep -ciE 'api|oauth' || true)"
  [ "${n:-0}" -gt 0 ] && ok "opencode: Zugangsdaten hinterlegt" || warn "opencode: noch keine Provider-Keys -> im TUI /connect"
fi
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
  $DOCKER exec "$NAME" sh -c '
    copy() { [ -f "$1" ] || return 0; mkdir -p "$(dirname "$2")"; cp "$1" "$2" && echo "neu eingespielt: $2"; }
    if command -v codex >/dev/null; then
      copy /opt/seed/codex/config.toml      ~/.codex/config.toml
      copy /opt/seed/codex/auto.config.toml ~/.codex/auto.config.toml
      copy /opt/seed/codex/AGENTS.md        ~/.codex/AGENTS.md
    fi
    command -v opencode >/dev/null && copy /opt/seed/opencode/opencode.json ~/.config/opencode/opencode.json
    true'
}

# ---------------------------------------------------------------- Autonome Laeufe
# Ein Lauf = eine tmux-Sitzung im Container. Auftrag, Protokoll und Ergebnis
# liegen unter /work/.sandbox-logs/ (also auch auf dem Host im Workspace).
LOGDIR=/work/.sandbox-logs

cmd_auto() {
  local tool="${1:-}"; shift || true
  case "$tool" in codex|opencode) ;; *) die "Aufruf: ./sandbox.sh auto codex|opencode [optionen] \"Auftrag\"  (siehe ./sandbox.sh help)" ;; esac
  local file="" tmo model="" prompt
  tmo="$(envval AUTO_TIMEOUT)"
  while [ $# -gt 0 ]; do
    case "$1" in
      -f|--file)    [ $# -ge 2 ] || die "-f braucht eine Datei";      file="$2";  shift 2 ;;
      -t|--timeout) [ $# -ge 2 ] || die "-t braucht eine Dauer (z. B. 4h)"; tmo="$2"; shift 2 ;;
      -m|--model)   [ $# -ge 2 ] || die "-m braucht einen Modellnamen"; model="$2"; shift 2 ;;
      --) shift; break ;;
      -*) die "Unbekannte Option $1" ;;
      *) break ;;
    esac
  done
  if [ -n "$file" ]; then
    case "$file" in /*) ;; *) file="$CALLER_PWD/$file" ;; esac
    [ -f "$file" ] || die "Auftragsdatei $file nicht gefunden."
    prompt="$(cat "$file")"
  else
    prompt="$*"
  fi
  [ -n "$prompt" ] || die "Kein Auftrag angegeben (Text oder -f datei)."
  case "$tmo" in ""|[0-9]*) ;; *) die "Ungueltige Zeitgrenze '$tmo' (z. B. 90m oder 4h)" ;; esac
  case "$model" in *[!A-Za-z0-9._/:-]*) die "Ungueltiger Modellname '$model'" ;; esac

  ensure_up; need_tool "$tool"
  local wd id; wd="$(container_wd)"
  id="$(date +%Y%m%d-%H%M%S)-$tool"

  if [ "$tool" = codex ]; then
    $DOCKER exec "$NAME" test -f /home/dev/.codex/auto.config.toml \
      || die "Profil ~/.codex/auto.config.toml fehlt im Container. Abhilfe: ./sandbox.sh reseed"
    $DOCKER exec "$NAME" codex login status >/dev/null 2>&1 \
      || die "Codex ist nicht angemeldet: ./sandbox.sh login codex"
  fi

  local extra=""
  if ! $DOCKER exec -w "$wd" "$NAME" git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    warn "$wd ist kein Git-Repository - Aenderungen lassen sich dann nicht einfach zuruecknehmen."
    [ "$tool" = codex ] && extra="--skip-git-repo-check"
  fi

  # Auftrag als Datei in den Container: kein Quoting-Aerger mit Sonderzeichen
  printf '%s\n' "$prompt" | $DOCKER exec -i "$NAME" sh -c "mkdir -p $LOGDIR && cat > $LOGDIR/$id.prompt.md" \
    || die "Konnte den Auftrag nicht ablegen."

  local run
  if [ "$tool" = codex ]; then
    run="codex exec -p auto $extra ${model:+-m $model} -o $LOGDIR/$id.result.md - < $LOGDIR/$id.prompt.md"
  else
    run="opencode run --auto ${model:+-m $model} --title $id \"\$(cat $LOGDIR/$id.prompt.md)\""
  fi
  [ -n "$tmo" ] && run="timeout --signal=INT --kill-after=60 $tmo $run"

  $DOCKER exec -i "$NAME" sh -c "cat > $LOGDIR/$id.run.sh" <<EOS
#!/usr/bin/env bash
cd "$wd" || exit 1
log=$LOGDIR/$id.log
echo "== Start \$(date '+%F %T') | $tool | $wd | Zeitgrenze: ${tmo:-keine} ==" | tee -a "\$log"
set -o pipefail
$run 2>&1 | tee -a "\$log"
rc=\$?
echo "\$rc" > $LOGDIR/$id.exit
echo "== Ende \$(date '+%F %T') | Exit-Code \$rc ==" | tee -a "\$log"
echo; echo "Lauf beendet. Enter schliesst dieses Fenster, das Protokoll bleibt erhalten."
read -r _ || sleep infinity
EOS
  $DOCKER exec "$NAME" tmux new-session -d -s "$id" -c "$wd" "bash $LOGDIR/$id.run.sh" \
    || die "Konnte die tmux-Sitzung nicht starten."

  info "Lauf ${B}$id${N} gestartet ($tool in $wd)."
  cat <<EOF
  Zuschauen:   ./sandbox.sh log $id      (Strg-C beendet nur das Zuschauen)
  Eingreifen:  ./sandbox.sh attach $id   (abkoppeln: Strg-b, dann d)
  Uebersicht:  ./sandbox.sh jobs
  Abbrechen:   ./sandbox.sh kill-job $id
  Dateien:     Workspace/.sandbox-logs/$id.*
EOF
}

cmd_jobs() {
  ensure_up
  $DOCKER exec -e LOGDIR="$LOGDIR" "$NAME" bash -c '
    ls "$LOGDIR"/*.prompt.md >/dev/null 2>&1 || { echo "Noch keine Laeufe."; exit 0; }
    printf "%-26s %-13s %s\n" LAUF STATUS AUFTRAG
    for p in $(ls -1 "$LOGDIR"/*.prompt.md | sort); do
      id="$(basename "$p" .prompt.md)"
      if [ -f "$LOGDIR/$id.exit" ]; then st="fertig ($(cat "$LOGDIR/$id.exit"))"
      elif tmux has-session -t "=$id" 2>/dev/null; then st="laeuft"
      else st="abgebrochen"; fi
      printf "%-26s %-13s %s\n" "$id" "$st" "$(head -n1 "$p" | cut -c1-60)"
    done'
}

# Ohne Angabe: neuester laufender Lauf, sonst der neueste ueberhaupt
pick_job() {
  if [ -n "${1:-}" ]; then echo "$1"; return; fi
  local id
  id="$($DOCKER exec "$NAME" sh -c "tmux ls -F '#{session_name}' 2>/dev/null | grep -E '^[0-9]{8}-[0-9]{6}-' | sort | tail -n1")"
  if [ -z "$id" ]; then
    id="$($DOCKER exec -e LOGDIR="$LOGDIR" "$NAME" sh -c 'ls -1 "$LOGDIR"/*.prompt.md 2>/dev/null | sort | tail -n1')"
    id="$(basename "${id:-x}" .prompt.md)"; [ "$id" = x ] && id=""
  fi
  [ -n "$id" ] || die "Kein Lauf gefunden. ./sandbox.sh jobs"
  echo "$id"
}

cmd_attach() {
  ensure_up; local id; id="$(pick_job "${1:-}")" || exit 1
  $DOCKER exec "$NAME" tmux has-session -t "=$id" 2>/dev/null \
    || die "Lauf $id hat keine offene Sitzung mehr. Protokoll: ./sandbox.sh log $id"
  info "Verbinde mit $id - abkoppeln mit Strg-b, dann d."
  $DOCKER exec -it "$NAME" tmux attach -t "=$id"
}

cmd_log() {
  ensure_up; local id; id="$(pick_job "${1:-}")" || exit 1
  $DOCKER exec "$NAME" test -f "$LOGDIR/$id.log" || die "Kein Protokoll fuer $id."
  if $DOCKER exec "$NAME" test -f "$LOGDIR/$id.exit"; then
    $DOCKER exec "$NAME" cat "$LOGDIR/$id.log"
  else
    info "Protokoll von $id (Strg-C beendet das Zuschauen, nicht den Lauf)"
    local tty="-i"; [ -t 0 ] && [ -t 1 ] && tty="-it"
    $DOCKER exec $tty "$NAME" tail -n 80 -f "$LOGDIR/$id.log"
  fi
}

cmd_kill_job() {
  ensure_up; [ -n "${1:-}" ] || die "Aufruf: ./sandbox.sh kill-job <lauf>  (siehe ./sandbox.sh jobs)"
  $DOCKER exec "$NAME" tmux kill-session -t "=$1" && info "Lauf $1 abgebrochen."
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
  auto)            cmd_auto "$@" ;;
  jobs)            cmd_jobs ;;
  attach)          cmd_attach "$@" ;;
  log)             cmd_log "$@" ;;
  kill-job)        cmd_kill_job "$@" ;;
  destroy)         cmd_destroy ;;
  help|-h|--help)  cmd_help ;;
  *)               die "Unbekannter Befehl '$sub'. ./sandbox.sh help" ;;
esac
