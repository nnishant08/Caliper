"""Reject rules, field decoding, and the traps that make this file worth having."""

from __future__ import annotations

import pytest

from snapshot import config
from snapshot.quality import (
    QualityFlag,
    Reject,
    evaluate,
    gtin_check_digit,
    is_valid_gtin,
    pivot_nutriments,
    parse_serving_quantity,
    resolve_energy_kcal,
    resolve_markets,
    resolve_name,
)


# --------------------------------------------------------------------------
# Fixtures
# --------------------------------------------------------------------------


def nutriment(name: str, per_100g: float | None, unit: str | None = None, **extra):
    return {
        "name": name,
        "value": per_100g,
        "100g": per_100g,
        "serving": None,
        "unit": unit,
        "prepared_value": None,
        "prepared_100g": None,
        "prepared_serving": None,
        "prepared_unit": None,
        **extra,
    }


def row(**overrides):
    """A minimal accepted row. Override one field per test."""
    base = {
        "code": "3017620422003",
        "product_name": [{"lang": "main", "text": "Chocolate Spread"}],
        "nutriments": [
            nutriment("energy-kcal", 539.0, "kcal"),
            nutriment("proteins", 6.3),
            nutriment("carbohydrates", 57.5),
            nutriment("fat", 30.9),
            nutriment("sugars", 56.3),
            nutriment("salt", 0.107),
        ],
        "serving_size": "15 g",
        "serving_quantity": "15.0",
        "brands": "Ferrero",
        "countries_tags": ["en:australia", "en:france"],
        "obsolete": False,
        "no_nutrition_data": False,
        "unique_scans_n": 4200,
        "popularity_key": 1000,
        "completeness": 0.85,
        "last_modified_t": 1_700_000_000,
    }
    base.update(overrides)
    return base


# --------------------------------------------------------------------------
# GTIN — the direction trap
# --------------------------------------------------------------------------


def _check_digit_reversed_weights(body: str) -> int:
    """The wrong implementation, kept only so the test can tell them apart."""
    total = sum(int(digit) * (3 if index % 2 == 0 else 1) for index, digit in enumerate(body))
    return (10 - total % 10) % 10


def test_gtin_weight_direction():
    """Pins which end the 3,1,3,1 weights are anchored at.

    5260181590832 validates under weights applied left-to-right and fails under
    the correct right-anchored ones. Getting this backwards rejects roughly 77%
    of the database — a failure that looks exactly like a data problem and not
    like arithmetic, which is why it is pinned rather than trusted.
    """
    barcode = "5260181590832"
    body, stated = barcode[:-1], int(barcode[-1])

    assert gtin_check_digit(body) != stated, "correct weights must reject this barcode"
    assert _check_digit_reversed_weights(body) == stated, "reversed weights accept it"
    assert not is_valid_gtin(barcode)


@pytest.mark.parametrize(
    "barcode",
    [
        "3017620422003",  # GTIN-13, real
        "5000112637922",  # GTIN-13, real
        "0012000001086",  # GTIN-13 with a leading zero
    ],
)
def test_real_barcodes_validate(barcode):
    assert is_valid_gtin(barcode)


@pytest.mark.parametrize("length", sorted(config.VALID_BARCODE_LENGTHS))
def test_check_digit_is_self_consistent_at_every_accepted_length(length):
    """The right-anchored form has to hold for 8, 12, 13 and 14 digits alike.

    A left-anchored implementation happens to be correct for GTIN-13, whose body
    has an even number of digits, and wrong for the other three. Generating and
    then validating at each length is what catches that.
    """
    body = "".join(str((index * 7 + 3) % 10) for index in range(length - 1))
    barcode = body + str(gtin_check_digit(body))

    assert len(barcode) == length
    assert is_valid_gtin(barcode)


@pytest.mark.parametrize("barcode", ["", "12345", "abcdefghijklm", "301762042200"])
def test_malformed_barcodes_are_rejected(barcode):
    assert not is_valid_gtin(barcode)


