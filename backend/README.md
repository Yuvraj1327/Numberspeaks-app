# Numberspeaks API

Backend for **Numberspeaks** — a bonus calculation app.

Completed so far:
- **Step 1:** FastAPI foundation (health check, config, CORS, error handling, Railway readiness).
- **Step 2:** Supabase database — schema, connection layer, and connectivity checks.
- **Step 3:** PDF report upload — extracts the "Party Profit Loss" table from every page and stores the results.
- **Step 4:** Validation — re-checks extracted rows before they're used for bonus calculation.
- **Steps 5-6:** Bonus calculation & results APIs — the full pipeline is wired up; only the client's exact formula is still pending.
- **Step 7:** WhatsApp integration — sends each user's calculated bonus to their WhatsApp number, with per-message success/failure tracking and accidental-resend protection.
- **Actual Bonus Feature:** the client's real bonus formula, the PDF's WhatsApp Number column, durable calculation/WhatsApp status tracking, and the full Admin → PDF → Bonus → WhatsApp flow. See "[Actual Bonus Feature](#actual-bonus-feature-client-confirmed-formula--flow)" below.

The exact WhatsApp provider credentials are still the client's own to supply (see Step 7's section below) — everything else the client had left open is now implemented per their confirmed spec.

## Project structure

```
numberspeaks-backend/
├── app/
│   ├── main.py                     # App entry point: FastAPI instance, CORS, error handlers
│   ├── core/
│   │   └── config.py                # Environment-based settings (Settings class)
│   ├── db/
│   │   └── supabase_client.py       # The ONLY place the Supabase client is created
│   ├── schemas/
│   │   ├── report.py                # ExtractedRecord / UploadReportResponse models
│   │   ├── validation.py            # InvalidRecord / ValidationSummary models
│   │   ├── bonus.py                 # BonusResult / BonusCalculationSummary models
│   │   └── whatsapp.py              # WhatsAppMessageResult / WhatsAppSendSummary models
│   ├── services/
│   │   ├── pdf_extractor.py         # Turns PDF pages into structured records
│   │   ├── reports_service.py       # All Supabase reads/writes for reports & results
│   │   ├── validation.py            # Checks extracted rows before bonus calculation
│   │   ├── bonus_calculator.py      # The client's real formula: 3% of a loss, else 0
│   │   ├── bonus_service.py         # Orchestrates validate -> calculate -> save per user
│   │   ├── whatsapp_templates.py    # Builds the message text (configurable)
│   │   ├── whatsapp_client.py       # Talks to the WhatsApp provider (Meta Cloud API)
│   │   └── whatsapp_service.py      # Orchestrates send -> record, with idempotency
│   └── api/
│       └── v1/
│           ├── router.py            # Combines all v1 endpoint routers
│           └── endpoints/
│               ├── health.py        # GET /api/v1/health
│               ├── db_health.py     # GET /api/v1/health/db
│               ├── reports.py       # POST /api/v1/reports/upload
│               │                    # POST /api/v1/reports/{report_id}/validate
│               ├── bonus.py         # POST /api/v1/reports/{report_id}/calculate-bonus
│               │                    # GET  /api/v1/reports/{report_id}/results
│               │                    # GET  /api/v1/reports/{report_id}/results/{user_id}
│               └── whatsapp.py      # POST /api/v1/reports/{report_id}/send-whatsapp
├── supabase/
│   ├── schema.sql                   # Database schema — run in Supabase SQL Editor
│   ├── storage_setup.sql            # Creates the 'reports' storage bucket
│   └── whatsapp_schema.sql          # Creates the 'whatsapp_messages' table
├── scripts/
│   └── test_supabase_connection.py  # One-off insert + read verification script
├── requirements.txt                 # Python dependencies
├── .env.example                     # Template for local environment variables
├── .gitignore
├── Procfile                         # Railway/Heroku-style start command
├── railway.json                     # Railway build/deploy configuration
└── README.md
```

### What the important files do

- **`app/main.py`** — Creates the FastAPI app, turns on CORS (so the Flutter
  app can call this API later), registers the `/api/v1` routes, and adds
  global error handlers so any unexpected error returns clean JSON instead
  of crashing or leaking a stack trace.
- **`app/core/config.py`** — Reads all configuration (port, CORS origins,
  Supabase and WhatsApp keys) from environment variables / `.env`. No
  secrets are hardcoded anywhere in the code.
- **`app/db/supabase_client.py`** — The single place that builds the Supabase
  client. Every future module (PDF processing, bonus calculation, WhatsApp)
  will import `get_supabase()` from here instead of creating its own
  connection, so configuration and error handling stay in one place. If
  `SUPABASE_URL` / `SUPABASE_KEY` aren't set, it fails with a clear error
  instead of a confusing one deep inside a request.
- **`app/api/v1/endpoints/health.py`** — Plain health check with zero
  dependencies; proves the API process itself is alive.
- **`app/api/v1/endpoints/db_health.py`** — Proves the API can actually reach
  Supabase (a lightweight read, no test data written).
- **`app/api/v1/router.py`** — Where every new feature's routes get plugged
  in as they're built.
- **`supabase/schema.sql`** — Creates the `users`, `reports`, and
  `bonus_results` tables, their relationships, indexes, and Row Level
  Security. Run this once against your Supabase project.
- **`scripts/test_supabase_connection.py`** — A manual check that inserts a
  temporary row into every table, reads it back through the relationships,
  and deletes it again. Confirms the whole pipeline (connect → insert →
  read) works end-to-end.
- **`Procfile`** / **`railway.json`** — Tell Railway how to start the app,
  using the `PORT` environment variable Railway provides automatically.
- **`app/services/pdf_extractor.py`** — Reads every page of the uploaded PDF,
  ignores repeated header rows and blank rows, and converts each data row
  into an `ExtractedRecord` matching the client's exact columns. Pure
  function, no Supabase involved — it can be tested on its own.
