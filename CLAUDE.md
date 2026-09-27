# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project status

**Pre-implementation.** Planning is finalized (see `docs/planning/Cafe-Reservierungssystem-Planung.md`,
in German), but `src/`, `frontend/`, `tests/`, and `deploy/` are still empty placeholder directories —
no code, solution file, Dockerfile, or CI config exists yet. There are no build/lint/test commands to
run yet either. When starting implementation, follow the repo layout, tech stack, and conventions
below exactly as planned rather than improvising new ones — the plan is the source of truth until code
exists to override it.

If asked to look up rationale beyond what's summarized here (e.g. "why Postgres exclusion constraints
over app-level locking"), read the planning doc directly — it's organized in numbered `Schritt` (step)
sections and contains the full reasoning.

## What this is

A café management platform, starting with a **table reservation module**, built as a portfolio project
(intended for public GitHub release, MIT licensed). Designed multi-tenant and modular from day one so
further modules (waitlist, POS, inventory, staff scheduling, etc. — explicitly out of scope for v1)
can be added later without reworking existing modules.

## Scope: what v1 actually is

**v1 must-haves**: guest reservation flow (soft lock → booking → email confirmation, race-condition-
safe, idempotent), live availability updates via SignalR, staff login with tenant isolation, staff
reservation overview.

**v1 should-haves** (build after the must-haves work): guest self-cancellation within the deadline,
staff can create a manual reservation (phone booking), owner can manage staff accounts.

**Explicitly not v1** — do not build these unless asked, even though they're mentioned in the planning
doc as future direction: guest waitlist, guest accounts, payment/POS, inventory, staff scheduling,
owner UI for managing tables (v1 tables are seeded, not editable via UI), tenant onboarding flow
(v1 has exactly one seeded tenant), Grafana/monitoring dashboard.

**Build order**: follow the milestones in `Schritt 13`/the task backlog in `Schritt 15` of the planning
doc (M1 Fundament → M2 core reservation logic → M3 API/realtime → M4 frontend → M5 production
readiness). If it's unclear which milestone is currently active, ask rather than assuming.

## Development environment

- **OS**: currently Windows, a switch to macOS is planned — give commands that work on both, or ask
  which OS is active, rather than assuming one. PowerShell does not support `mkdir -p`; Mac
  Terminal/zsh does.
- **IDE**: JetBrains Rider (free for non-commercial use since late 2024) — covers both C#/.NET and
  Angular/TypeScript, works identically on Windows/macOS.
- **DB tooling**: PostgreSQL via Rider's built-in DB client (no separate tool); Redis via RedisInsight
  (key/value/TTL inspection — useful for verifying the soft-lock behavior).
- **Prerequisites**: .NET SDK, Node.js/npm, Docker Desktop, Git.

## Architecture

**Modular monolith**, single deployable, with strict internal module boundaries:

- `Cafe.Api` — ASP.NET Core host (Program.cs, DI wiring, controllers/endpoints)
- `Cafe.Modules.Reservation` — table/slot management, availability, booking logic
- `Cafe.Modules.IdentityAccess` — staff login, multi-tenancy, roles (not for guests)
- `Cafe.Modules.Notification` — email sending, decoupled so other modules can trigger it later
- `Cafe.SharedKernel` — minimal cross-module contracts/base types only

Each module is internally split into `Domain` (entities, business rules), `Application` (use cases,
interfaces), `Infrastructure` (EF Core config, repositories). Entities and DB access are `internal` —
other modules never touch another module's tables directly. Two allowed inter-module communication
paths:

- **Synchronous, via interface**: e.g. `Reservation` asks `IdentityAccess` for the current
  tenant/role via `ICurrentUserContext`.
- **Asynchronous, via in-process domain events (MediatR)**: e.g. `Reservation` raises
  `ReservationConfirmed`; `Notification` subscribes and sends the email. Used whenever the triggering
  module shouldn't know about the reacting module.

This split is deliberate prep for an eventual microservices split (refactor, not rewrite) without
paying orchestration cost from day one.

### Planned repo layout

```
/src
  Cafe.Api/
  Cafe.Modules.Reservation/       (Domain / Application / Infrastructure)
  Cafe.Modules.IdentityAccess/
  Cafe.Modules.Notification/
  Cafe.SharedKernel/
/tests
  Cafe.Modules.Reservation.Tests/
  Cafe.Modules.IdentityAccess.Tests/
  Cafe.IntegrationTests/          (race-condition tests against real Postgres/Redis via Testcontainers)
/frontend
  cafe-admin-app/                 (Angular)
/docs
  adr/                            (Architecture Decision Records, one file per decision)
  diagrams/
  planning/                       (planning doc, source of truth pre-implementation)
/deploy
  docker-compose.yml
  k8s/                            (later)
```

