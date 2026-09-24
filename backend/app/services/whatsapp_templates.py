"""
WhatsApp message formatting.

The client has not provided exact wording yet, only that the message
should be "a simple bonus summary." DEFAULT_TEMPLATE below is that simple
summary — clearly a default, not approved copy, and built only from data
already sitting in a bonus_results row plus the user's name/level (nothing
invented, nothing calculated here).

Kept swappable two ways, so the client's real wording never requires a
code change:
  1. Set WHATSAPP_MESSAGE_TEMPLATE in .env to any string using the same
     {placeholder} names as DEFAULT_TEMPLATE below.
  2. Or edit DEFAULT_TEMPLATE directly once the format is confirmed.
"""

import logging
from typing import Optional

from app.core.config import get_settings
from app.schemas.bonus import BonusResult

logger = logging.getLogger("numberspeaks")

# Placeholders available: user_name, level, casino_pts, sport_pts,
# third_party_pts, profit_loss, ptype, bonus_amount.
DEFAULT_TEMPLATE = (
    "Hi {user_name},\n\n"
    "Here is your bonus summary:\n"
    "Level: {level}\n"
    "Casino Pts: {casino_pts}\n"
    "Sport Pts: {sport_pts}\n"
    "Third Party Pts: {third_party_pts}\n"
    "Profit/Loss: {profit_loss}\n"
    "Bonus Amount: {bonus_amount}\n\n"
    "Thank you."
)


def _placeholder_values(result: BonusResult) -> dict:
    def fmt(value: Optional[float]) -> str:
        return "-" if value is None else f"{value:g}"

    return {
        "user_name": result.user_name,
        "level": result.level or "-",
        "casino_pts": fmt(result.casino_pts),
        "sport_pts": fmt(result.sport_pts),
        "third_party_pts": fmt(result.third_party_pts),
        "profit_loss": fmt(result.profit_loss),
        "ptype": result.ptype or "-",
        "bonus_amount": fmt(result.bonus_amount),
    }


def build_bonus_message(result: BonusResult) -> str:
    """Renders the configured (or default) template for one user's result."""
    settings = get_settings()
    template = settings.WHATSAPP_MESSAGE_TEMPLATE.strip() or DEFAULT_TEMPLATE
    values = _placeholder_values(result)

    try:
        return template.format(**values)
    except (KeyError, IndexError, ValueError) as exc:
        logger.warning(
            "WHATSAPP_MESSAGE_TEMPLATE is invalid (%s) — falling back to the default template.",
            exc,
        )
        return DEFAULT_TEMPLATE.format(**values)
