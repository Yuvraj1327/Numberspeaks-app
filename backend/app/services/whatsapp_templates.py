"""
WhatsApp message formatting.

The client proposed this exact wording for the bonus notification:
    "Dear {Name},

    ₹{Bonus Amount} has been created to your wallet.
    Please enjoy the game!"

DEFAULT_TEMPLATE below intentionally does NOT use that "created to your
wallet" phrase. Per the client's own stated caveat, that wording should
only be used if the app actually has a wallet/credit API — and it doesn't:
nothing in this codebase credits a wallet anywhere. Saying so would tell
the user something happened that didn't, so the default here reports the
bonus amount honestly instead. The wording stays fully configurable (see
below), so switching to the client's exact phrase is a one-line env change
whenever a real wallet API exists to back it up — no code change needed.

Kept swappable two ways, so wording never requires a code change:
  1. Set WHATSAPP_MESSAGE_TEMPLATE in .env to any string using the same
     {placeholder} names as DEFAULT_TEMPLATE below.
  2. Or edit DEFAULT_TEMPLATE directly once the final wording is confirmed.
"""

import logging
from typing import Optional

from app.core.config import get_settings
from app.schemas.bonus import BonusResult

logger = logging.getLogger("numberspeaks")

# Placeholders available: user_name, level, casino_pts, sport_pts,
# third_party_pts, profit_loss, ptype, bonus_amount.
DEFAULT_TEMPLATE = (
    "Dear {user_name},\n\n"
    "Your bonus amount is ₹{bonus_amount}.\n"
    "Please enjoy the game!"
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
