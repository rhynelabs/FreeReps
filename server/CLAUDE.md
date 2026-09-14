# Server Development

- Build: `cd server && make build` (or `make build` from root)
- Test: `cd server && go test ./...`
- Go commands must run with `GOTOOLCHAIN=go1.25.5` (e.g.
  `GOTOOLCHAIN=go1.25.5 go test ./...`). *Why:* newer Go releases (1.27 on this
  Mac) fail on the pinned go-json-experiment dependency (`undefined:
  json.SkipFunc`) — the same pin `app/CLAUDE.md` documents for the
  TailscaleKit build script.
- Frontend stub for Go build: `mkdir -p server/web/dist && touch server/web/dist/.gitkeep`
- Frontend build: `cd server/web && npm ci && npm run build`

## Integration tests

`go test ./...` skips them. They need a PostgreSQL server in `FREEREPS_TEST_DSN`
and run with `-tags integration`. CI does not run them.

There is no Docker daemon on the development Mac, and the deployed database
publishes no port outside its compose network, so the DSN comes from a scratch
container on the homelab host plus a tunnel:

```bash
ssh root@freereps-lxc 'docker run -d --name freereps-idem \
  -e POSTGRES_PASSWORD=scratch -e POSTGRES_USER=freereps -e POSTGRES_DB=freereps_idem \
  -p 127.0.0.1:15432:5432 timescale/timescaledb:latest-pg16'
ssh -f -N -L 15432:127.0.0.1:15432 root@freereps-lxc

FREEREPS_TEST_DSN='postgres://freereps:scratch@127.0.0.1:15432/freereps_idem?sslmode=disable' \
  go test -tags integration ./...

ssh root@freereps-lxc 'docker rm -f freereps-idem'   # and kill the tunnel
```

The helper refuses to run against a database named `freereps`, because it
truncates. *Why the scratch server rather than a fake:* the property these tests
check is enforced by a unique constraint, so a fake store would assert the
fake's behaviour — see the 2026-08-10 entry in [`INCIDENTS.md`](../INCIDENTS.md).

**Rehearsing a data migration.** The same container takes a restore of the
deployed data, which is how the two dedupe migrations were checked before they
ran in production: `pg_dump --data-only --table=workout_sets` from
`freereps-db-1`, load it into a database that has the migrations applied up to
the one under test, then run the binary with `-migrate-only` from a directory
holding a `migrations/` copy and a config pointing at the scratch server.
