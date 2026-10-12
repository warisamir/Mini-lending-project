# Failure and edge-case log

Every failure hit during the work, its cause, the fix, and the edge cases for each function involved. Decisions behind the fixes are in [decision.md](decision.md).

Format:

```
## C-NNN: <short title>
- Date:
- Where: file / function
- Symptom: exact error or observed behaviour
- Cause: verified root cause (or "unverified" with what was ruled out)
- Fix: what changed, with decision reference
- Verified by: test or command that proves the fix
```

---

## Failures

### C-001: Startup fails with `invalid value for parameter "TimeZone": "Asia/Calcutta"`
- Date: 2026-10-11
- Where: Flyway / JPA startup, and the test context (`contextLoads`)
- Symptom: `FATAL: invalid value for parameter "TimeZone": "Asia/Calcutta"`
- Cause: The host JVM zone is Windows `Asia/Calcutta`. The driver sends it as the session `TimeZone`. Verified: `SET TimeZone='Asia/Calcutta'` fails on both `postgres:latest` and `postgres:18`, while `Asia/Kolkata` works.
- Fix: `-Duser.timezone=UTC` in Surefire `argLine`, Spring Boot plugin `jvmArguments`, and the Dockerfile. See D-001.
- Verified by: `mvn test` (22/22 at the time), `spring-boot:run` reaching readiness 200.

### C-002: Test config class not visible from a sub-package
- Date: 2026-10-11
- Where: `TestcontainersConfiguration`
- Symptom: `is not public in com.waris.lending.payment_service; cannot be accessed from outside package`
- Cause: The class was package-private and the test lived in `payment/`.
- Fix: made the class `public`. Kept after the rollback as configuration.
- Verified by: test compilation.

### C-003: Wrong error when the password is missing (`password authentication failed`)
- Date: 2026-10-11
- Where: `application.yaml` → `spring.datasource.password`
- Symptom: With no `POSTGRES_PASSWORD` set, startup failed with `FATAL: password authentication failed for user "lending_user"`, even though the password in `.env` was correct.
- Cause: Spring Boot leaves an unresolved `${POSTGRES_PASSWORD}` as the literal text, and the driver sent that. Verified: the same `.env` value works with `psql` inside the container.
- Fix: Read `./.env` through `spring.config.import` (D-005). A real fail-fast check is still missing (open item).
- Verified by: `mvn spring-boot:run` with `POSTGRES_PASSWORD` unset → readiness 200.
- Edge cases still open:
  - Started from another directory: `./.env` does not resolve. Fails with the same misleading error.
  - `.env` has a password with a trailing space or `#`: Spring properties parsing may truncate it. Not tested.

### C-004: Port 8081 busy while running locally
- Date: 2026-10-11
- Where: `docker compose` + local `spring-boot:run`
- Symptom: Local start conflicted with the container on port 8081.
- Cause: The app container was still running.
- Fix: stopped the container before the local run. Container removed later on request.
- Edge case: compose maps `127.0.0.1:8081`. Any other local run on that port fails to bind. Check with `docker ps` first.

### C-005: Compose edit rejected
- Date: 2026-10-11
- Where: `docker-compose.yml` (root)
- Symptom: `File has not been read yet`
- Cause: The file was not read in this session before editing.
- Fix: read the section, then edited. No functional impact.

### C-006: Edit tool could not match multi-line `pom.xml` blocks
- Date: 2026-10-11
- Where: `pom.xml`
- Symptom: `String to replace not found in file.`
- Cause: Indentation in the search string did not match the file (tabs and line endings).
- Fix: anchored on a single unique line (`<artifactId>spring-boot-maven-plugin</artifactId>`).
- Verified by: the next Maven build and run.

### C-007: Compile error: record accessor clash
- Date: 2026-10-11
- Where: `PaymentGateway.ChargeResult`
- Symptom: `invalid accessor method in record ... approved() must match the type of record component approved`
- Cause: The static factory `approved()` has the same name as the record component accessor.
- Fix: Renamed the factories to `approve()` and `decline(reason)`.
- Verified by: successful `mvn compile`.

### C-008: `sed` edit added a stray closing bracket risk
- Date: 2026-10-11
- Where: `PaymentApiIntegrationTest.java`
- Symptom: none observed. I checked the lines after the bulk edit and they were correct.
- Cause: Bulk regex replacement on test code.
- Lesson: check each line after a regex edit, or use the Edit tool for targeted changes.

