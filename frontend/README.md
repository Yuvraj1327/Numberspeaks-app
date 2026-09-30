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
├── assets/
│   └── images/
│       └── numberspeaks_logo.png          # Brand logo — top navbar, login screen (AppLogo)
└── lib/
    ├── main.dart                          # App entrypoint, Provider wiring, auth gate
    ├── core/
    │   ├── app_config.dart                # .env-driven config (API URL, Supabase keys)
    │   ├── app_theme.dart                 # Brand palette, spacing, ThemeData (navy/blue/cyan/teal)
    │   ├── api_client.dart                # Dio wrapper — the ONLY place HTTP calls happen
    │   ├── api_exception.dart             # Normalized error type + user-facing messages
    │   ├── formatters.dart                # Number/amount formatting
    │   ├── report_actions.dart            # Shared "what button/route does this status need" helper
    │   └── logout_helper.dart             # Shared logout confirmation dialog (Account + Settings)
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
    │   └── local_report_store.dart        # On-device recent-reports history (SharedPreferences)
    ├── repositories/
    │   ├── auth_repository.dart           # App-wide auth state (ChangeNotifier)
    │   └── report_repository.dart         # App-wide report/bonus/WhatsApp state (ChangeNotifier)
    ├── routing/
    │   ├── app_routes.dart                # Route name constants
    │   └── app_router.dart                # onGenerateRoute — every screen's entry point
    ├── screens/
    │   ├── login_screen.dart
    │   ├── main_shell.dart                # Bottom-nav shell — hosts the 5 tabs below
    │   ├── dashboard_screen.dart          # DashboardTab
    │   ├── reports_screen.dart            # ReportsTab
    │   ├── results_screen.dart            # ResultsTab (embedded) + ResultsScreen (pushed, explicit report)
    │   ├── account_screen.dart            # AccountTab
    │   ├── settings_screen.dart           # SettingsTab
    │   ├── terms_screen.dart              # Terms & Conditions (pushed from Settings)
    │   ├── report_upload_screen.dart
    │   ├── report_processing_screen.dart
    │   └── user_detail_screen.dart
    └── widgets/
        ├── loading_view.dart
        ├── error_view.dart
        ├── empty_view.dart
        ├── status_pill.dart
        ├── app_logo.dart                  # Brand mark, used in the top navbar + login screen
        └── app_top_bar.dart               # Compact shared top navbar (logo + wordmark, account icon)
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
| 2 | Main shell (top navbar + bottom navigation) | `screens/main_shell.dart` |
| 2a | Dashboard tab | `screens/dashboard_screen.dart` (`DashboardTab`) |
| 2b | Reports tab | `screens/reports_screen.dart` (`ReportsTab`) |
| 2c | Results tab | `screens/results_screen.dart` (`ResultsTab`) |
| 2d | Account tab | `screens/account_screen.dart` (`AccountTab`) |
| 2e | Settings tab | `screens/settings_screen.dart` (`SettingsTab`) |
| 3 | Report Upload | `screens/report_upload_screen.dart` |
| 4 | Report Processing | `screens/report_processing_screen.dart` |
| 5 | Bonus Results (a specific report, pushed) | `screens/results_screen.dart` (`ResultsScreen`) |
| 6 | Individual User Bonus Details (incl. WhatsApp status) | `screens/user_detail_screen.dart` |
| 7 | Terms & Conditions | `screens/terms_screen.dart` |

The spec listed WhatsApp Action as its own item, but the backend only
exposes a **report-wide** send endpoint (no per-user send). So "Send Bonus
via WhatsApp" is the action button on the Results screen, and the User
Detail screen shows that user's resulting status — this matches the spec's
own phrasing, "Send WhatsApp action **where supported**."

**UI redesign (this round):** the app was reskinned with the client's brand
palette and restructured around a bottom navigation bar — see §12 for the
full writeup. `dashboard_screen.dart` and `results_screen.dart` were
refactored (not replaced) into embeddable tab widgets so their existing
data-loading and error-handling logic carries over unchanged; the backend
calls each screen makes are identical to before.

---

## 3. Navigation flow

