"""Snapshot schema: FTS5 external content, licence separation, attribution."""

from __future__ import annotations

import sqlite3

import pytest

from snapshot import config
from snapshot.quality import Product
from snapshot.writer import SnapshotWriter, compress, sha256_of


def product(code: int, name: str, brand: str | None = "Acme", rank: int = 100) -> Product:
    return Product(
        code=code,
        name=name,
        brand=brand,
        serving_size="30 g",
        serving_g=300,
        kcal=250,
        protein=100,
        carbs=300,
        fat=50,
        fibre=20,
        sugar=150,
        sodium=40,
        markets=0b000001,
        rank=rank,
        quality_flags=0,
        last_modified=1_700_000_000,
    )


@pytest.fixture
def built(tmp_path):
    path = tmp_path / "snapshot.sqlite"
    with SnapshotWriter(path, batch_size=2) as writer:
        writer.add(product(3017620422003, "Chocolate Spread", "Ferrero"))
        writer.add(product(5000112637922, "Cola Zero", "Coca-Cola"))
        writer.add(product(4000417025005, "Dark Chocolate Bar", "Ritter"))
        writer.write_meta(
            {
                "off.attribution": config.OFF_ATTRIBUTION,
                "off.licence": config.OFF_LICENCE,
                "schema_version": str(config.SCHEMA_VERSION),
            }
        )
        result = writer.finish()
    return path, result


# --------------------------------------------------------------------------
# FTS5 external content
# --------------------------------------------------------------------------


def test_fts_external_content_joins_back_by_rowid(built):
    """The whole point of `content='off_products'`: the index stores no text.

    If the rowid linkage is wrong the search still returns hits, but the join
    resolves to the wrong product — a failure that shows up as one food's name
    against another's macros, which is exactly the kind of thing a user reports
    as "the app is lying to me" and we cannot reproduce.
    """
    path, _ = built
    connection = sqlite3.connect(path)

    hits = connection.execute(
        """
        SELECT p.code, p.name, p.kcal
        FROM off_products_fts AS f
        JOIN off_products AS p ON p.id = f.rowid
        WHERE off_products_fts MATCH 'chocolate'
        ORDER BY p.rank DESC
        """
    ).fetchall()

    assert {row[1] for row in hits} == {"Chocolate Spread", "Dark Chocolate Bar"}
    for code, name, kcal in hits:
        stored = connection.execute(
            "SELECT name, kcal FROM off_products WHERE code = ?", (code,)
        ).fetchone()
        assert stored == (name, kcal), "rowid join resolved to the wrong row"

    connection.close()


def test_fts_stores_no_copy_of_the_text(built):
    """External content means the FTS shadow tables carry the index, not the text."""
    path, _ = built
    connection = sqlite3.connect(path)

    # A contentless-standard table would have an off_products_fts_content table
    # holding a second copy of every name and brand.
    tables = {
        name for (name,) in connection.execute(
            "SELECT name FROM sqlite_master WHERE type='table' AND name LIKE 'off_products_fts%'"
        )
    }
    assert "off_products_fts_content" not in tables

    connection.close()


def test_brand_is_searchable_separately_from_name(built):
    path, _ = built
    connection = sqlite3.connect(path)
    hits = connection.execute(
        "SELECT p.name FROM off_products_fts f JOIN off_products p ON p.id = f.rowid "
        "WHERE off_products_fts MATCH 'brand:Ferrero'"
    ).fetchall()
    assert hits == [("Chocolate Spread",)]
    connection.close()


def test_diacritics_are_folded(built, tmp_path):
    path = tmp_path / "accents.sqlite"
    with SnapshotWriter(path) as writer:
        writer.add(product(3017620422003, "Pâté de Campagne"))
        writer.finish()

    connection = sqlite3.connect(path)
    hits = connection.execute(
        "SELECT p.name FROM off_products_fts f JOIN off_products p ON p.id = f.rowid "
        "WHERE off_products_fts MATCH 'pate'"
    ).fetchall()
    assert hits == [("Pâté de Campagne",)]
    connection.close()


# --------------------------------------------------------------------------
# Attribution travels with the data
# --------------------------------------------------------------------------


def test_odbl_attribution_is_inside_the_snapshot_file(built):
    """Docs/LICENSING.md: OFF data is never presented with the attribution stripped.

    Storing the notice in the file rather than hardcoding it in the app means a
    snapshot separated from its manifest still says where it came from and under
    what terms — and a future snapshot that changed source could not silently
    inherit the old credit.
    """
    path, _ = built

    connection = sqlite3.connect(path)
    stored = connection.execute(
        "SELECT value FROM snapshot_meta WHERE key = 'off.attribution'"
    ).fetchone()
    connection.close()

    assert stored is not None, "no attribution row in snapshot_meta"
    assert "Open Food Facts" in stored[0]
    assert "Open Database License (ODbL) 1.0" in stored[0]
    assert "openfoodfacts.org" in stored[0]

    # And literally present in the bytes, not merely reconstructable.
    assert config.OFF_ATTRIBUTION.encode("utf-8") in path.read_bytes()


