#!/usr/bin/env bash
# Behavior tests for haversack, including concurrent, interrupted and
# careless use.  Needs squashfuse, mksquashfs, fusermount, flock and
# unprivileged user namespaces; no conda.
#
#   tests/run.sh
#   HAVERSACK_TEST_DIR=/some/dir tests/run.sh   # where the scratch tree goes
set -uo pipefail

CS=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)/haversack
BASE=$(mktemp -d "${HAVERSACK_TEST_DIR:-${TMPDIR:-/tmp}}/haversack-test.XXXXXX")
BASE=$(cd "$BASE" && pwd -P)
export HAVERSACK_REGISTRY=$BASE/registry
unset HAVERSACK_ACTIVE HAVERSACK_NS HAVERSACK_IMAGES HAVERSACK_OLD_PATH
ME=$(id -un)

PASS=0 FAIL=0
ok()      { PASS=$((PASS + 1)); printf '  ok    %s\n' "$1"; }
bad()     { FAIL=$((FAIL + 1)); printf '  FAIL  %s\n' "$1"; }
check()   { local d=$1; shift; if "$@"; then ok "$d"; else bad "$d"; fi; }
section() { printf '\n%s\n' "$*"; }
# check "desc" all A... --and B...: every command must succeed.  Written out as
# 'check "desc" [ A ] && [ B ]', only the first would count toward the check.
all() {
    local cmd=()
    while [ $# -gt 0 ]; do
        if [ "$1" = --and ]; then "${cmd[@]}" || return 1; cmd=(); else cmd+=("$1"); fi
        shift
    done
    "${cmd[@]}"
}

# A stand-in environment.  bin/python answers the smoke test, can idle with a
# file under the environment held open (as a real interpreter holds its
# libraries), and can report where it runs from.
mkenv() {                          # dir name [nfiles]
    local e=$1/$2 i
    mkdir -p "$e/bin" "$e/lib" "$e/conda-meta" "$e/etc/conda/activate.d" "$e/etc/conda/deactivate.d"
    echo "# test environment" > "$e/conda-meta/history"
    for ((i = 1; i <= ${3:-5}; i++)); do echo "$i" > "$e/lib/f$i"; done
    cat > "$e/bin/python" <<'EOF'
#!/bin/sh
case "$1" in
    -c)    exit 0 ;;
    idle)  exec 3<"$0"; exec sleep "$2" ;;
    where) cd "$(dirname "$0")/.." && pwd -P ;;
esac
EOF
    chmod +x "$e/bin/python"
    echo 'export CS_TEST_HOOK="on-$CONDA_DEFAULT_ENV"' > "$e/etc/conda/activate.d/hook.sh"
    echo 'unset CS_TEST_HOOK' > "$e/etc/conda/deactivate.d/hook.sh"
}

E=$BASE/envs
mkdir -p "$E" "$BASE/other"

daemons()  { ps -u "$ME" -o args= | grep '[s]quashfuse' | grep -cF -- "$BASE/" || true; }
nmounts()  { grep -cF -- " ${1// /\\040} " /proc/self/mountinfo || true; }
state()    { "$CS" list 2>/dev/null | awk -v n="$1" '$1 == n { print $3 }'; }
inodes()   { find "$1" | wc -l; }
uinodes()  { find "$1" -printf '%i\n' | sort -u | wc -l; }
daemon_of(){ ps -u "$ME" -o pid=,args= | grep '[s]quashfuse' | grep -F -- "$1" | awk '{ print $1 }' | head -1; }

# ------------------------------------------------------------------------------
section "pack"
mkenv "$E" plain 20
"$CS" pack "$E/plain" -y -j 1 >"$BASE/plain.log" 2>&1; rc=$?
check "pack -y succeeds" [ $rc -eq 0 ]
check "the environment is replaced by a small mountpoint" [ "$(uinodes "$E/plain")" -le 10 ]
bash -c '"$1/bin/python" -c pass 2>"$2"; echo $? > "$3"' _ "$E/plain" "$BASE/stub.err" "$BASE/stub.rc"
check "an unmounted environment's python fails with status 127" [ "$(cat "$BASE/stub.rc")" = 127 ]
check "...and says how to run it" grep -q 'haversack exec plain' "$BASE/stub.err"
check "...every executable name is a hardlink to one stub" \
    [ "$(stat -c %i "$E/plain/bin/python")" = "$(stat -c %i "$E/plain/bin/.haversack-stub")" ]
check "activating an unmounted environment prints a warning" \
    grep -q 'not mounted' <(bash -c '. "$1/etc/conda/activate.d/00-haversack-not-mounted.sh"' _ "$E/plain" 2>&1)
