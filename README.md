# AI Adventure Master - Local Worker Files

Windows `.bat` files and scripts used by [AI Adventure Master](https://aiadventuremaster.space).

## Downloaded files

| File | Purpose |
|---|---|
| `StartFreeChat-*.bat` | Local free-chat relay for AI Adventure Master. |
| `StartImageGenerator-*.bat` | Local image worker/relay for AI Adventure Master. |
| `StartImage+Chat-*.bat` | Runs chat relay and image worker in one window. |
| `StartLocalAI-*.bat` | Connects an already running local OpenAI-compatible AI to AI Adventure Master. |

## How it works

### StartFreeChat

- Runs a local FastAPI chat relay on `127.0.0.1:8003` with an OpenAI-compatible `POST /v1/chat/completions` SSE endpoint.
- Connects the PC to AI Adventure Master through the connector WebSocket (`StartLocalAI-connector.ps1`).
- The site selects the provider via `X-Text-Provider`; the worker routes the request to the matching adapter and translates the provider response into OpenAI-style SSE chunks.
- When the connected relay is used, text requests go through the PC/IP/browser context instead of the shared site server IP.
- Some providers require a signed-in browser session. Depending on provider, the worker may use a parked Chrome/CDP session, DeepSeek session capture/PoW, or a page-context request.
- Runtime files live under `%LOCALAPPDATA%\AIAdventureMaster\free-chat`. While the console window is open, the relay/connection remains active.

### StartImageGenerator

- Runs a local FastAPI image worker on `127.0.0.1:8002`.
- Exposes `POST /v1/images/generations` (OpenAI-compatible shape, returns `b64_json`), `POST /proxy`, and `GET /healthz`.
- Connects the PC to AI Adventure Master through the connector WebSocket.
- Depending on request/config, the worker can forward browser-based image generation to the chat worker, use Duck.ai GPT Image 2, use Puter when configured, or use the imagefree upstream path.
- Runtime files live under `%LOCALAPPDATA%\AIAdventureMaster\image-generator`. While the console window is open, the worker/connection remains active.

### StartImage+Chat

- Runs the chat relay and image worker together in one console window.
- Combines the StartFreeChat and StartImageGenerator worker/connector flow.

### StartLocalAI

- Looks for a local OpenAI-compatible AI already running on the PC (Ollama, LM Studio, llama.cpp, vLLM, Jan, LocalAI, GPT4All, KoboldCpp, TabbyAPI, text-generation-webui, LiteLLM Proxy, one-api, FreeLLMAPI, etc.).
- Connects that local AI to AI Adventure Master through the connector.
- Does not install or start the local AI model itself.

## First run

On first run, a bat file may:

- extract embedded helper scripts into `%LOCALAPPDATA%\AIAdventureMaster\...`;
- download/install a private Python runtime;
- create a local Python virtual environment;
- install required Python packages;
- open a browser/Chrome window for provider sign-in or page context, if required by the selected provider.

Later runs reuse the prepared files.

## Scripts in this repository

| File | Description |
|---|---|
| `scripts/local-chat-worker.py` | Python FastAPI chat relay. Listens on `127.0.0.1:8003`, accepts OpenAI-compatible chat requests, selects an adapter by `X-Text-Provider`, handles browser-session/PoW/provider-specific flows, applies adapter cooldowns, and streams translated OpenAI SSE chunks. |
| `scripts/local-image-worker.py` | Python FastAPI image worker. Listens on `127.0.0.1:8002`, provides OpenAI-compatible image generation (`b64_json`), a generic `/proxy` for relaying requests from the user's IP, and `/healthz`. Can route image requests to chat-worker browser providers or other configured image backends. |
| `scripts/StartLocalAI-connector.ps1` | PowerShell connector that maintains the WebSocket connection to AI Adventure Master and forwards requests to local workers/models. |
| `scripts/StartLocalChatWorker.ps1` | PowerShell bootstrapper for the chat worker: prepares Python/runtime/venv, installs dependencies, and starts `local-chat-worker.py`. |
| `scripts/StartLocalImageWorker.ps1` | PowerShell bootstrapper for the image worker: prepares Python/runtime/venv, installs dependencies, and starts `local-image-worker.py`. |
| `scripts/*.bat.in` | Batch templates used to build distributable `.bat` files. |
| `scripts/build-*.ps1` | Build scripts that embed scripts/templates into distributable `.bat` files. |
