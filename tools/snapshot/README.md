# Food snapshot pipeline

Turns the Open Food Facts parquet export into the read-only SQLite snapshot the
app downloads on first launch, plus the `manifest.json` that points at it on
Cloudflare R2.

Runs offline, on a developer machine. **Nothing here ships in the app**, and
nothing here is Swift — it cannot break the app build.

```bash
python -m venv .venv && .venv/bin/pip install -r requirements.txt

.venv/bin/python -m snapshot inspect
.venv/bin/python -m snapshot build --row-groups 60 --stride --out out   # ~60s sample
.venv/bin/python -m snapshot build --out out                            # full build
.venv/bin/python -m pytest tests -q
```

No local download is needed for either: the reader streams the export over HTTPS
range requests, projecting to 13 of its 145 columns.

---

## Always use `--stride` for samples

The export is ordered by barcode and therefore by GS1 country prefix, so the
first N row groups are a sample of one region and nothing else. A contiguous
head reports a market distribution, a reject profile and a bytes-per-row figure
that none of them generalise. `--stride` spreads the selection across the file;
`build` prints a warning when you ask for a head sample without it.

## What the build prints, and why

Reject counts by reason, quality-flag counts, **the thresholds that produced
them**, bytes per row, and compressed size — every run. A rate without the rule
behind it is not evidence, it is a number that looks like one.

The reject table has two columns:

| | |
|---|---|
| **first match** | the reason a row is absent, in rule order. Sums to the rejected total; explains the row count. |
| **independent** | whether that rule *alone* would reject the row. Sums to nothing — rows fail several rules at once — but describes the data rather than the sequence. |

They disagree sharply, and that is the point. R12 disqualifies ~68% of the export
on its own, so its first-match share depends entirely on where it sits in the
order. See ADR-0017.

## Traps this code exists to avoid

Four things about the source will silently corrupt a naive ingest. All four are
pinned by tests; see `Docs/DECISIONS.md` ADR-0017 for the reasoning.

- **`nutriments` is long form.** There is no `energy-kcal_100g` column. It is a
  `name` value inside `list<struct{...}>` and every row must be pivoted.
- **The bare `energy` field mixes kJ and kcal in one column.** Read only through
  its own `unit`. Taking it as kcal inflates ~2.7% of rows by 4.184x, and those
  rows still pass every plausibility check.
- **`product_name` is `list<struct{lang, text}>`,** with a pseudo-language
  `main` on 93.1% of rows. Resolve main → en → first non-empty.
- **`serving_quantity` is a string** — "14.000000000000002". Unparseable is
  absent, not fatal.

And one arithmetic trap of our own: GTIN check-digit weights alternate 3,1
anchored at the **rightmost** body digit. Anchored from the left they are correct
for GTIN-13 by coincidence and wrong for 8, 12 and 14; reversed entirely they
reject ~77% of the database and look exactly like a data problem.
`test_gtin_weight_direction` pins the direction with a barcode that validates
only under the wrong one.

## Layout

```
snapshot/config.py       every threshold, market bit, scale factor, column
snapshot/quality.py      Reject enum, QualityFlag, Product, evaluate_full()
snapshot/source_off.py   streaming parquet reader, one row group at a time
snapshot/writer.py       SQLite schema, FTS5 rebuild, VACUUM, zstd, sha256
snapshot/manifest.py     manifest emitter + rclone upload hint
snapshot/cli.py          inspect / build
```

Peak memory stays bounded at `--workers` row groups of ~1,021 rows each,
whatever the row count. The file is never loaded whole.

Row groups are fetched concurrently because the cost over HTTPS is round-trip
latency, not bandwidth — but they are **yielded in file order regardless of
completion order**. Insert order decides which of two rows sharing a barcode
survives R3, so an out-of-order build would produce a different file, and a
different sha256, from identical input.

## Publishing

The build never uploads. It prints the two `rclone` commands, artifact first:

```
snapshots/<id>/caliper-foods-NNN.sqlite.zst    immutable, max-age=31536000
manifest.json                                  max-age=60, must-revalidate
```

A manifest pointing at an object that is not there yet is the one ordering that
breaks live clients.

There is no signing. With no backend and no accounts, the manifest is the trust
root and HTTPS plus bucket write access is the whole security model — a decision,
not an omission. The payload is opened as a read-only SQLite file and never
evaluated, so the worst an attacker with bucket access achieves is wrong
macronutrients.

## Not in this milestone

USDA FoodData Central ingest. `usda_foods`, its index and its FTS companion are
created and ship **empty**, so the app's schema and the migration path are fixed
now rather than later. `off_corrections` likewise — it is pipeline-authored per
ADR-0005 and nothing has been corrected yet.
