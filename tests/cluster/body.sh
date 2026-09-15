#!/bin/bash
# An ordinary job body, written the way lab jobs use conda.  It knows nothing
# about haversack.  Every check runs in its own subshell and prints
# "CHECK <name> ok" or "CHECK <name> FAIL", so one run reports every pattern
# instead of stopping at the first failure.
set -euo pipefail

: "${CANARY_NAME:?}" "${CANARY_PREFIX:?}" "${CONDA_SETUP:?}"
LOGS=$(mktemp -d)

# Each check starts from nothing, as a fresh job script would.
c_conda_setup() {
    eval "$CONDA_SETUP"
    command -v conda
}

c_activate_by_name() {
    eval "$CONDA_SETUP"
    eval "$(conda shell.bash hook)"
    conda activate "$CANARY_NAME"
    [ "$(cd "$CONDA_PREFIX" && pwd -P)" = "$CANARY_PREFIX" ]
    python -c 'import numpy'
}

c_activate_by_path() {
    eval "$CONDA_SETUP"
    source "$(conda info --base)/etc/profile.d/conda.sh"
    conda activate "$CANARY_PREFIX"
    python -c 'import numpy'
}

c_activate_hooks_run() {
    eval "$CONDA_SETUP"
    eval "$(conda shell.bash hook)"
    conda activate "$CANARY_NAME"
    ls "$CONDA_PREFIX"/etc/conda/activate.d/*.sh
    [ -n "${XML_CATALOG_FILES:-}" ]
}

c_deactivate_under_set_u() {
    eval "$CONDA_SETUP"
    eval "$(conda shell.bash hook)"
    conda activate "$CANARY_NAME"
    conda deactivate
}

c_env_listed() {
    eval "$CONDA_SETUP"
    conda info --envs | grep -q "$CANARY_NAME"
}

c_hardcoded_python() {
    "$CANARY_PREFIX/bin/python" -c 'import numpy as np; assert np.linalg.det(np.eye(3)) == 1'
}

c_hardcoded_tool() {
    "$CANARY_PREFIX/bin/minimap2" --version
}

c_home_symlink_tool() {
    "$HOME/.conda/envs/$CANARY_NAME/bin/minimap2" --version
}

c_sys_prefix_matches() {
    local p
    p=$("$CANARY_PREFIX/bin/python" -c 'import sys; print(sys.prefix)')
    [ "$(cd "$p" && pwd -P)" = "$CANARY_PREFIX" ]
}

failed=0
set +e
for c in c_conda_setup c_activate_by_name c_activate_by_path c_activate_hooks_run \
         c_deactivate_under_set_u c_env_listed c_hardcoded_python c_hardcoded_tool \
         c_home_symlink_tool c_sys_prefix_matches; do
    ( set -euo pipefail; "$c" ) > "$LOGS/$c" 2>&1
    if [ $? -eq 0 ]; then
        echo "CHECK ${c#c_} ok"
    else
        echo "CHECK ${c#c_} FAIL"
        tail -3 "$LOGS/$c" | sed 's/^/    | /'
        failed=$((failed + 1))
    fi
done
set -e
rm -rf "$LOGS"
echo "BODY failed=$failed"