## Tech stack

- **Backend**: C# / .NET, ASP.NET Core
- **ORM**: EF Core + Npgsql. Exclusion constraints (`tsrange` + GIST index, to prevent overlapping
  reservations at the DB level) are **not** supported natively by EF Core's model configuration —
  they must be added as raw SQL in the generated migration by hand.
- **Primary DB**: PostgreSQL — source of truth; final booking correctness enforced via exclusion
  constraints / unique constraints at the DB level, not just app logic.
- **Cache/ephemeral store**: Redis — two jobs: (1) soft-lock on a slot with TTL (`SET NX EX`,
  self-expiring, no cleanup job needed), (2) SignalR backplane for cross-instance live updates.
- **Realtime**: SignalR (`/hubs/availability`) with Redis backplane, so updates reach clients on every
  instance once horizontally scaled.
- **Frontend**: Angular, official SignalR JS client, TypeScript.
- **Backend tests**: xUnit; integration tests via Testcontainers (real Postgres/Redis, no DB mocking —
  the DB/cache interplay itself is what's under test); E2E via Playwright.
- **Frontend tests**: Jest (not Karma/Jasmine).
- Primary keys are **UUIDv7** (`Guid.CreateVersion7()`), not v4 — time-ordered for index locality,
  still globally unique.

## Key domain/API decisions

- **Auth**: HttpOnly cookie + anti-forgery token, not JWT in localStorage (trades XSS-token-theft risk
  for CSRF, mitigated by the anti-forgery token) — deliberate choice for the admin area.
- **Multi-tenancy**: `TenantId` is a mandatory field on every relevant entity (not just implied via
  relations), so tenant isolation can be enforced on every single query directly. Every endpoint with a
  `tenantId` in its route must additionally verify server-side that the logged-in user belongs to that
  exact tenant (broken-access-control protection) — v1 has exactly one tenant (seeded), but the field
  is mandatory from the start so a future onboarding module doesn't require a schema break.
- **Booking flow**: soft lock in Redis only (no DB row) → guest submits contact details → DB row
  created with `Status=AwaitingConfirmation` → confirmation email → guest clicks link →
  `Status=Confirmed`. If the lock expires first, no DB row is ever created. Unconfirmed reservations
  are expired by a background job after timeout.
- **Cancellation**: guest can self-cancel via link in the confirmation email, but only up to a
  configurable deadline (24–48h before the reservation start, exact value in app config, not
  per-tenant in v1). Cancellation past the deadline → `422`.
- **Idempotency**: `Idempotency-Key` header is mandatory on booking-creating POST requests.
- **Booking status codes**: `409` slot already taken, `410` soft lock expired, `422` invalid state
  transition (e.g. cancel after the cancellation deadline).
- **API style**: REST, JSON, URL versioning (`/api/v1/...`), OpenAPI via Swashbuckle/Swagger UI, error
  format is RFC 7807 Problem Details (`{type, title, status, detail, traceId}`) — never leak
  stack traces or raw DB errors.
- **Logging**: structured (Serilog), every line carries `traceId` + `tenantId`; `traceId` matches the
  one returned in the Problem Details response body. No secrets/passwords/full tokens in logs.
- Roles in v1 are deliberately coarse: `Owner` (full rights) and `Mitarbeiter`/staff (view/edit
  reservations, no settings) — no granular permission system.

## Success criteria (what "correct" means for v1)

- Race-condition test: N parallel requests on the same slot → exactly one succeeds.
- Idempotency test: same `Idempotency-Key` sent twice → no duplicate reservation.
- Tenant isolation test: request against another tenant's data → `403`/`404`, never `200`, even via
  direct API manipulation.
- Live-update test: slot status change is visible to all connected clients without a manual reload.
- Basic security checks pass (no secrets in the repo, CodeQL clean).
- Load targets: not yet quantified — treat as an open item, don't invent numbers.

## Data model

```
TENANT(Id, Name)
TISCH(Id, TenantId, Bezeichnung, Kapazitaet)
MITARBEITER(Id, TenantId, Email, PasswordHash, Rolle, IstAktiv)
RESERVIERUNG(Id, TenantId, TischId, GastName, GastEmail, Start, Ende, Status,
             BestaetigungsToken, StornoToken, ErstelltAm)
```
`TenantId` on every table (see Multi-tenancy above). All ids are UUIDv7. `RESERVIERUNG.Status`:
`AwaitingConfirmation` → `Confirmed` / `Expired` / `Cancelled`.

## Planned API endpoints

Public (guest, no auth):
- `GET /api/v1/tenants/{tenantId}/availability?date=`
- `POST /api/v1/tenants/{tenantId}/reservations/lock` → `lockToken` + TTL
- `POST /api/v1/reservations` (`lockToken` + guest data, `Idempotency-Key` required)
- `GET /api/v1/reservations/confirm?token=`
- `GET /api/v1/reservations/cancel?token=`

Admin (staff/owner, cookie auth):
- `POST /api/v1/auth/login`
- `GET /api/v1/tenants/{tenantId}/reservations?date=`
- `PATCH /api/v1/reservations/{id}`
- `POST /api/v1/tenants/{tenantId}/reservations/manual`
- `POST /api/v1/tenants/{tenantId}/staff` (owner only)
- `PATCH /api/v1/staff/{id}` (owner only)

Realtime: SignalR hub `/hubs/availability`, clients subscribe by `tenantId`, receive
`SlotStatusChanged` events.

## Security

- **Password hashing**: ASP.NET Core Identity's built-in hashing (PBKDF2) — do not build a custom
  scheme.
- **Rate limiting**: built-in ASP.NET Core Rate Limiting middleware (.NET 7+), applied to the public
  booking endpoints **and** explicitly to the `lock` endpoint too — locking without ever booking is a
  realistic abuse vector ("denial of inventory": tying up all slots without completing a reservation).
- **Input validation**: FluentValidation, declarative rules per DTO.
- **CORS**: only the app's own frontend origin is allowed.
- **Security headers**: HSTS, Content-Security-Policy, `X-Content-Type-Options: nosniff`.
- **Audit log**: a separate log for admin actions (who edited/cancelled which reservation, when),
  distinct from the general structured application log.
- **Data retention (GDPR)**: guest name/email are personal data — a retention period (e.g. automatic
  deletion N months after the reservation date) and an actual deletion background job need to exist;
  a cancel endpoint alone does not satisfy deletion requirements.
- Already covered elsewhere in this file and not repeated here: injection protection (parameterized
  queries/EF Core only), XSS/CSRF protection (see Auth above), tenant-boundary enforcement (see
  Multi-tenancy above).

## Conventions (from the plan, apply once code exists)

- **Testing approach**: not blanket TDD. Test-first (red-green-refactor) specifically for the
  Reservation module's core logic (concurrency, idempotency, locking) — expected behavior is
  specifiable upfront there. Test-after for simple CRUD endpoints and the Angular frontend. For
  unfamiliar tech (EF Core exclusion constraints, Redis locking pattern, SignalR backplane), do a
  short throwaway spike first to understand the behavior before writing the real test.
- C#: PascalCase, namespaces mirror folder structure (`Cafe.Modules.Reservation.Domain`).
- Angular: kebab-case file/component names.
- Branches: `feature/<desc>`, `fix/<desc>`, `chore/<desc>` (GitHub Flow — no long-lived
  `develop`/`release` branches).
- Commits: Conventional Commits (`feat:`, `fix:`, `docs:`, `refactor:`, `test:`, `chore:`).
- Architecturally significant changes should come with a new/updated ADR under `docs/adr/`
  (format: Kontext / Entscheidung / Konsequenzen).
- XML doc comments (`/// <summary>`) on public C# interfaces/methods only where the *why* isn't
  obvious from the code itself (e.g. "why this TTL is 5 minutes").
- No blanket coverage target — critical paths (booking logic, auth/access control, tenant isolation)
  must be fully covered; Coverlet is for visibility/badge, not a CI gate.
- Test data via builder pattern (e.g. `ReservationBuilder.ForTable(x).AtSlot(y).Build()`).
- Definition of Done per PR: tests green, CI green, ADR added/updated if architecturally relevant,
  README updated if needed.

## Planned CI/CD (GitHub Actions, not yet implemented)

**CI**, on every push/PR against `main`: build (`dotnet build`, `ng build`) → lint/format
(`dotnet format --verify-no-changes`, ESLint) → unit tests (xUnit + Jest) → integration tests
(Testcontainers via GitHub Actions service containers) → CodeQL security scan → Coverlet coverage
report (artifact only, not a gate). Branch protection requires all steps green before merge.
Dependabot is enabled for dependency updates. No pre-commit hooks by design (solo project; CI catches
formatting/lint issues).

**CD**: on merge to `main`, build a Docker image and push to GitHub Container Registry (GHCR). Actual
deployment stays manual in v1 (`docker compose pull && up` on a single small server/VPS). No automated
deploy target yet.

**Hosting**: v1 runs on Docker Compose on one small server. A later stage moves to Azure (Container
Apps or AKS), since that's the stack used at the author's job — the container/Kubernetes prep in this
architecture is deliberate groundwork for that move, not for v1 itself. Environment separation via
`appsettings.{Environment}.json` + env vars; Helm charts are explicitly not a v1 concern.