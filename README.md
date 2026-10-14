# termkit

Small bash tools that make the terminal faster to live in: find and move files
across your machine, cloud remotes and other computers with one command; keep
ssh hosts by name; open files and images straight from the shell; paste Python
from anywhere and run it cleanly.

| Command  | What it does |
|----------|--------------|
| `search` | Find files by pattern — locally, on any [rclone](https://rclone.org) remote, or on an ssh peer — and copy, move or upload what it finds. Keeps a history of every search. |
| `remote` | Register ssh hosts once, then connect by name (`remote -lab`, or just `lab`) or by number. |
| `run`    | Open files in their default app; arrow through a set of images. |
| `wrap`   | Paste Python into the terminal; smart quotes, HTML entities and other paste debris are cleaned before it runs. |

Works on Linux, macOS and WSL.

---

## Install

**From a zip:** download it, unzip it somewhere permanent, then:

```bash
cd termkit          # or termkit-main, if GitHub named it that
bash init.sh
```

**With git:**

```bash
git clone <repo-url> ~/termkit
cd ~/termkit && bash init.sh
```

`init.sh` asks which tools you want and sets each one up. Then open a new
terminal (or `source ~/.bashrc`).

| Command | Effect |
|---------|--------|
| `bash init.sh` | Pick what to set up from a menu, with a few questions for each. |
| `bash init.sh --all` | Set up everything, no questions. |
| `bash init.sh search remote` | Set up just the named tools. |
| `bash init.sh --status` | What is enabled, where things live. |
| `bash init.sh --remove run` | Disable a tool. |
| `bash init.sh --uninstall` | Disable everything and remove the line from your shell rc. |

Setup adds one block to your `~/.bashrc` (`~/.bash_profile` on macOS) that
loads the enabled tools in every new shell. **Keep the folder where it is**;
if you move it, run `bash init.sh` again from the new place and the block is
updated. Running it again never duplicates anything.

### Requirements

- **bash 4 or newer.** Linux and WSL have it. macOS ships bash 3.2:
  `brew install bash`, then run init with `/opt/homebrew/bin/bash init.sh`.
- **python3** for `search` and `wrap`.
- **ssh** for `remote` and for `search` on peers.
- Optional: **rclone** (search cloud remotes), **rsync** (transfers with ssh
  peers), **feh** (image cycling for `run`).

`init.sh` checks these and tells you what is missing.

---

## search

```text
search [savedname] 'DIR PATTERN' [--list] [--max K] [--get DEST | --up DEST]
```

`DIR` and `PATTERN` are **one quoted string**: the directory, a space, then the
file pattern. Quoting stops the shell from expanding the pattern first.

```bash
search '~/data *.csv'            # every .csv under ~/data, shown as a tree
search './ *.py' --max 0         # .py files directly in the current directory
```

### Where it can look

| DIR | Meaning |
|-----|---------|
| `./x`, `/abs/path` | Local directory. |
| `~/x` | Local; a leading `~` means `$HOME` (in `DEST` too). |
| `remote:path` | Any configured rclone remote, e.g. `gdrive:projects`. |
| `$/x` | The default ssh peer's home (`SEARCH_PEER=user@host`). |
| `$N/x` | Host number `N` from `remote`'s list. `search --$` shows the numbers. |

A peer's password is asked once per terminal and remembered per peer.

### Patterns

The grammar applies to folder names as well as file names, so a pattern can
pick folders on the way down.

| Pattern | Matches |
|---------|---------|
| `*` | Any run of characters. |
| `(abc)` | One character from the set, repeated to the set's length: `run-(12)` matches `run-11`, `run-12`, `run-21`, `run-22`. |
| `^(abc)` | One character *not* in the set, same length rule. |
| `[a\|b\|c]` | A whole-string choice: `ses-[02\|03]` matches `ses-02` or `ses-03`. |

```bash
search '~/data/sub-* *.nii*'         # NIfTIs inside any sub-* folder
search '~/data ses-[02|03]*.csv'     # only session 02 and 03 files
```

### Flags

| Flag | Effect |
|------|--------|
| `--list` | Bare paths, one per line, for piping into other commands. |
| `--max K` | Look at most `K` levels below `DIR`; `0` means only files directly in it. |
| `--get DEST` | Copy the matches into local `DEST`, keeping the folder tree; existing files are skipped. |
| `--up DEST` | Send the matches to `DEST`, keeping the folder tree. |

### Moving files

Where `DIR` and `DEST` point decides the direction; search picks the tool.

| | Direction | Done with |
|---|---|---|
| `--get` | remote → local | rclone |
| | peer → local | rsync |
| | local → local | copy |
| `--up` | local → remote | rclone |
| | local → peer | rsync |
| | local → local | **move** (stops if any target already exists) |

```bash
search 'gdrive:raw *.edf' --get ~/raw          # download from a remote
search '~/data *.csv' --get ~/backup           # local copy
search '~/results *' --up gdrive:results       # upload to a remote
search '~/scratch *.log' --up ~/logs           # local move
search '$2/project *.csv' --get ~/incoming     # peer 2 -> local
search '~/outgoing *.zip' --up '$2/inbox'      # local -> peer 2
```

Only the matches are transferred, so the pattern is what scopes a transfer.
Run the search without `--get`/`--up` first to see exactly what would move.

### Saved paths

```bash
search --spath "gdrive:projects/data" prj    # save a base path as 'prj'
search --lpath                               # list saved paths
search --rmpath prj                          # remove one
search prj 'raw/* *.csv'                     # saved name first: prefixes the dir
search '@prj/raw/* *.csv'                    # or @name inside the dir
```

### History

Every search is recorded, so a slow listing — a whole cloud drive, say — can
be reused instead of repeated. Runs are numbered newest first.

| Command | Effect |
|---------|--------|
| `searchhist [N]` | The last `N` runs (default 15). |
| `lastsearch` | Paths from the most recent run. |
| `searchget N` | Paths from run `N`, ready to pipe. |
| `searchdiff A B [depth]` | Compare two runs on their last `depth` path components (default 3), so a remote listing and a local one line up. |
| `searchsave N NAME [DIR]` | Write run `N`'s paths to `DIR/NAME.txt` (default: the saved folder). `--pipe remote:path` uploads it instead; `--pipecp` uploads and keeps a local copy. |
| `SEARCH_HISTORY=0 search ...` | Run without recording. |

```bash
search 'gdrive:archive *'              # one slow full listing
searchhist 3                           # find its number
searchget 1 | grep -c '\.mp3$'         # reuse it without listing again
searchsave 1 archive_list ~/lists      # keep it as a file
```

---

## remote

```bash
remote --add          # register a host: asks for a name, user and host/IP
remote -list          # numbered list (these are search's $1, $2, ...)
remote -lab           # ssh to 'lab'
lab                   # same: every host becomes a command of its own name
lab 'df -h'           # run a command there
remote                # ssh to the default host
remote --change       # change a host's address
remote --remove lab   # forget a host
```

The default host is `REMOTE_DEFAULT` if set, otherwise the first one
registered. A host whose name collides with an existing command gets no
shortcut; reach it with `remote -NAME`.

---

## run

```bash
run *.png                              # cycle through images with the arrow keys
run --view report.pdf                  # open in the default app
search './plots *.png' --list | run    # open whatever search found
```

Images use `feh` when installed. Otherwise they open in the system viewer;
on WSL they are gathered into one Windows folder first so Photos can arrow
through all of them.

---

## wrap

```bash
wrap            # paste a script, press Ctrl-D, it runs
wrap 3          # paste three scripts (Ctrl-D after each); all are
                # syntax-checked before any runs, and they run in order
wrap 2 a b , c  # arguments per script, separated by commas
```

Before running, `wrap` undoes what copying from browsers, PDFs and chat
windows does to code: HTML entities (`&gt;`), smart quotes, long dashes,
non-breaking and zero-width spaces, Windows line endings. If anything fails
to parse, nothing runs and the cleaned file is kept for inspection.

---

## Configuration

Everything termkit keeps is in one folder, `~/.config/termkit/`:

| File | Holds |
|------|-------|
| `modules` | Which tools are enabled. |
| `env` | Your settings, loaded in every shell. |
| `hosts` | `remote`'s hosts (tab-separated: name, user, host). |
| `search_paths` | Saved base paths. |
| `history/` | search history. |
| `saved/` | Lists written by `searchsave`. |

Settings you can put in `env` (init writes some of them for you):

| Variable | Effect |
|----------|--------|
| `SEARCH_PEER` | Default peer for `$` paths, as `user@host`. |
| `REMOTE_DEFAULT` | Host used by a bare `remote`. |
| `REMOTE_SSH_OPTS` | Extra ssh options, e.g. `-X` for graphical apps. |
| `SEARCH_PROGRESS=0` | Hide transfer progress bars. |
| `TK_CONFIG` | Use a different config folder (set before the rc block). |

---

## Adding your own tools

- **Executables:** drop a script into `bin/`. It is on your `PATH` in every
  new shell; run `bash init.sh --all` once to mark it executable.
- **Shell functions:** add `lib/NAME.sh`, add `NAME` to the `MODULES` list
  (with a description) at the top of `init.sh`, then `bash init.sh NAME`.

---

## Notes

- **Windows machines as ssh peers:** the peer's OpenSSH server must start
  WSL as its shell, so `$` paths resolve against the WSL home.
- **zsh:** the tools are bash. From zsh, run `bash` first, or make bash your
  shell; the autoload block does nothing outside bash rather than breaking.
- **Uninstalling** keeps your hosts and history. Delete `~/.config/termkit`
  to remove those too.