```
Login
  │  (Supabase Auth sign-in succeeds)
  ▼
MainShell (top navbar + bottom nav: Dashboard | Reports | Results | Account | Settings)
  │
  ├─ Dashboard tab ──────────► Report Upload
  │    (Quick Upload card,           │ (PDF selected & uploaded)
  │     status-aware "Continue/            ▼
  │     View Results" button,   Report Processing
  │     recent activity)               │ (validate → calculate-bonus, both succeed)
  │                                     ▼
  ├─ Reports tab ────────────► Bonus Results (pushed, this report)
  │    (Upload Report button,          │
  │     device upload history)   ┌─────┴─────┐
  │                               ▼           ▼
  ├─ Results tab            Send WhatsApp   User Detail
  │    (last report's results,  (dialog)    (tap a user row)
  │     same body as above,
  │     card list / table on wide screens)
  │
  ├─ Account tab (profile, session info, Log Out)
  │
  └─ Settings tab (Account, Theme, App Info, Terms & Conditions, Log Out)
```

- **Login → MainShell**: automatic on successful sign-in; also automatic on
  app launch if a Supabase session already exists (`main.dart`'s `_AuthGate`).
- **Bottom navigation** (`main_shell.dart`): switches between the five tabs
  in place via an `IndexedStack`, so each tab keeps its scroll position and
  in-flight loads when you switch away and back — no tab is torn down and
  rebuilt on every tap.
- **Dashboard tab → Report Upload**: the Quick Upload card, or the
  status-aware action button once a report is in progress.
- **Reports tab → Report Upload**: the "Upload Report" button; returning
  from upload refreshes the recent-reports list.
- **Report Upload → Report Processing**: only after a successful upload, via
  "Start Processing" (the backend requires the separate validate/calculate
  calls this screen makes — see below).
- **Report Processing → Bonus Results**: only after both validate and
  calculate-bonus succeed.
- **Dashboard / Reports tab → Bonus Results (pushed)**: "Continue" or "View
  Results" on a report card, resolved by its status (`core/report_actions.dart`).
- **Results tab**: shows the same results body for the most recent report on
  this device, embedded directly in the bottom-nav shell (no push needed).
- **Bonus Results → User Detail**: tapping any user row.
- **Settings → Terms & Conditions**: pushed screen.
- **Account tab / Settings tab → Logout**: both use the same confirmation
  dialog (`core/logout_helper.dart`), back to Login. There is no logout
  icon in the top navbar any more — logout lives only in Account/Settings,
  per the redesign brief.

---

## 4. Screen → Backend API mapping

| Screen | Backend endpoint(s) used |
|---|---|
| Login | Supabase Auth `signInWithPassword` (**not** a FastAPI endpoint — see gap #1 below) |
| Dashboard tab | `GET /api/v1/reports/{id}/results` (to compute the stat tiles and recent-activity list); everything else about "which reports exist" comes from on-device storage (gap #2) |
| Reports tab | No new calls — lists the on-device report history (gap #2); each card's action routes into the same Upload/Processing/Results flow |
| Report Upload | `POST /api/v1/reports/upload` |
| Report Processing | `POST /api/v1/reports/{id}/validate`, then `POST /api/v1/reports/{id}/calculate-bonus` |
| Results tab / Bonus Results (pushed) | `GET /api/v1/reports/{id}/results`, `POST /api/v1/reports/{id}/send-whatsapp` |
| User Detail | `GET /api/v1/reports/{id}/results/{user_id}` |
| Account tab | No new calls — reads the existing Supabase session already held by `AuthRepository` |
| Settings tab | No new calls — Logout reuses `AuthRepository.logout()` |

No new backend endpoint is called anywhere in this round — the redesign is
strictly a UI/navigation restructuring on top of the same API surface.

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
  gap #2 below. Stores a bounded (10-entry) history of report id/filename/
  status/updated-at, keyed by `reportId` (`upsertReport`), never any bonus
  or user data. Backs both the Dashboard's "latest report" and the Reports
  tab's list. Fixed a latent bug this round: `validateReport`/
  `calculateBonus` previously updated a single "last report" pointer
  without checking which `reportId` they were actually called for, so
  tracking more than one report at a time could overwrite the wrong
  entry's status — every call site now passes its own `reportId` through
  `upsertReport`.

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
5. ~~No endpoint to query historical WhatsApp status.~~ **Fixed in the
   Actual Bonus Feature update (see §11).** `GET /results` and `GET
   /results/{user_id}` now return a durable `whatsapp_status` field
   (`"not_sent" | "sent" | "failed"`) sourced from `whatsapp_messages`
   server-side, so status survives app restarts. The in-session cache
   (`ReportRepository.sessionWhatsAppStatusFor`) is kept and preferred
   when present — it can be more specific (e.g. `skipped_already_sent`)
   right after a send — but the screens now fall back to the backend's
   own `whatsapp_status` instead of showing nothing.
6. ~~No way to set a user's `whatsapp_number` anywhere in the system.~~
   **Fixed in the Actual Bonus Feature update (see §11).** The client
   confirmed the report PDF itself has a WhatsApp Number column; the
   backend now extracts it and saves it automatically on every upload, no
   separate screen or endpoint needed.

None of these required or received any change to the backend beyond what's
described in §11 below.

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

## 11. Actual Bonus Feature update

This round updates the app for the backend's real bonus formula, its new
`whatsapp_number` field, and two new status fields — matching the
backend's own "Actual Bonus Feature" README section. No screen was
rewritten; only the models and the two screens that display bonus results
were extended.

**Models:**
- `models/bonus_result.dart` — `BonusResult` gained `whatsappNumber`
  (`String?`), `calculationStatus` (`String`, defaults to `'pending'` if
  ever omitted), and `whatsappStatus` (`String`, defaults to `'not_sent'`).
- `models/extracted_record.dart` — `ExtractedRecord` gained
  `whatsappNumber` (`String?`), mirroring the PDF's new column.
- `models/whatsapp_send_summary.dart` — documented the new
  `skipped_no_bonus` status value and added `isSkippedNoBonus`.

**Screens:**
- `screens/results_screen.dart` (Bonus Results) — each card now shows the
  user's WhatsApp number alongside name/level, and its status pill prefers
  a same-session send result but falls back to the backend's durable
  `whatsapp_status` (see gap §8.5, now fixed) instead of hiding the pill
  when nothing happened this session.
- `screens/user_detail_screen.dart` — added a WhatsApp Number detail row,
  and the same session-first/backend-fallback status logic, with new
  status messages for `skipped_no_bonus` and `not_sent`.
- `widgets/status_pill.dart` — added `skipped_no_bonus` ("No bonus owed")
  and `not_sent` ("Not sent") to `StatusPill.forWhatsAppStatus`.

**Not changed:** the upload/processing screens, routing, repositories'
API-calling logic (beyond the fallback described above), and the WhatsApp
send action itself — all of that already worked against the real backend
contract and needed no changes for this update.

**Testing:** same limits as every other round — no Flutter/Dart SDK in
this sandbox (see §7), so this was a careful manual read-through of every
changed file plus an independent static review (checking every
`BonusResult`/`ExtractedRecord` construction site has the new required
fields, every field reference matches the model's exact camelCase name,
and braces/imports are consistent), not an actual compile. The backend
side of this same feature (which these models and screens now match) was
tested for real — see the backend README's "Actual Bonus Feature" section
for those results.

---

## 12. UI redesign — brand theme + bottom navigation (this round)

This round is **UI/UX only**: no backend call, business rule, or bonus/
WhatsApp logic changed anywhere. It reskins the app in the client's brand
colors and restructures navigation around a bottom navigation bar, reusing
the existing layered architecture (`core / models / services /
repositories / screens / widgets / routing`) rather than introducing a new
one.

### Brand theme (`core/app_theme.dart`)

A palette drawn from the supplied logo (navy, royal blue, cyan, teal-green,
white) replaces the previous placeholder colors. Every existing token
**name** (`AppTheme.primary`, `.primaryDark`, `.success`, `.danger`,
`.warning`, `.surfaceMuted`, `AppSpacing.*`) is unchanged, so no other file
needed to be touched just to pick up the new look — only screens getting
new content needed edits. New pieces: a navy `AppBarTheme`, a
`NavigationBarThemeData` for the new bottom bar, refreshed button/card/chip/
divider themes (white cards with a hairline navy border, 16px radius), and
an `AppShadows` helper for the few surfaces that want a soft elevation
shadow. Light theme only, as requested — the Settings tab's "Theme" entry
is an informational dialog, not a working dark-mode toggle, since dark mode
was never implemented (adding a non-functional-looking toggle would have
been worse than being upfront about it).

### Logo + top navbar

- **`assets/images/numberspeaks_logo.png`** — the client's logo, added as a
  real bundled asset (declared in `pubspec.yaml`).
- **`widgets/app_logo.dart`** (`AppLogo`) — renders it, with a small
  built-in fallback icon if the asset is ever missing, so a packaging
  mistake can never crash the app.
- **`widgets/app_top_bar.dart`** (`AppTopBar`) — the new compact top navbar:
  logo + "Numberspeaks" wordmark, no large page heading, and a small account
  icon instead of a logout icon (logout was moved into Account/Settings,
  per the brief).

### Bottom navigation shell (`screens/main_shell.dart`)

`MainShell` is the new post-login home (`AppRoutes.home`, replacing the old
`AppRoutes.dashboard`). It hosts five tabs — Dashboard, Reports, Results,
Account, Settings — in an `IndexedStack` under the shared `AppTopBar` and a
Material 3 `NavigationBar`. Everything that used to be pushed on top of the
Dashboard (Upload, Processing, a specific report's Results, User Detail,
Terms) still is, via the exact same `Navigator`/`AppRouter` mechanism as
before — no nested Navigators were introduced, and no existing push flow
changed.

### The five tabs

- **Dashboard tab** (`dashboard_screen.dart`, `DashboardTab`) — the old
  Dashboard's data-loading and error-handling logic carried over unchanged,
  now rendered without its own `Scaffold`/`AppBar` (the shell provides
  those). Adds a Quick Upload card, "Records processed" / "Calculated"
  stat tiles, a "Total bonus calculated" tile (summed from the already-
  fetched results — never a new call or an invented figure), a status-aware
  Continue/View-Results button, and a "Recent activity" list of the last
  few calculated users.
- **Reports tab** (`reports_screen.dart`, new) — an Upload Report button
  plus the on-device history of reports uploaded from this device
  (`LocalReportStore`, extended this round to keep up to 10 entries instead
  of just the last one), each with its status and a status-aware
  Continue/View-Results action. This is still explicitly on-device history,
  not a backend "list reports" feature — see gap #2 in §8, unchanged.
- **Results tab** (`results_screen.dart`, `ResultsTab`, new wrapper) — shows
  results for the most recent report on this device without an extra tap.
  The original `ResultsScreen` (pushed, for a specific `reportId` — e.g.
  from a Reports-tab card) and the new tab both now share one extracted
  `_ResultsBody` widget, so there is exactly one copy of the search/sort/
  WhatsApp-send logic, not two copies that could drift apart. Added a
  responsive `LayoutBuilder`: **≥720px** width (tablet/desktop/web) renders
  an explicit "User Name | WhatsApp | Profit/Loss | Bonus | WhatsApp
  Status" table; narrower renders the existing card list, restyled.
- **Account tab** (`account_screen.dart`, new) — profile info (name/email
  from the real Supabase session), session details, and Log Out.
- **Settings tab** (`settings_screen.dart`, new) — Account (opens the
  Account tab), Theme (info dialog), App Information (static version
  string kept in sync with `pubspec.yaml` by hand — deliberately not worth
  a new package dependency for one static string), Terms & Conditions
  (pushes `terms_screen.dart`, which is honestly labeled placeholder
  content since the client hasn't supplied real terms yet), and Log Out.
  Account and Settings share one logout confirmation flow
  (`core/logout_helper.dart`) rather than two near-duplicate dialogs.

### Responsive behavior

Tested by reasoning through layout at phone (~360–430px), tablet (~768px+)
and desktop/web (~1024px+) widths: the bottom navigation bar, cards, and
forms already used `MediaQuery`/flexible layouts before this round; the one
new width-dependent layout is the Results table/card split described above.

### Routing changes

- `AppRoutes.dashboard` → renamed `AppRoutes.home`, now points to
  `MainShell` (confirmed via search: no remaining references to the old
  name or to a directly-routed `DashboardScreen` anywhere in `lib/`).
- New `AppRoutes.terms` → `TermsScreen`.
- Nothing else in the route table changed.

### What did *not* change

No backend endpoint, request/response shape, bonus formula, WhatsApp
message wording, or business rule changed anywhere in this round — every
tab calls the same repositories and services as before (see the updated
§4 table). No new package dependency was added.

### Testing / review

Same constraint as every other round (§7): no Flutter/Dart SDK available
here, so this was verified by careful hand-authoring plus an independent
static-review pass (a second, fresh read of every new/changed file,
checking syntax, null-safety, that every referenced type/constructor/
field actually exists with the API used, and that no old
`AppRoutes.dashboard`/`DashboardScreen`/`saveLastReport*` reference was
left behind). That review came back clean; two minor pre-existing/advisory
items were noted, not introduced by this round and not fixed here since
they're outside the "UI/UX only, no logic changes" brief:
- `LoginScreen` shows a fixed "Invalid email or password" message for
  *any* login failure (network errors included), inherited unchanged from
  before this round.
- `app_theme.dart` uses `CardThemeData` (current Flutter API); if your
  installed Flutter version is materially older than what `pubspec.yaml`'s
  SDK floor implies, `flutter analyze` will catch it immediately and it's
  a one-line fix (`CardTheme` instead).

As always, this is not a substitute for a real `flutter analyze`/`flutter
run` on your machine — see §10 if it reports anything.

---

## 13. UI/UX follow-up — dashboard analytics, filters, retry, honest timeouts (this round)

This round builds directly on §12's bottom-nav redesign — same navbar,
same five tabs, same brand theme, same screens — and makes each tab do
more of what the brief asked for. Still **UI/UX + local-state only**: no
new backend endpoint, no change to the bonus formula, and no mock/invented
data anywhere below. Where a figure couldn't come from a real response, it
was left out rather than guessed.

### New: on-device activity log (`services/activity_log_store.dart`)

A small `SharedPreferences`-backed log (same pattern as
`LocalReportStore`, capped at 30 entries) that records four real events at
the exact moment their real backend call returns: report uploaded, report
processed (validate), bonus calculated, WhatsApp messages sent. Wired into
`ReportRepository`'s existing `uploadReport`/`validateReport`/
`calculateBonus`/`sendWhatsApp` methods — nothing new calls the backend
differently, this just also writes a receipt of what happened. Powers the
Dashboard's "Recent activity" feed. Same disclosure as `LocalReportStore`:
this is what *this device* did, not a backend audit log (the backend has
none to query).

### Dashboard — summary cards + real activity feed

Six summary cards were added: **Total Reports** (this device's own upload
count, from `LocalReportStore`), and **Users Processed / Total Loss /
Total Bonus / WhatsApp Sent / WhatsApp Pending**, all computed from the
latest report's real `GET /results` rows (the same call the Dashboard
already made). "Total Loss" sums the negative `profit_loss` values;
"WhatsApp Sent/Pending" are scoped to bonus-eligible rows only, so a user
with no bonus owed (who will never get a message) doesn't inflate
"Pending". The grid is responsive (2/3/6 columns by width) so it never
leaves large empty gaps on a phone or stretches oddly on desktop. The old
per-user "Recent activity" list was replaced with the real activity feed
above — Dashboard no longer shows the same information as Results, and
"Recent activity" now means what the brief asked for (uploaded / processed
/ calculated / sent), not a duplicate results list.

### Reports tab — user count + completed-report summary

`LocalReportEntry` (in `LocalReportStore`) gained three optional fields —
`userCount`, `bonusEligibleCount`, `totalBonus` — filled in from the real
validate/calculate-bonus responses at the moment those calls return
(`ReportRepository`), never fetched separately or guessed. Each report
card now shows its user count next to the date, and once a report reaches
`completed`, an inline mini-summary ("8 of 12 user(s) bonus-eligible •
$420.00 total bonus") — satisfying "show completed report summary"
without an extra network call per card in the list.

### Results tab / screen — filters, four-column layout, Retry

- Added a filter row — **All / Bonus / No Bonus / Profit / Loss** — as
  `ChoiceChip`s above the results list/table. "Bonus" / "No Bonus" reads
  `bonus_amount` (owed vs. null-or-zero); "Profit" / "Loss" reads the sign
  of `profit_loss`. Combines with the existing search and sort.
- The table/card fields were tightened to the exact set asked for — **User
  Name | Profit/Loss | Bonus | WhatsApp Status** — dropping the standalone
  WhatsApp-number column (it's still shown on the User Detail screen).
- WhatsApp status display now covers all four states asked for — **Sent /
  Pending / Failed / No Number** — `not_sent` is now labeled "Pending" and
  `skipped_no_number` is labeled "No Number" (`status_pill.dart`). A new
  `BonusResult.displayWhatsAppStatus()` helper also normalizes display-only:
  if a user has no WhatsApp number on file at all, the status always reads
  "No Number" regardless of the raw backend value, since no message could
  possibly have been sent to them — this never changes stored data, only
  what's displayed.
- **Retry**, on both the Results screen/tab (per-row) and the User Detail
  screen, for anyone whose status is Failed or Pending. There is still no
  per-user send endpoint (see §8, gap #4) — Retry calls the same
  report-wide `POST /send-whatsapp` again, which already skips anyone
  already sent and only (re)attempts pending/failed numbers. The snackbar
  says exactly that ("Retrying WhatsApp for pending/failed users on this
  report…") rather than implying a single-user resend that doesn't exist.

### Processing screen — honest timeouts + completion summary

- A request that times out (`ApiErrorKind.timeout`) is no longer shown as
  "Failed". It gets its own state — an amber "Timed out" indicator and
  wording that says explicitly this doesn't mean it failed, since a
  timeout means the server never told us the outcome, not that the
  outcome was bad — with the same "Try Again" action.
- Fixed a real display bug found by review: the stage rows (Validating /
  Calculating) used to derive their state from a plain enum-index
  comparison, which meant a validation failure made the *never-run*
  Calculating row show a green "done" checkmark too. A new `_failedAtStep`
  field now records exactly which step's own call failed, so steps before
  it correctly show done, that step shows error/timeout, and steps after
  it correctly show pending.
- After a successful calculation, a completion summary now shows: **Total
  users, Bonus-eligible users, Total bonus, WhatsApp sent, WhatsApp
  pending/failed** — all computed from the real `calculate-bonus`
  response. Right after calculation nothing has been sent yet, so "sent"
  is naturally 0 and "pending/failed" is the full eligible count — that's
  the real state, not a placeholder, and it uses the same "bonus-eligible"
  definition (`bonus_amount != null`) as the Dashboard and Reports tab so
  the same report never shows two different numbers in two places.

### Account tab

Added a "Status: Active" row. Supabase Auth (this app's only auth
provider) has no role/permission system, so there is no real "role" to
show — showing one would be invented. "Active" is shown instead, and it's
true by construction (reaching this screen means the session is active),
never a fabricated value.

### What did *not* change

Header (logo + wordmark, no logout icon), bottom navigation, brand theme,
and Settings tab are unchanged from §12 — they already matched this
round's brief. No backend endpoint, request/response shape, bonus formula,
or WhatsApp message logic changed anywhere.

### Testing / review

Same constraint as every round (§7): no Flutter/Dart SDK in this sandbox,
so `flutter analyze`/`flutter run -d chrome` could not actually be
executed here — confirmed again this round (no `flutter`/`dart` binary,
and pub.dev/storage.googleapis.com are still blocked at the network
proxy). This was verified instead by careful hand-authoring plus an
independent static-review pass (a second, fresh read of every new/changed
file against this round's exact checklist — syntax, null-safety, that
every new type/field/method referenced actually exists with the API used,
that `ReportRepository`'s new `activityLog` constructor parameter is
wired at its one construction site in `main.dart`, and that no stale
reference to a pre-round method/field was left behind). That review
surfaced three real logic bugs (the stage-row and bonus-eligible/WhatsApp-
pending inconsistencies described above under "Processing screen") — all
three are fixed in the delivered code, not left as known issues.

As always, this is not a substitute for a real `flutter analyze`/`flutter
run -d chrome` on your machine — please run both and send back anything
they report (file, line, exact error text) and it'll get fixed directly.

## 14. UI polish — chrome-less shell, bolder type, subtle shadows, compact dashboard (this round)

This round is a **visual-only** pass on top of §12/§13 — no screen, route,
backend call, bonus formula, or local-storage schema changed. Exactly three
Dart files were edited and one file was deleted; nothing else.

### Top navbar removed (`screens/main_shell.dart`, `widgets/app_top_bar.dart` deleted)

The `AppBar` that previously sat above the five tabs is gone. `MainShell`'s
`Scaffold` no longer has an `appBar:` at all — its body is now
`SafeArea(child: IndexedStack(...))`, so content still starts below the
status bar/notch, it just no longer has a navy bar with the logo/title
above it. The bottom `NavigationBar` (Dashboard, Reports, Results, Account,
Settings) is unchanged.

`widgets/app_top_bar.dart` (the `AppTopBar` widget that navbar used) is no
longer referenced anywhere and was **deleted** from the project. A zip that
only contains changed files can't represent a deletion, so this is called
out explicitly here and in the delivery message — **please delete
`lib/widgets/app_top_bar.dart` from your local project by hand** after
copying in the files from this round's zip; nothing else imports it, so
leaving it in place is harmless (just dead code) but removing it keeps the
tree accurate.

Screens reached by pushing (Upload, Processing, a specific report's
Results, User Detail, Terms) keep their own `Scaffold(appBar: AppBar(...))`
— that's a back button for a screen outside the five tabs, not the
"navbar" the brief asked to remove, so those were intentionally left alone.
`widgets/app_logo.dart` (`AppLogo`, used on the login screen) is a
different, unrelated file and was not touched.

### Premium fintech type + shadows (`core/app_theme.dart`)

- Added `AppTheme.textStrong` (`#10141F`, near-black) and built a bolder
  `TextTheme` from it: headings/titles at `FontWeight.w800`/`w700` and body
  text at `w500`, all in `textStrong`. Every screen already reads its text
  styles from `Theme.of(context).textTheme`, so this one change makes
  headings, card values, and titles bold and high-contrast **everywhere**
  without editing each screen. Secondary/meta text that screens set
  explicitly (e.g. `Colors.black54` timestamps, hint labels) was left as
  is on purpose — the brief asked for headings/values/labels to be bold,
  not for every last piece of text to be the same weight; dimmer secondary
  text is what keeps a compact dashboard scannable.
- Bottom-nav labels: unselected tabs now render at `w600` (was regular
  weight) and selected at `w800`, both still white/white70 on navy, so
  every tab label is clearly legible, not just the active one.
- Cards: `CardThemeData.elevation` went from `0` to `1.5` with a soft
  low-opacity navy `shadowColor`, on top of the existing thin border — "flat
  outlined card" became "clean card with a subtle shadow," per the brief.
  The stale doc comment on `AppShadows` (which used to say cards have no
  shadow) was corrected to match.
- Brand colors (navy/blue/cyan/teal), spacing scale, and every other token
  are unchanged from §12.

### Dashboard compactness (`screens/dashboard_screen.dart`)

Spacing-only changes, no new/removed widgets and no data changes:
- Summary-card grid tiles are a little shorter (`childAspectRatio` `1.5` →
  `1.3`), so six cards read as a tighter grid with less empty vertical
  space inside each one.
- The empty-state "Latest report" and "Recent activity" cards use tighter,
  more even padding instead of the previous large uniform padding.
- The gap above "Recent activity" and the bottom trailing gap were both
  reduced by one spacing step.

### What did not change

Same as every round before it: no backend endpoint changed, no bonus/
eligibility calculation changed, no existing screen was removed or
replaced with a placeholder, and no mock data was introduced anywhere.

### Verification (same limitation as every prior round)

This sandbox still has no Flutter/Dart SDK and no network access to
pub.dev, so `flutter analyze` and `flutter run -d chrome` could not
actually be executed here — same as every round before this one. What was
done instead: the three files were hand-edited carefully (matching the
project's existing `TextTheme`/`CardThemeData`/`NavigationBarThemeData`
API usage elsewhere in the file), then an independent review pass (a
fresh subagent that hadn't seen the edits) checked all three changed
files plus a whole-tree grep for `app_top_bar`/`AppTopBar` — it came back
clean: no dangling references to the deleted file, `AppLogo` untouched,
`_accountIndex`/`_goToTab` wiring intact, brace/paren balance fine in all
three files. Please run `flutter analyze` and `flutter run -d chrome` on
your machine and send back anything they report.