check "conda-meta is a file, so conda will not install into the mountpoint" [ -f "$E/plain/conda-meta" ]
check "state is packed" [ "$(state plain)" = packed ]
check "no partial image left behind" [ -z "$(ls -A "$E/.haversack" | grep partial)" ]
check "no trash left behind" [ -z "$(ls -A "$E" | grep haversack-trash)" ]

mkenv "$E" broken
printf '#!/bin/sh\nexit 1\n' > "$E/broken/bin/python"
n0=$(inodes "$E/broken")
"$CS" pack "$E/broken" -y -j 1 >/dev/null 2>&1; rc=$?
check "a failing smoke test fails pack" [ $rc -ne 0 ]
check "...leaves the environment untouched" [ "$(inodes "$E/broken")" -eq "$n0" ]
check "...registers nothing" [ -z "$(state broken)" ]
check "...and leaves no image or partial" [ -z "$(ls -A "$E/.haversack" | grep '^broken')" ]

mkenv "$E" notty
"$CS" pack "$E/notty" -j 1 </dev/null >"$BASE/notty.log" 2>&1; rc=$?
check "pack with no terminal and no -y refuses" [ $rc -ne 0 ]
check "...says to pass -y" grep -q 'pass -y' "$BASE/notty.log"
check "...and deletes nothing" [ "$(state notty)" = kept ]

mkenv "$E" busyfd
"$E/busyfd/bin/python" idle 30 & bp=$!
sleep 0.5
out=$("$CS" pack "$E/busyfd" -y -j 1 2>&1); rc=$?
check "pack refuses an environment a process holds a file in" [ $rc -ne 0 ]
check "...naming the PID" grep -qw "$bp" <<<"$out"
kill $bp; wait $bp 2>/dev/null

mkenv "$E" busycwd
( cd "$E/busycwd" && exec sleep 30 ) & bp=$!
sleep 0.5
out=$("$CS" pack "$E/busycwd" -y -j 1 2>&1); rc=$?
check "pack refuses an environment a process has as its working directory" [ $rc -ne 0 ]
check "...and deletes nothing" [ "$(state busycwd)" = kept ]
kill $bp; wait $bp 2>/dev/null

mkenv "$BASE/other" plain
"$CS" pack "$BASE/other/plain" -y -j 1 >"$BASE/steal.log" 2>&1; rc=$?
check "pack refuses to take a name that belongs to another environment" [ $rc -ne 0 ]
check "...and leaves that environment alone" [ "$(inodes "$BASE/other/plain")" -gt 5 ]
"$CS" pack "$BASE/other/plain" --name plain2 -y -j 1 >/dev/null 2>&1; rc=$?
check "--name registers it under another name" [ $rc -eq 0 ] 
check "...without disturbing the original owner of the name" [ "$(state plain)" = packed ]

mkenv "$E" gpu
mkdir -p "$E/gpu/lib/python3.11/site-packages/nvidia/cublas/lib" "$E/gpu/lib/python3.11/site-packages/nvidia/cudnn/lib"
"$CS" pack "$E/gpu" --fix-cuda -y -j 1 >"$BASE/gpu.log" 2>&1; rc=$?
check "pack --fix-cuda succeeds" [ $rc -eq 0 ]
out=$("$CS" exec gpu -- sh -c 'echo "$LD_LIBRARY_PATH"' 2>/dev/null)
# One here-string per check: two on the same line both feed the one check
# command, and the second grep would find its input already read.
check "...and exec puts the CUDA wheel lib dirs on the loader path, at the real prefix" \
    grep -qF "$E/gpu/lib/python3.11/site-packages/nvidia/cublas/lib" <<<"$out"
