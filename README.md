# haversack

Collapse a conda environment into a single squashfs image, and mount it back at
its own original path.

A conda environment is tens of thousands of small files. On a shared cluster
filesystem that is expensive twice over: it eats the group's inode quota, and
every `import` becomes a burst of metadata round-trips. `haversack` packs the
whole environment into one compressed file and mounts it where it used to live,
so nothing inside the environment needs rewriting and everything behaves as
before.

```
$ haversack pack ~/envs/tz
packing /home/you/envs/tz (94592 inodes) -> /home/you/envs/.haversack/tz.sqfs
image: 94592 inodes, 3.6G (source 7.9G)
  python 3.11.15 runs from the image
Delete /home/you/envs/tz (94592 inodes)? Recoverable with: haversack unpack tz
Type 'tz' to confirm: tz
removing the original ...
packed tz: 94592 inodes -> 11

$ haversack mount tz
$ python -c "import tensorflow"     # just works
```

Measured on a 94,592-file environment: **94,592 inodes to 11**, 7.9G to 3.6G, and
about **5x faster interpreter startup** than the same environment on NFS, because
one sequential read of a compressed file beats thousands of metadata lookups.

For everyday conda tasks next to their haversack equivalents - creating,
activating, batch jobs, job arrays, installing with conda or pip - see
[docs/examples.md](docs/examples.md).

Installing or using haversack through an AI agent: see
[docs/agents.md](docs/agents.md).

## What pack does

1. Builds the image under a temporary name.
2. Checks that it holds exactly as many inodes as the environment.
3. Mounts it over the environment in a private namespace and runs the
   environment's `python` from it. Nobody else sees that mount.
4. Moves the image into place and registers it.
5. Refuses to continue if any process on this node is using the environment.
6. Asks for confirmation and recounts the environment in case it changed.
7. Renames the environment aside, creates the mountpoint, then deletes the
   renamed copy.

A failure or interrupt before step 7 leaves the environment untouched. The
rename in step 7 is atomic, so an interrupt there leaves either the whole
environment or a finished mountpoint; a half-deleted copy left behind is removed
by the next command on that environment.

`unpack` restores the environment from the image byte for byte, so the delete is
not one-way. That is also the reason to keep the image rather than plan on
rebuilding: an environment built up with `pip install` on top of conda rarely
rebuilds to the same versions.

`--keep` stops after step 4, to try an image before committing to it.

## Building and changing environments

`create` builds a new environment without it ever touching the shared
filesystem: inside a private namespace, node-local disk is bound over the
environment's real path, conda installs there, and the result is packed
straight into an image. Paths baked into the environment name its real
location; the only file that reaches the shared filesystem is the image.

```
haversack create -n tz -c conda-forge python=3.11 numpy
haversack install tz scipy
haversack remove tz scipy
haversack edit tz -- pip install some-wheel
haversack edit tz                 # a shell; exit to save
```

A packed environment is read-only, so `install`, `update` and `remove` work the
same way: unpack to local disk, run conda there, pack, and swap the new image in
with a rename. Commands already running from the old image keep it until they
exit; a `mount` on another node keeps serving the old image until it is
remounted.

## Installing

`haversack` is a single bash script. Put it anywhere on your `PATH` and check
what it can use on this machine:

```
mkdir -p ~/.local/bin
cp haversack ~/.local/bin/
haversack doctor
```

There is nothing else to set up. Each user's images, index, locks and activation
records are their own: images sit next to that user's environments, and the
rest under `~/.local/share/haversack`.

## Requirements

`squashfuse`, `mksquashfs`, `fusermount` and `flock`. If your cluster has
Apptainer or Singularity, you already have the first three - they ship inside
it, and `haversack` will find them there. `flock` comes with util-linux. Run
`haversack doctor` to see what it found.

Unprivileged user namespaces are needed for `exec` and for the smoke test in
`pack`. Without them, `pack` skips the smoke test and you use `mount` / `umount`.

