#!/usr/bin/env bash
# truba_env.sh — load the CUDA toolchain + Python + the project venv on TRUBA.
#
# Usage:   source deploy/truba_env.sh
#
# Tested on cuda-ui (TRUBA ARF-ACC login node) and palamut-cuda compute nodes.
#
# Venv location policy:
#   - Default: $PROJECT_ROOT/.venv (on WEKA scratch, persists across jobs).
#   - If EVM_VENV_ON_TMP=1: build/keep the venv on node-local /tmp instead.
#     This costs ~30s of rebuild per job but sidesteps WEKA cache staleness
#     and I/O errors that we've observed on /arf/scratch in some windows.
#     Recommended when WEKA is acting up.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
PROJECT_ROOT="${PROJECT_ROOT:-$(dirname "$SCRIPT_DIR")}"

# --- 1. Modules -------------------------------------------------------------
if ! type module >/dev/null 2>&1; then
    echo "ERROR: 'module' command not available — source from a login shell." >&2
    echo "       SLURM scripts use #!/bin/bash -l; ad-hoc shells: bash -lc '...'" >&2
    return 1 2>/dev/null || exit 1
fi

module purge 2>/dev/null || true
module load "${EVM_GCC_MODULE:-comp/gcc/12.3.0}"
module load "${EVM_PYTHON_MODULE:-comp/python/miniconda3}"
module load "${EVM_CUDA_MODULE:-lib/cuda/12.6}"
module load "${EVM_CMAKE_MODULE:-comp/cmake/3.31.1}" 2>/dev/null || true

# cmake isn't present on all partitions (palamut has the module, kolyoz
# doesn't). If `module load` didn't provide it, fall back to a pip-installed
# cmake wheel inside the venv (set up below).
if ! command -v cmake >/dev/null 2>&1; then
    export EVM_NEED_PIP_CMAKE=1
else
    export EVM_NEED_PIP_CMAKE=0
fi

export CUDAHOSTCXX="$(command -v g++)"
export CC="$(command -v gcc)"
export CXX="$(command -v g++)"

# --- 2. Virtualenv ----------------------------------------------------------
# Where to put the venv. /tmp is node-local (rebuilt per job) but reliable;
# $PROJECT_ROOT/.venv is on WEKA (persistent but occasionally flaky).
if [[ "${EVM_VENV_ON_TMP:-0}" == "1" ]]; then
    VENV="/tmp/evm_venv_${SLURM_JOB_ID:-$$}"
    VENV_ALWAYS_FRESH=1
else
    VENV="$PROJECT_ROOT/.venv"
    VENV_ALWAYS_FRESH=0
fi

if [[ "$VENV_ALWAYS_FRESH" == "1" ]]; then
    # /tmp venv: always rebuild (node-local, doesn't persist between jobs).
    # Also remove the stale WEKA .venv marker so we never accidentally
    # try to activate the wrong venv.
    rm -f "$PROJECT_ROOT/.venv/.evm_deps_marker"
    echo "[truba_env] building fresh venv at $VENV" >&2
    rm -rf "$VENV"
    python3 -m venv "$VENV"
    # Use the venv's python directly (more robust than `source activate`).
    export PYTHONPATH=""
    export PATH="$VENV/bin:$PATH"
    hash -r 2>/dev/null || true
    python3 -m pip install --quiet \
        -r "$PROJECT_ROOT/requirements.txt" pybind11 pytest
    if [[ "$EVM_NEED_PIP_CMAKE" == "1" ]]; then
        python3 -m pip install --quiet cmake
    fi
elif [[ ! -d "$VENV/lib" ]]; then
    echo "[truba_env] building venv at $VENV" >&2
    rm -rf "$VENV"
    python3 -m venv "$VENV"
    export PATH="$VENV/bin:$PATH"
    hash -r 2>/dev/null || true
    python3 -m pip install --quiet \
        -r "$PROJECT_ROOT/requirements.txt" pybind11 pytest
    if [[ "$EVM_NEED_PIP_CMAKE" == "1" ]]; then
        python3 -m pip install --quiet cmake
    fi
    touch "$VENV/.evm_deps_marker"
else
    # Persistent WEKA venv from a prior session.
    export PATH="$VENV/bin:$PATH"
    hash -r 2>/dev/null || true
fi

# pybind11 needs to know where its headers are; expose them for CMake.
export pybind11_DIR="$(python -c 'import pybind11; print(pybind11.get_cmake_dir())')"
export PROJECT_ROOT
echo "[truba_env] nvcc=$(nvcc --version | tail -1 | sed 's/.*release /v/; s/,.*//')" \
     "  python=$(python --version 2>&1)" \
     "  gcc=$(gcc -dumpversion)" \
     "  venv=$VENV" >&2
