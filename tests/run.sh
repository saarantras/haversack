#!/usr/bin/env bash
# Behavior tests for conda-squash, including concurrent, interrupted and
# careless use.  Needs squashfuse, mksquashfs, fusermount, flock and
# unprivileged user namespaces; no conda.
#
#   tests/run.sh
#   CONDA_SQUASH_TEST_DIR=/some/dir tests/run.sh   # where the scratch tree goes
set -uo pipefail

CS=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)/conda-squash
BASE=$(mktemp -d "${CONDA_SQUASH_TEST_DIR:-${TMPDIR:-/tmp}}/conda-squash-test.XXXXXX")
BASE=$(cd "$BASE" && pwd -P)
export CONDA_SQUASH_REGISTRY=$BASE/registry
unset CONDA_SQUASH_ACTIVE CONDA_SQUASH_NS CONDA_SQUASH_IMAGES CONDA_SQUASH_OLD_PATH
ME=$(id -un)

PASS=0 FAIL=0
ok()      { PASS=$((PASS + 1)); printf '  ok    %s\n' "$1"; }
bad()     { FAIL=$((FAIL + 1)); printf '  FAIL  %s\n' "$1"; }
check()   { local d=$1; shift; if "$@"; then ok "$d"; else bad "$d"; fi; }
section() { printf '\n%s\n' "$*"; }

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
daemon_of(){ ps -u "$ME" -o pid=,args= | grep '[s]quashfuse' | grep -F -- "$1" | awk '{ print $1 }' | head -1; }

# ------------------------------------------------------------------------------
section "pack"
mkenv "$E" plain 20
"$CS" pack "$E/plain" -y -j 1 >"$BASE/plain.log" 2>&1; rc=$?
check "pack -y succeeds" [ $rc -eq 0 ]
check "the environment is replaced by a small mountpoint" [ "$(inodes "$E/plain")" -le 5 ]
check "state is packed" [ "$(state plain)" = packed ]
check "no partial image left behind" [ -z "$(ls -A "$E/.squashed" | grep partial)" ]
check "no trash left behind" [ -z "$(ls -A "$E" | grep conda-squash-trash)" ]

mkenv "$E" broken
printf '#!/bin/sh\nexit 1\n' > "$E/broken/bin/python"
n0=$(inodes "$E/broken")
"$CS" pack "$E/broken" -y -j 1 >/dev/null 2>&1; rc=$?
check "a failing smoke test fails pack" [ $rc -ne 0 ]
check "...leaves the environment untouched" [ "$(inodes "$E/broken")" -eq "$n0" ]
check "...registers nothing" [ -z "$(state broken)" ]
check "...and leaves no image or partial" [ -z "$(ls -A "$E/.squashed" | grep '^broken')" ]

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
check "exec works over a stale mount" [ $rc -eq 0 ] && [ "$(tail -1 <<<"$out")" = 3 ]
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
check "umount succeeds once that shell is gone" [ $rc -eq 0 ] && [ "$(nmounts "$E/plain")" -eq 0 ]

"$CS" mount plain >/dev/null 2>&1
"$E/plain/bin/python" idle 30 & sp=$!
sleep 0.5
"$CS" umount plain --force >/dev/null 2>&1; rc=$?
check "umount --force unmounts anyway" [ $rc -eq 0 ] && [ "$(nmounts "$E/plain")" -eq 0 ]
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
    echo "active_after=${CONDA_SQUASH_ACTIVE:-unset}"
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
"$CS" umount plain >/dev/null 2>&1; rc1=$?
"$CS" umount plain2 >/dev/null 2>&1; rc2=$?
check "shells that exited leave no activation records blocking umount" [ $rc1 -eq 0 ] && [ $rc2 -eq 0 ]

