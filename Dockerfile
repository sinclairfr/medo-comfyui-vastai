# Vast.ai ComfyUI image — extends vastai/comfy which has ComfyUI + supervisor pre-installed.
# Delegates startup to /opt/instance-tools/bin/entrypoint.sh (Vast.ai equivalent of RunPod's /start.sh).
FROM --platform=linux/amd64 vastai/comfy:v0.19.3-cuda-12.9-py312

# ---------------------------------------------------------------------------
# System tools — the stuff you always need when SSHed into a pod
# ---------------------------------------------------------------------------
RUN apt-get update && apt-get install -y --no-install-recommends \
    # editors
    nano \
    vim \
    # process / network inspection
    lsof \
    iproute2 \
    net-tools \
    iputils-ping \
    procps \
    # file tools
    tree \
    jq \
    unzip \
    zip \
    rsync \
    pv \
    # build essentials
    git \
    curl \
    wget \
    ca-certificates \
    build-essential \
    # misc
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
# blinker is pre-installed by Debian in this base; remove it so pip can manage it
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

# Isolated venv for ai-toolkit (uv venv is faster and works in this image)
RUN uv venv /opt/ai-toolkit-venv

# torch 2.7.0+cu128 — matches the CUDA version in the vastai/comfy base
RUN uv pip install --python /opt/ai-toolkit-venv/bin/python --no-cache-dir \
    torch==2.7.0 torchvision==0.22.0 torchaudio==2.7.0 \
    --index-url https://download.pytorch.org/whl/cu128

# ai-toolkit Python requirements + gradio
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
# Wrapper
# ---------------------------------------------------------------------------
COPY start_wrapper.sh /start_wrapper.sh
RUN chmod +x /start_wrapper.sh

ENTRYPOINT ["/start_wrapper.sh"]
