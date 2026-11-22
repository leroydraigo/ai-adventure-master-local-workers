#!/usr/bin/env python3
"""Local chat relay for agent offload.

Listens on http://127.0.0.1:8003 and exposes POST /v1/chat/completions
(OpenAI-compatible, streaming SSE). The site sends the provider id in the
``X-Text-Provider`` header; this build ships the arena.ai (Max router),
DeepSeek Chat and TryingOpen adapters. TryingOpen's /api/open only accepts
requests made from its own web page, so that adapter runs the call inside the
same hidden Chrome tab instead of a plain HTTP client.

DeepSeek Chat is a consumer web app, not an OpenAI-compatible API. The adapter
therefore uses a locally captured sign-in session, solves DeepSeek's proof of
work and translates its internal SSE stream into OpenAI chunks. The session and
its cookies never leave this machine: they live in ``deepseek-session.json``
next to this file (or DEEPSEEK_SESSION_FILE). A session older than a day is
refused, and an auth/rate-limit answer pauses the adapter, so a temporary
block is not prolonged by retrying the same dead token every turn.

arena.ai (formerly lmarena.ai) guards its chat with three things a plain HTTP
call cannot forge: a signed-in cookie, a reCAPTCHA Enterprise token minted on
arena.ai's own origin (the token embeds its hostname and the server checks it)
and a composer-interaction fingerprint field. The adapter therefore keeps one
real Chrome window parked off-screen with arena.ai open and mints tokens
through the DevTools protocol; the player sees that window only for the
one-time sign-in and for the rare reCAPTCHA v2 checkbox when Google doubts the
invisible token. On Windows it never owns a taskbar button, in any of those
states. The session lives in the browser's own profile next to this file
(``arena-chrome-profile``) and never leaves this machine.

Run ``python local-chat-worker.py --login`` (DeepSeek), ``--arena-login``
(arena.ai) or ``--gemini-login`` (Gemini web chat) once to open a browser and
capture the session. The bundled StartFreeChat.bat does the first two on its
first run. Gemini is enabled by default like the other free adapters; it only
needs that one-time Google sign-in, then fails fast with a clear error and the
shared cooldown while the sign-in is missing. Google can change its private web
protocol without notice. A login-gate, ban or quota answer
pauses only that provider for ten minutes (``ADAPTER_COOLDOWN_SECONDS``) so it
is not retried on every chat turn and world update. On Windows a watchdog
re-applies tool-window styling to every window of the real Chrome process,
including popups created after launch.

Everything here is deliberately single-file: the downloadable .bat embeds only
this script, so a second helper module would not travel with it.
"""
from __future__ import annotations

import asyncio
import atexit
import base64
import json
import logging
import os
import re
import socket
import struct
import subprocess
import sys
import threading
import time
import urllib.parse
import urllib.request
import uuid
from pathlib import Path
from typing import Any, Callable, Iterator

import httpx
from fastapi import FastAPI, HTTPException, Request
from fastapi.responses import JSONResponse, StreamingResponse

log = logging.getLogger("local-chat-worker")
logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s %(levelname)s %(name)s %(message)s",
)

app = FastAPI(title="Local Chat Relay", version="1.2.0")

# ---------------------------------------------------------------------------
# Adapter registry
# ---------------------------------------------------------------------------
# Every chat adapter the worker knows about, registered with the
# <see cref="register_adapter"/> decorator. The site sends the provider id in
# the <c>X-Text-Provider</c> header; the worker picks the matching adapter and
# translates the OpenAI-shaped request to that provider's internal protocol.
#
# Adapters live here on purpose: the downloadable .bat embeds only this single
# file, so a second module would never travel with it. Add a new provider by
# adding a new adapter function + one registry line.
#
# Each adapter receives the parsed request body and returns a
# <c>typing.Iterator[str]</c> of SSE lines (OpenAI chunk framing), exactly like
# the old <c>_translate_*</c> functions. Exceptions are turned into an
# <c>{"error": …}</c> SSE frame by the endpoint, so an adapter only needs to
# yield text.
ADAPTERS: dict[str, Callable[[str, list, Any, Any], Iterator[str]]] = {}

# ---------------------------------------------------------------------------
# Shared adapter cooldown
# ---------------------------------------------------------------------------
# A login-gate, ban or quota answer is not a transient network error. Retrying
# it on the next chat turn and the next world update is what turns a short
# restriction into days of failures (and keeps opening sign-in windows). One
# process-wide table covers every adapter, including ones added later.
_ADAPTER_COOLDOWN_LOCK = threading.Lock()
_ADAPTER_COOLDOWN: dict[str, float] = {}
_ADAPTER_COOLDOWN_SECONDS = float(os.getenv("ADAPTER_COOLDOWN_SECONDS", "600"))
# A CAPTCHA / "suspicious traffic" block is not a short quota: proxies report
# Google's block clearing after ~2 hours, so do not knock on the door every ten
# minutes and extend it.
_ADAPTER_BLOCK_COOLDOWN_SECONDS = float(os.getenv("ADAPTER_BLOCK_COOLDOWN_SECONDS", "7200"))
_ADAPTER_FAILURE_MARKERS = (
    "login required", "login_gate", "invalid_token", "token expired",
    "login expired", "cooling down", "rate limit", "too many", "captcha",
    "http 401", "http 403", "http 429", "auth", "banned", "blocked", "forbidden",
)


def _adapter_cooldown_left(provider: str) -> int:
    with _ADAPTER_COOLDOWN_LOCK:
        return max(0, int(_ADAPTER_COOLDOWN.get(provider, 0.0) - time.time()))


def _looks_like_auth_or_rate(message: str) -> bool:
    lowered = message.lower()
    return any(marker in lowered for marker in _ADAPTER_FAILURE_MARKERS)


def _adapter_trip(provider: str, message: str) -> None:
    if not _looks_like_auth_or_rate(message):
        return
    lowered = message.lower()
    blocked = any(marker in lowered for marker in ("captcha", "blocked", "suspicious", "sorry/index"))
    seconds = _ADAPTER_BLOCK_COOLDOWN_SECONDS if blocked else _ADAPTER_COOLDOWN_SECONDS
    with _ADAPTER_COOLDOWN_LOCK:
        _ADAPTER_COOLDOWN[provider] = time.time() + seconds
    log.warning("adapter %r paused for %ds after: %s", provider, int(seconds), message[:180])


def register_adapter(name: str) -> Callable[[Callable], Callable]:
    """Decorator: register a chat adapter under the given id."""

    def decorator(fn: Callable[[str, list, Any, Any], Iterator[str]]) -> Callable:
        if name in ADAPTERS:
            log.warning("adapter %r already registered; replacing", name)
        ADAPTERS[name] = fn
        return fn

    return decorator


# ---------------------------------------------------------------------------
# Legacy tryingopen relay (kept so an older server config still works)
# ---------------------------------------------------------------------------
BASE_URL = os.getenv("TRYINGOPEN_BASE_URL", "https://www.tryingopen.com")
OPEN_PATH = "/api/open"
DEFAULT_EFFORT = "balanced"
# TryingOpen's /api/open is protected by a Kasada challenge: the page's own
# fetch wrapper adds an x-is-human token that cannot be minted by httpx or
# HttpClient (a captured token replayed from curl still gets 403). The only
# reliable path is to run the request inside the site's own page. These are the
# two model ids that page still serves today; the cloud ids in server-settings
# now get 400 "That model isn't on this page.". TRYINGOPEN_PAGE_MODELS lets an
# owner update that short list without re-embedding the whole bat.
TRYINGOPEN_PAGE = os.getenv("TRYINGOPEN_PAGE_URL", "https://www.tryingopen.com/")
TRYINGOPEN_LOCAL_MODELS = ("offlinebase/base-router", "offlinebase/nemotron-3.5-bolt")

# Gemini web chat is usable as a free fallback only from a SIGNED-IN browser
# tab. Google's internal StreamGenerate endpoint needs the page's own SNlM0e /
# cfb2h / FdrFJe globals; replaying cookies from Python gets blocked. It is
# enabled by default in server-settings.json and fails fast with a clear login
# error while the sign-in is missing; Google can still change the protocol or
# rate-limit a shared exit IP without notice.
GEMINI_PAGE = os.getenv("GEMINI_PAGE_URL", "https://gemini.google.com/app")
GEMINI_SESSION_FILE = Path(
    os.getenv("GEMINI_SESSION_FILE") or Path(__file__).resolve().with_name("gemini-session.json")
).expanduser()
GEMINI_MODELS = {
    # friendly id -> (web model id, model number, capacity tail)
    "gemini-flash": ("fbb127bbb056c959", 1, 1),
    "gemini-flash-lite": ("cf41b0e0dd7d53e5", 6, 1),
    "gemini-pro": ("9d8ca3786ebdfbea", 3, 1),
}
GEMINI_DEFAULT_MODEL = "gemini-flash"
USER_AGENT = (
    "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 "
    "(KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36"
)
TIMEOUT = httpx.Timeout(connect=10.0, read=180.0, write=30.0, pool=10.0)

# ---------------------------------------------------------------------------
# Common OpenAI message helpers
# ---------------------------------------------------------------------------
def _content_text(content: Any) -> str:
    if content is None:
        return ""
    if isinstance(content, str):
        return content
    if isinstance(content, list):
        parts = []
        for item in content:
            if isinstance(item, dict):
                if item.get("type") == "text" or "text" in item:
                    parts.append(str(item.get("text", "")))
                else:
                    continue
            elif isinstance(item, str):
                parts.append(item)
        return "".join(parts)
    return str(content)


def _message_parts(content: Any) -> list[dict[str, Any]]:
    text = _content_text(content)
    if text == "":
        return [{"type": "text", "text": ""}]
    return [{"type": "text", "text": text}]


def _tool_instruction(tools: list, tool_choice: Any) -> str:
    names = []
    for tool in tools or []:
        fn = tool.get("function") if isinstance(tool, dict) and isinstance(tool.get("function"), dict) else tool
        if isinstance(fn, dict) and isinstance(fn.get("name"), str):
            names.append(fn["name"])
    available = ", ".join(names) if names else "(none)"
    instruction = (
        "You can call tools. To use one, respond with ONLY a single JSON object "
        "and no other text, no markdown fences: "
        '{"tool_call":{"name":"<exact tool name>","arguments":{...}}}\n'
        f"Available tools: {available}\n"
        "If no tool call is needed, answer normally as plain text."
    )
    if isinstance(tool_choice, dict):
        name = (tool_choice.get("function") or {}).get("name")
        if isinstance(name, str) and name:
            instruction += f'\nYou MUST call the tool named "{name}".'
    elif tool_choice == "required":
        instruction += "\nYou MUST call one or more tools."
    return instruction


def _convert_messages(messages, tools, tool_choice):
    converted = []
    for message in messages or []:
        role = str(message.get("role") or "user")
        tool_calls = message.get("tool_calls")
        if role == "assistant" and isinstance(tool_calls, list) and tool_calls:
            parts = _message_parts(message.get("content"))
            called = []
            for call in tool_calls:
                if not isinstance(call, dict):
                    continue
                function = call.get("function") if isinstance(call.get("function"), dict) else call
                name = str(function.get("name", ""))
                arguments = function.get("arguments", "{}")
                if isinstance(arguments, (dict, list)):
                    arguments = json.dumps(arguments, ensure_ascii=False, separators=(",", ":"))
                called.append(f"{name}({arguments})")
            if called:
                parts.append({"type": "text", "text": "[called " + "; ".join(called) + ";]"})
            converted.append({"id": str(message.get("id") or f"msg-{uuid.uuid4().hex[:12]}"), "role": "assistant", "parts": parts})
            continue
        if role == "tool":
            call_id = str(message.get("tool_call_id") or "unknown")
            tool_text = _content_text(message.get("content")) or "(empty result)"
            parts = [{"type": "text", "text": f"[TOOL RESULT for {call_id}]\n{tool_text}\n[/TOOL RESULT]"}]
            converted.append({"id": str(message.get("id") or f"msg-{uuid.uuid4().hex[:12]}"), "role": "user", "parts": parts})
            continue
        item_id = str(message.get("id") or f"msg-{uuid.uuid4().hex[:12]}")
        converted.append({"id": item_id, "role": role, "parts": _message_parts(message.get("content"))})

    user_index = next((i for i, item in enumerate(converted) if item["role"] == "user"), None)
    if user_index is None:
        converted.insert(0, {"id": f"msg-{uuid.uuid4().hex[:12]}", "role": "user", "parts": []})
        user_index = 0

    system_text = ""
    for message in messages or []:
        if str(message.get("role") or "") == "system":
            system_text = (_content_text(message.get("content")) + "\n" + system_text).strip()
    if tools and tool_choice != "none":
        system_text = (system_text + "\n" + _tool_instruction(tools, tool_choice)).strip()
    if system_text:
        converted[user_index]["parts"] = [
            {"type": "text", "text": f"[SYSTEM INSTRUCTIONS]\n{system_text}\n[/SYSTEM INSTRUCTIONS]"},
            *converted[user_index]["parts"],
        ]
    return converted


def _payload(model, messages, effort):
    return {
        "id": f"chat-{uuid.uuid4().hex[:16]}",
        "trigger": "submit-message",
        "messageId": f"msg-{uuid.uuid4().hex[:24]}",
        "model": model.split("/", 1)[1] if model.startswith("tryingopen/") else model,
        "effort": effort,
        "messages": messages,
        "stream": True,
    }


def _tryingopen_page_models() -> tuple[str, ...]:
    configured = tuple(
        part.strip() for part in os.getenv("TRYINGOPEN_PAGE_MODELS", "").split(",") if part.strip()
    )
    return configured or TRYINGOPEN_LOCAL_MODELS


def _tryingopen_candidates(model: str) -> list[str]:
    """Preferred page model first, then the other known-good page model.

    The public catalog is gone and cloud ids return 400 from the page's own
    /api/open. Keep the player's explicit pick meaningful: a Nemotron row really
    uses the page's Nemotron instead of silently becoming base-router, while the
    other rows keep base-router. The second model remains an automatic fallback
    on the specific "model isn't on this page" error.
    """
    upstream = model.split("/", 1)[1] if model.startswith("tryingopen/") else model
    models = _tryingopen_page_models()
    if upstream in models:
        preferred = upstream
    elif "nemotron" in upstream.lower() and any("nemotron" in m.lower() for m in models):
        preferred = next(m for m in models if "nemotron" in m.lower())
    else:
        preferred = models[0]
    ordered = [preferred]
    ordered.extend(m for m in models if m not in ordered)
    return ordered


def _usage(metadata):
    mapping = {
        "inputTokens": "prompt_tokens",
        "outputTokens": "completion_tokens",
        "totalTokens": "total_tokens",
        "reasoningTokens": "reasoning_tokens",
    }
    usage = {}
    for source, target in mapping.items():
        value = metadata.get(source)
        if isinstance(value, (int, float)):
            usage[target] = int(value)
    return usage or None


def _chunk(created, model, delta, finish=None):
    obj = {
        "id": f"chatcmpl-{uuid.uuid4().hex}",
        "object": "chat.completion.chunk",
        "created": created,
        "model": model,
        "choices": [{"index": 0, "delta": delta, "finish_reason": finish}],
    }
    return "data: " + json.dumps(obj, ensure_ascii=False) + "\n\n"


def _error_event(message):
    return "data: " + json.dumps(
        {"error": {"message": message, "type": "upstream_error"}}, ensure_ascii=False
    ) + "\n\n"


def _iter_upstream_events(response):
    for line in response.iter_lines():
        if not line:
            continue
        raw = str(line)
        if not raw.startswith("data:"):
            continue
        data = raw[5:].strip()
        if data == "[DONE]":
            return
        try:
            event = json.loads(data)
        except (TypeError, ValueError, json.JSONDecodeError):
            log.debug("ignoring non-JSON tryingopen SSE: %s", data[:200])
            continue
        yield event


def _translate_tryingopen(model, messages, tools, tool_choice):
    """Run the request inside TryingOpen's own page.

    A plain HTTP client cannot satisfy the site's Kasada challenge: even a
    genuine captured x-is-human token gets 403 when replayed from curl/httpx.
    The parked Chrome tab lets the site's own fetch wrapper add the header.
    """
    created = int(time.time())
    converted = _convert_messages(messages, tools, tool_choice)
    payload = _payload(model, converted, DEFAULT_EFFORT)
    events = None
    last_error = None
    for upstream_model in _tryingopen_candidates(model):
        attempt = dict(payload)
        attempt["model"] = upstream_model
        try:
            events = ArenaBrowser.instance().tryingopen_stream(attempt)
            break
        except Exception as exc:
            last_error = exc
            text = str(exc).lower()
            model_gone = ("isn't on this page" in text or
                          ("400" in text and "model" in text))
            if model_gone:
                log.warning("tryingopen model %s unavailable on page, trying next", upstream_model)
                continue
            raise
    if events is None:
        log.warning("tryingopen browser relay failed: %s", last_error)
        yield _error_event(f"tryingopen browser relay error: {str(last_error)[:240]}")
        yield "data: [DONE]\n\n"
        return

    finish_reason = "stop"
    stream_error = None
    usage_out = None
    for event in events:
        etype = event.get("type")
        if etype == "reasoning-delta":
            delta = str(event.get("delta") or "")
            if delta:
                yield _chunk(created, model, {"reasoning_content": delta})
        elif etype == "text-delta":
            delta = str(event.get("delta") or "")
            if delta:
                yield _chunk(created, model, {"content": delta})
        elif etype == "finish":
            finish_reason = str(event.get("finishReason") or "stop")
            usage_out = _usage(event.get("messageMetadata") or {})
            error_message = str(
                event.get("errorText")
                or (event.get("messageMetadata") or {}).get("errorText")
                or (event.get("messageMetadata") or {}).get("error")
                or ""
            )
            if finish_reason == "error" and error_message:
                stream_error = error_message
        elif etype == "error":
            stream_error = str(event.get("errorText") or "tryingopen upstream error")

    if stream_error:
        yield _error_event(stream_error)
        yield "data: [DONE]\n\n"
        return

    yield _chunk(created, model, {}, finish=finish_reason or "stop")
    if usage_out:
        chunk = {
            "id": f"chatcmpl-{uuid.uuid4().hex}",
            "object": "chat.completion.chunk",
            "created": created,
            "model": model,
            "choices": [],
            "usage": usage_out,
        }
        yield "data: " + json.dumps(chunk, ensure_ascii=False) + "\n\n"
    yield "data: [DONE]\n\n"

# ---------------------------------------------------------------------------
# DuckDuckGo AI Chat adapter (duck.ai) - best-effort, no login
# ---------------------------------------------------------------------------
DUCK_STATUS_URL = "https://duckduckgo.com/duckchat/v1/status"
DUCK_CHAT_URL = "https://duckduckgo.com/duckchat/v1/chat"
DUCK_TIMEOUT = httpx.Timeout(connect=15.0, read=180.0, write=30.0, pool=15.0)
DUCK_MODELS = {
    "gpt-4o-mini": "gpt-4o-mini",
    "gpt-5-mini": "gpt-4o-mini",
    "claude-haiku": "claude-3-5-haiku-latest",
    "claude-3-5-haiku": "claude-3-5-haiku-latest",
    "llama": "meta-llama/Llama-3.3-70B-Instruct-Turbo",
    "llama-3.3-70b": "meta-llama/Llama-3.3-70B-Instruct-Turbo",
    "mistral-small": "mistralai/Mistral-Small-24B-Instruct-2501",
    "mistral": "mistralai/Mistral-Small-24B-Instruct-2501",
    "o3-mini": "o3-mini",
    "gemma": "meta-llama/Llama-3.3-70B-Instruct-Turbo",
}


def _duck_model(model: str) -> str:
    m = (model or "").strip()
    low = m.lower()
    for k, v in DUCK_MODELS.items():
        if k in low:
            return v
    if "/" in m and "duck" in low:
        # allow explicit upstream names after prefix e.g. duckai/gpt-4o-mini
        return m.split("/", 1)[1]
    return "gpt-4o-mini"