# --------------------------------------------------------------------------
# TRAP 1 — nutriments is long form
# --------------------------------------------------------------------------


def test_nutriments_pivot_is_required_to_read_anything():
    nutriments = [nutriment("energy-kcal", 250.0, "kcal"), nutriment("proteins", 10.0)]
    pivoted = pivot_nutriments(nutriments)

    assert set(pivoted) == {"energy-kcal", "proteins"}
    assert pivoted["energy-kcal"]["100g"] == 250.0


def test_nutriments_pivot_keeps_the_first_of_a_repeated_name():
    pivoted = pivot_nutriments([nutriment("fat", 1.0), nutriment("fat", 99.0)])
    assert pivoted["fat"]["100g"] == 1.0


def test_nutriments_pivot_tolerates_null_and_empty():
    assert pivot_nutriments(None) == {}
    assert pivot_nutriments([]) == {}
    assert pivot_nutriments([None, nutriment("", 1.0)]) == {}


# --------------------------------------------------------------------------
# TRAP 2 — mixed units on the bare `energy` field
# --------------------------------------------------------------------------


def test_energy_prefers_kcal():
    pivoted = pivot_nutriments([
        nutriment("energy-kcal", 250.0, "kcal"),
        nutriment("energy-kj", 4184.0, "kj"),
        nutriment("energy", 4184.0, "kj"),
    ])
    kcal, flags = resolve_energy_kcal(pivoted)
    assert kcal == 250.0
    assert flags is QualityFlag.NONE


def test_energy_falls_back_to_kilojoules():
    pivoted = pivot_nutriments([nutriment("energy-kj", 1000.0, "kj")])
    kcal, flags = resolve_energy_kcal(pivoted)
    assert kcal == pytest.approx(1000.0 / config.KJ_PER_KCAL)
    assert flags & QualityFlag.ENERGY_FROM_KJ


def test_bare_energy_in_kilojoules_is_converted_not_taken_at_face_value():
    """The 4.184x trap.

    A row whose bare `energy` is kJ, read as kcal, comes out 4.184x too high and
    still passes every plausibility check — 150 kcal becomes 628, under the 900
    ceiling. Nothing downstream would catch it.
    """
    pivoted = pivot_nutriments([nutriment("energy", 628.0, "kJ")])
    kcal, flags = resolve_energy_kcal(pivoted)

    assert kcal == pytest.approx(150.1, abs=0.5)
    assert flags & QualityFlag.ENERGY_FROM_KJ
    assert flags & QualityFlag.ENERGY_FROM_BARE_FIELD


def test_bare_energy_in_kcal_is_taken_as_is():
    pivoted = pivot_nutriments([nutriment("energy", 150.0, "kcal")])
    kcal, flags = resolve_energy_kcal(pivoted)
    assert kcal == 150.0
    assert flags & QualityFlag.ENERGY_FROM_BARE_FIELD


def test_bare_energy_without_a_unit_resolves_to_nothing():
    """Unit-qualified only. An unrecognised unit is not a licence to guess."""
    for unit in (None, "", "kcal/100g", "unknown"):
        kcal, _ = resolve_energy_kcal(pivot_nutriments([nutriment("energy", 500.0, unit)]))
        assert kcal is None, f"unit {unit!r} must not resolve"


def test_row_with_only_an_unqualified_energy_is_rejected():
    product, reject = evaluate(row(nutriments=[
        nutriment("energy", 500.0, None),
        nutriment("proteins", 5.0),
        nutriment("carbohydrates", 10.0),
        nutriment("fat", 2.0),
    ]))
    assert product is None
    assert reject is Reject.NO_ENERGY


# --------------------------------------------------------------------------
# TRAP 3 — product_name is a list of structs
# --------------------------------------------------------------------------


def test_name_resolution_prefers_main_then_en_then_first():
    assert resolve_name([{"lang": "fr", "text": "Pâte"}, {"lang": "main", "text": "Spread"}]) == "Spread"
    assert resolve_name([{"lang": "fr", "text": "Pâte"}, {"lang": "en", "text": "Spread"}]) == "Spread"
    assert resolve_name([{"lang": "fr", "text": "Pâte"}]) == "Pâte"


