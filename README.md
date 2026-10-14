# termkit

Small bash tools that make the terminal faster to live in. Find and move files
across your machine, cloud remotes and other computers with one command; keep
ssh hosts by name; open files and images straight from the shell; paste Python
from anywhere and run it cleanly.

Works on Linux, macOS and WSL.

## Table of contents

- **A.** Installing
- **B.** How the folders are laid out
- **C.** Finding files with `search`
- **D.** Moving files with `search`
- **E.** Saved paths and search history
- **F.** ssh hosts with `remote`
- **G.** `run` and `wrap`
- **H.** Configuration
- **I.** Adding your own tools

---

## A. Installing

1. Download the zip, unzip it somewhere permanent (or `git clone` the repo),
   and move into the folder:

   ```bash
   cd termkit          # or termkit-main / OrganizePile, whatever the folder is called
   ```

2. Run the setup script:

   ```bash
   bash init.sh
   ```

   It lists the tools, asks which ones you want, and asks a couple of
   questions for each (a default ssh peer for `search`, hosts for `remote`).

3. Open a new terminal, or reload the current one:

   ```bash
   source ~/.bashrc
   ```

4. Check it worked: `search --help`.

Other ways to run setup:

- `bash init.sh --all` — set up everything, no questions
- `bash init.sh search remote` — set up only the named tools
- `bash init.sh --status` — what is enabled, where things live
- `bash init.sh --remove run` — disable one tool
- `bash init.sh --uninstall` — disable everything and remove the line from your shell rc

\*Setup adds one block to `~/.bashrc` (`~/.bash_profile` on macOS) that loads
the tools in every new shell. **Keep the folder where it is.** If you move it,
run `bash init.sh` again from the new place and the block is updated. Running
setup again never duplicates anything.

### Requirements

- **bash 4 or newer.** Linux and WSL have it. macOS ships bash 3.2:
  `brew install bash`, then run setup with `/opt/homebrew/bin/bash init.sh`.
- **python3** for `search` and `wrap`.
- **ssh** for `remote`, and for `search` on other computers.
- Optional: **rclone** (cloud remotes), **rsync** (transfers to other
  computers), **feh** (image viewing for `run`).

`init.sh` checks these and tells you what is missing.

---

## B. How the folders are laid out

### The toolkit folder

```text
termkit/
├── init.sh        setup: run once after downloading, again to add tools
├── autoload.sh    loaded by your shell at startup; turns the tools on
├── lib/           the tools themselves, one file each
│   ├── search.sh
│   ├── remote.sh
│   ├── run.sh
│   └── wrap.sh
├── bin/           your own executable scripts; this folder is put on your PATH
└── README.md
```

The files in `lib/` are **sourced**, not run: your shell reads them at startup
and the commands inside (`search`, `remote`, …) become available like built-in
commands. That is why they work in any directory without typing a path.

### Where your own data lives

Nothing personal is stored in the toolkit folder, so it can be shared or
updated freely. Everything the tools remember goes in one place:

```text
~/.config/termkit/
├── modules        which tools are turned on
├── env            your settings (default peer, ssh options, ...)
├── hosts          remote's saved hosts
├── search_paths   search's saved base paths
├── history/       every search you have run
└── saved/         lists written by searchsave
```

### Some terminology

***Directory*** — a folder. Every directory sits inside another one, up to the
root `/`. `~` is shorthand for your home directory (`/home/<user>`).

***Path*** — the walk from one directory down to a file, each step separated
by `/`: `project/sub-01/ses-01/anat`.

***Pattern*** — a path where some parts are left open, so it describes many
paths at once. `sub-*` stands for every folder starting with `sub-`.

***Remote*** — storage reached through rclone, written `name:path`
(`gdrive:projects`).

***Peer*** — another computer reached over ssh, written `$` (your default) or
`$N` (host number N from `remote -list`).

### The example folder

The examples below all use this small project. Three participants, two
sessions each, an `anat`, `eeg` and `beh` folder per session:

```text
project/
├── README.txt
├── participants.tsv
├── sub-01/
│   ├── ses-01/
│   │   ├── anat/   sub-01_ses-01_T1w.nii.gz
│   │   ├── beh/    sub-01_ses-01_task-rest_beh.csv
│   │   └── eeg/    sub-01_ses-01_task-rest_eeg.vhdr  .vmrk  .eeg
│   └── ses-02/     (same layout)
├── sub-02/         (same layout)
└── sub-03/         (same layout)
```

