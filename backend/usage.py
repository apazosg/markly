from datetime import datetime, timezone

from fastapi import APIRouter, Depends, HTTPException
from sqlalchemy import func, select
from sqlalchemy.ext.asyncio import AsyncSession

from auth import verified_user
from config import settings
from database import get_db, SessionLocal
from models import UsageEvent

router = APIRouter(prefix="/usage", tags=["usage"])


# ── Registro interno ──────────────────────────────────────────────────────────

def _credits_from_cost(cost_eur: float) -> float:
    return round(cost_eur * settings.credit_markup, 6)


async def record_deepgram(uid: str, session_id: str, duration_s: float) -> None:
    cost = (duration_s / 60) * settings.deepgram_rate_eur_per_min
    async with SessionLocal() as db:
        db.add(UsageEvent(
            uid=uid,
            session_id=session_id,
            event_type="deepgram",
            raw_amount=duration_s,
            cost_eur=cost,
            credits=_credits_from_cost(cost),
        ))
        await db.commit()


async def record_gemini(uid: str, session_id: str, input_tokens: int, output_tokens: int) -> None:
    cost = (
        input_tokens / 1_000_000 * settings.gemini_input_rate_eur_per_1m
        + output_tokens / 1_000_000 * settings.gemini_output_rate_eur_per_1m
    )
    async with SessionLocal() as db:
        db.add(UsageEvent(
            uid=uid,
            session_id=session_id,
            event_type="gemini",
            raw_amount=input_tokens + output_tokens,
            cost_eur=cost,
            credits=_credits_from_cost(cost),
        ))
        await db.commit()


# ── Guard de créditos ─────────────────────────────────────────────────────────

async def assert_credits_available(uid: str, db: AsyncSession, email: str = "") -> None:
    """Lanza 402 si el usuario ha agotado su cuota mensual."""
    unlimited = {e.strip().lower() for e in settings.unlimited_emails.split(",") if e.strip()}
    if email.lower() in unlimited:
        return

    now = datetime.now(timezone.utc)
    current_month = now.strftime("%Y-%m")
    row = await db.execute(
        select(func.sum(UsageEvent.credits))
        .where(
            UsageEvent.uid == uid,
            func.to_char(UsageEvent.created_at, "YYYY-MM") == current_month,
        )
    )
    used = row.scalar() or 0.0
    if used >= settings.free_credits_per_month:
        raise HTTPException(
            status_code=402,
            detail=f"Límite mensual alcanzado ({settings.free_credits_per_month:.0f} créditos). "
                   "Recarga tu cuenta para continuar.",
        )


# ── Endpoints ─────────────────────────────────────────────────────────────────

def _approx_minutes_per_credit() -> float:
    """Minutos de audio que cubre 1 crédito (solo coste Deepgram, mayoritario)."""
    eur_per_min = settings.deepgram_rate_eur_per_min * settings.credit_markup
    return round(1.0 / eur_per_min, 1) if eur_per_min > 0 else 0


@router.get("/summary")
async def usage_summary(
    user: dict = Depends(verified_user),
    db: AsyncSession = Depends(get_db),
):
    uid = user["uid"]
    now = datetime.now(timezone.utc)

    # Últimos 6 meses + mes actual
    rows = await db.execute(
        select(
            func.to_char(UsageEvent.created_at, "YYYY-MM").label("month"),
            UsageEvent.event_type,
            func.sum(UsageEvent.credits).label("credits"),
        )
        .where(UsageEvent.uid == uid)
        .group_by("month", UsageEvent.event_type)
        .order_by("month")
    )

    by_month: dict[str, dict] = {}
    for row in rows:
        m = row.month
        if m not in by_month:
            by_month[m] = {"month": m, "total": 0.0, "deepgram": 0.0, "gemini": 0.0}
        by_month[m][row.event_type] = round(row.credits, 4)
        by_month[m]["total"] = round(by_month[m]["total"] + row.credits, 4)

    current_month = now.strftime("%Y-%m")
    current_used = by_month.get(current_month, {}).get("total", 0.0)
    free = settings.free_credits_per_month
    return {
        "current_month": current_month,
        "months": list(by_month.values()),
        "approx_minutes_per_credit": _approx_minutes_per_credit(),
        "free_credits_per_month": free,
        "credits_used_this_month": round(current_used, 2),
        "credits_remaining": round(max(0.0, free - current_used), 2),
    }
