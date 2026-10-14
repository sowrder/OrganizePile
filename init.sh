#!/usr/bin/env bash
# ============================================================================
# termkit init -- set the toolkit up after unzipping or cloning it
# ============================================================================
#   bash init.sh                  choose what to set up, with prompts
#   bash init.sh --all            set up everything, no prompts
#   bash init.sh search remote    set up the named modules, with prompts
#   bash init.sh --status         what is enabled and what is installed
#   bash init.sh --remove NAME..  disable modules
#   bash init.sh --uninstall      disable everything and remove the rc line
#
# Leave this folder where it is afterwards: your shell rc points at it.
# Run it again any time to add modules; it never duplicates anything.
# ============================================================================
set -u

if [ -z "${BASH_VERSION:-}" ] || [ "${BASH_VERSINFO[0]:-0}" -lt 4 ]; then
  echo "termkit needs bash 4 or newer (this is ${BASH_VERSION:-not bash})."
  echo "On macOS: brew install bash, then run: /opt/homebrew/bin/bash init.sh"
  exit 1
fi

TK_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TK_CONFIG="${TK_CONFIG:-${XDG_CONFIG_HOME:-$HOME/.config}/termkit}"
MARK_BEGIN="# >>> termkit >>>"
MARK_END="# <<< termkit <<<"

# ---- modules ---------------------------------------------------------------
MODULES=(search remote run wrap)
declare -A DESC=(
  [search]="find files locally, on rclone remotes or ssh peers; copy, move, upload"
  [remote]="named ssh hosts: register once, connect by name or number"
  [run]="open files from the terminal; arrow through images"
  [wrap]="paste Python into the terminal, clean paste artifacts, run it"
)
declare -A NEEDS=(  [search]="python3"            [remote]="ssh" [run]=""      [wrap]="python3" )
declare -A OPTION=( [search]="rclone rsync ssh"  [remote]=""    [run]="feh"   [wrap]="" )

say()  { printf '%s\n' "$*"; }
ok()   { printf '  [ok]   %s\n' "$*"; }
warn() { printf '  [warn] %s\n' "$*"; }
ask()  { local a; read -rp "$1 " a; printf '%s' "$a"; }
yes()  { local a; a="$(ask "$1 [y/N]")"; [[ "$a" =~ ^[Yy] ]]; }

rc_file() {
  if [[ -n "${TK_RC:-}" ]]; then echo "$TK_RC"
  elif [[ "$(uname)" == "Darwin" ]]; then echo "$HOME/.bash_profile"
  else echo "$HOME/.bashrc"; fi
}

enabled() { [[ -f "$TK_CONFIG/modules" ]] && cat "$TK_CONFIG/modules"; }
is_enabled() { enabled | grep -qx "$1"; }

set_env() {   # set_env KEY VALUE -- replace or append in the env file
  local f="$TK_CONFIG/env" tmp
  touch "$f"; tmp="$(mktemp)"
  grep -v "^export $1=" "$f" > "$tmp"
  printf 'export %s=%q\n' "$1" "$2" >> "$tmp"
  mv "$tmp" "$f"
}

check_deps() {
  local m="$1" d missing=0
  for d in ${NEEDS[$m]}; do
    if command -v "$d" >/dev/null 2>&1; then ok "$m: $d found"
    else warn "$m: $d is REQUIRED and was not found"; missing=1; fi
  done
  for d in ${OPTION[$m]}; do
    command -v "$d" >/dev/null 2>&1 && ok "$m: $d found (optional)" \
      || say "  [info] $m: $d not found (optional; some features need it)"
  done
  return $missing
}

# ---- one-time base setup ----------------------------------------------------
base_setup() {
  mkdir -p "$TK_CONFIG" "$TK_CONFIG/history" "$TK_CONFIG/saved" "$TK_HOME/bin"
  touch "$TK_CONFIG/modules" "$TK_CONFIG/env"
  chmod +x "$TK_HOME/init.sh" 2>/dev/null
  find "$TK_HOME/bin" -maxdepth 1 -type f ! -name '.*' -exec chmod +x {} + 2>/dev/null

  # carry over state from the older layout, if any
  [[ -f "$HOME/.remote_hosts" && ! -s "$TK_CONFIG/hosts" ]] && \
    cp "$HOME/.remote_hosts" "$TK_CONFIG/hosts" && ok "imported hosts from ~/.remote_hosts"
  [[ -f "$HOME/.search_paths" && ! -s "$TK_CONFIG/search_paths" ]] && \
    cp "$HOME/.search_paths" "$TK_CONFIG/search_paths" && ok "imported saved paths from ~/.search_paths"

  local rc; rc="$(rc_file)"; touch "$rc"
  if ! grep -qF "$MARK_BEGIN" "$rc"; then
    { echo; echo "$MARK_BEGIN"
      echo "export TK_HOME=$(printf '%q' "$TK_HOME")"
      echo '[ -f "$TK_HOME/autoload.sh" ] && . "$TK_HOME/autoload.sh"'
      echo "$MARK_END"; } >> "$rc"
    ok "added the autoload line to $rc"
  else
    # the folder may have moved since last time: point the block at it
    local tmp; tmp="$(mktemp)"
    awk -v b="$MARK_BEGIN" -v e="$MARK_END" -v h="export TK_HOME=$(printf '%q' "$TK_HOME")" '
      $0==b {inb=1; print; next} $0==e {inb=0}
      inb && /^export TK_HOME=/ {print h; next} {print}' "$rc" > "$tmp" && cat "$tmp" > "$rc"
    rm -f "$tmp"; ok "autoload line already in $rc"
  fi
}