---

## C. Finding files with `search`

The form to use search |

```text
search '<directory> <file pattern>' [flags]
```

The directory and the file pattern go inside **one pair of quotes**,
separated by a space. The quotes stop the shell from expanding `*` before
search sees it. Start a relative directory with `./`.

- `*` — any run of characters | `*.csv`
- `[a|b]` — a choice between whole words | `sub-[01|03]`
- `(abc)` — one character from the set, repeated to the set's length |
  `ses-(01)` matches `ses-00`, `ses-01`, `ses-10`, `ses-11`
- `^(abc)` — one character *not* in the set, same length rule

The pattern rules work on **folder names too**, so a single search can pick
which folders to walk into as well as which files to keep.

Flags:

- `--list` — print bare paths instead of the tree, for passing to other commands
- `--max K` — look at most K folders deep; `--max 0` means only files directly in the directory

In this example — *What is at the top of the project?*

a. `--max 0` keeps the search from walking into any subfolder

```console
$ search './project *' --max 0
  dir './project'  file *  [max 0]
  └── .
      └── project
          ├── README.txt
          └── participants.tsv
  (2 match(es))
```

In this example — *Every participant's session-2 anatomical scan*

a. `sub-*` matches all three participant folders

b. `ses-02/anat` then walks straight into one session and one folder

c. `*.nii.gz` keeps only the images

```console
$ search './project/sub-*/ses-02/anat *.nii.gz'
  dir './project/sub-*/ses-02/anat'  file *.nii.gz
  └── .
      └── project
          ├── sub-01
          │   └── ses-02
          │       └── anat
          │           └── sub-01_ses-02_T1w.nii.gz
          ├── sub-02
          │   └── ses-02
          │       └── anat
          │           └── sub-02_ses-02_T1w.nii.gz
          └── sub-03
              └── ses-02
                  └── anat
                      └── sub-03_ses-02_T1w.nii.gz
  (3 match(es))
```

In this example — *Only some participants*

a. `[01|03]` is a choice: participant 01 or 03, nothing else

```console
$ search './project/sub-[01|03]/ses-01/eeg *.vhdr'
  dir './project/sub-[01|03]/ses-01/eeg'  file *.vhdr
  └── .
      └── project
          ├── sub-01
          │   └── ses-01
          │       └── eeg
          │           └── sub-01_ses-01_task-rest_eeg.vhdr
          └── sub-03
              └── ses-01
                  └── eeg
                      └── sub-03_ses-01_task-rest_eeg.vhdr
  (2 match(es))
```

In this example — *Using the results in other commands*

a. `--list` prints one path per line, which other commands can read

b. piped to `wc -l` it counts the matches

c. read into an array with `mapfile`, each path can be used in a loop

```console
$ search './project *.vhdr' --list | wc -l
6

$ mapfile -t T1 < <(search './project *T1w.nii.gz' --list)
$ echo ${#T1[@]} files; echo "first: ${T1[0]}"
6 files
first: ./project/sub-01/ses-01/anat/sub-01_ses-01_T1w.nii.gz

$ for f in "${T1[@]}"; do echo "processing $f"; done
```

### Searching other places

The same command searches anywhere, just by changing how the directory is
written:

- `./x`, `/abs/path`, `~/x` — this computer
- `remote:path` — a cloud remote set up in rclone | `search 'gdrive:raw *.edf'`
- `$/x` — your default peer's home folder | `search '$/project *.csv'`
- `$N/x` — host number N from `remote -list` | `search '$2/project *.csv'`

A peer's password is asked once per terminal and remembered for that peer.

---

## D. Moving files with `search`

Add a destination to any search and it moves what it found:

- `--get DEST` — copy the matches into a folder on **this** computer.
  Files already there are skipped.
- `--up DEST` — send the matches somewhere else. To a remote or a peer this
  copies; **between two folders on this computer it moves**.

The folder structure is kept, so the copies land in the same
`sub-*/ses-*/...` layout they came from. search chooses the right tool for
each direction:

| Flag | From → to | Uses |
|------|-----------|------|
| `--get` | remote → here | rclone |
| | peer → here | rsync |
| | here → here | copy |
| `--up` | here → remote | rclone |
| | here → peer | rsync |
| | here → here | **move** (stops if a target file already exists) |

