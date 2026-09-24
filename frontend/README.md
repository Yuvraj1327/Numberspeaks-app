# Numberspeaks — Flutter Frontend (Step 8)

This is the Flutter UI for the Numberspeaks Bonus Calculation App. It is a
**frontend only** — all business logic (PDF extraction, validation, bonus
calculation, WhatsApp sending) lives in the existing FastAPI backend
(`numberspeaks-backend/`, Steps 1–7) and is never duplicated or reimplemented
here. This app calls that backend's APIs and displays what it returns.

> **This is source code only.** This sandbox cannot run the Flutter
> toolchain (see "Why the app wasn't run here" below), so `flutter create .`,
> `flutter pub get`, and `flutter run` all need to happen on your machine.
> Every file has been written carefully and reviewed by hand (including an
> independent second pass) for compile-correctness, but a real `flutter
> analyze`/`flutter run` is the first time this code will actually be
> compiled. See "If you hit a compile error" at the bottom — send it back
> and it'll get fixed.

---

## 1. Final folder structure

```
numberspeaks_app/
├── pubspec.yaml
├── analysis_options.yaml
├── .env.example                           # Copy to .env and fill in real values (gitignored)
├── README.md
└── lib/
    ├── main.dart                          # App entrypoint, Provider wiring, auth gate
    ├── core/
    │   ├── app_config.dart                # .env-driven config (API URL, Supabase keys)
    │   ├── app_theme.dart                 # Colors, spacing, ThemeData
    │   ├── api_client.dart                # Dio wrapper — the ONLY place HTTP calls happen
    │   ├── api_exception.dart             # Normalized error type + user-facing messages
    │   └── formatters.dart                # Number/amount formatting
    ├── models/
    │   ├── extracted_record.dart          # Mirrors backend ExtractedRecord
    │   ├── upload_report_response.dart    # Mirrors backend UploadReportResponse
    │   ├── validation_summary.dart        # Mirrors backend ValidationSummary / InvalidRecord
    │   ├── bonus_result.dart              # Mirrors backend BonusResult
    │   ├── bonus_calculation_summary.dart # Mirrors backend BonusCalculationSummary
    │   ├── whatsapp_send_summary.dart     # Mirrors backend WhatsAppSendSummary
    │   └── report_status.dart             # reports.status enum (uploaded/processing/validated/completed/failed)
    ├── services/
    │   ├── auth_service.dart              # Supabase Auth (login/logout/session)
    │   ├── reports_api_service.dart       # POST /reports/upload, POST /reports/{id}/validate
    │   ├── bonus_api_service.dart         # POST /calculate-bonus, GET /results, GET /results/{user_id}
    │   ├── whatsapp_api_service.dart      # POST /send-whatsapp
    │   └── local_report_store.dart        # On-device "last report" cache (SharedPreferences)
    ├── repositories/
    │   ├── auth_repository.dart           # App-wide auth state (ChangeNotifier)
    │   └── report_repository.dart         # App-wide report/bonus/WhatsApp state (ChangeNotifier)
    ├── routing/
    │   ├── app_routes.dart                # Route name constants
    │   └── app_router.dart                # onGenerateRoute — every screen's entry point
    ├── screens/
    │   ├── login_screen.dart
    │   ├── dashboard_screen.dart
    │   ├── report_upload_screen.dart
    │   ├── report_processing_screen.dart
    │   ├── results_screen.dart
    │   └── user_detail_screen.dart
    └── widgets/
        ├── loading_view.dart
        ├── error_view.dart
        ├── empty_view.dart
        └── status_pill.dart
```

This is the exact layered structure requested (`core / models / services /
repositories / screens / widgets / routing`) — there was no pre-existing
Flutter project in this workspace, so this is the one and only architecture
now in place.

---

## 2. Screens created