check "...all of them" grep -qF "$E/gpu/lib/python3.11/site-packages/nvidia/cudnn/lib" <<<"$out"
out=$(LD_LIBRARY_PATH=/keep/me bash -c '
    eval "$("$1" activate gpu)"; echo "on=$LD_LIBRARY_PATH"
    eval "$("$1" deactivate)"; echo "off=${LD_LIBRARY_PATH-unset}"
' _ "$CS" 2>/dev/null)
check "...keeping what was already on it" grep -q '^on=.*:/keep/me$' <<<"$out"
check "...and deactivate restores it" grep -qx 'off=/keep/me' <<<"$out"
"$CS" umount gpu >/dev/null 2>&1

# ------------------------------------------------------------------------------
section "concurrency"
for i in 1 2 3 4 5 6; do ( "$CS" mount plain >/dev/null 2>&1; echo $? > "$BASE/cm.$i" ) & done; wait
check "six concurrent mounts all succeed" [ "$(sort -u "$BASE"/cm.* | tr -d '\n')" = 0 ]
check "...with one squashfuse process" [ "$(daemons)" -eq 1 ]
check "...and one mount" [ "$(nmounts "$E/plain")" -eq 1 ]
"$CS" umount plain >/dev/null 2>&1
check "umount clears it" [ "$(daemons)" -eq 0 ]

for i in 1 2 3 4 5 6 7 8; do mkenv "$E" "c$i"; done
for i in 1 2 3 4 5 6 7 8; do "$CS" pack "$E/c$i" --keep -j 1 >/dev/null 2>&1 & done; wait
check "eight concurrent packs of different environments keep all eight index rows" \
    [ "$("$CS" list | grep -cE '^c[1-8] ')" -eq 8 ]

mkenv "$E" race 300
"$CS" pack "$E/race" -y -j 1 >"$BASE/r1.log" 2>&1 & p1=$!
"$CS" pack "$E/race" -y -j 1 >"$BASE/r2.log" 2>&1 & p2=$!
wait $p1; r1=$?; wait $p2; r2=$?
wins=0; [ $r1 -eq 0 ] && wins=$((wins + 1)); [ $r2 -eq 0 ] && wins=$((wins + 1))
check "of two concurrent packs of one environment, exactly one proceeds" [ $wins -eq 1 ]
check "...and the other says why" grep -qE 'already working|already packed' "$BASE/r1.log" "$BASE/r2.log"
"$CS" mount race >/dev/null 2>&1
check "...and the result mounts with every file" [ "$(ls "$E/race/lib" | wc -l)" -eq 300 ]
"$CS" umount race >/dev/null 2>&1

# ------------------------------------------------------------------------------
section "stale mounts"
"$CS" mount plain >/dev/null 2>&1
kill -9 "$(daemon_of "$E/plain")"; sleep 0.5
check "a mount whose squashfuse was killed shows as stale" [ "$(state plain)" = stale ]
"$CS" mount plain >/dev/null 2>&1; rc=$?
check "mount recovers it" [ $rc -eq 0 ]
check "...and the environment is readable" [ "$(cat "$E/plain/lib/f7" 2>/dev/null)" = 7 ]
kill -9 "$(daemon_of "$E/plain")"; sleep 0.5
out=$("$CS" exec plain -- cat "$E/plain/lib/f3" 2>&1); rc=$?
check "exec works over a stale mount" all [ $rc -eq 0 ] --and [ "$(tail -1 <<<"$out")" = 3 ]
check "...and clears it" [ "$(state plain)" = packed ]
"$CS" umount plain >/dev/null 2>&1; rc=$?
check "umount of an unmounted environment is a no-op" [ $rc -eq 0 ]

# ------------------------------------------------------------------------------
section "umount safety"
"$CS" mount plain >/dev/null 2>&1
"$E/plain/bin/python" idle 30 & sp=$!
sleep 0.5
out=$("$CS" umount plain 2>&1); rc=$?
check "umount refuses while a process runs from the environment" [ $rc -ne 0 ]
check "...naming the PID" grep -qw "$sp" <<<"$out"
check "...and leaves it mounted" [ "$(nmounts "$E/plain")" -eq 1 ]
kill $sp; wait $sp 2>/dev/null

bash -c 'eval "$("$1" activate plain)" && exec sleep 30' _ "$CS" & ap=$!
sleep 1
out=$("$CS" umount plain 2>&1); rc=$?
check "umount refuses while a shell has the environment activated" [ $rc -ne 0 ]
check "...naming the shell" grep -qw "$ap" <<<"$out"
kill $ap; wait $ap 2>/dev/null
"$CS" umount plain >/dev/null 2>&1; rc=$?
check "umount succeeds once that shell is gone" all [ $rc -eq 0 ] --and [ "$(nmounts "$E/plain")" -eq 0 ]

"$CS" mount plain >/dev/null 2>&1
"$E/plain/bin/python" idle 30 & sp=$!
sleep 0.5
"$CS" umount plain --force >/dev/null 2>&1; rc=$?
check "umount --force unmounts anyway" all [ $rc -eq 0 ] --and [ "$(nmounts "$E/plain")" -eq 0 ]
kill $sp; wait $sp 2>/dev/null

# ------------------------------------------------------------------------------
section "activate"
out=$(bash -c '
    base=$PATH
    for i in 1 2 3; do eval "$("$1" activate plain)"; done
    echo "copies=$(printf %s "$PATH" | tr : "\n" | grep -c "/envs/plain/bin")"
    echo "hook=${CS_TEST_HOOK:-}"
    echo "where=$(python where)"
    eval "$("$1" activate plain2)"
    echo "switched_copies=$(printf %s "$PATH" | tr : "\n" | grep -c "/envs/plain/bin")"
    echo "switched_hook=${CS_TEST_HOOK:-}"
    eval "$("$1" deactivate)"
    [ "$PATH" = "$base" ] && echo "path=restored"
    echo "hook_after=${CS_TEST_HOOK:-unset}"
    echo "active_after=${HAVERSACK_ACTIVE:-unset}"
    eval "$("$1" deactivate)" && echo "second_deactivate=ok"
' _ "$CS" 2>&1)
check "activating three times puts the environment on PATH once" grep -qx 'copies=1' <<<"$out"
check "activate.d hooks run" grep -qx 'hook=on-plain' <<<"$out"
check "python resolves inside the environment" grep -qxF "where=$E/plain" <<<"$out"
check "activating another environment replaces the first" grep -qx 'switched_copies=0' <<<"$out"
check "...running its hooks" grep -qx 'switched_hook=on-plain2' <<<"$out"
check "deactivate restores PATH" grep -qx 'path=restored' <<<"$out"
check "deactivate.d hooks run" grep -qx 'hook_after=unset' <<<"$out"
check "deactivate clears the active marker" grep -qx 'active_after=unset' <<<"$out"
check "deactivating twice is harmless" grep -qx 'second_deactivate=ok' <<<"$out"
real_host=$(uname -n); real_host=${real_host%%.*}
HOSTNAME=not-this-node bash -c 'eval "$("$1" activate plain)" && exec sleep 30' _ "$CS" & hp=$!
sleep 1
check "activation records name the real node even under an inherited HOSTNAME" \
    [ -e "$HAVERSACK_REGISTRY/refs/plain/$real_host.$hp" ]
kill $hp; wait $hp 2>/dev/null
"$CS" umount plain >/dev/null 2>&1; rc1=$?
"$CS" umount plain2 >/dev/null 2>&1; rc2=$?
check "shells that exited leave no activation records blocking umount" all [ $rc1 -eq 0 ] --and [ $rc2 -eq 0 ]
out=$(bash -c '
    ( eval "$("$1" activate plain)"; python where >/dev/null; eval "$("$1" deactivate)"; "$1" umount plain ) 2>&1
    echo "rc=$?"
' _ "$CS")
check "activate and deactivate inside a subshell leave nothing blocking umount" grep -qx 'rc=0' <<<"$out"
"$CS" umount plain --force >/dev/null 2>&1

# ------------------------------------------------------------------------------
section "exec"
out=$("$CS" exec plain -- sh -c 'cat "$CONDA_PREFIX/lib/f2"; echo "ns=$HAVERSACK_NS"; exit 7' 2>&1); rc=$?
check "exec runs the command inside the environment" grep -qx 2 <<<"$out"
check "exec returns the command's exit status" [ $rc -eq 7 ]
check "exec marks the namespace it runs in" grep -qx 'ns=plain' <<<"$out"
out=$("$CS" exec plain -- "$CS" mount plain2 2>&1); rc=$?
check "mount is refused inside exec" all [ $rc -ne 0 ] --and grep -q 'inside' <<<"$out"
for i in 1 2 3 4 5 6 7 8; do "$CS" exec plain -- cat "$E/plain/lib/f1" >"$BASE/ex.$i" 2>&1 & done; wait
check "eight concurrent execs all see the environment" [ "$(cat "$BASE"/ex.* | sort -u | tr -d '\n')" = 1 ]
"$CS" mount plain >/dev/null 2>&1
out=$("$CS" exec plain -- sh -c 'echo "ns=${HAVERSACK_NS:-}"; python where' 2>&1)
check "exec uses its own private mount even when the environment is mounted" grep -qx 'ns=plain' <<<"$out"
check "...and runs inside the environment" grep -qxF "$E/plain" <<<"$out"
"$CS" exec plain -- sh -c 'for i in 1 2 3 4 5 6; do cat "$CONDA_PREFIX/lib/f5" || exit 1; sleep 0.5; done' \
    >"$BASE/survive.out" 2>&1 & xs=$!
sleep 1
hostd=$(ps -u "$ME" -o pid=,args= | grep '[s]quashfuse' | grep -F -- "$E/plain" | grep -v -- ' -f ' | awk '{ print $1 }' | head -1)
check "...a node mount to kill exists" [ -n "$hostd" ]
kill -9 "$hostd"
wait $xs; rc=$?
check "exec keeps working when the node's mount dies under it" all [ $rc -eq 0 ] --and [ "$(grep -cx 5 "$BASE/survive.out")" -eq 6 ]
"$CS" umount plain >/dev/null 2>&1
out=$("$CS" exec c1 -- cat "$E/c1/lib/f4" 2>&1); rc=$?
check "exec tries the image of a --keep environment" all [ $rc -eq 0 ] --and [ "$out" = 4 ]
"$CS" exec plain -- sleep 30 & xp=$!
sleep 1
kill -9 $xp; wait $xp 2>/dev/null; sleep 1
check "a SIGKILLed exec leaves no squashfuse process behind" [ "$(daemons)" -eq 0 ]
# The command itself outlives a SIGKILL of its launcher, as any child would.
pkill -u "$ME" -xf 'sleep 30' || true
sleep 1
check "no squashfuse processes left after exec" [ "$(daemons)" -eq 0 ]

# ------------------------------------------------------------------------------
section "shell"
mkdir -p "$BASE/home/decoy"
printf '#!/bin/sh\necho decoy-python\n' > "$BASE/home/decoy/python"; chmod +x "$BASE/home/decoy/python"
echo 'export PATH="$HOME/decoy:$PATH"' > "$BASE/home/.bashrc"
if command -v script >/dev/null; then
    # script(1) gives the shell a terminal, so bash is interactive and reads ~/.bashrc.
    # Strip terminal escapes: bash in a terminal writes bracketed-paste codes
    # in front of each command's output.
    printf 'python where\necho "prefix=$CONDA_PREFIX"\nexit 5\n' | \
        HOME=$BASE/home SHELL=/bin/bash script -qefc "$CS shell plain" /dev/null > "$BASE/shell-tty.raw"
    rc=${PIPESTATUS[1]}
    tr -d '\r' < "$BASE/shell-tty.raw" | sed 's/\x1b\[[?0-9;]*[a-zA-Z]//g' > "$BASE/shell-tty.out"
    check "shell runs the environment's python even when ~/.bashrc puts something in front of PATH" \
        grep -qxF "$E/plain" "$BASE/shell-tty.out"
    check "...not the one ~/.bashrc put first" bash -c '! grep -q decoy-python "$1"' _ "$BASE/shell-tty.out"
    check "...and returns the shell's exit status" [ "$rc" -eq 5 ]
else
    echo "  skip  shell with a terminal (no script(1) here)"
fi
printf 'python where\nexit 4\n' | HOME=$BASE/home SHELL=/bin/bash "$CS" shell plain > "$BASE/shell-notty.out" 2>/dev/null
rc=${PIPESTATUS[1]}
check "shell without a terminal also runs the environment's python" grep -qxF "$E/plain" "$BASE/shell-notty.out"
check "...and returns the shell's exit status" [ "$rc" -eq 4 ]
sleep 1
check "no squashfuse processes left after shell" [ "$(daemons)" -eq 0 ]

# ------------------------------------------------------------------------------
section "interrupts"
mkenv "$E" slow 4000
n0=$(inodes "$E/slow")
"$CS" pack "$E/slow" -y -j 1 >"$BASE/slow.log" 2>&1 & pp=$!
until grep -q '^packing' "$BASE/slow.log" 2>/dev/null || ! kill -0 $pp 2>/dev/null; do sleep 0.05; done
kill -TERM $pp; wait $pp; rc=$?
check "SIGTERM during the image build stops pack" [ $rc -ne 0 ]
check "...with the environment intact" [ "$(inodes "$E/slow")" -eq "$n0" ]
check "...no partial image" [ -z "$(ls -A "$E/.haversack" | grep '^slow')" ]
check "...and nothing registered" [ -z "$(state slow)" ]

mkenv "$E" stuck 50
chmod 555 "$E/stuck/lib"
"$CS" pack "$E/stuck" -y -j 1 >"$BASE/stuck.log" 2>&1; rc=$?
check "a delete that cannot finish still leaves a packed environment" all [ $rc -eq 0 ] --and [ "$(state stuck)" = packed ]
check "...warning about the leftovers" grep -q 'could not fully remove' "$BASE/stuck.log"
trash=$(ls -d "$E"/.haversack-trash.stuck.* 2>/dev/null | head -1)
check "...which sit in a trash directory" [ -n "$trash" ]
chmod -R u+w "$trash" 2>/dev/null
"$CS" mount stuck >"$BASE/stuck2.log" 2>&1; rc=$?
check "the next mount works" all [ $rc -eq 0 ] --and [ "$(ls "$E/stuck/lib" | wc -l)" -eq 50 ]
check "...and clears the leftovers" [ -z "$(ls -d "$E"/.haversack-trash.stuck.* 2>/dev/null)" ]
"$CS" umount stuck >/dev/null 2>&1

# ------------------------------------------------------------------------------
section "create and change"
mkdir -p "$BASE/fakebin" "$BASE/build" "$BASE/cenvs"
# A stand-in conda: just enough of config / create / env create / install /
# update / remove against -p PREFIX.  Packages become files in lib/, and
# installed ones also get an executable in bin/.  A package called FAIL fails.
cat > "$BASE/fakebin/conda" <<'EOF'
#!/bin/bash
set -euo pipefail
verb=$1; shift
if [ "$verb" = config ]; then printf 'envs_dirs:\n  - %s\n' "$CONDA_ENVS_PATH"; exit 0; fi
[ "$verb" = env ] && { verb=env-$1; shift; }
prefix="" pkgs=()
while [ $# -gt 0 ]; do
    case $1 in
        -p|--prefix) prefix=$2; shift 2 ;;
        -f|--file)   while read -r p; do pkgs+=("$p"); done < "$2"; shift 2 ;;
        -c)          shift 2 ;;
        -y|--yes)    shift ;;
        *)           pkgs+=("$1"); shift ;;
    esac