\*Only what matched is moved, so the pattern decides what goes. **Run the
search without `--get`/`--up` first**, look at the tree, then add the flag.

In this example — *Copy every session-1 scan to a working folder*

a. the search finds the three files and shows them

b. `--get ~/anat_ses01` copies them, keeping each one's `sub-*/ses-*` folders

```console
$ search './project/sub-*/ses-01/anat *.nii.gz' --get ~/anat_ses01
  ...tree of the 3 matches...
  --get: copied 3, skipped 0 already present  /home/you/project -> /home/you/anat_ses01

$ find ~/anat_ses01 -type f
/home/you/anat_ses01/sub-01/ses-01/anat/sub-01_ses-01_T1w.nii.gz
/home/you/anat_ses01/sub-02/ses-01/anat/sub-02_ses-01_T1w.nii.gz
/home/you/anat_ses01/sub-03/ses-01/anat/sub-03_ses-01_T1w.nii.gz
```

In this example — *Tidy log files into their own folder*

a. `--up` between two local folders **moves**, so `scratch` keeps only what
   did not match

```console
$ search './scratch *.log' --up ./logs
  dir './scratch'  file *.log
  └── .
      └── scratch
          ├── run1.log
          └── run2.log
  (2 match(es))
  --up: moved 2 file(s)  /home/you/scratch -> ./logs

$ ls scratch logs
logs:
run1.log  run2.log

scratch:
notes.txt
```

More directions, same form:

```bash
search 'gdrive:raw *.edf' --get ~/raw            # download from a cloud remote
search '~/results *' --up gdrive:results         # upload to it
search '$2/project *.csv' --get ~/incoming       # copy from another computer
search '~/outgoing *.zip' --up '$2/inbox'        # send to another computer
```

---

## E. Saved paths and search history

### Saved paths

A long base path can be stored under a short name:

- `search --spath PATH NAME` — save | `search --spath ~/data/project proj`
- `search --lpath` — list saved paths
- `search --rmpath NAME` — remove one

In this example — *Using a saved path*

a. save the project folder as `proj`

b. put the name first, and it is put in front of the directory

c. or write `@proj` inside the directory itself

```console
$ search --spath ~/data/project proj
proj             /home/you/data/project

$ search proj 'sub-02/* *.csv' --list
/home/you/data/project/sub-02/ses-01/beh/sub-02_ses-01_task-rest_beh.csv
/home/you/data/project/sub-02/ses-02/beh/sub-02_ses-02_task-rest_beh.csv

$ search '@proj/sub-0(1)/ses-02 *.vhdr' --list
/home/you/data/project/sub-01/ses-02/eeg/sub-01_ses-02_task-rest_eeg.vhdr
```

### History

Every search is recorded, so a slow one (a whole cloud drive) can be reused
instead of run again. Runs are numbered **newest first**.

- `searchhist [N]` — the last N runs (default 15)
- `lastsearch` — the paths from the most recent run
- `searchget N` — the paths from run N, ready to pipe
- `searchdiff A B [depth]` — what differs between two runs, compared on the
  last `depth` parts of each path (default 3), so a cloud listing and a local
  one still line up
- `searchsave N NAME [DIR]` — write run N's paths to a file
- `SEARCH_HISTORY=0 search ...` — run without recording

In this example — *Which file went missing?*

a. count the behaviour files: 6

b. something removes one; count again: 5

c. `searchhist` shows both runs, newest as 1

d. `searchdiff 2 1` names exactly which file the newer run lacks

e. `searchsave` keeps the current list as a file

```console
$ search './project *.csv' --list | wc -l
6
$ search './project *.csv' --list | wc -l
5

$ searchhist
  1  20261014-211110         5  ./project *.csv
  2  20261014-211110         6  ./project *.csv

$ searchdiff 2 1
--- only in run 2 (1) ---
ses-02/beh/sub-03_ses-02_task-rest_beh.csv
--- only in run 1 (0) ---
--- in both (5) ---

$ searchsave 1 beh_files ./lists
./lists/beh_files.txt  (5 lines)
```

\*`searchsave` can also send the file to a cloud remote:
`--pipe remote:path` uploads it and removes the local copy, `--pipecp`
uploads and keeps it.

---

## F. ssh hosts with `remote`

