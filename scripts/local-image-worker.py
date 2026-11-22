#!/usr/bin/env python3
"""Local image worker for agent offload.

Listens on http://127.0.0.1:8002 and exposes:
- POST /v1/images/generations (OpenAI-compatible shape) - draws through the
  player's signed-in Gemini tab (via the chat worker on 8003), then Duck.ai's
  GPT Image 2, then Puter when PUTER_ACCESS_TOKEN is set. Always returns
  b64_json and names the model that actually drew the picture. Z-Image-Turbo
  is NOT part of this chain: the site draws it itself from imagefree.net,
  with no bat file and no browser tab.
- POST /proxy - generic HTTP proxy (for relaying Pollinations/Horde calls
  from the user's IP).
- GET /healthz - health check.

This runs entirely on the user's machine when launched via the bundled
bat/ps1. No automatic startup from the browser.

Why plain HTTP instead of a browser: imagefree.net's generator page is a
Next.js client over two XHR endpoints, POST /api/generate (returns a
taskId) and GET /api/generate/status?taskId=... (progress, then the image
URL). Those are the same requests the page makes, so a plain client does
exactly what the browser did - but without a 1-2 GB Camoufox download, a
visible window, guessed CSS selectors or waiting minutes for a form that
never produced a picture. In the default chain those calls are no longer
used at all: imagefree.net is reached by the SITE directly. An explicitly
requested "imagefree" model still works here from the player's own IP.
"""
from __future__ import annotations

import asyncio
import base64
import json
import logging
import os
import re
import time
from typing import Any, Dict
from urllib.parse import urlparse

import httpx
from fastapi import FastAPI, HTTPException, Request
from fastapi.responses import JSONResponse

log = logging.getLogger("local-image-worker")

# The worker is copied next to image-worker.ps1, whose log this shares:
# uvicorn runs hidden, so a file is the only place a failure can be read.
_LOG_PATH = os.path.join(os.path.dirname(os.path.abspath(__file__)), "image-worker.log")
logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s %(levelname)s %(name)s %(message)s",
    handlers=[logging.FileHandler(_LOG_PATH, encoding="utf-8"), logging.StreamHandler()],
)

app = FastAPI(title="Local Image Worker", version="2.0.0")

# The free image service. Here the requests leave from the player's machine
# instead of the site's server.
UPSTREAM = os.getenv("IMAGE_WORKER_UPSTREAM", "https://imagefree.net").rstrip("/")
# Reported to the site so the background status can name the exact upstream.
IMAGE_PROVIDER = urlparse(UPSTREAM).hostname or "imagefree.net"
# The concrete models behind the free image services, for the Settings
# status line. imagefree.net's own site credits Z-Image-Turbo (8-step DiT);
# Duck.ai's own engineering podcast names GPT Image 2; the Gemini tab uses the
# Flash web model with native Nano Banana image generation.
IMAGE_MODEL = os.getenv("IMAGE_WORKER_MODEL", "z-image-turbo")
GEMINI_IMAGE_MODEL = "gemini-flash-image"
DUCK_IMAGE_MODEL = "gpt-image-2"
# Puter's browser API (/drivers/call) needs a free account token. The owner can
# put it in PUTER_ACCESS_TOKEN next to the other worker settings; without it the
# Puter rung simply reports "not configured" and the site tries its own server.
PUTER_API = os.getenv("PUTER_API", "https://api.puter.com").rstrip("/")
PUTER_IMAGE_MODEL = os.getenv("PUTER_IMAGE_MODEL", "gpt-image-2.6-flare")
PUTER_IMAGE_MODEL_LABEL = "puter / " + PUTER_IMAGE_MODEL
PUTER_ACCESS_TOKEN = os.getenv("PUTER_ACCESS_TOKEN", "").strip()
PUTER_IMAGE_TIMEOUT = float(os.getenv("PUTER_IMAGE_TIMEOUT", "90"))

# The server gives this call Background:ImageApiTimeoutSeconds + 10 (190s by
# default), so stop polling a little before that: a clear "timed out" beats the
# server giving up first and reporting nothing.
POLL_TIMEOUT = float(os.getenv("IMAGE_WORKER_TIMEOUT", "175"))
POLL_INTERVAL = float(os.getenv("IMAGE_WORKER_POLL_INTERVAL", "3"))

