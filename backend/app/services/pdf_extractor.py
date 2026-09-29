"""
PDF table extraction for the "Party Profit Loss" report.

Scope (Step 3 only): read the uploaded PDF and turn its table rows into
structured records using the exact columns the client specified. No
validation rules, no bonus math, no invented fields — a row is either
extracted as-is or skipped with a reason, and every skip is reported back
rather than silently dropped.

Column order, per the client (updated for the "actual bonus feature" spec,
which adds WhatsApp Number as a required-when-available column):
    No | User Name | WhatsApp Number | Level | Casino Pts | Sport Pts |
    Third Party Pts | Profit/Loss | Ptype
"""

import io
import re
from dataclasses import dataclass, field
from typing import Callable, Dict, List, Optional

import pdfplumber

from app.schemas.report import ExtractedRecord

# Canonical field order — also the fallback column order when a page's
# header row can't be confidently detected.
CANONICAL_FIELDS = [
    "no",
    "user_name",
    "whatsapp_number",
    "level",
    "casino_pts",
    "sport_pts",
    "third_party_pts",
    "profit_loss",
    "ptype",
]

NUMERIC_FIELDS = {"casino_pts", "sport_pts", "third_party_pts", "profit_loss"}

# Recognized header text -> canonical field. Matched after normalization
# (lowercased, punctuation stripped, whitespace collapsed), so
# "Profit/Loss", "Profit Loss" and "profit  loss" all match the same key.
HEADER_ALIASES: Dict[str, str] = {
    "no": "no",
    "sno": "no",
    "s no": "no",
    "user name": "user_name",
    "username": "user_name",
    "name": "user_name",
    "whatsapp number": "whatsapp_number",
    "whatsapp no": "whatsapp_number",
    "whatsapp": "whatsapp_number",
    "mobile number": "whatsapp_number",
    "mobile no": "whatsapp_number",
    "mobile": "whatsapp_number",
    "phone number": "whatsapp_number",
    "phone no": "whatsapp_number",
    "phone": "whatsapp_number",
    "contact number": "whatsapp_number",
    "level": "level",
    "casino pts": "casino_pts",
    "casino points": "casino_pts",
    "sport pts": "sport_pts",
    "sports pts": "sport_pts",
    "sport points": "sport_pts",
    "third party pts": "third_party_pts",
    "third party points": "third_party_pts",
    "profit loss": "profit_loss",
    "profit and loss": "profit_loss",
    "p l": "profit_loss",
    "ptype": "ptype",
    "p type": "ptype",
}


class PdfExtractionError(Exception):
    """Raised when the PDF can't be read or has no extractable table data."""


@dataclass
class ExtractionResult:
    records: List[ExtractedRecord] = field(default_factory=list)
    pages_processed: int = 0
    warnings: List[str] = field(default_factory=list)


def _normalize_header_text(text: str) -> str:
    text = (text or "").strip().lower()
    text = re.sub(r"[^a-z0-9]+", " ", text)
    return re.sub(r"\s+", " ", text).strip()


def _normalize_cell(value: Optional[str]) -> str:
    if value is None:
        return ""
    return str(value).replace("\n", " ").strip()


def _is_empty_row(cells: List[str]) -> bool:
    return all(cell.strip() == "" for cell in cells)


def _detect_header_mapping(cells: List[str]) -> Optional[Dict[int, str]]:
    """
    If `cells` looks like a header row (its normalized text matches known
    column names), return {column_index: canonical_field}. Otherwise None.
    """
    mapping: Dict[int, str] = {}
    matches = 0
    for idx, raw in enumerate(cells):
        key = _normalize_header_text(raw)
        if key in HEADER_ALIASES:
            mapping[idx] = HEADER_ALIASES[key]
            matches += 1
    # Require at least 3 recognized column names before trusting it's a
    # header row, so a genuine data row doesn't get mistaken for one.
    if matches >= 3:
        return mapping
    return None


def _is_header_row(cells: List[str]) -> bool:
    return _detect_header_mapping(cells) is not None


def parse_number(raw: str) -> Optional[float]:
    """
    Parses a numeric cell, preserving sign and decimals.
    Handles: "-123.45", "1,234.56", "(123.45)" (accounting negative),
    "" / "-" / "N/A" (treated as 0.0 — a blank points/PL cell in this
    report means zero, per the client's "values can be positive, negative,
    or zero" note).
    Returns None if the cell has non-numeric content that isn't a
    recognized "blank" marker, so the caller can flag the row instead of
    guessing.
    """
    text = (raw or "").strip()
    if text in ("", "-", "--", "N/A", "n/a", "NA"):
        return 0.0

    negative = False
    if text.startswith("(") and text.endswith(")"):
        negative = True
        text = text[1:-1].strip()

    text = text.replace(",", "").replace("₹", "").replace("$", "").strip()

    if re.fullmatch(r"[+-]?\d+(\.\d+)?", text):
        value = float(text)
        return -abs(value) if negative else value

    return None