def test_name_resolution_skips_blank_entries():
    assert resolve_name([{"lang": "main", "text": "   "}, {"lang": "de", "text": "Brot"}]) == "Brot"


@pytest.mark.parametrize("value", [None, [], [{"lang": "main", "text": ""}]])
def test_missing_name_is_rejected(value):
    product, reject = evaluate(row(product_name=value))
    assert product is None
    assert reject is Reject.NO_NAME


def test_single_character_name_is_rejected():
    product, reject = evaluate(row(product_name=[{"lang": "main", "text": "X"}]))
    assert reject is Reject.NO_NAME


# --------------------------------------------------------------------------
# TRAP 4 — serving_quantity is a string
# --------------------------------------------------------------------------


@pytest.mark.parametrize(
    "raw,expected",
    [
        ("1.0", 1.0),
        ("30.05047", 30.05047),
        ("14.000000000000002", 14.000000000000002),
        ("  45 ", 45.0),
        ("", None),
        ("about 30g", None),
        (None, None),
        ("0", None),
        ("-5", None),
    ],
)
def test_serving_quantity_parses_defensively(raw, expected):
    assert parse_serving_quantity(raw) == expected


def test_unparseable_serving_quantity_is_absent_not_fatal():
    product, reject = evaluate(row(serving_quantity="one sachet", serving_size="1 sachet (30 g)"))
    assert reject is None
    assert product is not None
    assert product.serving_g is None
    assert product.serving_size == "1 sachet (30 g)"


def test_serving_size_text_is_kept():
    """SPEED_BUDGET.md: without it the user types grams, and the <=4-action
    barcode flow cannot spare the action."""
    product, _ = evaluate(row(serving_size="1.61 ONZ (45 g)"))
    assert product.serving_size == "1.61 ONZ (45 g)"


def test_no_serving_information_is_flagged_not_rejected():
    product, reject = evaluate(row(serving_size=None, serving_quantity=None))
    assert reject is None
    assert product.flags & QualityFlag.NO_SERVING_SIZE


# --------------------------------------------------------------------------
# Markets
# --------------------------------------------------------------------------


def test_market_bits_are_positional():
    assert resolve_markets(["en:australia"]) == 1 << 0
    assert resolve_markets(["en:canada"]) == 1 << 5
    assert resolve_markets(["en:australia", "en:canada"]) == (1 << 0) | (1 << 5)


def test_untargeted_markets_are_ignored():
    assert resolve_markets(["en:france", "en:germany"]) == 0


def test_no_target_market_is_rejected_last():
    """R12 fires on ~64% of rows and would be far cheaper first.

    Running it last keeps every published rate measured against the same
    denominator, so the reject table reads as a breakdown rather than as a
    sequence of survivors.
    """
    product, reject = evaluate(row(countries_tags=["en:france"]))
    assert reject is Reject.NO_MARKET

    # A row that is junk *and* untargeted reports the junk reason, not the market.
    product, reject = evaluate(row(countries_tags=["en:france"], product_name=None))
    assert reject is Reject.NO_NAME


# --------------------------------------------------------------------------
# Plausibility
# --------------------------------------------------------------------------


def test_obsolete_is_rejected_first():
    _, reject = evaluate(row(obsolete=True, product_name=None))
    assert reject is Reject.OBSOLETE


def test_no_nutrition_data_flag_is_honoured():
    _, reject = evaluate(row(no_nutrition_data=True))
    assert reject is Reject.NO_NUTRITION_DATA


def test_missing_macro_is_rejected():
    _, reject = evaluate(row(nutriments=[
        nutriment("energy-kcal", 100.0, "kcal"),
        nutriment("proteins", 5.0),
        nutriment("fat", 1.0),
    ]))
    assert reject is Reject.MISSING_MACRO


