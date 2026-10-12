"""Per-admin bonus rates (3% personal and 10% referral by default)."""

from datetime import datetime, timezone

from supabase import Client

from app.core.config import get_settings
from app.schemas.referral import BonusSettings, BonusSettingsUpdate


def get_bonus_settings(db: Client, owner_id: str) -> BonusSettings:
    """This admin's rates, or the configured defaults if never changed."""
    res = db.table("bonus_settings").select("*").eq("owner_id", owner_id).limit(1).execute()
    if res.data:
        row = res.data[0]
        return BonusSettings(
            personal_rate=float(row["personal_rate"]),
            referral_rate=float(row["referral_rate"]),
            whatsapp_template=row.get("whatsapp_template"),
            updated_at=row.get("updated_at"),
        )
    defaults = get_settings()
    return BonusSettings(
        personal_rate=defaults.DEFAULT_PERSONAL_RATE,
        referral_rate=defaults.DEFAULT_REFERRAL_RATE,
    )


def save_bonus_settings(db: Client, owner_id: str, update: BonusSettingsUpdate) -> BonusSettings:
    current = get_bonus_settings(db, owner_id)
    personal = current.personal_rate if update.personal_rate is None else update.personal_rate
    referral = current.referral_rate if update.referral_rate is None else update.referral_rate
    template = current.whatsapp_template
    if update.whatsapp_template is not None:
        template = update.whatsapp_template.strip() or None  # empty = back to the built-in default
    now = datetime.now(timezone.utc).isoformat()
    db.table("bonus_settings").upsert(
        {
            "owner_id": owner_id,
            "personal_rate": personal,
            "referral_rate": referral,
            "whatsapp_template": template,
            "updated_at": now,
        },
        on_conflict="owner_id",
    ).execute()
    return BonusSettings(personal_rate=personal, referral_rate=referral, whatsapp_template=template, updated_at=now)
