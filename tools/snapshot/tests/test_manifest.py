"""Manifest shape, and the sampling rule that keeps development builds honest."""

from __future__ import annotations

import json
from datetime import datetime, timezone

from snapshot import config
from snapshot.manifest import build_manifest, upload_hint, write_manifest
from snapshot.source_off import select_row_groups


def make(**overrides):
    arguments = {
        "snapshot_id": "20260813-000000",
        "object_key": "snapshots/20260813-000000/caliper-foods-001.sqlite.zst",
        "base_url": "https://snapshots.caliper.app",
        "bytes_compressed": 66_000_000,
        "bytes_expanded": 141_000_000,
        "sha256_expanded": "a" * 64,
        "sha256_compressed": "b" * 64,
        "markets": list(config.MARKET_BITS),
        "table_counts": {"off_products": 1_110_000, "usda_foods": 0, "off_corrections": 0},
        "source_url": config.OFF_PARQUET_URL,
        "source_etag": "deadbeef",
        "source_rows": 4_667_112,
        "accepted_rows": 1_110_000,
        "built_at": datetime(2026, 8, 13, tzinfo=timezone.utc),
    }
    arguments.update(overrides)
    return build_manifest(**arguments)


def test_manifest_carries_a_schema_floor():
    """An old build must refuse a newer snapshot rather than mis-read a column
    that moved."""
    document = make()
    assert document["min_app_schema"] == config.MIN_APP_SCHEMA
    assert document["snapshot"]["schema_version"] == config.SCHEMA_VERSION


def test_manifest_carries_both_digests():
    snapshot = make()["snapshot"]
    assert snapshot["sha256"] != snapshot["sha256_compressed"]
    assert snapshot["bytes_expanded"] > snapshot["bytes_compressed"]


def test_artifact_url_is_versioned_and_immutable_shaped():
    """Immutable versioned keys cached forever; only the manifest is polled."""
    url = make()["snapshot"]["url"]
    assert url.startswith("https://")
    assert "/snapshots/20260813-000000/" in url
    assert url.endswith(".sqlite.zst")


def test_sources_block_names_open_food_facts_with_licence_and_link():
    """Docs/LICENSING.md requires the Attribution screen to name OFF, link to it
    and state ODbL. Driving that from the manifest means the notice cannot drift
    from the data actually installed."""
    off = next(source for source in make()["sources"] if source["id"] == "off")

    assert off["name"] == "Open Food Facts"
    assert off["url"] == "https://openfoodfacts.org"
    assert "ODbL" in off["licence"]
    assert off["licence_url"].startswith("https://opendatacommons.org/")
    assert "Open Food Facts" in off["attribution"]


def test_sources_block_records_the_export_it_was_built_from():
    off = next(source for source in make()["sources"] if source["id"] == "off")
    assert off["export_etag"] == "deadbeef"
    assert off["export_rows"] == 4_667_112
    assert off["rows"] == 1_110_000


def test_usda_is_declared_even_though_it_ships_empty():
    usda = next(source for source in make()["sources"] if source["id"] == "usda")
    assert usda["rows"] == 0
    assert "CC0" in usda["licence"]


def test_manifest_round_trips_as_json(tmp_path):
    path = write_manifest(make(), tmp_path / "manifest.json")
    reloaded = json.loads(path.read_text(encoding="utf-8"))
    assert reloaded == make()


def test_upload_hint_writes_the_artifact_before_the_manifest():
    """A manifest pointing at an object that is not there yet is the one ordering
    that breaks live clients."""
    hint = upload_hint(
        snapshot_path=__import__("pathlib").Path("out/caliper-foods-001.sqlite.zst"),
        object_key="snapshots/x/caliper-foods-001.sqlite.zst",
    )
    assert hint.index("snapshots/x/") < hint.index("manifest.json")
    assert "immutable" in hint
    assert "must-revalidate" in hint


# --------------------------------------------------------------------------
# Sampling
# --------------------------------------------------------------------------


def test_stride_spreads_the_sample_across_the_file():
    """The export is ordered by barcode and therefore by GS1 country prefix, so
    the first N row groups are a sample of one region and nothing else."""
    selected = select_row_groups(total=4567, limit=60, stride=True)

    assert len(selected) == 60
    assert selected[0] < 100
    assert selected[-1] > 4400
    assert selected == sorted(selected)
    assert len(set(selected)) == len(selected)


def test_head_sample_is_contiguous_when_stride_is_off():
    assert select_row_groups(total=4567, limit=5, stride=False) == [0, 1, 2, 3, 4]


def test_no_limit_reads_everything():
    assert select_row_groups(total=10, limit=None, stride=True) == list(range(10))
    assert select_row_groups(total=10, limit=99, stride=True) == list(range(10))
