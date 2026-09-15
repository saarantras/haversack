#!/usr/bin/env bash
# Exercise haversack against a real conda environment through Slurm, the way
# jobs actually use conda: activation by name and by path, hardcoded
# interpreter and tool paths, conda info checks, set -u, and job arrays
# sharing a node.
#
# Builds a small canary environment (python, numpy, minimap2, libxml2 - the
# last for its activate.d hook) with haversack create if it does not exist.  Then
# submits one job that runs the same body with the environment unmounted,
# under exec, mounted and activated, plus two array pairs, and summarizes.
#
#   tests/cluster/run.sh --account ACCOUNT [--partition day] [--out DIR]
#
# Environment:
#   CONDA_SETUP   how a job gets conda (default: module load miniconda)
#   CANARY_NAME   canary environment name (default: haversack-canary)
set -euo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
CS=$(cd "$HERE/../.." && pwd -P)/haversack
account="" partition=day out=""
while [[ $# -gt 0 ]]; do
    case $1 in
        --account)   account=$2; shift 2 ;;
        --partition) partition=$2; shift 2 ;;
        --out)       out=$2; shift 2 ;;
        *)           echo "unknown option $1" >&2; exit 2 ;;
    esac
done
[[ -n $account ]] || { echo "usage: $0 --account ACCOUNT [--partition P] [--out DIR]" >&2; exit 2; }

# Creating the canary and packing it are real conda and mksquashfs work, which
# does not belong on a login node.  Run this from inside an allocation
# (salloc, or an interactive srun); the tests themselves go out as sbatch jobs.
[[ -n ${SLURM_JOB_ID:-} ]] || {
    echo "run this inside a Slurm allocation, not on a login node (e.g. salloc -c 4 --mem 8G)" >&2
    exit 2
}

