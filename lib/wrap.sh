#!/usr/bin/env bash
# ============================================================================
# wrap — paste Python at the terminal, auto-clean paste artifacts, run it
# ============================================================================
# Sourced function.  Works with any python3 on PATH. Paste code (from Copilot, a browser, a PDF, anywhere),
# end with Ctrl-D, and wrap will:
#   1. CLEAN it   — undo HTML entities (&gt; &amp; &quot; &#39;), smart quotes,
#                   em/en dashes, non-breaking/zero-width spaces, CRLF.
#   2. SYNTAX-CHECK all pasted scripts before running any.
#   3. RUN them in order, stopping at the first failure.
#
# USAGE
#   wrap            paste one script, Ctrl-D, it runs
#   wrap N          paste N scripts (Ctrl-D between each), all checked then run
#   wrap ... args   args after the count are passed to EVERY script as argv,
#                   comma-separated per script:  wrap 2 a b , c
#
# Cleaned source for script i is left at the path printed on error, so a
# syntax failure shows you the cleaned file to inspect.
# ----------------------------------------------------------------------------

wrap() {
    local count=1
    local -a argsets=()
    # first arg: count if numeric
    if [[ "${1:-}" =~ ^[0-9]+$ ]]; then count="$1"; shift; fi
    # remaining: per-script arg sets split on commas
    if (( $# )); then
        local raw="$*" IFS=','
        read -ra argsets <<< "$raw"
        unset IFS
    fi

    local -a tmps=()
    local i tmp rc

    for ((i=1; i<=count; i++)); do
        # portable: BSD/macOS mktemp has no --suffix
        tmp="$(mktemp "${TMPDIR:-/tmp}/wrap.XXXXXX")" || return 1
        mv "$tmp" "$tmp.py" && tmp="$tmp.py"
        if (( count == 1 )); then
            echo "wrap: paste Python, then Ctrl-D to run"
        else
            echo "wrap: paste script $i of $count, then Ctrl-D"
        fi
        # capture the paste, then clean it via python
        local rawtmp; rawtmp="$(mktemp)"
        cat > "$rawtmp"
        python3 - "$rawtmp" "$tmp" << 'PYEOF'
import sys, html, re
raw_path, out_path = sys.argv[1], sys.argv[2]
with open(raw_path, "r", encoding="utf-8", errors="replace") as f:
    text = f.read()
text = html.unescape(text)
repl = {
    "\u2018":"'", "\u2019":"'", "\u201a":"'", "\u201b":"'",
    "\u201c":'"', "\u201d":'"', "\u201e":'"', "\u201f":'"',
    "\u2013":"-", "\u2014":"-", "\u2015":"-",
    "\u00a0":" ", "\u2007":" ", "\u202f":" ", "\u2026":"...",
}
for k,v in repl.items():
    text = text.replace(k,v)
text = re.sub(r"[\u200b\u200c\u200d\ufeff\u2060]", "", text)
text = text.replace("\r\n","\n").replace("\r","\n")
text = "\n".join(line.rstrip() for line in text.split("\n"))
with open(out_path, "w", encoding="utf-8") as f:
    f.write(text)
PYEOF
        rm -f "$rawtmp"
        tmps+=("$tmp")
    done

    # syntax-check all before running any
    local errf; errf="$(mktemp)"
    for i in "${!tmps[@]}"; do
        if ! python3 -m py_compile "${tmps[$i]}" 2>"$errf"; then
            echo
            echo "wrap: syntax error in script $((i+1)); nothing executed"
            cat "$errf"; rm -f "$errf"
            echo "wrap: cleaned source retained: ${tmps[*]}"
            return 1
        fi
    done
    rm -f "$errf"
    echo "wrap: syntax OK for all $count; executing in order"

    # run in order; stop on first failure
    for i in "${!tmps[@]}"; do
        local -a a=(); read -ra a <<< "${argsets[$i]:-}"
        echo "----- wrap: running script $((i+1))/$count${a:+ (args: ${a[*]})} -----"
        python3 "${tmps[$i]}" "${a[@]}"
        rc=$?
        if (( rc != 0 )); then
            echo "wrap: script $((i+1)) exited $rc; stopping"
            rm -f "${tmps[@]}"
            return "$rc"
        fi
    done

    rm -f "${tmps[@]}"
    return 0
}