done
[ -n "$prefix" ] || { echo "fake conda: no -p" >&2; exit 2; }
for p in "${pkgs[@]}"; do [ "$p" = FAIL ] && { echo "fake conda: cannot solve" >&2; exit 1; }; done
case $verb in
    create|env-create)
        mkdir -p "$prefix/bin" "$prefix/lib" "$prefix/conda-meta"
        echo "# fake" > "$prefix/conda-meta/history"
        cat > "$prefix/bin/python" <<'PYEOF'
#!/bin/sh
case "$1" in
    -c)    exit 0 ;;
    has)   [ -e "$(dirname "$0")/../lib/$2" ] && echo yes || echo no ;;
    where) cd "$(dirname "$0")/.." && pwd -P ;;
esac
PYEOF
        chmod +x "$prefix/bin/python"
        for p in "${pkgs[@]}"; do
            : > "$prefix/lib/$p"
            # nvidia-foo stands in for a pip CUDA wheel: site-packages/nvidia/foo/lib
            case $p in nvidia-*) mkdir -p "$prefix/lib/python3.11/site-packages/nvidia/${p#nvidia-}/lib" ;; esac
        done ;;
    install|update)
        for p in "${pkgs[@]}"; do
            : > "$prefix/lib/$p"
            printf '#!/bin/sh\necho %s\n' "$p" > "$prefix/bin/$p"; chmod +x "$prefix/bin/$p"
        done ;;
    remove)
        for p in "${pkgs[@]}"; do rm -f "$prefix/lib/$p" "$prefix/bin/$p"; done ;;
    *)  echo "fake conda: $verb?" >&2; exit 2 ;;
