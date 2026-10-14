# ============================================================================
# search — filesystem search with a glob-ish grammar, local, over rclone,
#          or on the ssh peer
# ============================================================================
# USAGE
#   search [savedname] '(dir) PATTERN' [--list] [--max K] [MODE DEST]
#
#   One directory, one pattern.  For several searches, loop:
#     for s in P114 P115; do search "./ *${s}*" ; done
#
# PATTERN grammar (applies to BOTH dir components and the filename)
#   *          any run of characters
#   (abc)      one char from the set, repeated to the SET's length
#   ^(abc)     one char NOT in the set, same length rule
#   [a|b|c]    whole-string choice: ses-[03|04|12|13].  Separator is '|' not
#              a space, because the group is split on whitespace first.
#
# --max K   cap the walk at K edges BELOW the resolved base, cumulative.
#           0 = files sitting directly in the base; 1 = those plus one folder
#           down; and so on.  A folder appears in the tree exactly when a
#           MATCHED FILE sits under it within the limit — the cap bounds the
#           walk, it does not add directories to the result set.
#           Locally this prunes os.walk in place, so the skipped subtree is
#           never stat'd.  On a remote it becomes rclone --max-depth, and on
#           the ssh peer find -maxdepth, both enforced on the far side rather
#           than by listing everything and discarding most.
#           Unbounded when omitted.
#
# --list    bare paths instead of the tree, for piping:
#             mapfile -t paths < <(search './data *.csv' --list)
#
# MODE      --get DEST  copy matches into a LOCAL dir, tree preserved, existing
#                       files skipped (remote->local: rclone download;
#                       peer->local: rsync; local->local: copy)
#           --up  DEST  send local matches on, tree preserved (local->remote:
#                       rclone upload; local->peer: rsync copy; local->local:
#                       move, aborts if any target already exists)
#
# PATHS     a leading ~ in the dir token or a destination means $HOME
# PEER      a leading $ in the dir token or a destination means the ssh peer's
#           home directory.  SEARCH_PEER=user@host names the default peer;
#           $N picks host N from the remote registry (search --$ lists them).
#           The password is asked once per terminal on first use.
# HELP      search --help
#
# REMOTES   a dir token shaped 'name:path' is rclone.  The name is checked
#           against the rclone config, so a stray colon fails loudly instead
#           of being guessed at.  rclone is reached ONLY for remote tokens;
#           a purely local search never touches it and does not need it
#           installed.
#
# SAVED PATHS
#   search --spath "gdrive:projects/data" prj     save
#   search --lpath                                list
#   search --rmpath prj                           remove
#   search prj 'raw/* *.csv'                      name first: prefixes the dir
#   search '@prj/raw/* *.csv'                     @name inside the dir token
# ============================================================================

# ---- state ---------------------------------------------------------------------
# Everything search keeps lives under one config directory, each path
# overridable on its own.  Exported so the embedded python sees the same values.
_SEARCH_LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
: "${TK_CONFIG:=${XDG_CONFIG_HOME:-$HOME/.config}/termkit}"
export SEARCH_HIST_DIR="${SEARCH_HIST_DIR:-$TK_CONFIG/history}"
export SEARCH_SAVE_DIR="${SEARCH_SAVE_DIR:-$TK_CONFIG/saved}"
export SEARCH_PATHS="${SEARCH_PATHS:-$TK_CONFIG/search_paths}"

# ---- $ peers via remote -----------------------------------------------------
# $ alone is SEARCH_PEER as before.  $N picks host N from remote's registry;
# the only thing that changes is which user@ip SEARCH_PEER holds for the call.
_search_remote_src() {
  declare -F _remote_enum >/dev/null && return 0
  # remote.sh ships beside this file
  [[ -f "$_SEARCH_LIB/remote.sh" ]] || { echo "search: remote.sh not found beside search.sh" >&2; return 1; }
  . "$_SEARCH_LIB/remote.sh"
}

_search_peer_idx() {
  _search_remote_src || return 1
  local t; t="$(_remote_byidx "$1")" || {
    echo "search: no peer $1 (search --\$ to list)" >&2; return 1; }
  printf '%s' "$t"
}

