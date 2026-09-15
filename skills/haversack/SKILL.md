---
name: haversack
description: Use when a conda environment is managed by haversack (packed into a squashfs image), or when an environment's programs fail with "is packed but not mounted", exit status 127 from an environment's bin/, or "Transport endpoint is not connected". Also use when writing Slurm batch scripts or job arrays that use a conda environment on a machine with haversack installed, and when creating, installing into, packing, editing or deleting environments with haversack.
---

# haversack

haversack packs a conda environment into one squashfs image and mounts it back
at its original path. While mounted, or inside `haversack exec`, it is an
ordinary conda environment. Everywhere else its path holds a small stub:
programs exit 127 with a message, and activating it prints a warning.

Everyday tasks, conda next to haversack, are in `docs/examples.md` in the
haversack repository.

## First

- `command -v haversack` - is it installed? If not, installation is in
  `docs/agents.md` in the repository.
- `haversack list` - packed environments and their state on this node:
  `packed`, `mounted`, `stale`, `kept`, `MISSING`.
- `haversack doctor` - what the machine supports.

## Rules

- Batch jobs and job arrays: `haversack exec NAME -- command`. Never
  `haversack mount` in a batch script; the mount ends with the job that made it,
  and other jobs on the node lose the environment. An existing job body can run
  unchanged as `haversack exec NAME -- bash job-body.sh`.
- Interactive work: `haversack mount NAME`, then `conda activate NAME` as usual;
  or `haversack shell NAME`.
- `module load miniconda` (or any conda on `PATH`) is needed only where conda
  itself runs: `create`, `install`, `update`, `remove`, and any `conda` command.
  `haversack exec NAME -- python ...` needs no conda: it sets up `PATH` and the
  environment's activation hooks itself.
- Change a packed environment only through haversack:
  `haversack install|update|remove NAME [conda args]`, and
  `haversack edit NAME -- pip install ...` for pip. Never `conda install -n NAME`,
  never `pip install` into it, never write into its directory, its image or the
  `.haversack/` directory beside it.
- New environments: `haversack create -n NAME [conda create args]` or
  `haversack create -n NAME -f environment.yml`.
- `create`, `pack`, `install`, `update`, `remove` and `edit` do real work: on a
  Slurm cluster run them inside an allocation or a batch job, not on a login
  node.
- Ask the user first, every time, before anything that deletes:
  `haversack pack PATH` without `--keep` (deletes the original environment) and
  `haversack delete NAME`. Never add `-y`, `--force`, `umount --force` or
  `forget --force` on your own.
- To convert an existing environment: `haversack pack PATH --keep`, test with
  `haversack exec NAME -- ...`, then ask before `haversack pack PATH`.

## Errors

- "is packed but not mounted on this node", or exit 127 from a program in the
  environment's `bin/`: the environment is fine but not available here. Run the
  command under `haversack exec NAME --`, or mount it interactively. Do not
  recreate or reinstall it.
- "Transport endpoint is not connected" on the environment's path: a stale mount
  from a killed process. `haversack mount NAME` or `haversack umount NAME`
  clears it.
- "already working on": another haversack command holds the environment's lock.
  Wait and retry; do not remove lock files.
- "is still in use on this node" from `umount`: the output names the processes
  or shells. Report them to the user; do not force.
- "prefix already exists" from `conda create`, or an error from
  `conda install -n NAME`: conda was aimed at a packed environment. Use
  `haversack install` or `haversack edit` to change it.
- "Bad owner or permissions on /etc/ssh/..." or "/root/.ssh/known_hosts:
  Permission denied": `ssh` cannot work inside `exec`, `shell` or `edit` (you
  appear as root in a user namespace). Run SSH-based commands - `git` over SSH,
  `scp`, `rsync` - outside haversack, or use `git` over HTTPS.
- A packed environment missing from `conda env list`: it is only listed where
  mounted or inside `exec`. Use `haversack list`.
