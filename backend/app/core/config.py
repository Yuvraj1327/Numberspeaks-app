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

    # --- No1API (WhatsApp sending; server-side only, never sent to the app) ---
    # All four values come from the No1API dashboard: Channel -> API Details.
    # See app/services/no1api_client.py.
    NO1API_BASE_URL: str = ""  # "API URL", e.g. https://crm1.no1api.com/api/meta
    NO1API_API_KEY: str = ""  # "Access Token" (shown once by the dashboard)
    NO1API_API_VERSION: str = "v19.0"  # "API Version"
    NO1API_PHONE_NUMBER_ID: str = ""  # "Phone Number ID" of the sending number
    # Pause between two messages of a bulk run (provider rate limiting).
    NO1API_MIN_INTERVAL_SECONDS: float = 2.0
    # Most messages one bulk run may contain.
    WHATSAPP_BULK_MAX: int = 500

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


@lru_cache
def get_settings() -> Settings:
    """
    Cached settings instance.
    Using a function (instead of a module-level singleton) makes it easy
    to override settings in tests later via dependency overrides.
    """
    return Settings()
