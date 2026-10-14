#!/usr/bin/env bash
# ============================================================================
# remote — named ssh hosts: register once, connect by name or number
# ============================================================================
# Sourced.  Hosts live in $REMOTE_HOSTS_FILE (tab-separated: name user host).
# Every registered host also becomes a shortcut command of its own name.
#
#   remote --add               register a host (prompts for name, user, host)
#   remote --change            change a host's address
#   remote --remove NAME       forget a host
#   remote -list               numbered list of hosts (the numbers search's $N uses)
#   remote                     ssh to the default host
#   remote -NAME [cmd...]      ssh to NAME, optionally running a command
#   NAME [cmd...]              same, via the shortcut
#
# REMOTE_DEFAULT   host used by bare `remote` (else the first registered)
# REMOTE_SSH_OPTS  extra ssh options, e.g. "-X" for X forwarding
# ============================================================================

: "${TK_CONFIG:=${XDG_CONFIG_HOME:-$HOME/.config}/termkit}"
_REMOTE_HOSTS_FILE="${REMOTE_HOSTS_FILE:-$TK_CONFIG/hosts}"

# iterate registered hosts: name<TAB>user<TAB>host, comments and blanks skipped
_remote_rows() {
  [[ -f "$_REMOTE_HOSTS_FILE" ]] || return 0
  awk -F'\t' 'NF>=3 && $1 !~ /^#/ && $1 != ""' "$_REMOTE_HOSTS_FILE"
}

_remote_resolve() {
  _remote_rows | awk -F'\t' -v n="$1" '$1==n {print $2"@"$3; f=1; exit} END{exit !f}'
}

# idx<TAB>name<TAB>user@host, in file order -- the numbering search's $N uses
_remote_enum() {
  _remote_rows | awk -F'\t' '{printf "%d\t%s\t%s@%s\n", NR, $1, $2, $3}'
}

_remote_byidx() {
  _remote_enum | awk -F'\t' -v k="$1" '$1==k {print $3; f=1} END{exit !f}'
}

_remote_list() {
  local out; out="$(_remote_enum)"
  [[ -n "$out" ]] || { echo "  (no hosts yet -- remote --add)"; return 0; }
  printf '%s\n' "$out" | awk -F'\t' '{printf "  %2s  %-12s %s\n", $1, $2, $3}'
}

_remote_shortcut() {
  # a shortcut must not shadow an existing command
  if type "$1" >/dev/null 2>&1 && ! declare -F "$1" >/dev/null; then
    echo "remote: '$1' is already a command; use 'remote -$1' instead" >&2
    return 0
  fi
  eval "$1() { remote -$1 \"\$@\"; }"
}

_remote_add() {
  local name user host
  read -rp "name: " name
  read -rp "user: " user
  read -rp "host (IP or hostname): " host
  name="${name// /}"; user="${user// /}"; host="${host// /}"
  [[ -n "$name" && -n "$user" && -n "$host" ]] || { echo "remote --add: name, user and host are all required" >&2; return 2; }
  [[ "$name" =~ ^[A-Za-z_][A-Za-z0-9_-]*$ ]] || { echo "remote --add: name must be letters, digits, _ or -" >&2; return 2; }
  _remote_resolve "$name" >/dev/null && { echo "remote --add: '$name' already exists (remote --change)" >&2; return 2; }
  mkdir -p "$(dirname "$_REMOTE_HOSTS_FILE")"
  printf '%s\t%s\t%s\n' "$name" "$user" "$host" >> "$_REMOTE_HOSTS_FILE"
  _remote_shortcut "$name"
  echo "added: $name -> $user@$host"
}

_remote_change() {
  local name host tmp
  echo "hosts:"; _remote_list
  read -rp "name to change: " name
  read -rp "new host (IP or hostname): " host
  name="${name// /}"; host="${host// /}"
  [[ -n "$name" && -n "$host" ]] || { echo "remote --change: name and host required" >&2; return 2; }
  _remote_resolve "$name" >/dev/null || { echo "remote --change: no host '$name'" >&2; return 2; }
  tmp="$(mktemp)"
  awk -F'\t' -v OFS='\t' -v n="$name" -v h="$host" '$1==n {$3=h} {print}' \
      "$_REMOTE_HOSTS_FILE" > "$tmp" && mv "$tmp" "$_REMOTE_HOSTS_FILE"
  echo "changed: $name -> $host"
}

_remote_remove() {
  local name="${1:-}" tmp
  [[ -n "$name" ]] || { echo "usage: remote --remove NAME" >&2; return 2; }
  _remote_resolve "$name" >/dev/null || { echo "remote --remove: no host '$name'" >&2; return 2; }
  tmp="$(mktemp)"
  awk -F'\t' -v n="$name" '$1!=n' "$_REMOTE_HOSTS_FILE" > "$tmp" && mv "$tmp" "$_REMOTE_HOSTS_FILE"
  declare -F "$name" >/dev/null && unset -f "$name"
  echo "removed: $name"
}

remote() {
  local host="${REMOTE_DEFAULT:-}" target
  while [[ "${1:-}" == -* ]]; do
    case "$1" in
      -h|--help) sed -n '3,19p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; return 0 ;;
      -list|--list) _remote_list; return 0 ;;
      --add)    _remote_add;    return $? ;;
      --change) _remote_change; return $? ;;
      --remove) shift; _remote_remove "${1:-}"; return $? ;;
      --) shift; break ;;
      -*)
        local cand="${1#-}"; cand="${cand#-}"
        if _remote_resolve "$cand" >/dev/null; then host="$cand"; shift
        else echo "remote: unknown flag or host '$1' (remote -list)" >&2; return 2; fi ;;
    esac
  done
  [[ -n "$host" ]] || host="$(_remote_rows | head -n1 | cut -f1)"
  [[ -n "$host" ]] || { echo "remote: no hosts registered (remote --add)" >&2; return 2; }
  target="$(_remote_resolve "$host")" || { echo "remote: no host '$host' (remote -list)" >&2; return 2; }
  # conda and similar environments can leak libraries that break ssh
  # shellcheck disable=SC2086
  env -u LD_LIBRARY_PATH -u LD_PRELOAD ssh ${REMOTE_SSH_OPTS:-} "$target" "$@"
}

# a shortcut per registered host
while IFS=$'\t' read -r _rn _ru _rh; do
  [[ -n "$_rn" ]] && _remote_shortcut "$_rn"
done < <(_remote_rows)
unset _rn _ru _rh
