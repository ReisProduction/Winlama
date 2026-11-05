import argparse
import asyncio
import io
import json
import logging
import os
import threading
from contextlib import asynccontextmanager
from typing import Literal
import soundfile
import torch
import uvicorn
from fastapi import FastAPI, HTTPException
from fastapi.exceptions import RequestValidationError
from fastapi.responses import JSONResponse, Response
from pydantic import BaseModel, Field
from starlette.exceptions import HTTPException as StarletteHTTPException
from transformers import AutoTokenizer, VitsModel
DEFAULT_MODEL = "facebook/mms-tts-tur"
DEFAULT_LANGUAGE = "tr"
VOICE_PROFILES = {
    "tr": ("facebook/mms-tts-tur", "7e364479c307f06733ca865b0a5269e0209cf82d"),
    "en": ("facebook/mms-tts-eng", "c71de0fe7204c83f1c10820a7d696d0b450048ba"),
}
MESSAGE_KEYS = (
    "Tts.Api.InternalError",
    "Tts.Api.MethodNotAllowed",
    "Tts.Api.NotFound",
    "Tts.Api.RequestInvalid",
    "Tts.Cli.Description",
    "Tts.Cli.Help",
    "Tts.Cli.HostHelp",
    "Tts.Cli.InvalidArguments",
    "Tts.Cli.PortHelp",
    "Tts.Error.LanguageUnsupported",
    "Tts.Error.LoopbackOnly",
    "Tts.Error.ModelNotReady",
    "Tts.Error.ModelUnsupported",
    "Tts.Error.SynthesisFailed",
    "Tts.Error.VoiceUnsupported",
    "Tts.Log.SynthesisFailed",
    "Tts.Log.UnexpectedFailure",
    "Tts.Voice.en",
    "Tts.Voice.tr",
)
def load_messages():
    messages = {key: key for key in MESSAGE_KEYS}
    raw_messages = os.environ.get("WINLAMA_TTS_MESSAGES", "")
    if not raw_messages:
        return messages
    try:
        configured = json.loads(raw_messages)
    except (json.JSONDecodeError, TypeError):
        return messages
    if not isinstance(configured, dict):
        return messages
    for key in MESSAGE_KEYS:
        value = configured.get(key)
        if isinstance(value, str) and value.strip():
            messages[key] = value
    return messages
messages = load_messages()
def get_message(key: str):
    return messages.get(key, key)
class LocalizedArgumentParser(argparse.ArgumentParser):
    def error(self, _message):
        self.exit(
            2,
            f"{get_message('Tts.Cli.InvalidArguments')}\n",
        )
def get_configured_model():
    return os.environ.get("WINLAMA_TTS_MODEL", DEFAULT_MODEL)
def get_configured_language():
    language = os.environ.get("WINLAMA_TTS_LANGUAGE", DEFAULT_LANGUAGE)
    if language not in {"en", "tr"}:
        raise ValueError(get_message("Tts.Error.LanguageUnsupported"))
    return language
class SpeechRequest(BaseModel):
    model: str = ""
    input: str = Field(min_length=1, max_length=5000)
    voice: str = ""
    response_format: Literal["mp3", "wav", "flac"] = "mp3"
    speed: float = Field(default=1.0, ge=0.25, le=4.0)
logger = logging.getLogger("winlama.tts")
model_lock = threading.Lock()
model_state = {}
def configured_profiles():
    language = get_configured_language()
    primary = (get_configured_model(), os.environ.get("WINLAMA_TTS_REVISION") or None)
    profiles = {language: primary}
    if os.environ.get("WINLAMA_TTS_BILINGUAL") == "1":
        additional = "en" if language == "tr" else "tr"
        profiles[additional] = VOICE_PROFILES[additional]
    return profiles
def get_model(model_id: str, revision: str | None):
    with model_lock:
        key = (model_id, revision)
        if key in model_state:
            return model_state[key]
        cache_dir = os.environ.get("WINLAMA_TTS_CACHE") or None
        if cache_dir and model_id != get_configured_model():
            cache_dir = os.path.join(os.path.dirname(cache_dir), model_id.split("/")[-1])
        tokenizer = AutoTokenizer.from_pretrained(
            model_id,
            cache_dir=cache_dir,
            revision=revision,
        )
        model = VitsModel.from_pretrained(
            model_id,
            cache_dir=cache_dir,
            revision=revision,
        )
        device = "cuda" if torch.cuda.is_available() else "cpu"
        model.to(device)
        model.eval()
        state = {"device": device, "model": model, "tokenizer": tokenizer}
        model_state[key] = state
        return state
@asynccontextmanager
async def lifespan(_):
    for profile in configured_profiles().values():
        await asyncio.to_thread(get_model, *profile)
    yield
app = FastAPI(docs_url=None, redoc_url=None, lifespan=lifespan)
@app.exception_handler(RequestValidationError)
async def request_validation_error(_, __):
    return JSONResponse(
        status_code=422,
        content={"detail": get_message("Tts.Api.RequestInvalid")},
    )