def _duck_messages(messages, tools=None, tool_choice=None):
    out = []
    system_parts = []
    for m in messages or []:
        role = (m.get("role") or "user").lower()
        text = _content_text(m.get("content"))
        if role == "system":
            system_parts.append(text)
            continue
        if role == "tool":
            call_id = str(m.get("tool_call_id") or "unknown")
            text = f"[TOOL RESULT for {call_id}]\n{text or '(empty result)'}\n[/TOOL RESULT]"
            role = "user"
        elif role == "assistant" and isinstance(m.get("tool_calls"), list) and m["tool_calls"]:
            # Duck chat has no tool channel. Mirror the JSON contract the other
            # adapters use so a tool round-trip is not silently dropped here.
            calls = []
            for call in m["tool_calls"]:
                fn = call.get("function") if isinstance(call, dict) else None
                if not isinstance(fn, dict):
                    continue
                args = fn.get("arguments")
                if isinstance(args, str):
                    try:
                        args = json.loads(args)
                    except Exception:
                        pass
                calls.append({"name": fn.get("name", ""), "arguments": args})
            if calls:
                text = (text + "\n" if text else "") + json.dumps(
                    {"tool_call": calls[0]}, ensure_ascii=False
                )
        if role not in ("user", "assistant"):
            role = "user"
        out.append({"role": role, "content": text})

    if tools and tool_choice != "none":
        system_parts.append(_tool_instruction(tools, tool_choice))
    if system_parts:
        instruction = "\n".join(p for p in system_parts if p).strip()
        if instruction:
            system_block = f"[SYSTEM INSTRUCTIONS]\n{instruction}\n[/SYSTEM INSTRUCTIONS]"
            if out and out[0]["role"] == "user":
                out[0]["content"] = (system_block + "\n\n" + out[0]["content"]).strip()
            else:
                out.insert(0, {"role": "user", "content": system_block})

    # merge consecutive same-role messages (basic)
    merged = []
    for msg in out:
        if merged and merged[-1]["role"] == msg["role"]:
            merged[-1]["content"] = (merged[-1]["content"] + "\n\n" + msg["content"]).strip()
        else:
            merged.append(msg)
    if merged and merged[0]["role"] == "assistant":
        merged.insert(0, {"role": "user", "content": "Hello"})
    return merged or [{"role": "user", "content": "Hello"}]


@register_adapter("duckai")
@register_adapter("duck")
def _translate_duckai(model, messages, tools, tool_choice):
    created = int(time.time())
    out_model = model or "duckai/gpt-4o-mini"
    duck_model = _duck_model(out_model)
    headers_base = {
        "User-Agent": USER_AGENT,
        "Accept": "text/event-stream",
        "Referer": "https://duckduckgo.com/",
        "Origin": "https://duckduckgo.com",
    }
    try:
        with httpx.Client(timeout=DUCK_TIMEOUT, headers=headers_base, follow_redirects=True) as client:
            # 1) obtain VQD token
            st = client.get(DUCK_STATUS_URL, headers={"x-vqd-accept": "1"})
            vqd = st.headers.get("x-vqd-4") or st.headers.get("x-vqd-hash-1")
            if not vqd:
                yield _error_event("duck.ai: could not obtain session token (vqd). Try again later.")
                yield "data: [DONE]\n\n"
                return
            payload = {"model": duck_model, "messages": _duck_messages(messages, tools, tool_choice)}
            chat_headers = {
                "Content-Type": "application/json",
                "x-vqd-4": vqd,
            }
            with client.stream("POST", DUCK_CHAT_URL, headers=chat_headers, json=payload) as resp:
                if resp.status_code == 429:
                    yield _error_event("duck.ai rate limit reached on this IP; try later or use another provider.")
                    yield "data: [DONE]\n\n"
                    return
                if resp.status_code >= 400:
                    body = resp.read().decode("utf-8", "replace")[:300]
                    yield _error_event(f"duck.ai HTTP {resp.status_code}: {body}")
                    yield "data: [DONE]\n\n"
                    return
                for line in resp.iter_lines():
                    if not line:
                        continue
                    if not line.startswith("data:"):
                        continue
                    data = line[5:].strip()
                    if data == "[DONE]":
                        break
                    try:
                        evt = json.loads(data)
                    except Exception:
                        continue
                    if "message" in evt and evt.get("message"):
                        delta = str(evt.get("message") or "")
                        if delta:
                            yield _chunk(created, out_model, {"content": delta})
                    if evt.get("action") == "error":
                        yield _error_event("duck.ai upstream error: " + str(evt.get("status") or evt.get("type") or "error")[:120])
                        yield "data: [DONE]\n\n"
                        return
            yield _chunk(created, out_model, {}, finish="stop")
            yield "data: [DONE]\n\n"
    except httpx.HTTPError as exc:
        yield _error_event(f"duck.ai network error: {str(exc)[:160]}")
        yield "data: [DONE]\n\n"
    except Exception as exc:
        yield _error_event(f"duck.ai adapter error: {str(exc)[:160]}")
        yield "data: [DONE]\n\n"


# ---------------------------------------------------------------------------
# Pollinations keyless adapter (runs from the player's own IP)
# ---------------------------------------------------------------------------
# The site's ServerDirect Pollinations row shares ONE server IP with every
# player and answers 402 almost immediately under real load. The same free API
# from the player's own machine has its own allowance, so expose it as a worker
# adapter. No sign-in, no cookies, no browser: this is the rung that keeps the
# auto ladder alive when Arena/DeepSeek/Gemini sessions are missing or stale.
POLLINATIONS_URL = os.getenv(
    "POLLINATIONS_URL", "https://text.pollinations.ai/v1/chat/completions").rstrip("/")
POLLINATIONS_TIMEOUT = httpx.Timeout(connect=15.0, read=120.0, write=30.0, pool=15.0)


def _pollinations_model(model: str) -> str:
    value = (model or "").strip()
    if "/" in value:
        value = value.split("/", 1)[1]
    return value or "openai-fast"


@register_adapter("pollinations-device")
@register_adapter("pollinations-text")
@register_adapter("pollinations-openai")
@register_adapter("pollinations")
def _translate_pollinations(model, messages, tools, tool_choice):
    created = int(time.time())
    out_model = model or "pollinations-device/openai-fast"
    payload = {
        "model": _pollinations_model(out_model),
        "stream": True,
        # Reuse the Duck normaliser: it already folds the system block, tool
        # results and multi-part content into the two-role shape free chat
        # endpoints accept.
        "messages": _duck_messages(messages, tools, tool_choice),
    }
    try:
        with httpx.Client(
            timeout=POLLINATIONS_TIMEOUT,
            headers={"User-Agent": USER_AGENT, "Accept": "text/event-stream"},
        ) as client:
            with client.stream("POST", POLLINATIONS_URL, json=payload) as resp:
                if resp.status_code in (402, 429):
                    yield _error_event(
                        "pollinations rate limit reached on this PC; it clears in about a minute."
                    )
                    yield "data: [DONE]\n\n"
                    return
                if resp.status_code >= 400:
                    detail = resp.read().decode("utf-8", "replace")[:300]
                    yield _error_event(f"pollinations HTTP {resp.status_code}: {detail}")
                    yield "data: [DONE]\n\n"
                    return
                for line in resp.iter_lines():
                    if not line or not line.startswith("data:"):
                        continue
                    data = line[5:].strip()
                    if data == "[DONE]":
                        break
                    try:
                        event = json.loads(data)
                    except Exception:
                        continue
                    if isinstance(event, dict) and event.get("error"):
                        err = event["error"]
                        msg = err.get("message") if isinstance(err, dict) else str(err)
                        yield _error_event("pollinations upstream error: " + str(msg)[:200])
                        yield "data: [DONE]\n\n"
                        return
                    for choice in (event.get("choices") or []) if isinstance(event, dict) else []:
                        delta = choice.get("delta") or {}
                        text = delta.get("content")
                        if text:
                            yield _chunk(created, out_model, {"content": str(text)})
                yield _chunk(created, out_model, {}, finish="stop")
                yield "data: [DONE]\n\n"
    except httpx.HTTPError as exc:
        yield _error_event("pollinations network error: " + str(exc)[:200])
        yield "data: [DONE]\n\n"
    except Exception as exc:
        yield _error_event("pollinations adapter error: " + str(exc)[:200])
        yield "data: [DONE]\n\n"


# ---------------------------------------------------------------------------
# DeepSeek Chat adapter
# ---------------------------------------------------------------------------
DEEPSEEK_BASE = os.getenv("DEEPSEEK_BASE_URL", "https://chat.deepseek.com").rstrip("/")
DEFAULT_SESSION_FILE = Path(__file__).resolve().with_name("deepseek-session.json")
SESSION_FILE = Path(os.getenv("DEEPSEEK_SESSION_FILE", str(DEFAULT_SESSION_FILE))).expanduser()
DEEPSEEK_TIMEOUT = httpx.Timeout(connect=20.0, read=300.0, write=60.0, pool=20.0)

# DeepSeek's free web session is easy to trip: a stale token retried on every
# message and world update turns a short restriction into days of 403s. Park
# the adapter after an auth/rate-limit answer instead of feeding it more calls.
_DS_STATE_LOCK = threading.Lock()
_DS_COOLDOWN_UNTIL = 0.0
_DS_LAST_CALL_AT = 0.0
_DS_COOLDOWN_SECONDS = float(os.getenv("DEEPSEEK_COOLDOWN_SECONDS", "600"))
_DS_MAX_AGE_SECONDS = float(os.getenv("DEEPSEEK_SESSION_MAX_AGE_SECONDS", "86400"))
_DS_MIN_INTERVAL_SECONDS = float(os.getenv("DEEPSEEK_MIN_INTERVAL_SECONDS", "2"))

_CONTENT_PATH = re.compile(r"^response/fragments/(-?\d+)/content$")

