# Thin layer on top of ai-dock/comfyui — that image provides everything out
# of the box: file browser, web terminal, splashscreen, ComfyUI, Jupyter,
# Syncthing (ports 1111 / 8188 / 8888 / 8384).
#
# We only bake in on_start.sh, which installs and starts the medo custom
# tools (S3 offloader, ai-toolkit) at runtime without touching anything
# the base image owns.
#
# Vast.ai template — On-start Script:
#   entrypoint.sh
#   /opt/medo/on_start.sh
FROM ghcr.io/ai-dock/comfyui:v2-cuda-12.1.1-base-22.04

COPY on_start.sh /opt/medo/on_start.sh
RUN chmod +x /opt/medo/on_start.sh

# ai-toolkit UI port (optional service, only when RUN_AI_TOOLKIT=true)
EXPOSE 8675
