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

from app.api.v1.router import api_router
from app.core.config import get_settings

settings = get_settings()

# Root stays at INFO so third-party libraries never emit DEBUG noise; only the
# application logger honours the DEBUG setting.
logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s | %(levelname)s | %(name)s | %(message)s",
)
logger = logging.getLogger("numberspeaks")
logger.setLevel(logging.DEBUG if settings.DEBUG else logging.INFO)

# PDF parsing libraries log every token/operator at DEBUG (and may include
# document content), so keep them at WARNING regardless of settings.
for _noisy in ("pdfminer", "pdfplumber", "PIL"):
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
    logger.warning(
        "Validation error on %s: %s",
        request.url.path,
        [(e.get("loc"), e.get("msg")) for e in exc.errors()],
    )
    return JSONResponse(
        status_code=status.HTTP_422_UNPROCESSABLE_ENTITY,
        content={
            "success": False,
            "error": "Validation error",
            "details": exc.errors(),
        },
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