esac
EOF
chmod +x "$BASE/fakebin/conda"
export HAVERSACK_CONDA=$BASE/fakebin/conda HAVERSACK_BUILD_DIR=$BASE/build CONDA_ENVS_PATH=$BASE/cenvs
C=$BASE/cenvs

"$CS" create -n cenv -c conda-forge alpha beta >"$BASE/create.log" 2>&1; rc=$?
check "create -n builds and registers a packed environment" all [ $rc -eq 0 ] --and [ "$(state cenv)" = packed ]
check "...at conda's first envs directory" [ -f "$C/.haversack/cenv.sqfs" ]
check "...without the build ever writing at the real path" [ ! -e "$C/cenv/lib" ]
check "...leaving a small mountpoint" [ "$(uinodes "$C/cenv")" -le 10 ]
check "...and no build directory" [ -z "$(ls -A "$BASE/build")" ]
check "the new environment runs under exec, at its real path" \
    [ "$("$CS" exec cenv -- python where 2>/dev/null)" = "$C/cenv" ]
check "...with its packages" [ "$("$CS" exec cenv -- python has alpha 2>/dev/null)" = yes ]

"$CS" create -n cenv beta >/dev/null 2>&1; rc=$?
check "create refuses a name that already exists" [ $rc -ne 0 ]
"$CS" create -n cgpu --fix-cuda nvidia-cublas >"$BASE/cgpu.log" 2>&1; rc=$?
out=$("$CS" exec cgpu -- sh -c 'echo "$LD_LIBRARY_PATH"' 2>/dev/null)
check "create --fix-cuda puts the wheel lib dirs on the loader path, at the real prefix" \
    all [ $rc -eq 0 ] --and grep -qF "$C/cgpu/lib/python3.11/site-packages/nvidia/cublas/lib" <<<"$out"