# DeepSeek's own DeepSeekHashV1 module, base64-embedded so the single-file
# worker needs no second download and no CDN at runtime. The module is executed
# inside wasmtime; it has no access to files or the network.
_POW_WASM_B64 = "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ADYCAEGEocAAQfigwAA2AgBBgKHAAEH4oMAANgIAQYyhwABBgKHAADYCAEGIocAAQYChwAA2AgBBlKHAAEGIocAANgIAQZChwABBiKHAADYCAEGcocAAQZChwAA2AgBBpKHAAEGYocAANgIAQZihwABBkKHAADYCAEGsocAAQaChwAA2AgBBoKHAAEGYocAANgIAQbShwABBqKHAADYCAEGoocAAQaChwAA2AgBBvKHAAEGwocAANgIAQbChwABBqKHAADYCAEHEocAAQbihwAA2AgBBuKHAAEGwocAANgIAQcyhwABBwKHAADYCAEHAocAAQbihwAA2AgBB1KHAAEHIocAANgIAQcihwABBwKHAADYCAEHcocAAQdChwAA2AgBB0KHAAEHIocAANgIAQeShwABB2KHAADYCAEHYocAAQdChwAA2AgBB7KHAAEHgocAANgIAQeChwABB2KHAADYCAEH0ocAAQeihwAA2AgBB6KHAAEHgocAANgIAQfyhwABB8KHAADYCAEHwocAAQeihwAA2AgBBhKLAAEH4ocAANgIAQfihwABB8KHAADYCAEGMosAAQYCiwAA2AgBBgKLAAEH4ocAANgIAQZSiwABBiKLAADYCAEGIosAAQYCiwAA2AgBBrKLAACABNgIAQZCiwABBiKLAADYCAEGkosAAIANBKGsiADYCACABIABBAXI2AgQgACABakEoNgIEQbiiwABBgICAATYCAAwHCyACIARJIAEgAk1yDQAgACgCDEUNAwtBvKLAAEG8osAAKAIAIgAgASAAIAFJGzYCACABIANqIQRBgKDAACEAAkACQANAIAQgACgCACIGRwRAIAAoAggiAA0BDAILCyAAKAIMRQ0BC0GAoMAAIQADQAJAIAIgACgCACIETwRAIAIgBCAAKAIEaiIGSQ0BCyAAKAIIIQAMAQsLQayiwAAgATYCAEGkosAAIANBKGsiADYCACABIABBAXI2AgQgACABakEoNgIEQbiiwABBgICAATYCACACIAZBIGtBeHFBCGsiACAAIAJBEGpJGyIEQRs2AgRBgKDAACkCACEJIARBEGpBiKDAACkCADcCACAEIAk3AghBhKDAACADNgIAQYCgwAAgATYCAEGIoMAAIARBCGo2AgBBjKDAAEEANgIAIARBHGohAANAIABBBzYCACAAQQRqIgAg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QZyiwABBnKLAACgCACADcjYCAA8LAkACQCABIAQoAgAiAygCBEF4cUYEQCADIQIMAQsgAUEZIAJBAXZrQQAgAkEfRxt0IQUDQCADIAVBHXZBBHFqQRBqIgQoAgAiAkUNAiAFQQF0IQUgAiEDIAIoAgRBeHEgAUcNAAsLIAIoAggiASAANgIMIAIgADYCCCAAQQA2AhggACACNgIMIAAgATYCCA8LIAQgADYCACAAIAM2AhggACAANgIMIAAgADYCCAuBAgEFfyMAQYABayIEJAACfwJAAkAgASgCHCICQRBxRQRAIAJBIHENASAAIAEQDwwDC0H/ACECA0AgBCACIgNqIgUgAEEPcSICQTByIAJB1wBqIAJBCkkbOgAAIANBAWshAiAAQRBJIABBBHYhAEUNAAsMAQtB/wAhAgNAIAQgAiIDaiIFIABBD3EiAkEwciACQTdqIAJBCkkbOgAAIANBAWshAiAAQRBJIABBBHYhAEUNAAsgA0GBAU8EQCADEBgACyABQYCEwABBAiAFQYABIANrEAkMAQsgA0GBAU8EQCADEBgACyABQYCEwABBAiAFQYABIANrEAkLIARBgAFqJAALuQIAIAIEQCABIAJBiAFsaiECA0AgACAAKQMAIAEpAACFNwMAIAAgACkDCCABKQAIhTcDCCAAIAApAxAgASkAEIU3AxAgACAAKQMYIAEpABiFNwMYIAAgACkDICABKQAghTcDICAAIAApAyggASkAKIU3AyggACAAKQMwIAEpADCFNwMwIAAgACkDOCABKQA4hTcDOCAAIAApA0AgASkAQIU3A0AgACAAKQNIIAEpAEiFNwNIIAAgACkDUCABKQBQhTcDUCAAIAApA1ggASkAWIU3A1ggACAAKQNgIAEpAGCFNwNgIAAgACkDaCABKQBohTcDaCAAIAApA3AgASkAcIU3A3AgACAAKQN4IAEpAHiFNwN4IAAgACkDgAEgASkAgAGFNwOAASAAEAQgAUGIAWoiASACRw0ACwsLsAEBAn8jAEEgayIDJAAgASABIAJqIgJLBEBBAEEAECgAC0EIIAAoAgAiAUEBdCIEIAIgAiAESRsiAiACQQhNGyIEQQBIBEBBAEEAECgACyADIAEEfyADIAE2AhwgAyAAKAIENgIUQQEFQQALNgIYIANBCGogBCADQRRqEB0gAygCCEEBRgRAIAMoAgwgAygCEBAoAAsgAygCDCEBIAAgBDYCACAAIAE2AgQgA0EgaiQAC7ABAQR/IwBBIGsiASQAIAAoAgAiAkF/RgRAQQBBABAoAAtBCCACQQF0IgMgAkEBaiIEIAMgBEsbIgMgA0EITRsiA0EASARAQQBBABAoAAsgASACBH8gASACNgIcIAEgACgCBDYCFEEBBUEACzYCGCABQQhqIAMgAUEUahAdIAEoAghBAUYEQCABKAIMIAEoAhAQKAALIAEoAgwhAiAAIAM2AgAgACACNgIEIAFBIGokAAuOAQECfyABQRBPBEAgAEEAIABrQQNxIgNqIQIgAwRAA0AgAEEAOgAAIABBAWoiACACSQ0ACwsgAiABIANrIgFBfHEiA2ohACADQQBKBEADQCACQQA2AgAgAkEEaiICIABJDQALCyABQQNxIQELIAEEQCAAIAFqIQEDQCAAQQA6AAAgAEEBaiIAIAFJDQALCwtsAQN/AkACQCAAKAIAIgIEQCAAKAIEIgBBBGsoAgAiAUF4cSIDQQRBCCABQQNxIgEbIAJqSQ0BIAFBACADIAJBJ2pLGw0CIAAQBQsPC0H5ncAAQS5BqJ7AABAgAAtBuJ7AAEEuQeiewAAQIAALewEBfyMAQRBrIgMkAEH8nsAAQfyewAAoAgAiBEEBajYCAAJAIARBAEgNAAJAQciiwAAtAABFBEBBxKLAAEHEosAAKAIAQQFqNgIAQfiewAAoAgBBAE4NAQwCCyADQQhqIAAgARECAAALQciiwABBADoAACACRQ0AAAsAC2wCAX8BfiMAQTBrIgEkACABIAA2AgAgAUGAATYCBCABQQI2AgwgAUGAhsAANgIIIAFCAjcCFCABQoCAgIAwIgIgAUEEaq2ENwMoIAEgAiABrYQ3AyAgASABQSBqNgIQIAFBCGpB8IPAABAkAAtoAgF/AX4jAEEwayIDJAAgAyABNgIEIAMgADYCACADQQI2AgwgA0G4g8AANgIIIANCAjcCFCADQoCAgIAwIgQgA62ENwMoIAMgBCADQQRqrYQ3AyAgAyADQSBqNgIQIANBCGogAhAkAAtoAgF/AX4jAEEwayIDJAAgAyAANgIAIAMgATYCBCADQQI2AgwgA0HUhsAANgIIIANCAjcCFCADQoCAgIAwIgQgA0EEaq2ENwMoIAMgBCADrYQ3AyAgAyADQSBqNgIQIANBCGogAhAkAAtiAQF/AkACQCABBEAgAEEEaygCACICQXhxIgNBBEEIIAJBA3EiAhsgAWpJDQEgAkEAIAMgAUEnaksbDQIgABAFCw8LQfmdwABBLkGonsAAECAAC0G4nsAAQS5B6J7AABAgAAtbAQJ/AkAgAEEEaygCACICQXhxIgNBBEEIIAJBA3EiAhsgAWpPBEAgAkEAIAMgAUEnaksbDQEgABAFDwtB+Z3AAEEuQaiewAAQIAALQbiewABBLkHonsAAECAAC1gBAX8CfyACKAIEBEACQCACKAIIIgNFBEAMAQsgAigCACADQQEgARAHDAILC0HJosAALQAAGiABEAALIQIgACABNgIIIAAgAkEBIAIbNgIEIAAgAkU2AgALSAACQCABaUEBR0GAgICAeCABayAASXINACAABEBByaLAAC0AABoCfyABQQlPBEAgASAAEAoMAQsgABAACyIBRQ0BCyABDwsAC0EBAX8gAiAAKAIAIAAoAggiA2tLBEAgACADIAIQEyAAKAIIIQMLIAAoAgQgA2ogASACEA0aIAAgAiADajYCCEEAC0EBAX8jAEEgayIDJAAgA0EANgIQIANBATYCBCADQgQ3AgggAyABNgIcIAMgADYCGCADIANBGGo2AgAgAyACECQACzgAAkAgAkGAgMQARg0AIAAgAiABKAIQEQAARQ0AQQEPCyADRQRAQQAPCyAAIAMgBCABKAIMEQEACzwBAX9BASECAkAgACgCACABEBENACABKAIUQciCwABBAiABKAIYKAIMEQEADQAgACgCBCABEBEhAgsgAgstAAJAIANpQQFHQYCAgIB4IANrIAFJckUEQCAAIAEgAyACEAciAA0BCwALIAAL6gECAn8BfiMAQRBrIgIkACACQQE7AQwgAiABNgIIIAIgADYCBCMAQRBrIgEkACACQQRqIgApAgAhBCABIAA2AgwgASAENwIEIwBBEGsiACQAIAFBBGoiASgCACICKAIMIQMCQAJAAkACQCACKAIEDgIAAQILIAMNAUEBIQJBACEDDAILIAMNACACKAIAIgIoAgQhAyACKAIAIQIMAQsgAEGAgICAeDYCACAAIAE2AgwgAEEGIAEoAggiAC0ACCAALQAJEBcACyAAIAM2AgQgACACNgIAIABBByABKAIIIgAtAAggAC0A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AgAgBkEDdGoiACgCACAAKAIEIAIoAiQoAgwRAQBFDQELQQEMAQtBAAsgAkEwaiQACwsAIAAoAgAgARAPCwwAIAAgASkCADcDAAsJACAAQQA2AgALC/weAgBBgIDAAAtBRXJyb3IAAAAIAAAADAAAAAQAAAAJAAAACgAAAAsAAABzaGEzLXdhc20vc3JjL2xpYi5ycyAAEAAUAAAASQAAADMAQcyAwAALqR4BAAAADAAAAGEgRGlzcGxheSBpbXBsZW1lbnRhdGlvbiByZXR1cm5lZCBhbiBlcnJvciB1bmV4cGVjdGVkbHkvVXNlcnMvcnoucGFuLy5ydXN0dXAvdG9vbGNoYWlucy9zdGFibGUtYWFyY2g2NC1hcHBsZS1kYXJ3aW4vbGliL3J1c3RsaWIvc3JjL3J1c3QvbGlicmFyeS9hbGxvYy9zcmMvc3RyaW5nLnJziwAQAG0AAAB7CgAADgAAAGNhcGFjaXR5IG92ZXJmbG93AAAACAEQABEAAABhbGxvYy9zcmMvcmF3X3ZlYy5ycyQBEAAUAAAAGAAAAAUAAAAuLjAxMjM0NTY3ODlhYmNkZWZjYWxsZWQgYE9wdGlvbjo6dW53cmFwKClgIG9uIGEgYE5vbmVgIHZhbHVlaW5kZXggb3V0IG9mIGJvdW5kczogdGhlIGxlbiBpcyAgYnV0IHRoZSBpbmRleCBpcyAAhQEQACAAAAClARAAEgAAADogAAABAAAAAAAAAMgBEAACAAAAY29yZS9zcmMvZm10L251bS5ycwDcARAAEwAAAGYAAAAXAAAAMHgwMDAxMDIwMzA0MDUwNjA3MDgwOTEwMTExMjEzMTQxNTE2MTcxODE5MjAyMTIyMjMyNDI1MjYyNzI4MjkzMDMxMzIzMzM0MzUzNjM3MzgzOTQwNDE0MjQzNDQ0NTQ2NDc0ODQ5NTA1MTUyNTM1NDU1NTY1NzU4NTk2MDYxNjI2MzY0NjU2NjY3Njg2OTcwNzE3MjczNzQ3NTc2Nzc3ODc5ODA4MTgyODM4NDg1ODY4Nzg4ODk5MDkxOTI5Mzk0OTU5Njk3OTg5OXJhbmdlIHN0YXJ0IGluZGV4ICBvdXQgb2YgcmFuZ2UgZm9yIHNsaWNlIG9mIGxlbmd0aCAAAMoCEAASAAAA3AIQACIAAAByYW5nZSBlbmQgaW5kZXggEAMQABAAAADcAhAAIgAAAHNsaWNlIGluZGV4IHN0YXJ0cyBhdCAgYnV0IGVuZHMgYXQgADADEAAWAAAARgMQAA0AAABbLi4uXWJlZ2luIDw9IGVuZCAoIDw9ICkgd2hlbiBzbGljaW5nIGBgaQMQAA4AAAB3AxAABAAAAHsDEAAQAAAAiwMQAAEAAABieXRlIGluZGV4ICBpcyBub3QgYSBjaGFyIGJvdW5kYXJ5OyBpdCBpcyBpbnNpZGUgIChieXRlcyApIG9mIGAArAMQAAsAAAC3AxAAJgAAAN0DEAAIAAAA5QMQAAYAAACLAxAAAQAAACBpcyBvdXQgb2YgYm91bmRzIG9mIGAAAKwDEAALAAAAFAQQABYAAACLAxAAAQAAAGNvcmUvc3JjL3N0ci9tb2QucnMARAQQABMAAADxAAAALAAAAGNvcmUvc3JjL3VuaWNvZGUvcHJpbnRhYmxlLnJzAAAAaAQQAB0AAAAaAAAANgAAAGgEEAAdAAAACgAAACsAAAAABgEBAwEEAgUHBwIICAkCCgULAg4EEAERAhIFExwUARUCFwIZDRwFHQgfASQBagRrAq8DsQK8As8C0QLUDNUJ1gLXAtoB4AXhAucE6ALuIPAE+AL6BPsBDCc7Pk5Pj56en3uLk5aisrqGsQYHCTY9Plbz0NEEFBg2N1ZXf6qur7014BKHiY6eBA0OERIpMTQ6RUZJSk5PZGWKjI2PtsHDxMbL1ly2txscBwgKCxQXNjk6qKnY2Qk3kJGoBwo7PmZpj5IRb1+/7u9aYvT8/1NUmpsuLycoVZ2goaOkp6iturzEBgsMFR06P0VRpqfMzaAHGRoiJT4/5+zv/8XGBCAjJSYoMzg6SEpMUFNVVlhaXF5gY2Vma3N4fX+KpKqvsMDQrq9ub93ek14iewUDBC0DZgMBLy6Agh0DMQ8cBCQJHgUrBUQEDiqAqgYkBCQEKAg0C04DNAyBNwkWCggYO0U5A2MICTAWBSEDGwUBQDgESwUvBAoHCQdAICcEDAk2AzoFGgcEDAdQSTczDTMHLggKBiYDHQgCgNBSEAM3LAgqFhomHBQXCU4EJAlEDRkHCgZICCcJdQtCPioGOwUKBlEGAQUQAwULWQgCHWIeSAgKgKZeIkULCgYNEzoGCgYUHCwEF4C5PGRTDEgJCkZFG0gIUw1JBwqAtiIOCgZGCh0DR0k3Aw4ICgY5BwqBNhkHOwMdVQEPMg2Dm2Z1C4DEikxjDYQwEBYKj5sFgkeauTqGxoI5ByoEXAYmCkYKKAUTgbA6gMZbZUsEOQcRQAULAg6X+AiE1ikKoueBMw8BHQYOBAiBjIkEawUNAwkHEI9ggPoGgbRMRwl0PID2CnMIcBVGehQMFAxXCRmAh4FHA4VCDxWEUB8GBoDVKwU+IQFwLQMaBAKBQB8ROgUBgdAqgNYrBAGB4ID3KUwECgQCgxFETD2AwjwGAQRVBRs0AoEOLARkDFYKgK44HQ0sBAkHAg4GgJqD2AQRAw0DdwRfBgwEAQ8MBDgICgYoCCwEAj6BVAwdAwoFOAccBgkHgPqEBgABAwUFBgYCBwYIBwkRChwLGQwaDRAODA8EEAMSEhMJFgEXBBgBGQMaBxsBHAIfFiADKwMtCy4BMAQxAjIBpwSpAqoEqwj6AvsF/QL+A/8JrXh5i42iMFdYi4yQHN0OD0tM+/wuLz9cXV/ihI2OkZKpsbq7xcbJyt7k5f8ABBESKTE0Nzo7PUlKXYSOkqmxtLq7xsrOz+TlAAQNDhESKTE0OjtFRklKXmRlhJGbncnOzw0RKTo7RUlXW1xeX2RljZGptLq7xcnf5OXwDRFFSWRlgISyvL6/1dfw8YOFi6Smvr/Fx8/a20iYvc3Gzs9JTk9XWV5fiY6Psba3v8HGx9cRFhdbXPb3/v+AbXHe3w4fbm8cHV99fq6vTbu8FhceH0ZHTk9YWlxefn+1xdTV3PDx9XJzj3R1liYuL6evt7/Hz9ffmgBAl5gwjx/Oz9LUzv9OT1pbBwgPECcv7u9ubzc9P0JFkJFTZ3XIydDR2Nnn/v8AIF8igt8EgkQIGwQGEYGsDoCrBR8IgRwDGQgBBC8ENAQHAwEHBgcRClAPEgdVBwMEHAoJAwgDBwMCAwMDDAQFAwsGAQ4VBU4HGwdXBwIGFwxQBEMDLQMBBBEGDww6BB0lXyBtBGolgMgFgrADGgaC/QNZBxYJGAkUDBQMagYKBhoGWQcrBUYKLAQMBAEDMQssBBoGCwOArAYKBi8xgPQIPAMPAz4FOAgrBYL/ERgILxEtAyEPIQ+AjASCmhYLFYiUBS8FOwcCDhgJgL4idAyA1hqBEAWA4QnyngM3CYFcFIC4CIDdFTsDCgY4CEYIDAZ0Cx4DWgRZCYCDGBwKFglMBICKBqukDBcEMaEEgdomBwwFBYCmEIH1BwEgKgZMBICNBIC+AxsDDw1jb3JlL3NyYy91bmljb2RlL3VuaWNvZGVfZGF0YS5ycwAAAFEKEAAgAAAATgAAACgAAABRChAAIAAAAFoAAAAWAAAAAAMAAIMEIACRBWAAXROgABIXIB8MIGAf7ywgKyowoCtvpmAsAqjgLB774C0A/iA2nv9gNv0B4TYBCiE3JA3hN6sOYTkvGOE5MBzhSvMe4U5ANKFSHmHhU/BqYVRPb+FUnbxhVQDPYVZl0aFWANohVwDgoViu4iFa7OThW9DoYVwgAO5c8AF/XQBwAAcALQEBAQIBAgEBSAswFRABZQcCBgICAQQjAR4bWws6CQkBGAQBCQEDAQUrAzsJKhgBIDcBAQEECAQBAwcKAh0BOgEBAQIECAEJAQoCGgECAjkBBAIEAgIDAwEeAgMBCwI5AQQFAQIEARQCFgYBAToBAQIBBAgBBwMKAh4BOwEBAQwBCQEoAQMBNwEBAwUDAQQHAgsCHQE6AQICAQEDAwEEBwILAhwCOQIBAQIECAEJAQoCHQFIAQQBAgMBAQgBUQECBwwIYgECCQsHSQIbAQEBAQE3DgEFAQIFCwEkCQFmBAEGAQICAhkCBAMQBA0BAgIGAQ8BAAMABBwDHQIeAkACAQcIAQILCQEtAwEBdQIiAXYDBAIJAQYD2wICAToBAQcBAQEBAggGCgIBMB8xBDAKBAMmCQwCIAQCBjgBAQIDAQEFOAgCApgDAQ0BBwQBBgEDAsZAAAHDIQADjQFgIAAGaQIABAEKIAJQAgABAwEEARkCBQGXAhoSDQEmCBkLAQEsAzABAgQCAgIBJAFDBgICAgIMAQgBLwEzAQEDAgIFAgEBKgIIAe4BAgEEAQABABAQEAACAAHiAZUFAAMBAgUEKAMEAaUCAARBBQACTwRGCzEEewE2DykBAgIKAzEEAgIHAT0DJAUBCD4BDAI0CQEBCAQCAV8DAgQGAQIBnQEDCBUCOQIBAQEBDAEJAQ4HAwVDAQIGAQECAQEDBAMBAQ4CVQgCAwEBFwFRAQIGAQECAQECAQLrAQIEBgIBAhsCVQgCAQECagEBAQIIZQEBAQIEAQUACQEC9QEKBAQBkAQCAgQBIAooBgIECAEJBgIDLg0BAgAHAQYBAVIWAgcBAgECegYDAQECAQcBAUgCAwEBAQACCwI0BQUDFwEAAQYPAAwDAwAFOwcAAT8EUQELAgACAC4CFwAFAwYICAIHHgSUAwA3BDIIAQ4BFgUBDwAHARECBwECAQVkAaAHAAE9BAAE/gIAB20HAGCA8AAAAAAAAAEAAAAAAAAAgoAAAAAAAACKgAAAAAAAgACAAIAAAACAi4AAAAAAAAABAACAAAAAAIGAAIAAAACACYAAAAAAAICKAAAAAAAAAIgAAAAAAAAACYAAgAAAAAAKAACAAAAAAIuAAIAAAAAAiwAAAAAAAICJgAAAAAAAgAOAAAAAAACAAoAAAAAAAICAAAAAAAAAgAqAAAAAAAAACgAAgAAAAICBgACAAAAAgICAAAAAAACAAQAAgAAAAAAIgACAAAAAgC9ydXN0L2RlcHMvZGxtYWxsb2MtMC4yLjYvc3JjL2RsbWFsbG9jLnJzYXNzZXJ0aW9uIGZhaWxlZDogcHNpemUgPj0gc2l6ZSArIG1pbl9vdmVyaGVhZADQDhAAKQAAAKgEAAAJAAAAYXNzZXJ0aW9uIGZhaWxlZDogcHNpemUgPD0gc2l6ZSArIG1heF9vdmVyaGVhZAAA0A4QACkAAACuBAAADQA7CXByb2R1Y2VycwEMcHJvY2Vzc2VkLWJ5AgZ3YWxydXMGMC4yMy4yDHdhc20tYmluZGdlbgYwLjIuOTc="


class DeepSeekSessionError(RuntimeError):
    pass


class DeepSeekAuthError(DeepSeekSessionError):
    """Token expired/banned or the account is rate-limited.

    Unlike a transient network error this must NOT be retried on the next turn:
    that is what keeps a temporary restriction alive.
    """
    pass


class _DeepSeekPow:
    """Thread-safe wrapper around DeepSeek's sha3 wasm module."""

    _instance: "_DeepSeekPow | None" = None
    _lock = threading.Lock()

    def __init__(self) -> None:
        try:
            import wasmtime
        except ImportError as exc:  # pragma: no cover - setup issue
            raise DeepSeekSessionError(
                "The DeepSeek proof-of-work module needs the 'wasmtime' package. "
                "Close the worker and run StartFreeChat.bat again so its setup can install it."
            ) from exc

        self._wasmtime = wasmtime
        wasm = base64.b64decode(_POW_WASM_B64)
        self._store = wasmtime.Store()
        module = wasmtime.Module(self._store.engine, wasm)
        instance = wasmtime.Instance(self._store, module, [])
        exports = instance.exports(self._store)
        self._memory = exports["memory"]
        self._solve = exports["wasm_solve"]
        self._malloc = exports["__wbindgen_export_0"]
        self._add_to_stack = exports["__wbindgen_add_to_stack_pointer"]

    @classmethod
    def get(cls) -> "_DeepSeekPow":
        with cls._lock:
            if cls._instance is None:
                cls._instance = cls()
            return cls._instance

    def _write(self, text: str) -> tuple[int, int]:
        data = text.encode("utf-8")
        ptr = self._malloc(self._store, len(data), 1)
        self._memory.write(self._store, data, ptr)
        return ptr, len(data)

    def _solve_value(self, challenge: str, prefix: str, difficulty: float) -> int | None:
        store = self._store
        retptr = self._add_to_stack(store, -16)
        try:
            c_ptr, c_len = self._write(challenge)
            p_ptr, p_len = self._write(prefix)
            self._solve(store, retptr, c_ptr, c_len, p_ptr, p_len, float(difficulty))
            data = self._memory.read(store, retptr, retptr + 16)
            status = struct.unpack("<i", data[0:4])[0]
            value = struct.unpack("<d", data[8:16])[0]
        finally:
            self._add_to_stack(store, 16)
        return int(value) if status != 0 else None

    def make_header(self, challenge: dict) -> str:
        prefix = f"{challenge['salt']}_{challenge['expire_at']}_"
        answer = self._solve_value(challenge["challenge"], prefix, challenge["difficulty"])
        if answer is None:
            raise RuntimeError("DeepSeek PoW solver returned no answer (challenge expired?)")
        payload = {
            "algorithm": challenge["algorithm"],
            "challenge": challenge["challenge"],
            "salt": challenge["salt"],
            "answer": answer,
            "signature": challenge["signature"],
            "target_path": challenge["target_path"],
        }
        raw = json.dumps(payload, separators=(",", ":")).encode("utf-8")
        return base64.b64encode(raw).decode("utf-8")


class DeepSeekSession:
    def __init__(self, token: str, cookies: dict[str, str], user_agent: str, captured_at: float = 0.0):
        self.token = token
        self.cookies = cookies
        self.user_agent = user_agent
        self.captured_at = captured_at

    @classmethod
    def load(cls) -> "DeepSeekSession":
        if not SESSION_FILE.exists():
            raise DeepSeekSessionError(
                "DeepSeek is not signed in on this computer. Start StartFreeChat.bat again and sign in "
                "in the browser window it opens (once), or run: python local-chat-worker.py --login"
            )
        try:
            data = json.loads(SESSION_FILE.read_text(encoding="utf-8"))
        except Exception as exc:
            raise DeepSeekSessionError(f"Could not read {SESSION_FILE}: {exc}") from exc

        token = data.get("token") or data.get("userToken") or ""
        if isinstance(token, dict):
            token = token.get("value") or ""
        if not isinstance(token, str) or not token.strip():
            raise DeepSeekSessionError(
                f"{SESSION_FILE} does not contain a DeepSeek token. Run the login command again."
            )

        cookies = data.get("cookies") or {}
        if isinstance(cookies, list):
            cookies = {
                str(c.get("name")): str(c.get("value"))
                for c in cookies
                if isinstance(c, dict) and c.get("name") and c.get("value") is not None
            }
        if not isinstance(cookies, dict):
            cookies = {}
        cookies = {str(k): str(v) for k, v in cookies.items()}

        ua = data.get("user_agent") or data.get("userAgent") or USER_AGENT
        captured = data.get("captured_at") or data.get("capturedAt") or 0
        try:
            captured = float(captured)
        except (TypeError, ValueError):
            captured = 0.0
        if captured > 0 and time.time() - captured > _DS_MAX_AGE_SECONDS:
            # The worker used to keep hammering a token that DeepSeek had
            # already rotated: every turn and every world update added three
            # more calls to the same dead session.
            raise DeepSeekAuthError(
                "DeepSeek login is too old (saved over a day ago). "
                "Run StartFreeChat.bat again and sign in once to refresh it."
            )
        return cls(token.strip(), cookies, str(ua), captured)


def _deepseek_biz(data: dict) -> dict:
    if not isinstance(data, dict):
        raise RuntimeError("DeepSeek returned an unexpected response")
    if data.get("code") not in (0, None):
        msg = str(data.get("msg") or data)
        lowered = msg.lower()
        if any(marker in lowered for marker in (
            "invalid_token", "token", "401", "403", "429",
            "too many", "captcha", "forbidden", "unauthorized",
        )):
            raise DeepSeekAuthError("DeepSeek login expired or limited: " + msg[:160])
        raise RuntimeError("DeepSeek API error: " + msg[:160])
    biz = (data.get("data") or {}).get("biz_data")
    if biz is None:
        raise RuntimeError(f"Unexpected DeepSeek response shape: {str(data)[:300]}")
    return biz


def _flatten_prompt(messages, tools, tool_choice) -> str:
    """One flattened prompt string for providers that take a single user
    message (DeepSeek's composer, arena.ai's evaluation): the system block
    first, then every turn labelled by its role."""
    system_parts: list[str] = []
    lines: list[str] = []
    for message in messages or []:
        role = str(message.get("role") or "user")
        text = _content_text(message.get("content")).strip()
        if not text:
            continue
        if role == "system":
            system_parts.append(text)
        elif role == "assistant":
            lines.append("ASSISTANT:\n" + text)
        elif role == "tool":
            lines.append("TOOL RESULT:\n" + text)
        else:
            lines.append("USER:\n" + text)

    if tools and tool_choice != "none":
        system_parts.append(_tool_instruction(tools, tool_choice))

    prefix = ""
    if system_parts:
        prefix = "[SYSTEM INSTRUCTIONS]\n" + "\n\n".join(system_parts) + "\n[/SYSTEM INSTRUCTIONS]\n\n"
    return prefix + "\n\n".join(lines) + "\n\nASSISTANT:"


def _nested(value: Any, path: list[Any], default: Any = None) -> Any:
    """Read a positional field from Google's nested-list responses."""
    current = value
    for key in path:
        if not isinstance(current, (list, dict)):
            return default
        try:
            current = current[key]
        except (IndexError, KeyError, TypeError):
            return default
    return current if current is not None else default


def _parse_gemini_frames(text: str) -> list[Any]:
    """Parse Gemini's ``)]}'`` + length-prefixed stream without importing
    anything. Each frame is ``<utf16 length>\\n<json>``; the reply text inside
    a frame is cumulative, not a delta."""
    if not isinstance(text, str) or not text:
        return []
    body = text[4:].lstrip() if text.startswith(")]}'") else text.lstrip()
    frames: list[Any] = []
    pos = 0
    while pos < len(body):
        while pos < len(body) and body[pos].isspace():
            pos += 1
        if pos >= len(body):
            break
        match = re.match(r"(\d+)\n", body[pos:])
        if not match:
            # Older builds sometimes return plain NDJSON instead.
            for line in body[pos:].splitlines():
                line = line.strip()
                if not line:
                    continue
                try:
                    parsed = json.loads(line)
                except ValueError:
                    continue
                frames.extend(parsed if isinstance(parsed, list) else [parsed])
            break
        length = int(match.group(1))
        pos += match.end()
        start = pos
        units = 0
        while pos < len(body) and units < length:
            units += 2 if ord(body[pos]) > 0xFFFF else 1
            pos += 1
        try:
            parsed = json.loads(body[start:pos])
            frames.extend(parsed if isinstance(parsed, list) else [parsed])
        except ValueError:
            log.debug("ignored a malformed Gemini stream frame")
    return frames