def test_negative_values_are_rejected():
    _, reject = evaluate(row(nutriments=[
        nutriment("energy-kcal", 100.0, "kcal"),
        nutriment("proteins", -5.0),
        nutriment("carbohydrates", 10.0),
        nutriment("fat", 1.0),
    ]))
    assert reject is Reject.NEGATIVE_VALUE


def test_energy_above_pure_fat_is_rejected():
    _, reject = evaluate(row(nutriments=[
        nutriment("energy-kcal", 901.0, "kcal"),
        nutriment("proteins", 0.0),
        nutriment("carbohydrates", 0.0),
        nutriment("fat", 100.0),
    ]))
    assert reject is Reject.ENERGY_IMPLAUSIBLE


def test_pure_fat_at_884_is_accepted():
    product, reject = evaluate(row(nutriments=[
        nutriment("energy-kcal", 884.0, "kcal"),
        nutriment("proteins", 0.0),
        nutriment("carbohydrates", 0.0),
        nutriment("fat", 100.0),
    ]))
    assert reject is None
    assert product.kcal == 884


def test_macro_sum_above_105_is_rejected():
    _, reject = evaluate(row(nutriments=[
        nutriment("energy-kcal", 500.0, "kcal"),
        nutriment("proteins", 40.0),
        nutriment("carbohydrates", 40.0),
        nutriment("fat", 30.0),
    ]))
    assert reject is Reject.MACRO_SUM_IMPLAUSIBLE


def test_five_grams_of_slack_absorbs_label_rounding():
    """Three independently rounded figures can legitimately sum past 100."""
    product, reject = evaluate(row(nutriments=[
        nutriment("energy-kcal", 500.0, "kcal"),
        nutriment("proteins", 34.0),
        nutriment("carbohydrates", 34.0),
        nutriment("fat", 34.0),
    ]))
    assert reject is None
    assert product is not None


# --------------------------------------------------------------------------
# Atwater — flag, don't reject
# --------------------------------------------------------------------------


def test_moderate_atwater_mismatch_is_flagged_and_kept():
    """4/4/9 is wrong by construction for polyols, unavailable fibre and alcohol.

    Rejecting on a 30% mismatch discards ~102k real products. ADR-0017: shown
    and downranked beats silently dropped, which is also ADR-0007's stance.
    """
    product, reject = evaluate(row(nutriments=[
        nutriment("energy-kcal", 200.0, "kcal"),
        nutriment("proteins", 5.0),
        nutriment("carbohydrates", 50.0),
        nutriment("fat", 5.0),
    ]))
    assert reject is None
    assert product.flags & QualityFlag.ATWATER_MISMATCH


def test_flagged_rows_are_downranked_not_hidden():
    clean, _ = evaluate(row())
    flagged, _ = evaluate(row(nutriments=[
        nutriment("energy-kcal", 200.0, "kcal"),
        nutriment("proteins", 5.0),
        nutriment("carbohydrates", 50.0),
        nutriment("fat", 5.0),
    ]))
    assert flagged.rank < clean.rank
    assert flagged.rank > 0


def test_gross_atwater_mismatch_is_rejected():
    _, reject = evaluate(row(nutriments=[
        nutriment("energy-kcal", 50.0, "kcal"),
        nutriment("proteins", 20.0),
        nutriment("carbohydrates", 20.0),
        nutriment("fat", 20.0),
    ]))
    assert reject is Reject.ATWATER_IMPLAUSIBLE


def test_relative_mismatch_alone_does_not_reject_a_low_energy_food():
    """A 60% mismatch on a 12 kcal product is arithmetic noise, not junk.

    Both the relative and the absolute threshold must be breached.
    """
    product, reject = evaluate(row(nutriments=[
        nutriment("energy-kcal", 12.0, "kcal"),
        nutriment("proteins", 0.5),
        nutriment("carbohydrates", 1.5),
        nutriment("fat", 0.2),
    ]))
    assert reject is None
    assert not (product.flags & QualityFlag.ATWATER_MISMATCH)


# --------------------------------------------------------------------------
# Storage scaling
# --------------------------------------------------------------------------