- **`app/services/reports_service.py`** — All Supabase reads/writes for this
  feature: creating the `reports` row, uploading the PDF to Storage,
  finding-or-creating the matching `users` row, and inserting `bonus_results`
  rows. The route handler doesn't talk to Supabase directly.
- **`app/api/v1/endpoints/reports.py`** — `POST /api/v1/reports/upload` and
  `POST /api/v1/reports/{report_id}/validate`. Upload validates and extracts
  the PDF *before* touching Supabase, so a bad file fails fast and a
  database outage is reported as its own distinct error rather than looking
  like a bad upload.
- **`supabase/storage_setup.sql`** — Creates the private `reports` Storage
  bucket the uploaded PDFs are saved into.
- **`app/services/validation.py`** — Re-checks each extracted row: required
  fields present, numeric fields are real numbers, blank/leftover-header
  rows ignored. Pure function — no Supabase, easy to test on its own,
  reuses the exact same number-parsing rules as extraction so a value is
  never interpreted two different ways.
- **`app/services/bonus_calculator.py`** — **The client's bonus formula goes
  here, and only here.** Right now `calculate_bonus()` raises
  `BonusFormulaNotConfiguredError` on purpose — no formula has been
  invented or guessed. The whole rest of the pipeline (API, validation,
  saving to Supabase, results endpoints) is fully built and already calls
  this function; implementing the real formula here is the only change
  needed to make bonus calculation work.
- **`app/services/bonus_service.py`** — Orchestrates one report's
  calculation: re-validates each row, calls `calculate_bonus()` per user
  independently, saves the result, and collects per-row errors without
  stopping the rest of the report. Contains no formula logic itself.
- **`app/api/v1/endpoints/bonus.py`** — `POST /reports/{id}/calculate-bonus`,
  `GET /reports/{id}/results`, `GET /reports/{id}/results/{user_id}`.
- **`supabase/whatsapp_schema.sql`** — Creates `whatsapp_messages`, purely
  additive (no existing table changes). One row per send *attempt*, so a
  resend keeps history instead of overwriting the last attempt.
- **`app/services/whatsapp_templates.py`** — Builds the message text from a
  simple default template. Override it without touching code via
  `WHATSAPP_MESSAGE_TEMPLATE` in `.env`.
