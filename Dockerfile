FROM vastai/comfy:v0.19.3-cuda-12.9-py312

SHELL ["/bin/bash", "-o", "pipefail", "-c"]

ENV DEBIAN_FRONTEND=noninteractive \
    WORKSPACE=/workspace \
    S3_OFFLOADER_PORT=5055 \
    FILEBROWSER_PORT=8081 \
    AI_TOOLKIT_PORT=8675 \
    RUN_AI_TOOLKIT=false

RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates curl wget git jq unzip zip rsync net-tools lsof \
    procps iproute2 supervisor gnupg software-properties-common \
    && rm -rf /var/lib/apt/lists/*

RUN curl -fsSL https://deb.nodesource.com/setup_20.x | bash - \
    && apt-get update && apt-get install -y --no-install-recommends nodejs \
    && rm -rf /var/lib/apt/lists/*

RUN pip install --no-cache-dir \
    flask boto3 python-dotenv gguf scikit-image dill piexif imageio-ffmpeg \
    ultralytics segment-anything albumentations

RUN curl -fsSL https://raw.githubusercontent.com/filebrowser/get/master/get.sh | bash

COPY supervisord/supervisord.conf /etc/supervisor/supervisord.conf
COPY supervisord/programs/*.conf /opt/medo/supervisor-templates/
COPY scripts/discover_ai_dock_portal.sh /opt/medo/scripts/discover_ai_dock_portal.sh

RUN chmod +x /opt/medo/scripts/discover_ai_dock_portal.sh

EXPOSE 8188 8888 8080 8675 5055 8081
