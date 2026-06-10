from sqlalchemy import text
from sqlalchemy.ext.asyncio import AsyncSession, async_sessionmaker, create_async_engine
from sqlalchemy.orm import DeclarativeBase

from config import settings

engine = create_async_engine(settings.database_url, pool_pre_ping=True)
SessionLocal = async_sessionmaker(engine, expire_on_commit=False)


class Base(DeclarativeBase):
    pass


async def get_db() -> AsyncSession:
    async with SessionLocal() as session:
        yield session


async def create_tables() -> None:
    async with engine.begin() as conn:
        await conn.run_sync(Base.metadata.create_all)
        # Migración segura: añade columnas nuevas si no existen
        new_columns = [
            ("title", "TEXT"),
            ("labels", "TEXT"),
            ("speaker_names", "TEXT"),
            ("transcript_notes", "TEXT"),
            ("notes_content", "TEXT"),
            ("utterance_edits", "TEXT"),
            ("summary", "TEXT"),
            ("topics", "TEXT"),
            ("utterances_data", "TEXT"),
            ("paragraphs_data", "TEXT"),
            ("speaker_overrides", "TEXT"),
            ("general_notes", "TEXT"),
            ("duration_ms", "INTEGER"),
        ]
        for col, typ in new_columns:
            await conn.execute(
                text(f"ALTER TABLE sessions ADD COLUMN IF NOT EXISTS {col} {typ}")
            )
        # usage_events se crea via create_all, pero nos aseguramos del índice
        await conn.execute(text(
            "CREATE INDEX IF NOT EXISTS ix_usage_events_uid ON usage_events (uid)"
        ))