def _gemini_model_spec(model: str) -> tuple[str, str, int, int]:
    key = str(model or "").strip().lower()
    for alias, target in (
        ("gemini-web", GEMINI_DEFAULT_MODEL),
        ("gemini", GEMINI_DEFAULT_MODEL),
        ("gemini-flash", "gemini-flash"),
        ("gemini-flash-lite", "gemini-flash-lite"),
        ("gemini-lite", "gemini-flash-lite"),
        ("gemini-pro", "gemini-pro"),
    ):
        if key == alias or key.startswith(alias + ":") or key.startswith(alias + "/"):
            model_id, number, capacity = GEMINI_MODELS[target]
            return target, model_id, number, capacity
    model_id, number, capacity = GEMINI_MODELS[GEMINI_DEFAULT_MODEL]
    return GEMINI_DEFAULT_MODEL, model_id, number, capacity


def _deepseek_headers(session: DeepSeekSession) -> dict[str, str]:
    return {
        "authorization": f"Bearer {session.token}",
        "accept": "*/*",
        "content-type": "application/json",
        "user-agent": session.user_agent or USER_AGENT,
        "origin": DEEPSEEK_BASE,
        "referer": f"{DEEPSEEK_BASE}/",
        "x-app-version": "2.0.0",
        "x-client-version": "2.0.0",
        "x-client-platform": "web",
        "x-client-locale": "en_US",
        "x-client-bundle-id": "com.deepseek.chat",
        "x-client-timezone-offset": "0",
    }


def _parse_fragment_list(value) -> list[dict]:
    if isinstance(value, str):
        try:
            value = json.loads(value)
        except json.JSONDecodeError:
            return []
    if isinstance(value, dict):
        return [value]
    if isinstance(value, list):
        return [f for f in value if isinstance(f, dict)]
    return []


def _parse_deepseek_sse(lines, include_thinking: bool) -> Iterator[tuple[str, str]]:
    """Yield ("content" | "reasoning", text) from DeepSeek's completion stream."""
    types: list[str | None] = []
    active: int | None = None
    emitted: dict[int, int] = {}

    def resolve(index: int) -> int:
        return len(types) - 1 if index == -1 else index

    def fragment_kind(index: int | None) -> str | None:
        if index is None or index < 0 or index >= len(types):
            return None
        return types[index]

    def claim(index: int, fragment: dict) -> Iterator[tuple[str, str]]:
        content = fragment.get("content") or ""
        if not isinstance(content, str):
            return
        seen = emitted.get(index, 0)
        if len(content) <= seen:
            return
        emitted[index] = len(content)
        kind = fragment_kind(index)
        if kind == "RESPONSE" or (kind == "THINK" and include_thinking):
            yield ("content" if kind == "RESPONSE" else "reasoning", content[seen:])

    for line in lines:
        if not line or not line.startswith("data:"):
            continue
        payload = line[len("data:"):].strip()
        if not payload or payload == "[DONE]":
            continue
        try:
            obj = json.loads(payload)
        except json.JSONDecodeError:
            continue

        value = obj.get("v")

        # Initial (or refreshed) snapshot: the full response object.
        if isinstance(value, dict) and "response" in value:
            fragments = [f for f in value["response"].get("fragments", []) if isinstance(f, dict)]
            types = [f.get("type") for f in fragments]
            emitted = {}
            for index, fragment in enumerate(fragments):
                kind = fragment.get("type")
                if kind == "RESPONSE" or (kind == "THINK" and include_thinking):
                    active = index
                    yield from claim(index, fragment)
            continue

        path = obj.get("p")

        # A new fragment object appended to the list.
        if path == "response/fragments" and obj.get("o") == "APPEND":
            for fragment in _parse_fragment_list(value):
                index = len(types)
                types.append(fragment.get("type"))
                kind = fragment.get("type")
                if kind == "RESPONSE" or (kind == "THINK" and include_thinking):
                    active = index
                    yield from claim(index, fragment)
            continue

        if "p" in obj:
            match = _CONTENT_PATH.match(path) if isinstance(path, str) else None
            if match:
                active = resolve(int(match.group(1)))
            if obj.get("o") == "APPEND" and isinstance(value, str) and match:
                kind = fragment_kind(active)
                if kind == "RESPONSE" or (kind == "THINK" and include_thinking):
                    emitted[active] = emitted.get(active, 0) + len(value)
                    yield ("content" if kind == "RESPONSE" else "reasoning", value)
            continue

        if isinstance(value, str):
            kind = fragment_kind(active)
            if kind == "RESPONSE" or (kind == "THINK" and include_thinking):
                emitted[active] = emitted.get(active, 0) + len(value)
                yield ("content" if kind == "RESPONSE" else "reasoning", value)


def _is_bot_challenge(response: httpx.Response) -> bool:
    header = (response.headers.get("x-amzn-waf-action") or "").lower()
    return response.status_code == 202 or "challenge" in header


def _translate_deepseek(model: str, messages, tools, tool_choice):
    global _DS_COOLDOWN_UNTIL, _DS_LAST_CALL_AT
    created = int(time.time())
    session = None
    produced = 0
    # A banned/expired token must not be retried on the next turn: that is how a
    # two-day restriction gets prolonged indefinitely. Pace chat + world too.
    with _DS_STATE_LOCK:
        now = time.time()
        if now < _DS_COOLDOWN_UNTIL:
            left = int(_DS_COOLDOWN_UNTIL - now)
            yield _error_event(
                f"DeepSeek is cooling down for {left}s after an auth or rate-limit error. "
                "Run StartFreeChat.bat again and sign in once if the login expired."
            )
            yield "data: [DONE]\n\n"
            return
        wait = _DS_MIN_INTERVAL_SECONDS - (now - _DS_LAST_CALL_AT)
        if wait > 0:
            time.sleep(wait)
        _DS_LAST_CALL_AT = time.time()
    try:
        session = DeepSeekSession.load()
        prompt = _flatten_prompt(messages, tools, tool_choice)
        lower = model.lower()
        model_type = "expert" if "expert" in lower or "reason" in lower else "default"
        thinking = "expert" in lower or "think" in lower

        with httpx.Client(
            base_url=DEEPSEEK_BASE,
            headers=_deepseek_headers(session),
            cookies=session.cookies,
            timeout=DEEPSEEK_TIMEOUT,
            follow_redirects=True,
        ) as client:
            create = client.post("/api/v0/chat_session/create", json={})
            if create.status_code in (401, 403):
                raise DeepSeekAuthError(
                    "DeepSeek rejected the saved session (login expired). Run StartFreeChat.bat again to sign in."
                )
            create.raise_for_status()
            session_id = _deepseek_biz(create.json())["chat_session"]["id"]

            challenge_response = client.post(
                "/api/v0/chat/create_pow_challenge",
                json={"target_path": "/api/v0/chat/completion"},
            )
            if challenge_response.status_code in (401, 403):
                raise DeepSeekAuthError(
                    "DeepSeek rejected the saved session (login expired). Run StartFreeChat.bat again to sign in."
                )
            challenge_response.raise_for_status()
            challenge = _deepseek_biz(challenge_response.json())["challenge"]
            pow_header = _DeepSeekPow.get().make_header(challenge)

            body = {
                "chat_session_id": session_id,
                "parent_message_id": None,
                "prompt": prompt,
                "ref_file_ids": [],
                "thinking_enabled": thinking,
                "search_enabled": False,
                "action": None,
                "preempt": False,
                "model_type": model_type,
            }

            with client.stream(
                "POST",
                "/api/v0/chat/completion",
                json=body,
                headers={"x-ds-pow-response": pow_header},
            ) as response:
                if _is_bot_challenge(response):
                    raise DeepSeekAuthError(
                        "DeepSeek answered with a bot check instead of a reply. Run StartFreeChat.bat again "
                        "and sign in once in the browser window so a fresh session is saved."
                    )
                if response.status_code in (401, 403):
                    raise DeepSeekAuthError(
                        "DeepSeek rejected the saved session (login expired). Run StartFreeChat.bat again to sign in."
                    )
                if response.status_code < 200 or response.status_code >= 300:
                    body_text = response.read().decode("utf-8", "replace")[:300]
                    raise RuntimeError(f"DeepSeek HTTP {response.status_code}: {body_text}")

                for kind, text in _parse_deepseek_sse(response.iter_lines(), include_thinking=thinking):
                    if not text:
                        continue
                    produced += 1
                    if kind == "reasoning":
                        yield _chunk(created, model, {"reasoning_content": text})
                    else:
                        yield _chunk(created, model, {"content": text})

        if produced == 0:
            yield _error_event(
                "DeepSeek returned no text. Check that the saved session is still valid, then try again."
            )
        else:
            with _DS_STATE_LOCK:
                _DS_COOLDOWN_UNTIL = 0.0
            yield _chunk(created, model, {}, finish="stop")
        yield "data: [DONE]\n\n"
    except DeepSeekAuthError as exc:
        # An INVALID_TOKEN session can never recover by waiting: it needs a new
        # browser sign-in. Delete the dead receipt so the next bat run offers
        # --login again, and keep the pause short so a fresh sign-in is usable
        # on the very next turn instead of unlocking ten minutes later.
        auth_dead = any(
            word in str(exc).lower()
            for word in ("invalid_token", "login expired", "rejected the saved session")
        )
        pause = 120.0 if auth_dead else min(_DS_COOLDOWN_SECONDS, 180.0)
        with _DS_STATE_LOCK:
            _DS_COOLDOWN_UNTIL = time.time() + pause
        if auth_dead:
            try:
                if SESSION_FILE.exists():
                    SESSION_FILE.unlink()
                    log.warning("removed stale DeepSeek session %s", SESSION_FILE)
            except OSError:
                pass
        log.warning("DeepSeek auth/rate-limit issue; pausing the adapter for %ss: %s", int(pause), exc)
        extra = (
            " The stale sign-in was removed; rerun StartImage+Chat.bat and press Enter to sign in again."
            if auth_dead else ""
        )
        yield _error_event(str(exc) + f" The adapter is paused for {int(pause)}s." + extra)
        yield "data: [DONE]\n\n"
    except DeepSeekSessionError as exc:
        log.warning("DeepSeek session issue: %s", exc)
        yield _error_event(str(exc))
        yield "data: [DONE]\n\n"
    except httpx.HTTPStatusError as exc:
        status = exc.response.status_code
        detail = ""
        try:
            detail = exc.response.text[:240]
        except Exception:
            pass
        if status == 429:
            raise DeepSeekAuthError("DeepSeek rate limit reached on this machine's IP.")
        if status in (401, 403):
            raise DeepSeekAuthError("DeepSeek rejected the saved session (login expired).")
        message = f"DeepSeek HTTP {status}: {detail}"
        log.warning("DeepSeek request failed: %s", message)
        yield _error_event(message)
        yield "data: [DONE]\n\n"
    except Exception as exc:
        log.exception("DeepSeek relay error")
        yield _error_event(f"DeepSeek relay error: {str(exc)[:240]}")
        yield "data: [DONE]\n\n"


# ---------------------------------------------------------------------------
# One-time browser login (Chrome DevTools Protocol; no Playwright dependency)
# ---------------------------------------------------------------------------
def _find_chrome() -> str:
    candidates = []
    env = os.getenv("CHROME_PATH")
    if env:
        candidates.append(Path(env))
    for root in (os.getenv("ProgramFiles"), os.getenv("ProgramFiles(x86)"), os.getenv("LocalAppData")):
        if root:
            candidates.append(Path(root) / "Google" / "Chrome" / "Application" / "chrome.exe")
            candidates.append(Path(root) / "Microsoft" / "Edge" / "Application" / "msedge.exe")
    for candidate in candidates:
        if candidate.is_file():
            return str(candidate)
    raise DeepSeekSessionError(
        "Could not find Google Chrome or Microsoft Edge. Install Chrome, or set CHROME_PATH to the browser executable."
    )


def _free_port() -> int:
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as sock:
        sock.bind(("127.0.0.1", 0))
        return int(sock.getsockname()[1])


def _cdp_call(ws, request_id: int, method: str, params: dict | None = None) -> dict:
    ws.send(json.dumps({"id": request_id, "method": method, "params": params or {}}))
    deadline = time.time() + 20
    while time.time() < deadline:
        message = json.loads(ws.recv())
        if message.get("id") != request_id:
            continue
        if "error" in message:
            raise RuntimeError(f"Chrome DevTools: {message['error']}")
        return message.get("result") or {}
    raise RuntimeError("Chrome DevTools did not answer in time")


def _wait_cdp_target(port: int, timeout: float = 30.0) -> str:
    deadline = time.time() + timeout
    while time.time() < deadline:
        try:
            with urllib.request.urlopen(f"http://127.0.0.1:{port}/json", timeout=2) as response:
                targets = json.loads(response.read().decode("utf-8"))
            for target in targets:
                if target.get("type") == "page" and target.get("webSocketDebuggerUrl"):
                    return str(target["webSocketDebuggerUrl"])
        except Exception:
            pass
        time.sleep(0.5)
    raise RuntimeError("Chrome did not expose a browser page. Close any other Chrome automation window and try again.")


def login() -> None:
    try:
        import websocket  # type: ignore
    except ImportError as exc:
        raise DeepSeekSessionError(
            "The DeepSeek login helper needs the 'websocket-client' package. "
            "Run StartFreeChat.bat again so its setup can install it."
        ) from exc

    chrome = _find_chrome()
    port = _free_port()
    profile = Path(__file__).resolve().with_name("deepseek-chrome-profile")
    profile.mkdir(parents=True, exist_ok=True)
    url = f"{DEEPSEEK_BASE}/sign_in"
    process = subprocess.Popen(
        [
            chrome,
            f"--remote-debugging-port={port}",
            f"--user-data-dir={profile}",
            "--no-first-run",
            "--no-default-browser-check",
            "--disable-blink-features=AutomationControlled",
            "--start-maximized",
            url,
        ],
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )

    try:
        ws_url = _wait_cdp_target(port)
        ws = websocket.create_connection(ws_url, timeout=20)
        try:
            request_id = 0
            _cdp_call(ws, request_id, "Runtime.enable")
            request_id += 1
            _cdp_call(ws, request_id, "Network.enable")
            request_id += 1

            token_js = (
                "(() => { try { const raw = localStorage.getItem('userToken');"
                " if (!raw) return ''; const o = JSON.parse(raw);"
                " return (o && o.value) ? o.value : ''; } catch (e) { return ''; } })()"
            )
            token = ""
            deadline = time.time() + 300
            print("Sign in to DeepSeek in the browser window. Waiting up to 5 minutes...")
            while time.time() < deadline:
                result = _cdp_call(ws, request_id, "Runtime.evaluate", {"expression": token_js, "returnByValue": True})
                request_id += 1
                token = str(((result.get("result") or {}).get("value")) or "")
                if token:
                    break
                time.sleep(2)

            if not token:
                raise DeepSeekSessionError("DeepSeek login timed out; no token was captured.")

            ua_result = _cdp_call(
                ws, request_id, "Runtime.evaluate",
                {"expression": "navigator.userAgent", "returnByValue": True},
            )
            request_id += 1
            user_agent = str(((ua_result.get("result") or {}).get("value")) or USER_AGENT)

            cookies_result = _cdp_call(ws, request_id, "Network.getAllCookies")
            cookies = {}
            for cookie in cookies_result.get("cookies") or []:
                domain = str(cookie.get("domain") or "")
                if "deepseek.com" not in domain:
                    continue
                name = cookie.get("name")
                value = cookie.get("value")
                if name and value is not None:
                    cookies[str(name)] = str(value)

            SESSION_FILE.parent.mkdir(parents=True, exist_ok=True)
            SESSION_FILE.write_text(
                json.dumps(
                    {
                        "token": token,
                        "cookies": cookies,
                        "user_agent": user_agent,
                        "captured_at": time.time(),
                    },
                    indent=2,
                ),
                encoding="utf-8",
            )
            print(f"Saved DeepSeek session to {SESSION_FILE}")
        finally:
            try:
                ws.close()
            except Exception:
                pass
    finally:
        # terminate() only signals the launcher; Chrome's renderers survive and
        # leave a maximized window in the taskbar. Kill the whole tree.
        subprocess.run(["taskkill", "/PID", str(process.pid), "/T", "/F"], capture_output=True)


# ---------------------------------------------------------------------------
# Arena adapter (arena.ai, formerly lmarena.ai; router model Max)
# ---------------------------------------------------------------------------
# Arena's chat takes three things a plain HTTP call cannot make: a signed-in
# session cookie, a reCAPTCHA Enterprise token minted ON arena.ai (the token
# embeds its origin and the server checks it), and a composer-interaction
# fingerprint ("cx"). The worker therefore keeps one real Chrome window
# parked off-screen and off the taskbar with arena.ai open, and mints a
# token through the DevTools protocol right before each request. The player
# meets that window exactly twice: the one-time sign-in, and the rare
# reCAPTCHA v2 checkbox when Google doubts the invisible token. Everything
# else is a plain httpx call, exactly like the DeepSeek adapter.
#
# Each chat turn is a fresh "direct-battle" evaluation against Max: the whole
# conversation is flattened into one user message, so no arena-side session
# state is needed and the cookie never leaves this machine.

ARENA_BASE = os.getenv("ARENA_BASE_URL", "https://arena.ai").rstrip("/")
ARENA_HOSTNAME = urllib.parse.urlparse(ARENA_BASE).hostname or "arena.ai"
ARENA_PROFILE = Path(os.getenv("ARENA_CHROME_PROFILE") or Path(__file__).resolve().with_name("arena-chrome-profile")).expanduser()
ARENA_INFO_FILE = Path(os.getenv("ARENA_INFO_FILE") or Path(__file__).resolve().with_name("arena-chrome.json")).expanduser()
ARENA_SESSION_FILE = Path(os.getenv("ARENA_SESSION_FILE") or Path(__file__).resolve().with_name("arena-session.json")).expanduser()
# The browser splits the session value into arena-auth-prod-v1.0/.1/... chunks.
ARENA_COOKIE_PREFIX = "arena-auth"
# reCAPTCHA keys from arena.ai's own pages: Enterprise v3 (invisible) for
# every request, v2 (checkbox) for their low-score fallback.
ARENA_RECAPTCHA_KEY = "6LeTGMcsAAAAALuIlkVwIxaAuZA8VledA6d3Nnb0"
ARENA_RECAPTCHA_V2_KEY = "6Le3_cYsAAAAAGwWOK2RLDgNI15Bh8C0yLBOL1yL"
ARENA_CREATE_PATH = "/nextjs-api/stream/create-evaluation"
ARENA_CATALOG_PATH = "/nextjs-api/model-catalog"
# Max, arena.ai's router model; resolved from the live catalog (cached for a
# day) with this id as the unreachable-catalog fallback.
ARENA_DEFAULT_MODEL_ID = "019b24bb-5caf-71c3-b854-37d0c7086f21"
ARENA_TIMEOUT = httpx.Timeout(connect=20.0, read=300.0, write=60.0, pool=20.0)
# arena.ai allows roughly 30 messages per account per 5-minute window, so the
# adapter keeps its own pace instead of leaning on the server's 429s.
ARENA_MIN_INTERVAL = 1.2
ARENA_WINDOW_SECONDS = 300.0
ARENA_WINDOW_MAX = 24


class ArenaError(RuntimeError):
    """An arena.ai failure that already has a player-readable cause."""


class ArenaLoginRequired(ArenaError):
    """The parked browser holds no arena.ai session cookie."""


class GeminiLoginRequired(ArenaError):
    """No signed-in Google tab is available for the Gemini web adapter."""


