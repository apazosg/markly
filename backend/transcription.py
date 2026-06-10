import asyncio
import json
import logging
from pathlib import Path

from deepgram import AsyncDeepgramClient
from google import genai
from google.genai import types
from sqlalchemy.ext.asyncio import AsyncSession

import usage as usage_module

logger = logging.getLogger(__name__)

from config import settings
from models import Session, TranscriptStatus

_deepgram_client: AsyncDeepgramClient | None = None
_gemini_client: genai.Client | None = None


def deepgram_client() -> AsyncDeepgramClient:
    global _deepgram_client
    if _deepgram_client is None:
        _deepgram_client = AsyncDeepgramClient(api_key=settings.deepgram_api_key)
    return _deepgram_client


def gemini_client() -> genai.Client | None:
    if not settings.gemini_api_key:
        return None
    global _gemini_client
    if _gemini_client is None:
        _gemini_client = genai.Client(api_key=settings.gemini_api_key)
    return _gemini_client


def _duration_from_utterances(utterances: list[dict]) -> float | None:
    if not utterances:
        return None
    try:
        return utterances[-1]["end"] - utterances[0]["start"]
    except (KeyError, TypeError):
        return None


def _summary_instructions(duration_s: float | None, labels: list[str]) -> str:
    normalized = [l.lower().strip() for l in labels]
    is_one_to_one = "one to one" in normalized

    if is_one_to_one:
        return """Estructura el resumen en exactamente estas tres secciones con sus títulos en markdown:

## Situación personal y evolución
- Puntos clave sobre el estado del empleado, motivación y bienestar.

## Trabajo, equipo y proyectos
- Estado de proyectos, logros recientes y bloqueos o dificultades técnicas.

## Acciones acordadas
- Lista de compromisos y tareas concretas para la siguiente reunión."""

    minutes = (duration_s / 60) if duration_s else None

    return f"""Genera el resumen en markdown con bullets, sin párrafos de prosa. Usa este formato:

## Participantes
Para cada persona que habló, una línea con su nombre en negrita seguida de bullets con sus puntos:

**Nombre** — descripción de su rol si se puede inferir
- Punto clave 1
- Punto clave 2

## Decisiones y acuerdos
- Lista de decisiones tomadas (omite esta sección si no hubo ninguna)

## Acciones pendientes
- **Responsable**: descripción de la tarea (omite esta sección si no hay tareas claras)

Reglas:
- Usa los nombres reales de los hablantes si se mencionan en la transcripción, no "Hablante X".
- Sé conciso: cada bullet en una línea, sin subordinadas largas.
- No incluyas secciones vacías."""


