# syntax=docker/dockerfile:1
# Coding-Sandbox: Codex (ChatGPT-Abo) und AIE-opencode in einem Container.
# Build-Kontext ist das Repo-Wurzelverzeichnis (siehe compose.yaml).

ARG NODE_MAJOR=24
# Volles (nicht "slim") Image: bringt ca-certificates, curl und git schon mit.
# Damit kann apt von Anfang an ueber HTTPS laufen - manche Firmenproxys
# lassen kein reines HTTP durch.
FROM node:${NODE_MAJOR}-trixie

ARG TZ=Europe/Berlin
ARG USER_UID=1000
ARG USER_GID=1000
ARG ENABLE_SUDO=false
ARG INSTALL_GH=true
ARG EXTRA_APT_PACKAGES=""
ARG CODEX_VERSION=latest
ARG AIE_OPENCODE_VERSION=latest
ARG AIE_NPM_REGISTRY=https://plugins.dev.aie.ai.t-systems.net/v1/npm
# Wird von "./sandbox.sh update" gesetzt, damit npm frisch installiert
ARG CACHE_BUST=0

SHELL ["/bin/bash", "-o", "pipefail", "-c"]
ENV DEBIAN_FRONTEND=noninteractive \
    TZ=${TZ} \
    LANG=C.UTF-8

# ------------------------------------------------------------------ Firmen-CA
# Alles aus certs/ (*.crt, *.pem) landet zuerst im Systemspeicher, damit apt
# und npm auch hinter einem TLS-aufbrechenden Proxy funktionieren.
COPY certs/ /tmp/certs/
RUN set -eux; \
    mkdir -p /usr/local/share/ca-certificates/corp; \
    for f in /tmp/certs/*.crt /tmp/certs/*.pem; do \
      [ -f "$f" ] || continue; \
      cp "$f" "/usr/local/share/ca-certificates/corp/$(basename "${f%.*}").crt"; \
    done; \
    rm -rf /tmp/certs; \
    update-ca-certificates; \
    sed -i 's|http://deb.debian.org|https://deb.debian.org|g' /etc/apt/sources.list.d/*.sources; \
    apt-get update

# Ein Bundle fuer alle: Node/Bun (opencode), Codex, Python, curl, git
ENV SSL_CERT_FILE=/etc/ssl/certs/ca-certificates.crt \
    NODE_EXTRA_CA_CERTS=/etc/ssl/certs/ca-certificates.crt \
    REQUESTS_CA_BUNDLE=/etc/ssl/certs/ca-certificates.crt

# ------------------------------------------------------------------ Werkzeuge
RUN set -eux; \
    apt-get install -y --no-install-recommends \
      bash-completion build-essential curl fd-find file git jq less locales \
      nano openssh-client procps python3 python3-pip python3-venv ripgrep \
      socat sudo tmux tzdata unzip vim-tiny wget zip \
      ${EXTRA_APT_PACKAGES}; \
    ln -sf /usr/bin/fdfind /usr/local/bin/fd; \
    ln -snf "/usr/share/zoneinfo/${TZ}" /etc/localtime; echo "${TZ}" > /etc/timezone; \
    if [ "${INSTALL_GH}" = "true" ]; then \
      curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
        -o /usr/share/keyrings/githubcli-archive-keyring.gpg; \
      echo "deb [signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
        > /etc/apt/sources.list.d/github-cli.list; \
      apt-get update; apt-get install -y --no-install-recommends gh; \
    fi; \
    rm -rf /var/lib/apt/lists/*

# ------------------------------------------------------------------ Benutzer
# Das Node-Image bringt "node" mit UID 1000 mit; wir ersetzen ihn durch "dev"
# mit der UID/GID des Hosts, damit Dateien in /work dem Host-Nutzer gehoeren.
RUN set -eux; \
    userdel -r node 2>/dev/null || true; \
    groupdel node 2>/dev/null || true; \
    if getent group "${USER_GID}" >/dev/null; then \
      GROUP_NAME="$(getent group "${USER_GID}" | cut -d: -f1)"; \
    else \
      groupadd -g "${USER_GID}" dev; GROUP_NAME=dev; \
    fi; \
    useradd -m -u "${USER_UID}" -g "${GROUP_NAME}" -s /bin/bash dev; \
    if [ "${ENABLE_SUDO}" = "true" ]; then \
      echo "dev ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/dev; chmod 0440 /etc/sudoers.d/dev; \
    fi; \
    mkdir -p /work \
      /home/dev/.codex \
      /home/dev/.config/opencode /home/dev/.config/gh \
      /home/dev/.local/share/opencode /home/dev/.local/state/opencode \
      /home/dev/.cache /home/dev/.npm-global; \
    chown -R dev:"${GROUP_NAME}" /work /home/dev

# ------------------------------------------------------------------ Agenten
# Codex (OpenAI) und die AIE-Variante von opencode, global unter /usr/local.
RUN set -eux; \
    echo "cache-bust ${CACHE_BUST}"; \
    npm config set --location=global "@aie:registry" "${AIE_NPM_REGISTRY}"; \
    # auch als "builtin", damit es mit dem Nutzer-Prefix unten weiter gilt
    echo "@aie:registry=${AIE_NPM_REGISTRY}" >> "$(npm root -g)/npm/npmrc"; \
    npm install -g --no-fund --no-audit \
      "@openai/codex@${CODEX_VERSION}" \
      "@aie/opencode@${AIE_OPENCODE_VERSION}"; \
    # @aie/opencode zieht die Binaries aller 12 Plattformen (~2 GB), verlinkt
    # aber nur eines. Den Rest entfernen.
    oc="$(npm root -g)/@aie/opencode"; keep="$(readlink -f "$oc/bin/opencode")"; \
    for d in "$oc"/node_modules/@aie/opencode-*; do \
      case "$keep" in "$d"/*) ;; *) rm -rf "$d" ;; esac; \
    done; \
    npm cache clean --force; \
    codex --version; \
    opencode --version

COPY --chmod=0755 docker/entrypoint.sh /usr/local/bin/sandbox-entrypoint
COPY --chmod=0644 docker/bashrc.sh /etc/profile.d/zz-sandbox.sh
# Am Ende der Nutzer-.bashrc, damit Prompt und Begruessung nicht ueberschrieben werden
RUN echo '. /etc/profile.d/zz-sandbox.sh' >> /home/dev/.bashrc

USER dev
WORKDIR /work
ENV PATH=/home/dev/.npm-global/bin:/home/dev/.local/bin:${PATH} \
    NPM_CONFIG_PREFIX=/home/dev/.npm-global \
    EDITOR=nano

ENTRYPOINT ["/usr/local/bin/sandbox-entrypoint"]
CMD ["sleep", "infinity"]