# The "cx" field is arena.ai's composer-interaction fingerprint: a bit-packed
# table of typing statistics, shuffled and masked by a seed that travels in
# the blob header (v2 of their encoder, ported from the site bundle). The
# server only sanity-checks the shape, so a plausible synthetic interaction
# that matches the message length is enough.
_CX_ALPHABET = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_"
_CX_SUBMIT_KINDS = ["enter", "button", "programmatic", "unknown"]
_CX_DOC_OWN_PROPS = ["visibilityState", "hidden", "hasFocus"]
_CX_PRESS_BUCKETS = ["none", "lt5", "lt50", "lt300", "ge300"]
_CX_PRESSURE_BUCKETS = ["none", "zero", "half", "other"]
_CX_MOVE_BUCKETS = ["0", "1to3", "4to15", "gt15"]
_CX_COALESCED_BUCKETS = ["0", "1", "2to4", "gt4"]
_CX_HEARTBEAT_BUCKETS = ["lt2s", "lt10s", "lt60s", "ge60s"]
_CX_VISIBILITY_BUCKETS = ["0", "1to3", "gt3"]
_CX_LAYOUT = [
    ("submitKind", 2), ("submitTrusted", 2), ("untrustedUiEvents", 4),
    ("charsTyped", 8), ("insertMulti", 4), ("pasteCount", 4),
    ("pasteWithoutModifier", 1), ("composition", 1), ("otherInputTypes", 4),
    ("docOwnProps", 3), ("coarsePointer", 1), ("integrity", 16),
    ("pressBucket", 3), ("pressureBucket", 2), ("movesBeforeClick", 2),
    ("maxCoalesced", 2), ("heartbeatGapBucket", 2), ("visibilityChangesBucket", 2),
    ("focusVisContradiction", 1), ("visitTag", 16), ("minuteTag", 16),
]
_CX_VERSION = 2
_CX_PAYLOAD_BYTES = (sum(bits for _, bits in _CX_LAYOUT) + 7) // 8


def _cx_imul(a: int, b: int) -> int:
    """JavaScript Math.imul semantics: a 32-bit integer multiply."""
    return ((a & 0xFFFFFFFF) * (b & 0xFFFFFFFF)) & 0xFFFFFFFF


def _cx_rng(seed: int):
    state = (0x5BD1E995 ^ seed) & 0xFFFFFFFF

    def rand() -> int:
        nonlocal state
        state = (state + 0x6D2B79F5) & 0xFFFFFFFF
        t = state ^ (state >> 15)
        t = _cx_imul(t, (1 | state) & 0xFFFFFFFF)
        t = (t ^ ((t + _cx_imul(t ^ (t >> 7), (61 | t) & 0xFFFFFFFF)) & 0xFFFFFFFF)) & 0xFFFFFFFF
        return (t ^ (t >> 14)) & 0xFFFFFFFF

    return rand


def _cx_order_and_mask(seed: int):
    rand = _cx_rng(seed)
    order = list(range(len(_CX_LAYOUT)))
    for i in range(len(order) - 1, 0, -1):
        j = rand() % (i + 1)
        order[i], order[j] = order[j], order[i]
    mask = bytes(rand() & 0xFF for _ in range(_CX_PAYLOAD_BYTES))
    return order, mask


def _cx_bucket_index(buckets: list[str], value) -> int:
    return buckets.index(value) if value in buckets else 0


def _cx_encode(interaction: dict, seed: int) -> str:
    order, mask = _cx_order_and_mask(seed)
    payload = bytearray(_CX_PAYLOAD_BYTES)
    bitpos = 0

    def put(value: int, bits: int) -> None:
        nonlocal bitpos
        for shift in range(bits - 1, -1, -1):
            if (value >> shift) & 1:
                payload[bitpos >> 3] |= 128 >> (bitpos & 7)
            bitpos += 1

    for idx in order:
        key, bits = _CX_LAYOUT[idx]
        if key == "submitKind":
            put(_cx_bucket_index(_CX_SUBMIT_KINDS, interaction.get("submitKind", "unknown")), bits)
        elif key == "submitTrusted":
            value = interaction.get("submitTrusted")
            put(0 if value is None else (2 if value else 1), bits)
        elif key in ("pasteWithoutModifier", "composition", "coarsePointer", "focusVisContradiction"):
            put(1 if interaction.get(key) else 0, bits)
        elif key == "docOwnProps":
            put(sum(1 << _CX_DOC_OWN_PROPS.index(p) for p in interaction.get("docOwnProps", []) if p in _CX_DOC_OWN_PROPS), bits)
        elif key in ("untrustedUiEvents", "charsTyped", "insertMulti", "pasteCount", "otherInputTypes", "integrity", "visitTag", "minuteTag"):
            put(interaction.get(key, 0) & ((1 << bits) - 1), bits)
        elif key == "pressBucket":
            put(_cx_bucket_index(_CX_PRESS_BUCKETS, interaction.get(key, "none")), bits)
        elif key == "pressureBucket":
            put(_cx_bucket_index(_CX_PRESSURE_BUCKETS, interaction.get(key, "none")), bits)
        elif key == "movesBeforeClick":
            put(_cx_bucket_index(_CX_MOVE_BUCKETS, interaction.get(key, "0")), bits)
        elif key == "maxCoalesced":
            put(_cx_bucket_index(_CX_COALESCED_BUCKETS, interaction.get(key, "0")), bits)
        elif key == "heartbeatGapBucket":
            put(_cx_bucket_index(_CX_HEARTBEAT_BUCKETS, interaction.get(key, "lt2s")), bits)
        elif key == "visibilityChangesBucket":
            put(_cx_bucket_index(_CX_VISIBILITY_BUCKETS, interaction.get(key, "0")), bits)

    for i in range(_CX_PAYLOAD_BYTES):
        payload[i] ^= mask[i]

    blob = bytes([_CX_VERSION, (seed >> 8) & 0xFF, seed & 0xFF]) + bytes(payload)
    out = []
    for i in range(0, len(blob), 3):
        b0 = blob[i]
        b1 = blob[i + 1] if i + 1 < len(blob) else None
        b2 = blob[i + 2] if i + 2 < len(blob) else None
        n = (b0 << 16) | ((b1 or 0) << 8) | (b2 or 0)
        chunk = _CX_ALPHABET[(n >> 18) & 63] + _CX_ALPHABET[(n >> 12) & 63]
        if b1 is not None:
            chunk += _CX_ALPHABET[(n >> 6) & 63]
        if b2 is not None:
            chunk += _CX_ALPHABET[n & 63]
        out.append(chunk)
    return "".join(out)


def _arena_uuid7() -> str:
    """UUIDv7, the id shape arena.ai's client generates for every evaluation
    and message (time-ordered; a uuid4 would be accepted too, but staying
    faithful costs six lines)."""
    ms = int(time.time() * 1000)
    raw = bytearray(uuid.uuid4().bytes)
    raw[0] = (ms >> 40) & 0xFF
    raw[1] = (ms >> 32) & 0xFF
    raw[2] = (ms >> 24) & 0xFF
    raw[3] = (ms >> 16) & 0xFF
    raw[4] = (ms >> 8) & 0xFF
    raw[5] = ms & 0xFF
    raw[6] = (raw[6] & 0x0F) | 0x70
    raw[8] = (raw[8] & 0x3F) | 0x80
    return str(uuid.UUID(bytes=bytes(raw)))


# A small overlay drawn on arena.ai's own page for the rare reCAPTCHA v2
# fallback; their script tag serves the widget itself.
_ARENA_V2_WIDGET_JS = """
(function () {
  var d = document.getElementById('aam-recaptcha-overlay');
  if (d) d.remove();
  window.__aamV2Token = null;
  d = document.createElement('div');
  d.id = 'aam-recaptcha-overlay';
  d.style.cssText = 'position:fixed;inset:0;z-index:2147483647;background:rgba(15,18,25,0.82);display:flex;align-items:center;justify-content:center';
  var card = document.createElement('div');
  card.style.cssText = 'background:#fff;padding:28px 34px;border-radius:14px;display:flex;flex-direction:column;gap:14px;align-items:center;font-family:system-ui,sans-serif';
  var title = document.createElement('div');
  title.style.cssText = 'font-size:15px;font-weight:600;color:#111';
  title.textContent = 'AI Adventure Master: human check';
  var hint = document.createElement('div');
  hint.style.cssText = 'font-size:12px;color:#555';
  hint.textContent = 'Tick the box so the game can keep talking to arena.ai.';
  var slot = document.createElement('div');
  card.appendChild(title);
  card.appendChild(slot);
  card.appendChild(hint);
  d.appendChild(card);
  document.body.appendChild(d);
  grecaptcha.enterprise.render(slot, {
    sitekey: %s,
    callback: function (token) { window.__aamV2Token = token; d.remove(); }
  });
})();
""" % json.dumps(ARENA_RECAPTCHA_V2_KEY)


