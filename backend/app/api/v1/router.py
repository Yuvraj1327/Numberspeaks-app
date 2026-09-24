"""
Aggregates all v1 endpoint routers into a single router that main.py mounts
under the /api/v1 prefix. New endpoint modules get added here as they are
built in later steps (upload, validation, bonus, whatsapp, etc.).
"""

from fastapi import APIRouter

from app.api.v1.endpoints import bonus, db_health, health, reports, whatsapp

api_router = APIRouter()

api_router.include_router(health.router)
api_router.include_router(db_health.router)
api_router.include_router(reports.router)
api_router.include_router(bonus.router)
api_router.include_router(whatsapp.router)
