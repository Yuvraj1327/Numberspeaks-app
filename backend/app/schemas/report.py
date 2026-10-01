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
    """
    Returned by POST /reports/upload as soon as the file is stored.
    Extraction happens in the background, so pages_processed/total_records/
    records are empty here — poll GET /reports/{report_id}/status, then read
    GET /reports/{report_id}/results.
    """

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


class ReportStatusResponse(BaseModel):
    """
    Progress of a report being processed in the background — what the
    client polls after upload.

    status: uploaded -> processing -> validating -> calculating ->
    completed | failed. ('validated' only appears on reports driven
    through the manual /validate + /calculate-bonus endpoints.)
    """

    report_id: str
    file_name: str
    status: str
    is_final: bool = Field(
        description="True once status is 'completed' or 'failed' — stop polling."
    )
    pages_processed: int = 0
    total_records: int = Field(0, description="Rows saved from the PDF.")
    calculated_count: int = 0
    failed_count: int = Field(0, description="Rows that failed validation or calculation.")
    error_message: Optional[str] = Field(None, description="Why the report failed, if it did.")
    warnings: List[str] = Field(default_factory=list)
    uploaded_at: Optional[str] = None
    updated_at: Optional[str] = None


class ReportListItem(BaseModel):
    """One report in GET /reports — the signed-in account's own uploads."""

    report_id: str
    file_name: str
    status: str
    total_records: int = 0
    calculated_count: int = 0
    failed_count: int = 0
    uploaded_at: Optional[str] = None
    updated_at: Optional[str] = None
