# haversack for AI agents

Instructions for an agent installing or using haversack on a user's behalf.
Examples of everyday tasks are in [examples.md](examples.md); this page is the
install procedure and the rules that keep an agent from doing damage.

haversack packs a conda environment into one squashfs image and mounts it back
at its original path. A packed environment still looks like an ordinary conda
environment while it is mounted, and like a small stub directory while it is
not.

## Install

1. Get the script. It is a single bash file, `haversack`, at the top of the
   repository:

   ```
   git clone https://github.com/saarantras/haversack.git
   ```

   If the clone fails for lack of access, stop and ask the user where to get
   the script.

2. Put it on `PATH`:

   ```
   mkdir -p ~/.local/bin
   cp haversack/haversack ~/.local/bin/
   command -v haversack
   ```

   If `command -v` prints nothing, `~/.local/bin` is not on `PATH`. Tell the
   user and ask before editing their shell startup files.

3. Check the machine:

   ```
   haversack doctor
   ```

   `squashfuse`, `mksquashfs`, `unsquashfs`, `fusermount` and `flock` must all
   show a path, not `NOT FOUND`. `user ns` must say `yes` for `exec`, `create`
   and `edit` to work. If anything required is missing, stop and report the
   `doctor` output to the user rather than working around it.

4. Optionally, confirm it works end to end. On a Slurm cluster, run this inside
   an allocation or as a batch job, not on a login node; it takes a few minutes:

   ```
   haversack/tests/run.sh
   ```

5. For Claude Code, install the skill so later sessions know these rules without
   being told:

   ```
   mkdir -p ~/.claude/skills
   cp -r haversack/skills/haversack ~/.claude/skills/
   ```

There is nothing else to configure. Each user's images sit next to their own
environments, and the index, locks and activation records live under their own
`~/.local/share/haversack`.

## Rules

- **Batch jobs and job arrays use `haversack exec NAME -- command`.** Never put
  `haversack mount` in a batch script: the mount ends with the job that made it,
  and other jobs on the node lose the environment.
- **Interactive work uses `haversack mount NAME`**, then `conda activate` as
  usual, or `haversack shell NAME`.
- **Change a packed environment only through haversack**:
  `haversack install|update|remove NAME ...` for conda packages,
  `haversack edit NAME -- pip install ...` for pip. Never run
  `conda install -n NAME`, `pip install` into it, or write into its directory,
  its image, or the `.haversack/` directory beside it.
- **Building and changing run inside an allocation.** `create`, `pack`,
  `install`, `update`, `remove` and `edit` do real work; on a Slurm cluster, do
  not run them on a login node.
- **Ask the user before anything that deletes.** `haversack pack PATH` without
  `--keep` deletes the original environment once the image is verified, and
  `haversack delete NAME` deletes the image. Do not pass `-y`, `--force`,
  `umount --force` or `forget --force` without the user's explicit agreement.
- **Convert cautiously.** To pack an existing environment, run
  `haversack pack PATH --keep` first, try it with `haversack exec`, and ask
  before running `haversack pack PATH` to replace the original.

## Reading errors

| Message | Meaning | Do |
|---|---|---|
| `NAME is packed but not mounted on this node`, or exit status 127 from a program in the environment's `bin/` | The environment exists but is not available here | Run the command under `haversack exec NAME --`, or `haversack mount NAME` interactively. Do not recreate the environment. |
| `haversack: NAME is packed but not mounted on this node; nothing in it will run` when activating | Same | Same |
| `Transport endpoint is not connected` on the environment's path | A stale mount left by a killed process | `haversack mount NAME` or `haversack umount NAME` clears it |
| `another haversack command is already working on 'NAME'` | Another command holds the lock | Wait and retry. Do not delete lock files. |
| `'NAME' is still in use on this node` from `umount` | Processes or shells are using it; they are named | Tell the user. Do not force. |
| `prefix already exists` from `conda create`, or an error from `conda install -n NAME` | conda was aimed at a packed environment | Use `haversack create` for a new name, or `haversack install` / `haversack edit` to change this one |
| `Bad owner or permissions on /etc/ssh/...`, or `/root/.ssh/known_hosts: Permission denied` | `ssh` does not work inside `exec`, `shell` or `edit` | Run SSH-based commands (`git` over SSH, `scp`, `rsync`) outside haversack, or use `git` over HTTPS |
| The environment is missing from `conda env list` | Packed environments are listed only where mounted, or inside `exec` | Check `haversack list` |

`haversack list` shows every packed environment with its state on this node:
`packed`, `mounted`, `stale`, `kept` (packed with `--keep`, original still
there) or `MISSING` (image gone).
