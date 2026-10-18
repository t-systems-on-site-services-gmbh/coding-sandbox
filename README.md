# Coding-Sandbox: Codex und opencode im Container

Ein abgeschotteter Docker-Container für KI-gestütztes Programmieren. Darin
laufen zwei Coding-Agenten:

* **Codex** (OpenAI), angemeldet mit dem eigenen ChatGPT-Abo
* **opencode** in der AIE-Variante (`@aie/opencode`), vorkonfiguriert für
  AI Foundation Services / LLM Hub; API-Keys trägt man selbst im TUI ein

Der Quellcode bleibt auf dem eigenen Rechner. Der Container sieht nur den
Projektordner, nicht das restliche Home-Verzeichnis, keine SSH-Keys und keine
Zugangsdaten des Hosts.

Unterstützt: **macOS** (Apple Silicon und Intel) und **Windows über WSL2**.
Natives Linux funktioniert genauso wie WSL2.

---

## Inhalt

1. [Voraussetzungen](#voraussetzungen)
2. [Schnellstart](#schnellstart)
3. [Codex anmelden](#codex-anmelden)
4. [opencode einrichten](#opencode-einrichten)
5. [Täglicher Gebrauch](#täglicher-gebrauch)
6. [Firmenproxy und Zertifikate](#firmenproxy-und-zertifikate)
7. [Projekte und Dateien](#projekte-und-dateien)
8. [Aktualisieren](#aktualisieren)
9. [Was isoliert ist und was nicht](#was-isoliert-ist-und-was-nicht)
10. [Fehlersuche](#fehlersuche)
11. [Aufbau des Repos](#aufbau-des-repos)

---

## Voraussetzungen

Gebraucht wird eine Docker-Engine mit `docker compose`, sonst nichts. Node,
Codex und opencode müssen auf dem Rechner **nicht** installiert sein.

### macOS

Eine der folgenden Varianten:

| Variante | Hinweis |
|---|---|
| Docker Desktop | Lizenzpflichtig für größere Unternehmen – prüfen, ob eine Firmenlizenz besteht |
| [Colima](https://github.com/abiosoft/colima) | Frei: `brew install colima docker docker-compose && colima start --cpu 4 --memory 8` |
| Rancher Desktop | Frei, Einstellung „dockerd (moby)“ wählen |

Unter Colima nach der Installation einmal `docker compose version` prüfen.
Fehlt das Plugin: `mkdir -p ~/.docker/cli-plugins && ln -sfn "$(brew --prefix)/opt/docker-compose/bin/docker-compose" ~/.docker/cli-plugins/docker-compose`.

### Windows (WSL2)

1. WSL2 mit Ubuntu einrichten (PowerShell als Admin): `wsl --install -d Ubuntu`
2. Docker bereitstellen, **eine** der beiden Varianten:
   * **Docker Desktop** mit aktivierter WSL-Integration für die Ubuntu-Distribution
     (*Settings → Resources → WSL integration*), oder
   * **Docker Engine direkt in WSL2** (ohne Docker Desktop, keine Lizenzfrage):
     ```bash
     curl -fsSL https://get.docker.com | sh
     sudo usermod -aG docker "$USER"     # danach WSL neu starten: wsl --shutdown
     ```
     Läuft systemd in WSL nicht, die Engine mit `sudo service docker start` starten.
3. **Alles Weitere in der WSL-Shell.** Das Repo gehört ins Linux-Dateisystem
   (`~/…`), nicht nach `/mnt/c/…` – dort ist es langsam und Dateirechte gehen
   kaputt.

PowerShell- oder `cmd`-Skripte gibt es bewusst nicht: unter Windows ist WSL2
der Weg.

---

## Schnellstart

```bash
git clone <repo-url> ~/coding-sandbox
cd ~/coding-sandbox
./sandbox.sh doctor        # prüft Docker, Netz, Proxy – legt beim ersten Mal .env an
./sandbox.sh               # baut das Image (einige Minuten) und öffnet eine Shell
```

Hinter dem Firmenproxy vorher [Firmenproxy und Zertifikate](#firmenproxy-und-zertifikate)
erledigen, sonst scheitert schon der Build.

Beim ersten Start passiert automatisch:

* Codex bekommt die Vorlage `config/codex/config.toml`.
* opencode holt die AIE-Konfiguration – das entspricht
  `opencode auth login https://plugins.dev.aie.ai.t-systems.net`.
  Die AIE-Registry (`npm config set @aie:registry …`) ist bereits im Image
  hinterlegt.
* Git-Name und -E-Mail werden vom Host übernommen (oder aus der `.env`).

Danach fehlen nur noch die persönlichen Anmeldungen, siehe die nächsten beiden
Abschnitte.

---

## Codex anmelden

Einmalig, die Anmeldung bleibt im Volume `codex-home` erhalten:

```bash
./sandbox.sh login codex
```

Es erscheint ein Link zu `auth.openai.com`. Diesen **im Browser auf dem
eigenen Rechner** öffnen (unter WSL2: im Windows-Browser) und mit dem
ChatGPT-Konto anmelden. Der Browser leitet danach auf `localhost:1455` zurück;
das Skript reicht diese Rückleitung in den Container durch.

**Alternative ohne Rückleitung** (falls der Browser „Seite nicht erreichbar“
meldet):

```bash
./sandbox.sh login codex --device
```

Dafür muss in ChatGPT unter *Einstellungen → Sicherheit* die
Gerätecode-Anmeldung erlaubt sein; bei Workspace-Konten aktiviert das ein
Admin.

**Bereits auf dem Host angemeldet?** Dann lässt sich die vorhandene Datei
übernehmen:

```bash
./sandbox.sh import-codex-auth            # nimmt ~/.codex/auth.json
```

Starten:

```bash
./sandbox.sh codex          # oder in der Sandbox-Shell: codex
```

Prüfen: `codex login status`.

### Codex-Voreinstellungen

`config/codex/config.toml` wird beim ersten Start nach `~/.codex/config.toml`
im Container kopiert und gehört danach dem Nutzer. Die wichtigsten Punkte:

* `sandbox_mode = "danger-full-access"` – klingt drastisch, gilt aber nur
  **innerhalb** des Containers. Codex' eigene Linux-Sandbox (Landlock/seccomp)
  läuft in unprivilegierten Containern nicht zuverlässig; die Isolation
  übernimmt hier der Container.
* `approval_policy = "on-request"` – das Modell fragt, wenn es es für nötig
  hält. Wer jeden Befehl bestätigen will, stellt im TUI per `/approvals` auf
  strenger.
* `forced_login_method = "chatgpt"` – Anmeldung über das Abo, nicht per API-Key.

Vorlage nach Änderungen neu einspielen (überschreibt eigene Anpassungen):
`./sandbox.sh reseed`.

---

## opencode einrichten

Die AIE-Konfiguration (Provider, Modelle, Voreinstellungen) ist nach dem
ersten Start schon da. Es fehlt nur der eigene API-Key:

```bash
./sandbox.sh opencode       # oder in der Sandbox-Shell: opencode
```

Im TUI:

1. `/connect` eingeben
2. Provider wählen, z. B. **AI Foundation Services**
3. API-Key einfügen
4. Modell mit `/models` wählen

Die Keys liegen danach im Volume `opencode-data` und überstehen Neustarts und
Rebuilds. Weitere Provider (auch eigene, etwa ein OpenAI-kompatibler Endpunkt)
lassen sich jederzeit auf demselben Weg ergänzen.

Hat das automatische Holen der AIE-Konfiguration beim Start nicht geklappt
(zum Beispiel weil der Proxy noch fehlte):

```bash
./sandbox.sh login opencode
```

Prüfen: `opencode auth list` und `opencode models`.

---

## Täglicher Gebrauch

```bash
./sandbox.sh                   # hineinspringen (Shell, siehe DEFAULT_ENTRY)
./sandbox.sh codex             # direkt Codex
./sandbox.sh opencode          # direkt opencode
./sandbox.sh run npm test      # einzelner Befehl im Container
./sandbox.sh status            # läuft er? welche Versionen?
./sandbox.sh doctor            # Selbsttest
./sandbox.sh stop              # anhalten (Anmeldungen bleiben)
./sandbox.sh help              # alle Befehle
```

Ruft man `./sandbox.sh` aus einem Unterordner des Workspaces auf, landet man
im passenden Ordner unter `/work`:

```bash
cd ~/coding-sandbox/workspace/mein-projekt
../../sandbox.sh codex         # startet in /work/mein-projekt
```

Tipp: ein Alias in `~/.zshrc` bzw. `~/.bashrc` spart Tipparbeit:
`alias sbx="$HOME/coding-sandbox/sandbox.sh"`.

Der Container läuft im Hintergrund weiter und startet nach einem Neustart von
Docker automatisch. Mehrere Shells gleichzeitig sind kein Problem.

---

## Firmenproxy und Zertifikate

### Proxy

In der `.env` eintragen – gilt für den Build (apt, npm) und zur Laufzeit
(Codex, opencode, git, curl):

```
HTTP_PROXY=http://proxy.example.com:8080
HTTPS_PROXY=http://proxy.example.com:8080
NO_PROXY=localhost,127.0.0.1,.intern.example.com
```

Läuft auf dem Rechner ein lokaler Proxy-Helfer (px, cntlm o. Ä.) auf
`127.0.0.1:3128`, im Container stattdessen
`http://host.docker.internal:3128` verwenden. Der Helfer muss dann auch auf
Verbindungen aus dem Docker-Netz hören.

Docker Desktop holt das Basis-Image selbst; dafür den Proxy zusätzlich unter
*Settings → Resources → Proxies* eintragen. Bei der Docker Engine unter WSL2
gehört er in die Daemon-Konfiguration
(`/etc/systemd/system/docker.service.d/http-proxy.conf`).

### Zertifikate (TLS-Inspektion)

Bricht der Proxy TLS auf, braucht der Container das Firmen-Stammzertifikat.
Die PEM-Dateien (`*.crt` oder `*.pem`) nach `certs/` legen, danach
`./sandbox.sh rebuild`. Sie gelten dann für apt, npm, Codex, opencode, git,
curl und Python. Dateien in `certs/` werden nicht eingecheckt.

Export unter **macOS** (alle Stammzertifikate des System-Schlüsselbunds):

```bash
security find-certificate -a -p /Library/Keychains/System.keychain > certs/macos-system.pem
```

Export unter **Windows** (aus WSL heraus, Name des Zertifikats anpassen):

```bash
powershell.exe -NoProfile -Command \
  "Get-ChildItem Cert:\LocalMachine\Root | Where-Object Subject -like '*Firmenname*' |
   ForEach-Object { '-----BEGIN CERTIFICATE-----'; [Convert]::ToBase64String(\$_.RawData, 'InsertLineBreaks'); '-----END CERTIFICATE-----' }" \
  | tr -d '\r' > certs/firma-root.crt
```

Ob es klappt, zeigt `./sandbox.sh doctor` (Abschnitt „Netz“).

---

## Projekte und Dateien

Standardmäßig ist `./workspace` im Repo der Projektordner; im Container heißt
er `/work`. Woanders liegende Projekte in der `.env` eintragen:

```
WORKSPACE_DIR=~/projekte
```

Danach `./sandbox.sh restart`. Nur dieser Ordner ist für den Container
sichtbar.

Repositories klont man am einfachsten in der Sandbox-Shell. Für GitHub ist
`gh` installiert (`gh auth login`, Zustand bleibt im Volume `gh-config`).
SSH-Keys sind bewusst nicht eingehängt; wer sie braucht, nimmt in
`compose.local.yaml` (siehe unten) einen nur lesenden Mount auf.

Persönliche Ergänzungen an `compose.yaml` – zusätzliche Mounts, Ports für
Dev-Server – gehören in eine eigene `compose.local.yaml` (nicht im Git), die
`sandbox.sh` automatisch mitlädt:

```yaml
services:
  sandbox:
    ports:
      - "127.0.0.1:5173:5173"
    volumes:
      - ${HOME}/.ssh:/home/dev/.ssh:ro
```

### Wo was liegt

| Was | Wo | Überlebt `rebuild`? | Überlebt `destroy`? |
|---|---|---|---|
| Quellcode | Host, `WORKSPACE_DIR` | ja | ja |
| Codex-Anmeldung und -Einstellungen | Volume `codex-home` | ja | nein |
| opencode-Keys und Sitzungen | Volumes `opencode-data`, `opencode-state`, `opencode-config` | ja | nein |
| gh-Anmeldung | Volume `gh-config` | ja | nein |
| selbst installierte npm-Tools | Volume `npm-global` | ja | nein |

---

## Aktualisieren

```bash
git pull                   # neue Version dieses Repos
./sandbox.sh update        # neuestes Basis-Image, Codex und @aie/opencode
```

Feste Versionen lassen sich in der `.env` vorgeben, etwa
`CODEX_VERSION=0.163.0` und `AIE_OPENCODE_VERSION=1.18.30-aie`, danach
`./sandbox.sh rebuild`. Die Selbstaktualisierung von opencode ist im Container
abgeschaltet, damit alle denselben Stand haben.

---

## Was isoliert ist und was nicht

Isoliert:

* Der Container sieht nur `WORKSPACE_DIR` (und die Vorlagen unter `config/`,
  nur lesend). Home-Verzeichnis, SSH-Keys und Schlüsselbund des Hosts sind
  nicht erreichbar.
* Er läuft als unprivilegierter Nutzer `dev`, `sudo` ist abgeschaltet
  (`ENABLE_SUDO=true` in der `.env` schaltet es ein – betrifft nur den
  Container).
* Kein Docker-Socket: aus der Sandbox lassen sich keine Container auf dem Host
  starten.
* CPU-, Speicher- und Prozessgrenzen (`SANDBOX_CPUS`, `SANDBOX_MEMORY`).
* Der einzige veröffentlichte Port ist `127.0.0.1:1455` für die
  Codex-Anmeldung, nur lokal erreichbar.

Nicht isoliert:

* **Ausgehendes Netz ist offen.** Die Agenten brauchen es für ihre Modelle, und
  Paketinstallationen sollen funktionieren. Ein Agent kann also grundsätzlich
  alles erreichen, was der Rechner erreicht – auch interne Dienste im
  Firmennetz.
* **Alles im Workspace ist les- und schreibbar** für die Agenten. Mit Git
  arbeiten und Änderungen vor dem Commit ansehen.
* Anmeldetoken liegen im Container (in Volumes). Ein Agent im Container kann
  sie lesen. Deshalb gehören keine produktiven Geheimnisse (Kunden-Zugangsdaten,
  Produktions-Keys) in den Workspace oder die `.env`.

Für Experimente mit fremdem oder nicht vertrauenswürdigem Code reicht das
nicht – dafür braucht es zusätzlich einen Netzfilter.

---

## Fehlersuche

Immer zuerst: `./sandbox.sh doctor`.

| Symptom | Ursache und Abhilfe |
|---|---|
| `Docker laeuft nicht` | Docker Desktop/Colima starten; WSL2 mit Engine: `sudo service docker start` |
| Build bricht bei `apt-get update` oder `npm install` ab | Proxy in `.env` fehlt, oder Firmenzertifikat fehlt in `certs/` |
| `certificate verify failed`, `self-signed certificate in chain` | Firmenzertifikat nach `certs/`, dann `./sandbox.sh rebuild` |
| `/work nicht beschreibbar` | Image mit anderer UID gebaut: `./sandbox.sh rebuild` |
| Codex-Login: Browser zeigt „Seite nicht erreichbar“ | Port 1455 auf dem Host belegt oder durch Sicherheitssoftware blockiert: `./sandbox.sh login codex --device` |
| opencode zeigt keine AIE-Modelle | `./sandbox.sh login opencode`, danach `opencode models` |
| `exec format error` beim Start | Zeilenenden: Dateien wurden mit CRLF ausgecheckt. Repo in WSL (nicht unter Windows) klonen |
| Alles sehr langsam unter WSL2 | Repo bzw. `WORKSPACE_DIR` liegt unter `/mnt/c/…` – nach `~/…` verschieben |

Kompletter Neuanfang (löscht Anmeldungen und Einstellungen, nicht den Code):

```bash
./sandbox.sh destroy && ./sandbox.sh
```

---

## Aufbau des Repos

```
coding-sandbox/
├── sandbox.sh               Start- und Steuerskript (macOS, Linux, WSL2)
├── compose.yaml             Dienst, Mounts, Volumes, Grenzen
├── .env.example             Vorlage für die persönliche .env
├── docker/
│   ├── Dockerfile           Debian 13 + Node 24 + Codex + @aie/opencode
│   ├── entrypoint.sh        Startlogik: Vorlagen, Git, AIE-Konfiguration
│   └── bashrc.sh            Prompt und Begrüßung
├── config/codex/config.toml Vorlage für Codex
├── certs/                   Firmenzertifikate (nicht im Git)
└── workspace/               Standard-Projektordner (nicht im Git)
```

Mit eingebaut: git, GitHub CLI, Python 3, build-essential, ripgrep, fd, jq,
tmux. Zusätzliche Debian-Pakete über `EXTRA_APT_PACKAGES` in der `.env`.
