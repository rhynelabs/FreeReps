# Incidents

Postmortems for things that broke. One section per incident, newest first.

Add an entry after fixing something that was not obvious — the kind of failure
where the useful question six months later is "have I seen this before?". Skip
routine config changes, dependency bumps, and one-line typos.

Structure per entry: **symptoms** (what was visible), **root cause** (concrete:
component, version, why), **fix** (what changed), **lesson** (one line,
actionable).

The entries below were written on 2026-08-04 from the commit history. Their
symptoms are as recorded in the commit messages; where a commit did not say how
the fix was verified, this file does not claim it was.

---

## 2026-09-14 — Route and metric ingest requests failed with "deadlock detected" after the one-transaction change

**Symptoms.** Build `fork-fc64d29`, deployed at 20:34 CEST. Between 20:34 and
20:44 the server log showed, four times in a row,

    processing workouts: inserting workouts: inserting workout routes: ERROR: deadlock detected (SQLSTATE 40P01)

each time on three concurrent workout-route requests of an older-data run — one
workout per request, 140–3,600 GPS points, different workouts in different
weeks of 2022 — and once

    processing metrics: inserting health metrics: ERROR: deadlock detected (SQLSTATE 40P01)

on one 5,000-row `health_metrics` batch while six batches of the same category
were in flight. The `context canceled` errors that followed were the app
cancelling the sibling requests of a failed window. The run's 2022 route
windows failed; the app gives such a window up after its retries and carries on
with the next (commit `39618b0`), so the data was left for a later pass rather
than lost.

**Root cause.** Commit `fc64d29`, deployed as that build, had put a request's
workouts insert and its point inserts into one transaction, where before each
workout had been committed on its own before its points. The transaction holds
`RowExclusiveLock` on `workouts` from its first statement until commit.
`workout_routes` and `workout_heart_rate` are TimescaleDB hypertables whose
`workout_id` references `workouts(id)`; when an insert lands in a week with no
chunk yet, TimescaleDB creates the chunk inside the inserting transaction and
copies the hypertable's constraints onto it, the foreign key included, and
adding a foreign key takes `ShareRowExclusiveLock` on the referenced table —
which conflicts with a `RowExclusiveLock` held by anyone else. The 2022 routes
were new territory, so every request needed a chunk.

The Postgres log at 18:44:23 UTC (20:44:23 CEST) shows the cycle. Three
backends, each running the multi-row `INSERT INTO workout_routes` of a
different request:

- process A `waits for ShareUpdateExclusiveLock on relation <workout_routes>`
  — the hypertable, to create its chunk — `blocked by process` B;
- B `waits for ShareRowExclusiveLock on relation <workouts>` — copying the
  foreign key onto its new chunk — blocked by C, which holds
  `RowExclusiveLock` on `workouts` from the workouts insert of the same
  transaction;
- C `waits for ShareUpdateExclusiveLock on relation <workout_routes>`, blocked
  by A.

The `health_metrics` case has no foreign key. Its insert is `ON CONFLICT DO
UPDATE`, which locks each conflicting row as the statement reaches it, and the
rows were bound in arrival order — five type streams interleaved as the app
produced them. A retried window is cut into 5,000-row batches at different
boundaries than the cancelled attempt's, whose statements may still be running
on the server, so two statements can hold overlapping rows in different orders.
That reading fits the one occurrence; it was not confirmed from the Postgres
log the way the route cycle was.

**Fix.** Three changes in `server/internal/storage`:

- `InsertWorkoutBatch` commits the workouts in their own transaction before the
  points. The points transaction then holds only the foreign key's `KEY SHARE`
  on the workout rows, which `ShareRowExclusiveLock` does not conflict with,
  and the workouts transaction never creates a chunk because `workouts` is a
  plain table. A request that fails between the two commits leaves workouts
  without points until the app re-sends them, which it does.
- Every ingest bulk insert sorts its rows by the table's unique key before the
  statement — `health_metrics` in the order of `idx_health_metrics_dedup`, the
  two point tables by `(workout_id, time)`, `sleep_stages`, `category_samples`
  and `state_of_mind` likewise — so that two statements sharing rows wait on
  them in the same order.