search() {
  case "${1:-}" in -h|--help) _search_help; return 0 ;; esac
  case "${1:-}" in
    '--$'|--peers)
      _search_remote_src || return 1
      echo "  peers (\$N):"
      _remote_enum | awk -F'\t' '{printf "  %2s  %-10s %s\n", $1, $2, $3}'
      return 0 ;;
  esac
  # saved-path management, handled before the group grammar
  case "${1:-}" in
    --spath)
      [[ -n "$2" && -n "$3" ]] || { echo 'usage: search --spath "<path>" <name>' >&2; return 2; }
      mkdir -p "$(dirname "$SEARCH_PATHS")"; touch "$SEARCH_PATHS"
      local _tmp; _tmp=$(mktemp)
      awk -F'\t' -v n="$3" '$1!=n' "$SEARCH_PATHS" > "$_tmp"
      printf '%s\t%s\n' "$3" "$(_search_tilde "$2")" >> "$_tmp"
      sort -o "$SEARCH_PATHS" "$_tmp"; rm -f "$_tmp"
      printf '%-16s %s\n' "$3" "$2"
      return 0 ;;
    --lpath)
      [[ -s "$SEARCH_PATHS" ]] || { echo "search: no saved paths yet" >&2; return 1; }
      awk -F'\t' '{printf "%-16s %s\n", $1, $2}' "$SEARCH_PATHS"
      return 0 ;;
    --rmpath)
      [[ -n "$2" ]] || { echo "usage: search --rmpath <name>" >&2; return 2; }
      [[ -s "$SEARCH_PATHS" ]] || return 1
      local _tmp; _tmp=$(mktemp)
      awk -F'\t' -v n="$2" '$1!=n' "$SEARCH_PATHS" > "$_tmp"
      mv "$_tmp" "$SEARCH_PATHS"
      echo "removed $2"
      return 0 ;;
  esac

  # a bare saved-path name as the first argument prefixes the dir token
  local _base=""
  if [[ -n "${1:-}" && "$1" != *" "* && "$1" != *"/"* && "$1" != -* ]]; then
    if _base="$(_spath_get "$1")"; then
      shift
    else
      _base=""
    fi
  fi

  # --- pre-pass: pull --max out wherever it sits -----------------------------
  # Lifting it before the mode-flag split means position never matters, so
  # '--max 2 --get DIR' and '--get DIR --max 2' behave the same instead of the
  # second one feeding '--max' to the destination parser.
  local maxd="" ; local -a argv=()
  local ai=0 ; local -a _in=("$@")
  while (( ai < ${#_in[@]} )); do
    case "${_in[$ai]}" in
      --max)
        local nx="${_in[$((ai+1))]:-}"
        [[ "$nx" =~ ^[0-9]+$ ]] || {
          echo "search: --max needs a non-negative integer, got '${nx:-<nothing>}'" >&2
          return 2; }
        maxd="$nx"; ai=$((ai+2)); continue ;;
      --max=*)
        local nx="${_in[$ai]#--max=}"
        [[ "$nx" =~ ^[0-9]+$ ]] || {
          echo "search: --max needs a non-negative integer, got '$nx'" >&2
          return 2; }
        maxd="$nx"; ai=$((ai+1)); continue ;;
      *) argv+=("${_in[$ai]}"); ai=$((ai+1)) ;;
    esac
  done

  # --- split the input group from the output mode ---------------------------
  local -a inargs=() outargs=()
  local seen_mv=0 mode="" tok
  for tok in "${argv[@]}"; do
    if [[ "$tok" == "--mv" || "$tok" == "--cp" ]]; then
      echo "search: $tok was replaced -- use --get DEST to copy, or --up DEST to move (DEST local)" >&2
      return 2
    fi
    if [[ "$tok" == "--get" ]]; then seen_mv=1; mode="get"; continue; fi
    if [[ "$tok" == "--up"  ]]; then seen_mv=1; mode="up";  continue; fi
    if (( seen_mv )); then outargs+=("$tok"); else inargs+=("$tok"); fi
  done

  # --- the one group --------------------------------------------------------
  local -a a=(); read -ra a <<< "${inargs[*]}"
  local dir="./" list=0 rcl=0 rsh=0 pat="" ti=0 t
  while (( ti < ${#a[@]} )); do
    t="${a[$ti]}"
    if [[ "$t" == "--list" ]]; then list=1; ti=$((ti+1)); continue; fi
    if [[ "$t" == *"/"* || "$t" == "~" || "$t" == '$'* || "$t" =~ ^[A-Za-z0-9_][A-Za-z0-9_+.-]*: ]]; then
      dir="$t"; ti=$((ti+1)); continue
    fi
    pat="$t"; ti=$((ti+1))
  done
  if [[ -z "$pat" ]]; then
    echo "search: no file pattern given: '${inargs[*]}'" >&2
    return 2
  fi

  dir="$(_spath_expand "$(_search_tilde "$dir")")"
  if [[ -n "$_base" && "$dir" != '$'* ]]; then
    case "$dir" in
      ./|.)  dir="$_base" ;;
      /*)    dir="${_base%/}$dir" ;;
      *)     dir="${_base%/}/$dir" ;;
    esac
  fi
  # a leading $ is the ssh peer's home; the rest is relative to it.
  # a "remote:path" token is rclone.  The name is checked against the rclone
  # config on the python side, so a stray colon in a local path fails loudly
  # rather than being guessed at.
  local _peer=""
  if [[ "$dir" == '$'* ]]; then
    rsh=1; dir="${dir#\$}"
    if [[ "$dir" =~ ^([0-9]+) ]]; then
      _peer="$(_search_peer_idx "${BASH_REMATCH[1]}")" || return 2
      dir="${dir#${BASH_REMATCH[1]}}"
    fi
    dir="${dir#/}"
  elif [[ "$dir" =~ ^[A-Za-z0-9_][A-Za-z0-9_+.-]*: ]]; then rcl=1; fi

  # --- destination ----------------------------------------------------------
  local odir="" orcl=0 orsh=0
  if (( seen_mv )); then
    odir="${outargs[0]:-}"
    [[ -n "$odir" ]] || { echo "search: --$mode needs a destination" >&2; return 2; }
    if (( ${#outargs[@]} > 1 )); then
      echo "search: --$mode takes one destination, got: ${outargs[*]}" >&2
      return 2
    fi
    odir="$(_search_tilde "$odir")"
    if [[ "$odir" == '$'* ]]; then
      orsh=1; odir="${odir#\$}"
      if [[ "$odir" =~ ^([0-9]+) ]]; then
        local _op; _op="$(_search_peer_idx "${BASH_REMATCH[1]}")" || return 2
        if [[ -n "$_peer" && "$_op" != "$_peer" ]]; then
          echo "search: two different peers in one call ($_peer, $_op) -- that is a peer-to-peer transfer, do it directly" >&2
          return 2
        fi
        _peer="$_op"; odir="${odir#${BASH_REMATCH[1]}}"
      fi
      odir="${odir#/}"
    elif [[ "$odir" =~ ^[A-Za-z0-9_][A-Za-z0-9_+.-]*: ]]; then orcl=1; fi
    # --get always lands locally; sending matches elsewhere is --up's job
    if [[ "$mode" == "get" ]] && (( orcl || orsh )); then
      echo "search: --get delivers to a local dir; to send matches on use --up $odir" >&2
      return 2
    fi
  fi

  # $ peer password: asked once per terminal, held in this shell only (not
  # exported), handed to the one call that needs it.  Cleared if rejected.
  local _pk="${_peer:-${SEARCH_PEER:-peer}}"
  declare -gA _SEARCH_PW_MAP 2>/dev/null
  if (( rsh || orsh )) && [[ -z "${_SEARCH_PW_MAP[$_pk]+x}" ]]; then
    read -rsp "password for $_pk: " _SEARCH_PW_MAP["$_pk"]; echo >&2
  fi
  local _rc
  SEARCH_PW="${_SEARCH_PW_MAP[$_pk]:-}" SEARCH_PEER="${_peer:-$SEARCH_PEER}" _search_exec "$dir" "$pat" "$list" "$seen_mv" "$odir" "$mode" "$rcl" "$maxd" "$orcl" "$rsh" "$orsh"
  _rc=$?
  (( _rc == 4 )) && unset '_SEARCH_PW_MAP[$_pk]'
  return $_rc
}

_search_exec() {
python3 - "$@" <<'PYEOF'
import os, re, sys, time, shutil, subprocess, shlex

g_dir   = sys.argv[1]
g_pat   = sys.argv[2]
g_list  = sys.argv[3] == "1"
seen_mv = sys.argv[4] == "1"
o_dir   = sys.argv[5]
mode    = sys.argv[6]
g_rcl   = sys.argv[7] == "1"
g_max   = int(sys.argv[8]) if len(sys.argv) > 8 and sys.argv[8] != "" else None
o_rcl   = len(sys.argv) > 9 and sys.argv[9] == "1"
g_rsh   = len(sys.argv) > 10 and sys.argv[10] == "1"
o_rsh   = len(sys.argv) > 11 and sys.argv[11] == "1"

class PatternError(ValueError): pass

_STEM = {"v": ""}

def _build_tree(paths):
    root={}
    for p in paths:
        if re.match(r"^[A-Za-z0-9_][A-Za-z0-9_+.-]*:", p):
            parts=[x for x in p.replace(":", ":/", 1).split("/") if x!=""]
        else:
            parts=[x for x in p.split(os.sep) if x!=""]
        node=root
        for part in parts: node=node.setdefault(part,{})
    return root

def _render(node, prefix=""):
    lines=[]; items=sorted(node.items())
    for i,(name,child) in enumerate(items):
        last=i==len(items)-1
        lines.append(prefix+("\u2514\u2500\u2500 " if last else "\u251c\u2500\u2500 ")+name)
        if child:
            lines.extend(_render(child, prefix+("    " if last else "\u2502   ")))
    return lines

def tokenize(p):
    toks=[]; i=0; n=len(p); lit=[]
    def flush():
        if lit: toks.append(("LIT","".join(lit))); lit.clear()
    while i<n:
        c=p[i]
        if c=="*": flush(); toks.append(("STAR",None)); i+=1
        elif c=="^" and i+1<n and p[i+1]=="(":
            flush(); j=p.find(")",i+2)
            if j==-1: raise PatternError("unclosed '^('")
            toks.append(("NGROUP",p[i+2:j])); i=j+1
        elif c=="(":
            flush(); j=p.find(")",i+1)
            if j==-1: raise PatternError("unclosed '('")
            toks.append(("GROUP",p[i+1:j])); i=j+1
        elif c==")": raise PatternError("unmatched ')'")
        elif c=="[":
            flush(); j=p.find("]",i+1)
            if j==-1: raise PatternError("unclosed '['")
            toks.append(("ALT",p[i+1:j])); i=j+1
        elif c=="]": raise PatternError("unmatched ']'")
        else: lit.append(c); i+=1
    flush(); return toks

def validate(toks):
    for k,v in toks:
        if k in ("GROUP","NGROUP") and v=="":
            raise PatternError("empty union '()' has no category")
        if k=="ALT" and not [x for x in v.split("|") if x]:
            raise PatternError("empty choice '[]' has no alternatives")

def _class(m,neg):
    esc=m.replace("\\","\\\\").replace("]","\\]").replace("^","\\^").replace("-","\\-")
    return (f"[^{esc}]" if neg else f"[{esc}]")+f"{{{len(m)}}}"

def compile_token(p):
    toks=tokenize(p); validate(toks); out=["^"]
    for k,v in toks:
        if k=="STAR": out.append(".*")
        elif k=="LIT": out.append(re.escape(v))
        elif k=="GROUP": out.append(_class(v,False))
        elif k=="NGROUP": out.append(_class(v,True))
        elif k=="ALT":
            parts=[x for x in v.split("|") if x]
            out.append("(?:"+"|".join(re.escape(x) for x in parts)+")")
    out.append("$")
    return re.compile("".join(out))

def resolve_bases(dirtok):
    if dirtok in ("", "."):
        return ["."]
    lead = ""
    d = dirtok
    if d.startswith("/"):
        lead="/"; d=d[1:]
    elif d.startswith("./"):
        lead="./"; d=d[2:]
    comps=[c for c in d.split("/") if c!=""]
    bases=[lead if lead else "./"]
    for comp in comps:
        cre=compile_token(comp)
        nxt=[]
        for b in bases:
            try: entries=os.listdir(b)
            except OSError: entries=[]
            for dn in entries:
                full=os.path.join(b,dn)
                if os.path.isdir(full) and cre.match(dn):
                    nxt.append(full)
        if not nxt:
            has_wild=any(ch in comp for ch in "*()^[]")
            if not has_wild:
                raise FileNotFoundError(f"folder '{comp}' not found under {bases}")
        bases=nxt
        if not bases: break
    return bases

# ---- the rclone side -------------------------------------------------------
# rclone has no wildcards and walking it a level at a time costs a round trip
# per level.  So it returns the flat path list with ONE recursive call and
# search's own grammar filters it and draws the branches.
_WILD = "*()^[]"

def rclone_remotes():
    """{name: type} from the rclone config.  The config is what decides
    whether a token is a remote — not the shape of the string."""
    if not hasattr(rclone_remotes, "_c"):
        out={}
        r=subprocess.run(["rclone","listremotes","--long"],
                         capture_output=True, text=True)
        if r.returncode==0 and r.stdout.strip():
            for line in r.stdout.splitlines():
                nm,_,ty=line.partition(":")
                nm=nm.strip()
                if nm: out[nm]=ty.strip() or "?"
        else:                      # --long is newer; bare names still work
            r=subprocess.run(["rclone","listremotes"],
                             capture_output=True, text=True)
            for line in r.stdout.splitlines():
                nm=line.strip().rstrip(":")
                if nm: out[nm]="?"
        rclone_remotes._c=out
    return rclone_remotes._c

_PROG = os.environ.get("SEARCH_PROGRESS","1") != "0" and sys.stderr.isatty()

def rclone_listing(target, maxdepth=None):
    """Raw `rclone lsf -R` lines for target.

    Read line by line rather than buffered, so the count rises while the
    listing runs instead of the terminal sitting dead.  rclone announces no
    total for a listing, so there is no percentage to show — the honest
    signals are the running count, the rate, and elapsed time.

    Progress goes to stderr, so `search ... --list > out.txt` stays parseable.
    SEARCH_PROGRESS=0 silences it; it is off already when stderr is not a tty.
    """
    name=target.split(":",1)[0]
    try:
        rem=rclone_remotes()
    except FileNotFoundError:
        raise FileNotFoundError(
            "rclone is not installed, so remote paths are unavailable "
            "(local search is unaffected)")
    if name not in rem:
        known=", ".join(sorted(rem)) or "none configured"
        raise FileNotFoundError(
            f"'{name}:' is not an rclone remote (configured: {known})")

    cmd=["rclone","lsf","-R",target,"--files-only"]
    if maxdepth is not None:
        cmd+=["--max-depth", str(maxdepth)]

    if _PROG:
        sys.stderr.write(f"  [{rem[name]}] listing {target}"
                         + (f" (max-depth {maxdepth})" if maxdepth else "")
                         + "\n")
        sys.stderr.flush()

    t0=time.time(); out=[]; err=[]
    pr=subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                        text=True, bufsize=1)
    try:
        for line in pr.stdout:
            line=line.strip()
            if not line: continue
            out.append(line)
            if _PROG and len(out)%200==0:
                el=time.time()-t0
                sys.stderr.write(f"\r  {len(out):,} files  "
                                 f"{len(out)/max(el,1e-9):,.0f}/s  {el:,.0f}s ")
                sys.stderr.flush()
        err=pr.stderr.read().strip().splitlines()
    finally:
        pr.wait()

    if _PROG:
        el=time.time()-t0
        sys.stderr.write(f"\r  {len(out):,} files in {el:,.1f}s"
                         + " "*24 + "\n")
        sys.stderr.flush()

    if pr.returncode!=0:
        msg=(err or ["failed"])[-1]
        raise FileNotFoundError(f"rclone lsf {target}: {msg}")
    return out

# ---- the ssh peer ($) ------------------------------------------------------
# $ is "the other end"; SEARCH_PEER names it on each machine.  The peer's sshd
# must start a POSIX shell (on a Windows peer, set its sshd shell to WSL) so
# paths resolve against that home.  Paths
# are absolute because sshd starts the shell in the Windows profile dir.  One
# multiplexed connection is reused for the home lookup, listing and transfer.
PEER = os.environ.get("SEARCH_PEER", "")
SSH_OPTS = ["-o", "ControlMaster=auto",
            "-o", "ControlPath=" + os.path.expanduser("~/.ssh") + "/cm-%r@%h:%p",
            "-o", "ControlPersist=120"]
RSH = "ssh " + " ".join(shlex.quote(x) for x in SSH_OPTS)
# hand the terminal's password to ssh (and rsync's ssh) through OpenSSH's own
# askpass hook; the helper only echoes the variable, it stores nothing
if os.environ.get("SEARCH_PW"):
    _ap = os.path.expanduser("~/.ssh/.search_askpass")
    os.makedirs(os.path.dirname(_ap), exist_ok=True)
    if not os.path.exists(_ap):
        with open(_ap, "w") as fh: fh.write('#!/bin/sh\nprintf "%s\\n" "$SEARCH_PW"\n')
        os.chmod(_ap, 0o700)
    os.environ["SSH_ASKPASS"] = _ap
    os.environ["SSH_ASKPASS_REQUIRE"] = "force"

def _ssh(cmd):
    if not PEER:
        raise FileNotFoundError("$ needs SEARCH_PEER set (user@host of the other end)")
    os.makedirs(os.path.expanduser("~/.ssh"), exist_ok=True)
    return subprocess.run(["ssh"] + SSH_OPTS + [PEER, cmd], capture_output=True, text=True)

def peer_home():
    if not hasattr(peer_home, "_h"):
        r = _ssh("echo $HOME")
        if r.returncode == 255 and "Permission denied" in r.stderr:
            print(f"search: password rejected by {PEER}", file=sys.stderr); sys.exit(4)
        lines = r.stdout.strip().splitlines()
        h = lines[-1].strip() if lines else ""
        if r.returncode != 0 or not h.startswith("/"):
            raise FileNotFoundError(
                f"ssh {PEER}: could not resolve a home directory (got "
                f"{h or r.stderr.strip() or 'nothing'!r}; on a Windows peer, sshd's shell must be WSL)")
        peer_home._h = h
    return peer_home._h

def ssh_listing(stem, maxdepth=None):
    base = peer_home() + ("/" + stem if stem else "")
    cmd = "cd -- " + shlex.quote(base) + " && find . " + \
          (f"-maxdepth {int(maxdepth)} " if maxdepth is not None else "") + "-type f"
    if _PROG:
        sys.stderr.write(f"  [ssh {PEER}] listing $/{stem}"
                         + (f" (max-depth {maxdepth})" if maxdepth else "") + "\n")
        sys.stderr.flush()
    r = _ssh(cmd)
    if r.returncode != 0:
        msg = (r.stderr.strip().splitlines() or ["failed"])[-1]
        raise FileNotFoundError(f"ssh find $/{stem}: {msg}")
    out = [l[2:] if l.startswith("./") else l
           for l in r.stdout.splitlines() if l.strip() and l.strip() != "."]
    if _PROG:
        sys.stderr.write(f"  {len(out):,} files\n"); sys.stderr.flush()
    return out

def listed_search(dirtok, pat, maxd=None, lister=None, ssh=False):
    # Shared by rclone and the ssh peer: one flat recursive listing from the
    # fixed stem, filtered by search's own grammar.
    # A trailing slash means "the files are AT this level, stop here", which
    # becomes --max-depth and so is enforced on the far side rather than by
    # fetching everything and discarding most of it.  An explicit --max wins
    # over it: --max 0 is the same statement made deliberately, and a larger
    # value is a deliberate widening.
    stop_here = dirtok.endswith("/")
    dirtok = dirtok.rstrip("/")
    comps=dirtok.split("/")
    fixed=[]; wild=[]
    for c in comps:
        if wild or any(ch in c for ch in _WILD): wild.append(c)
        else: fixed.append(c)
    stem="/".join(fixed)
    wild=[c for c in wild if c]
    cres=[compile_token(c) for c in wild]
    fre=compile_token(pat)
    _STEM["v"]=stem
    # depth counts from the stem: each wild component is a level, plus one
    # for the file itself, plus however many extra levels --max allows.
    if maxd is not None:
        depth = len(cres) + 1 + maxd
    else:
        depth = (len(cres)+1) if stop_here else None
    hits=[]
    for path in (lister or rclone_listing)(stem, depth):
        seg=path.split("/")
        if not fre.match(seg[-1]): continue
        dirs=seg[:-1]
        if cres:
            if len(dirs)<len(cres): continue
            if not all(c.match(d) for c,d in zip(cres,dirs)): continue
        # --max is measured from the RESOLVED BASE, i.e. after the wild
        # components, so anything deeper than that is dropped here.  The
        # far-side depth limit already trimmed most of it; this is the exact cut.
        if maxd is not None and len(dirs) - len(cres) > maxd: continue
        if ssh:
            hits.append("$/" + (stem + "/" if stem else "") + path)
        else:
            sep="" if stem.endswith(":") or stem.endswith("/") else "/"
            hits.append(stem+sep+path)
    hits.sort()
    if _PROG:
        sys.stderr.write(f"  {len(hits):,} match(es) after filtering\n")
        sys.stderr.flush()
    return hits

def do_search(dirtok, pat, rcl=False, maxd=None, rsh=False):
    if rsh:
        return listed_search(dirtok, pat, maxd, ssh_listing, True)
    if rcl:
        return listed_search(dirtok, pat, maxd)
    fre=compile_token(pat)
    bases=resolve_bases(dirtok)
    found=[]; seen=set()
    for base in bases:
        base_n = base.rstrip(os.sep).count(os.sep)
        for dp,dns,fns in os.walk(base):
            for fn in fns:
                if fre.match(fn):
                    full=os.path.join(dp,fn)
                    if full not in seen: seen.add(full); found.append(full)
            # Depth of dp BELOW base; 0 is the base itself.  Pruning AFTER the
            # files at this level are collected is what makes --max K include
            # level K rather than stop one short of it.  os.walk is top-down,
            # so emptying dns means the subtree is never stat'd at all.
            if maxd is not None:
                if dp.rstrip(os.sep).count(os.sep) - base_n >= maxd:
                    dns[:] = []
    found.sort()
    return found

try:
    results = do_search(g_dir, g_pat, g_rcl, g_max, g_rsh)
except (PatternError, FileNotFoundError) as e:
    print(f"search: {e}", file=sys.stderr); sys.exit(2)

if g_list:
    for pth in results:
        print(pth)
else:
    print(f"  dir '{('$/' + g_dir) if g_rsh else g_dir}'  file {g_pat}"
          + (f"  [max {g_max}]" if g_max is not None else "")
          + ("  [rclone]" if g_rcl else "")
          + (f"  [ssh {PEER}]" if g_rsh else ""))
    if results:
        for line in _render(_build_tree(results)):
            print("  "+line)
    print(f"  ({len(results)} match(es))")

# ---- output modes ----------------------------------------------------------
def _bar(done, total, w=30):
    f = done/total if total else 1.0
    n = int(f*w)
    return "["+"#"*n+"-"*(w-n)+f"] {done}/{total} ({f*100:.0f}%)"

def _relfile(rels):
    import tempfile
    tf=tempfile.NamedTemporaryFile("w",suffix=".txt",delete=False,
                                   dir=os.path.expanduser("~"))
    tf.write("\n".join(rels)+"\n"); tf.close()
    return tf.name

if seen_mv and mode == "get":
    os.makedirs(o_dir, exist_ok=True)
    if not results:
        print("  --get: no matches")
    elif g_rsh:
        stem=_STEM["v"]
        pre="$/"+(stem+"/" if stem else "")
        rels=[q[len(pre):] if q.startswith(pre) else q for q in results]
        lf=_relfile(rels)
        src=PEER+":"+peer_home()+("/"+stem if stem else "")+"/"
        print(f"  --get: {len(rels)} file(s)  $/{stem} -> {o_dir}")
        rc=subprocess.call(["rsync","-a","-s","--ignore-existing","--info=progress2",
                            "-e",RSH,"--files-from",lf,src,o_dir.rstrip("/")+"/"])
        os.unlink(lf)
        if rc!=0:
            print(f"  --get: rsync exited {rc}", file=sys.stderr); sys.exit(3)
        print(f"  --get: {len(rels)} file(s)")
    elif g_rcl:
        stem=_STEM["v"]
        pre=stem+("" if stem.endswith(":") else "/")
        rels=[q[len(pre):] if q.startswith(pre) else q for q in results]
        lf=_relfile(rels)
        print(f"  --get: {len(rels)} file(s)  {stem} -> {o_dir}")
        rc=subprocess.call(["rclone","copy",stem,o_dir,
                            "--files-from-raw",lf,"-P"])
        os.unlink(lf)
        if rc!=0:
            print(f"  --get: rclone exited {rc}", file=sys.stderr); sys.exit(3)
        print(f"  --get: {len(rels)} file(s)")
    else:
        root=os.path.commonpath(
            [os.path.dirname(os.path.abspath(q)) for q in results])
        copied=skipped=0; total=len(results)
        for idx,src in enumerate(results, 1):
            dst=os.path.join(o_dir, os.path.relpath(os.path.abspath(src), root))
            os.makedirs(os.path.dirname(dst), exist_ok=True)
            if os.path.exists(dst): skipped+=1
            else: shutil.copy2(src,dst); copied+=1
            sys.stderr.write("\r  --get "+_bar(idx,total)+f"  copied {copied} skipped {skipped}   ")
            sys.stderr.flush()
        sys.stderr.write("\n")
        print(f"  --get: copied {copied}, skipped {skipped} already present  {root} -> {o_dir}")

elif seen_mv and mode == "up":
    # Mirror of --get, direction reversed.  A remote or peer source would need
    # a far-side to far-side copy, which search does not manage, so it is
    # refused.
    import tempfile
    if g_rcl or g_rsh:
        print("search: --up sends LOCAL matches on; a remote or peer source "
              "would need a direct copy between the two — do that directly",
              file=sys.stderr)
        sys.exit(2)
    if not results:
        print("  --up: no matches")
    elif not o_rcl and not o_rsh:
        # local -> local: move, tree preserved; refuse before touching anything
        absp=[os.path.abspath(q) for q in results]
        root=os.path.commonpath([os.path.dirname(q) for q in absp])
        dsts=[os.path.join(o_dir, os.path.relpath(q, root)) for q in absp]
        pre=[d for d in dsts if os.path.exists(d)]
        if pre:
            print("  --up ABORTED: target(s) already exist; nothing moved", file=sys.stderr)
            for t in pre[:20]: print(f"    exists: {t}", file=sys.stderr)
            sys.exit(3)
        total=len(absp)
        for i,(src,dst) in enumerate(zip(absp,dsts), 1):
            os.makedirs(os.path.dirname(dst), exist_ok=True)
            shutil.move(src, dst)
            sys.stderr.write("\r  --up (move) "+_bar(i,total)+"   "); sys.stderr.flush()
        sys.stderr.write("\n")
        print(f"  --up: moved {total} file(s)  {root} -> {o_dir}")
    elif o_rsh:
        # local -> peer: copy, tree preserved, same as the rclone upload
        absp=[os.path.abspath(q) for q in results]
        root=os.path.commonpath([os.path.dirname(q) for q in absp])
        rels=[os.path.relpath(q, root) for q in absp]
        dest=peer_home()+("/"+o_dir if o_dir else "")
        r=_ssh("mkdir -p -- "+shlex.quote(dest))
        if r.returncode!=0:
            print(f"  --up: could not create $/{o_dir}: {r.stderr.strip()}", file=sys.stderr)
            sys.exit(3)
        lf=_relfile(rels)
        print(f"  --up: {len(rels)} file(s)  {root} -> $/{o_dir}")
        rc=subprocess.call(["rsync","-a","-s","--info=progress2","-e",RSH,
                            "--files-from",lf,root+"/",PEER+":"+dest+"/"])
        os.unlink(lf)
        if rc!=0:
            print(f"  --up: rsync exited {rc}", file=sys.stderr); sys.exit(3)
        print(f"  --up: {len(rels)} file(s)")
    else:
        # Stage the relpaths against the common parent of the sources, so the
        # tree the user matched is what lands on the remote — not a flat dump
        # and not a mirror of the absolute local path.
        absp=[os.path.abspath(q) for q in results]
        root=os.path.commonpath([os.path.dirname(q) for q in absp])
        rels=[os.path.relpath(q, root) for q in absp]
        with tempfile.TemporaryDirectory() as td:
            for src, rel in zip(absp, rels):
                dst=os.path.join(td, rel)
                os.makedirs(os.path.dirname(dst), exist_ok=True)
                # symlink is enough — rclone follows it to the real file
                try: os.symlink(src, dst)
                except OSError: shutil.copy2(src, dst)
            lf=_relfile(rels)
            print(f"  --up: {len(rels)} file(s)  {root} -> {o_dir}")
            rc=subprocess.call(["rclone","copy",td,o_dir,
                                "--files-from-raw",lf,
                                "--copy-links","-P"])
            os.unlink(lf)
            if rc!=0:
                print(f"  --up: rclone exited {rc}", file=sys.stderr); sys.exit(3)
            print(f"  --up: {len(rels)} file(s)")


# ---- history ---------------------------------------------------------------
# Every call stashes its raw paths, whether or not --list was passed, so a
# result can be reused without re-running the search.  This is a record of
# what was returned, NOT a cache: the next search still queries live.
def _stash(res, dirtok, pat, maxd):
    import time as _t
    d=os.environ.get("SEARCH_HIST_DIR") or os.path.expanduser("~/.search_hist")
    try: os.makedirs(d, exist_ok=True)
    except OSError: return
    ts=_t.strftime("%Y%m%d-%H%M%S", _t.localtime())
    idx=os.path.join(d,"index.tsv")
    q=f"{dirtok} {pat}" + (f"  --max {maxd}" if maxd is not None else "")
    slug=re.sub(r"[^A-Za-z0-9._-]+","_",q).strip("_")[:60]
    fn=os.path.join(d,f"{ts}-{slug}.txt")
    try:
        with open(fn,"w") as fh:
            fh.write("\n".join(res) + ("\n" if res else ""))
        with open(idx,"a") as fh:
            fh.write(f"{ts}\t{len(res)}\t{q}\t{fn}\n")
        lp=os.path.join(d,"last.txt")
        tmp=lp+".tmp"
        with open(tmp,"w") as fh:
            fh.write("\n".join(res) + ("\n" if res else ""))
        os.replace(tmp,lp)
    except OSError:
        pass

if os.environ.get("SEARCH_HISTORY", "1") != "0":
    _stash(results, ("$/" + g_dir) if g_rsh else g_dir, g_pat, g_max)
PYEOF
}

# ---- search history --------------------------------------------------------
# lastsearch          raw paths from the most recent search
# searchhist [N]      the last N runs, numbered, newest first
# searchget N         raw paths from run N as numbered by searchhist
# searchdiff A B [D]  compare two runs on their last D path components
#                     (default 3), so a remote result and a local one line up

lastsearch() {
  local f="$SEARCH_HIST_DIR/last.txt"
  [[ -s "$f" ]] || { echo "lastsearch: no history yet" >&2; return 1; }
  cat "$f"
}

# tac is GNU-only; macOS and the BSDs have 'tail -r'.  Resolved once here so
# the history functions below do not each have to care.
_search_tac() {
  if command -v tac >/dev/null 2>&1; then tac "$@"
  else tail -r "$@"; fi
}

searchhist() {
  local n="${1:-15}" idx="$SEARCH_HIST_DIR/index.tsv"
  [[ -s "$idx" ]] || { echo "searchhist: no history yet" >&2; return 1; }
  _search_tac "$idx" | head -n "$n" | awk -F'\t' \
    '{printf "%3d  %-18s %6s  %s\n", NR, $1, $2, $3}'
}

_search_hist_path() {
  local n="$1" idx="$SEARCH_HIST_DIR/index.tsv"
  [[ -s "$idx" ]] || return 1
  _search_tac "$idx" | sed -n "${n}p" | cut -f4
}

searchget() {
  [[ -n "$1" ]] || { echo "usage: searchget N   (see searchhist)" >&2; return 2; }
  local f; f="$(_search_hist_path "$1")"
  [[ -n "$f" && -f "$f" ]] || { echo "searchget: no run $1" >&2; return 1; }
  cat "$f"
}

searchdiff() {
  [[ -n "$2" ]] || { echo "usage: searchdiff A B [depth]   (see searchhist)" >&2; return 2; }
  local a b d="${3:-3}"
  a="$(_search_hist_path "$1")"; b="$(_search_hist_path "$2")"
  [[ -f "$a" && -f "$b" ]] || { echo "searchdiff: bad run number" >&2; return 1; }
  # compare on the path tail: a remote path and a local one share their last
  # few components but never their prefix, so full-string comparison is useless
  local ta tb
  ta=$(mktemp); tb=$(mktemp)
  awk -v d="$d" -F/ '{s="";for(i=(NF-d+1>1?NF-d+1:1);i<=NF;i++)s=s (s==""?"":"/") $i; print s}' "$a" | sort -u > "$ta"
  awk -v d="$d" -F/ '{s="";for(i=(NF-d+1>1?NF-d+1:1);i<=NF;i++)s=s (s==""?"":"/") $i; print s}' "$b" | sort -u > "$tb"
  echo "--- only in run $1 ($(comm -23 "$ta" "$tb" | wc -l)) ---"
  comm -23 "$ta" "$tb"
  echo "--- only in run $2 ($(comm -13 "$ta" "$tb" | wc -l)) ---"
  comm -13 "$ta" "$tb"
  echo "--- in both ($(comm -12 "$ta" "$tb" | wc -l)) ---"
  rm -f "$ta" "$tb"
}

# ---- searchsave ------------------------------------------------------------
# searchsave                 list what has been saved
# searchsave N NAME [DIR]    write run N's paths to DIR/NAME.txt
#                            (DIR defaults to $SEARCH_SAVE_DIR)
#   --pipe   REMOTE:PATH     upload the .txt there, then delete the local copy
#   --pipecp REMOTE:PATH     same, but keep the local copy

searchsave() {
  if [[ -z "${1:-}" ]]; then
    mkdir -p "$SEARCH_SAVE_DIR"
    ls -la "$SEARCH_SAVE_DIR" 2>/dev/null | tail -n +4
    return 0
  fi
  local n="$1" name="${2:-}" dest="" keep=0 outdir="$SEARCH_SAVE_DIR"
  [[ -n "$name" ]] || { echo "usage: searchsave N NAME [DIR] [--pipe|--pipecp REMOTE:PATH]" >&2; return 2; }
  shift 2
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --flat) ;;   # accepted for compatibility: output is always a flat list
      --pipe|--pipecp)
        [[ "$1" == "--pipecp" ]] && keep=1
        shift
        [[ -n "${1:-}" ]] || { echo "searchsave: needs REMOTE:PATH" >&2; return 2; }
        dest="$1"
        [[ "$dest" =~ ^[A-Za-z0-9_][A-Za-z0-9_+.-]*: ]] || {
          echo "searchsave: '$dest' is not an rclone remote (want remote:path)" >&2
          return 2; } ;;
      -*) echo "searchsave: unknown flag '$1'" >&2; return 2 ;;
      *)  outdir="$(_search_tilde "$1")"; outdir="${outdir%/}" ;;
    esac
    shift
  done
  local src; src="$(_search_hist_path "$n")"
  [[ -n "$src" && -f "$src" ]] || { echo "searchsave: no run $n (see searchhist)" >&2; return 1; }
  mkdir -p "$outdir" || return 1
  local dst="$outdir/${name%.txt}.txt"
  cp -- "$src" "$dst" || return 1
  printf "%s  (%s lines)\n" "$dst" "$(wc -l < "$dst" | tr -d ' ')"

  if [[ -n "$dest" ]]; then
    local op="move"; (( keep )) && op="copy"
    rclone "$op" "$dst" "$dest" --progress || {
      echo "searchsave: rclone $op failed for $dst" >&2; return 3; }
    printf "  %s -> %s/%s\n" "$op" "$dest" "$(basename "$dst")"
  fi
}

# ---- saved base paths ------------------------------------------------------

_spath_get() {
  [[ -f "$SEARCH_PATHS" ]] || return 1
  awk -F'\t' -v n="$1" '$1==n {print $2; found=1} END{exit !found}' "$SEARCH_PATHS"
}

_spath_expand() {
  # @name or @name/rest -> <path>/rest
  local tok="$1"
  [[ "$tok" == @* ]] || { printf '%s' "$tok"; return; }
  local body="${tok#@}" name rest p
  name="${body%%/*}"
  rest=""
  [[ "$body" == */* ]] && rest="${body#*/}"
  if p="$(_spath_get "$name")"; then
    [[ -n "$rest" ]] && printf '%s/%s' "${p%/}" "$rest" || printf '%s' "$p"
  else
    echo "search: no saved path '$name' (search --lpath)" >&2
    printf '%s' "$tok"
  fi
}

