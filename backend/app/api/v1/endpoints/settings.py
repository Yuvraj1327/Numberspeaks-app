"""Bonus-rate settings (personal 3% / referral 10% by default)."""

from fastapi import APIRouter, Depends
from supabase import Client

from app.api.deps import CurrentUser, get_current_user, get_db
from app.schemas.referral import BonusSettings, BonusSettingsUpdate
from app.services.settings_service import get_bonus_settings, save_bonus_settings

router = APIRouter(prefix="/settings", tags=["Settings"])


@router.get("", response_model=BonusSettings, summary="Get this admin's bonus rates")
async def read_settings(
    current_user: CurrentUser = Depends(get_current_user),
    db: Client = Depends(get_db),
) -> BonusSettings:
    return get_bonus_settings(db, current_user.id)


@router.put("", response_model=BonusSettings, summary="Change this admin's bonus rates (fractions, 0.03 = 3%)")
async def update_settings(
    body: BonusSettingsUpdate,
    current_user: CurrentUser = Depends(get_current_user),
    db: Client = Depends(get_db),
) -> BonusSettings:
    return save_bonus_settings(db, current_user.id, body)
