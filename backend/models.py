import enum
import uuid
from datetime import datetime, timezone

from sqlalchemy import DateTime, Enum, Float, Integer, Text
from sqlalchemy.orm import Mapped, mapped_column

from database import Base


class TranscriptStatus(str, enum.Enum):
    pending = "pending"
    done = "done"
    error = "error"


class Session(Base):
    __tablename__ = "sessions"

    id: Mapped[str] = mapped_column(Text, primary_key=True, default=lambda: str(uuid.uuid4()))
    uid: Mapped[str] = mapped_column(Text, index=True, nullable=False)
    session_id: Mapped[str] = mapped_column(Text, nullable=False)
    audio_path: Mapped[str] = mapped_column(Text, nullable=False)
    notes_path: Mapped[str] = mapped_column(Text, nullable=False)
    note_count: Mapped[int] = mapped_column(Integer, nullable=False, default=0)
    created_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True),
        nullable=False,
        default=lambda: datetime.now(timezone.utc),
    )
    transcript_status: Mapped[TranscriptStatus] = mapped_column(
        Enum(TranscriptStatus),
        nullable=False,
        default=TranscriptStatus.pending,
    )
    transcript: Mapped[str | None] = mapped_column(Text, nullable=True)
    diarization: Mapped[str | None] = mapped_column(Text, nullable=True)
    # Metadata — fuente de verdad para multi-dispositivo
    title: Mapped[str | None] = mapped_column(Text, nullable=True)
    labels: Mapped[str | None] = mapped_column(Text, nullable=True)          # JSON: ["sprint","cliente"]
    speaker_names: Mapped[str | None] = mapped_column(Text, nullable=True)   # JSON: {"0":"Adrián"}
    transcript_notes: Mapped[str | None] = mapped_column(Text, nullable=True) # JSON: [{timestamp_s,text,title}]
    notes_content: Mapped[str | None] = mapped_column(Text, nullable=True)   # JSON: [{timestamp_ms,text,title}]
    utterance_edits: Mapped[str | None] = mapped_column(Text, nullable=True)   # JSON: {"start_ms": "edited text"}
    speaker_overrides: Mapped[str | None] = mapped_column(Text, nullable=True) # JSON: {"start_ms": "speakerId"}
    general_notes: Mapped[str | None] = mapped_column(Text, nullable=True)     # texto libre sin timestamp
    duration_ms: Mapped[int | None] = mapped_column(Integer, nullable=True)
    # Audio Intelligence
    summary: Mapped[str | None] = mapped_column(Text, nullable=True)
    topics: Mapped[str | None] = mapped_column(Text, nullable=True)           # JSON: ["topic1", "topic2"]
    utterances_data: Mapped[str | None] = mapped_column(Text, nullable=True)  # JSON: [{speaker,start,end,text}]
    paragraphs_data: Mapped[str | None] = mapped_column(Text, nullable=True)  # JSON: [{start,end}]


class UsageEvent(Base):
    __tablename__ = "usage_events"

    id: Mapped[str] = mapped_column(Text, primary_key=True, default=lambda: str(uuid.uuid4()))
    uid: Mapped[str] = mapped_column(Text, index=True, nullable=False)
    session_id: Mapped[str | None] = mapped_column(Text, nullable=True)
    # "deepgram" (raw_amount = segundos) | "gemini" (raw_amount = tokens totales)
    event_type: Mapped[str] = mapped_column(Text, nullable=False)
    raw_amount: Mapped[float] = mapped_column(Float, nullable=False)
    cost_eur: Mapped[float] = mapped_column(Float, nullable=False)
    credits: Mapped[float] = mapped_column(Float, nullable=False)
    created_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True),
        nullable=False,
        default=lambda: datetime.now(timezone.utc),
    )
