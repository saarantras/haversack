# conda-squash

Collapse a conda environment into a single squashfs image, and mount it back at
its own original path.

A conda environment is tens of thousands of small files. On a shared cluster
filesystem that is expensive twice over: it eats the group's inode quota, and
every `import` becomes a burst of metadata round-trips. `conda-squash` packs the
whole environment into one compressed file and mounts it where it used to live,
so nothing inside the environment needs rewriting and everything behaves as
before.

```
$ conda-squash pack ~/envs/tz
packing /home/you/envs/tz (94592 inodes) -> /home/you/envs/.squashed/tz.sqfs
image: 94592 inodes, 3.5G (source 7.9G)
  python 3.11.15 runs from the image
Delete /home/you/envs/tz (94592 inodes)? Recoverable with: conda-squash unpack tz
Type 'tz' to confirm: tz
removing the original ...
packed tz: 94592 inodes -> 6

$ conda-squash mount tz
$ python -c "import tensorflow"     # just works
```

Measured on a 94,592-file environment: **94,592 inodes to 6**, 7.9G to 3.5G, and
about **5x faster interpreter startup** than the same environment on NFS, because
one sequential read of a compressed file beats thousands of metadata lookups.

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

## Requirements

`squashfuse`, `mksquashfs`, `fusermount` and `flock`. If your cluster has
Apptainer or Singularity, you already have the first three - they ship inside
it, and `conda-squash` will find them there. `flock` comes with util-linux. Run
`conda-squash doctor` to see what it found.

Unprivileged user namespaces are needed for `exec` and for the smoke test in
`pack`. Without them, `pack` skips the smoke test and you use `mount` / `umount`.

## Two ways to use it

**Mounted** - mount once per node, then work normally for the rest of the
session. Fastest, and `conda activate` and GPU access work exactly as they
always did.

```
conda-squash mount tz
... work ...
conda-squash umount tz
```

or, without conda loaded at all:

```
eval "$(conda-squash activate tz)"     # mounts if needed
... work ...
eval "$(conda-squash deactivate)"
```

**Per-command** - mount inside a private namespace for the length of one
command. Nothing is left mounted, nothing is visible to anyone else, and a
killed job cannot leave a mount behind. Good for batch jobs.

```
conda-squash exec tz -- python train.py
```

## Commands

| | |
|---|---|
| `pack <env> [--keep] [-y] [--force] [--name N] [--to DIR] [-j N] [--fix-cuda]` | Build, check, smoke-test, then replace the environment with its image. |
| `unpack <name>` | Restore the environment from its image. |
| `mount <name>` / `umount <name> [--force]` | Mount at the original path, on this node. |
| `exec <name> -- <cmd>` / `shell <name>` | Run inside a private, temporary mount. |
| `eval "$(conda-squash activate <name>)"` / `deactivate` | Put it on `PATH` in the current shell. |
| `list` / `verify <name>` | What is packed and in what state; a quick check that it runs. |
| `forget <name> [--force]` | Drop an entry from the index. |
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

`conda-squash` is meant to be typed at, repeatedly and in several terminals at
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
- A FUSE mount belongs to the user who made it. Unless `user_allow_other` is set
  in `/etc/fuse.conf`, other users cannot see it - for a shared environment,
  each user mounts the image themselves, or uses `exec`.
- `exec` runs under `unshare --map-root-user`, so `id -u` reads 0 inside. File
  ownership still maps back to you; only tools that refuse to "run as root" will
  notice.
- A mount made on a login node lasts until you unmount it.
- The image is read-only. Installing a package means `unpack`, install, `pack`.

## Configuration

| | |
|---|---|
| `CONDA_SQUASH_IMAGES` | where images go (default: `<env-parent>/.squashed`) |
| `CONDA_SQUASH_REGISTRY` | index, locks and activation records (default: `~/.local/share/conda-squash`) |

## Tests

```
tests/run.sh
```

Exercises packing, concurrent and repeated commands, stale mounts, unmounting
in use, activation, `exec`, interrupts, `forget` and `unpack` against stand-in
environments. It needs the same tools as `conda-squash` itself, but no conda.
Set `CONDA_SQUASH_TEST_DIR` to choose where its scratch tree goes.