## Two ways to use it

**Mounted** - mount once per node, then work normally for the rest of the
session. Fastest, and `conda activate` and GPU access work exactly as they
always did.

```
haversack mount tz
... work ...
haversack umount tz
```

or, without conda loaded at all:

```
eval "$(haversack activate tz)"     # mounts if needed
... work ...
eval "$(haversack deactivate)"
```

**Per-command** - mount inside a private namespace for the length of one
command. Nothing is left mounted, nothing is visible to anyone else, and a
killed job cannot leave a mount behind. Good for batch jobs.

```
haversack exec tz -- python train.py
```

**In batch jobs, use `exec`.** Slurm ends every process of a job when the job
ends, including the squashfuse behind a `mount`, so any other job on that node
still using the environment loses it mid-run. With two array tasks sharing a
node, the second task's imports failed within ten seconds of the first task
exiting. `exec` gives each job its own mount and never borrows one made by
`mount`.

## Commands

| | |
|---|---|
| `create -n NAME \| -p PATH [-f env.yml] [conda args...]` | Build a new environment on node-local disk and pack it straight into an image. |
| `install\|update\|remove NAME [conda args...]` | Change a packed environment: rebuilt on node-local disk, repacked, swapped in. |
| `edit NAME [-- command...]` | A shell, or one command, with the environment writable on node-local disk; what changed is repacked. For `pip`, or batching changes. |
| `pack <env> [--keep] [-y] [--force] [--name N] [--to DIR] [-j N] [--fix-cuda]` | Build, check, smoke-test, then replace the environment with its image. |
| `unpack <name>` | Restore the environment from its image. |
| `mount <name>` / `umount <name> [--force]` | Mount at the original path, on this node. |
| `exec <name> -- <cmd>` / `shell <name>` | Run inside a private, temporary mount. |
| `eval "$(haversack activate <name>)"` / `deactivate` | Put it on `PATH` in the current shell. |
| `list` / `verify <name>` | What is packed and in what state; a quick check that it runs. |
| `delete <name> [-y]` | Delete a packed environment: its image, its mountpoint and its entry. |
| `forget <name> [--force]` | Drop an entry from the index, leaving the files. |
| `doctor` | What is installed and what works here. |

| `pack` option | |
|---|---|
| `--keep` | Stop before deleting the environment. |
| `-y` | Do not prompt before deleting. Required when there is no terminal. |
| `--force` | Delete even if processes on this node are using the environment. |
| `--name N` | Register under `N` instead of the directory name. |
| `--fix-cuda` | See below. |

`--fix-cuda` adds the `nvidia/*/lib` directories from pip-installed CUDA wheels
to the environment's `activate.d`, and undoes it in `deactivate.d`. Those
libraries are not on the loader path by default, which is why a framework can
find the driver and then fail to `dlopen` its own runtime and fall back to CPU.
This edits the environment itself, before it is packed.

## Careless use

`haversack` is meant to be typed at, repeatedly and in several terminals at
once, so it is built to hold up to that:

- **Concurrent commands.** Commands on the same environment take a lock.
  Concurrent `pack` or `unpack` fail fast with a message; concurrent `mount`
  and `umount` wait their turn, so five terminals mounting at once end up with
  one mount and one squashfuse process. Index updates are serialized, so
  packing several environments at once loses nothing.
- **Unmounting under someone.** `umount` refuses while processes on the node
  are running from the environment or shells have it activated, and names
  them. `--force` detaches it anyway; programs already inside keep what they
  have open until they exit.
- **Activating twice, or switching.** `activate` is idempotent, and activating
  a second environment deactivates the first. `deactivate` runs the
  environment's `deactivate.d` hooks and restores `PATH`.
- **Killed mounts.** When a squashfuse process dies - at the end of a Slurm
  job, for instance - its mount is left behind and every access fails with
  "Transport endpoint is not connected". `list` shows these as `stale`, and
  `mount`, `umount`, `exec`, `pack` and `unpack` clear them.