check "...and never names the build directory" all [ -n "$out" ] --and bash -c '! grep -qF "$1" <<<"$2"' _ "$BASE/build" "$out"
mkenv "$C" occupied
"$CS" create -p "$C/occupied" beta >/dev/null 2>&1; rc=$?
check "create refuses to build over a directory that is not empty" all [ $rc -ne 0 ] --and [ -x "$C/occupied/bin/python" ]
"$CS" create -n cfail alpha FAIL >/dev/null 2>&1; rc=$?
check "a failed create fails" [ $rc -ne 0 ]
check "...registers nothing" [ -z "$(state cfail)" ]
check "...leaves no image, mountpoint or build directory" \
    all [ ! -e "$C/.haversack/cfail.sqfs" ] --and [ ! -e "$C/cfail" ] --and [ -z "$(ls -A "$BASE/build")" ]
printf 'gamma\ndelta\n' > "$BASE/env.txt"
"$CS" create -n cfile -f "$BASE/env.txt" >/dev/null 2>&1; rc=$?
check "create -f builds from an environment file" all [ $rc -eq 0 ] --and [ "$("$CS" exec cfile -- python has delta 2>/dev/null)" = yes ]

"$CS" exec cenv -- sh -c 'sleep 4; python has alpha; ls "$CONDA_PREFIX/bin"' >"$BASE/old-image.out" 2>&1 & ep=$!
sleep 1
"$CS" install cenv gamma >"$BASE/install.log" 2>&1; rc=$?
check "install changes a packed environment" all [ $rc -eq 0 ] --and [ "$("$CS" exec cenv -- python has gamma 2>/dev/null)" = yes ]
check "...keeping what was there" [ "$("$CS" exec cenv -- python has alpha 2>/dev/null)" = yes ]
check "...new executables run" [ "$("$CS" exec cenv -- gamma 2>/dev/null)" = gamma ]
check "...and get a stub where it is not mounted" \
    [ "$(stat -c %i "$C/cenv/bin/gamma")" = "$(stat -c %i "$C/cenv/bin/.haversack-stub")" ]