enable() {
  is_enabled "$1" || echo "$1" >> "$TK_CONFIG/modules"
  ok "$1 enabled"
}

# ---- per-module prompts (interactive runs only) ---------------------------
setup_search() {
  say "  search keeps its history, saved paths and saved lists in $TK_CONFIG."
  if yes "  Set a default ssh peer for \$ paths (user@host)?"; then
    local p; p="$(ask "  peer (user@host):")"
    [[ -n "$p" ]] && set_env SEARCH_PEER "$p" && ok "SEARCH_PEER=$p"
  fi
  say "  (peers registered with 'remote --add' are reachable as \$1, \$2, ...)"
}

setup_remote() {
  if yes "  Register an ssh host now?"; then
    while :; do
      local n u h
      n="$(ask "  name:")"; u="$(ask "  user:")"; h="$(ask "  host (IP or hostname):")"
      if [[ "$n" =~ ^[A-Za-z_][A-Za-z0-9_-]*$ && -n "$u" && -n "$h" ]]; then
        printf '%s\t%s\t%s\n' "$n" "$u" "$h" >> "$TK_CONFIG/hosts"; ok "$n -> $u@$h"
      else warn "skipped: name must be letters/digits/_/-, user and host required"; fi
      yes "  Another?" || break
    done
  fi
  if yes "  Forward X11 (graphical apps) over ssh by default?"; then
    set_env REMOTE_SSH_OPTS "-X"; ok "REMOTE_SSH_OPTS=-X"
  fi
}

setup_run()  { :; }
setup_wrap() { :; }

do_modules() {   # do_modules PROMPT(0|1) NAME...
  local prompt="$1" m; shift
  base_setup
  for m in "$@"; do
    say ""; say "== $m: ${DESC[$m]}"
    check_deps "$m" || warn "$m enabled anyway; install the missing tool before using it"
    enable "$m"
    (( prompt )) && "setup_$m"
  done
  say ""
  say "Done. Open a new terminal, or run:  source $(rc_file)"
  say "Every command has --help.  Settings: $TK_CONFIG/env"
}

status() {
  say "termkit: $TK_HOME"; say "config:  $TK_CONFIG"; say "rc:      $(rc_file)"
  grep -qF "$MARK_BEGIN" "$(rc_file)" 2>/dev/null && ok "autoload line present" || warn "autoload line missing"
  local m
  for m in "${MODULES[@]}"; do
    printf '  %-8s %-9s %s\n' "$m" "$(is_enabled "$m" && echo enabled || echo -)" "${DESC[$m]}"
  done
}

menu() {
  say "termkit setup -- choose what to set up"
  local i=1 m
  for m in "${MODULES[@]}"; do
    printf '  %d) %-8s %s%s\n' "$i" "$m" "${DESC[$m]}" "$(is_enabled "$m" && echo '   [enabled]')"
    ((i++))
  done
  say "  a) all"
  local pick; pick="$(ask "numbers (e.g. 1 3), a for all, Enter to quit:")"
  [[ -z "$pick" ]] && { say "nothing changed"; exit 0; }
  local -a chosen=()
  if [[ "$pick" =~ ^[Aa] ]]; then chosen=("${MODULES[@]}")
  else
    for i in $pick; do
      [[ "$i" =~ ^[0-9]+$ ]] && (( i>=1 && i<=${#MODULES[@]} )) \
        && chosen+=("${MODULES[$((i-1))]}") || warn "ignored '$i'"
    done
  fi
  (( ${#chosen[@]} )) || { say "nothing chosen"; exit 0; }
  do_modules 1 "${chosen[@]}"
}

remove_modules() {
  local m tmp
  for m in "$@"; do
    tmp="$(mktemp)"; enabled | grep -vx "$m" > "$tmp"; mv "$tmp" "$TK_CONFIG/modules"
    ok "$m disabled"
  done
  say "takes effect in a new terminal"
}

uninstall() {
  local rc tmp; rc="$(rc_file)"
  if [[ -f "$rc" ]] && grep -qF "$MARK_BEGIN" "$rc"; then
    tmp="$(mktemp)"
    awk -v b="$MARK_BEGIN" -v e="$MARK_END" '$0==b{skip=1} !skip{print} $0==e{skip=0}' "$rc" > "$tmp" \
      && cat "$tmp" > "$rc"; rm -f "$tmp"; ok "removed the autoload line from $rc"
  fi
  : > "$TK_CONFIG/modules" 2>/dev/null
  say "Modules disabled. Your hosts, history and saved files are kept in $TK_CONFIG;"
  say "delete that folder too if you want them gone."
}

# ---- main --------------------------------------------------------------------
case "${1:-}" in
  "")            menu ;;
  --all)         do_modules 0 "${MODULES[@]}" ;;
  --status)      status ;;
  --remove)      shift; (( $# )) || { say "usage: init.sh --remove NAME..."; exit 2; }; remove_modules "$@" ;;
  --uninstall)   uninstall ;;
  -h|--help)     sed -n '3,14p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//' ;;
  -*)            say "unknown option '$1' (try --help)"; exit 2 ;;
  *)
    for m in "$@"; do [[ -n "${DESC[$m]:-}" ]] || { say "unknown module '$m' (have: ${MODULES[*]})"; exit 2; }; done
    do_modules 1 "$@" ;;
esac
