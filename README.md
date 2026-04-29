# medo-comfyui-vastai

Script de démarrage personnel pour ComfyUI sur Vast.ai.

## Image de base

`ghcr.io/ai-dock/comfyui:v2-cuda-12.1.1-base-22.04`

Fournit out-of-the-box : file browser, terminal web, splashscreen, ComfyUI, Jupyter, Syncthing.

## Utilisation

Dans le template Vast.ai :

**Image** → `ghcr.io/ai-dock/comfyui:v2-cuda-12.1.1-base-22.04`

**On-start Script** :
```bash
entrypoint.sh
bash <(curl -fsSL https://raw.githubusercontent.com/sinclairfr/medo-comfyui-vastai/main/on_start.sh)
```

## Ce que `on_start.sh` ajoute

- Deps Python custom pour nodes ComfyUI (`ultralytics`, `gguf`, `segment-anything`…)
- `comfyui_S3_offloader` — démarré automatiquement à chaque boot
- `ai-toolkit` + UI Next.js sur `:8675` — optionnel, activer avec `RUN_AI_TOOLKIT=true`

Tout est caché dans `/workspace` (volume persistant) — la première instance est lente, les suivantes sont rapides.

## Variables d'environnement

| Variable | Défaut | Effet |
|----------|--------|-------|
| `RUN_AI_TOOLKIT` | `false` | `true` pour démarrer ai-toolkit sur :8675 |
| `HF_TOKEN` | — | Token HuggingFace (modèles privés) |

## Modifier le script

```bash
git clone https://github.com/sinclairfr/medo-comfyui-vastai
# éditer on_start.sh
git push
# la prochaine instance démarre avec la nouvelle version
```
