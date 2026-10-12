"""
Numberspeaks API — application entry point.

This file only wires things together (app instance, middleware, routers,
error handlers). Business logic lives in its own modules, added in later
steps.
"""

import logging

from fastapi import FastAPI, Request, status
from fastapi.exceptions import RequestValidationError
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import JSONResponse
from postgrest.exceptions import APIError

from app.api.v1.router import api_router
from app.core.config import get_settings
from app.services.reports_service import safe_error

settings = get_settings()

logging.basicConfig(
    level=logging.INFO if not settings.DEBUG else logging.DEBUG,
    format="%(asctime)s | %(levelname)s | %(name)s | %(message)s",
)
logger = logging.getLogger("numberspeaks")

# Third-party HTTP stacks log request/response headers and bodies at DEBUG
# (httpcore, hpack, h2 ...) — including the Supabase service-role key and
# bearer tokens — and flood the log. Keep them quiet whatever DEBUG is.
for _noisy in (
    "httpx", "httpcore", "hpack", "h2", "hyperframe", "urllib3",
    "postgrest", "storage3", "supabase", "supabase_functions", "gotrue", "realtime", "websockets",
):
    logging.getLogger(_noisy).setLevel(logging.WARNING)

app = FastAPI(
    title=settings.APP_NAME,
    description="Backend API for Numberspeaks — bonus calculation from Party Profit Loss reports.",
    version="0.1.0",
    docs_url="/docs",
    redoc_url="/redoc",
)

# --- CORS -------------------------------------------------------------
# Allows the Flutter app (web/mobile) to call this API once it exists.
app.add_middleware(
    CORSMiddleware,
    allow_origins=settings.cors_origins_list,
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)

# --- Routers ------------------------------------------------------------
app.include_router(api_router, prefix="/api/v1")


# --- Global error handling ----------------------------------------------
@app.exception_handler(RequestValidationError)
async def validation_exception_handler(request: Request, exc: RequestValidationError):
    """Turns FastAPI's default validation error into a consistent shape."""
    # Only where and why — never `input`, which holds the request body.
    problems = [(".".join(str(p) for p in err.get("loc", ())), err.get("type")) for err in exc.errors()]
    logger.warning("Validation error on %s: %s", request.url.path, problems)
    return JSONResponse(
        status_code=status.HTTP_422_UNPROCESSABLE_ENTITY,
        content={
            "success": False,
            "error": "Validation error",
            "details": [{k: v for k, v in err.items() if k not in ("input", "ctx")} for err in exc.errors()],
        },
    )


@app.exception_handler(APIError)
async def database_error_handler(request: Request, exc: APIError):
    """A failed Supabase/PostgREST call. The details go to the log only —
    raw database error text is never sent to the client."""
    logger.error("Database error on %s: %s", request.url.path, safe_error(exc))
    return JSONResponse(
        status_code=status.HTTP_503_SERVICE_UNAVAILABLE,
        content={"detail": "The database request failed. Please try again."},
    )


@app.exception_handler(Exception)
async def unhandled_exception_handler(request: Request, exc: Exception):
    """
    Catch-all for anything unexpected so the client always gets a clean
    JSON response instead of a raw stack trace or a hung connection.
    """
    logger.exception("Unhandled error on %s", request.url.path)
    return JSONResponse(
        status_code=status.HTTP_500_INTERNAL_SERVER_ERROR,
        content={
            "success": False,
            "error": "Internal server error",
        },
    )


# --- Root -----------------------------------------------------------------
@app.get("/", tags=["Root"], summary="Root")
def root() -> dict:
    return {
        "service": "numberspeaks-api",
        "status": "running",
        "docs": "/docs",
        "health": "/api/v1/health",
    }


if __name__ == "__main__":
    # Local development entry point.
    # On Railway, the Procfile/railway.json starts the app instead of this
    # block, but both paths honor the PORT environment variable.
    import uvicorn

    uvicorn.run("app.main:app", host="0.0.0.0", port=settings.PORT, reload=settings.DEBUG)