`remote` keeps a list of the computers you connect to, so you never retype a
user and address.

- `remote --add` — save a host; asks for a name, user and address
- `remote -list` — numbered list of hosts (these numbers are search's `$N`)
- `remote -NAME` — connect | `remote -lab`
- `NAME` — the same: every saved host becomes a command | `lab`
- `NAME 'command'` — run something there without logging in | `lab 'df -h'`
- `remote` — connect to the default host
- `remote --change` — change a host's address
- `remote --remove NAME` — forget a host

In this example — *Saving two machines and using them*

a. add each host once

b. `remote -list` numbers them; `search --$` shows the same numbers

c. `lab` now logs in, and `$2` in a search means `gpu`

```console
$ remote --add
name: lab
user: alice
host (IP or hostname): 192.168.1.20
added: lab -> alice@192.168.1.20

$ remote -list
   1  lab          alice@192.168.1.20
   2  gpu          bob@gpu.example.org

$ search --$
  peers ($N):
   1  lab        alice@192.168.1.20
   2  gpu        bob@gpu.example.org

$ lab                                   # logs in to 192.168.1.20
$ search '$2/results *.csv' --get ~/res # copies from gpu
```

\*The default host is `REMOTE_DEFAULT` if set (see H), otherwise the first
one saved. A host whose name clashes with an existing command gets no
shortcut; use `remote -NAME` for it.

---

## G. `run` and `wrap`

### run — open files from the terminal

- `run FILES` — images open in a viewer you can arrow through; anything else
  opens in its default app | `run *.png`
- `run --view FILE` — open in the default app | `run --view report.pdf`

In this example — *Look at every plot a script produced*

a. search finds the images, `--list` prints them, `run` opens them as one set

```bash
search './plots *.png' --list | run
```

\*Images use `feh` if installed; otherwise the system viewer. On WSL the
images are gathered into one Windows folder first so Photos can arrow through
all of them.

### wrap — paste Python and run it

Code copied from a browser, a PDF or a chat window often carries invisible
damage: curly quotes, `&gt;` instead of `>`, non-breaking spaces. Python
refuses to run it. `wrap` cleans that, checks the syntax, then runs it.

- `wrap` — paste one script, press Ctrl-D, it runs
- `wrap N` — paste N scripts (Ctrl-D after each); all are checked before any
  runs, then they run in order, stopping at the first failure
- `wrap 2 a b , c` — arguments for each script, separated by commas

In this example — *Code pasted from a web page*

a. the pasted line has curly quotes and `&gt;`, which Python cannot read

b. wrap converts them, the syntax check passes, the script runs

```console
$ wrap
wrap: paste Python, then Ctrl-D to run
print(“hello from wrap”, 2 &gt; 1)
wrap: syntax OK for all 1; executing in order
----- wrap: running script 1/1 -----
hello from wrap True
```

If a script still fails to parse, **nothing runs** and the cleaned file is
kept so you can see what went wrong.

---

## H. Configuration

Settings go in `~/.config/termkit/env`, which every new shell reads.
Setup writes some of these for you; edit the file to change them.

- `SEARCH_PEER=user@host` — the computer `$` means in search
- `REMOTE_DEFAULT=NAME` — the host a bare `remote` connects to
- `REMOTE_SSH_OPTS="-X"` — extra ssh options (`-X` lets graphical programs on
  the other computer open windows here)
- `SEARCH_PROGRESS=0` — hide transfer progress bars
- `TK_CONFIG=/other/folder` — keep the data folder somewhere else (set it
  before the termkit block in your rc file)

---

## I. Adding your own tools

- **A script you run by name:** put it in `bin/`. That folder is on your
  PATH, so it works from anywhere in a new terminal. Run `bash init.sh --all`
  once to mark it executable.
- **A shell function (like `search`):** add `lib/NAME.sh`, add `NAME` and a
  one-line description to the `MODULES` list at the top of `init.sh`, then
  `bash init.sh NAME`.

---

### Notes

- **Windows computers as peers:** the Windows OpenSSH server must start WSL
  as its shell, so `$` paths point into the WSL home.
- **zsh:** these tools are bash. From zsh run `bash` first, or make bash your
  shell. The startup block does nothing outside bash rather than breaking it.
- **Uninstalling** keeps your hosts and history; delete `~/.config/termkit`
  to remove those too.