- `withAsyncCommit` reruns the transaction on SQLSTATE `40P01` and `40001`, up
  to three attempts with a jittered pause of 50–200 ms that doubles, as long as
  the request is still alive. Every caller is an idempotent ingest write, which
  is what the helper exists for; the two that count rows inside the transaction
  reset their counts per attempt.

What would have caught it before deploy: an integration test that sends two
concurrent requests whose points land in weeks without chunks. Not written yet;
it is the follow-up to this entry.

**Lesson.** A hypertable with a foreign key creates that foreign key again on
every new chunk, inside the inserting transaction and with the DDL lock that
implies — the transaction that writes the referenced table must not be the one
that creates chunks.

---

## 2026-08-10 — The Alpha Progression history was stored twice, offset by the Berlin UTC offset

**Symptoms.** `get_strength_summary` reported 378 working sets and 171,869 kg of
tonnage for January 2026 against 11 training days, and 22 `sessions` for the same
month. `get_strength_intensity` and `get_strength_volume` carried the same
inflation, and the RIR distribution was weighted toward the duplicated period.
No tool output marked anything as duplicated; the numbers were merely twice what
they should have been.

Measured against the deployed database on 2026-08-10: 117 of 280 stored sessions
existed twice, spanning 2025-03-18 to 2026-02-19 — the entire Alpha history up to
that date, not a window within it. The two copies of a session were identical in
`session_name` and in every set, warm-ups included; they differed only in
`session_date`, by 3600 s for sessions in CET and 7200 s for sessions in CEST.

**Root cause.** `parseSessionDate` in `server/internal/ingest/alpha/parser.go`
read the export's session time with `time.ParseInLocation(layout, s, time.Local)`.
The Alpha CSV carries a bare wall clock with no zone, so the instant it produced
was a property of the host running the import:

- an import running in `Europe/Berlin` read `2026-01-02 9:22` as `08:22Z`,
- the deployed container has no `/etc/localtime` and no `TZ`, so Go's
  `time.Local` is UTC there, and the same line read as `09:22Z`.

`session_date` is part of `workout_sets_source_natural_key` (migration
`000020_hevy.up.sql`), so the `ON CONFLICT DO NOTHING` in `InsertWorkoutSets`
compared two different keys and inserted rather than skipped. The insert order in
`workout_sets.id` shows it directly: ids 1–2936 hold the Berlin-read copy of all
117 sessions, ids 2991–5926 the UTC-read copy of the same 117, written by the
import logged at 2026-02-25 17:12 UTC (`import_logs` id 7, 2990 rows received,
2990 inserted — nothing conflicted, because every key had moved).

`time.Local` reached the parser through commit `39de7f1` (2026-02-21), which
replaced `time.Parse` with `time.ParseInLocation` to fix a genuine bug: read as
UTC, the wall clock was wrong by the local offset. The fix was correct in intent
and wrong in mechanism — it made the timestamp depend on the environment instead
of on a stated zone.

Cross-checked against the `workouts` table, which holds Apple Health workouts
with real zoned timestamps: on all 117 days the Berlin-read copy lands within
−20 to +16 minutes of that day's `Traditional Strength Training` start, and the
UTC-read copy 56 to 136 minutes after it. The earlier copy is the true one.

**Fix.** Three commits:

- The parser takes the zone as a parameter, supplied from
  `ingest.session_timezone` (see [`DECISIONS.md`](DECISIONS.md), 2026-08-10).
  Covered by `TestParseIsIndependentOfProcessTimezone` and, against a real
  database, by `TestReimportUnderADifferentProcessTimezoneIsIdempotent`
  (`-tags integration`).
- Migration `000027_dedupe_alpha_sessions` deleted the later copy of every
  session whose name and full set signature matched another copy of the same
  session: 117 sessions, 2936 set rows, of which 2367 working sets.
