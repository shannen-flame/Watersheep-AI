# Watersheep Backend

FastAPI backend for the Watersheep smart glasses assistant. It stores memories in SQLite, supports recall and daily summaries, accepts image uploads for vision analysis, and proxies vision requests through Gemini with an Ollama fallback.

## Setup

From `watersheep/backend`:

```bash
cd watersheep/backend
python3 -m venv .venv
source .venv/bin/activate
python -m pip install -r requirements.txt
cp .env.example .env
```

If you already have a local `.env`, keep it and just fill in any new values.

For a local Llama setup with Ollama, set in `.env`:

```bash
WATERSHEEP_LLM_PROVIDER=ollama
WATERSHEEP_LLM_MODEL=llama3.2:3b
OLLAMA_BASE_URL=http://127.0.0.1:11434
```

Then make sure Ollama is running and the models are pulled:

```bash
ollama pull llama3.2:3b
ollama pull gemma3
ollama serve
```

## Run

```bash
cd watersheep/backend
source .venv/bin/activate
python -m uvicorn main:app --reload --host 0.0.0.0 --port 8000
```

Open:

- `http://127.0.0.1:8000/docs`
- `http://127.0.0.1:8000/health`

For iPhone testing on the same Wi-Fi network, point the app at your Mac's LAN IP, for example `http://192.168.1.235:8000`. The phone cannot reach `127.0.0.1` or `localhost` on the Mac; those addresses point to the phone itself.

## Main Endpoints

- `GET /health`
- `POST /api/memories`
- `GET /api/memories`
- `POST /api/recall`
- `POST /api/summarise-day`
- `POST /api/vision/analyze` (preferred image analysis endpoint, multipart or JSON)
- `POST /vision/analyze` (legacy alias kept for compatibility)
- `POST /api/quick-actions`

## Notes

- The app uses a modular `app/routers`, `app/services`, `app/models`, and `app/utils` structure.
- SQLite data is stored locally in `watersheep/backend/watersheep.db` and runs in WAL mode for concurrent access.
- Uploads are saved under `watersheep/backend/uploads/`.
- Image uploads and base64 frames are capped by `WATERSHEEP_MAX_IMAGE_BYTES`, `WATERSHEEP_MAX_IMAGE_PIXELS`, and `WATERSHEEP_MAX_IMAGE_DIMENSION`.
- CORS is open in development. Set `WATERSHEEP_CORS_ORIGINS` to a comma-separated allow-list in production.
- Diagnostic routes such as `GET /api/events` are hidden in production unless `WATERSHEEP_DEBUG_ENDPOINTS=true`.
- `POST /api/ask` supports optional `llm_provider` and `llm_model` fields, so you can override the default model per request.
- `POST /api/vision/analyze` accepts either multipart image uploads or JSON with `image_base64`, plus optional `prompt`, `scene_summary`, and `model`. The backend tries Gemini first and falls back to Ollama or a local summary as needed.