# ------------------------------------------------------------------------------
section "exec"
out=$("$CS" exec plain -- sh -c 'cat "$CONDA_PREFIX/lib/f2"; echo "ns=$CONDA_SQUASH_NS"; exit 7' 2>&1); rc=$?
check "exec runs the command inside the environment" grep -qx 2 <<<"$out"
check "exec returns the command's exit status" [ $rc -eq 7 ]
check "exec marks the namespace it runs in" grep -qx 'ns=plain' <<<"$out"
out=$("$CS" exec plain -- "$CS" mount plain2 2>&1); rc=$?
check "mount is refused inside exec" [ $rc -ne 0 ] && grep -q 'inside' <<<"$out"
for i in 1 2 3 4 5 6 7 8; do "$CS" exec plain -- cat "$E/plain/lib/f1" >"$BASE/ex.$i" 2>&1 & done; wait
check "eight concurrent execs all see the environment" [ "$(cat "$BASE"/ex.* | sort -u | tr -d '\n')" = 1 ]
"$CS" mount plain >/dev/null 2>&1
out=$("$CS" exec plain -- python where 2>&1)
check "exec uses an existing mount" [ "$out" = "$E/plain" ]
"$CS" umount plain >/dev/null 2>&1
out=$("$CS" exec c1 -- cat "$E/c1/lib/f4" 2>&1); rc=$?
check "exec tries the image of a --keep environment" [ $rc -eq 0 ] && [ "$out" = 4 ]
"$CS" exec plain -- sleep 30 & xp=$!
sleep 1
kill -9 $xp; wait $xp 2>/dev/null; sleep 1
check "a SIGKILLed exec leaves no squashfuse process behind" [ "$(daemons)" -eq 0 ]
# The command itself outlives a SIGKILL of its launcher, as any child would.
pkill -u "$ME" -xf 'sleep 30' || true
sleep 1
check "no squashfuse processes left after exec" [ "$(daemons)" -eq 0 ]

# ------------------------------------------------------------------------------
section "interrupts"
mkenv "$E" slow 4000
n0=$(inodes "$E/slow")
"$CS" pack "$E/slow" -y -j 1 >"$BASE/slow.log" 2>&1 & pp=$!
until grep -q '^packing' "$BASE/slow.log" 2>/dev/null || ! kill -0 $pp 2>/dev/null; do sleep 0.05; done
kill -TERM $pp; wait $pp; rc=$?
check "SIGTERM during the image build stops pack" [ $rc -ne 0 ]
check "...with the environment intact" [ "$(inodes "$E/slow")" -eq "$n0" ]
check "...no partial image" [ -z "$(ls -A "$E/.squashed" | grep '^slow')" ]
check "...and nothing registered" [ -z "$(state slow)" ]

mkenv "$E" stuck 50
chmod 555 "$E/stuck/lib"
"$CS" pack "$E/stuck" -y -j 1 >"$BASE/stuck.log" 2>&1; rc=$?
check "a delete that cannot finish still leaves a packed environment" [ $rc -eq 0 ] && [ "$(state stuck)" = packed ]
check "...warning about the leftovers" grep -q 'could not fully remove' "$BASE/stuck.log"
trash=$(ls -d "$E"/.conda-squash-trash.stuck.* 2>/dev/null | head -1)
check "...which sit in a trash directory" [ -n "$trash" ]
chmod -R u+w "$trash" 2>/dev/null
"$CS" mount stuck >"$BASE/stuck2.log" 2>&1; rc=$?
check "the next mount works" [ $rc -eq 0 ] && [ "$(ls "$E/stuck/lib" | wc -l)" -eq 50 ]
check "...and clears the leftovers" [ -z "$(ls -d "$E"/.conda-squash-trash.stuck.* 2>/dev/null)" ]
"$CS" umount stuck >/dev/null 2>&1

# ------------------------------------------------------------------------------
section "forget and unpack"
"$CS" mount plain >/dev/null 2>&1
"$CS" forget plain >/dev/null 2>&1; rc=$?
check "forget refuses a mounted environment" [ $rc -ne 0 ] && [ "$(state plain)" = mounted ]
"$CS" umount plain >/dev/null 2>&1
"$CS" forget plain >/dev/null 2>&1; rc=$?
check "forget refuses when the image is the only copy" [ $rc -ne 0 ] && [ "$(state plain)" = packed ]
"$CS" forget notty >/dev/null 2>&1; rc=$?
check "forget drops a --keep environment" [ $rc -eq 0 ] && [ -z "$(state notty)" ]

"$CS" unpack plain >/dev/null 2>&1; rc=$?
check "unpack restores the environment" [ $rc -eq 0 ] && [ "$(state plain)" = kept ]
check "...with every file" [ "$(ls "$E/plain/lib" | wc -l)" -eq 20 ] && [ "$(cat "$E/plain/lib/f20")" = 20 ]
check "...and runs natively" [ "$("$E/plain/bin/python" where)" = "$E/plain" ]
check "...leaving no restore directory behind" [ -z "$(ls -A "$E" | grep conda-squash-unpack)" ]
"$CS" unpack plain >/dev/null 2>&1; rc=$?
check "unpack refuses to overwrite a live environment" [ $rc -ne 0 ]
"$CS" pack "$E/plain" -y -j 1 >/dev/null 2>&1; rc=$?
check "an unpacked environment packs again" [ $rc -eq 0 ] && [ "$(state plain)" = packed ]

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
