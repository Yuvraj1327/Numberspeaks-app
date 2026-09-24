"""
Pydantic models for the validation step.

A validated record is exactly an ExtractedRecord — validation checks data,
it never changes it (no rounding, no renaming, no invented defaults). An
invalid record keeps its raw, as-extracted values alongside the specific
reasons it failed, so the affected row can always be traced back to its
source.
"""

from typing import Dict, List, Optional

from pydantic import BaseModel, Field

from app.schemas.report import ExtractedRecord


class InvalidRecord(BaseModel):
    row_reference: str = Field(
        ..., description="Where this row came from, e.g. 'page 3, row 5' or a stored record id."
    )
    raw: Dict[str, Optional[str]] = Field(
        ..., description="The row's original field values, unmodified."
    )
    issues: List[str] = Field(..., description="One entry per problem found with this row.")


class ValidationSummary(BaseModel):
    report_id: str
    status: str
    total_input_records: int
    valid_count: int
    invalid_count: int
    valid_records: List[ExtractedRecord]
    invalid_records: List[InvalidRecord]
