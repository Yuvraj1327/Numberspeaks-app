"""
Validation for extracted "Party Profit Loss" rows — the gate between
extraction (Step 3) and bonus calculation (a later step).

This runs on the data Step 3 already extracted (and stored), and checks it
again as its own explicit, auditable stage rather than assuming extraction
got everything right. It never edits a valid value — a record either
passes as-is, or it's set aside with a clear reason and the row it came
from.

Required fields: `user_name`, `casino_pts`, `sport_pts`, `third_party_pts`,
`profit_loss`. `level` and `ptype` are recorded but not required — the
client hasn't said whether every row must have them (e.g. some report
rows may legitimately leave Ptype blank), and no such rule is invented
here. This assumption is called out in the README and is easy to tighten
once the client confirms it.
"""

from dataclasses import dataclass, field
from typing import Dict, List, Optional, Union

from app.schemas.report import ExtractedRecord
from app.schemas.validation import InvalidRecord
from app.services.pdf_extractor import HEADER_ALIASES, NUMERIC_FIELDS, _normalize_header_text, parse_number

REQUIRED_TEXT_FIELDS = ["user_name"]
REQUIRED_NUMERIC_FIELDS = sorted(NUMERIC_FIELDS)  # casino_pts, sport_pts, third_party_pts, profit_loss

RawValue = Union[str, int, float, None]


@dataclass
class ValidationResult:
    valid_records: List[ExtractedRecord] = field(default_factory=list)
    invalid_records: List[InvalidRecord] = field(default_factory=list)
    ignored_count: int = 0  # blank rows / leftover header rows — not counted as invalid


def _to_text(value: RawValue) -> str:
    if value is None:
        return ""
    return str(value).strip()


def _is_blank_row(raw: Dict[str, RawValue]) -> bool:
    return all(_to_text(v) == "" for v in raw.values())


def _is_header_remnant(raw: Dict[str, RawValue]) -> bool:
    """Catches a repeated PDF header row that slipped past extraction —
    e.g. user_name literally being the text 'User Name'."""
    name_key = _normalize_header_text(_to_text(raw.get("user_name")))
    return HEADER_ALIASES.get(name_key) == "user_name" and name_key != ""


def validate_record(raw: Dict[str, RawValue], row_reference: str) -> Optional[Union[ExtractedRecord, InvalidRecord]]:
    """
    Validates a single row.

    Returns:
        None            if the row is blank or a leftover header (ignored, not invalid)
        ExtractedRecord if every check passes
        InvalidRecord   if one or more checks fail
    """
    if _is_blank_row(raw):
        return None
    if _is_header_remnant(raw):
        return None

    issues: List[str] = []

    user_name = _to_text(raw.get("user_name"))
    if not user_name:
        issues.append("user_name is required but missing or empty")

    numeric_values: Dict[str, float] = {}
    for field_name in REQUIRED_NUMERIC_FIELDS:
        raw_value = raw.get(field_name)

        if isinstance(raw_value, (int, float)):
            numeric_values[field_name] = float(raw_value)
            continue

        text_value = _to_text(raw_value)
        if text_value == "":
            issues.append(f"{field_name} is required but missing")
            continue

        parsed = parse_number(text_value)
        if parsed is None:
            issues.append(f"{field_name} is not a valid number: {text_value!r}")
            continue

        numeric_values[field_name] = parsed

    if issues:
        public_fields = [
            "no",
            "user_name",
            "whatsapp_number",
            "level",
            *REQUIRED_NUMERIC_FIELDS,
            "ptype",
        ]
        return InvalidRecord(
            row_reference=row_reference,
            raw={f: (None if raw.get(f) is None else str(raw.get(f))) for f in public_fields},
            issues=issues,
        )

    no_value = raw.get("no")
    try:
        no_parsed = int(no_value) if no_value not in (None, "") else None
    except (TypeError, ValueError):
        no_parsed = None

    return ExtractedRecord(
        no=no_parsed,
        user_name=user_name,
        whatsapp_number=_to_text(raw.get("whatsapp_number")) or None,
        level=_to_text(raw.get("level")) or None,
        casino_pts=numeric_values["casino_pts"],
        sport_pts=numeric_values["sport_pts"],
        third_party_pts=numeric_values["third_party_pts"],
        profit_loss=numeric_values["profit_loss"],
        ptype=_to_text(raw.get("ptype")) or None,
        source_page=raw.get("source_page") if isinstance(raw.get("source_page"), int) else None,
    )


def validate_records(
    rows: List[Dict[str, RawValue]],
    row_reference_fn,
) -> ValidationResult:
    """
    Validates a list of raw rows.

    `row_reference_fn(row, index)` builds the human-readable reference used
    to trace an invalid row back to its source — different callers (PDF
    extraction vs. a stored report) have different natural references.
    """
    result = ValidationResult()

    for index, raw in enumerate(rows):
        reference = row_reference_fn(raw, index)
        outcome = validate_record(raw, reference)

        if outcome is None:
            result.ignored_count += 1
        elif isinstance(outcome, ExtractedRecord):
            result.valid_records.append(outcome)
        else:
            result.invalid_records.append(outcome)

    return result
