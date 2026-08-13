"""SQLite snapshot writer: schema, bulk insert, FTS5 rebuild, VACUUM, compress.

The file this produces is opened **read-only** by the app. That handle is what
makes ADR-0004's licence separation structural rather than a matter of
discipline: `off_products` is bit-identical to what we ingested, and the app has
no way to write into it even by mistake.

Three tables share the file and are never joined across a licence boundary in
SQL. Search unions them in Swift instead.
"""

from __future__ import annotations

import dataclasses
import hashlib
import sqlite3
from collections.abc import Iterable
from pathlib import Path

from . import config
from .quality import Product

# --------------------------------------------------------------------------
# Schema
# --------------------------------------------------------------------------

SCHEMA = f"""
PRAGMA journal_mode = OFF;
PRAGMA synchronous = OFF;

-- Open Food Facts. ODbL. Never merged with anything else.
CREATE TABLE off_products (
    id            INTEGER PRIMARY KEY,
    code          INTEGER NOT NULL,
    name          TEXT    NOT NULL,
    brand         TEXT,
    serving_size  TEXT,
    serving_g     INTEGER,
    kcal          INTEGER NOT NULL,
    protein       INTEGER NOT NULL,
    carbs         INTEGER NOT NULL,
    fat           INTEGER NOT NULL,
    fibre         INTEGER,
    sugar         INTEGER,
    sodium        INTEGER,
    markets       INTEGER NOT NULL,
    rank          INTEGER NOT NULL,
    quality_flags INTEGER NOT NULL DEFAULT 0,
    last_modified INTEGER
);

-- Doubles as the R3 duplicate check: INSERT OR IGNORE against this index costs
-- nothing extra and replaces holding three million barcodes in a Python set.
CREATE UNIQUE INDEX off_products_code ON off_products(code);

-- Search ranks on `rank`, so the covering index carries it.
CREATE INDEX off_products_rank ON off_products(rank DESC);

-- Deliberately absent: an index on `markets`. SQLite cannot use a b-tree to
-- answer a `markets & ? != 0` test, so the index would be 6% of the file that
-- no query can read.

-- Corrections to OFF rows, as deltas keyed to the barcode. Pipeline-authored,
-- never applied destructively, and the only table that would be exported if we
-- ever published a derivative database (ADR-0005). Empty until we clean anything.
CREATE TABLE off_corrections (
    code          INTEGER NOT NULL,
    field         TEXT    NOT NULL,
    value         TEXT,
    reason        TEXT,
    corrected_at  INTEGER,
    PRIMARY KEY (code, field)
) WITHOUT ROWID;

-- USDA FoodData Central. CC0. Ingest is M1+1, not this milestone: the table,
-- its index and its FTS companion exist so the app's schema and the migration
-- path are fixed now, and ship empty.
CREATE TABLE usda_foods (
    id            INTEGER PRIMARY KEY,
    fdc_id        INTEGER NOT NULL,
    name          TEXT    NOT NULL,
    category      TEXT,
    serving_size  TEXT,
    serving_g     INTEGER,
    kcal          INTEGER NOT NULL,
    protein       INTEGER NOT NULL,
    carbs         INTEGER NOT NULL,
    fat           INTEGER NOT NULL,
    fibre         INTEGER,
    sugar         INTEGER,
    sodium        INTEGER,
    rank          INTEGER NOT NULL,
    quality_flags INTEGER NOT NULL DEFAULT 0
);
CREATE UNIQUE INDEX usda_foods_fdc_id ON usda_foods(fdc_id);

CREATE TABLE snapshot_meta (
    key   TEXT PRIMARY KEY,
    value TEXT NOT NULL
) WITHOUT ROWID;

-- External content: the FTS index stores no copy of the text, reading it back
-- from off_products by rowid. Measured 19% smaller than a contentless-standard
-- table holding its own copy.
--
-- columnsize=0 drops the per-row column-length vector bm25 uses for length
-- normalisation. Over two fields as short as a product name and a brand that
-- normalisation is noise, and we rank on popularity rather than on bm25 anyway.
--
-- No prefix index. prefix='2 3' costs 18% of the file; that trade gets made at
-- M3 against a measured search flow, not guessed at here.
CREATE VIRTUAL TABLE off_products_fts USING fts5(
    name,
    brand,
    content='off_products',
    content_rowid='id',
    columnsize=0,
    tokenize='unicode61 remove_diacritics 2'
);

CREATE VIRTUAL TABLE usda_foods_fts USING fts5(
    name,
    category,
    content='usda_foods',
    content_rowid='id',
    columnsize=0,
    tokenize='unicode61 remove_diacritics 2'
);
"""

INSERT_SQL = """
INSERT OR IGNORE INTO off_products
    (code, name, brand, serving_size, serving_g, kcal, protein, carbs, fat,
     fibre, sugar, sodium, markets, rank, quality_flags, last_modified)
VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
"""


