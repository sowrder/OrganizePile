#!/usr/bin/env bash
# ============================================================================
# run — open files: images cycle with the arrow keys, everything else opens
#       in the system's default application
# ============================================================================
# Sourced.  Works on Linux, macOS and WSL.
#
#   run *.png                     cycle through images
#   run --view report.pdf         open in the default application
#   search './plots *.png' --list | run      open whatever search found
#
# Images use feh when it is installed (needs a display: X11, Wayland or
# WSLg).  Without feh they open in the default viewer: on WSL the files are
# copied to one Windows temp folder so the Photos app can arrow through all
# of them; on macOS Preview receives the whole set at once.
# ============================================================================

# open one path with the platform's default handler
_run_open() {
  if grep -qi microsoft /proc/version 2>/dev/null; then
    cmd.exe /c start "" "$(wslpath -w "$(realpath "$1")")" 2>/dev/null
  elif [[ "$(uname)" == "Darwin" ]]; then
    open "$1"
  else
    xdg-open "$1" >/dev/null 2>&1 &
  fi
}

_run_is_image() {
  case "${1,,}" in
    *.png|*.jpg|*.jpeg|*.gif|*.bmp|*.tif|*.tiff|*.webp) return 0 ;;
  esac
  return 1
}

run() {
  local view=0
  [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]] && { sed -n '3,16p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; return 0; }
  [[ "${1:-}" == "--view" ]] && { view=1; shift; }

  local -a files=()
  if [[ -t 0 ]]; then
    files=("$@")
  else
    local line
    while IFS= read -r line; do [[ -n "$line" ]] && files+=("$line"); done
  fi
  (( ${#files[@]} )) || { echo "run: no files" >&2; return 1; }

  local f all_img=1
  for f in "${files[@]}"; do _run_is_image "$f" || all_img=0; done

  if (( view )) || (( ! all_img )); then
    for f in "${files[@]}"; do _run_open "$f"; done
    return 0
  fi

  if command -v feh >/dev/null 2>&1; then
    feh --scale-down --auto-zoom "${files[@]}"
    return 0
  fi

  if grep -qi microsoft /proc/version 2>/dev/null; then
    # gather into one Windows folder so the viewer can arrow through all of them
    local wintmp dst first
    wintmp="$(cmd.exe /c 'echo %TEMP%' 2>/dev/null | tr -d '\r')"
    dst="$(wslpath -u "$wintmp")/run_view"
    rm -rf "$dst"; mkdir -p "$dst"
    for f in "${files[@]}"; do cp -- "$f" "$dst/" 2>/dev/null; done
    first="$(ls "$dst" | head -n1)"
    [[ -n "$first" ]] || { echo "run: nothing to open" >&2; return 1; }
    cmd.exe /c start "" "$wintmp\\run_view\\$first"
  elif [[ "$(uname)" == "Darwin" ]]; then
    open -a Preview "${files[@]}"
  else
    _run_open "${files[0]}"
  fi
}
