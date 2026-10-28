# v1 baseline

What the v1 prototype (commit 1047dbd) computes on a fresh demo database.
v2 must reproduce these files exactly, except `alert_messages.csv`.

Regenerate (into a scratch database, so the working `subwatch` db is untouched):

```bash
createdb subwatch_v1base
for f in schema seed detection; do psql -X -q -v ON_ERROR_STOP=1 -d subwatch_v1base -f db/$f.sql; done
psql -X -q -v ON_ERROR_STOP=1 -d subwatch_v1base -v outdir=db/tests/v1_baseline -f db/tests/snapshot.sql
```

Two independent seeds give identical files apart from `alert_messages.csv`.
Usage logs get random timestamps inside their 30-day bucket, so a message like
"hasn't been used in 82 days" changes between runs. That file is for reading,
not diffing.
