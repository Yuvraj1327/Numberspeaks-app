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
    DEBUG: bool = True

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

    # --- Report processing ---
    # Largest PDF accepted by POST /reports/upload.
    MAX_UPLOAD_MB: int = 50
    # How many reports are processed at the same time in this process; the
    # rest wait their turn (status stays "uploaded"). Keeps memory bounded
    # when many users upload at once.
    MAX_CONCURRENT_REPORT_JOBS: int = 2
    # Rows per bulk Supabase insert/upsert request.
    DB_BATCH_SIZE: int = 500
    # A report that has been in a processing state this long without any
    # progress is treated as abandoned (e.g. the server restarted mid-job)
    # and is picked up again the next time its status is requested.
    PROCESSING_STALE_SECONDS: int = 600

    # --- WhatsApp ---
    # Default provider is Meta's WhatsApp Cloud API (the official WhatsApp
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
