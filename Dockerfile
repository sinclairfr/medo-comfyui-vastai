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
# blinker is pre-installed by Debian; remove it so uv can manage it
# ---------------------------------------------------------------------------
RUN apt-get remove -y --purge python3-blinker 2>/dev/null || true \
    && uv pip install --system --no-cache-dir flask boto3 python-dotenv

# ---------------------------------------------------------------------------
# ComfyUI custom node deps
# ---------------------------------------------------------------------------
RUN uv pip install --system --no-cache-dir \
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

# Isolated venv for ai-toolkit
RUN uv venv /opt/ai-toolkit-venv

RUN uv pip install --python /opt/ai-toolkit-venv/bin/python --no-cache-dir \
    torch==2.7.0 torchvision==0.22.0 torchaudio==2.7.0 \
    --index-url https://download.pytorch.org/whl/cu128

RUN uv pip install --python /opt/ai-toolkit-venv/bin/python --no-cache-dir \
    -r /opt/ai-toolkit/requirements.txt

RUN uv pip install --python /opt/ai-toolkit-venv/bin/python --no-cache-dir \
    accelerate transformers diffusers huggingface_hub gradio

# Build the Next.js UI
RUN cd /opt/ai-toolkit/ui \
    && npm install \
    && npx prisma generate \
    && npm run build

# ---------------------------------------------------------------------------
# Boot script — runs via Vast.ai's /etc/vast_boot.d/ mechanism.
# Keeps the Vast.ai portal/splashscreen intact.
# ---------------------------------------------------------------------------
COPY start_wrapper.sh /etc/vast_boot.d/50-medo.sh
RUN chmod +x /etc/vast_boot.d/50-medo.sh
