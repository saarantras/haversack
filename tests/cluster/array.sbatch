#!/bin/bash
# Two array tasks on one node sharing the canary.  Task 1 makes the env
# available first and exits early; task 2 keeps using it for two minutes.
# With 'mount', task 1 owns the squashfuse process, so this shows whether
# Slurm's cleanup of task 1 takes the mount away from task 2.  With 'exec',
# each task has its own private mount.  run.sh gives each mode its own node.
#SBATCH -t 00:10:00
#SBATCH -c 1
#SBATCH --mem=2G
#SBATCH --array=1-2
set -euo pipefail

mode=${1:?mode: mount|exec}
: "${CS:?}" "${CANARY_NAME:?}" "${CANARY_PREFIX:?}"
task=${SLURM_ARRAY_TASK_ID:?}
echo "MODE array-$mode TASK $task HOST $(hostname -s) JOB ${SLURM_JOB_ID:-?}"

host_mounted() { grep -qF " $CANARY_PREFIX " /proc/self/mountinfo; }

if [ "$task" = 1 ]; then
    if [ "$mode" = mount ]; then
        # Task 1 has to be the one that creates the mount for this to test anything.
        if host_mounted; then echo "INVALID array-mount: already mounted before task 1 started"; exit 0; fi
        "$CS" mount "$CANARY_NAME"
        "$CANARY_PREFIX/bin/python" -c 'import numpy' && echo "TASK1 probe ok"
        sleep 20
    else
        "$CS" exec "$CANARY_NAME" -- bash -c '
            [ -n "${HAVERSACK_NS:-}" ] || echo "INVALID array-exec: task 1 ran without a private mount"
            python -c "import numpy" && echo "TASK1 probe ok"
            sleep 20'
    fi
    echo "TASK1 exiting $(date +%T)"
    exit 0
fi

# Task 2: let task 1 get there first, then keep probing past task 1's exit.
sleep 8
loop='[ "$2" = exec ] && [ -z "${HAVERSACK_NS:-}" ] && echo "INVALID array-exec: task 2 ran without a private mount"
for i in $(seq 1 12); do
    if "$1/bin/python" -c "import numpy" >/dev/null 2>&1; then r=ok; else r=FAIL; fi
    echo "READ $i $(date +%T) $r"
    sleep 10
done'
if [ "$mode" = mount ]; then
    "$CS" mount "$CANARY_NAME"
    bash -c "$loop" _ "$CANARY_PREFIX" mount
    # Leave the node clean, stale or not.
    "$CS" umount "$CANARY_NAME" || true
else
    "$CS" exec "$CANARY_NAME" -- bash -c "$loop" _ "$CANARY_PREFIX" exec
fi
echo "TASK2 done"