# The chat worker owns the player's Gemini/DeepSeek/Arena/Duck browser
# sessions. Image requests for those providers are forwarded to its image
# endpoint. Anything else keeps using imagefree.net exactly as before.
CHAT_WORKER_URL = os.getenv("CHAT_WORKER_URL", "http://127.0.0.1:8003").rstrip("/")
# The site allows one generation ~190s. Cap each browser attempt so two failed
# attempts still leave room for the site's own Z-Image-Turbo path.
GEMINI_IMAGE_TIMEOUT = float(os.getenv("GEMINI_IMAGE_TIMEOUT", "50"))
DUCK_IMAGE_TIMEOUT = float(os.getenv("DUCK_IMAGE_TIMEOUT", "65"))

# Same shape the page sends: a same-origin fetch with a browser user agent.
# Referer/Origin matter to the upstream's WAF, not to us.
_HEADERS = {
    "User-Agent": (
        "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 "
        "(KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36"
    ),
    "Accept": "*/*",
    "Content-Type": "application/json",
    "Origin": UPSTREAM,
    "Referer": UPSTREAM + "/",
    "Accept-Language": "en-US,en;q=0.9",
    "Sec-Fetch-Dest": "empty",
    "Sec-Fetch-Mode": "cors",
    "Sec-Fetch-Site": "same-origin",
}

_RATIO = re.compile(r"^\d{1,2}:\d{1,2}$")


def _aspect(body: Dict[str, Any]) -> str:
    """The ratio the site understands: its own value, else the page default."""
    ratio = str(body.get("aspect_ratio") or "").strip()
    if _RATIO.match(ratio):
        return ratio

    width, height = body.get("width"), body.get("height")
    try:
        width, height = int(width), int(height)
        if width > 0 and height > 0:
            a, b = width, height
            while b:
                a, b = b, a % b
            return f"{width // a}:{height // a}"
    except (TypeError, ValueError):
        pass
    return "1:1"


def _error_detail(data: Dict[str, Any]) -> str:
    message = data.get("error")
    code = data.get("errorCode")
    if message and code:
        return f"{message} ({code})"
    return str(message or code or "the upstream rejected the request")


async def _submit(client: httpx.AsyncClient, prompt: str, aspect: str) -> str:
    """Creates the generation task and returns its id.

    The free queue accepts an anonymous request (turnstile_token null) exactly
    as the page sends it before a challenge is solved. A challenge, a per-IP
    limit or any other refusal comes back as {"error": ...} in the JSON body,
    which is passed on verbatim so the site can show the real reason.
    """
    response = await client.post(
        f"{UPSTREAM}/api/generate",
        json={"prompt": prompt, "aspect_ratio": aspect, "turnstile_token": None},
        headers=_HEADERS,
    )
    try:
        data = response.json()
    except ValueError:
        data = {}

    if response.status_code != 200 or data.get("error"):
        raise HTTPException(
            status_code=502,
            detail=f"imagefree.net refused the job: {_error_detail(data) or 'HTTP ' + str(response.status_code)}",
        )

    task_id = data.get("taskId")
    if not task_id:
        raise HTTPException(status_code=502, detail="imagefree.net returned no taskId")
    log.info("generation submitted: task=%s ratio=%s", task_id, aspect)
    return str(task_id)


async def _poll(client: httpx.AsyncClient, task_id: str, timeout: float | None = None) -> str:
    """Waits for the task and returns the picture's URL."""
    limit = POLL_TIMEOUT if timeout is None else timeout
    deadline = time.monotonic() + limit
    last_progress = None

    while True:
        if time.monotonic() > deadline:
            raise HTTPException(
                status_code=504,
                detail=f"imagefree.net did not finish within {limit:.0f}s (task {task_id})",
            )

        try:
            response = await client.get(
                f"{UPSTREAM}/api/generate/status",
                params={"taskId": task_id},
                headers=_HEADERS,
            )
        except httpx.TransportError as exc:
            # A blip while polling is not a failed picture; the deadline above
            # is what ends an unreachable upstream.
            log.warning("status request failed for task %s: %s", task_id, exc)
            await asyncio.sleep(POLL_INTERVAL)
            continue

        if response.status_code >= 400:
            raise HTTPException(
                status_code=502,
                detail=f"imagefree.net status check failed: HTTP {response.status_code}",
            )

        try:
            data = response.json()
        except ValueError:
            data = {}

        if data.get("error"):
            raise HTTPException(
                status_code=502,
                detail=f"imagefree.net reported an error: {_error_detail(data)}",
            )

        status = data.get("status")
        progress = data.get("progress")
        if progress != last_progress:
            log.info("task %s: %s %s%%", task_id, status, progress)
            last_progress = progress

        if status == "completed":
            image = data.get("image")
            if not image:
                raise HTTPException(status_code=502, detail="imagefree.net finished without an image URL")
            return str(image)

        if status in ("error", "failed"):
            raise HTTPException(
                status_code=502,
                detail=f"imagefree.net failed to draw the picture: {_error_detail(data)}",
            )

        await asyncio.sleep(POLL_INTERVAL)


