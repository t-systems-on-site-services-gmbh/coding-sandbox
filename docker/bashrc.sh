# shellcheck shell=bash
# Prompt und Begruessung in der Sandbox (nur interaktive Shells)
umask 022
case $- in *i*) ;; *) return 0 2>/dev/null || exit 0 ;; esac
PS1='\[\e[1;36m\][sandbox]\[\e[0m\] \[\e[1;34m\]\w\[\e[0m\] \$ '
[ -n "${SANDBOX_GREETED:-}" ] && return 0
export SANDBOX_GREETED=1

printf '\n  Coding-Sandbox   Projekte unter /work (= WORKSPACE_DIR auf dem Host)\n'
if command -v codex >/dev/null 2>&1; then
  if codex login status >/dev/null 2>&1; then _sb_cl="angemeldet"; else _sb_cl="nicht angemeldet -> ./sandbox.sh login codex"; fi
  printf '  codex    %-12s %s\n' "$(codex --version 2>/dev/null | awk '{print $NF}')" "$_sb_cl"
  unset _sb_cl
fi
if command -v opencode >/dev/null 2>&1; then
  printf '  opencode %-12s %s\n' "$(opencode --version 2>/dev/null | head -n1)" "Provider-Keys im TUI per /connect, Modell per /models"
fi
printf '\n'
