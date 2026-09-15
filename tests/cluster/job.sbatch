#!/bin/bash
# Runs body.sh once per way of making the canary available, one after another
# on a single node, writing each to $OUT/<mode>.out:
#   none      nothing: the image exists but nobody mounted it on this node
#   exec      the whole body under haversack exec
#   mount     haversack mount before, umount after
#   activate  eval "$(haversack activate ...)" in the job shell
# Sequential on purpose.  A mount made by a concurrent mode on the same node
# would make 'none' and 'exec' pass without testing anything, so those two run
# first and refuse to count if the environment is already mounted.
#SBATCH -t 00:30:00
#SBATCH -c 2
#SBATCH --mem=4G
set -uo pipefail

: "${CS:?}" "${BODY:?}" "${CANARY_NAME:?}" "${CANARY_PREFIX:?}" "${OUT:?}"

host_mounted() { grep -qF " $CANARY_PREFIX " /proc/self/mountinfo; }

run_mode() {
    local mode=$1
    echo "MODE $mode HOST $(hostname -s) JOB ${SLURM_JOB_ID:-?}"
    if [[ $mode == none || $mode == exec ]] && host_mounted; then
        echo "INVALID $mode: $CANARY_PREFIX is already mounted on this node, so this would test nothing"
        return 0
    fi
    case $mode in
        none)
            bash "$BODY" ;;
        exec)
            "$CS" exec "$CANARY_NAME" -- bash -c '
                [ -n "${HAVERSACK_NS:-}" ] || { echo "INVALID exec: ran without its own private mount"; exit 0; }
                bash "$1"' _ "$BODY" ;;
        mount)
            "$CS" mount "$CANARY_NAME"
            bash "$BODY"
            "$CS" umount "$CANARY_NAME" ;;
        activate)
            eval "$("$CS" activate "$CANARY_NAME")"
            bash "$BODY"
            eval "$("$CS" deactivate)"
            "$CS" umount "$CANARY_NAME" ;;
    esac
    if host_mounted; then echo "LEFTOVER $mode: still mounted after the mode finished"; fi
    echo "DONE $mode"
}

for mode in none exec mount activate; do
    echo "running $mode $(date +%T)"
    ( set -e; run_mode "$mode" ) > "$OUT/$mode.out" 2>&1
    rc=$?
    [[ $rc -eq 0 ]] || echo "EXIT $mode $rc" >> "$OUT/$mode.out"
done
echo "all modes done $(date +%T)"
