import json
import subprocess
import tempfile
from datetime import datetime, timezone
from pathlib import Path

from fastapi import APIRouter, BackgroundTasks, Depends, HTTPException
from pydantic import BaseModel
from sqlalchemy.ext.asyncio import AsyncSession

from auth import verified_user
from config import settings
from database import get_db, SessionLocal
from models import Session, TranscriptStatus
from sessions import _to_response, SessionResponse
from transcription import transcribe_session

router = APIRouter(prefix="/sessions", tags=["sessions"])


class MergeRequest(BaseModel):
    session_ids: list[str]  # exactamente 2, en orden cronológico


async def _transcribe_merged(session_id: str, audio_path: str) -> None:
    async with SessionLocal() as db:
        await transcribe_session(session_id, audio_path, db)


def _audio_duration_s(path: Path) -> float:
    result = subprocess.run(
        [
            "ffprobe", "-v", "error",
            "-show_entries", "format=duration",
            "-of", "default=noprint_wrappers=1:nokey=1",
            str(path),
        ],
        capture_output=True, text=True, check=True,
    )
    return float(result.stdout.strip())


def _concat_audio(path1: Path, path2: Path, output: Path) -> None:
    subprocess.run(
        [
            "ffmpeg", "-y",
            "-i", str(path1),
            "-i", str(path2),
            "-filter_complex", "[0:a][1:a]concat=n=2:v=0:a=1[out]",
            "-map", "[out]",
            str(output),
        ],
        capture_output=True, check=True,
    )


def _shift_notes(notes: list[dict], offset_ms: int) -> list[dict]:
    return [
        {**n, "timestamp_ms": n["timestamp_ms"] + offset_ms}
        for n in notes
    ]


@router.post("/merge", response_model=SessionResponse, status_code=201)
async def merge_sessions(
    body: MergeRequest,
    background_tasks: BackgroundTasks,
    user: dict = Depends(verified_user),
    db: AsyncSession = Depends(get_db),
):
    if len(body.session_ids) != 2:
        raise HTTPException(status_code=422, detail="Se requieren exactamente 2 sesiones")

    id1, id2 = body.session_ids
    rec1 = await db.get(Session, id1)
    rec2 = await db.get(Session, id2)

    if not rec1 or rec1.uid != user["uid"]:
        raise HTTPException(status_code=404, detail=f"Sesión {id1} no encontrada")
    if not rec2 or rec2.uid != user["uid"]:
        raise HTTPException(status_code=404, detail=f"Sesión {id2} no encontrada")

    path1 = Path(settings.upload_dir) / rec1.audio_path
    path2 = Path(settings.upload_dir) / rec2.audio_path

    if not path1.exists():
        raise HTTPException(status_code=422, detail="Audio de la primera sesión no disponible")
    if not path2.exists():
        raise HTTPException(status_code=422, detail="Audio de la segunda sesión no disponible")

    uid = user["uid"]
    session_id = datetime.now(timezone.utc).strftime("%Y%m%d_%H%M%S")
    session_dir = Path(settings.upload_dir) / uid / session_id
    session_dir.mkdir(parents=True, exist_ok=True)

    # Concatenar audio — usar extensión del primer archivo
    ext = path1.suffix
    merged_audio = session_dir / f"audio{ext}"
    try:
        _concat_audio(path1, path2, merged_audio)
    except subprocess.CalledProcessError as e:
        raise HTTPException(status_code=500, detail=f"Error al concatenar audio: {e.stderr.decode()[:200]}")

    # Calcular offset para las notas de la segunda sesión
    try:
        duration1_ms = int(_audio_duration_s(path1) * 1000)
    except Exception:
        duration1_ms = 0

    # Fusionar notas
    notes1: list[dict] = json.loads(rec1.notes_content) if rec1.notes_content else []
    notes2: list[dict] = json.loads(rec2.notes_content) if rec2.notes_content else []
    merged_notes = notes1 + _shift_notes(notes2, duration1_ms)

    rel_audio = str(merged_audio.relative_to(settings.upload_dir))

    record = Session(
        uid=uid,
        session_id=session_id,
        audio_path=rel_audio,
        notes_path="",
        note_count=len(merged_notes),
        notes_content=json.dumps(merged_notes, ensure_ascii=False),
        # Copiar labels y speaker_names de la primera sesión como punto de partida
        labels=rec1.labels,
        speaker_names=rec1.speaker_names,
    )
    db.add(record)
    await db.commit()
    await db.refresh(record)

    background_tasks.add_task(_transcribe_merged, record.id, rel_audio)

    return _to_response(record)
