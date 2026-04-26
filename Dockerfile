# Vast.ai ComfyUI image — extends vastai/comfy.
# Does NOT override ENTRYPOINT so the Vast.ai portal/splashscreen is preserved.
# Custom services (S3 offloader, ai-toolkit) are started via /etc/vast_boot.d/
FROM vastai/comfy:v0.19.3-cuda-12.9-py312

# ---------------------------------------------------------------------------
# System tools — the stuff you always need when SSHed into a pod
# ---------------------------------------------------------------------------
RUN apt-get update && apt-get install -y --no-install-recommends \
    nano \
    vim \
    lsof \
    iproute2 \
    net-tools \
    iputils-ping \
    procps \
    tree \
    jq \
    unzip \
    zip \
    rsync \
    pv \
    htop \
    tmux \
    screen \
    less \
    && rm -rf /var/lib/apt/lists/*

# ---------------------------------------------------------------------------
# Node.js 20 (required for ai-toolkit UI)
# ---------------------------------------------------------------------------
RUN curl -fsSL https://deb.nodesource.com/setup_20.x | bash - \
    && apt-get install -y nodejs \
    && rm -rf /var/lib/apt/lists/*

# ---------------------------------------------------------------------------
# S3 offloader deps
# Base image has an unmanaged blinker install (no RECORD), so force-reinstall
# avoids uninstall failures during dependency resolution.
# ---------------------------------------------------------------------------
RUN apt-get remove -y --purge python3-blinker 2>/dev/null || true \
    && python3 -m pip install --no-cache-dir --break-system-packages \
       --ignore-installed blinker flask boto3 python-dotenv

# ---------------------------------------------------------------------------
# ComfyUI custom node deps
# ---------------------------------------------------------------------------
RUN python3 -m pip install --no-cache-dir --break-system-packages \
    gguf \
    scikit-image \
    ultralytics \
    dill \
    piexif \
    segment-anything \
    albumentations \
    imageio-ffmpeg

# ---------------------------------------------------------------------------
# ai-toolkit — cloned into /opt/ai-toolkit
# ---------------------------------------------------------------------------
RUN git clone --depth=1 https://github.com/ostris/ai-toolkit.git /opt/ai-toolkit \
    && cd /opt/ai-toolkit \
    && git submodule update --init --recursive

# Install ai-toolkit Python deps into the base image venv (/venv/main).
# /venv/main already contains a CUDA-compatible PyTorch used by ComfyUI, so
# we avoid downloading a duplicate torch+torchvision+torchaudio stack (~10 GB).
# pip skips packages whose version constraints are already satisfied.
RUN /venv/main/bin/python3 -m pip install --no-cache-dir \
    -r /opt/ai-toolkit/requirements.txt

RUN /venv/main/bin/python3 -m pip install --no-cache-dir \
    accelerate transformers diffusers huggingface_hub gradio

# Build the Next.js UI; clean the npm cache afterwards (node_modules kept for
# `next start` and `node dist/cron/worker.js` at runtime).
RUN cd /opt/ai-toolkit/ui \
    && npm install \
    && npx prisma generate \
    && npm run build \
    && npm cache clean --force

# ---------------------------------------------------------------------------
# Exposed ports
#   8188 — ComfyUI (started by base image entrypoint)
#   8675 — ai-toolkit UI (started by boot hook when RUN_AI_TOOLKIT=true)
# ---------------------------------------------------------------------------
EXPOSE 8188 8675

# ---------------------------------------------------------------------------
# Boot hook — runs via Vast.ai's /etc/vast_boot.d/ mechanism.
# Keeps Vast portal/splashscreen + default service startup intact.
# ---------------------------------------------------------------------------
COPY vast_boot_services.sh /etc/vast_boot.d/70-medo-services.sh
RUN chmod +x /etc/vast_boot.d/70-medo-services.sh
