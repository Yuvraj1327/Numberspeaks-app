"""
Application configuration.

All configuration values are loaded from environment variables (via a .env
file during local development, or real environment variables on Railway).
Nothing here should ever contain a hardcoded secret.
"""

from functools import lru_cache
from typing import List

from pydantic_settings import BaseSettings, SettingsConfigDict


class Settings(BaseSettings):
    # --- General ---
    APP_NAME: str = "Numberspeaks API"
    ENVIRONMENT: str = "development"  # development | staging | production
    DEBUG: bool = False  # set DEBUG=true locally only; never in production

    # --- Server ---
    # Railway injects PORT at runtime. Default is for local development only.
    PORT: int = 8000

    # --- CORS ---
    # Comma-separated list of allowed origins, e.g.
    # "http://localhost:3000,https://app.numberspeaks.com"
    # Use "*" to allow all origins (fine for early development).
    CORS_ORIGINS: str = "*"

    # --- Supabase ---
    # SUPABASE_URL: the project URL, e.g. https://xxxxx.supabase.co
    # SUPABASE_KEY: the *service role* key (server-side only — this backend
    # is a trusted server, never expose this key to the Flutter app).
    SUPABASE_URL: str = ""
    SUPABASE_KEY: str = ""

    # --- Bonus rates (defaults only) ---
    # Each admin account can override these in the app (Settings screen ->
    # stored in the bonus_settings table). These are what a brand-new
    # account starts with, as fractions (0.03 = 3%, 0.10 = 10%).
    DEFAULT_PERSONAL_RATE: float = 0.03
    DEFAULT_REFERRAL_RATE: float = 0.10

    # --- WhatsApp (legacy, NOT used by the app any more) ---
    # The backend no longer sends WhatsApp messages by itself (the admin
    # opens WhatsApp from the app via a wa.me link instead), so the
    # settings below are inert. They are kept only so an existing .env
    # keeps loading without errors.
    # Default provider was Meta's WhatsApp Cloud API (the official WhatsApp
    # Business Platform API) — no specific provider was given, and this is
    # the literal "WhatsApp API" rather than a guessed third-party one.
    # WHATSAPP_API_KEY: a permanent access token for your WhatsApp Business app.
    WHATSAPP_API_KEY: str = ""
    # WHATSAPP_PHONE_NUMBER_ID: the sending number's ID from Meta's dashboard
    # (Business Settings -> WhatsApp Accounts -> Phone numbers). Not the
    # phone number itself.
    WHATSAPP_PHONE_NUMBER_ID: str = ""
    # Base URL for the Graph API. Only change this to point at a different
    # provider/proxy, or to pin a different Graph API version.
    WHATSAPP_API_BASE_URL: str = "https://graph.facebook.com/v20.0"
    # Optional override for the message sent to each user. Leave unset to
    # use the built-in default template in app/services/whatsapp_templates.py.
    # See that file for the exact placeholder names available.
    WHATSAPP_MESSAGE_TEMPLATE: str = ""

    model_config = SettingsConfigDict(
        env_file=".env",
        env_file_encoding="utf-8",
        case_sensitive=True,
        extra="ignore",
    )

    @property
    def cors_origins_list(self) -> List[str]:
        if self.CORS_ORIGINS.strip() == "*":
            return ["*"]
        return [origin.strip() for origin in self.CORS_ORIGINS.split(",") if origin.strip()]

    @property
    def has_supabase_config(self) -> bool:
        """True once both Supabase values are set. Lets calling code fail
        with a clear message instead of a confusing client error."""
        return bool(self.SUPABASE_URL) and bool(self.SUPABASE_KEY)

    @property
    def has_whatsapp_config(self) -> bool:
        """True once both WhatsApp values are set."""
        return bool(self.WHATSAPP_API_KEY) and bool(self.WHATSAPP_PHONE_NUMBER_ID)


@lru_cache
def get_settings() -> Settings:
    """
    Cached settings instance.
    Using a function (instead of a module-level singleton) makes it easy
    to override settings in tests later via dependency overrides.
    """
    return Settings()