wait $ep
check "a command already running keeps the old image through an install" \
    grep -qx yes "$BASE/old-image.out" && ! grep -qx gamma "$BASE/old-image.out"
"$CS" remove cenv gamma >/dev/null 2>&1; rc=$?
check "remove takes a package back out" all [ $rc -eq 0 ] --and [ "$("$CS" exec cenv -- python has gamma 2>/dev/null)" = no ]
check "...and its stub" [ ! -e "$C/cenv/bin/gamma" ]
"$CS" update cenv beta >/dev/null 2>&1; rc=$?
check "update runs" [ $rc -eq 0 ]
before=$(md5sum < "$C/.haversack/cenv.sqfs")
"$CS" install cenv FAIL >/dev/null 2>&1; rc=$?
check "a failed install fails" [ $rc -ne 0 ]
check "...leaving the image untouched" [ "$(md5sum < "$C/.haversack/cenv.sqfs")" = "$before" ]
check "...and no build directory" [ -z "$(ls -A "$BASE/build")" ]
"$CS" mount cenv >/dev/null 2>&1
"$CS" install cenv gamma >/dev/null 2>&1; rc=$?
check "install refuses an environment mounted on this node" [ $rc -ne 0 ]
"$CS" umount cenv >/dev/null 2>&1
before=$(md5sum < "$C/.haversack/cenv.sqfs")
"$CS" edit cenv -- true >"$BASE/edit-noop.log" 2>&1; rc=$?
check "edit that changes nothing succeeds" [ $rc -eq 0 ]
check "...and leaves the image untouched" [ "$(md5sum < "$C/.haversack/cenv.sqfs")" = "$before" ]
"$CS" edit cenv -- sh -c 'printf "#!/bin/sh\necho piped\n" > "$CONDA_PREFIX/bin/pipthing"; chmod +x "$CONDA_PREFIX/bin/pipthing"; : > "$CONDA_PREFIX/lib/by-pip"' \
    >"$BASE/edit.log" 2>&1; rc=$?
check "edit saves what a command changed, the way pip changes it" \
    all [ $rc -eq 0 ] --and [ "$("$CS" exec cenv -- python has by-pip 2>/dev/null)" = yes ]
check "...new executables run" [ "$("$CS" exec cenv -- pipthing 2>/dev/null)" = piped ]
check "...and get a stub" [ "$(stat -c %i "$C/cenv/bin/pipthing")" = "$(stat -c %i "$C/cenv/bin/.haversack-stub")" ]
before=$(md5sum < "$C/.haversack/cenv.sqfs")
"$CS" edit cenv -- sh -c ': > "$CONDA_PREFIX/lib/half-done"; exit 3' >/dev/null 2>&1; rc=$?
check "edit saves nothing when the command fails" all [ $rc -ne 0 ] --and [ "$(md5sum < "$C/.haversack/cenv.sqfs")" = "$before" ]
"$CS" edit cenv -- "$CS" install cenv zeta >/dev/null 2>&1; rc=$?
check "the environment stays locked while it is being edited" \
    all [ $rc -ne 0 ] --and [ "$(md5sum < "$C/.haversack/cenv.sqfs")" = "$before" ]