# ---- ~ -> $HOME at the start of a path token ------------------------------
_search_tilde() {
  case "$1" in
    "~")   printf '%s' "$HOME" ;;
    "~/"*) printf '%s/%s' "$HOME" "${1#"~/"}" ;;
    *)     printf '%s' "$1" ;;
  esac
}

# ---- search --help ----------------------------------------------------------
_search_help() {
cat << 'HELP'
search - find files by a glob-ish pattern, locally, on an rclone remote, or on
         an ssh peer, and optionally copy, move or upload what it finds.

SYNTAX
  search [savedname] 'DIR PATTERN' [--list] [--max K] [--get DEST | --up DEST]

  DIR and PATTERN are ONE quoted string: the dir token, a space, the file pattern.
  DIR is local (./x, /abs, ~/x), an rclone remote (remote:path), or an ssh
  peer ($/x, $N/x).
  A leading ~ in DIR or DEST means $HOME.
  A leading $ means the default peer's home (SEARCH_PEER=user@host);
  $N means host N from the remote registry.  The password is asked once
  per terminal, per peer.

PATTERN GRAMMAR (applies to dir components and file names)
  *          any run of characters
  (abc)      one char from the set, repeated to the set's length
  ^(abc)     one char NOT in the set, same length rule
  [a|b|c]    whole-string choice, e.g. ses-[02|03]

FLAGS
  --list       bare paths instead of the tree (for piping)
  --max K      walk at most K levels below the resolved dir (0 = files directly in it)
  --get DEST   copy matches into local DEST, tree preserved, existing files skipped
                 remote -> local: rclone download     peer -> local: rsync
                 local -> local: copy
  --up DEST    send matches on, tree preserved
                 local -> remote: rclone upload       local -> peer: rsync copy
                 local -> local: move (aborts if any target already exists)
  --$          list the peers available as $N
  -h, --help   this text

SAVED PATHS
  search --spath "gdrive:projects/data" prj    save a base path as 'prj'
  search --lpath                               list saved paths
  search --rmpath prj                          remove one
  search prj 'raw/* *.csv'                     saved name first: prefixes the dir
  search '@prj/raw/* *.csv'                    @name inside the dir token

HISTORY
  lastsearch                     paths from the most recent search
  searchhist [N]                 the last N runs, newest first (1 = newest)
  searchget N                    paths from run N
  searchdiff A B [depth]         compare two runs on their last path components
  searchsave N NAME [DIR]        write run N's paths to a file
  SEARCH_HISTORY=0 search ...    run without recording history

EXAMPLES
  search './ *'                                  everything under the current dir
  search './ *.py' --max 0                       .py files directly in the current dir
  search '~/data/sub-* *.nii*' --max 3           NIfTIs in sub-* folders, tree view
  search 'gdrive:raw *.edf' --get ~/raw          download from a remote
  search '~/data *.csv' --get ~/backup           local copy
  search '~/results *' --up gdrive:results       upload to a remote
  search '~/scratch *.log' --up ~/logs           local move
  search '$/project *.csv'                       list on the default peer
  search '$2/project *.csv' --get ~/incoming     peer 2 -> local
  search '~/outgoing *.zip' --up '$2/inbox'      local -> peer 2
HELP
}