- **Using an environment where it is not mounted.** What is left at the path
  answers every way in: each executable name in `bin/` is a stub that exits
  127 and says to use `haversack exec` or `mount` (they are all hardlinks to
  one file, so they cost one inode); activating it prints a warning; and
  `conda create` or `conda install` aimed at it refuses instead of writing an
  environment into the mountpoint.
- **Mounting in a batch job.** `mount` warns when run inside a Slurm job,
  since the mount goes away with that job; see "In batch jobs, use `exec`".
- **Killed `exec`.** The squashfuse behind an `exec` is tied to it and goes
  away when it exits or is killed, even with `SIGKILL`.
- **Mounting from inside `exec`.** Refused: those mounts would be private to a
  namespace that disappears with the command.
- **Name clashes.** `pack` will not register an environment under a name that
  already belongs to another; pass `--name`.
- **Forgetting the only copy.** `forget` refuses while the environment is
  mounted, or when its image is the only copy of it.

## Caveats

- Do not pack an environment that running jobs are using. `pack` checks for
  processes on the node it runs on, but it cannot see jobs on other nodes, and
  deleting an environment under a running Python crashes it on its next import.
  The same goes for `umount`: its check covers this node only.
- Locks and activation records live under your registry, so they coordinate
  your own commands. Across nodes, locking is only as reliable as the NFS
  server's lock manager.
- A FUSE mount belongs to the user who made it; unless `user_allow_other` is set
  in `/etc/fuse.conf`, other users on the same node cannot see into it.
- `exec` runs under `unshare --map-root-user`, so `id -u` reads 0 inside. File
  ownership still maps back to you; only tools that refuse to "run as root" will
  notice.
- `shell` reads `~/.bashrc` before setting up the environment when your shell
  is bash. Other shells read their startup files after, so anything there that
  puts directories in front of `PATH` can shadow the environment's executables;
  use `exec` or `mount` instead.
- `delete` refuses only while the environment is mounted on this node; it
  cannot see mounts on other nodes. Commands running from it under `exec`, on
  any node, keep it until they finish, which is why it leaves the emptied
  directory behind for you to `rmdir` later.
- A mount made on a login node lasts until you unmount it.
- The image is read-only. Change it with `install`, `update`, `remove` or `edit`,
  which rebuild it on node-local disk.

## Configuration

| | |
|---|---|
| `HAVERSACK_IMAGES` | where images go (default: `<env-parent>/.haversack`) |
| `HAVERSACK_CONDA` | conda, mamba or micromamba to build with (default: first on `PATH`) |
| `HAVERSACK_BUILD_DIR` | node-local directory for builds (default: `$TMPDIR`, else `/tmp`) |
| `HAVERSACK_PKGS_DIR` | package cache for builds (default: a fresh one inside each build) |
| `HAVERSACK_REGISTRY` | index, locks and activation records (default: `~/.local/share/haversack`) |

## Tests

```
tests/run.sh
```

Exercises packing, `--fix-cuda`, concurrent and repeated commands, stale mounts,
unmounting in use, activation, `exec`, interrupts, `create`, `install`, `edit`,
`forget` and `unpack` against stand-in environments, with a stand-in `conda`
for the commands that build. It needs the same tools as `haversack` itself, but
no conda.
Set `HAVERSACK_TEST_DIR` to choose where its scratch tree goes.

```
tests/cluster/run.sh --account ACCOUNT [--partition day]
```

Runs a real conda environment through Slurm the way jobs use conda: activation
by name and by path, hardcoded interpreter and tool paths, `conda info --envs`
checks, `set -u`, and two array tasks sharing a node. It builds a small
`haversack-canary` environment with `haversack create` on first use, then runs
the same job body with
the environment unmounted, mounted, under `exec`, and activated. Set
`CONDA_SETUP` if your jobs get conda some other way than `module load miniconda`.