class ArenaBrowser:
    """One Chrome holding arena.ai open for cookies and reCAPTCHA tokens.

    The window never owns a taskbar button (Windows only): it is parked
    off-screen normally and is only brought on-screen for the one-time sign-in
    and the rare v2 checkbox. Cookies are re-read from the live profile before
    every request, and the ones arena.ai re-mints mid-flight are fed back in,
    so the tab and the relay always share one live session. Chrome is adopted across worker
    restarts through a small {port, pid} note, so a killed worker never
    strands a profile-locked browser behind it.
    """

    _instance: "ArenaBrowser | None" = None
    _instance_lock = threading.Lock()

    @classmethod
    def instance(cls) -> "ArenaBrowser":
        with cls._instance_lock:
            if cls._instance is None:
                cls._instance = cls()
            return cls._instance

    @classmethod
    def stop_instance(cls) -> None:
        if cls._instance is not None:
            cls._instance.stop()

    def __init__(self) -> None:
        self._lock = threading.RLock()
        self._proc: subprocess.Popen | None = None
        self._ws = None
        self._cdp_port: int | None = None
        self._cdp_pid: int | None = None
        self._window_pid_cache: int | None = None
        # Whether the Chrome window is supposed to be off-screen right now.
        # Every branch that shows it for sign-in / a human check restores this
        # afterwards; guarded calls re-apply it in case Chrome re-created the HWND.
        self._window_hidden = True
        self._next_id = 0
        self._user_agent: str | None = None
        self._model_id: str | None = None
        self._model_id_at = 0.0
        self._window_watchdog: threading.Thread | None = None
        # A second DevTools tab for TryingOpen. Its page JS installs the
        # Kasada x-is-human header on /api/open, so the request has to be made
        # there instead of from httpx.
        self._trying_ws = None
        self._trying_ws_url: str | None = None
        self._trying_next_id = 0
        # Same idea for Gemini web chat: a second page-context socket in the
        # same parked Chrome. Its globals carry the CSRF token we cannot mint.
        self._gemini_ws = None
        self._gemini_ws_url: str | None = None
        self._gemini_next_id = 0
        # HuggingChat guest tab. Driven through the page UI, not a private
        # endpoint, so no account token or internal API shape is required.
        self._hug_ws = None
        self._hug_ws_url: str | None = None
        self._hug_next_id = 0
        self._start_window_watchdog()

    # -- lifecycle ----------------------------------------------------------

    def _read_note(self) -> dict:
        try:
            return json.loads(ARENA_INFO_FILE.read_text(encoding="utf-8"))
        except Exception:
            return {}

    def _write_note(self) -> None:
        try:
            ARENA_INFO_FILE.write_text(json.dumps({"port": self._cdp_port, "pid": self._cdp_pid}), encoding="utf-8")
        except Exception:
            log.debug("could not write %s", ARENA_INFO_FILE, exc_info=True)

    def _page_ws_url(self, port: int, timeout: float = 2.0) -> str | None:
        try:
            with urllib.request.urlopen(f"http://127.0.0.1:{port}/json", timeout=timeout) as response:
                targets = json.loads(response.read().decode("utf-8"))
        except Exception:
            return None
        for target in targets:
            if target.get("type") == "page" and ARENA_HOSTNAME in str(target.get("url") or ""):
                ws_url = target.get("webSocketDebuggerUrl")
                if ws_url:
                    return str(ws_url)
        return None

    def ensure(self) -> None:
        """A connected DevTools session, launching or adopting Chrome if
        needed. Safe to call before every request."""
        with self._lock:
            self._ensure_connected()

    def _ensure_connected(self) -> None:
        if self._ws is not None:
            return
        note = self._read_note()
        port = note.get("port")
        pid = note.get("pid")
        self._window_pid_cache = None
        if isinstance(port, int):
            ws_url = self._page_ws_url(port)
            if ws_url:
                self._cdp_port = port
                self._cdp_pid = pid if isinstance(pid, int) else None
                self._connect(ws_url)
                self._apply_window_style(hidden=True)
                log.info("arena: adopted parked Chrome on port %d", port)
                return
        if isinstance(pid, int):
            # A previous worker left Chrome holding the profile but not its
            # debugging port: retire it before launching a fresh one, or the
            # new process would just open a tab in the old browser and the
            # port we asked for would never answer.
            subprocess.run(["taskkill", "/PID", str(pid), "/T", "/F"], capture_output=True)
        self._launch(visible=False)

    def _retire_stranded(self) -> None:
        """Kill an arena Chrome left by an earlier login before launching.

        A stranded browser keeps the profile lock, so the next launch only
        opens a tab in it - with its old taskbar window - instead of becoming
        the browser we can style and close. The note identifies that process;
        removing it here breaks the chain that made the window permanent.
        """
        pid = self._read_note().get("pid")
        if isinstance(pid, int) and pid > 0:
            subprocess.run(["taskkill", "/PID", str(pid), "/T", "/F"], capture_output=True)

    def _launch(self, visible: bool) -> None:
        try:
            chrome = _find_chrome()
        except DeepSeekSessionError as exc:
            raise ArenaError(str(exc)) from exc
        ARENA_PROFILE.mkdir(parents=True, exist_ok=True)
        self._retire_stranded()
        port = _free_port()
        args = [
            chrome,
            f"--remote-debugging-port={port}",
            f"--user-data-dir={ARENA_PROFILE}",
            "--no-first-run",
            "--no-default-browser-check",
            "--disable-blink-features=AutomationControlled",
            # These are the Chrome windows that used to appear unmarked on the
            # taskbar ("restore pages", "Chrome was not shut down correctly",
            # extension/component prompts). None of them is needed for cookies
            # or the reCAPTCHA script the arena adapter reads.
            "--disable-session-crashed-bubble",
            "--disable-infobars",
            "--noerrdialogs",
            "--disable-extensions",
            "--disable-component-update",
            "--disable-background-networking",
            "--disable-default-apps",
            "--disable-sync",
            "--disable-features=Translate,MediaRouter,InterestFeedContentSuggestions,CalculateNativeWinOcclusion",
            "--window-size=1100,800",
        ]
        if visible:
            args += ["--window-position=120,80"]
        else:
            # Parked out of sight: the tab exists for its cookies and its
            # reCAPTCHA script, not for the player to look at.
            args += ["--window-position=-32000,-32000"]
        args.append(f"{ARENA_BASE}/")
        proc = subprocess.Popen(args, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        self._proc = proc
        self._cdp_port = port
        self._cdp_pid = proc.pid
        self._window_pid_cache = None
        self._write_note()
        deadline = time.time() + 40
        # Chrome creates its HWND seconds before DevTools reports a page, and a
        # taskbar button appears with it. Style the window during that gap too,
        # using the PID we just launched, so it is never visibly registered -
        # not even when this launch is the player-visible sign-in window.
        early_deadline = time.time() + 6.0
        ws_url = None
        while time.time() < deadline:
            ws_url = self._page_ws_url(port, timeout=1.0)
            if ws_url:
                break
            if proc.poll() is not None:
                raise ArenaError("Chrome closed itself while opening arena.ai")
            if time.time() < early_deadline:
                # The launcher may have handed the browser to an already-running
                # chrome.exe, so ask the OS for the real owner of the CDP port.
                self._apply_window_style(hidden=not visible, pid=self._window_pid() or proc.pid)
            time.sleep(0.2)
        if not ws_url:
            raise ArenaError("Chrome did not open arena.ai within 40 seconds")
        self._connect(ws_url)
        # The visible sign-in window is on screen, but must be a tool window
        # too: otherwise Windows gives it a taskbar button for the whole login.
        self._apply_window_style(hidden=not visible)
        log.info("arena: parked Chrome on port %d (pid %s)", port, self._window_pid() or proc.pid)

    def _connect(self, ws_url: str) -> None:
        try:
            import websocket  # installed by StartFreeChat.bat's setup
        except ImportError as exc:
            raise ArenaError(
                "The arena.ai adapter needs the 'websocket-client' package. "
                "Run StartFreeChat.bat again so its setup can install it."
            ) from exc
        self._ws = websocket.create_connection(ws_url, timeout=30)
        self._cdp_call("Runtime.enable")
        self._cdp_call("Network.enable")

    def reset(self) -> None:
        """Forget the DevTools session (the browser itself is left alone)."""
        for socket in (self._ws, self._trying_ws, self._gemini_ws):
            try:
                if socket is not None:
                    socket.close()
            except Exception:
                pass
        self._ws = None
        self._trying_ws = None
        self._trying_ws_url = None
        self._gemini_ws = None
        self._gemini_ws_url = None
        self._window_pid_cache = None

    def _port_alive(self) -> bool:
        if self._cdp_port is None:
            return False
        try:
            with urllib.request.urlopen(f"http://127.0.0.1:{self._cdp_port}/json/version", timeout=2.0):
                return True
        except Exception:
            return False

    def _graceful_close(self) -> None:
        """Ask Chrome to close itself (Browser.close on the browser-level
        socket). A hard terminate leaves the profile marked as crashed, and
        the next launch would greet the player with a restore bubble."""
        if self._cdp_port is None:
            return
        try:
            import websocket

            with urllib.request.urlopen(
                f"http://127.0.0.1:{self._cdp_port}/json/version", timeout=2.0
            ) as response:
                ws_url = json.loads(response.read().decode("utf-8")).get("webSocketDebuggerUrl")
            if not ws_url:
                return
            ws = websocket.create_connection(ws_url, timeout=10)
            try:
                ws.send(json.dumps({"id": 1, "method": "Browser.close"}))
                deadline = time.time() + 5.0
                while time.time() < deadline:
                    ws.settimeout(max(0.5, deadline - time.time()))
                    try:
                        ws.recv()
                    except Exception:
                        break
            finally:
                ws.close()
        except Exception:
            log.debug("arena: graceful close failed", exc_info=True)

    def stop(self) -> None:
        with self._lock:
            # The launcher PID is NOT necessarily the browser: when Chrome hands
            # a second launch to an already-running process, _cdp_pid exits at
            # once and the visible window survives. Ask the OS/CDP for the real
            # owner first, and keep both IDs for the forced cleanup below.
            browser_pid = self._window_pid() or self._cdp_pid
            launcher_pid = self._cdp_pid
            self.reset()
            # Park and strip the taskbar button BEFORE closing. If the close is
            # refused (a hung renderer, a sign-in dialog), the window is still
            # off-screen and unlisted instead of sitting in the player's bar.
            self._apply_window_style(hidden=True, pid=browser_pid)
            self._graceful_close()
            if self._proc is not None:
                try:
                    self._proc.wait(timeout=10)
                except Exception:
                    pass
                if self._proc.poll() is None:
                    try:
                        self._proc.terminate()
                        self._proc.wait(timeout=5)
                    except Exception:
                        pass
                self._proc = None
            else:
                deadline = time.time() + 8.0
                while time.time() < deadline and self._port_alive():
                    time.sleep(0.5)
            # Final guarantee: if the debugging port still answers, the real
            # browser is alive regardless of what happened to the launcher.
            # This is exactly the case that used to leave an arena.ai window
            # behind after --arena-login / --gemini-login.
            deadline = time.time() + 8.0
            while time.time() < deadline and self._port_alive():
                time.sleep(0.5)
            for candidate in (browser_pid, launcher_pid):
                if candidate and self._port_alive():
                    subprocess.run(
                        ["taskkill", "/PID", str(candidate), "/T", "/F"], capture_output=True
                    )
            self._cdp_pid = None
            # Drop the port/pid note only while it still describes this
            # browser; another worker may have adopted and re-written it.
            try:
                note_pid = self._read_note().get("pid")
                if note_pid in (None, browser_pid, launcher_pid):
                    ARENA_INFO_FILE.unlink(missing_ok=True)
            except Exception:
                pass

    # -- DevTools plumbing --------------------------------------------------

    def _cdp_call(self, method: str, params: dict | None = None, timeout: float = 60.0) -> dict:
        if self._ws is None:
            raise ArenaError("Chrome DevTools is not connected")
        self._next_id += 1
        request_id = self._next_id
        self._ws.send(json.dumps({"id": request_id, "method": method, "params": params or {}}))
        deadline = time.time() + timeout
        while True:
            remaining = deadline - time.time()
            if remaining <= 0:
                raise ArenaError(f"Chrome DevTools {method} timed out")
            self._ws.settimeout(max(1.0, remaining))
            try:
                message = json.loads(self._ws.recv())
            except Exception as exc:
                raise ArenaError(f"Chrome DevTools connection lost: {exc}") from exc
            if message.get("id") != request_id:
                continue
            if "error" in message:
                raise ArenaError(f"Chrome DevTools {method}: {message['error']}")
            return message.get("result") or {}

    def _evaluate(self, expression: str, await_promise: bool = False, timeout: float = 90.0):
        result = self._cdp_call(
            "Runtime.evaluate",
            {"expression": expression, "awaitPromise": await_promise, "returnByValue": True},
            timeout=timeout,
        )
        details = result.get("exceptionDetails")
        if details:
            raise ArenaError(f"arena.ai page script failed: {json.dumps(details)[:200]}")
        return (result.get("result") or {}).get("value")

    def _evaluate_soft(self, expression: str):
        """Evaluate and swallow failures: during a navigation the old context
        disappears and the next poll succeeds."""
        try:
            return self._evaluate(expression)
        except ArenaError:
            return None

    def _guarded(self, action):
        """Run action() under the lock, restarting Chrome once if the parked
        tab died since the last request (a crash, a cleaner, a reboot)."""
        with self._lock:
            try:
                self._ensure_connected()
                if self._window_hidden:
                    # Chrome can re-create or re-show its HWND on its own (a
                    # profile bubble, a crash recovery). Keep the promise: no
                    # taskbar button while the browser is meant to be parked.
                    self._apply_window_style(hidden=True)
                return action()
            except ArenaLoginRequired:
                raise
            except ArenaError:
                log.warning("arena: DevTools hiccup; restarting the parked Chrome once", exc_info=True)
                self.reset()
                self._ensure_connected()
                return action()

    # -- window cosmetics ---------------------------------------------------

    _GWL_EXSTYLE = -20
    _WS_EX_TOOLWINDOW = 0x80
    _WS_EX_APPWINDOW = 0x40000

    def _start_window_watchdog(self) -> None:
        """Keep arena.ai's helper Chrome off the taskbar for the whole run.

        Styling the window once at launch is not enough: Chrome re-creates and
        re-shows top-level windows on its own (sign-in popups, "restore pages",
        account prompts), and those arrive a second later with a taskbar button.
        A small daemon re-applies the same style every couple of seconds, so a
        newly created window is parked before the player notices it. It uses the
        cached browser PID only — never the DevTools websocket — so it cannot
        interleave a CDP call with an in-flight chat request.
        """
        if sys.platform != "win32" or self._window_watchdog is not None:
            return

        def watch() -> None:
            while True:
                # Chrome can create and show a popup ("restore pages", an
                # account prompt) in well under a second. Re-style four times
                # per second so even a fast window never keeps a taskbar button.
                time.sleep(0.25)
                try:
                    pid = self._window_pid()
                    if not pid:
                        continue
                    self._apply_window_style(hidden=self._window_hidden, pid=pid)
                except Exception:
                    log.debug("arena: window watchdog pass failed", exc_info=True)

        self._window_watchdog = threading.Thread(
            target=watch, name="arena-window-watchdog", daemon=True
        )
        self._window_watchdog.start()

    def _window_pid(self) -> int | None:
        """The PID that actually owns Chrome's window.

        A second launch with the same profile is handed to the already-running
        browser, so the process WE started can exit immediately and the saved
        PID can point at nothing. The owner of the DevTools listening socket is
        always the real browser, so ask the OS first; CDP and the launch PID are
        fallbacks only.
        """
        port = self._cdp_port
        if port and sys.platform == "win32":
            try:
                output = subprocess.run(
                    ["netstat", "-ano", "-p", "tcp"],
                    capture_output=True, text=True, timeout=5.0,
                    creationflags=getattr(subprocess, "CREATE_NO_WINDOW", 0),
                ).stdout
                # netstat prints both the browser's LISTENING socket and our own
                # ESTABLISHED WebSocket connection on the same port. Taking the
                # first line that merely contains ":port" can return THIS worker's
                # PID, so the watchdog styles nothing and Chrome keeps its taskbar
                # button. Only the LISTENING row identifies the real browser.
                for line in output.splitlines():
                    parts = line.split()
                    if len(parts) < 5 or parts[-2] != "LISTENING":
                        continue
                    if not parts[1].endswith(f":{port}"):
                        continue
                    candidate = parts[-1]
                    if candidate.isdigit() and int(candidate) > 0:
                        self._window_pid_cache = int(candidate)
                        return self._window_pid_cache
            except Exception:
                pass
        if self._window_pid_cache is not None:
            return self._window_pid_cache
        try:
            info = self._cdp_call("SystemInfo.getProcessInfo", timeout=5.0)
            for process in info.get("processInfo") or []:
                if str(process.get("type")) == "browser" and isinstance(process.get("id"), int):
                    self._window_pid_cache = int(process["id"])
                    return self._window_pid_cache
        except Exception:
            pass
        return self._cdp_pid

    def _apply_window_style(self, hidden: bool, pid: int | None = None) -> int:
        """Park the Chrome window off-screen, or bring it on-screen for a
        human check - but never give it a taskbar button in either state.

        Windows gives a taskbar button to any visible, unowned top-level
        window unless it is a tool window. Chrome keeps several of those:
        the browser, a "restore pages" bubble, sign-in dialogs, and popup
        windows created after the first paint. So this styles EVERY top-level
        window owned by the real browser process, including ones still hidden,
        instead of only the one window that existed at launch. WS_EX_TOOLWINDOW
        stays set in both states and WS_EX_APPWINDOW is always cleared; only the
        position changes. Returns the number of windows adjusted.
        """
        self._window_hidden = hidden
        if sys.platform != "win32":
            return 0
        target_pid = pid if pid is not None else self._window_pid()
        if not target_pid:
            return 0
        try:
            import ctypes
            from ctypes import wintypes

            user32 = ctypes.windll.user32
            long_ptr = ctypes.c_ssize_t if ctypes.sizeof(ctypes.c_void_p) == 8 else wintypes.LONG

            get_long = getattr(user32, "GetWindowLongPtrW", None) or user32.GetWindowLongW
            get_long.argtypes = [wintypes.HWND, ctypes.c_int]
            get_long.restype = long_ptr
            set_long = getattr(user32, "SetWindowLongPtrW", None) or user32.SetWindowLongW
            set_long.argtypes = [wintypes.HWND, ctypes.c_int, long_ptr]
            set_long.restype = long_ptr
            user32.GetWindow.argtypes = [wintypes.HWND, ctypes.c_int]
            user32.GetWindow.restype = wintypes.HWND
            user32.IsWindowVisible.argtypes = [wintypes.HWND]
            user32.GetWindowThreadProcessId.argtypes = [wintypes.HWND, ctypes.POINTER(wintypes.DWORD)]
            user32.MoveWindow.argtypes = [
                wintypes.HWND, ctypes.c_int, ctypes.c_int, ctypes.c_int, ctypes.c_int, wintypes.BOOL
            ]
            user32.ShowWindow.argtypes = [wintypes.HWND, ctypes.c_int]
            user32.BringWindowToTop.argtypes = [wintypes.HWND]
            user32.SetForegroundWindow.argtypes = [wintypes.HWND]
            user32.SetWindowPos.argtypes = [
                wintypes.HWND, wintypes.HWND, ctypes.c_int, ctypes.c_int,
                ctypes.c_int, ctypes.c_int, wintypes.UINT,
            ]

            hwnds: list = []

            @ctypes.WINFUNCTYPE(wintypes.BOOL, wintypes.HWND, wintypes.LPARAM)
            def on_window(hwnd, _lparam):
                # Do not skip hidden or owned windows. A window that is invisible
                # now can be shown a moment later with a taskbar button already
                # attached, and an owned dialog can be promoted to a top-level
                # window by Chrome. Styling them all keeps every case covered.
                window_pid = wintypes.DWORD()
                user32.GetWindowThreadProcessId(hwnd, ctypes.byref(window_pid))
                if window_pid.value == target_pid:
                    hwnds.append(hwnd)
                return True

            user32.EnumWindows(on_window, 0)
            for hwnd in hwnds:
                style = get_long(hwnd, self._GWL_EXSTYLE)
                wanted = (style | self._WS_EX_TOOLWINDOW) & ~self._WS_EX_APPWINDOW
                if wanted != style:
                    set_long(hwnd, self._GWL_EXSTYLE, wanted)
                if hidden:
                    user32.MoveWindow(hwnd, -32000, -32000, 1100, 800, True)
                else:
                    user32.MoveWindow(hwnd, 120, 80, 1100, 800, True)
                    user32.ShowWindow(hwnd, 9)  # SW_RESTORE
                    user32.BringWindowToTop(hwnd)
                    user32.SetForegroundWindow(hwnd)
                # MoveWindow alone does not make Explorer drop the taskbar
                # button; SWP_FRAMECHANGED applies the new style at once.
                user32.SetWindowPos(
                    hwnd, 0, 0, 0, 0, 0,
                    0x0001 | 0x0002 | 0x0004 | 0x0010 | 0x0020,
                    # NOSIZE | NOMOVE | NOZORDER | NOACTIVATE | FRAMECHANGED
                )
            return len(hwnds)
        except Exception:
            log.debug("arena: could not adjust the Chrome window style", exc_info=True)
            return 0

    # -- tryingopen.ai browser page ----------------------------------------

    def _trying_call(self, method: str, params: dict | None = None, timeout: float = 60.0) -> dict:
        if self._trying_ws is None:
            raise ArenaError("the TryingOpen browser tab is not connected")
        self._trying_next_id += 1
        request_id = self._trying_next_id
        self._trying_ws.send(json.dumps({"id": request_id, "method": method, "params": params or {}}))
        deadline = time.time() + timeout
        while True:
            remaining = deadline - time.time()
            if remaining <= 0:
                raise ArenaError(f"TryingOpen page DevTools {method} timed out")
            self._trying_ws.settimeout(max(1.0, remaining))
            try:
                message = json.loads(self._trying_ws.recv())
            except Exception as exc:
                raise ArenaError(f"TryingOpen page DevTools connection lost: {exc}") from exc
            if message.get("id") != request_id:
                continue
            if "error" in message:
                raise ArenaError(f"TryingOpen page DevTools {method}: {message['error']}")
            return message.get("result") or {}

    def _trying_eval(self, expression: str, await_promise: bool = False, timeout: float = 90.0):
        result = self._trying_call(
            "Runtime.evaluate",
            {"expression": expression, "awaitPromise": await_promise, "returnByValue": True},
            timeout=timeout,
        )
        details = result.get("exceptionDetails")
        if details:
            raise ArenaError("TryingOpen page script failed: " + json.dumps(details)[:200])
        return (result.get("result") or {}).get("value")

    def _ensure_trying_page(self) -> None:
        """Open (or reuse) a TryingOpen tab in the parked Chrome.

        The site's own fetch wrapper mints the Kasada x-is-human token that
        /api/open requires. We must therefore run the request inside that page:
        the same token replayed from curl/httpx is still rejected with 403.
        """
        self._ensure_connected()
        port = self._cdp_port
        if port is None:
            raise ArenaError("the parked Chrome has no DevTools port")

        def find_target() -> dict | None:
            try:
                with urllib.request.urlopen(f"http://127.0.0.1:{port}/json", timeout=3.0) as response:
                    targets = json.loads(response.read().decode("utf-8"))
            except Exception:
                return None
            for target in targets:
                if target.get("type") == "page" and "tryingopen.com" in str(target.get("url") or ""):
                    return target
            return None

        target = find_target()
        if target is None:
            url = f"http://127.0.0.1:{port}/json/new?{urllib.parse.quote(TRYINGOPEN_PAGE, safe='')}"
            try:
                request = urllib.request.Request(url, method="PUT")
                with urllib.request.urlopen(request, timeout=10.0):
                    pass
            except Exception as exc:
                raise ArenaError("could not open a TryingOpen tab: " + str(exc)[:160]) from exc
            deadline = time.time() + 30.0
            while time.time() < deadline:
                target = find_target()
                if target is not None:
                    break
                time.sleep(0.4)
        if target is None:
            raise ArenaError("the TryingOpen tab did not open")

        ws_url = str(target.get("webSocketDebuggerUrl") or "")
        if not ws_url:
            raise ArenaError("the TryingOpen tab has no DevTools socket")
        if self._trying_ws is None or self._trying_ws_url != ws_url:
            try:
                import websocket
            except ImportError as exc:
                raise ArenaError("TryingOpen needs 'websocket-client'; rerun StartFreeChat.bat") from exc
            if self._trying_ws is not None:
                try:
                    self._trying_ws.close()
                except Exception:
                    pass
            self._trying_ws = websocket.create_connection(ws_url, timeout=120)
            self._trying_ws_url = ws_url
            self._trying_call("Runtime.enable")

        # The fetch wrapper that installs x-is-human is added by a page script.
        deadline = time.time() + 30.0
        while time.time() < deadline:
            try:
                ready = self._trying_eval(
                    "document.readyState === 'complete' && "
                    "location.hostname === 'www.tryingopen.com' && "
                    "String(window.fetch).indexOf('x-is-human') >= 0 ? 1 : 0"
                )
            except ArenaError:
                ready = None
            if ready == 1:
                return
            time.sleep(0.5)
        raise ArenaError("the TryingOpen page did not install its anti-bot fetch wrapper")

    def tryingopen_stream(self, payload: dict) -> list[dict]:
        """POST /api/open from inside the site page and return its SSE events."""
        expression = """
(async () => {
  const r = await fetch('/api/open', {
    method: 'POST',
    headers: {'Content-Type': 'application/json', 'Accept': 'text/event-stream'},
    body: JSON.stringify(%s)
  });
  if (!r.ok) return 'ERR' + r.status + ':' + (await r.text()).slice(0, 300);
  const reader = r.body.getReader();
  const decoder = new TextDecoder();
  let text = '';
  for (;;) {
    const part = await reader.read();
    if (part.done) break;
    text += decoder.decode(part.value, {stream: true});
  }
  text += decoder.decode();
  const frames = [];
  for (const line of text.split(/\r?\n/)) {
    if (line.indexOf('data:') === 0) frames.push(line.slice(5).trim());
  }
  return 'OK' + JSON.stringify(frames);
})()
""" % json.dumps(payload, ensure_ascii=False)

        def action() -> list[dict]:
            self._ensure_trying_page()
            raw = self._trying_eval(expression, await_promise=True, timeout=200.0)
            if not isinstance(raw, str) or not raw.startswith("OK"):
                raise ArenaError(str(raw)[:300] if raw is not None else "empty TryingOpen page response")
            events = []
            for frame in json.loads(raw[2:]):
                if not frame or frame == "[DONE]":
                    continue
                try:
                    events.append(json.loads(frame))
                except (TypeError, ValueError):
                    log.debug("ignoring non-JSON tryingopen frame: %s", frame[:120])
            return events

        return self._guarded(action)

    # -- gemini.google.com browser page ------------------------------------

    def _gemini_call(self, method: str, params: dict | None = None, timeout: float = 60.0) -> dict:
        if self._gemini_ws is None:
            raise ArenaError("the Gemini browser tab is not connected")
        self._gemini_next_id += 1
        request_id = self._gemini_next_id
        self._gemini_ws.send(json.dumps({"id": request_id, "method": method, "params": params or {}}))
        deadline = time.time() + timeout
        while True:
            remaining = deadline - time.time()
            if remaining <= 0:
                raise ArenaError(f"Gemini page DevTools {method} timed out")
            self._gemini_ws.settimeout(max(1.0, remaining))
            try:
                message = json.loads(self._gemini_ws.recv())
            except Exception as exc:
                raise ArenaError(f"Gemini page DevTools connection lost: {exc}") from exc
            if message.get("id") != request_id:
                continue
            if "error" in message:
                raise ArenaError(f"Gemini page DevTools {method}: {message['error']}")
            return message.get("result") or {}

    def _gemini_eval(self, expression: str, await_promise: bool = False, timeout: float = 90.0):
        result = self._gemini_call(
            "Runtime.evaluate",
            {"expression": expression, "awaitPromise": await_promise, "returnByValue": True},
            timeout=timeout,
        )
        details = result.get("exceptionDetails")
        if details:
            raise ArenaError("Gemini page script failed: " + json.dumps(details)[:200])
        return (result.get("result") or {}).get("value")

    def _gemini_tokens(self) -> dict[str, str]:
        expression = """
(() => {
  const wiz = window.WIZ_global_data || {};
  const pick = (name) => {
    const value = window[name] !== undefined ? window[name] : wiz[name];
    return typeof value === 'string' ? value : '';
  };
  return {at: pick('SNlM0e'), bl: pick('cfb2h'), sid: pick('FdrFJe'),
          lang: pick('TuX5cc') || 'en', url: location.href};
})()
"""
        value = self._gemini_eval(expression)
        return value if isinstance(value, dict) else {}

    def _ensure_gemini_page(self, require_tokens: bool = True, timeout: float = 30.0) -> dict[str, str]:
        """Reuse (or open) a signed-in Gemini tab in the parked Chrome."""
        self._ensure_connected()
        port = self._cdp_port
        if port is None:
            raise ArenaError("the parked Chrome has no DevTools port")

        def find_target() -> dict | None:
            try:
                with urllib.request.urlopen(f"http://127.0.0.1:{port}/json", timeout=3.0) as response:
                    targets = json.loads(response.read().decode("utf-8"))
            except Exception:
                return None
            for target in targets:
                if target.get("type") == "page" and "gemini.google.com" in str(target.get("url") or ""):
                    return target
            return None

        target = find_target()
        if target is None:
            url = f"http://127.0.0.1:{port}/json/new?{urllib.parse.quote(GEMINI_PAGE, safe='')}"
            try:
                with urllib.request.urlopen(urllib.request.Request(url, method="PUT"), timeout=10.0):
                    pass
            except Exception as exc:
                raise ArenaError("could not open a Gemini tab: " + str(exc)[:160]) from exc
            deadline = time.time() + 30.0
            while time.time() < deadline:
                target = find_target()
                if target is not None:
                    break
                time.sleep(0.4)
        if target is None:
            raise ArenaError("the Gemini tab did not open")

        ws_url = str(target.get("webSocketDebuggerUrl") or "")
        if not ws_url:
            raise ArenaError("the Gemini tab has no DevTools socket")
        if self._gemini_ws is None or self._gemini_ws_url != ws_url:
            try:
                import websocket
            except ImportError as exc:
                raise ArenaError("Gemini needs 'websocket-client'; rerun StartFreeChat.bat") from exc
            if self._gemini_ws is not None:
                try:
                    self._gemini_ws.close()
                except Exception:
                    pass
            self._gemini_ws = websocket.create_connection(ws_url, timeout=120)
            self._gemini_ws_url = ws_url
            self._gemini_call("Runtime.enable")

        deadline = time.time() + timeout
        while True:
            try:
                tokens = self._gemini_tokens()
            except ArenaError:
                tokens = {}
            if tokens.get("at") and tokens.get("bl") and tokens.get("sid"):
                if not GEMINI_SESSION_FILE.exists():
                    try:
                        GEMINI_SESSION_FILE.write_text(
                            json.dumps(
                                {"captured_at": time.time(), "url": tokens.get("url", "")},
                                indent=2,
                            ),
                            encoding="utf-8",
                        )
                    except Exception:
                        log.debug("could not write %s", GEMINI_SESSION_FILE, exc_info=True)
                return tokens
            if not require_tokens:
                return tokens
            if time.time() >= deadline:
                raise GeminiLoginRequired(
                    "gemini.google.com has no signed-in session on this PC. "
                    "Run the chat relay once with --gemini-login and sign in to Google, "
                    "then enable the Gemini provider."
                )
            time.sleep(0.5)

    def gemini_stream(
        self,
        prompt: str,
        model_spec: tuple[str, str, int, int],
        collect_images: bool = False,
    ) -> list[dict]:
        """POST through the Gemini page and return text/reasoning deltas.

        With ``collect_images`` the image card Gemini adds to its answer is
        returned as ``{"type": "image", "delta": <url>}`` instead of being
        flattened into text. The local image worker uses that to draw a chat
        background from the player's own signed-in Gemini tab.
        """
        model_name, model_id, model_number, capacity = model_spec
        tokens = self._ensure_gemini_page()
        request_id = int(time.time() * 1000) % 100000

        inner: list[Any] = [None] * 81
        inner[0] = [prompt, 0, None, None, None, None, 0]
        inner[1] = [tokens.get("lang") or "en"]
        inner[2] = ["", "", "", None, None, None, None, None, None, ""]
        inner[6] = [1]
        inner[7] = 1  # stream
        inner[10] = 1
        inner[11] = 0
        inner[17] = [[0]]
        inner[18] = 0
        inner[27] = 1
        inner[30] = [4]
        inner[41] = [1]
        inner[45] = 1  # temporary chat: no provider-side history to drift
        inner[53] = 0
        inner[61] = []
        inner[68] = 1
        inner[79] = model_number
        inner[80] = 1
        uuid_val = str(uuid.uuid4()).upper()
        inner[59] = uuid_val

        headers = {
            "Content-Type": "application/x-www-form-urlencoded;charset=utf-8",
            "Origin": "https://gemini.google.com",
            "Referer": "https://gemini.google.com/",
            "X-Same-Domain": "1",
            "x-goog-ext-525001261-jspb": json.dumps(
                [1, None, None, None, model_id, None, None, 0, [4, 5, 6, 8],
                 None, None, capacity, None, None, model_number],
                separators=(",", ":"),
            ),
            "x-goog-ext-73010989-jspb": "[0]",
            "x-goog-ext-73010990-jspb": "[0,0,0]",
            "x-goog-ext-525005358-jspb": json.dumps([uuid_val, 1], separators=(",", ":")),
        }
        query = urllib.parse.urlencode({
            "bl": tokens["bl"], "f.sid": tokens["sid"], "hl": tokens.get("lang") or "en",
            "_reqid": request_id, "rt": "c",
        })
        form = {
            "at": tokens["at"],
            "f.req": json.dumps([None, json.dumps(inner, separators=(",", ":"))],
                                separators=(",", ":")),
        }

        expression = """
(async () => {
  const endpoint = %s + '?' + %s;
  const response = await fetch(endpoint, {
    method: 'POST',
    credentials: 'same-origin',
    headers: %s,
    body: new URLSearchParams(%s).toString()
  });
  const text = await response.text();
  if (response.url.indexOf('/sorry/') >= 0 || response.url.indexOf('accounts.google.com') >= 0) {
    return 'ERRBLOCK:' + response.url;
  }
  if (!response.ok) return 'ERR' + response.status + ':' + text.slice(0, 500);
  return 'OK' + JSON.stringify({text: text, url: response.url});
})()
""" % (
            json.dumps("https://gemini.google.com/_/BardChatUi/data/assistant.lamda.BardFrontendService/StreamGenerate"),
            json.dumps(query),
            json.dumps(headers),
            json.dumps(form, ensure_ascii=False),
        )

        def action() -> list[dict]:
            raw = self._gemini_eval(expression, await_promise=True, timeout=240.0)
            if isinstance(raw, str) and raw.startswith("ERRBLOCK:"):
                raise GeminiLoginRequired(
                    "gemini.google.com blocked this session or IP with a CAPTCHA page (captcha): "
                    + raw[9:][:160]
                )
            if isinstance(raw, str) and raw.startswith("ERR"):
                raise ArenaError("gemini.google " + raw[:400])
            if not isinstance(raw, str) or not raw.startswith("OK"):
                raise ArenaError(str(raw)[:300] if raw is not None else "empty Gemini page response")
            payload = json.loads(raw[2:])
            frames = _parse_gemini_frames(payload.get("text") or "")
            if not frames:
                raise ArenaError("gemini.google returned no readable stream frames")

            deltas: list[dict] = []
            images: list[str] = []
            last_text = ""
            last_thought = ""
            for frame in frames:
                error_code = _nested(frame, [5, 2, 0, 1, 0])
                if error_code:
                    code = str(error_code)
                    messages = {
                        "1037": "gemini.google rate limit / quota exceeded",
                        "1016": "gemini.google login expired - run --gemini-login again",
                        "1060": "gemini.google CAPTCHA / IP block",
                        "1052": "gemini.google model header is stale - reload the tab",
                        "1050": "gemini.google model inconsistent with session",
                        "1013": "gemini.google temporary error 1013",
                    }
                    raise ArenaError(messages.get(code, f"gemini.google error code {code}"))
                inner_json = _nested(frame, [2])
                if not isinstance(inner_json, str):
                    continue
                try:
                    body = json.loads(inner_json)
                except ValueError:
                    continue
                for candidate in _nested(body, [4], []) or []:
                    text = str(_nested(candidate, [1, 0], "") or "")
                    image_url = str(_nested(candidate, [22, 0], "") or "")
                    looks_like_image = (
                        text.startswith("data:image/")
                        or "googleusercontent.com" in text[:120]
                        or image_url.startswith("data:image/")
                        or "googleusercontent.com" in image_url[:200]
                    )
                    if collect_images and looks_like_image and image_url:
                        if image_url not in images:
                            images.append(image_url)
                        continue
                    if looks_like_image and image_url:
                        text = image_url
                    thought = str(_nested(candidate, [37, 0, 0], "") or "")
                    if thought and thought != last_thought:
                        deltas.append({"type": "reasoning", "delta": thought[len(last_thought):]})
                        last_thought = thought
                    if text and text != last_text:
                        deltas.append({"type": "text", "delta": text[len(last_text):]})
                        last_text = text
            if collect_images and images:
                return [{"type": "image", "delta": url} for url in images]
            if not last_text and not last_thought:
                raise ArenaError(
                    f"gemini.google returned no text for {model_name}. "
                    "The model may not be available on this Google account."
                )
            return deltas

        return self._guarded(action)

    # -- arena.ai state -----------------------------------------------------

    def _ensure_page_ready(self) -> None:
        """The tab must sit on arena.ai with its reCAPTCHA script fully
        loaded. The enterprise script first installs a stub whose
        <c>execute</c> only becomes a function once the real API arrives, so
        a truthiness check is not enough - minting against the stub is
        exactly the failure this guard prevents."""
        hostname = self._evaluate("location.hostname")
        if hostname != ARENA_HOSTNAME:
            self._evaluate(f"location.href = {json.dumps(ARENA_BASE + '/')}")
        deadline = time.time() + 45
        while time.time() < deadline:
            if self._evaluate_soft(
                "(typeof grecaptcha !== 'undefined' && grecaptcha.enterprise"
                " && typeof grecaptcha.enterprise.execute === 'function') ? 1 : 0"
            ) == 1:
                return
            time.sleep(1.0)
        raise ArenaError("arena.ai did not finish loading its reCAPTCHA script")

    def mint_token(self, action: str = "chat_submit") -> str:
        """A fresh reCAPTCHA Enterprise token from the parked arena.ai tab.
        The token embeds arena.ai's hostname, which is the whole reason the
        tab exists - it cannot be minted anywhere else."""

        def run() -> str:
            self._ensure_page_ready()
            expression = (
                "grecaptcha.enterprise.execute(%s, {action: %s})"
                ".then(function (t) { return 'OK' + t; })"
                ".catch(function (e) { return 'ERR' + String(e); })"
                % (json.dumps(ARENA_RECAPTCHA_KEY), json.dumps(action))
            )
            value = self._evaluate(expression, await_promise=True, timeout=120.0)
            if isinstance(value, str) and value.startswith("OK") and len(value) > 10:
                return value[2:]
            raise ArenaError(f"arena.ai did not produce a reCAPTCHA token: {str(value)[:200]}")

        return self._guarded(run)

    def _raw_cookies(self) -> dict[str, str]:
        result = self._cdp_call("Network.getAllCookies", timeout=30.0)
        cookies: dict[str, str] = {}
        now = time.time()
        for cookie in result.get("cookies") or []:
            name = str(cookie.get("name") or "")
            value = cookie.get("value")
            if not name.startswith(ARENA_COOKIE_PREFIX) or value is None:
                continue
            domain = str(cookie.get("domain") or "").lstrip(".")
            if not domain.endswith(ARENA_HOSTNAME):
                continue
            expires = cookie.get("expires") or 0
            try:
                if float(expires) and float(expires) < now:
                    continue
            except (TypeError, ValueError):
                pass
            cookies[name] = str(value)
        return cookies

    def cookies(self) -> dict[str, str]:
        """The arena.ai session cookies from the live profile. Raises
        <see cref="ArenaLoginRequired"/> when nobody is signed in."""

        def run() -> dict[str, str]:
            cookies = self._raw_cookies()
            if not any(name.startswith(ARENA_COOKIE_PREFIX) for name in cookies):
                raise ArenaLoginRequired(
                    "arena.ai has no saved sign-in on this PC. Run StartFreeChat.bat again "
                    "and sign in when its browser window opens."
                )
            return cookies

        return self._guarded(run)

    def inject_cookies(self, set_cookie_headers: list[str], now: float) -> None:
        """Write arena-auth cookies from raw Set-Cookie headers into the very
        profile the cookies are read from (Network.setCookie)."""

        def run() -> None:
            for header in set_cookie_headers:
                parts = [p.strip() for p in header.split(";")]
                if not parts or "=" not in parts[0]:
                    continue
                name, _, value = parts[0].partition("=")
                name, value = name.strip(), value.strip()
                if not name.startswith(ARENA_COOKIE_PREFIX):
                    continue
                params: dict[str, Any] = {"name": name, "value": value, "domain": ARENA_HOSTNAME, "path": "/"}
                delete = not value
                for attribute in parts[1:]:
                    key, _, raw = attribute.partition("=")
                    key, raw = key.strip().lower(), raw.strip()
                    if key == "max-age":
                        if raw.isdigit() and int(raw) > 0:
                            params["expires"] = now + float(raw)
                        else:
                            delete = True
                    elif key == "path":
                        params["path"] = raw or "/"
                    elif key == "domain":
                        params["domain"] = raw.lstrip(".") or ARENA_HOSTNAME
                    elif key == "samesite":
                        if raw.lower() in ("strict", "lax", "none"):
                            params["sameSite"] = raw[0].upper() + raw[1:].lower()
                    elif key == "secure":
                        params["secure"] = True
                    elif key == "httponly":
                        params["httpOnly"] = True
                if delete:
                    self._cdp_call("Network.deleteCookies", {"name": name, "domain": params["domain"]}, timeout=15.0)
                else:
                    self._cdp_call("Network.setCookie", params, timeout=15.0)

        self._guarded(run)

    def user_agent(self) -> str:
        if self._user_agent:
            return self._user_agent

        def run() -> str:
            value = self._evaluate_soft("navigator.userAgent") or USER_AGENT
            self._user_agent = str(value)
            return self._user_agent

        return self._guarded(run)

    def model_id(self) -> str:
        """Max's model id, from the live catalog when reachable (cached for a
        day); the built-in id is the fallback."""
        now = time.time()
        if self._model_id and now - self._model_id_at < 24 * 3600:
            return self._model_id
        model_id = ARENA_DEFAULT_MODEL_ID
        try:
            response = httpx.get(
                f"{ARENA_BASE}{ARENA_CATALOG_PATH}",
                headers={"User-Agent": self.user_agent()},
                timeout=20.0,
            )
            if response.status_code == 200:
                for group in response.json():
                    if not isinstance(group, dict) or str(group.get("arena") or "") != "text":
                        continue
                    for entry in group.get("models") or []:
                        if isinstance(entry, dict) and str(entry.get("publicName") or "").strip().lower() == "max":
                            found = str(entry.get("id") or "").strip()
                            if found:
                                model_id = found
                                break
        except Exception as exc:
            log.debug("arena: catalog lookup failed (%s); using the built-in Max id", exc)
        self._model_id = model_id
        self._model_id_at = now
        return model_id

    def refresh_model_id(self) -> str:
        self._model_id = None
        self._model_id_at = 0.0
        return self.model_id()

    # -- the two player-visible moments ------------------------------------

    def login(self, keep_running: bool = False, timeout: float = 300.0) -> dict[str, str]:
        """Open arena.ai visibly and wait for the sign-in. Used once by the
        setup script and, rarely, mid-game when the session truly died. The
        session itself lives on in the browser profile; arena-session.json is
        only a receipt that this PC has signed in."""
        with self._lock:
            self.stop()  # a parked hidden instance restarts visibly
            self._launch(visible=True)
            try:
                print("Sign in to arena.ai in the browser window (Google or email works). Waiting up to 5 minutes...")
                deadline = time.time() + timeout
                cookies: dict[str, str] = {}
                while time.time() < deadline:
                    try:
                        if self._ws is None:
                            self._ensure_connected()
                        cookies = self._raw_cookies()
                    except ArenaError:
                        cookies = {}
                    if any(name.startswith(ARENA_COOKIE_PREFIX) for name in cookies):
                        break
                    time.sleep(3.0)
                if not any(name.startswith(ARENA_COOKIE_PREFIX) for name in cookies):
                    raise ArenaError("arena.ai sign-in timed out; no session cookie was captured")
                self._user_agent = str(self._evaluate_soft("navigator.userAgent") or USER_AGENT)
                try:
                    ARENA_SESSION_FILE.write_text(
                        json.dumps(
                            {"cookies": cookies, "user_agent": self._user_agent, "captured_at": time.time()},
                            indent=2,
                        ),
                        encoding="utf-8",
                    )
                except Exception:
                    log.debug("could not write %s", ARENA_SESSION_FILE, exc_info=True)
                print(f"Saved arena.ai session to {ARENA_SESSION_FILE}")
                return cookies
            finally:
                # A timeout, a closed window or an exception must NOT strand the
                # visible Chrome with a taskbar button. This is the path that
                # used to leave the player closing the arena window by hand.
                if keep_running:
                    self._apply_window_style(hidden=True)
                else:
                    self.stop()

    def solve_v2(self, timeout: float = 180.0) -> str:
        """arena.ai's own reCAPTCHA v2 fallback: show the parked window with
        a small overlay and wait for the player to tick the checkbox. Holds
        the browser lock while waiting, so parallel requests queue instead of
        fighting over the same captcha."""
        with self._lock:
            self._ensure_connected()
            self._ensure_page_ready()
            self._apply_window_style(hidden=False)
            try:
                self._evaluate(_ARENA_V2_WIDGET_JS)
                print("arena.ai wants a human check: tick the checkbox in the browser window to continue.")
                deadline = time.time() + timeout
                while time.time() < deadline:
                    token = self._evaluate_soft("window.__aamV2Token || ''")
                    if token:
                        return str(token)
                    time.sleep(1.0)
                raise ArenaError(
                    "The arena.ai human check was not solved in time. Switch to the browser window, "
                    "tick the checkbox, then send your message again."
                )
            finally:
                self._evaluate_soft(
                    "(() => { const d = document.getElementById('aam-recaptcha-overlay'); if (d) d.remove(); })()"
                )
                self._apply_window_style(hidden=True)


atexit.register(ArenaBrowser.stop_instance)


def _arena_cookie_header(cookies: dict[str, str]) -> str:
    def sort_key(name: str):
        head, _, tail = name.rpartition(".")
        try:
            return (head or name, int(tail))
        except ValueError:
            return (name, -1)

    return "; ".join(f"{name}={cookies[name]}" for name in sorted(cookies, key=sort_key))


_ARENA_PACE_LOCK = threading.Lock()
_ARENA_REQUEST_TIMES: list[float] = []


def _arena_pace() -> None:
    """Keep arena.ai's per-account budget (~30 messages per 5 minutes) from
    running dry mid-story: space requests a little, and stop with a clear
    message once this PC has used its window, instead of letting the server
    cut a generation off with a 429."""
    with _ARENA_PACE_LOCK:
        now = time.time()
        times = [t for t in _ARENA_REQUEST_TIMES if now - t < ARENA_WINDOW_SECONDS]
        if times and now - times[-1] < ARENA_MIN_INTERVAL:
            time.sleep(ARENA_MIN_INTERVAL - (now - times[-1]))
            now = time.time()
            times = [t for t in _ARENA_REQUEST_TIMES if now - t < ARENA_WINDOW_SECONDS]
        if len(times) >= ARENA_WINDOW_MAX:
            raise ArenaError(
                "arena.ai's per-account limit (about 30 messages per 5 minutes) is used up on "
                "this PC right now. Wait a few minutes or pick a different model in the game."
            )
        times.append(now)
        _ARENA_REQUEST_TIMES[:] = times


def _arena_cx(prompt_len: int) -> str:
    """A plausible composer fingerprint for a message of the given length:
    keyboard submit, no pastes, a bit of typing proportional to the prompt."""
    interaction = {
        "submitKind": "enter",
        "submitTrusted": True,
        "untrustedUiEvents": 0,
        "charsTyped": min(prompt_len, 220),
        "insertMulti": 3 if prompt_len > 120 else 0,
        "pasteCount": 0,
        "pasteWithoutModifier": False,
        "composition": False,
        "otherInputTypes": 0,
        "docOwnProps": [],
        "coarsePointer": False,
        "integrity": 0,
        "pressBucket": "lt50",
        "pressureBucket": "none",
        "movesBeforeClick": "gt15",
        "maxCoalesced": "2to4",
        "heartbeatGapBucket": "lt10s",
        "visibilityChangesBucket": "1to3",
        "focusVisContradiction": False,
        "visitTag": int.from_bytes(uuid.uuid4().bytes[:2], "big"),
        "minuteTag": int(time.time() * 1000 / 60000) & 0xFFFF,
    }
    return _cx_encode(interaction, int.from_bytes(uuid.uuid4().bytes[:2], "big"))


def _arena_session_cookies(browser: ArenaBrowser) -> dict[str, str]:
    """Cookies for the request. A background chat/world request must NEVER open
    Chrome by itself: that used to pop a visible arena.ai window in the middle
    of play and leave it sitting in the taskbar when the player ignored it.
    Sign-in is opt-in through the bat's Y prompt (or --arena-login); here a
    missing session is an honest, actionable error instead."""
    try:
        return browser.cookies()
    except ArenaLoginRequired as exc:
        raise ArenaLoginRequired(
            "Arena.ai is not signed in on this PC. Close any leftover Arena "
            "window, run StartImage+Chat.bat again and answer Y to the Arena.ai "
            "sign-in prompt (or start with --arena-login)."
        ) from exc


def _arena_capture_cookies(response, browser: ArenaBrowser) -> None:
    """arena.ai's middleware re-mints the session cookie whenever the access
    token inside has gone stale (verified live: a request carrying an expired
    token still gets HTTP 200 plus a fresh arena-auth Set-Cookie pair). Feed
    those cookies back into the parked browser, so the tab and the relay
    always share one live session and never race each other's refresh-token
    rotation. Best effort: the request itself already succeeded."""
    try:
        headers = response.headers.get_list("set-cookie")
    except Exception:
        return
    fresh = [h for h in headers if h.strip().lower().startswith(ARENA_COOKIE_PREFIX)]
    if not fresh:
        return
    try:
        browser.inject_cookies(fresh, time.time())
    except ArenaError:
        log.debug("arena: could not feed the refreshed cookie back into Chrome", exc_info=True)


def _arena_create(prompt: str, model_id: str, token: str, token_kind: str, cookies: dict[str, str], user_agent: str):
    """POST one direct-battle evaluation; the returned context manager yields
    arena.ai's own stream framing."""
    payload: dict[str, Any] = {
        "id": _arena_uuid7(),
        # direct-battle is what arena.ai's own /chat/direct and /max pages
        # send: one user message, one answering model, no B side.
        "mode": "direct-battle",
        "modelAId": model_id,
        "userMessageId": _arena_uuid7(),
        "modelAMessageId": _arena_uuid7(),
        "userMessage": {"content": prompt},
        "modality": "chat",
        "cx": _arena_cx(len(prompt)),
    }
    payload["recaptchaV3Token" if token_kind == "v3" else "recaptchaV2Token"] = token
    headers = {
        "Content-Type": "application/json",
        "Accept": "text/event-stream",
        "Origin": ARENA_BASE,
        "Referer": f"{ARENA_BASE}/",
        "User-Agent": user_agent,
        "Cookie": _arena_cookie_header(cookies),
    }
    return httpx.stream(
        "POST", f"{ARENA_BASE}{ARENA_CREATE_PATH}", headers=headers, json=payload, timeout=ARENA_TIMEOUT
    )


def _arena_error_text(value: dict) -> str:
    for key in ("message", "errorMessage", "error", "detail"):
        found = value.get(key)
        if isinstance(found, str) and found.strip():
            return found.strip()[:240]
    return json.dumps(value)[:240]


def _arena_stream_once(model, messages, tools, tool_choice):
    """Translate an OpenAI-shaped request into one arena.ai direct-battle
    evaluation and stream its custom framing back as OpenAI chunks.

    Arena's stream is the Vercel AI SDK data-stream protocol prefixed with
    the answering side: ``a0:"text"``, ``ag:"reasoning"``, ``ad:{finish}``,
    ``a2:[data]`` - direct-battle answers on side A only, and no ``data:``
    SSE framing at all."""
    created = int(time.time())
    produced = 0
    try:
        browser = ArenaBrowser.instance()
        browser.ensure()
        prompt = _flatten_prompt(messages, tools, tool_choice)
        model_id = browser.model_id()
        cookies = _arena_session_cookies(browser)
        user_agent = browser.user_agent()

        # Retry ladder, cheapest first: a fresh invisible token, then the
        # visible v2 checkbox (Google doubt), then a real sign-in (a dead
        # session), then the catalog (a rotated Max id). Each runs once.
        v3_retried = False
        v2_attempted = False
        model_retried = False
        v2_token: str | None = None
        while True:
            token = v2_token or browser.mint_token("chat_submit")
            token_kind = "v2" if v2_token else "v3"
            v2_token = None
            _arena_pace()
            with _arena_create(prompt, model_id, token, token_kind, cookies, user_agent) as response:
                if response.status_code != 200:
                    body = response.read().decode("utf-8", "replace")
                    _arena_capture_cookies(response, browser)
                    lowered = body.lower()

                    if response.status_code == 401 or "login_gate" in lowered:
                        # Do not pop a sign-in window in the middle of a chat:
                        # that is how the player ends up with an unmarked extra
                        # Chrome window they never asked for. The shared adapter
                        # cooldown stops the next turn from trying again too.
                        raise ArenaLoginRequired(
                            "arena.ai session expired (LOGIN_GATE). Run StartFreeChat.bat "
                            "once and sign in again; the adapter is paused meanwhile."
                        )

                    if response.status_code == 403 and "recaptcha" in lowered:
                        if not v3_retried:
                            v3_retried = True  # a fresh invisible token first
                            continue
                        if not v2_attempted:
                            v2_attempted = True
                            v2_token = browser.solve_v2()
                            continue
                        raise ArenaError(
                            "arena.ai rejected the captcha twice. Wait a minute, then try again."
                        )

                    if response.status_code == 404 and not model_retried and "not found" in lowered:
                        model_retried = True
                        model_id = browser.refresh_model_id()
                        continue

                    if response.status_code == 429:
                        raise ArenaError(
                            "arena.ai's rate limit for this account is exhausted. Wait a few "
                            "minutes, then try again."
                        )

                    raise ArenaError(f"arena.ai HTTP {response.status_code}: {body[:240]}")

                _arena_capture_cookies(response, browser)
                finish_reason = "stop"
                stream_error = None
                for line in response.iter_lines():
                    raw = str(line)
                    if len(raw) < 3 or raw[2] != ":":
                        continue
                    participant, code = raw[0], raw[1]
                    if participant != "a":
                        continue  # direct-battle answers on side A only
                    try:
                        value = json.loads(raw[3:])
                    except (ValueError, json.JSONDecodeError):
                        continue
                    if code == "0" and isinstance(value, str) and value:
                        produced += 1
                        yield _chunk(created, model, {"content": value})
                    elif code == "g" and isinstance(value, str) and value:
                        yield _chunk(created, model, {"reasoning_content": value})
                    elif code == "d" and isinstance(value, dict):
                        found = str(value.get("finishReason") or "stop")
                        finish_reason = found if found in ("stop", "length") else "stop"
                    elif code == "8" and isinstance(value, dict):
                        stream_error = _arena_error_text(value)

                if stream_error:
                    raise ArenaError(f"arena.ai stopped mid-reply: {stream_error}")
                if produced == 0:
                    raise ArenaError(
                        "arena.ai returned no text for this turn. Try again or pick a different model."
                    )
                yield _chunk(created, model, {}, finish=finish_reason)
                yield "data: [DONE]\n\n"
                return
    except ArenaError as exc:
        log.warning("arena request failed: %s", exc)
        yield _error_event(str(exc))
        yield "data: [DONE]\n\n"
    except httpx.HTTPError as exc:
        log.warning("arena network error: %s", exc)
        yield _error_event(f"arena.ai network error: {str(exc)[:240]}")
        yield "data: [DONE]\n\n"
    except Exception as exc:
        log.exception("arena relay error")
        yield _error_event(f"arena.ai relay error: {str(exc)[:240]}")
        yield "data: [DONE]\n\n"


def _translate_arena(model, messages, tools, tool_choice):
    """Arena with a bounded retry for the edge's TCP reset.

    WinError 10054 / "remote host forcibly closed" is a transient arena.ai edge
    event, but the old code reported it as a permanent provider failure and
    ended the whole world ladder on the first rung. Retry at most twice with a
    short backoff; the fresh token is minted inside every retry. Only a reset
    seen BEFORE any answer text is retried, so a half-streamed reply is never
    duplicated.
    """
    for attempt in range(3):
        frames = []
        reset = False
        produced = False
        for frame in _arena_stream_once(model, messages, tools, tool_choice):
            text = frame if isinstance(frame, str) else ""
            if "10054" in text or "forcibly closed" in text.lower():
                reset = True
                continue
            if '"content"' in text and not text.rstrip().endswith('""'):
                produced = True
            if not reset:
                yield frame
            else:
                frames.append(frame)
        if not reset:
            return
        if produced or attempt == 2:
            for frame in frames:
                yield frame
            return
        log.warning("arena connection reset; retry %d/2", attempt + 1)
        time.sleep(1.0 + attempt)


def _translate_gemini_web(model, messages, tools, tool_choice):
    """Gemini web chat from a signed-in tab, as OpenAI SSE chunks.

    This is deliberately opt-in. Google can change the web protocol or block
    an IP without notice, so it is a fallback, never the only provider.
    """
    created = int(time.time())
    spec = _gemini_model_spec(model)
    prompt = _flatten_prompt(messages, tools, tool_choice)
    if not GEMINI_SESSION_FILE.exists():
        # Same fast-fail as DeepSeek: do not launch Chrome just to discover an
        # absent Google login, and do not spend a ladder attempt on a 30s wait.
        yield _error_event(
            "gemini.google login required: this PC has no saved Google sign-in. "
            "Run python local-chat-worker.py --gemini-login once, then retry."
        )
        yield "data: [DONE]\n\n"
        return
    try:
        deltas = ArenaBrowser.instance().gemini_stream(prompt, spec)
    except Exception as exc:
        log.warning("gemini web relay failed: %s", exc)
        yield _error_event(f"gemini web relay error: {str(exc)[:300]}")
        yield "data: [DONE]\n\n"
        return

    for item in deltas:
        delta = str(item.get("delta") or "")
        if not delta:
            continue
        field = "reasoning_content" if item.get("type") == "reasoning" else "content"
        yield _chunk(created, model, {field: delta})
    yield _chunk(created, model, {}, finish="stop")
    yield "data: [DONE]\n\n"


# Register every adapter the worker knows about. The site selects the adapter
# for each turn by sending the provider id in the <c>X-Text-Provider</c>
# header; the worker looks it up here. Keys are the stable ids from
# <see cref="server-settings.json"/> <c>TextProviders[*].Id</c>.
register_adapter("tryingopen")(_translate_tryingopen)

# Register the DeepSeek adapter (kept under the old "deepseek-web" id for
# backwards compatibility with older server configs).
register_adapter("deepseek-web")(_translate_deepseek)
register_adapter("deepseek")(_translate_deepseek)

# Register the arena.ai adapter (provider id "arena", model "arena/max").
register_adapter("arena")(_translate_arena)

# Gemini web chat. Needs one signed-in Google tab; see --gemini-login.
register_adapter("gemini-web")(_translate_gemini_web)
register_adapter("gemini")(_translate_gemini_web)


# ---------------------------------------------------------------------------
# Image generation on the chat worker (127.0.0.1:8003)
# ---------------------------------------------------------------------------
# The image worker (8002) forwards ``gemini-image`` / ``duckai-image`` here.
# Both providers draw from the player's own browser session, so this endpoint
# lives next to the adapters that already own those sessions. It is plain
# JSON, not chat SSE: the caller only needs the finished picture.

DUCK_IMAGE_MODEL = os.getenv("DUCK_IMAGE_MODEL", "image-generation")
_IMAGE_HTTP_TIMEOUT = httpx.Timeout(connect=15.0, read=180.0, write=30.0, pool=15.0)


def _image_result(b64: str, fmt: str) -> dict:
    fmt = (fmt or "png").strip().lower().lstrip(".")
    if fmt not in ("png", "jpeg", "jpg", "webp", "gif"):
        fmt = "png"
    return {
        "created": int(time.time()),
        "data": [{"b64_json": b64, "mime_type": "image/" + fmt}],
    }


def _find_b64_image(value) -> tuple[str, str] | None:
    """Dig the finished base64 picture out of Duck.ai's stream events.

    Duck sends the result as a ``ui-component`` whose data contains
    ``status: success``, ``b64Image`` and ``format`` (an older frame shape uses
    ``generated-image`` with ``result``). Recursive on purpose: the payload's
    nesting has changed between site builds more than once.
    """
    if isinstance(value, dict):
        status = str(value.get("status") or "").strip().lower()
        if status not in ("", "success", "succeeded", "done", "ready"):
            for key in ("data", "result", "value"):
                nested = _find_b64_image(value.get(key))
                if nested:
                    return nested
            return None
        for key in ("b64Image", "b64_image", "imageBase64"):
            b64 = value.get(key)
            if isinstance(b64, str) and len(b64) > 1024:
                return b64, str(value.get("format") or "png")
        for key in ("result", "image", "data", "value"):
            nested = _find_b64_image(value.get(key))
            if nested:
                return nested
        return None
    if isinstance(value, list):
        for item in value:
            nested = _find_b64_image(item)
            if nested:
                return nested
    return None


def _duck_image(prompt: str) -> dict:
    """Draw via Duck.ai's own image mode inside the regular chat stream."""
    headers_base = {
        "User-Agent": USER_AGENT,
        "Accept": "text/event-stream",
        "Referer": "https://duckduckgo.com/",
        "Origin": "https://duckduckgo.com",
    }
    with httpx.Client(timeout=_IMAGE_HTTP_TIMEOUT, headers=headers_base, follow_redirects=True) as client:
        status = client.get(DUCK_STATUS_URL, headers={"x-vqd-accept": "1"})
        vqd = status.headers.get("x-vqd-4") or status.headers.get("x-vqd-hash-1")
        if not vqd:
            raise RuntimeError("duck.ai did not issue a session token (vqd)")
        payload = {
            "model": DUCK_IMAGE_MODEL,
            "messages": [{"role": "user", "content": [{"type": "text", "text": prompt}]}],
            "metadata": {"toolChoice": {"GenerateImage": True}},
            "canUseTools": False,
            "canDelegateImageGeneration": True,
        }
        with client.stream(
            "POST",
            DUCK_CHAT_URL,
            headers={"Content-Type": "application/json", "x-vqd-4": vqd},
            json=payload,
        ) as response:
            if response.status_code == 429:
                raise RuntimeError("duck.ai image rate limit reached on this IP")
            if response.status_code >= 400:
                body = response.read().decode("utf-8", "replace")[:240]
                raise RuntimeError(f"duck.ai image HTTP {response.status_code}: {body}")
            for line in response.iter_lines():
                if not line or not line.startswith("data:"):
                    continue
                data = line[5:].strip()
                if data == "[DONE]":
                    break
                try:
                    event = json.loads(data)
                except ValueError:
                    continue
                found = _find_b64_image(event)
                if found:
                    log.info("duck.ai returned an image (%d base64 chars)", len(found[0]))
                    return _image_result(*found)
                if event.get("action") == "error" or event.get("type") == "error":
                    raise RuntimeError("duck.ai image error: " + str(event.get("status") or event.get("error") or "unknown")[:200])
    raise RuntimeError("duck.ai finished the stream without an image (image mode may be unavailable on this account)")


def _gemini_image(prompt: str) -> dict:
    """Ask the player's signed-in Gemini tab for a picture."""
    if not GEMINI_SESSION_FILE.exists():
        raise RuntimeError(
            "gemini.google login required: run python local-chat-worker.py --gemini-login once"
        )
    spec = _gemini_model_spec(os.getenv("GEMINI_IMAGE_MODEL", "gemini-web"))
    browser = ArenaBrowser.instance()
    instruction = (
        "Create the image described below. Produce the image itself, not a description, "
        "a prompt, code or a link.\n\n" + prompt
    )
    deltas = browser.gemini_stream(instruction, spec, collect_images=True)
    urls = [
        str(item.get("delta") or "")
        for item in deltas
        if item.get("type") == "image" and item.get("delta")
    ]
    if not urls:
        raise RuntimeError(
            "gemini.google did not return an image in the stream; "
            "the signed-in model may not offer image generation today"
        )
    url = urls[-1]
    if url.startswith("data:"):
        header, b64 = url.split(",", 1)
        mime = header[5:].split(";")[0].strip() or "image/png"
        return _image_result(b64, mime)

    # The CDN link belongs to the browser session: fetch it from the same tab
    # instead of from Python, where Google's cookies/referer are missing.
    browser._ensure_gemini_page()
    expression = """
(async () => {
  const r = await fetch(%s, {credentials: 'same-origin'});
  if (!r.ok) return 'ERR' + r.status;
  const blob = await r.blob();
  return await new Promise((resolve) => {
    const reader = new FileReader();
    reader.onload = () => resolve('OK' + reader.result);
    reader.onerror = () => resolve('ERRREADER');
    reader.readAsDataURL(blob);
  });
})()
""" % json.dumps(url)
    raw = browser._gemini_eval(expression, await_promise=True, timeout=90.0)
    if not isinstance(raw, str) or not raw.startswith("OKdata:"):
        raise RuntimeError("could not download the Gemini image: " + str(raw)[:160])
    header, b64 = raw[2:].split(",", 1)
    mime = header[5:].split(";")[0].strip() or "image/png"
    log.info("gemini returned an image (%d base64 chars)", len(b64))
    return _image_result(b64, mime)


def _image_adapter(provider: str, prompt: str) -> dict:
    if provider == "duckai":
        return _duck_image(prompt)
    return _gemini_image(prompt)


@app.post("/v1/images/generations")
async def images_generations(request: Request):
    try:
        body = await request.json()
    except Exception:
        body = {}
    if not isinstance(body, dict):
        body = {}
    prompt = str(body.get("prompt") or body.get("input") or "").strip()
    if not prompt:
        raise HTTPException(status_code=400, detail="prompt required")
    model = str(body.get("model") or "gemini-image").strip().lower()
    provider = "duckai" if "duck" in model else "gemini"
    try:
        result = await asyncio.to_thread(_image_adapter, provider, prompt)
    except Exception as exc:
        log.warning("%s image generation failed: %s", provider, exc)
        raise HTTPException(status_code=502, detail=f"{provider} image error: {str(exc)[:300]}")
    return JSONResponse(result)


# ---------------------------------------------------------------------------
# HTTP surface
# ---------------------------------------------------------------------------
@app.post("/v1/chat/completions")
async def chat_completions(request: Request):
    try:
        body = await request.json()
    except Exception:
        body = {}
    model = str(body.get("model") or "deepseek-web")
    messages = body.get("messages") or []
    tools = body.get("tools")
    tool_choice = body.get("tool_choice")
    if not isinstance(messages, list) or not messages:
        raise HTTPException(status_code=400, detail="messages required")

    provider = (request.headers.get("x-text-provider") or "").strip().lower()
    if not provider:
        lowered = model.lower()
        if "deepseek" in lowered:
            provider = "deepseek-web"
        elif "arena" in lowered:
            provider = "arena"
        elif "gemini" in lowered:
            provider = "gemini-web"
        else:
            provider = "tryingopen"

    def error_stream(message: str) -> StreamingResponse:
        async def _stream():
            yield _error_event(message)
            yield "data: [DONE]\n\n"
        return StreamingResponse(_stream(), media_type="text/event-stream")

    # One auth/ban/quota answer per provider is enough. Without this, a
    # LOGIN_GATE or INVALID_TOKEN is retried on every chat turn and every world
    # update, which is how a temporary block becomes a permanent-looking ban.
    left = _adapter_cooldown_left(provider)
    if left:
        return error_stream(
            f"{provider} is cooling down for {left}s after a login, ban or rate-limit "
            "error. The next turn will try it again."
        )

    adapter = ADAPTERS.get(provider)
    if adapter is None:
        # NEVER fall back to TryingOpen here. Its /api/open answers 403 to
        # programmatic calls, so the old fallback turned every missing adapter
        # into a misleading "tryingopen HTTP 403" in the world error and hid the
        # real cause (stale worker / outdated bat). Fail loudly instead: the
        # site then marks this adapter as failed and tries the next one.
        log.warning("unknown x-text-provider %r; no TryingOpen fallback", provider)
        return error_stream(
            f"{provider} is not available in this worker. "
            "Re-download and run the newest StartImage+Chat.bat."
        )

    try:
        generator = adapter(model, messages, tools, tool_choice)
    except Exception as exc:
        log.exception("adapter %r failed", provider or model)
        _adapter_trip(provider, str(exc))
        return error_stream(f"adapter {provider or model} failed: {str(exc)[:200]}")

    def watched():
        # Every adapter reports failures as an SSE error frame. Trip the shared
        # cooldown there so Arena, DeepSeek, DuckDuckGo, TryingOpen and any
        # future provider all get the same protection without extra code.
        for frame in generator:
            if isinstance(frame, str) and frame.startswith("data: {") and '"error"' in frame:
                try:
                    payload = json.loads(frame[5:].strip())
                    error = payload.get("error")
                    message = error.get("message") if isinstance(error, dict) else str(error)
                    if isinstance(message, str):
                        _adapter_trip(provider, message)
                except Exception:
                    pass
            yield frame

    # Always streamed back to the site; its SSE reader expects OpenAI chunk
    # framing regardless of whether it asked for stream:true.
    return StreamingResponse(watched(), media_type="text/event-stream")


@app.get("/healthz")
async def healthz():
    session_ready = SESSION_FILE.exists()
    arena_ready = ARENA_SESSION_FILE.exists()
    gemini_ready = GEMINI_SESSION_FILE.exists()
    return {
        "status": "ok",
        "deepseekSession": session_ready,
        "arenaSession": arena_ready,
        "geminiSession": gemini_ready,
    }


def gemini_login(timeout: float = 300.0) -> None:
    """Show Chrome once so the player can sign in to gemini.google.com."""
    browser = ArenaBrowser.instance()
    with browser._lock:
        browser.stop()  # restart visibly; the session itself lives in the profile
        browser._launch(visible=True)
        try:
            print("Sign in to gemini.google.com in the browser window. Waiting up to 5 minutes...")
            deadline = time.time() + timeout
            tokens: dict[str, str] = {}
            while time.time() < deadline:
                try:
                    tokens = browser._ensure_gemini_page(require_tokens=False, timeout=2.0)
                except ArenaError:
                    tokens = {}
                if tokens.get("at") and tokens.get("bl") and tokens.get("sid"):
                    break
                time.sleep(3.0)
            if not (tokens.get("at") and tokens.get("bl") and tokens.get("sid")):
                raise ArenaError("Gemini sign-in timed out; no signed-in page token was found")
            GEMINI_SESSION_FILE.write_text(
                json.dumps({"captured_at": time.time(), "url": tokens.get("url", "")}, indent=2),
                encoding="utf-8",
            )
            print(f"Saved Gemini sign-in receipt to {GEMINI_SESSION_FILE}")
        finally:
            # Always park + close the helper Chrome, even if the sign-in timed
            # out or the player closed the window mid-wait.
            browser._apply_window_style(hidden=True)
            browser.stop()


if __name__ == "__main__":
    if "--login" in sys.argv:
        try:
            login()
        except Exception as exc:
            log.error("%s", exc)
            print(f"DeepSeek login failed: {exc}")
            sys.exit(1)
        sys.exit(0)

    if "--arena-login" in sys.argv:
        try:
            ArenaBrowser.instance().login(keep_running=False)
        except Exception as exc:
            log.error("%s", exc)
            print(f"arena.ai login failed: {exc}")
            sys.exit(1)
        sys.exit(0)

    if "--gemini-login" in sys.argv:
        try:
            gemini_login()
        except Exception as exc:
            log.error("%s", exc)
            print(f"gemini.google login failed: {exc}")
            sys.exit(1)
        sys.exit(0)

    if "--test-image" in sys.argv:
        # One-shot check on the player's PC: which browser providers really
        # return a picture here, and how long each one takes.
        sample = "A quiet medieval library at dusk, warm candlelight, watercolor illustration"
        for provider in ("gemini", "duckai"):
            started = time.time()
            try:
                result = _image_adapter(provider, sample)
                item = result["data"][0]
                ext = (item.get("mime_type") or "image/png").split("/")[-1].replace("jpeg", "jpg")
                target = Path(__file__).resolve().with_name(f"test-image-{provider}.{ext}")
                target.write_bytes(base64.b64decode(item["b64_json"]))
                print(f"{provider}: OK in {time.time() - started:.1f}s -> {target}")
            except Exception as exc:
                print(f"{provider}: FAIL after {time.time() - started:.1f}s: {exc}")
        sys.exit(0)

    import uvicorn

    port = int(os.getenv("CHAT_WORKER_PORT", "8003"))
    uvicorn.run(app, host="127.0.0.1", port=port, log_level="info")