async def _generate(prompt: str, aspect: str, poll_timeout: float | None = None) -> Dict[str, Any]:
    # The picture itself is a few hundred KB to a couple of MB: give the
    # download its own generous read timeout.
    timeout = httpx.Timeout(30.0, read=120.0, connect=20.0)
    async with httpx.AsyncClient(timeout=timeout, follow_redirects=True) as client:
        task_id = await _submit(client, prompt, aspect)
        image_url = await _poll(client, task_id, poll_timeout)

        # Download here, on this machine, and hand the bytes back as base64:
        # the server that asked for the picture never has to reach
        # imagefree.net (or its CDN) itself.
        response = await client.get(image_url)
        response.raise_for_status()
        raw = response.content
        mime = (response.headers.get("content-type") or "image/png").split(";")[0].strip()
        if not mime.startswith("image/"):
            mime = "image/png"

    log.info("task %s: %d bytes of %s", task_id, len(raw), mime)
    return _with_provider({
        "created": int(time.time()),
        "data": [
            {
                "b64_json": base64.b64encode(raw).decode("ascii"),
                "mime_type": mime,
            }
        ],
    }, IMAGE_PROVIDER, IMAGE_MODEL)


def _site_headers(origin: str, content_type: str | None = None) -> Dict[str, str]:
    """The same-origin fetch headers Puter.js sends from puter.com."""
    root = origin.rstrip("/")
    headers = dict(_HEADERS)
    headers["Origin"] = root
    headers["Referer"] = root + "/"
    if content_type is None:
        headers.pop("Content-Type", None)
    else:
        headers["Content-Type"] = content_type
    return headers


def _find_media(node: Any) -> Any:
    """Find an image URL / data URI / base64 blob in Puter's answer shapes."""
    if isinstance(node, dict):
        for key in ("image_url", "asset_url", "b64_json", "base64", "url", "href", "image", "result", "output", "data"):
            if key not in node:
                continue
            value = node[key]
            if isinstance(value, str) and (
                value.startswith("http://") or value.startswith("https://")
                or value.startswith("data:image/") or len(value) > 512
            ):
                return value
            if isinstance(value, (dict, list)):
                found = _find_media(value)
                if found is not None:
                    return found
        for value in node.values():
            if isinstance(value, (dict, list)):
                found = _find_media(value)
                if found is not None:
                    return found
    elif isinstance(node, list):
        for value in node:
            found = _find_media(value)
            if found is not None:
                return found
    elif isinstance(node, str) and len(node) > 512 and not node.startswith("{"):
        return node
    return None


async def _decode_media(client: httpx.AsyncClient, media: str) -> tuple[bytes, str]:
    if media.startswith("data:image/"):
        head, _, payload = media.partition(",")
        mime = head[5:].split(";")[0] or "image/png"
        if ";base64" in head:
            return base64.b64decode(payload), mime
        return payload.encode("utf-8"), mime
    if media.startswith("http://") or media.startswith("https://"):
        response = await client.get(media, headers=_site_headers("https://puter.com"))
        response.raise_for_status()
        raw = response.content
        mime = (response.headers.get("content-type") or "image/png").split(";")[0].strip()
        return raw, mime if mime.startswith("image/") else "image/png"
    return base64.b64decode(media), "image/png"