export CONDA_SETUP=${CONDA_SETUP:-module load miniconda}
export CANARY_NAME=${CANARY_NAME:-haversack-canary}
out=${out:-$PWD/haversack-cluster-test.$(date +%Y%m%d-%H%M%S)}
mkdir -p "$out"
out=$(cd "$out" && pwd -P)
case $out in /tmp/*|/var/tmp/*|/dev/shm/*)
    echo "--out must be on a filesystem the compute nodes share, not $out" >&2; exit 2 ;;
esac

log() { printf '[%s] %s\n' "$(date +%T)" "$*"; }

# ---------------------------------------------------------------- canary --
eval "$CONDA_SETUP"
# Once packed, the environment's path is a bare mountpoint that conda does not
# list, so ask haversack first; asking only conda would recreate it on top.
# Build the canary the way users are meant to: haversack create, straight to
# an image, never extracted on the shared filesystem.
if [[ -z $("$CS" list 2>/dev/null | awk -v n="$CANARY_NAME" '$1 == n') ]]; then
    log "creating $CANARY_NAME with haversack create"
    if ! "$CS" create -n "$CANARY_NAME" -c conda-forge -c bioconda \
            python=3.11 numpy minimap2 libxml2 >"$out/create.log" 2>&1; then
        echo "haversack create failed; the last lines of $out/create.log:" >&2
        tail -5 "$out/create.log" >&2
        exit 1
    fi
fi
state=$("$CS" list | awk -v n="$CANARY_NAME" '$1 == n { print $3 }')
case $state in
    packed)  log "$CANARY_NAME is packed" ;;
    mounted) "$CS" umount "$CANARY_NAME" ;;
    *)       echo "$CANARY_NAME is in state '$state'; sort that out first" >&2; exit 1 ;;
esac
CANARY_PREFIX=$("$CS" list | awk -v n="$CANARY_NAME" '$1 == n { print $4 }')
export CANARY_PREFIX
[[ $("$CS" list | awk -v n="$CANARY_NAME" '$1 == n { print $3 }') == packed ]] || \
    { echo "$CANARY_NAME is not packed and unmounted here" >&2; exit 1; }

# ---------------------------------------------------------------- submit --
export CS BODY=$HERE/body.sh OUT=$out
common=(--parsable -A "$account" -p "$partition" --export=ALL)
# Each array pair gets a node to itself, and the modes job stays off both: a
# mount from one test would let another pass without doing its own mounting.
# Pinned jobs wait for their node, so pick the two with the most idle CPUs.
mapfile -t nodes < <(sinfo -p "$partition" -h -t idle,mix -o '%n %C' | \
    awk '{ split($2, c, "/"); if (c[2] >= 4) print c[2], $1 }' | sort -rn | head -2 | awk '{ print $2 }')
[[ ${#nodes[@]} -eq 2 ]] || { echo "need two nodes in $partition with at least 4 idle CPUs" >&2; exit 1; }
jobs=()
id=$(sbatch "${common[@]}" -J hvs-modes --exclude="${nodes[0]},${nodes[1]}" -o "$out/modes.out" "$HERE/job.sbatch")
jobs+=("$id"); log "submitted the four modes as $id"
id=$(sbatch "${common[@]}" -J hvs-array-mount -w "${nodes[0]}" -o "$out/array-mount-%a.out" "$HERE/array.sbatch" mount)
jobs+=("$id"); log "submitted array-mount as $id on ${nodes[0]}"
id=$(sbatch "${common[@]}" -J hvs-array-exec -w "${nodes[1]}" -o "$out/array-exec-%a.out" "$HERE/array.sbatch" exec)
jobs+=("$id"); log "submitted array-exec as $id on ${nodes[1]}"

# ------------------------------------------------------------------ wait --
# One sacct call a minute for all of them.
while :; do
    sleep 60
    pending=$(sacct -n -X -j "$(IFS=,; echo "${jobs[*]}")" -o State | \
        grep -cvE 'COMPLETED|FAILED|CANCELLED|TIMEOUT|OUT_OF_MEMORY|NODE_FAIL|PREEMPTED' || true)
    [[ $pending -eq 0 ]] && break
    log "$pending still running or pending"
done

# --------------------------------------------------------------- summary --
modes=(none exec mount activate)
fail=0
echo
for m in "${modes[@]}"; do
    f=$out/$m.out
    [[ -f $f ]] || { echo "no output for '$m' (see $out/modes.out)"; fail=1; continue; }
    grep -E '^(INVALID|LEFTOVER|EXIT) ' "$f" && fail=1
    grep -q "^DONE $m" "$f" || { echo "'$m' did not finish (see $f)"; fail=1; }
done

# 'none' is the baseline with nothing mounted: its failures are what a job
# sees on a node where nobody mounted the environment, and are not counted.
checks=$(cat "$out"/{none,exec,mount,activate}.out 2>/dev/null | awk '$1 == "CHECK" && !seen[$2]++ { print $2 }')
printf '\n%-26s' check; for m in "${modes[@]}"; do printf '%-10s' "$m"; done; echo
for c in $checks; do
    printf '%-26s' "$c"
    for m in "${modes[@]}"; do
        r=$(awk -v c="$c" '$1 == "CHECK" && $2 == c { print $3 }' "$out/$m.out" 2>/dev/null)
        r=${r:-missing}
        printf '%-10s' "$r"
        [[ $m != none && $r != ok ]] && fail=1
    done
    echo
done

echo
for m in mount exec; do
    grep -h '^INVALID' "$out"/array-$m-*.out 2>/dev/null && fail=1
    f=$out/array-$m-2.out
    total=$(grep -c '^READ' "$f" 2>/dev/null || true)
    bad=$(grep -c '^READ .* FAIL' "$f" 2>/dev/null || true)
    first_bad=$(awk '$1 == "READ" && $4 == "FAIL" { print $3; exit }' "$f" 2>/dev/null)
    t1_exit=$(awk '$1 == "TASK1" && $2 == "exiting" { print $3 }' "$out/array-$m-1.out" 2>/dev/null)
    printf 'array-%-6s task 2 reads: %s ok of %s' "$m" "$((total - bad))" "$total"
    if [[ -n $t1_exit ]]; then
        printf ' (task 1 exited %s' "$t1_exit"
        if [[ -n $first_bad ]]; then printf ', first failure %s)' "$first_bad"; else printf ')'; fi
    fi
    echo
    [[ $m == exec && ( $bad -gt 0 || $total -eq 0 ) ]] && fail=1
done

echo
echo "outputs: $out"
exit $fail
