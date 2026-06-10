import json
from contextlib import asynccontextmanager

import firebase_admin
from firebase_admin import credentials
from fastapi import FastAPI

from config import settings
from database import create_tables
from sessions import router as sessions_router
from merge import router as merge_router
from usage import router as usage_router


def _init_firebase() -> None:
    if settings.firebase_sa_json:
        cred = credentials.Certificate(json.loads(settings.firebase_sa_json))
    else:
        cred = credentials.ApplicationDefault()
    firebase_admin.initialize_app(cred)


def _validate_config() -> None:
    missing = []
    if not settings.firebase_sa_json:
        missing.append("FIREBASE_SA_JSON")
    if not settings.deepgram_api_key:
        missing.append("DEEPGRAM_API_KEY")
    if missing:
        raise RuntimeError(f"Variables de entorno requeridas no configuradas: {', '.join(missing)}")


@asynccontextmanager
async def lifespan(app: FastAPI):
    _validate_config()
    _init_firebase()
    await create_tables()
    yield


app = FastAPI(title="Markly API", version="0.1.0", lifespan=lifespan)

# 500 MB máximo por request (reuniones largas en .m4a)
from fastapi import Request
from fastapi.responses import JSONResponse

@app.middleware("http")
async def limit_upload_size(request: Request, call_next):
    content_length = request.headers.get("content-length")
    if content_length and int(content_length) > 500 * 1024 * 1024:
        return JSONResponse(status_code=413, content={"detail": "Archivo demasiado grande (máx 500 MB)"})
    return await call_next(request)

app.include_router(sessions_router)
app.include_router(merge_router)
app.include_router(usage_router)


@app.get("/health")
async def health():
    return {"status": "ok"}