### C-009: Background Maven run reported exit 127
- Date: 2026-10-11
- Where: background `mvn spring-boot:run` task
- Symptom: `failed with exit code 127`
- Cause: I stopped the Java process myself to clean up. Expected, not a defect.

---

## Per-function failure modes and edge cases

These describe what each function does and what it must handle. Status is one of: **tested**, **designed** (no code yet), or **open**.

### `PaymentService.createPayment(key, request)`
| Case | Expected | Status |
|---|---|---|
| New key | 201, `SUCCESS` / `FAILED` / `PENDING` | tested (earlier draft) |
| Same key, same body | 200, original payment, no second charge | tested |
| Same key, different body | 409 | tested |
| Two concurrent requests, same key | one insert wins, the other replays it | designed, race not load-tested |
| Gateway throws after `PROCESSING` | `PENDING` | tested |
| Process crashes after `PROCESSING` | sweeper → `PENDING` after 5 min | tested (sweeper unit-level) |
| Database down during first insert | 500, nothing charged | designed |
| Database down after gateway approves | payment stays `PROCESSING`, sweeper → `PENDING`. Money moved, so reconciliation must find it | open: needs reconciliation job |
| Amount `0`, negative, >4 decimals, >15 integer digits | 400 | tested |
| Currency not `[A-Z]{3}` | 400 | tested |
| Missing `Idempotency-Key` | 400, no charge | tested |
| Key longer than 64 chars or with spaces | 400 | tested (pattern) |
| `"100"` vs `"100.00"` same key | treated as same request | tested |

### `Payment.transitionTo(next, now)`
| Case | Expected | Status |
|---|---|---|
| Valid transition | status and `updatedAt` change | tested |
| Terminal state (`SUCCESS`, `FAILED`) | `IllegalStateException` | tested |
| Skip `PROCESSING` | `IllegalStateException` | tested |
| `PENDING → SUCCESS/FAILED` | allowed (reconciliation) | tested |

### `Payment.markFailed(reason, now)` / `markPending(reason, now)`
| Case | Expected | Status |
|---|---|---|
| Reason longer than 255 | truncated to 255 | tested |
| Reason `null` | stored as null | open: not tested |

### `CreatePaymentRequest.fingerprint()`
| Case | Expected | Status |
|---|---|---|
| Equivalent amounts (`1E+2`, `100.0`, `100.00`) | same hash | tested |
| Different amount, currency, loan, or user | different hash | tested |
| Currency omitted | defaults to INR | tested |
| Amount with 5 decimals | rejected by `@Digits(fraction=4)` before hashing | tested via validation |

### `StalePaymentSweeper.markStalePaymentsPending()`
| Case | Expected | Status |
|---|---|---|
| Row `PROCESSING` older than cutoff | → `PENDING`, version +1 | tested |
| Row `PROCESSING` newer than cutoff | unchanged | open: not asserted |
| Row `SUCCESS` or `FAILED` old | unchanged | open: not asserted |
| Two app instances run the sweeper | both update, one wins per row (version) | open: needs a lock or single-leader |

### `PaymentController.listByUser(userId, page, size)`
| Case | Expected | Status |
|---|---|---|
| Page size over 100 | 400 | tested via validation (not explicitly asserted) |
| Page negative | 400 | open |
| Unknown user | empty page | open |

### `SimulatedPaymentGateway.charge(request)`
| Case | Expected | Status |
|---|---|---|
| Any charge | approved | tested (mocked in integration tests) |
| Enabled in production | must not be | open: add a startup guard before go-live |

### Events (designed, not built)
| Case | Expected | Status |
|---|---|---|
| Kafka down | outbox keeps rows, relay retries | designed |
| Consumer receives duplicate | dedupe on `eventId` | designed |
| Poison message | DLT after retries | designed |

---

## Open items from this log
1. Real fail-fast startup check for a missing `POSTGRES_PASSWORD` (C-003).
2. Reconciliation job for payments stuck in `PENDING` after an approved charge (per-function table).
3. Sweeper lock or single-leader for multiple instances.
4. Startup guard so the simulated gateway cannot run in production.
5. Decide whether the password lives in one `.env` file or two (D-005).