| # | Screen | File |
|---|--------|------|
| 1 | Login / Authorized Access | `screens/login_screen.dart` |
| 2 | Dashboard | `screens/dashboard_screen.dart` |
| 3 | Report Upload | `screens/report_upload_screen.dart` |
| 4 | Report Processing | `screens/report_processing_screen.dart` |
| 5 | Bonus Results | `screens/results_screen.dart` |
| 6 | Individual User Bonus Details (incl. WhatsApp status) | `screens/user_detail_screen.dart` |

The spec listed WhatsApp Action as a 7th item, but the backend only exposes
a **report-wide** send endpoint (no per-user send). So "Send Bonus via
WhatsApp" is the action button on the **Results** screen (screen 5), and the
User Detail screen (screen 6) shows that user's resulting status — this
matches the spec's own phrasing, "Send WhatsApp action **where supported**."

---

## 3. Navigation flow

```
Login
  │  (Supabase Auth sign-in succeeds)
  ▼
Dashboard ───────────────► Report Upload
  │  (View Results,               │ (PDF selected & uploaded)
  │   only if a report                  ▼
  │   exists on this device)    Report Processing
  │                                     │ (validate → calculate-bonus, both succeed)
  │                                     ▼
  └───────────────────────────► Bonus Results ───► Individual User Bonus Details
                                       │  (tap a user)      │
                                       │  (Send WhatsApp)   │ (shows WhatsApp status,
                                       ▼                    │  links back to Results
                                  WhatsApp send summary      to actually send)
                                  (dialog on Results screen)
```

