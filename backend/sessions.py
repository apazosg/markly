import csv
import io
import json
import shutil
from datetime import datetime, timezone
from pathlib import Path

from fastapi import APIRouter, BackgroundTasks, Depends, HTTPException, UploadFile, File
from pydantic import BaseModel
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from auth import verified_user
from config import settings
from database import get_db, SessionLocal
from models import Session, TranscriptStatus
from transcription import transcribe_session, reprocess_session
import usage as usage_module

router = APIRouter(prefix="/sessions", tags=["sessions"])


class MetadataUpdate(BaseModel):
    title: str | None = None
    labels: list[str] | None = None
    speaker_names: dict[str, str] | None = None
    transcript_notes: list[dict] | None = None
    notes_content: list[dict] | None = None
    utterance_edits: dict[str, str] | None = None
    speaker_overrides: dict[str, str] | None = None
    general_notes: str | None = None
    duration_ms: int | None = None


class SessionResponse(BaseModel):
    id: str
    session_id: str
    uid: str
    note_count: int
    created_at: datetime
    transcript_status: TranscriptStatus
    transcript: str | None = None
    diarization: str | None = None
    title: str | None = None
    labels: list[str] = []
    speaker_names: dict[str, str] = {}
    transcript_notes: list[dict] = []
    notes_content: list[dict] = []
    utterance_edits: dict[str, str] = {}
    speaker_overrides: dict[str, str] = {}
    general_notes: str | None = None
    duration_ms: int | None = None
    # Audio Intelligence (read-only, generado por Deepgram)
    summary: str | None = None
    topics: list[str] = []
    utterances_data: list[dict] = []
    paragraphs_data: list[dict] = []


async def _transcribe_in_background(session_id: str, audio_path: str) -> None:
    async with SessionLocal() as db:
        await transcribe_session(session_id, audio_path, db)


async def _reprocess_in_background(session_id: str) -> None:
    async with SessionLocal() as db:
        await reprocess_session(session_id, db)


@router.post("", response_model=SessionResponse, status_code=201)
async def upload_session(
    background_tasks: BackgroundTasks,
    audio: UploadFile = File(...),
    notes: UploadFile = File(...),
    user: dict = Depends(verified_user),
    db: AsyncSession = Depends(get_db),
):
    if not audio.filename or not audio.filename.endswith((".m4a", ".wav")):
        raise HTTPException(status_code=422, detail="El archivo de audio debe ser .m4a o .wav")
    if not notes.filename or not notes.filename.endswith(".csv"):
        raise HTTPException(status_code=422, detail="El archivo de notas debe ser .csv")

    uid = user["uid"]
    await usage_module.assert_credits_available(uid, db, email=user.get("email", ""))

    session_id = datetime.now(timezone.utc).strftime("%Y%m%d_%H%M%S")
    session_dir = Path(settings.upload_dir) / uid / session_id
    session_dir.mkdir(parents=True, exist_ok=True)

    ext = ".wav" if audio.filename.endswith(".wav") else ".m4a"
    audio_path = session_dir / f"audio{ext}"
    notes_path = session_dir / "notes.csv"

    with audio_path.open("wb") as f:
        shutil.copyfileobj(audio.file, f)

    notes_bytes = await notes.read()
    notes_path.write_bytes(notes_bytes)

    notes_json = _parse_csv(notes_bytes.decode("utf-8", errors="replace"))
    rel_audio = str(audio_path.relative_to(settings.upload_dir))

    record = Session(
        uid=uid,
        session_id=session_id,
        audio_path=rel_audio,
        notes_path=str(notes_path.relative_to(settings.upload_dir)),
        note_count=len(notes_json),
        notes_content=json.dumps(notes_json, ensure_ascii=False),
    )
    db.add(record)
    await db.commit()
    await db.refresh(record)

    background_tasks.add_task(_transcribe_in_background, record.id, rel_audio)

    return _to_response(record)


@router.post("/{session_id}/reprocess", response_model=SessionResponse)
async def reprocess_session_endpoint(
    session_id: str,
    background_tasks: BackgroundTasks,
    user: dict = Depends(verified_user),
    db: AsyncSession = Depends(get_db),
):
    record = await db.get(Session, session_id)
    if not record or record.uid != user["uid"]:
        raise HTTPException(status_code=404)

    await usage_module.assert_credits_available(user["uid"], db, email=user.get("email", ""))

    record.transcript_status = TranscriptStatus.pending
    await db.commit()
    await db.refresh(record)

    if record.utterances_data:
        background_tasks.add_task(_reprocess_in_background, record.id)
    else:
        audio_full = Path(settings.upload_dir) / record.audio_path
        if not audio_full.exists():
            raise HTTPException(status_code=422, detail="No hay transcripción ni audio disponible para reprocesar")
        background_tasks.add_task(_transcribe_in_background, record.id, record.audio_path)

    return _to_response(record)