async def _puter_image(prompt: str, aspect: str, timeout: float) -> Dict[str, Any]:
    """Draw with PUTER_ACCESS_TOKEN through Puter's own browser-call API."""
    if not PUTER_ACCESS_TOKEN:
        raise RuntimeError(
            "puter: set PUTER_ACCESS_TOKEN in the bat settings to use this model "
            "(a free Puter account is enough)"
        )
    body = {
        "auth_token": PUTER_ACCESS_TOKEN,
        "interface": "puter-image-generation",
        "driver": "ai-image",
        "method": "generate",
        "test_mode": False,
        "args": {"prompt": prompt, "model": PUTER_IMAGE_MODEL, "aspect_ratio": aspect},
    }
    client_timeout = httpx.Timeout(30.0, read=timeout, connect=20.0)
    async with httpx.AsyncClient(timeout=client_timeout, follow_redirects=True) as client:
        response = await client.post(
            PUTER_API + "/drivers/call",
            content=json.dumps(body),
            headers=_site_headers("https://puter.com", "text/plain;actually=json"),
        )
        try:
            data = response.json()
        except ValueError:
            data = {}
        if response.status_code >= 400 or (isinstance(data, dict) and data.get("success") is False):
            raise RuntimeError(f"puter refused the job: HTTP {response.status_code} {str(data)[:200]}")
        media = _find_media(data.get("result") if isinstance(data, dict) and "result" in data else data)
        if not media:
            raise RuntimeError("puter returned no image: " + str(data)[:200])
        raw, mime = await _decode_media(client, str(media))
    log.info("puter generated %d bytes of %s", len(raw), mime)
    return _with_provider({
        "created": int(time.time()),
        "data": [{"b64_json": base64.b64encode(raw).decode("ascii"), "mime_type": mime}],
    }, "puter", PUTER_IMAGE_MODEL_LABEL)


def _with_provider(result: Dict[str, Any], provider: str, model: str) -> Dict[str, Any]:
    """Tag the answer with the upstream AND model that actually drew it.

    The site stores both next to the background so Settings can say
    "Free AI (Gemini Flash image)" / "Free AI (imagefree.net / Z-Image-Turbo)"
    instead of one generic label. An older worker omits the fields; the site
    then says the source is unknown and asks the player to update the file.
    """
    out = dict(result) if isinstance(result, dict) else {}
    out["provider"] = provider
    out["model"] = model
    return out


async def _chat_image(provider: str, prompt: str, timeout: float) -> Dict[str, Any]:
    """Forward an image request to the browser-session worker on port 8003."""
    model = "gemini-image" if provider == "gemini" else "duckai-image"
    try:
        async with httpx.AsyncClient(timeout=timeout) as client:
            response = await client.post(
                f"{CHAT_WORKER_URL}/v1/images/generations",
                json={"model": model, "prompt": prompt},
            )
    except httpx.TransportError as exc:
        raise RuntimeError(f"chat worker on port 8003 is not reachable: {exc}") from exc
    if response.status_code >= 400:
        try:
            detail = (response.json().get("detail") or response.text[:200])
        except ValueError:
            detail = response.text[:200]
        raise RuntimeError(f"{provider}: {detail}")
    try:
        result = response.json()
    except ValueError as exc:
        raise RuntimeError(f"{provider} returned invalid JSON") from exc
    data = result.get("data") if isinstance(result, dict) else None
    if not isinstance(data, list) or not data or not data[0].get("b64_json"):
        raise RuntimeError(f"{provider} returned no image data")
    return _with_provider(result, provider, GEMINI_IMAGE_MODEL if provider == "gemini" else DUCK_IMAGE_MODEL)