async def _postprocess_with_gemini(
    utterances: list[dict],
    notes: list[dict],
    labels: list[str],
    speaker_names: dict[str, str] | None = None,
    transcript_notes: list[dict] | None = None,
    _uid: str = "",
    _session_id: str = "",
    general_notes: str | None = None,
) -> dict | None:
    client = gemini_client()
    if not client:
        return None

    names = speaker_names or {}

    def _speaker_label(sid: str) -> str:
        return names[sid] if sid in names else f"Hablante {sid}"

    transcript_text = "\n".join(
        f"[{_speaker_label(u['speaker'])}] ({u['start']:.1f}s–{u['end']:.1f}s) {u['text']}"
        for u in utterances
    )
    notes_text = (
        "\n".join(f"[{n['timestamp_ms'] // 1000}s] {n['text']}" for n in notes)
        if notes
        else "(sin notas)"
    )

    speaker_names_text = (
        "Nombres confirmados por el usuario: "
        + ", ".join(f"Hablante {sid} = {name}" for sid, name in names.items())
        if names
        else ""
    )

    duration_s = _duration_from_utterances(utterances)
    summary_instructions = _summary_instructions(duration_s, labels)

    existing_labels_text = (
        f"Etiquetas existentes: {', '.join(labels)}"
        if labels
        else "El usuario no tiene etiquetas asignadas."
    )

    tnotes_text = (
        "\n".join(f"[{n['timestamp_s']:.1f}s] {n['text']}" for n in (transcript_notes or []))
        if transcript_notes
        else ""
    )

    prompt = f"""Eres un asistente que procesa transcripciones de reuniones en español.

TRANSCRIPCIÓN DIARIZADA (Deepgram Whisper):
{transcript_text}
{f'''
NOMBRES DE HABLANTES CONFIRMADOS POR EL USUARIO:
{speaker_names_text}
Usa siempre estos nombres en el resumen y en la transcripción corregida, nunca "Hablante X".
''' if names else ''}
NOTAS DEL USUARIO durante la grabación (anclas de momentos importantes):
{notes_text}
{f'''
NOTAS AÑADIDAS DURANTE LA REVISIÓN DE LA TRANSCRIPCIÓN:
{tnotes_text}
''' if tnotes_text else ''}
{f'''
NOTAS GENERALES DEL USUARIO SOBRE LA REUNIÓN:
{general_notes}
''' if general_notes else ''}
INSTRUCCIONES PARA EL RESUMEN:
{summary_instructions}

Corrige errores de transcripción, nombres propios y términos técnicos usando el contexto.
Incorpora el contexto de todas las notas del usuario al generar el resumen.

INSTRUCCIONES PARA ETIQUETAS:
{existing_labels_text}
Si hay etiquetas existentes, reutiliza las que encajen con el contenido de esta reunión.
Solo añade etiquetas nuevas si ninguna existente encaja o si una nueva describe mejor el contenido.
Devuelve entre 1 y 4 etiquetas en minúsculas. No inventes etiquetas redundantes o genéricas.

Devuelve únicamente un JSON con estos campos:
{{
  "transcript": "transcripción corregida; si hay nombres confirmados úsalos en vez de 'Hablante X'",
  "summary": "resumen según las instrucciones anteriores",
  "topics": ["tema1", "tema2", "tema3"],
  "title": "título conciso de 4-6 palabras que describa de qué trató la reunión",
  "labels": ["etiqueta1", "etiqueta2"]
}}"""

    last_exc: Exception | None = None
    for attempt in range(4):
        try:
            response = await client.aio.models.generate_content(
                model="gemini-2.5-flash",
                contents=prompt,
                config=types.GenerateContentConfig(
                    response_mime_type="application/json",
                ),
            )
            try:
                meta = response.usage_metadata
                if meta and _uid:
                    asyncio.create_task(usage_module.record_gemini(
                        _uid, _session_id,
                        int(getattr(meta, "prompt_token_count", 0) or 0),
                        int(getattr(meta, "candidates_token_count", 0) or 0),
                    ))
            except Exception:
                pass
            return json.loads(response.text)
        except Exception as exc:
            last_exc = exc
            msg = str(exc)
            # Solo reintentar en errores transitorios (503, 429, 500)
            if not any(code in msg for code in ("503", "429", "500", "UNAVAILABLE", "RESOURCE_EXHAUSTED")):
                raise
            wait = 2 ** attempt * 5  # 5s, 10s, 20s, 40s
            logger.warning("Gemini intento %d falló (%s), reintentando en %ds…", attempt + 1, msg[:80], wait)
            await asyncio.sleep(wait)
    raise last_exc  # type: ignore[misc]


