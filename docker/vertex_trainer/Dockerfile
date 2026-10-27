# Z-Image-Turbo LoRA trainer for Vertex AI Custom Training Jobs.
#
# Bakes in ostris/ai-toolkit (the CUDA trainer DN/BE's cloud_train.py submits
# jobs against) plus google-cloud-storage for the entrypoint's own GCS I/O.
# Built once, pushed to Artifact Registry; cloud_train.py references the
# pushed image URI via GCP_VERTEX_TRAIN_IMAGE in backend/.env.
#
# Build + push: see build_and_push.sh in this folder.

FROM nvidia/cuda:12.4.1-runtime-ubuntu22.04

ENV DEBIAN_FRONTEND=noninteractive
ENV PIP_NO_CACHE_DIR=1

# Ubuntu 22.04's own apt repo serves python3.11 as a pre-release RC1 build
# (confirmed live: `sys.version` reports "3.11.0rc1" inside a container built
# this way), which is missing stdlib additions that landed later in the 3.11
# release-candidate cycle (sys.get_int_max_str_digits, needed by a torch
# polyfill ai-toolkit's deps pull in) - torch dies at import time with
# AttributeError: module 'sys' has no attribute 'get_int_max_str_digits'.
# deadsnakes tracks genuine upstream CPython final releases instead.
#
# build-essential: Triton JIT-compiles some CUDA kernels at runtime and
# needs a real C compiler to do it - the CUDA "runtime" base image has none
# by design (confirmed live: "RuntimeError: Failed to find C compiler").
# python3.11-dev: that same JIT-compiled extension #includes <Python.h> -
# build-essential alone gets you gcc, but not Python's C headers (confirmed
# live: "fatal error: Python.h: No such file or directory").
RUN apt-get update && apt-get install -y --no-install-recommends \
        software-properties-common ca-certificates gnupg git ffmpeg \
    && add-apt-repository -y ppa:deadsnakes/ppa \
    && apt-get update && apt-get install -y --no-install-recommends \
        python3.11 python3.11-venv python3.11-distutils python3.11-dev \
        build-essential \
    && rm -rf /var/lib/apt/lists/* \
    && python3.11 -m ensurepip --upgrade

WORKDIR /opt
RUN git clone --depth 1 https://github.com/ostris/ai-toolkit.git ai-toolkit
WORKDIR /opt/ai-toolkit
RUN git submodule update --init --recursive || true
# ai-toolkit's own requirements_base.txt pins no torch/torchvision/torchaudio
# at all - it assumes you already installed the official PyTorch triplet
# yourself (its own setup docs say so). Left to pip's own resolver, torch
# only arrives transitively (as a dependency of accelerate/transformers/
# diffusers) with no torchaudio at all - confirmed live:
# "ModuleNotFoundError: No module named 'torchaudio'" from toolkit's own
# config_modules.py, which imports it unconditionally - and whatever torch
# build pip picks on its own isn't guaranteed to match this image's CUDA
# runtime (confirmed live: torch landed as 2.14.1+cu130 against a
# cuda:12.4.1 base). Installing the matched triplet from the official cu124
# index FIRST pins the version before requirements.txt's unpinned transitive
# pull can pick something else.
RUN python3.11 -m pip install --upgrade pip \
    && python3.11 -m pip install torch torchvision torchaudio \
        --index-url https://download.pytorch.org/whl/cu124 \
    && python3.11 -m pip install -r requirements.txt \
    && python3.11 -m pip install google-cloud-storage

# The cu124 wheel index tops out at torch 2.6.0 (confirmed live: no 2.7+
# published there) - getting a newer torch means switching CUDA wheel series
# entirely (cu126/cu128), which reopens the whole base-image-compatibility
# chain above for what's actually a one-line Python gap: see
# sitecustomize.py for the real explanation and the fix.
#
# PYTHONPATH, not a guessed sysconfig/site-packages location: a first
# attempt wrote sitecustomize.py into whatever sysconfig.get_paths()
# ['purelib'] reported, which turned out not to be on sys.path at runtime
# on this Debian-patched python3.11 (confirmed live: the patch never took
# effect). PYTHONPATH entries are added to sys.path directly by the
# interpreter before site.py's sitecustomize search runs, so this is the
# version that's actually guaranteed to be found - including by
# entrypoint.py's `subprocess.call(["python3.11", "run.py", ...])`, a
# separate process env vars set here still reach because ENV applies to
# every process in the image, not just the one that set it.
COPY sitecustomize.py /opt/pysitecustomize/sitecustomize.py
ENV PYTHONPATH=/opt/pysitecustomize

COPY entrypoint.py /opt/entrypoint.py

WORKDIR /workspace
ENTRYPOINT ["python3.11", "/opt/entrypoint.py"]