@router.delete("/{session_id}", status_code=204)
async def delete_session(
    session_id: str,
    user: dict = Depends(verified_user),
    db: AsyncSession = Depends(get_db),
):
    record = await db.get(Session, session_id)
    if not record or record.uid != user["uid"]:
        raise HTTPException(status_code=404)
    try:
        session_dir = (Path(settings.upload_dir) / record.audio_path).parent
        shutil.rmtree(session_dir, ignore_errors=True)
    except Exception:
        pass
    await db.delete(record)
    await db.commit()


@router.patch("/{session_id}/metadata", response_model=SessionResponse)
async def update_metadata(
    session_id: str,
    body: MetadataUpdate,
    user: dict = Depends(verified_user),
    db: AsyncSession = Depends(get_db),
):
    record = await db.get(Session, session_id)
    if not record or record.uid != user["uid"]:
        raise HTTPException(status_code=404)

    if body.title is not None:
        record.title = body.title or None
    if body.labels is not None:
        record.labels = json.dumps(body.labels, ensure_ascii=False)
    if body.speaker_names is not None:
        record.speaker_names = json.dumps(body.speaker_names, ensure_ascii=False)
    if body.transcript_notes is not None:
        record.transcript_notes = json.dumps(body.transcript_notes, ensure_ascii=False)
    if body.notes_content is not None:
        record.notes_content = json.dumps(body.notes_content, ensure_ascii=False)
        record.note_count = len(body.notes_content)
    if body.utterance_edits is not None:
        record.utterance_edits = json.dumps(body.utterance_edits, ensure_ascii=False)
    if body.speaker_overrides is not None:
        record.speaker_overrides = json.dumps(body.speaker_overrides, ensure_ascii=False)
    if body.general_notes is not None:
        record.general_notes = body.general_notes or None
    if body.duration_ms is not None:
        record.duration_ms = body.duration_ms

    await db.commit()
    await db.refresh(record)
    return _to_response(record)


@router.get("", response_model=list[SessionResponse])
async def list_sessions(
    user: dict = Depends(verified_user),
    db: AsyncSession = Depends(get_db),
):
    result = await db.execute(
        select(Session).where(Session.uid == user["uid"]).order_by(Session.created_at.desc())
    )
    return [_to_response(r) for r in result.scalars().all()]


@router.get("/{session_id}", response_model=SessionResponse)
async def get_session(
    session_id: str,
    user: dict = Depends(verified_user),
    db: AsyncSession = Depends(get_db),
):
    record = await db.get(Session, session_id)
    if not record or record.uid != user["uid"]:
        raise HTTPException(status_code=404)
    return _to_response(record)


def _to_response(r: Session) -> SessionResponse:
    return SessionResponse(
        id=r.id,
        session_id=r.session_id,
        uid=r.uid,
        note_count=r.note_count,
        created_at=r.created_at,
        transcript_status=r.transcript_status,
        transcript=r.transcript,
        diarization=r.diarization,
        title=r.title,
        labels=json.loads(r.labels) if r.labels else [],
        speaker_names=json.loads(r.speaker_names) if r.speaker_names else {},
        transcript_notes=json.loads(r.transcript_notes) if r.transcript_notes else [],
        notes_content=json.loads(r.notes_content) if r.notes_content else [],
        utterance_edits=json.loads(r.utterance_edits) if r.utterance_edits else {},
        speaker_overrides=json.loads(r.speaker_overrides) if r.speaker_overrides else {},
        general_notes=r.general_notes,
        duration_ms=r.duration_ms,
        summary=r.summary,
        topics=json.loads(r.topics) if r.topics else [],
        utterances_data=json.loads(r.utterances_data) if r.utterances_data else [],
        paragraphs_data=json.loads(r.paragraphs_data) if r.paragraphs_data else [],
    )


def _parse_csv(content: str) -> list[dict]:
    notes = []
    reader = csv.DictReader(io.StringIO(content))
    for row in reader:
        try:
            notes.append({
                "timestamp_ms": int(row.get("timestamp_ms", 0)),
                "text": row.get("note", ""),
                "title": row.get("title") or None,
            })
        except (ValueError, KeyError):
            continue
    return notes