printf ': > "$CONDA_PREFIX/lib/from-shell"\nexit\n' | "$CS" edit cenv >"$BASE/edit-shell.log" 2>&1; rc=$?
check "edit with no command opens a shell and saves what it changed" \
    all [ $rc -eq 0 ] --and [ "$("$CS" exec cenv -- python has from-shell 2>/dev/null)" = yes ]
check "...leaving no build directory" [ -z "$(ls -A "$BASE/build")" ]
# delete ------------------------------------------------------------------------
"$CS" mount cfile >/dev/null 2>&1
"$CS" delete cfile -y >/dev/null 2>&1; rc=$?
check "delete refuses an environment mounted on this node" all [ $rc -ne 0 ] --and [ "$(state cfile)" = mounted ]
"$CS" umount cfile >/dev/null 2>&1
"$CS" delete cfile </dev/null >"$BASE/delete-notty.log" 2>&1; rc=$?
check "delete with no terminal and no -y refuses" all [ $rc -ne 0 ] --and [ "$(state cfile)" = packed ]
"$CS" exec cfile -- sh -c 'sleep 3; python has gamma' >"$BASE/delete-running.out" 2>&1 & dp=$!
sleep 1
"$CS" delete cfile -y >"$BASE/delete.log" 2>&1; rc=$?
check "delete -y removes the environment from the index" all [ $rc -eq 0 ] --and [ -z "$(state cfile)" ]
check "...its image" [ ! -e "$C/.haversack/cfile.sqfs" ]
check "...and empties its mountpoint" [ -z "$(ls -A "$C/cfile")" ]
wait $dp
check "a command already running from it finishes" grep -qx yes "$BASE/delete-running.out"
"$CS" create -n cfile gamma >/dev/null 2>&1; rc=$?
check "the name can be used again" all [ $rc -eq 0 ] --and [ "$(state cfile)" = packed ]
"$CS" delete nosuchenv -y >/dev/null 2>&1; rc=$?
check "delete of an unknown name fails" [ $rc -ne 0 ]
mkenv "$C" kept
"$CS" pack "$C/kept" --keep -j 1 >/dev/null 2>&1
"$CS" delete kept -y >/dev/null 2>&1; rc=$?
check "delete refuses while the original environment is still there" all [ $rc -ne 0 ] --and [ -x "$C/kept/bin/python" ]
unset HAVERSACK_CONDA HAVERSACK_BUILD_DIR CONDA_ENVS_PATH

# ------------------------------------------------------------------------------
section "forget and unpack"
"$CS" mount plain >/dev/null 2>&1
"$CS" forget plain >/dev/null 2>&1; rc=$?
check "forget refuses a mounted environment" all [ $rc -ne 0 ] --and [ "$(state plain)" = mounted ]
"$CS" umount plain >/dev/null 2>&1
"$CS" forget plain >/dev/null 2>&1; rc=$?
check "forget refuses when the image is the only copy" all [ $rc -ne 0 ] --and [ "$(state plain)" = packed ]
"$CS" forget notty >/dev/null 2>&1; rc=$?
check "forget drops a --keep environment" all [ $rc -eq 0 ] --and [ -z "$(state notty)" ]

"$CS" unpack plain >/dev/null 2>&1; rc=$?
check "unpack restores the environment" all [ $rc -eq 0 ] --and [ "$(state plain)" = kept ]
check "...with every file" all [ "$(ls "$E/plain/lib" | wc -l)" -eq 20 ] --and [ "$(cat "$E/plain/lib/f20")" = 20 ]
check "...and runs natively" [ "$("$E/plain/bin/python" where)" = "$E/plain" ]
check "...leaving no restore directory behind" [ -z "$(ls -A "$E" | grep haversack-unpack)" ]
"$CS" unpack plain >/dev/null 2>&1; rc=$?
check "unpack refuses to overwrite a live environment" [ $rc -ne 0 ]
"$CS" pack "$E/plain" -y -j 1 >/dev/null 2>&1; rc=$?
check "an unpacked environment packs again" all [ $rc -eq 0 ] --and [ "$(state plain)" = packed ]

# ------------------------------------------------------------------------------
section "cleanup"
sleep 1
check "no squashfuse processes left" [ "$(daemons)" -eq 0 ]
awk '{ print $5 }' /proc/self/mountinfo | grep -F -- "$BASE/" | while read -r m; do
    fusermount3 -u "$(printf '%b' "$m")" 2>/dev/null || fusermount -u "$(printf '%b' "$m")" 2>/dev/null
done
chmod -R u+w "$BASE" 2>/dev/null

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
if [ "$FAIL" -eq 0 ]; then
    rm -rf "$BASE"
else
    printf 'scratch tree kept for inspection: %s\n' "$BASE"
    exit 1
fi
