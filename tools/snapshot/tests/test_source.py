"""Streaming reader: ordering guarantees and the independent-cause column."""

from __future__ import annotations

import pyarrow as pa
import pyarrow.parquet as pq
import pytest

from snapshot import config, source_off
from snapshot.quality import Reject, evaluate_full


# --------------------------------------------------------------------------
# Parallel reads must not change the output
# --------------------------------------------------------------------------


@pytest.fixture
def local_parquet(tmp_path):
    """A file with several row groups, each row tagged with its position."""
    path = tmp_path / "sample.parquet"
    rows = 40

    table = pa.table(
        {
            "code": [f"{index:013d}" for index in range(rows)],
            "product_name": [[{"lang": "main", "text": f"Item {index}"}] for index in range(rows)],
            "nutriments": [[] for _ in range(rows)],
            "serving_size": [None] * rows,
            "serving_quantity": [None] * rows,
            "brands": [None] * rows,
            "countries_tags": [["en:australia"]] * rows,
            "obsolete": [False] * rows,
            "no_nutrition_data": [False] * rows,
            "unique_scans_n": [0] * rows,
            "popularity_key": [0] * rows,
            "completeness": [0.0] * rows,
            "last_modified_t": [0] * rows,
        }
    )
    pq.write_table(table, path, row_group_size=5)
    return path


def test_parallel_reads_preserve_row_group_order(local_parquet):
    """Order decides which of two rows sharing a barcode survives R3, so an
    out-of-order build produces a different file — and a different sha256 —
    from identical input. Concurrency is a latency optimisation and must be
    invisible in the output."""
    serial = [row["code"] for row in source_off.iter_rows(str(local_parquet), workers=1)]
    parallel = [row["code"] for row in source_off.iter_rows(str(local_parquet), workers=8)]

    assert serial == parallel
    assert serial == sorted(serial)


def test_every_row_survives_the_parallel_path(local_parquet):
    assert len(list(source_off.iter_rows(str(local_parquet), workers=8))) == 40


def test_row_group_limit_is_honoured_on_both_paths(local_parquet):
    serial = list(source_off.iter_rows(str(local_parquet), row_group_limit=3, workers=1))
    parallel = list(source_off.iter_rows(str(local_parquet), row_group_limit=3, workers=4))
    assert len(serial) == len(parallel) == 15


def test_only_the_projected_columns_are_decoded(local_parquet):
    row = next(iter(source_off.iter_rows(str(local_parquet), workers=1)))
    assert set(row) == set(config.COLUMNS)


def test_describe_reports_the_shape(local_parquet):
    info = source_off.describe(str(local_parquet))
    assert info.num_rows == 40
    assert info.num_row_groups == 8
    assert info.etag is None


# --------------------------------------------------------------------------
# Order-free reject attribution
# --------------------------------------------------------------------------


def base_row(**overrides):
    row = {
        "code": "3017620422003",
        "product_name": [{"lang": "main", "text": "Thing"}],
        "nutriments": [
            {"name": "energy-kcal", "100g": 200.0, "unit": "kcal"},
            {"name": "proteins", "100g": 5.0},
            {"name": "carbohydrates", "100g": 20.0},
            {"name": "fat", "100g": 10.0},
        ],
        "serving_size": None,
        "serving_quantity": None,
        "brands": None,
        "countries_tags": ["en:australia"],
        "obsolete": False,
        "no_nutrition_data": False,
        "unique_scans_n": 1,
        "popularity_key": 0,
        "completeness": 0.5,
        "last_modified_t": 0,
    }
    row.update(overrides)
    return row


def test_all_rejects_records_every_independent_cause():
    """A row can fail several rules at once. First-match attribution hides that,
    which is why both columns are reported."""
    verdict = evaluate_full(base_row(code="1234", product_name=None, countries_tags=["en:france"]))

    assert verdict.all_rejects == {Reject.BAD_BARCODE, Reject.NO_NAME, Reject.NO_MARKET}
    assert verdict.reject is Reject.BAD_BARCODE, "first match follows rule order"


def test_first_match_follows_numeric_rule_order():
    verdict = evaluate_full(base_row(obsolete=True, code="nope"))
    assert verdict.reject is Reject.OBSOLETE
    assert Reject.BAD_BARCODE in verdict.all_rejects


def test_a_rule_that_cannot_be_evaluated_does_not_fire():
    """R9 says nothing about a row with no energy at all.

    `all_rejects` is a lower bound on independent causes; it never claims a rule
    fired that could not be assessed.
    """
    verdict = evaluate_full(base_row(nutriments=[{"name": "proteins", "100g": 5.0}]))

    assert Reject.NO_ENERGY in verdict.all_rejects
    assert Reject.MISSING_MACRO in verdict.all_rejects
    assert Reject.ENERGY_IMPLAUSIBLE not in verdict.all_rejects
    assert Reject.ATWATER_IMPLAUSIBLE not in verdict.all_rejects


def test_market_rejection_is_independent_of_data_quality():
    """R12 disqualifies about two thirds of the export on its own. Whether it
    runs first or last moves large percentages between rows of the reject table
    without a single row changing fate — which is the reason the order-free
    column exists."""
    good_but_untargeted = evaluate_full(base_row(countries_tags=["en:france"]))
    assert good_but_untargeted.all_rejects == {Reject.NO_MARKET}
    assert good_but_untargeted.product is None


def test_accepted_rows_have_no_rejects():
    verdict = evaluate_full(base_row())
    assert verdict.reject is None
    assert verdict.all_rejects == frozenset()
    assert verdict.product is not None