- The 46 sessions imported after 2026-02-21 needed a second step. They were
  written by the container alone, in UTC, so they had no duplicate — they were
  an hour or two late, and with the importer now reading Europe/Berlin a
  re-import would have inserted a corrected copy beside each of them.
  A script was written to move them by `UPDATE`. Before it ran, the export was
  re-imported, which did the same thing by a different route: it wrote the
  correct instants as 1067 new rows beside the stale ones, brought in one
  genuinely new session (2026-08-08) and left the 117 corrected sessions
  untouched, as they now conflict. Migration
  `000028_dedupe_alpha_sessions_after_reimport` then deleted the stale copies
  under the same content-matched rule as 000027 — 1067 set rows in 46 sessions,
  876 of them working sets — and the script was removed as obsolete.

  The window between the two steps is the lesson within the lesson: a
  half-corrected table is a table where the next import duplicates the
  uncorrected half. Migration 000027 and this correction should have shipped
  together.

`sessions` in `get_strength_summary` counted distinct session start times, which
is what it still does; the 22 for an 11-day January was the duplication showing
through, not a counting error. The field is now documented as such and a
`training_days` count sits beside it, because the two differ on any day holding
more than one session and nothing said which was being reported.

**Lesson.** A timestamp that is part of a natural key must be computed from the
file and stated configuration only — never from the process environment, which
differs between the machine that develops an importer and the container that
runs it.

---

## 2026-04-08 — Alpha Progression sets with "N+" notation were dropped or read as zero

**Symptoms.** Strength training sets imported from Alpha Progression CSV were
missing from the workout detail view, and some that did arrive carried an RIR of
0. The import reported success and no error; the set count was simply lower than
the CSV's.

**Root cause.** Alpha Progression writes `5+` for "at least 5" in the reps, RIR
and weight columns. Two code paths in `server/internal/ingest/alpha/parser.go`
handled it differently, and both silently:

- `parseEuropeanFloat` returned 0 for `5+`, so an RIR of "5 or more" became 0 —
  the value that means "to failure".
- The reps column was matched by a strict `\d+` regex, which rejected `5+`, and
  the rejection dropped the whole set line rather than the one field.

**Fix.** The trailing `+` is stripped before parsing, so the numeric value
survives in both paths (commit `bb929f1`). The commit adds cases to
`parser_test.go` covering the notation in each column.

**Lesson.** A parser that returns a zero value on a format it does not know
turns a format gap into wrong data; return an error or normalize explicitly.

---

## 2026-03-26 — Sleep durations of 22 hours and more after the Oura integration

**Symptoms.** Sleep sessions showed impossible durations — 22 hours and above —
for nights where both Oura and Health Auto Export had delivered data. Correct
Oura sessions had been present earlier and were overwritten.

**Root cause.** The sleep session backfill in `server/internal/storage/sleep.go`
read all rows in `sleep_stages` for a date regardless of source and summed their
durations. With two sources reporting the same night, every stage was counted
twice. The backfill then wrote the result over the session a direct source had
already produced.

**Fix.** Commit `731b001`. The backfill uses `ON CONFLICT DO NOTHING`, so it only
creates sessions for dates that have none, and never overwrites a direct source.
Oura sync writes `sleep_analysis` metrics itself, so the dashboard chart no
longer depends on the backfill running.

**Lesson.** A derivation that aggregates across sources needs a source filter at
the point it reads, not a priority applied afterwards.

---

## 2026-03-25 — Respiratory rate 60× too high, SpO2 shown as 0.94 for one source and 94.5 for the other

**Symptoms.** After the Oura integration, respiratory rate read around 900 per
minute. SpO2 rendered as `0.94` for Apple Health values and `94.5` for Oura
values in the same chart.

**Root cause.** Two unit mismatches in `server/internal/oura/mapper.go`:

- The Oura OpenAPI specification documents `average_breath` as breaths per
  second. It is breaths per minute. The ingest applied a ×60 conversion the data
  did not need.
- Apple Health stores SpO2 as a fraction (`0.94`), Oura as a percentage
  (`94.5`). Neither was normalized, so both landed in the same metric.

**Fix.** Commit `5554cd9` removes the ×60 conversion, normalizes Oura SpO2 to a
fraction on ingest, and adds a `display_multiplier` of ×100 for presentation.
Migration `000019_fix_spo2_multiplier` corrects the rows already stored.

**Lesson.** Vendor documentation is a claim about units, not evidence — compare
a known value against the vendor's own app before trusting a conversion factor,
and store one unit per metric across all sources.