- **Login → Dashboard**: automatic on successful sign-in; also automatic on
  app launch if a Supabase session already exists (`main.dart`'s `_AuthGate`).
- **Dashboard → Report Upload**: floating action button.
- **Report Upload → Report Processing**: only after a successful upload, via
  "Start Processing" (the backend requires the separate validate/calculate
  calls this screen makes — see below).
- **Report Processing → Bonus Results**: only after both validate and
  calculate-bonus succeed.
- **Dashboard → Bonus Results**: directly, for the last report uploaded on
  this device (if any).
- **Bonus Results → User Detail**: tapping any user row.
- **Logout**: app bar icon on the Dashboard, back to Login.

---

## 4. Screen → Backend API mapping

| Screen | Backend endpoint(s) used |
|---|---|
| Login | Supabase Auth `signInWithPassword` (**not** a FastAPI endpoint — see gap #1 below) |
| Dashboard | `GET /api/v1/reports/{id}/results` (to compute the two stat tiles); everything else about "latest report" comes from on-device storage (gap #2) |
| Report Upload | `POST /api/v1/reports/upload` |
| Report Processing | `POST /api/v1/reports/{id}/validate`, then `POST /api/v1/reports/{id}/calculate-bonus` |
| Bonus Results | `GET /api/v1/reports/{id}/results`, `POST /api/v1/reports/{id}/send-whatsapp` |
| User Detail | `GET /api/v1/reports/{id}/results/{user_id}` |

No screen calls any endpoint that doesn't already exist in the Steps 1–7
backend, and no screen performs bonus math or builds a WhatsApp message —
both stay entirely server-side.

---

## 5. Important models & services

- **`core/api_client.dart`** — the single Dio wrapper all network calls go
  through. Maps every possible failure (timeout, no connection, 400/401/403/
  404/409/501/5xx, FastAPI's `{"detail": ...}` error shape) into one
  `ApiException` with a `.userMessage` that's always safe to show directly —
  no raw exception text ever reaches a screen.
- **`models/bonus_result.dart`** — mirrors the backend's `BonusResult`
  field-for-field, including keeping `bonusAmount` nullable. The UI never
  computes a fallback value for it; null is always rendered as "not
  calculated yet" / "—".
- **`repositories/report_repository.dart`** — the one place that decides
  which backend call to make for a given action, and the only place that
  layers the on-device workarounds (last report id/status, in-session
  WhatsApp status) on top of real responses.
- **`services/local_report_store.dart`** — the on-device cache described in
  gap #2 below. Stores only a report id/filename/status string, never any
  bonus or user data.

---

## 6. Running the app

This project has **not** been scaffolded with `flutter create` yet (that
step generates the `android/`, `ios/`, `web/`, etc. platform folders, which
depend on your installed Flutter version and are safe to generate locally —
doing it here would just produce stale platform code). On your machine, with
Flutter installed:

```bash
cd numberspeaks_app

# 1. Generate the platform folders (safe — does not touch lib/ or pubspec.yaml)
flutter create .

# 2. One-time setup — copy the example env file and fill in your real
#    values. .env is already in .gitignore, same as the backend's .env.
cp .env.example .env

# 3. Install dependencies
flutter pub get

# 4. Static analysis
flutter analyze

# 5. Run — reads config from .env automatically (see below), no flags needed
flutter run
```

`.env` (see `.env.example` for the exact keys — `API_BASE_URL`,
`SUPABASE_URL`, `SUPABASE_ANON_KEY`) is loaded at startup by
`flutter_dotenv`, mirroring the backend's own `python-dotenv`/`.env` setup
(`core/app_config.dart` reads it, same as `app/core/config.py` does on the
backend). Nothing is hardcoded in source. Use the Supabase **anon** key
here, never the service-role key (that stays backend-only, as in Steps
1–7).

**Note on `.env` and app builds** (unlike the backend, where `.env` never
leaves the server): Flutter bundles `.env` into the compiled app as an
asset, so a built APK/IPA can technically have it extracted back out. That
tradeoff is fine for a backend URL and a Supabase *anon* key (which is
public-safe by design — that's what "anon" means), but never put a real
secret in it.

If `.env` is missing or `SUPABASE_URL`/`SUPABASE_ANON_KEY` are blank, the
app still starts and shows a clear "Missing configuration" screen instead
of crashing.

---

## 7. Why the app wasn't run here

This sandbox's network policy blocks `pub.dev` and `storage.googleapis.com`
(confirmed directly — both return `403`/connection-refused, and the sandbox's
proxy allowlist explicitly excludes them). The Flutter SDK needs both to
fetch its engine artifacts and resolve packages, so `flutter pub get` /
`flutter run` / `flutter build` cannot execute here, even though outbound
`git`/GitHub access itself works fine. This is a constraint of this specific
sandbox, not of the code.

To compensate, every file was hand-written against the real backend response
schemas (read directly from `numberspeaks-backend/app/schemas/*.py`) and then
independently re-reviewed line-by-line for import correctness, method-
signature matches across files, null-safety, and API-version-correct usage
of `dio`, `supabase_flutter`, `file_picker`, `intl`, and `shared_preferences`.
No compile errors were found in that review, but it is not a substitute for
`flutter analyze`/`flutter run` on your machine — see the note at the bottom.

---

## 8. Known backend dependency gaps

These are real, disclosed gaps between what the Step 8 spec asks for and
what the Steps 1–7 backend currently exposes. None of them were worked
around by changing backend logic (out of scope for this step) — each is
handled honestly on the frontend, as noted:

1. **No login/auth endpoint in FastAPI.** The backend doesn't verify tokens
   yet. Login uses Supabase Auth directly (`services/auth_service.dart`),
   and the resulting access token is still attached to every backend request
   (`ApiClient.setAuthToken`) so the backend can start enforcing it later
   with zero Flutter-side changes.
2. **No "list reports" / "latest report" endpoint.** The Dashboard's
   "latest report" is the last report *this device* uploaded, tracked
   locally (`services/local_report_store.dart`). A different device, or a
   reinstalled app, will show "no report uploaded yet" until it uploads one
   — this is disclosed on-screen via the empty state, not hidden.
3. **No report-status / processing-progress endpoint.** The Processing
   screen only shows states for calls it is actually making (validate, then
   calculate-bonus) — never a fabricated progress bar. Likewise, the
   Dashboard's "status" pill reflects the `status` field from the most
   recent real response for that report, not a live poll.
4. **No per-user WhatsApp send endpoint.** Only `POST /reports/{id}/
   send-whatsapp` (whole report) exists. The "Send Bonus via WhatsApp"
   action lives on the Results screen; the User Detail screen shows that
   user's resulting status with a note pointing back to it, rather than a
   non-functional per-user button.
5. **No endpoint to query historical WhatsApp status.** `whatsapp_messages`
   rows aren't exposed via any GET endpoint, so WhatsApp status can only be
   shown for a send made during the **current app session**
   (`ReportRepository`'s in-memory `_sessionWhatsAppSummaries`). Reopening
   the app loses that status until the next send; this is stated directly
   in the User Detail screen's UI text, not silently assumed to be "not
   sent."
6. **No way to set a user's `whatsapp_number` anywhere in the system.**
   Discovered during Step 9-10 integration testing: the report's 8 columns
   (No, User Name, Level, Casino Pts, Sport Pts, Third Party Pts,
   Profit/Loss, Ptype) never included a phone number, `users.whatsapp_number`
   is never set by the upload pipeline, and no endpoint or screen sets it
   either. As shipped, `POST /send-whatsapp` will report every user as
   `skipped_no_number` until that column is populated some other way (today,
   only a direct edit in the Supabase `users` table). This was **not**
   fixed here — adding a way to set it is a new feature, out of this step's
   scope — but it will block real WhatsApp sends until addressed, so it's
   flagged for the client/next step rather than left to be discovered later.

None of these required or received any change to the backend.

---

## 9. Step 9–10 — integration & end-to-end testing (this round)

This sandbox still cannot run the Flutter toolchain (see section 7), so
"integration testing" here means the most rigorous thing that actually is
possible without it: the real, unmodified FastAPI backend was driven
through its exact HTTP contract — same paths, methods, multipart shape,
query params this app's `ApiClient`/services use — via Starlette's
`TestClient`, with only the three things Flutter itself never talks to
directly stood in for:

- **Supabase** (no real project available) → a small in-memory fake that
  implements only the exact `.table().select().eq()...execute()` query
  shapes `app/services/*.py` actually issues, enforcing the same
  status-CHECK and foreign-key constraints `schema.sql` declares.
- **The bonus formula** (still not provided by the client) → first tested
  completely unpatched, confirming the live 501 behavior end-users will
  see today; then, only for testing the *rest* of the pipeline, a clearly
  temporary in-memory formula was substituted in the running test process.
  `bonus_calculator.py` on disk was never edited — verified with a SHA-256
  check at the end of the test run.
- **The WhatsApp provider** (no real credentials available) → a canned
  fake sender, so idempotency/duplicate-protection logic could be proven
  without a real Meta Graph API call.

A synthetic 12-page, 60-row PDF (`generate_test_pdf.py`, not shipped —
regenerate from that script if needed) was used specifically because 12
≠ 8, to prove nothing anywhere hardcodes an 8-page assumption. Full results
are in the accompanying chat message; every response body was also diffed
field-by-field against this project's Dart models (`models/*.dart`) and
matched exactly, with no drift found.

One real bug was found and fixed this round: `ApiClient._extractDetail`
only read FastAPI's default `{"detail": ...}` error shape, but
`app/main.py`'s global handler for unexpected/validation errors returns
`{"success", "error", "details"}` instead (no `detail` key) — now both
shapes are handled. A second polish fix: the 501 "bonus formula not
configured" error's raw backend text names a source file to edit
(`bonus_calculator.py`) and was being shown as-is to the end user; it's
now replaced with a plain "contact your administrator" message
(`core/api_exception.dart`).

---

## 10. If you hit a compile error

Since this couldn't be run here, please run `flutter analyze` (and/or
`flutter run`) locally and send back whatever it reports — file, line, and
the exact error text — and it'll get fixed directly.