def _row_to_record(
    cells: List[str],
    mapping: Dict[int, str],
    page_number: int,
    row_index: int,
    warnings: List[str],
) -> Optional[ExtractedRecord]:
    values: Dict[str, str] = {}
    for idx, field_name in mapping.items():
        if idx < len(cells):
            values[field_name] = cells[idx]

    user_name = _normalize_cell(values.get("user_name"))
    if not user_name:
        warnings.append(
            f"Page {page_number}, row {row_index}: skipped — no user name "
            f"found (raw={cells!r})"
        )
        return None

    parsed: Dict[str, object] = {
        "user_name": user_name,
        "whatsapp_number": _normalize_cell(values.get("whatsapp_number")) or None,
        "level": _normalize_cell(values.get("level")) or None,
        "ptype": _normalize_cell(values.get("ptype")) or None,
    }

    no_raw = _normalize_cell(values.get("no"))
    if no_raw:
        try:
            parsed["no"] = int(float(no_raw))
        except ValueError:
            parsed["no"] = None
    else:
        parsed["no"] = None

    for field_name in NUMERIC_FIELDS:
        raw_value = _normalize_cell(values.get(field_name))
        number = parse_number(raw_value)
        if number is None:
            warnings.append(
                f"Page {page_number}, row {row_index}: skipped — could not "
                f"parse '{field_name}' value {raw_value!r} (raw row={cells!r})"
            )
            return None
        parsed[field_name] = number

    parsed["source_page"] = page_number
    return ExtractedRecord(**parsed)


def _extract_page_table(page: "pdfplumber.page.Page") -> Optional[List[List[Optional[str]]]]:
    """Tries the default (line-based) strategy, then falls back to a
    text-based strategy for PDFs whose tables have no visible borders."""
    table = page.extract_table()
    if table and len(table) > 1:
        return table

    table = page.extract_table(
        table_settings={
            "vertical_strategy": "text",
            "horizontal_strategy": "text",
        }
    )
    if table and len(table) > 1:
        return table

    return None


def extract_records_from_pdf(
    file_bytes: bytes,
    on_page_done: Optional[Callable[[int, int], None]] = None,
) -> ExtractionResult:
    """
    Reads every page of the PDF and returns structured records.

    `on_page_done(pages_done, total_pages)`, if given, is called after each
    page so a long-running caller can report progress; it does not affect
    what is extracted.

    Raises PdfExtractionError if the file can't be opened as a PDF, or if
    no table data could be found on any page.
    """
    if not file_bytes:
        raise PdfExtractionError("The uploaded file is empty.")

    try:
        pdf = pdfplumber.open(io.BytesIO(file_bytes))
    except Exception as exc:  # noqa: BLE001
        raise PdfExtractionError(f"Could not open file as a PDF: {exc}") from exc

    result = ExtractionResult()
    active_mapping: Optional[Dict[int, str]] = None

    try:
        with pdf:
            if len(pdf.pages) == 0:
                raise PdfExtractionError("The PDF has no pages.")

            for page_number, page in enumerate(pdf.pages, start=1):
                result.pages_processed += 1
                table = _extract_page_table(page)
                # Release this page's parsed layout so memory stays flat on
                # PDFs with many pages.
                page.flush_cache()

                if on_page_done:
                    on_page_done(page_number, len(pdf.pages))

                if table is None:
                    result.warnings.append(
                        f"Page {page_number}: no table detected — skipped."
                    )
                    continue

                for row_index, raw_row in enumerate(table, start=1):
                    cells = [_normalize_cell(c) for c in raw_row]

                    if _is_empty_row(cells):
                        continue

                    header_mapping = _detect_header_mapping(cells)
                    if header_mapping:
                        active_mapping = header_mapping
                        continue

                    mapping = active_mapping or {
                        i: name for i, name in enumerate(CANONICAL_FIELDS)
                    }

                    record = _row_to_record(
                        cells, mapping, page_number, row_index, result.warnings
                    )
                    if record:
                        result.records.append(record)
    except PdfExtractionError:
        raise
    except Exception as exc:  # noqa: BLE001
        raise PdfExtractionError(f"Failed while reading PDF content: {exc}") from exc

    if not result.records:
        raise PdfExtractionError(
            "No table rows could be extracted from this PDF. It may not "
            "contain a recognizable 'Party Profit Loss' table, or the "
            "table has no visible structure pdfplumber can detect."
        )

    return result