@dataclasses.dataclass(slots=True)
class WriteResult:
    path: Path
    rows: int
    duplicates: int
    bytes_on_disk: int
    sha256: str
    page_breakdown: dict[str, int]

    @property
    def bytes_per_row(self) -> float:
        return self.bytes_on_disk / self.rows if self.rows else 0.0


class SnapshotWriter:
    """Builds one snapshot file."""

    def __init__(self, path: Path, batch_size: int = 5_000) -> None:
        self.path = path
        self.batch_size = batch_size
        self._connection: sqlite3.Connection | None = None
        self._pending: list[tuple] = []
        self._attempted = 0
        self._inserted = 0

    # -- lifecycle ------------------------------------------------------

    def __enter__(self) -> SnapshotWriter:
        self.path.parent.mkdir(parents=True, exist_ok=True)
        if self.path.exists():
            self.path.unlink()
        self._connection = sqlite3.connect(self.path)
        self._connection.executescript(SCHEMA)
        return self

    def __exit__(self, *exc_info: object) -> None:
        if self._connection is not None:
            self._connection.close()
            self._connection = None

    @property
    def connection(self) -> sqlite3.Connection:
        if self._connection is None:
            raise RuntimeError("SnapshotWriter used outside its context manager")
        return self._connection

    # -- writing --------------------------------------------------------

    def add(self, product: Product) -> None:
        self._pending.append(
            (
                product.code,
                product.name,
                product.brand,
                product.serving_size,
                product.serving_g,
                product.kcal,
                product.protein,
                product.carbs,
                product.fat,
                product.fibre,
                product.sugar,
                product.sodium,
                product.markets,
                product.rank,
                product.quality_flags,
                product.last_modified,
            )
        )
        if len(self._pending) >= self.batch_size:
            self.flush()

    def flush(self) -> None:
        if not self._pending:
            return
        before = self.connection.total_changes
        self.connection.executemany(INSERT_SQL, self._pending)
        self._inserted += self.connection.total_changes - before
        self._attempted += len(self._pending)
        self._pending.clear()

    def write_meta(self, values: dict[str, str]) -> None:
        self.connection.executemany(
            "INSERT OR REPLACE INTO snapshot_meta (key, value) VALUES (?, ?)",
            sorted(values.items()),
        )

    # -- finishing ------------------------------------------------------

    def finish(self) -> WriteResult:
        """Rebuild FTS, compact, and measure.

        The FTS index is built once here rather than maintained by triggers
        during insert. One rebuild over a populated table is several times faster
        and packs measurably tighter, and the snapshot is immutable after this
        point so there is nothing for triggers to maintain.
        """
        self.flush()

        connection = self.connection
        connection.execute("INSERT INTO off_products_fts(off_products_fts) VALUES('rebuild')")
        connection.execute("INSERT INTO usda_foods_fts(usda_foods_fts) VALUES('rebuild')")
        connection.commit()

        breakdown = self._page_breakdown()

        connection.execute("PRAGMA journal_mode = DELETE")
        connection.execute("VACUUM")
        connection.execute("PRAGMA optimize")
        connection.commit()

        rows = connection.execute("SELECT count(*) FROM off_products").fetchone()[0]
        connection.close()
        self._connection = None

        return WriteResult(
            path=self.path,
            rows=rows,
            duplicates=self._attempted - self._inserted,
            bytes_on_disk=self.path.stat().st_size,
            sha256=sha256_of(self.path),
            page_breakdown=breakdown,
        )

    def _page_breakdown(self) -> dict[str, int]:
        """Bytes per table/index, when the build of SQLite exposes dbstat.

        Every schema decision in this file was taken against this breakdown
        rather than reasoned about, so it is worth printing even though it is
        only advisory. Python's bundled SQLite does not always carry the
        extension, and its absence is not a build failure.
        """
        try:
            rows = self.connection.execute(
                "SELECT name, sum(pgsize) FROM dbstat GROUP BY name ORDER BY 2 DESC"
            ).fetchall()
        except sqlite3.OperationalError:
            return {}
        return {name: int(size or 0) for name, size in rows}


# --------------------------------------------------------------------------
# Compression and hashing
# --------------------------------------------------------------------------


def sha256_of(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1 << 20), b""):
            digest.update(chunk)
    return digest.hexdigest()


def compress(path: Path, level: int = config.ZSTD_LEVEL) -> tuple[Path, int, str]:
    """zstd the snapshot. Returns (path, size, sha256 of the compressed bytes).

    Both digests end up in the manifest: the compressed one verifies the
    transfer, the expanded one verifies what actually gets opened. Checking only
    the transferred bytes would not catch a decompression that went wrong on
    device.
    """
    import zstandard

    target = path.with_suffix(path.suffix + ".zst")
    compressor = zstandard.ZstdCompressor(level=level)

    with path.open("rb") as source, target.open("wb") as sink:
        compressor.copy_stream(source, sink)

    return target, target.stat().st_size, sha256_of(target)


def bulk_load(writer: SnapshotWriter, products: Iterable[Product]) -> None:
    for product in products:
        writer.add(product)
    writer.flush()