@app.exception_handler(StarletteHTTPException)
async def http_error(_, exception):
    if exception.status_code == 404:
        detail = get_message("Tts.Api.NotFound")
    elif exception.status_code == 405:
        detail = get_message("Tts.Api.MethodNotAllowed")
    elif isinstance(exception.detail, str) and exception.detail.strip():
        detail = exception.detail
    else:
        detail = get_message("Tts.Api.InternalError")
    return JSONResponse(
        status_code=exception.status_code,
        content={"detail": detail},
        headers=exception.headers,
    )
@app.exception_handler(Exception)
async def unexpected_error(_, exception):
    logger.error(
        get_message("Tts.Log.UnexpectedFailure"),
        exc_info=(
            type(exception),
            exception,
            exception.__traceback__,
        ),
    )
    return JSONResponse(
        status_code=500,
        content={"detail": get_message("Tts.Api.InternalError")},
    )
@app.get("/health")
def health():
    profiles = configured_profiles()
    language = get_configured_language()
    model, revision = profiles[language]
    if not all(profile in model_state for profile in profiles.values()):
        raise HTTPException(
            status_code=503,
            detail=get_message("Tts.Error.ModelNotReady"),
        )
    return {
        "model": model,
        "language": language,
        "ready": True,
        "revision": revision,
        "voices": list(profiles),
    }
@app.get("/v1/models")
def models():
    entries = [
        {"id": model_id, "name": model_id, "object": "model"}
        for model_id, _ in configured_profiles().values()
    ]
    return {"data": entries, "models": entries}
@app.get("/v1/audio/models")
def audio_models():
    return models()
@app.get("/v1/audio/voices")
def voices():
    entries = [
        {"id": language, "name": get_message(f"Tts.Voice.{language}")}
        for language in configured_profiles()
    ]
    return {"data": entries, "voices": entries}
@app.post("/v1/audio/speech")
def speech(request: SpeechRequest):
    profiles = configured_profiles()
    default_language = get_configured_language()
    language_for_model = {
        model_id: language for language, (model_id, _) in profiles.items()
    }
    if request.model and request.model not in language_for_model:
        raise HTTPException(
            status_code=400,
            detail=get_message("Tts.Error.ModelUnsupported"),
        )
    language = request.voice or language_for_model.get(request.model, default_language)
    if language not in profiles:
        raise HTTPException(
            status_code=400,
            detail=get_message("Tts.Error.VoiceUnsupported"),
        )
    if request.model and request.model not in {profiles[language][0], profiles[default_language][0]}:
        raise HTTPException(
            status_code=400,
            detail=get_message("Tts.Error.ModelUnsupported"),
        )
    try:
        state = get_model(*profiles[language])
        inputs = state["tokenizer"](
            request.input,
            return_tensors="pt",
        )
        inputs = {
            key: value.to(state["device"])
            for key, value in inputs.items()
        }
        with torch.inference_mode():
            waveform = state["model"](**inputs).waveform
        if request.speed != 1.0:
            output_length = max(
                1,
                round(waveform.shape[-1] / request.speed),
            )
            waveform = torch.nn.functional.interpolate(
                waveform.unsqueeze(1),
                size=output_length,
                mode="linear",
                align_corners=False,
            ).squeeze(1)
        audio = waveform.squeeze().detach().cpu().float().numpy()
        buffer = io.BytesIO()
        formats = {
            "flac": ("FLAC", "audio/flac"),
            "mp3": ("MP3", "audio/mpeg"),
            "wav": ("WAV", "audio/wav"),
        }
        output_format, media_type = formats[request.response_format]
        soundfile.write(
            buffer,
            audio,
            state["model"].config.sampling_rate,
            format=output_format,
        )
        return Response(buffer.getvalue(), media_type=media_type)
    except HTTPException:
        raise
    except Exception as exception:
        logger.exception(get_message("Tts.Log.SynthesisFailed"))
        raise HTTPException(
            status_code=500,
            detail=get_message("Tts.Error.SynthesisFailed"),
        ) from exception
def write_cli_help():
    for key in (
        "Tts.Cli.Description",
        "Tts.Cli.Help",
        "Tts.Cli.HostHelp",
        "Tts.Cli.PortHelp",
    ):
        print(get_message(key))
def main():
    parser = LocalizedArgumentParser(add_help=False)
    parser.add_argument(
        "-h",
        "--help",
        action="store_true",
        dest="show_help",
    )
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--port", type=int, default=8880)
    arguments = parser.parse_args()
    if arguments.show_help:
        write_cli_help()
        return
    if arguments.host not in {"127.0.0.1", "localhost", "::1"}:
        parser.exit(
            2,
            f"{get_message('Tts.Error.LoopbackOnly')}\n",
        )
    uvicorn.run(
        app,
        host=arguments.host,
        port=arguments.port,
        access_log=False,
        log_level="warning",
    )
if __name__ == "__main__":
    main()