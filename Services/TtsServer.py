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
model_state = {
    "device": None,
    "model": None,
    "model_id": None,
    "revision": None,
    "tokenizer": None,
}
def get_model(model_id: str):
    with model_lock:
        revision = os.environ.get("WINLAMA_TTS_REVISION") or None
        if (
            model_state["model_id"] == model_id
            and model_state["revision"] == revision
        ):
            return model_state
        cache_dir = os.environ.get("WINLAMA_TTS_CACHE") or None
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
        model_state.update(
            device=device,
            model=model,
            model_id=model_id,
            revision=revision,
            tokenizer=tokenizer,
        )
        return model_state
@asynccontextmanager
async def lifespan(_):
    model_id = get_configured_model()
    get_configured_language()
    await asyncio.to_thread(get_model, model_id)
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
    expected_model = get_configured_model()
    if model_state["model_id"] != expected_model:
        raise HTTPException(
            status_code=503,
            detail=get_message("Tts.Error.ModelNotReady"),
        )
    return {
        "model": model_state["model_id"],
        "language": get_configured_language(),
        "ready": True,
        "revision": model_state["revision"],
    }
@app.get("/v1/models")
def models():
    model_id = get_configured_model()
    entries = [{"id": model_id, "name": model_id, "object": "model"}]
    return {"data": entries, "models": entries}
@app.get("/v1/audio/models")
def audio_models():
    return models()
@app.get("/v1/audio/voices")
def voices():
    language = get_configured_language()
    names = {
        "en": get_message("Tts.Voice.en"),
        "tr": get_message("Tts.Voice.tr"),
    }
    entries = [{"id": language, "name": names[language]}]
    return {"data": entries, "voices": entries}
@app.post("/v1/audio/speech")
def speech(request: SpeechRequest):
    allowed_model = get_configured_model()
    allowed_language = get_configured_language()
    requested_model = request.model or allowed_model
    requested_voice = request.voice or allowed_language
    if requested_model != allowed_model:
        raise HTTPException(
            status_code=400,
            detail=get_message("Tts.Error.ModelUnsupported"),
        )
    if requested_voice != allowed_language:
        raise HTTPException(
            status_code=400,
            detail=get_message("Tts.Error.VoiceUnsupported"),
        )
    try:
        state = get_model(allowed_model)
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