async def reprocess_session(session_id: str, db: AsyncSession) -> None:
    record = await db.get(Session, session_id)
    if not record:
        return

    try:
        utterances_list: list[dict] = json.loads(record.utterances_data) if record.utterances_data else []

        speaker_overrides: dict[str, str] = json.loads(record.speaker_overrides) if record.speaker_overrides else {}
        if speaker_overrides:
            for u in utterances_list:
                key = str(round(u["start"] * 1000))
                if key in speaker_overrides:
                    u["speaker"] = speaker_overrides[key]

        edits: dict[str, str] = json.loads(record.utterance_edits) if record.utterance_edits else {}
        if edits:
            for u in utterances_list:
                key = str(round(u["start"] * 1000))
                if key in edits:
                    u["text"] = edits[key]

        if not utterances_list:
            record.transcript_status = TranscriptStatus.done
            await db.commit()
            return

        notes: list[dict] = json.loads(record.notes_content) if record.notes_content else []
        labels: list[str] = json.loads(record.labels) if record.labels else []
        names: dict[str, str] = json.loads(record.speaker_names) if record.speaker_names else {}
        tnotes: list[dict] = json.loads(record.transcript_notes) if record.transcript_notes else []

        gemini_result = await _postprocess_with_gemini(
            utterances_list, notes, labels, names,
            transcript_notes=tnotes,
            general_notes=record.general_notes,
            _uid=record.uid,
            _session_id=record.id,
        )
        if gemini_result:
            if gemini_result.get("transcript"):
                record.transcript = gemini_result["transcript"]
            if gemini_result.get("summary"):
                record.summary = gemini_result["summary"]
            if gemini_result.get("topics"):
                record.topics = json.dumps(gemini_result["topics"], ensure_ascii=False)
            # Preservar título y etiquetas definidos por el usuario; solo completar si faltan
            if not record.title and gemini_result.get("title"):
                record.title = gemini_result["title"]
            if gemini_result.get("labels"):
                existing = set(labels)
                merged = labels + [l for l in gemini_result["labels"] if l not in existing]
                record.labels = json.dumps(merged, ensure_ascii=False)

        record.transcript_status = TranscriptStatus.done

    except Exception as e:
        record.transcript_status = TranscriptStatus.error
        record.transcript = str(e)

    await db.commit()


async def transcribe_session(session_id: str, audio_path: str, db: AsyncSession) -> None:
    record = await db.get(Session, session_id)
    if not record:
        return

    try:
        path = Path(settings.upload_dir) / audio_path
        audio_bytes = path.read_bytes()

        response = await deepgram_client().listen.v1.media.transcribe_file(
            request=audio_bytes,
            model="whisper-large",
            language="es",
            diarize=True,
            punctuate=True,
            utterances=True,
        )

        results = response.results

        # Registrar coste Deepgram
        try:
            duration_s = float(getattr(getattr(response, "metadata", None), "duration", 0) or 0)
            if duration_s > 0:
                asyncio.create_task(usage_module.record_deepgram(record.uid, record.id, duration_s))
        except Exception:
            pass

        if not results or not results.channels:
            record.transcript_status = TranscriptStatus.done
            record.transcript = ""
            await db.commit()
            return

        channel = results.channels[0]
        alternative = channel.alternatives[0] if channel.alternatives else None

        record.transcript = alternative.transcript if alternative else ""

        record.diarization = json.dumps([
            {
                "speaker": str(getattr(w, "speaker", "?")),
                "start": w.start,
                "end": w.end,
                "text": getattr(w, "punctuated_word", w.word),
            }
            for w in (alternative.words if alternative else []) or []
        ], ensure_ascii=False)

        utterances_list: list[dict] = []
        try:
            utterances_list = [
                {
                    "speaker": str(u.speaker),
                    "start": u.start,
                    "end": u.end,
                    "text": u.transcript,
                }
                for u in (results.utterances or [])
            ]
            record.utterances_data = json.dumps(utterances_list, ensure_ascii=False)
        except Exception:
            pass

        if utterances_list or record.transcript:
            try:
                notes = json.loads(record.notes_content) if record.notes_content else []
                labels = json.loads(record.labels) if record.labels else []
                names = json.loads(record.speaker_names) if record.speaker_names else {}
                tnotes = json.loads(record.transcript_notes) if record.transcript_notes else []
                gemini_result = await _postprocess_with_gemini(
                    utterances_list, notes, labels, names,
                    transcript_notes=tnotes,
                    general_notes=record.general_notes,
                    _uid=record.uid,
                    _session_id=record.id,
                )
                if gemini_result:
                    if gemini_result.get("transcript"):
                        record.transcript = gemini_result["transcript"]
                    if gemini_result.get("summary"):
                        record.summary = gemini_result["summary"]
                    if gemini_result.get("topics"):
                        record.topics = json.dumps(gemini_result["topics"], ensure_ascii=False)
                    if not record.title and gemini_result.get("title"):
                        record.title = gemini_result["title"]
                    if gemini_result.get("labels"):
                        record.labels = json.dumps(gemini_result["labels"], ensure_ascii=False)
            except Exception:
                pass

        record.transcript_status = TranscriptStatus.done

    except Exception as e:
        record.transcript_status = TranscriptStatus.error
        record.transcript = str(e)

    await db.commit()
