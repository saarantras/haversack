# Examples: conda and haversack side by side

Each task below shows the plain conda way first and the haversack way second.
The examples use an environment called `tz` in conda's default envs directory
(`~/.conda/envs`); substitute your own names and paths.

Commands that build or change an environment (`create`, `pack`, `install`,
`update`, `remove`, `edit`) do real work. On a cluster, run them inside an
allocation, not on a login node.

## Create an environment

conda:

```
conda create -n tz -c conda-forge python=3.11 numpy
```

haversack:

```
haversack create -n tz -c conda-forge python=3.11 numpy
```

Arguments after the name are passed to conda. The environment is built on
node-local disk and packed straight into an image; the only file written to the
shared filesystem is the image.

## Create from an environment file

conda:

```
conda env create -n tz -f environment.yml
```

haversack:

```
haversack create -n tz -f environment.yml
```

## Turn an existing environment into an image

conda: the environment stays as it is, tens of thousands of files.

haversack:

```
haversack pack ~/.conda/envs/tz --keep               # build and test the image; delete nothing
haversack exec tz -- python -c 'import numpy'        # try it
haversack pack ~/.conda/envs/tz                      # replace the environment with the image
```

## Work interactively

conda:

```
conda activate tz
python analysis.py
```

haversack:

```
haversack mount tz
conda activate tz
python analysis.py
haversack umount tz
```

or, for a single shell with the environment on `PATH`:

```
haversack shell tz
```

A mount made inside an allocation ends when the allocation does.

## Run a batch job

conda:

```
#!/bin/bash
#SBATCH -t 04:00:00
module load miniconda
eval "$(conda shell.bash hook)"
conda activate tz
python train.py
```

haversack:

```
#!/bin/bash
#SBATCH -t 04:00:00
haversack exec tz -- python train.py
```

`exec` puts the environment on `PATH` and runs its activation hooks, so the
command needs no `conda activate`. To leave an existing job body untouched, run
the whole body under `exec`; `conda activate tz` inside it works as before:

```
haversack exec tz -- bash job-body.sh
```

Do not use `mount` in batch jobs: the mount belongs to the job that made it,
and other jobs on the same node lose the environment when that job ends.

## Run a job array

conda:

```
#SBATCH --array=1-100
module load miniconda
eval "$(conda shell.bash hook)"
conda activate tz
python task.py "$SLURM_ARRAY_TASK_ID"
```

haversack:

```
#SBATCH --array=1-100
haversack exec tz -- python task.py "$SLURM_ARRAY_TASK_ID"
```

Every task gets its own private mount, so tasks sharing a node do not depend on
each other.

## Call an environment's interpreter by path

conda:

```
~/.conda/envs/tz/bin/python script.py
```

haversack:

```
haversack exec tz -- ~/.conda/envs/tz/bin/python script.py
```

The path does not change. Outside `exec` or a mount, it leads to a stub that
exits with status 127 and says how to run it.

## Run one command without activating

conda:

```
conda run -n tz python script.py
```

haversack:

```
haversack exec tz -- python script.py
```

## Install, update or remove packages

conda:

```
conda install -n tz -c conda-forge scipy
conda update -n tz --all
conda remove -n tz scipy
```

haversack:

```
haversack install tz -c conda-forge scipy
haversack update tz --all
haversack remove tz scipy
```

Each rebuilds the image on node-local disk and swaps it in. Unmount the
environment on this node first if it is mounted; commands already running under
`exec` keep the old image until they finish.

## Install with pip

conda:

```
conda activate tz
pip install some-package
```

haversack:

```
haversack edit tz -- pip install some-package
```

If the command fails, nothing is saved.

## Make several changes at once

conda:

```
conda activate tz
conda install -c conda-forge scipy
pip install some-package
```

haversack:

```
haversack edit tz
conda install -c conda-forge scipy
pip install some-package
exit
```

`edit` opens a shell with the environment writable, and asks whether to save
when the shell exits. Everything is repacked once.

## Check whether an environment exists

conda:

```
conda env list | grep -q tz
```

haversack:

```
haversack list | awk '$1 == "tz"'
```

`conda env list` only shows a packed environment where it is mounted or inside
`exec`. `haversack list` shows it everywhere, with its state on this node.

## Use pip-installed CUDA wheels

conda:

```
conda activate tz
export LD_LIBRARY_PATH=$(ls -d "$CONDA_PREFIX"/lib/python*/site-packages/nvidia/*/lib | paste -sd:):$LD_LIBRARY_PATH
python train.py
```

haversack, once:

```
haversack pack ~/.conda/envs/tz --fix-cuda
```

then every time:

```
haversack exec tz -- python train.py
```

`--fix-cuda` writes the `LD_LIBRARY_PATH` change into the environment's
`activate.d`, and undoes it in `deactivate.d`. `create`, `install`, `update` and
`remove` accept it too.

## Go back to a plain environment

conda: nothing to do.

haversack:

```
haversack umount tz                  # if it is mounted on this node
haversack unpack tz
```

The image is left in place; once the environment is back, remove it with
`haversack forget tz` and `rm ~/.conda/envs/.haversack/tz.sqfs`.

## Delete an environment

conda:

```
conda env remove -n tz
```

haversack:

```
haversack delete tz
```

It asks for confirmation; `-y` skips that, and it refuses while the environment
is mounted on this node. Commands already running from the environment under
`exec`, on any node, keep it until they finish. The environment's directory is
left behind, empty, because removing it would cut those commands off; `rmdir`
it once nothing is running from it.
