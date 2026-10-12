# Decision log

Every decision that changes code, config, or the design is recorded here, newest at the bottom. Each entry gives the context, the decision, the alternatives considered, and why. Failures and edge cases go in [coomo.md](coomo.md).

Format:

```
## D-NNN: <short title>
- Date: YYYY-MM-DD
- Context: what problem or choice came up
- Decision: what was done
- Alternatives: what else was considered
- Why: the reason for this choice
- Status: active | superseded by D-NNN | reverted
```

---

## D-001: Run the JVM in UTC, not the host zone
- Date: 2026-10-11
- Context: Startup failed with `FATAL: invalid value for parameter "TimeZone": "Asia/Calcutta"`. The host JVM uses the Windows zone name, and the PostgreSQL images reject it.
- Decision: Set `-Duser.timezone=UTC` in three places: Surefire `argLine` (tests), Spring Boot Maven plugin `jvmArguments` (local runs), and the Dockerfile `JAVA_TOOL_OPTIONS`.
- Alternatives: Set `spring.jpa.properties.hibernate.jdbc.time_zone` only (does not fix the driver's startup `TimeZone` parameter); add a `TimeZone.setDefault` in `main()` (covers `java -jar` but not tests or IDE runs).
- Why: All timestamps are `TIMESTAMPTZ`, so UTC is the correct zone, and the JVM setting covers every run path.
- Status: active

## D-002: Pin Testcontainers to PostgreSQL 18
- Date: 2026-10-11
- Context: Tests used `postgres:latest`. Production compose uses `postgres:18`.
- Decision: `TestcontainersConfiguration` uses `postgres:18`.
- Alternatives: keep `latest` (drifts silently with new majors).
- Why: Tests should run against the same engine as production. The `TimeZone` problem also reproduced on `latest`.
- Status: active

## D-003: No default database password
- Date: 2026-10-11
- Context: `application.yaml` had `${POSTGRES_PASSWORD:change_me}`, a committed default secret.
- Decision: Removed the default: `password: ${POSTGRES_PASSWORD}`.
- Alternatives: keep the default (risk of running with a known password in production).
- Why: A committed default secret is a production risk.
- Consequence: an unset variable now produces a misleading auth error (see coomo.md C-003). Mitigated by D-005.
- Status: active

## D-004: Payment state machine with explicit transitions
- Date: 2026-10-11
- Context: Need to prevent illegal status changes such as `FAILED → SUCCESS`.
- Decision: `PaymentStatus.canTransitionTo()` allows only: `CREATED→PROCESSING`; `PROCESSING→SUCCESS|FAILED|PENDING`; `PENDING→SUCCESS|FAILED`; `SUCCESS` and `FAILED` are terminal. The entity throws `IllegalStateException` on an illegal move.
- Alternatives: allow any transition and rely on the DB CHECK constraint (only checks allowed values, not sequences).
- Why: Money state must not move backwards. The rules live in one place and are unit-tested.
- Status: active (rules to be re-checked against the reconciliation design)

## D-005: Read the root `.env` for local runs
- Date: 2026-10-11
- Context: `mvn spring-boot:run` and IntelliJ do not load the root `.env`, so `${POSTGRES_PASSWORD}` was passed literally to the driver (see coomo.md C-003).
- Decision: `spring.config.import: optional:file:./.env[.properties]` in `application.yaml`, plus `payment-service/.env` with the three `POSTGRES_*` keys. Real environment variables still win.
- Alternatives: (a) `../.env` from the repo root (works, but the user later created the service-local file); (b) fail-fast startup check (not added yet).
- Why: Gives local runs the same secrets as compose without exporting variables by hand.
- Consequence: the password now exists in two gitignored files. They must be kept in sync. Open for a single-file decision.
- Status: active

## D-006: Keep the gateway as a stub behind a `PaymentGateway` port
- Date: 2026-10-11
- Context: No payment provider was chosen. The provider call must not be inside a DB transaction.
- Decision: A `PaymentGateway` interface with a `SimulatedPaymentGateway` enabled only when `payment.gateway.mode=simulated`, default in `application.yaml`. The service calls the gateway outside any transaction, and any exception becomes `PENDING`.
- Alternatives: call a real provider now (no provider chosen); hard-code approval (no port, hard to test).
- Why: Keeps the state machine and API testable without a provider. Makes the stub explicit so it cannot be mistaken for a real integration.
- Status: active. The simulated mode must be disabled before live money.

## D-007: Idempotency by key, with a request fingerprint
- Date: 2026-10-11
- Context: Clients retry requests; a retry must not charge twice. A reused key with a different body is a client bug.
- Decision: The `Idempotency-Key` is unique in the DB. The entity stores a SHA-256 of canonical fields (loanId, userId, amount normalised with `stripTrailingZeros`, currency). Same key and same hash returns the original with 200. Same key and different hash returns 409. A race on insert falls back to the winner.
- Alternatives: key per user (weaker, the DB constraint would need to change); store the full body (larger, same information).
- Why: Simple, safe, and it handles concurrent duplicates through the unique constraint.
- Status: active

## D-008: Gateway call outside the DB transaction, three short transactions
- Date: 2026-10-11
- Context: A slow provider must not hold a DB connection, and a crash must leave a visible state.
- Decision: (1) insert `CREATED`; (2) `PROCESSING`; (3) call the gateway; (4) update to the final state. Each step is its own transaction via `TransactionTemplate`.
- Alternatives: one transaction around the whole call (holds a connection during network I/O and rolls back a real charge on a crash).
- Why: No charge is silently lost, and connections stay free.
- Status: active

## D-009: Timeouts become `PENDING`, never `FAILED`
- Date: 2026-10-11
- Context: A timeout does not tell us whether the provider charged the customer.
- Decision: Any exception from the gateway → `PENDING` with reason "Gateway outcome unknown". Only an explicit decline → `FAILED`.
- Alternatives: mark `FAILED` and let the customer retry (risks a double charge).
- Why: Safe for money. Resolved later by reconciliation.
- Status: active

## D-010: Stale `PROCESSING` sweeper
- Date: 2026-10-11
- Context: A crash between steps 2 and 4 of D-008 leaves a row in `PROCESSING` forever.
- Decision: `StalePaymentSweeper` runs every minute and moves `PROCESSING` rows older than 5 minutes to `PENDING`, bumping `version`.
- Alternatives: retry automatically (risks double charge); leave for manual handling (does not scale).
- Why: Makes the unknown state visible and queueable for reconciliation.
- Status: active (in the reverted draft; to be rebuilt)

## D-011: Problem+JSON errors, no internals in 500s
- Date: 2026-10-11
- Context: Need stable, machine-readable errors.
- Decision: RFC 9457 `ProblemDetail` with a stable `type` URI (`https://lending.local/problems/<slug>`). Unexpected exceptions fall through to Spring's generic 500.
- Alternatives: custom error envelope (non-standard); expose exception messages (leaks internals).
- Why: Standard format, and clients can switch on `type`.
- Status: active

## D-012: Expose `OptimisticLockingFailureException` as 409
- Date: 2026-10-11
- Context: Concurrent updates with `@Version` throw a Spring exception that can surface either as `ObjectOptimisticLockingFailureException` or as its base class.
- Decision: Handle the base class `OptimisticLockingFailureException` in the advice → 409 "Concurrent update".
- Alternatives: handle only the subclass (may miss commit-time translations).
- Why: Covers both paths.
- Status: active

## D-013: Store the event envelope through an outbox (design)
- Date: 2026-10-11
- Context: Events must be published whenever state changes and never without it.
- Decision: Producers write to an `outbox_events` table in the same transaction as the state change. A relay publishes to Kafka. Consumers dedupe on `eventId`.
- Alternatives: publish directly after commit (lost events on crash); distributed transaction (not supported by Kafka).
- Why: At-least-once delivery without dual writes.
- Status: design only. Not built yet.

## D-014: Database per service on one Postgres instance (design)
- Date: 2026-10-11
- Context: Four services, one EC2 host.
- Decision: One Postgres instance with one database and one user per service. Services never read each other's tables.
- Alternatives: one shared database (coupling); one instance per service (more operational cost now).
- Why: Ownership is enforced without extra infrastructure. Can split later.
- Status: design only.

## D-015: Git hygiene
- Date: 2026-10-11
- Context: Earlier in the session I made no commits. The index holds an empty staged `V1__create_payments.sql`.
- Decision: Nothing is committed or pushed until the user says so. Untracked junk (`1`, `.docker-compose.yml.swo`) is left in place.
- Alternatives: clean up or commit now.
- Why: Commits and pushes are outward-facing; junk files belong to the user until confirmed.
- Status: active

## D-016: Remove the rebuilt payment code when asked
- Date: 2026-10-11
- Context: User asked to remove all code added in this session except configuration.
- Decision: Deleted the payment domain, config class, tests, and the rewritten main class. Kept `pom.xml`, `application.yaml`, the Testcontainers config, `Dockerfile`, `.dockerignore`, and the compose service block. Stopped the app containers and processes that I started.
- Alternatives: keep the code in a branch (not requested).
- Why: Explicit instruction. Config kept as requested.
- Status: done. The rebuild restarts from the design (D-013, D-014).

## D-017: System design as the source for the rebuild
- Date: 2026-10-11
- Context: Need a shared plan before more code.
- Decision: `docs/system-design.md` is the design of record. It lists assumptions and open questions (§14).
- Alternatives: start coding immediately (risk of building the wrong business rules).
- Why: Business rules (interest method, default threshold, disbursement, provider) are not decided. The design makes them explicit.
- Status: draft v1, awaiting answers to §14.
