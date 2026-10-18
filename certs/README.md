# Firmen-Stammzertifikate

Hinter einem TLS-aufbrechenden Firmenproxy hier die Stamm- bzw.
Zwischenzertifikate als PEM ablegen (`*.crt` oder `*.pem`), danach:

    ./sandbox.sh rebuild

Sie werden ins Image übernommen und gelten für apt, npm, Codex, opencode,
git, curl und Python. Die Dateien selbst landen nicht im Git (siehe
`.gitignore`). Wie man sie exportiert, steht im README unter
„Firmenproxy und Zertifikate“.