def test_values_are_stored_as_scaled_integers():
    product, _ = evaluate(row())

    assert product.kcal == 539
    assert product.protein == 63       # 6.3 g x10
    assert product.carbs == 575        # 57.5 g x10
    assert product.fat == 309          # 30.9 g x10
    assert product.sugar == 563        # 56.3 g x10
    assert product.serving_g == 150    # 15.0 g x10
    assert isinstance(product.code, int)


def test_sodium_is_derived_from_salt_when_absent():
    product, _ = evaluate(row())
    assert product.sodium == round(0.107 / config.SALT_TO_SODIUM * config.SODIUM_SCALE)


def test_sodium_is_preferred_over_salt_when_both_present():
    product, _ = evaluate(row(nutriments=[
        nutriment("energy-kcal", 100.0, "kcal"),
        nutriment("proteins", 1.0),
        nutriment("carbohydrates", 1.0),
        nutriment("fat", 1.0),
        nutriment("sodium", 0.4),
        nutriment("salt", 99.0),
    ]))
    assert product.sodium == 40


def test_missing_sodium_stays_null_rather_than_being_guessed():
    product, _ = evaluate(row(nutriments=[
        nutriment("energy-kcal", 100.0, "kcal"),
        nutriment("proteins", 1.0),
        nutriment("carbohydrates", 1.0),
        nutriment("fat", 1.0),
    ]))
    assert product.sodium is None


# --------------------------------------------------------------------------
# Unbounded columns — the bug the full build found
# --------------------------------------------------------------------------


@pytest.mark.parametrize("nutrient", ["fibre", "sugars", "sodium"])
def test_implausible_optional_nutrient_is_dropped_not_stored(nutrient):
    """R9 bounds energy and R10 bounds protein+carb+fat. Nothing bounded these.

    A full build found sodium at 788 g per 100 g. Scaled by 100 that is merely
    wrong; a value a few orders larger overflows int64 and SQLite refuses the
    insert, seventy minutes in, naming neither row nor column.
    """
    product, reject = evaluate(row(nutriments=[
        nutriment("energy-kcal", 100.0, "kcal"),
        nutriment("proteins", 1.0),
        nutriment("carbohydrates", 1.0),
        nutriment("fat", 1.0),
        nutriment(nutrient, 1e30),
    ]))

    assert reject is None, "one bad optional field must not cost the product"
    assert product.flags & QualityFlag.IMPLAUSIBLE_NUTRIENT
    assert product.fibre is None and product.sugar is None and product.sodium is None


def test_a_scaled_value_always_fits_int64():
    """The property that actually matters, stated directly."""
    product, _ = evaluate(row(
        serving_quantity="1e30",
        nutriments=[
            nutriment("energy-kcal", 100.0, "kcal"),
            nutriment("proteins", 1.0),
            nutriment("carbohydrates", 1.0),
            nutriment("fat", 1.0),
            nutriment("sugars", 1e18),
            nutriment("sodium", 1e18),
        ],
    ))

    limit = 2**63 - 1
    for value in (product.code, product.serving_g, product.kcal, product.protein,
                  product.carbs, product.fat, product.fibre, product.sugar,
                  product.sodium, product.markets, product.rank, product.last_modified):
        assert value is None or abs(value) <= limit


def test_plausible_extremes_are_still_kept():
    """Pure salt is ~40 g sodium per 100 g. The bound must not eat real food."""
    product, reject = evaluate(row(nutriments=[
        nutriment("energy-kcal", 0.0, "kcal"),
        nutriment("proteins", 0.0),
        nutriment("carbohydrates", 0.0),
        nutriment("fat", 0.0),
        nutriment("sodium", 39.3),
    ]))
    assert reject is None
    assert product.sodium == 3930
    assert not (product.flags & QualityFlag.IMPLAUSIBLE_NUTRIENT)


def test_absurd_serving_quantity_is_dropped():
    product, reject = evaluate(row(serving_quantity="99999999", serving_size="a pallet"))
    assert reject is None
    assert product.serving_g is None
    assert product.flags & QualityFlag.IMPLAUSIBLE_NUTRIENT