def test_licence_url_survives_the_vacuum(built):
    path, _ = built
    connection = sqlite3.connect(path)
    value = connection.execute(
        "SELECT value FROM snapshot_meta WHERE key = 'off.licence'"
    ).fetchone()[0]
    connection.close()
    assert value == config.OFF_LICENCE


# --------------------------------------------------------------------------
# Licence separation (ADR-0004 / ADR-0005)
# --------------------------------------------------------------------------


def test_the_three_sources_are_separate_tables(built):
    path, _ = built
    connection = sqlite3.connect(path)
    tables = {
        name for (name,) in connection.execute(
            "SELECT name FROM sqlite_master WHERE type = 'table'"
        )
    }
    connection.close()

    assert {"off_products", "off_corrections", "usda_foods"} <= tables


def test_usda_and_corrections_ship_empty(built):
    """M1 ingests OFF only. The tables exist so the schema and the migration path
    are fixed now rather than at M2."""
    path, _ = built
    connection = sqlite3.connect(path)
    assert connection.execute("SELECT count(*) FROM usda_foods").fetchone()[0] == 0
    assert connection.execute("SELECT count(*) FROM off_corrections").fetchone()[0] == 0
    connection.close()


def test_no_view_or_trigger_joins_across_the_licence_boundary(built):
    """Nothing in the file may merge OFF rows with another source.

    ADR-0004's separation is only structural if the database itself contains no
    object that does the merging for you. Search unions the sources in Swift.
    """
    path, _ = built
    connection = sqlite3.connect(path)
    objects = connection.execute(
        "SELECT sql FROM sqlite_master WHERE type IN ('view', 'trigger') AND sql IS NOT NULL"
    ).fetchall()
    connection.close()

    for (sql,) in objects:
        lowered = sql.lower()
        assert not ("off_products" in lowered and "usda_foods" in lowered), sql


# --------------------------------------------------------------------------
# Duplicates, indexes, compression
# --------------------------------------------------------------------------


def test_duplicate_codes_are_dropped_by_the_unique_index(tmp_path):
    """R3 without holding three million barcodes in a Python set."""
    path = tmp_path / "dupes.sqlite"
    with SnapshotWriter(path) as writer:
        writer.add(product(3017620422003, "First"))
        writer.add(product(3017620422003, "Second"))
        writer.add(product(5000112637922, "Other"))
        result = writer.finish()

    assert result.rows == 2
    assert result.duplicates == 1

    connection = sqlite3.connect(path)
    assert connection.execute(
        "SELECT name FROM off_products WHERE code = 3017620422003"
    ).fetchone() == ("First",), "first write wins"
    connection.close()


def test_markets_is_deliberately_unindexed(built):
    """A b-tree cannot answer `markets & ? != 0`, so an index on it would be
    6% of the file no query can read."""
    path, _ = built
    connection = sqlite3.connect(path)
    indexes = {
        name for (name,) in connection.execute(
            "SELECT name FROM sqlite_master WHERE type = 'index' AND tbl_name = 'off_products'"
        )
    }
    connection.close()
    assert not any("market" in name.lower() for name in indexes)


def test_market_bitmask_filters_correctly(tmp_path):
    path = tmp_path / "markets.sqlite"
    australia, canada = 1 << 0, 1 << 5

    with SnapshotWriter(path) as writer:
        au = product(3017620422003, "AU only")
        au.markets = australia
        ca = product(5000112637922, "CA only")
        ca.markets = canada
        both = product(4000417025005, "Both")
        both.markets = australia | canada
        for item in (au, ca, both):
            writer.add(item)
        writer.finish()

    connection = sqlite3.connect(path)
    names = {
        name for (name,) in connection.execute(
            "SELECT name FROM off_products WHERE markets & ? != 0", (australia,)
        )
    }
    connection.close()
    assert names == {"AU only", "Both"}


def test_result_reports_bytes_per_row(built):
    _, result = built
    assert result.rows == 3
    assert result.bytes_on_disk > 0
    assert result.bytes_per_row > 0
    assert len(result.sha256) == 64


def test_compression_produces_a_distinct_digest(built, tmp_path):
    path, result = built
    compressed_path, size, digest = compress(path, level=3)

    assert compressed_path.exists()
    assert size > 0
    assert len(digest) == 64
    # The manifest carries both: one verifies the transfer, the other verifies
    # what is actually opened.
    assert digest != result.sha256
    assert sha256_of(path) == result.sha256


def test_overflow_names_the_offending_barcode_and_column(tmp_path):
    """A build that dies at minute seventy must say which row did it.

    SQLite reports only "Python int too large to convert", with no row and no
    column. Reconstructing that from a traceback costs another full build.
    """
    path = tmp_path / "overflow.sqlite"
    with SnapshotWriter(path, batch_size=10) as writer:
        bad = product(3017620422003, "Impossible")
        bad.sodium = 10**30
        writer.add(bad)

        with pytest.raises(ValueError) as caught:
            writer.flush()

    message = str(caught.value)
    assert "3017620422003" in message
    assert "sodium" in message
    assert "int64" in message
