#!/usr/bin/env bash
# truba_env.sh — load the CUDA toolchain + Python + the project venv on TRUBA.
#
# Usage:   source deploy/truba_env.sh
#
# Tested on cuda-ui (TRUBA ARF-ACC login node, Jun 2026). Module names below
# match the actual Tcl Environment Modules tree at /arf/sw/modulefiles.
# Override versions with environment variables if the cluster offers newer:
#     EVM_CUDA_MODULE=lib/cuda/13.0 source deploy/truba_env.sh

set -euo pipefail

# Locate the project root relative to this script (works after rsync).
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
PROJECT_ROOT="${PROJECT_ROOT:-$(dirname "$SCRIPT_DIR")}"

# --- 1. Modules -------------------------------------------------------------
# We're sourced from a SLURM job script or interactive srun; both run a
# login shell, so `module` is defined as a function. If not (rare), bail
# with a clear error rather than silently missing the toolchain.
if ! type module >/dev/null 2>&1; then
    echo "ERROR: 'module' command not available." >&2
    echo "       source this script from a login shell (slurm scripts run one)." >&2
    echo "       For an ad-hoc non-login shell, run: bash -lc 'source .../truba_env.sh'" >&2
    return 1 2>/dev/null || exit 1
fi

module purge 2>/dev/null || true
module load "${EVM_GCC_MODULE:-comp/gcc/12.3.0}"
# NOTE: prefer comp/python/miniconda3 over comp/python/3.12.0 — the latter
# is missing _ctypes (no libffi at build time), which breaks scipy/numpy.
module load "${EVM_PYTHON_MODULE:-comp/python/miniconda3}"
module load "${EVM_CUDA_MODULE:-lib/cuda/12.6}"
module load "${EVM_CMAKE_MODULE:-comp/cmake/3.31.1}"

# Point NVCC at the matching host compiler so it doesn't fall back to a
# mismatched system g++.
export CUDAHOSTCXX="$(command -v g++)"
export CC="$(command -v gcc)"
export CXX="$(command -v g++)"

# --- 2. Virtualenv ----------------------------------------------------------
VENV="$PROJECT_ROOT/.venv"
if [[ ! -d "$VENV" ]]; then
    echo "[truba_env] creating venv at $VENV" >&2
    python3 -m venv "$VENV"
fi
# Activate unconditionally (re-source safe).
# shellcheck disable=SC1091
source "$VENV/bin/activate"
python -m pip install --upgrade pip --quiet >&2 || true

# Install Python deps if missing. pybind11 and pytest are needed for the
# extension build and the test suite; requirements.txt pins the rest.
if ! python -c "import numpy, cv2, scipy, pytest, pybind11" 2>/dev/null; then
    echo "[truba_env] installing Python deps" >&2
    python -m pip install --quiet \
        -r "$PROJECT_ROOT/requirements.txt" pybind11 pytest
fi

# pybind11 needs to know where its headers are; expose them for CMake.
export pybind11_DIR="$(python -c 'import pybind11; print(pybind11.get_cmake_dir())')"
export PROJECT_ROOT
echo "[truba_env] nvcc=$(nvcc --version | tail -1 | sed 's/.*release /v/; s/,.*//')" \
     "  python=$(python --version 2>&1)" \
     "  gcc=$(gcc -dumpversion)" >&2
