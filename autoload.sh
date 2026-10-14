# ============================================================================
# termkit autoload -- sourced from your shell rc (init.sh adds the line).
# Puts bin/ on PATH and sources every enabled module from lib/.
# ============================================================================
# bash 4+ only; quietly do nothing anywhere else so a shared rc never breaks
[ -n "${BASH_VERSION:-}" ] || return 0 2>/dev/null
[ "${BASH_VERSINFO[0]}" -ge 4 ] || return 0

TK_HOME="${TK_HOME:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"
: "${TK_CONFIG:=${XDG_CONFIG_HOME:-$HOME/.config}/termkit}"
export TK_HOME TK_CONFIG

# personal settings (SEARCH_PEER, REMOTE_DEFAULT, ...) written by init.sh
[ -f "$TK_CONFIG/env" ] && . "$TK_CONFIG/env"

case ":$PATH:" in *":$TK_HOME/bin:"*) ;; *) export PATH="$TK_HOME/bin:$PATH" ;; esac

if [ -f "$TK_CONFIG/modules" ]; then
  while IFS= read -r _tk_m; do
    [ -n "$_tk_m" ] && [ -f "$TK_HOME/lib/$_tk_m.sh" ] && . "$TK_HOME/lib/$_tk_m.sh"
  done < "$TK_CONFIG/modules"
  unset _tk_m
fi
