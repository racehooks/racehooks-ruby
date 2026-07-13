# Changelog

All notable changes to the `racehooks` Ruby gem are documented here. This project
adheres to [Semantic Versioning](https://semver.org/).

## [0.2.0]

- Aligned all feed identifiers with the canonical RaceHooks contract — feeds are
  now hyphenated (e.g. `timing.data`, `weather.data`, `events.race`,
  `weather.forecast-update`, `weather.tire-mismatch`, `weather.compound-crossover`).
- Added `Client#get_events` — list calendar events and their nested sessions
  (`GET /v1/events`, with optional `limit`/`offset`/`upcoming`/`year`).
- Added `Client#get_live_context` — snapshot of the currently live session
  (`GET /v1/live/context`).
- Added fantasy scoring methods (paid plans): `Client#get_race_scores` (estimated
  F1 Fantasy points for a completed Grand Prix or Sprint), `Client#get_session_scores`
  (running provisional score while a session is live), and `Client#get_session_pit_times`
  (pit stop time leaderboard — `pitStopTimeSec` per driver).
- Documented the full DriverRef identity block on driver entries (`driverId`,
  `constructorId`, `number`, `tla`, `name`, `team`) and the analytics
  `race_id` (distinct from and independent of `session_id`).
- Documented the canonical `replay` metadata fields (`simulationId`,
  `originalSessionId`, `sessionElapsed`).

## [0.1.0]

Initial release.

- HMAC-SHA256 webhook signature verification (`verify_signature`).
- `construct_event` — verify and parse a delivery into a typed event in one step.
- REST client for the RaceHooks API (webhooks and feeds).
- No runtime dependencies — uses only the Ruby standard library.
