"""
Aggregates all v1 endpoint routers into a single router that main.py mounts
under the /api/v1 prefix. The health endpoints are public; every other
router's endpoints require a logged-in admin (see app/core/auth.py).
"""

from fastapi import APIRouter

from app.api.v1.endpoints import bonus, db_health, exports, health, ledger, referrals, reports, settings, users, whatsapp

api_router = APIRouter()

api_router.include_router(health.router)
api_router.include_router(db_health.router)
api_router.include_router(reports.router)
api_router.include_router(bonus.router)
api_router.include_router(referrals.router)
api_router.include_router(ledger.router)
api_router.include_router(exports.router)
api_router.include_router(users.router)
api_router.include_router(settings.router)
api_router.include_router(whatsapp.router)
api_router.include_router(whatsapp.tools_router)
