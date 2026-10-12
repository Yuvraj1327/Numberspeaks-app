"""
Casino-user management endpoints.

These users are the bonus recipients listed in the weekly report — they
never log in. The admin saves each user's WhatsApp number here (permanently)
and can review a user's full calculation history. Scoped to the logged-in
admin on every call.
"""

from typing import List, Optional

from fastapi import APIRouter, Depends, HTTPException, Query, status
from supabase import Client

from app.api.deps import CurrentUser, get_current_user, get_db
from app.schemas.users import UserHistory, UserProfile, UserUpdate
from app.services.users_service import (
    get_history,
    get_user,
    list_users,
    previous_balances,
    to_profile,
    update_user,
)

router = APIRouter(prefix="/users", tags=["Users"])


def _user_or_404(db: Client, owner_id: str, user_id: str) -> dict:
    user = get_user(db, owner_id, user_id)
    if user is None:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail=f"No user found with id {user_id}")
    return user


@router.get("", response_model=List[UserProfile], summary="List this admin's casino users")
def list_my_users(
    q: Optional[str] = Query(None, description="Search by User ID / Name"),
    current_user: CurrentUser = Depends(get_current_user),
    db: Client = Depends(get_db),
) -> List[UserProfile]:
    return [to_profile(u) for u in list_users(db, current_user.id, q)]


@router.get("/{user_id}", response_model=UserProfile, summary="Get one user, with their latest carried-forward balance")
def get_one_user(
    user_id: str,
    current_user: CurrentUser = Depends(get_current_user),
    db: Client = Depends(get_db),
) -> UserProfile:
    user = _user_or_404(db, current_user.id, user_id)
    carry = previous_balances(db, current_user.id, needed_user_ids={user_id}).get(user_id)
    return to_profile(user, carry)


@router.patch("/{user_id}", response_model=UserProfile, summary="Edit a user's name, level or WhatsApp number")
def update_one_user(
    user_id: str,
    body: UserUpdate,
    current_user: CurrentUser = Depends(get_current_user),
    db: Client = Depends(get_db),
) -> UserProfile:
    user = update_user(db, current_user.id, user_id, body.model_dump(exclude_unset=True))
    return to_profile(user)


@router.get("/{user_id}/history", response_model=UserHistory, summary="A user's full bonus calculation history")
def get_user_history(
    user_id: str,
    current_user: CurrentUser = Depends(get_current_user),
    db: Client = Depends(get_db),
) -> UserHistory:
    user = _user_or_404(db, current_user.id, user_id)
    carry = previous_balances(db, current_user.id, needed_user_ids={user_id}).get(user_id)
    return UserHistory(user=to_profile(user, carry), history=get_history(db, current_user.id, user_id))