@app.post("/v1/images/generations")
async def images_generations(request: Request):
    try:
        body = await request.json()
    except Exception:
        body = {}
    if not isinstance(body, dict):
        body = {}

    prompt = (body.get("prompt") or body.get("input") or "").strip()
    if not prompt:
        raise HTTPException(status_code=400, detail="prompt required")

    model = str(body.get("model") or "").strip().lower()
    started = time.monotonic()

    # An explicit model wins. The bare default ("imagefree/default" from the
    # site) means "best free picture this PC can make", ranked by the model
    # each service actually runs - see the order below. Every attempt is
    # bounded so the server's ~190s deadline is never blown by a hung tab.
    if model.startswith(("gemini", "nano")):
        try:
            return JSONResponse(await _chat_image("gemini", prompt, GEMINI_IMAGE_TIMEOUT))
        except Exception as exc:
            log.warning("gemini image failed: %s", exc)
            raise HTTPException(status_code=502, detail=str(exc))
    if model.startswith(("duck", "gpt-image")):
        try:
            return JSONResponse(await _chat_image("duckai", prompt, DUCK_IMAGE_TIMEOUT))
        except Exception as exc:
            log.warning("duck.ai image failed: %s", exc)
            raise HTTPException(status_code=502, detail=str(exc))

    if model.startswith("puter"):
        try:
            return JSONResponse(await _puter_image(prompt, _aspect(body), PUTER_IMAGE_TIMEOUT))
        except Exception as exc:
            log.warning("puter image failed: %s", exc)
            raise HTTPException(status_code=502, detail=str(exc))
    if model.startswith(("free.ai", "freeai", "freedotai", "mage", "mango", "guava")):
        # These use account tokens held by the SITE, not by the player's PC.
        # Fail fast so the server-side provider of the same name takes over.
        raise HTTPException(status_code=502, detail=f"{model}: configured on the server only; no local token")

    if not model or model in ("imagefree/default", "default", "auto-image", "free"):
        # Only the browser-backed models belong to this worker:
        #   1. Gemini Flash image - high quality AND fast (50s cap).
        #   2. Duck.ai / GPT Image 2 - its own engineers call it the slowest
        #      of their image models (65s cap).
        #   3. Puter (/drivers/call) when the owner supplied PUTER_ACCESS_TOKEN.
        # Z-Image-Turbo is deliberately NOT here. The site already draws it
        # from imagefree.net as its FIRST source, without any bat file;
        # duplicating it here would put all Free AI models in one pot again.
        # The site tries AI Horde next and Pollinations (SANA) last.
        attempts = [
            ("gemini", GEMINI_IMAGE_TIMEOUT, GEMINI_IMAGE_MODEL),
            ("duckai", DUCK_IMAGE_TIMEOUT, DUCK_IMAGE_MODEL),
        ]
        if PUTER_ACCESS_TOKEN:
            attempts.append(("puter", PUTER_IMAGE_TIMEOUT, PUTER_IMAGE_MODEL_LABEL))
        last_error = "no free image model on this PC answered"
        for provider, timeout, model_name in attempts:
            try:
                if provider == "puter":
                    result = await _puter_image(prompt, _aspect(body), timeout)
                else:
                    result = await _chat_image(provider, prompt, timeout)
                log.info("generated with %s in %.1fs", model_name, time.monotonic() - started)
                return JSONResponse(result)
            except Exception as exc:
                last_error = str(exc)
                log.warning("%s image attempt failed: %s", model_name, exc)
        raise HTTPException(status_code=502, detail=last_error[:300])

    try:
        return JSONResponse(await _generate(prompt, _aspect(body)))
    except HTTPException:
        raise
    except Exception as exc:
        log.exception("image generation error")
        raise HTTPException(status_code=500, detail=str(exc))


@app.post("/proxy")
@app.post("/v1/proxy")
async def proxy_request(request: Request):
    """Generic HTTP proxy: forwards arbitrary request from this machine's IP.

    Expected JSON body:
    {
      "method": "GET|POST|PUT|DELETE|...",
      "url": "https://...",
      "headers": {"Header": "value"},
      "body_b64": "base64 encoded body or empty",
      "follow_redirects": true
    }
    Returns:
    {
      "status": 200,
      "headers": {...},
      "body_b64": "...",
      "content_type": "..."
    }
    """
    try:
        body = await request.json()
    except Exception:
        raise HTTPException(status_code=400, detail="invalid json")

    method = (body.get("method") or "GET").upper()
    url = body.get("url") or ""
    if not url:
        raise HTTPException(status_code=400, detail="url required")

    headers = body.get("headers") or {}
    body_b64 = body.get("body_b64") or ""
    follow_redirects = body.get("follow_redirects", True)

    req_body = None
    if body_b64:
        try:
            req_body = base64.b64decode(body_b64)
        except Exception:
            raise HTTPException(status_code=400, detail="invalid body_b64")

    try:
        async with httpx.AsyncClient(timeout=300, follow_redirects=follow_redirects) as client:
            resp = await client.request(
                method=method,
                url=url,
                headers=headers,
                content=req_body,
            )
            resp_body = resp.content
            resp_headers = {}
            for k, v in resp.headers.items():
                resp_headers[k] = v
            return JSONResponse({
                "status": resp.status_code,
                "headers": resp_headers,
                "body_b64": base64.b64encode(resp_body).decode("ascii"),
                "content_type": resp.headers.get("content-type", ""),
            })
    except httpx.TimeoutException:
        raise HTTPException(status_code=504, detail="proxy request timed out")
    except httpx.RequestError as exc:
        raise HTTPException(status_code=502, detail=f"proxy request failed: {exc}")
    except Exception as exc:
        log.exception("proxy error")
        raise HTTPException(status_code=500, detail=str(exc))


@app.get("/healthz")
async def healthz():
    return {"status": "ok"}


if __name__ == "__main__":
    import uvicorn

    port = int(os.getenv("IMAGE_WORKER_PORT", "8002"))
    uvicorn.run(app, host="127.0.0.1", port=port, log_level="info")