- **`app/services/whatsapp_client.py`** — The only file that talks to the
  WhatsApp provider (Meta's WhatsApp Cloud API by default). Never raises for
  an expected failure — always returns a result so a caller looping over
  many users doesn't need per-call error handling.
- **`app/services/whatsapp_service.py`** — Orchestrates one report's send:
  checks each user has a number, skips anyone already successfully
  notified (unless `force=true`), calls the client, and records every
  attempt. Contains no bonus-calculation logic — it only reads an
  already-calculated `bonus_amount`.
- **`app/api/v1/endpoints/whatsapp.py`** —
  `POST /reports/{id}/send-whatsapp`.

## Database structure (Step 2)

Three tables, matching the columns in the client's "Party Profit Loss" PDF:

**`users`** — a person listed in the report, who can receive a bonus.
| Column | Type | Notes |
|---|---|---|
| `id` | uuid, PK | |
| `name` | text | from "User Name" |
| `level` | text | from "Level" |
| `whatsapp_number` | text | used later to send the bonus summary |
| `is_active` | boolean | default `true` |
| `created_at` | timestamptz | default `now()` |

**`reports`** — one row per uploaded PDF.
| Column | Type | Notes |
|---|---|---|
| `id` | uuid, PK | |
| `file_name` | text | |
| `file_path` | text | |
| `status` | text | `uploaded` / `processing` / `validated` / `completed` / `failed` |
| `uploaded_at` | timestamptz | default `now()` |

**`bonus_results`** — one row per user, per report.
| Column | Type | Notes |
|---|---|---|
| `id` | uuid, PK | |
| `report_id` | uuid, FK → `reports.id` | `ON DELETE CASCADE` |
| `user_id` | uuid, FK → `users.id` | `ON DELETE RESTRICT` |
| `casino_pts` | numeric | from "Casino Pts" |
| `sport_pts` | numeric | from "Sport Pts" |
| `third_party_pts` | numeric | from "Third Party Pts" |
| `profit_loss` | numeric | from "Profit/Loss" |
| `ptype` | text | from "Ptype" |
| `bonus_amount` | numeric, nullable | filled in once the bonus formula (Step 4+) exists; `null` = not yet calculated |
| `created_at` | timestamptz | default `now()` |

**Relationships**
```
users (1) ──< bonus_results >── (1) reports
```
Each `bonus_results` row belongs to exactly one `user` and one `report`. A
unique constraint on `(report_id, user_id)` keeps a user from appearing
twice in the same report's results. Deleting a `report` cascades to delete
its `bonus_results`; a `user` can't be deleted while bonus history for them
still exists (`ON DELETE RESTRICT`), to protect financial records.

**Row Level Security** is enabled on all three tables with no public
policies — only the backend's service-role key can read/write them
directly.

**Authorized access:** the `users` table above is for report *subjects*
(bonus recipients), not app logins. Login/authorization for the staff who
upload reports is intentionally left to Supabase's built-in Auth in a later
step, rather than a custom table — per the "keep it simple" requirement, no
separate roles/permissions system has been built yet.

## PDF upload & extraction (Step 3)

### Endpoint

```
POST /api/v1/reports/upload
Content-Type: multipart/form-data
Field: file  (a .pdf file, content-type application/pdf)
```

**What it does, in order:**
1. Rejects anything that isn't a PDF (`400`).
2. Extracts the table from every page — no Supabase involved yet, so a bad
   or unreadable PDF fails fast (`422`) without creating any database
   record.
3. Connects to Supabase (`503` with a clear message if not configured).
4. Creates a `reports` row and uploads the original PDF to Supabase
   Storage (bucket `reports`).
5. For each extracted row: finds or creates the matching `users` row (by
   name), then inserts a `bonus_results` row with the extracted figures
   (`bonus_amount` left `null` — no formula exists yet).
6. Sets the report's status to `processing` and returns everything that
   was extracted.

**Extraction behavior:**
- Reads all pages present in the PDF (not hardcoded to 8).
- A page's header row is detected by matching column names (e.g. "User
  Name", "Profit/Loss") and is skipped on every page it repeats on.
- Fully blank rows are skipped.
- Numbers keep their sign and decimals; comma thousands-separators and
  accounting-style negatives like `(123.45)` are handled; a blank
  points/P&L cell is treated as `0`.
- Any row that can't be parsed (e.g. a genuinely garbled cell) is skipped
  and listed in the response's `warnings` array with the page number and
  reason — never silently dropped, and never guessed at.

### Example response shape

```json
{
  "report_id": "b3b6a5b0-...",
  "file_name": "party_profit_loss.pdf",
  "status": "processing",
  "pages_processed": 8,
  "total_records": 20,
  "records": [
    {
      "no": 1,
      "user_name": "Rahul Sharma",
      "level": "Master",
      "casino_pts": 120.5,
      "sport_pts": -30.0,
      "third_party_pts": 0.0,
      "profit_loss": 500.75,
      "ptype": "User",
      "source_page": 1
    }
  ],
  "warnings": []
}
```

### Testing

I don't have the client's actual PDF yet, so I validated the extraction
logic against a synthetic multi-page PDF built specifically to exercise the
tricky cases: a repeated header on every page, a fully blank row, negative
values (both `-45.25` and accounting-style `(75.00)`), decimals, and
comma-formatted thousands. Result: all 8 pages processed, all repeated
headers correctly ignored, the blank row skipped, and every value —
including negatives and decimals — extracted exactly. Malformed/non-PDF
uploads were also tested and correctly rejected at the right stage (`400`
for wrong file type, `422` for a file that isn't a readable PDF, `503` if
Supabase isn't reachable).

**This is not a substitute for testing against the real report.** Once you
share the actual "Party Profit Loss" PDF, run it through
`POST /api/v1/reports/upload` (e.g. via `/docs` or `curl -F
"file=@party_profit_loss.pdf;type=application/pdf"
http://localhost:8000/api/v1/reports/upload`) so the column-detection and
number-parsing can be checked — and adjusted if needed — against its real
layout.

### Storage bucket setup

Run `supabase/storage_setup.sql` in the Supabase SQL Editor (once, after
`schema.sql`) to create the private `reports` bucket that uploaded PDFs are
stored in. Equivalent to creating a bucket named `reports` with "Public"
turned off via the dashboard.

## Validation (Step 4)

### Endpoint

```
POST /api/v1/reports/{report_id}/validate
```

### Validation flow

```
reports.upload (Step 3)
        │
        ▼
 bonus_results rows already saved for this report_id
        │
        ▼
 GET each row + its linked user (name, level)     [get_bonus_results_for_report]
        │
        ▼
 reshape into the report's 8 columns                [_bonus_result_row_to_raw]
        │
        ▼
 for each row:
   ├─ blank row?              → ignored (not counted invalid)
   ├─ leftover header row?    → ignored (not counted invalid)
   ├─ user_name missing?      → invalid: "user_name is required but missing or empty"
   ├─ a numeric field missing?→ invalid: "<field> is required but missing"
   ├─ a numeric field         → invalid: "<field> is not a valid number: '<value>'"
   │  not parseable as a
   │  number?
   └─ otherwise               → valid (value unchanged — sign/decimals preserved)
        │
        ▼
 report.status = "validated"  if at least one valid record
                 "failed"     if zero valid records (or nothing to validate)
        │
        ▼
 response: valid_records (ready for bonus calc) + invalid_records (with reasons) + counts
```

Required fields: `user_name`, `casino_pts`, `sport_pts`, `third_party_pts`,
`profit_loss`. `level` and `ptype` are recorded but **not** required — the
client hasn't specified whether every row must carry them, and no such rule
has been invented. This is the one assumption made in Step 4; it's easy to
tighten once confirmed.

A validated value is never altered — no rounding, no defaulting, no
renaming. A row either passes exactly as extracted, or it's set aside with
the specific reason(s) it failed, always traceable back to its source row.

### Example valid record

```json
{
  "no": null,
  "user_name": "Priya Singh",
  "level": "Super Master",
  "casino_pts": -45.25,
  "sport_pts": 1250.0,
  "third_party_pts": 5.0,
  "profit_loss": -120.0,
  "ptype": null,
  "source_page": null
}
```
(`level`/`ptype` here are `null` because that input row left them blank —
still valid, since they aren't required. Negative and comma-formatted
values pass through exactly.)

### Example invalid record

```json
{
  "row_reference": "test row 7 (user='Sana Khan')",
  "raw": {
    "no": "7",
    "user_name": "Sana Khan",
    "level": "Level 1",
    "casino_pts": null,
    "sport_pts": "abc",
    "third_party_pts": "0",
    "profit_loss": "15",
    "ptype": "User"
  },
  "issues": [
    "casino_pts is required but missing",
    "sport_pts is not a valid number: 'abc'"
  ]
}
```

### Test result

Still no client PDF, so — same approach as Step 3 — I unit-tested
`validate_records` directly against 7 hand-built rows designed to hit
every rule: a clean row, a row with legitimately blank `level`/`ptype` plus
accounting-negative and comma-formatted numbers, a fully blank row, a
leftover repeated-header row, a row with a missing name, a row with a
garbage value in a numeric field, and a row missing one numeric field while
another has garbage.

**Result:** 7 input rows → 2 ignored (blank + header, correctly *not*
counted as invalid), 2 valid (negatives, decimals, and comma-formatted
numbers all preserved exactly), 3 invalid (each with the precise field and
reason — missing name, unparseable `casino_pts`, and the combined
missing+garbage case). I also verified the glue that reshapes a stored
Supabase row (with its joined `users` record) into the same validator
input — including a defensive case of a linked user with an empty name —
which correctly produced 2 valid / 1 invalid.

On the HTTP side: confirmed the route is registered
(`/api/v1/reports/{report_id}/validate`) and that it fails cleanly (`503`)
when Supabase isn't configured, consistent with Steps 2–3.

**Not yet tested:** an actual report_id from a real Supabase project (the
404-not-found path, and a full run against rows that came from your real
PDF via Step 3). That needs live Supabase credentials and the real report —
once both are available, upload the PDF, then call `validate` with the
returned `report_id`.

## Bonus calculation & results (Steps 5-6)

### ✅ The client's bonus formula is implemented

`app/services/bonus_calculator.py` now contains the client's confirmed
formula — see "[Actual Bonus Feature](#actual-bonus-feature-client-confirmed-formula--flow)"
below for the full explanation and examples. `is_formula_configured()`
returns `True`, and `POST /calculate-bonus` runs the real math.
`BonusFormulaNotConfiguredError` and the `501` response are kept in the
code as a safety net only — they'd fire again if `calculate_bonus()` were
ever gutted back to a placeholder, but that's not the current state.

### Calculation API

```
POST /api/v1/reports/{report_id}/calculate-bonus
```

**What it does, in order:**
1. Looks up the report (`404` if it doesn't exist).
2. Requires `report.status == "validated"` — i.e. Step 4's
   `/validate` must have been run and succeeded first. Otherwise `409
   Conflict` with a message telling you to validate first.
3. Checks the formula is configured. If not: `501 Not Implemented`,
   report status left untouched (this is a system-configuration gap, not
   a problem with this report's data).
4. For each of the report's rows, independently: re-validates it (same
   rules as Step 4 — a row that somehow became invalid since validation is
   still caught, not calculated), computes its bonus via
   `calculate_bonus()`, and saves `bonus_amount` onto its `bonus_results`
   row. One user's failure (bad data or a calculation error) is recorded
   and skipped — it never stops the rest of the report.
5. Sets `report.status` to `"completed"` if at least one bonus was
   calculated, or `"failed"` if none were.
6. Returns a summary: how many were calculated, how many failed and why,
   and the full result for each user calculated.

### Results APIs

```
GET /api/v1/reports/{report_id}/results               # every user's result for this report
GET /api/v1/reports/{report_id}/results/{user_id}      # one user's result for this report
```

Both return the input values (`casino_pts`, `sport_pts`, `third_party_pts`,
`profit_loss`, `ptype`, plus the user's `level` and `whatsapp_number`)
alongside `bonus_amount` — `bonus_amount` is `null` until calculation has
run for that report — and two status fields: `calculation_status`
(`"pending"` / `"calculated"` / `"invalid"`) and `whatsapp_status`
(`"not_sent"` / `"sent"` / `"failed"`, the latest send attempt's outcome).
Together with `user_name`, `whatsapp_number`, `profit_loss` and
`bonus_amount`, `whatsapp_status` is exactly the `User Name | WhatsApp |
Profit/Loss | Bonus | WhatsApp Status` view the admin screen needs — no
separate endpoint required. `404` if the report, or that user's result
within it, doesn't exist.

### Example response

`POST /calculate-bonus`:
```json
{
  "report_id": "b3b6a5b0-...",
  "status": "completed",
  "total_input_records": 3,
  "calculated_count": 2,
  "failed_count": 1,
  "results": [
    {
      "bonus_result_id": "b1", "report_id": "r1", "user_id": "u1",
      "user_name": "Rahul", "whatsapp_number": "919999900001", "level": "Gold",
      "casino_pts": 200.0, "sport_pts": 150.0, "third_party_pts": 50.0,
      "profit_loss": -1000.0, "ptype": "User",
      "bonus_amount": 30.0, "calculation_status": "calculated",
      "whatsapp_status": "not_sent", "created_at": "2026-01-01"
    }
  ],
  "errors": [
    {"bonus_result_id": "b3", "user_name": "", "issues": ["user_name is required but missing or empty"]}
  ]
}
```
`GET /results/{user_id}` returns one object in that same `BonusResult`
shape, and `GET /results` returns a list of them.

### Supabase result structure

Step 2's `bonus_results` table already had the input values (`casino_pts`,
`sport_pts`, `third_party_pts`, `profit_loss`, `ptype`) and a nullable
`bonus_amount` column. The Actual Bonus Feature update adds exactly one
new column on top of that, via the additive migration
`supabase/bonus_status_schema.sql` (run this once, after `schema.sql`):
`calculation_status text not null default 'pending'`, constrained to
`'pending' | 'calculated' | 'invalid'`. It exists because the real formula
always returns a number — `bonus_amount = 0` for a non-loss row is now a
valid, successfully-calculated result, not a missing one — so
`bonus_amount IS NULL` alone can no longer tell "not yet calculated" apart
from "row failed validation and was skipped." `user_name`/`level`/
`whatsapp_number` stay in `users` (all three already existed there from
Step 2), reached via the existing `user_id` foreign key rather than being
duplicated.

### Test result

Since the formula isn't available, I tested the **plumbing** — the part
that's actually shippable right now — three ways:

1. **The gate itself:** called the calculation service with the real,
   shipped (unconfigured) formula. It raised `BonusFormulaNotConfiguredError`
   immediately, before reading or writing a single row — confirmed no data
   was touched.
2. **The pipeline, with a temporary test-only formula** (10% of
   profit/loss — monkeypatched in a throwaway test script, never
   committed): ran three rows through validate → calculate → save against
   a fake in-memory Supabase client. Result: 2 calculated correctly
   (including a negative `profit_loss` producing a negative bonus,
   confirming sign is preserved), 1 correctly rejected and skipped (a
   defensive case — a linked user with an empty name) without blocking
   the other two. Confirmed the calculated amount was actually persisted
   onto the row, not just returned.
3. **HTTP layer:** confirmed all three endpoints are registered and each
   fails cleanly with `503` when Supabase isn't configured, and that
   `/docs` still renders correctly with the new schemas.

**Not yet tested:** the real formula (doesn't exist yet), the `404`/`409`
paths against a real report, and a run against your actual PDF's data —
all pending the same two things as Steps 3-4: live Supabase credentials
and the real client PDF, plus now the bonus formula itself.

## WhatsApp integration (Step 7)

### Two things weren't specified, so here's what was assumed

Your own project notes said the provider and exact message format would
come later, so this step made two deliberate defaults rather than
guessing at business rules the way the bonus formula would have been:

- **Provider — Meta's WhatsApp Cloud API.** This is the official WhatsApp
  Business Platform API, not a third-party guess. All of the
  provider-specific code lives in one file
  (`app/services/whatsapp_client.py`); switching providers later (Twilio,
  Gupshup, etc.) means rewriting that one file only.
- **Message wording — close to your proposal, with one deliberate change.**
  You proposed *"₹{Bonus Amount} has been created to your wallet."* This
  app has no wallet or credit API anywhere — nothing here actually credits
  a wallet — so saying that would tell the user something happened that
  didn't. Per your own stated caveat ("only say it if there's a real
  wallet API; otherwise store/display the amount and keep the wording
  configurable"), the default template instead says *"Your bonus amount
  is ₹{amount}."* — see the example below. It's isolated in
  `app/services/whatsapp_templates.py`, and can be overridden entirely via
  the `WHATSAPP_MESSAGE_TEMPLATE` environment variable — switching to your
  exact wording (once/if a real wallet API exists) is a one-line env
  change, no code change needed.

### WhatsApp service structure

```
app/services/
├── whatsapp_templates.py   # builds the message text (pure, no I/O)
├── whatsapp_client.py      # talks to Meta's Cloud API (pure I/O, no DB)
└── whatsapp_service.py     # orchestrates: eligibility -> idempotency check
                             # -> template -> client -> record to Supabase
```
Deliberately separate from `bonus_calculator.py` / `bonus_service.py` —
this code only ever *reads* an already-calculated `bonus_amount`, it never
computes or changes one.

### Flow

```
POST /reports/{report_id}/send-whatsapp?force=false
        │
        ▼
 report must have status == "completed" (Steps 5-6 already ran)   [409 otherwise]
        │
        ▼
 for each bonus_results row with a non-null bonus_amount:
   ├─ bonus_amount <= 0 (no loss -> no bonus)? → skipped_no_bonus
   ├─ user has no whatsapp_number?           → skipped_no_number
   ├─ already has a "sent" message            → skipped_already_sent
   │  for this row, and force=false?            (force=true bypasses this)
   ├─ build the message (configurable template)
   ├─ send via whatsapp_client (Meta Cloud API)
   │    ├─ success → record status="sent" + provider_message_id
   │    └─ failure → record status="failed" + error, keep going
   └─ next user (one user's failure never stops the rest)
        │
        ▼
 response: total_eligible, sent_count, failed_count, skipped_count, per-user results
```
Every attempt — success or failure — is written to `whatsapp_messages` as
its own row, so re-sends build history instead of erasing the last result.

### Example message (default template)

```
Dear Rahul,

Your bonus amount is ₹30.
Please enjoy the game!
```

### Success / failure response

```json
{
  "report_id": "r1",
  "total_eligible": 3,
  "sent_count": 1,
  "failed_count": 1,
  "skipped_count": 1,
  "results": [
    {
      "bonus_result_id": "b1", "user_id": "u1", "user_name": "Rahul Sharma",
      "whatsapp_number": "+919876543210", "status": "sent",
      "message": "Hi Rahul Sharma,...", "provider_message_id": "wamid.FAKE_3210"
    },
    {
      "bonus_result_id": "b2", "user_id": "u2", "user_name": "Priya Singh",
      "whatsapp_number": null, "status": "skipped_no_number",
      "error": "This user has no WhatsApp number on file."
    },
    {
      "bonus_result_id": "b3", "user_id": "u3", "user_name": "Amit Patel",
      "whatsapp_number": "+919111111111", "status": "failed",
      "error": "Simulated provider error: invalid number"
    }
  ]
}
```
Calling it again immediately (without `force=true`) would return Rahul as
`"status": "skipped_already_sent"` instead of sending a duplicate.

### Test result

No real WhatsApp credentials exist yet, and `graph.facebook.com` is outside
this environment's network access anyway, so — same honesty as every
formula-dependent step — I tested everything that's actually shippable
without a live call:

1. **Schema**, validated against a real local Postgres (not just Supabase
   syntax-checked): inserted two send attempts for the same
   `bonus_result_id` (one failed, one sent), confirmed the "most recent
   sent" query returns the right one, confirmed both attempts stay in
   history, and confirmed the foreign-key and status check constraints
   correctly reject bad data.
2. **Full pipeline**, against a fake in-memory Supabase client with
   `send_whatsapp_message` mocked (no network call): 4 rows in (one
   correctly excluded for having no calculated bonus yet) → 1 sent, 1
   failed (simulated provider error), 1 skipped (no WhatsApp number) —
   each independently, one failure never blocked the others. Re-running
   without `force` correctly skipped the already-sent user; re-running
   *with* `force=true` correctly resent it, and both attempts were
   preserved in `whatsapp_messages` rather than one overwriting the other.
3. **HTTP layer:** confirmed the route is registered and fails cleanly
   with `503` when Supabase isn't configured (checked with and without
   `force=true`), and `/docs` still renders.

**Not yet tested:** an actual send through Meta's real API (needs real
WhatsApp Business credentials), and the `404`/`409` paths against a real
report — same live-credentials gap as every other step so far.

## Background report processing

`POST /api/v1/reports/upload` no longer does the work inside the HTTP
request. It only checks the file is a PDF, stores it in Supabase Storage,
creates the `reports` row, queues the report and returns `202` with the
report id — in milliseconds, whatever the PDF's size. A client timeout can
therefore no longer be confused with a processing failure, and closing the
app never stops or fails a report.

```
POST /reports/upload  ->  202 { report_id, status: "uploaded" }
                            |
                            v   (background worker, app/services/report_processor.py)
uploaded -> processing   download PDF, extract every page, save users + bonus_results in bulk
         -> validating   read rows back, run the existing validation
         -> calculating  existing 3%-of-a-loss formula, saved in bulk
         -> completed | failed

GET /reports/{id}/status   -> { status, is_final, pages_processed, total_records,
                                calculated_count, failed_count, error_message, warnings, ... }
GET /reports/{id}/results  -> the per-user rows (once status is "completed")
```

Poll `/status` every couple of seconds until `is_final` is `true`. A
`failed` report carries a user-safe `error_message`.

- **Bulk database work.** Users are looked up 100 names per request, new
  users are inserted and changed users updated in batches, and
  `bonus_results` are saved and updated in batches of `DB_BATCH_SIZE` (500).
  For the client's 174-user report that is about 17 Supabase requests
  instead of 872. If a batch is rejected it is retried row by row, so one
  bad row costs only itself.
- **No duplicate processing.** A worker must first claim the report with an
  atomic compare-and-swap on `(status, attempts)`; a second upload
  handler, worker or retry loses and does nothing. The legacy
  `/validate` and `/calculate-bonus` endpoints answer `409` while a
  background job owns the report.
- **Bounded load.** At most `MAX_CONCURRENT_REPORT_JOBS` (2) reports are
  processed at once per instance; the rest wait as `uploaded`. PDF pages
  are released as they are read, and results are read in pages of 1000
  (Supabase never returns more per request).
- **Restart safety.** Every stage updates the report row
  (`reports.updated_at`). A report that has not changed for
  `PROCESSING_STALE_SECONDS` (600) is presumed abandoned (e.g. a deploy
  restarted the server mid-job) and is resumed the next time its status is
  requested — at most 3 attempts, then it is marked `failed`.
- **Logging.** Logs contain report ids, counts, timings and error types
  only — never PDF contents, names, phone numbers or amounts.

Tests: `venv/bin/python -m unittest tests.test_report_pipeline -v` (runs the
whole pipeline against an in-memory Supabase fake, including the client's
PDF if it is at `~/Downloads/Party Profit Loss (1).pdf` or `CLIENT_PDF`).

## Local setup

### 1. Create and activate a virtual environment

```bash
python3 -m venv venv
source venv/bin/activate        # Windows: venv\Scripts\activate
```

### 2. Install dependencies

```bash
pip install -r requirements.txt
```

### 3. Create the Supabase project and tables

1. Create a project at [supabase.com](https://supabase.com).
2. Open **SQL Editor** in the Supabase dashboard, paste the contents of
   `supabase/schema.sql`, and run it. This creates `users`, `reports`, and
   `bonus_results`.
3. Run `supabase/storage_setup.sql` the same way to create the `reports`
   Storage bucket that uploaded PDFs are saved into.
4. Run `supabase/whatsapp_schema.sql` the same way to create the
   `whatsapp_messages` table used by Step 7.
   Then run `supabase/processing_status_schema.sql` to add the status
   tracking that background report processing needs (**required** — uploads
   will stay at `uploaded` without it).
5. In **Project Settings → API**, copy:
   - **Project URL** → this is `SUPABASE_URL`.
   - **service_role secret key** → this is `SUPABASE_KEY`.

   Use the **service role** key, not the `anon` key — the backend is a
   trusted server and needs full read/write access. This key must never be
   shipped inside the Flutter app.

### 4. Set up environment variables

```bash
cp .env.example .env
```

Then edit `.env` and fill in the two values from the step above:

```env
SUPABASE_URL=https://your-project-ref.supabase.co
SUPABASE_KEY=your-service-role-key
```

The WhatsApp variables (`WHATSAPP_API_KEY`, `WHATSAPP_PHONE_NUMBER_ID`) can
stay empty unless you're testing Step 7 — without them,
`/send-whatsapp` returns a clean `503` rather than failing oddly. To use
it for real: create a Meta WhatsApp Business app, get a permanent access
token and your sending number's phone number ID, and set:

```env
WHATSAPP_API_KEY=your-permanent-access-token
WHATSAPP_PHONE_NUMBER_ID=your-phone-number-id
```

### 5. Run the server

```bash
uvicorn app.main:app --reload
```

The API will be available at `http://localhost:8000`.

## Testing the connection

With the server running and `.env` filled in:

**1. Plain health check** (no dependencies):
```bash
curl http://localhost:8000/api/v1/health
# {"status":"ok","service":"numberspeaks-api"}
```

**2. Database connectivity check:**
```bash
curl http://localhost:8000/api/v1/health/db
# {"status":"ok","database":"connected","users_table_row_count":0}
```
If Supabase isn't configured or unreachable, this returns a `503` with a
clear message instead of crashing.

**3. Full insert + read verification** (writes temporary rows, reads them
back through the table relationships, then deletes them):
```bash
python -m scripts.test_supabase_connection
```
Expected output ends with:
```
All checks passed: connection, insert, and read all work.
```

You can also open `http://localhost:8000/docs` for the interactive Swagger
UI, which lists every available endpoint.

## Actual Bonus Feature (client-confirmed formula & flow)

This section documents the update that implements your real bonus rule
and message flow, on top of everything in Steps 1-7 above. Nothing here
is invented — every rule below is exactly what you specified.

### Files changed

- `app/services/pdf_extractor.py` — added `whatsapp_number` to
  `CANONICAL_FIELDS` (right after `user_name`, matching your column
  order) and to `HEADER_ALIASES` (recognizes "WhatsApp Number", "Mobile
  No", "Phone", "Contact Number", etc.); `_row_to_record()` now extracts
  it as text (never run through numeric parsing).
- `app/schemas/report.py` — `ExtractedRecord` gained `whatsapp_number`.
- `app/services/validation.py` — carries `whatsapp_number` through
  validation (optional — a missing number never fails validation, per
  your own "bonus calculated but WhatsApp skipped" test case).
- `app/services/reports_service.py` — `get_or_create_user()` now also
  sets/updates a user's `whatsapp_number`; `save_extracted_records()`
  passes it through; `to_bonus_result()` and `bonus_result_row_to_raw()`
  carry it (and the two new status fields below) into every API response;
  new `update_calculation_status()` and `get_latest_whatsapp_status()`
  helpers.
- `app/services/bonus_calculator.py` — **the real formula** (see below).
  `is_formula_configured()` now returns `True`.
- `app/services/bonus_service.py` — persists `calculation_status =
  'invalid'` for any row that fails validation or calculation, so a
  failure is saved durably, not just reported in the one API response
  that produced it.
- `app/services/whatsapp_service.py` — eligibility now requires
  `bonus_amount > 0` (not just "calculated"), with a new
  `skipped_no_bonus` status for the ₹0 case.
- `app/services/whatsapp_templates.py` — new default message wording (see
  "The WhatsApp message" below).
- `app/schemas/bonus.py` — `BonusResult` gained `whatsapp_number`,
  `calculation_status`, `whatsapp_status`.
- `app/schemas/whatsapp.py` — documented the new `skipped_no_bonus` status
  value.
- `app/api/v1/endpoints/bonus.py` — `GET /results` and `GET
  /results/{user_id}` now attach each row's latest WhatsApp status, so the
  admin view (`User Name | WhatsApp | Profit/Loss | Bonus | WhatsApp
  Status`) is available from a single call, with no separate lookup.
- `supabase/bonus_status_schema.sql` — **new, additive migration.** Run
  this once, after `schema.sql`, to add the `calculation_status` column.
  Nothing existing is altered.
- `numberspeaks_app/` (the Flutter app) — matching model, results-screen,
  and user-detail-screen updates; see that project's own README.

### The updated bonus calculation

```python
if profit_loss < 0:
    bonus = abs(profit_loss) * 0.03
else:
    bonus = 0.0
```
Only a loss earns a bonus — 3% of its absolute value. A profit or exactly
zero always yields ₹0, and the code path that would compute 3% of a
*positive* number is never reached (there's an `if`, not an `abs()` that
could hide a sign error). Verified against your own examples:

| Profit/Loss | Bonus |
|---|---|
| -1000 | 30 |
| -2500 | 75 |
| -5000 | 150 |
| +500 | 0 |

Nothing else on the row (`level`, `casino_pts`, `sport_pts`,
`third_party_pts`, `ptype`) affects the bonus — your rule is based on
`profit_loss` alone, so `bonus_calculator.py` uses nothing else, rather
than inventing a level- or points-based adjustment you never asked for.

### The WhatsApp message — one deliberate wording change

You proposed:
> Dear {Name},
>
> ₹{Bonus Amount} has been created to your wallet.
> Please enjoy the game!

This app has **no wallet or credit API anywhere** — nothing in this
codebase, or in Supabase, actually credits a wallet. Per your own caveat
("only say it was created to a wallet if there's a real wallet API;
otherwise store/display the amount and keep the wording configurable"),
the shipped default instead reads:

```
Dear Rahul,

Your bonus amount is ₹30.
Please enjoy the game!
```

Same greeting, same bonus figure, same closing line — the only change is
not claiming a wallet credit that doesn't exist. The wording stays fully
configurable via the `WHATSAPP_MESSAGE_TEMPLATE` environment variable (see
`app/services/whatsapp_templates.py`), so switching to your exact proposed
wording is a one-line env change whenever a real wallet API exists to
back it up.

### Error handling

| Case | Behavior |
|---|---|
| Missing user name | Row skipped at extraction, reported in `warnings` |
| Missing WhatsApp number | Bonus still calculated and saved; `send-whatsapp` reports `skipped_no_number` for that user |
| Invalid (unparseable) Profit/Loss | Row skipped at extraction, reported in `warnings` — never silently dropped, never guessed |
| Invalid PDF data (any numeric field) | Same as above — the row is set aside with a reason, not the whole upload |
| Duplicate user within one report | The 2nd insert for the same `(report_id, user_id)` violates `bonus_results`'s existing unique constraint; recorded as a warning, first row's data untouched |
| Same user across multiple reports | Matched by name via `get_or_create_user()` (existing Step 3 behavior) — same user record reused, not duplicated |
| WhatsApp send failure | Recorded as `status="failed"` with the provider's error, saved to `whatsapp_messages`; never stops the rest of the report |
| No bonus owed (₹0) | WhatsApp send is skipped (`skipped_no_bonus`) — no message sent for a zero bonus |

### Test results (against your exact sample data)

Ran the full Admin → PDF → Bonus → WhatsApp flow through the real,
unmodified FastAPI app (via `TestClient`) against a synthetic PDF built
with your own sample rows, using a fake in-memory Supabase client (no live
Supabase project available in this environment) and a faked WhatsApp send
call (no live credentials). All of the following passed:

1. **PDF extraction:** WhatsApp Number extracted correctly for 3 of 4
   valid users (Rahul, Amit, Priya); the 4th (`NoPhoneUser`) correctly
   extracted with `whatsapp_number = null` from a blank cell. A 5th row
   with an unparseable Profit/Loss cell was correctly skipped with a
   warning, never crashing the upload or silently vanishing.
2. **Bonus calculation:** Rahul (-1000) → **30**, Amit (-2500) → **75**,
   Priya (+500) → **0**, NoPhoneUser (-400) → **12** — all matching hand
   calculation. Also directly unit-tested `calculate_bonus()` against all
   three of your original examples (-1000→30, -2500→75, -5000→150) and
   the +500/0 boundary case.
3. **Database saving:** all 4 rows persisted to `bonus_results` with
   `calculation_status="calculated"`, correct `whatsapp_number` (or
   `null` for NoPhoneUser), and the right `bonus_amount` — confirmed by
   reading straight from the (fake) database, not just the API response.
4. **WhatsApp flow:** Rahul and Amit → `sent`, each with a message
   containing their exact bonus amount and no wallet-credit claim; Priya
   → `skipped_no_bonus` (₹0 owed); NoPhoneUser → `skipped_no_number`.
   Re-fetching `GET /results` afterward showed `whatsapp_status` updated
   to `"sent"` for Rahul/Amit and staying `"not_sent"` for the other two.
5. **Duplicate handling:** re-uploading the identical PDF reused the same
   4 user records (matched by name) rather than creating duplicates; a
   second row for the same user within one PDF was correctly rejected by
   the database's unique constraint and reported as a warning.
6. **Full flow confirmed working end to end:** Upload → (WhatsApp Number
   extracted) → Validate → Calculate (real formula) → Save → `GET
   /results` (all 5 admin columns present) → Send WhatsApp (correct
   eligibility gate) → `GET /results` again (status reflects the send).

**Not yet tested:** a real WhatsApp send (no live Meta credentials in this
environment) and your actual production PDF (only synthetic test data
built from your sample numbers was available here).

## Deploying to Railway

1. Push this project to a GitHub repository.
2. Create a new Railway project from that repository.
3. Railway auto-detects Python and uses `railway.json` / `Procfile` to start
   the app with `uvicorn app.main:app --host 0.0.0.0 --port $PORT`.
4. In Railway's project settings, add the environment variables from
   `.env.example` (`SUPABASE_URL`, `SUPABASE_KEY`, `WHATSAPP_API_KEY`,
   `CORS_ORIGINS`, etc.) with their real values.
5. Deploy. Railway assigns `PORT` automatically — no code changes needed.

## Status

- **Step 1 complete:** FastAPI foundation, versioned API structure, health
  check, environment configuration, CORS, global error handling, Railway
  readiness.
- **Step 2 complete:** Supabase schema (`users`, `reports`, `bonus_results`)
  with relationships and RLS, a shared connection/service layer, a DB
  connectivity endpoint, and an insert/read verification script.
- **Step 3 complete:** `POST /api/v1/reports/upload` — validates and
  extracts the PDF, stores the file in Supabase Storage, and saves the
  extracted rows to `bonus_results`. Verified against a synthetic
  multi-page PDF covering headers, blank rows, negatives, and decimals;
  **not yet verified against the client's real PDF**.
- **Step 4 complete:** `POST /api/v1/reports/{report_id}/validate` —
  re-checks a report's extracted rows (required fields, valid numbers,
  blank/header rows ignored) and updates the report's status. Verified
  with direct unit tests covering every rule, including deliberately
  invalid rows; **not yet run against real Supabase data or the client's
  real PDF**.
- **Steps 5-6 complete:** `POST
  /api/v1/reports/{report_id}/calculate-bonus`, `GET .../results`, `GET
  .../results/{user_id}` — full validate → calculate → save → retrieve
  pipeline, gated on report status, tolerant of per-row failures. The
  client's real bonus formula is now implemented (see "Actual Bonus
  Feature" below) — no longer a placeholder.
- **Step 7 complete:** `POST /api/v1/reports/{report_id}/send-whatsapp` —
  sends each eligible user's bonus via Meta's WhatsApp Cloud API (the
  assumed default provider), records success/failure per message in a
  `whatsapp_messages` table, and skips anyone already successfully
  notified unless `force=true`. Verified: schema against real Postgres,
  full pipeline (idempotency, missing-number handling, partial failure)
  against a mocked client, and HTTP error paths on a running server.
  **No real message has been sent** (no live WhatsApp credentials, and
  Meta's API is outside this environment's network access) — the message
  wording itself is now the client's own confirmed content, minus the one
  deliberate change explained in "Actual Bonus Feature" below.

- **Step 8 complete:** Flutter frontend (`numberspeaks_app/`, delivered as
  its own zip) — all 6 screens, calling this backend's real endpoints only,
  no bonus math or WhatsApp logic on the client. See that project's own
  README for its full status and known gaps.
- **Steps 9-10 complete (integration & testing, within this environment's
  limits):** every endpoint was re-driven exactly as the Flutter app calls
  it (same paths/methods/multipart/query params) via FastAPI's `TestClient`
  against this exact, unmodified source — including the full pipeline on a
  synthetic **12-page** PDF (60 rows, to prove no 8-page assumption
  anywhere), all documented error paths (400/404/409/422/501), and
  WhatsApp's duplicate-protection/force-resend/failure handling. Every
  response was diffed field-by-field against the Flutter app's models with
  no mismatches. One integration bug was found and fixed (in the Flutter
  app, not here — see its README §9). **Newly discovered gap:** nothing in
  this backend or the Flutter app ever sets `users.whatsapp_number` (the
  report has no phone-number column) — `send-whatsapp` will report
  everyone as `skipped_no_number` until that's populated some other way
  (today: a direct edit in Supabase). **Fixed by the Actual Bonus Feature
  update below** — the PDF itself now carries a WhatsApp Number column, so
  it's populated automatically on every upload, same as every other field.
- **Actual Bonus Feature complete:** see the dedicated section below for
  the full explanation, the exact test results, and the one deliberate
  wording deviation from your proposed WhatsApp message (flagged per your
  own stated caveat).

Ready for manual deployment (Railway), per your instruction not to deploy
here. The recurring gap across every step so far: no real client PDF, no
live Supabase/WhatsApp credentials, and no real WhatsApp send performed —
all pending from your side before true production end-to-end testing (with
real data and a real WhatsApp send) is possible. The bonus formula and
WhatsApp message wording are no longer open questions — both are now
implemented per your confirmed spec.
