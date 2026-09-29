"""
Pydantic models for the report upload / extraction API.

These mirror the client PDF's exact columns — nothing added, nothing
renamed to something friendlier, so the API output stays traceable back to
the source report.
"""

from typing import List, Optional

from pydantic import BaseModel, Field


class ExtractedRecord(BaseModel):
    """One row from the 'Party Profit Loss' table, as extracted from the PDF."""

    no: Optional[int] = Field(None, description="Row number from the 'No' column")
    user_name: str = Field(..., description="From the 'User Name' column")
    whatsapp_number: Optional[str] = Field(
        None, description="From the 'WhatsApp Number' column"
    )
    level: Optional[str] = Field(None, description="From the 'Level' column")
    casino_pts: float = Field(..., description="From the 'Casino Pts' column")
    sport_pts: float = Field(..., description="From the 'Sport Pts' column")
    third_party_pts: float = Field(..., description="From the 'Third Party Pts' column")
    profit_loss: float = Field(..., description="From the 'Profit/Loss' column")
    ptype: Optional[str] = Field(None, description="From the 'Ptype' column")

    # Which PDF page this row came from — useful for tracing extraction issues.
    source_page: Optional[int] = None


class UploadReportResponse(BaseModel):
    report_id: str
    file_name: str
    status: str
    pages_processed: int
    total_records: int
    records: List[ExtractedRecord]
    warnings: List[str] = Field(
        default_factory=list,
        description="Rows or pages that were skipped during extraction/saving, and why.",
    )
