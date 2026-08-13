"""Row evaluation: the reject rules R1–R12 and the quality flags.

Nothing here touches SQLite or the network. `evaluate()` takes one decoded
parquet row as a dict and returns either an accepted `Product` or the first
`Reject` that fired, in the numeric order of the rules.

Rule order is load-bearing for the *reported rates*, not just the outcome. R12
(no target market) fires on roughly 64% of rows and would be far cheaper to test
first, but running it last means every published rate is measured against the
same denominator as every other rule, so the table can be read as a breakdown
rather than a sequence of survivors.
"""

from __future__ import annotations

import enum
from dataclasses import dataclass, field
from typing import Any

from . import config


class Reject(enum.Enum):
    """Why a row did not make it into the snapshot."""

    OBSOLETE = "R1 obsolete"
    BAD_BARCODE = "R2 barcode malformed or check digit fails"
    DUPLICATE = "R3 duplicate code"
    NO_NAME = "R4 no usable product name"
    NO_NUTRITION_DATA = "R5 no_nutrition_data set"
    NO_ENERGY = "R6 no usable energy at 100g"
    MISSING_MACRO = "R7 protein, carbohydrate or fat missing at 100g"
    NEGATIVE_VALUE = "R8 negative value"
    ENERGY_IMPLAUSIBLE = "R9 energy above 900 kcal/100g"
    MACRO_SUM_IMPLAUSIBLE = "R10 protein+carb+fat above 105 g/100g"
    ATWATER_IMPLAUSIBLE = "R11 Atwater mismatch beyond reject thresholds"
    NO_MARKET = "R12 no target market"


class QualityFlag(enum.IntFlag):
    """Persisted per row in `off_products.quality_flags`.

    A flag downranks a product in search. It never hides it — see ADR-0017.
    """

    NONE = 0
    ATWATER_MISMATCH = 1 << 0
    NO_SERVING_SIZE = 1 << 1
    ENERGY_FROM_KJ = 1 << 2
    ENERGY_FROM_BARE_FIELD = 1 << 3
    IMPLAUSIBLE_NUTRIENT = 1 << 4


@dataclass(slots=True)
class Product:
    """An accepted row, in the units the snapshot stores."""

    code: int
    name: str
    brand: str | None
    serving_size: str | None
    serving_g: int | None
    kcal: int
    protein: int
    carbs: int
    fat: int
    fibre: int | None
    sugar: int | None
    sodium: int | None
    markets: int
    rank: int
    quality_flags: int
    last_modified: int | None
    flags: QualityFlag = field(default=QualityFlag.NONE, repr=False)


# --------------------------------------------------------------------------
# Barcode
# --------------------------------------------------------------------------


def gtin_check_digit(body: str) -> int:
    """The GTIN check digit for a barcode body (the code without its last digit).

    Weights alternate 3, 1 anchored at the **rightmost** body digit.

    Anchoring from the right rather than the left is what makes this correct for
    all four accepted lengths. For GTIN-13 the body is 12 digits and the pattern
    reads 1,3,1,3,... from the left, which is the form usually quoted — but a
    GTIN-12 body is 11 digits and reads 3,1,3,... from the left, and GTIN-8 and
    GTIN-14 likewise start on 3. Hardcoding the left-to-right form and applying
    it to every length rejects most of the 8-, 12- and 14-digit products.

    Getting the direction backwards altogether rejects roughly 77% of the
    database and looks exactly like a data problem rather than an arithmetic one,
    which is why `test_gtin_weight_direction` pins it with a barcode that
    validates only under the reversed weights.
    """
    total = 0
    for position, digit in enumerate(reversed(body)):
        weight = 3 if position % 2 == 0 else 1
        total += int(digit) * weight
    return (10 - total % 10) % 10


def is_valid_gtin(code: str) -> bool:
    if len(code) not in config.VALID_BARCODE_LENGTHS:
        return False
    if not code.isdigit():
        return False
    return gtin_check_digit(code[:-1]) == int(code[-1])


# --------------------------------------------------------------------------
# Field decoding
# --------------------------------------------------------------------------


def resolve_name(product_name: Any) -> str | None:
    """`product_name` is `list<struct{lang, text}>`, not a string.

    OFF emits a pseudo-language "main" on 93.1% of rows. Resolution is
    main -> en -> first non-empty; 6.0% of rows have no name at all.
    """
    if not product_name:
        return None

    by_lang: dict[str, str] = {}
    first_non_empty: str | None = None

    for entry in product_name:
        if not entry:
            continue
        text = (entry.get("text") or "").strip()
        if not text:
            continue
        lang = (entry.get("lang") or "").strip().lower()
        by_lang.setdefault(lang, text)
        if first_non_empty is None:
            first_non_empty = text

    return by_lang.get("main") or by_lang.get("en") or first_non_empty


def pivot_nutriments(nutriments: Any) -> dict[str, dict[str, Any]]:
    """Turn the long-form nutriment list into a name-keyed mapping.

    `nutriments` is
    `list<struct{name, value, 100g, serving, unit, prepared_*}>`. There is no
    `energy-kcal_100g` column anywhere in the file — `energy-kcal` is a *value*
    of the `name` field inside this list, so every row must be pivoted before
    any nutrient can be read.
    """
    if not nutriments:
        return {}

    pivoted: dict[str, dict[str, Any]] = {}
    for entry in nutriments:
        if not entry:
            continue
        name = (entry.get("name") or "").strip().lower()
        if name:
            pivoted.setdefault(name, entry)
    return pivoted


def parse_serving_quantity(raw: Any) -> float | None:
    """`serving_quantity` is a string, not a float.

    Values look like "1.0", "30.05047", "14.000000000000002". Unparseable means
    absent, not fatal — a serving size we cannot read costs one extra tap, while
    rejecting the row costs the product entirely.
    """
    if raw is None:
        return None
    try:
        value = float(str(raw).strip())
    except (TypeError, ValueError):
        return None
    if value != value or value in (float("inf"), float("-inf")):  # NaN / inf
        return None
    return value if value > 0 else None


def _bounded(value: float | None, ceiling: float) -> tuple[float | None, bool]:
    """Discard a value that cannot be true, rather than storing it.

    Applied to the optional columns — fibre, sugar, sodium, serving mass — which
    no reject rule constrains. The precedent is `parse_serving_quantity`: a value
    we cannot believe is *absent*, not fatal. Dropping one optional nutrient
    costs a field on one product; rejecting the row costs the product; storing it
    costs the whole build, because a scaled garbage value overflows int64 and
    SQLite refuses the insert.
    """
    if value is None:
        return None, False
    if value > ceiling:
        return None, True
    return value, False


def _leaf(nutriment: dict[str, Any] | None, key: str = "100g") -> float | None:
    if not nutriment:
        return None
    value = nutriment.get(key)
    if value is None:
        return None
    value = float(value)
    if value != value or value in (float("inf"), float("-inf")):
        return None
    return value


def resolve_energy_kcal(
    pivoted: dict[str, dict[str, Any]],
) -> tuple[float | None, QualityFlag]:
    """Energy per 100 g in kilocalories, by the fixed resolution order.

    `energy-kcal` -> `energy-kj` / 4.184 -> `energy` **read through its own unit
    field** -> unresolvable.

    The third step is the trap. The bare `energy` nutriment mixes kJ and kcal
    rows in one column, so a row whose unit says kJ and whose value is taken as
    kcal comes out 4.184x too high — and still passes the plausibility checks,
    because a 4.184x error on a 150 kcal product lands at 628, under the 900
    ceiling. A unit we do not recognise resolves to nothing rather than to a
    guess.
    """
    kcal = _leaf(pivoted.get("energy-kcal"))
    if kcal is not None:
        return kcal, QualityFlag.NONE

    kilojoules = _leaf(pivoted.get("energy-kj"))
    if kilojoules is not None:
        return kilojoules / config.KJ_PER_KCAL, QualityFlag.ENERGY_FROM_KJ

    bare = pivoted.get("energy")
    value = _leaf(bare)
    if bare is not None and value is not None:
        unit = (bare.get("unit") or "").strip().lower()
        if unit in config.ENERGY_UNITS_KCAL:
            return value, QualityFlag.ENERGY_FROM_BARE_FIELD
        if unit in config.ENERGY_UNITS_KJ:
            return value / config.KJ_PER_KCAL, (
                QualityFlag.ENERGY_FROM_BARE_FIELD | QualityFlag.ENERGY_FROM_KJ
            )

    return None, QualityFlag.NONE


def resolve_markets(countries_tags: Any) -> int:
    if not countries_tags:
        return 0
    mask = 0
    for tag in countries_tags:
        market = config.COUNTRY_TAG_TO_MARKET.get((tag or "").strip().lower())
        if market is not None:
            mask |= 1 << config.MARKET_BITS[market]
    return mask


def compute_rank(unique_scans: Any, completeness: Any, flagged: bool) -> int:
    scans = int(unique_scans or 0)
    scans = max(0, min(scans, config.RANK_SCANS_CLAMP))
    complete = float(completeness or 0.0)
    complete = max(0.0, min(complete, 1.0))

    rank = scans * config.RANK_SCANS_WEIGHT + round(complete * config.RANK_COMPLETENESS_WEIGHT)
    if flagged:
        rank //= config.RANK_FLAGGED_DIVISOR
    return rank


# --------------------------------------------------------------------------
# Evaluation
# --------------------------------------------------------------------------


@dataclass(slots=True)
class Evaluation:
    """The full verdict on one row.

    `reject` is the first rule that fires in numeric order — the reason the row
    is absent. `all_rejects` is every rule that *would* fire, evaluated
    independently.

    Both are reported, because first-match attribution is an artefact of
    ordering rather than a property of the data. R12 alone accounts for around
    two thirds of the file, so whether it runs first or last moves large
    percentages between rows of the reject table without a single row changing
    fate. The order-free column is the one to reason about; the first-match
    column is the one that explains the row count.
    """

    product: Product | None
    reject: Reject | None
    all_rejects: frozenset[Reject]
    flags: QualityFlag


def evaluate_full(row: dict[str, Any]) -> Evaluation:
    """Apply every rule, collecting all that fire.

    R3 (duplicate code) is not tested here. It is enforced by the unique index in
    the writer via INSERT OR IGNORE, because holding three million barcodes in a
    Python set to answer a question SQLite already answers is a waste of a
    gigabyte.

    A rule that cannot be evaluated does not fire: R9 says nothing about a row
    with no energy. That is why `all_rejects` is a lower bound on independent
    causes and never contradicts `reject`.
    """
    rejects: list[Reject] = []
    flags = QualityFlag.NONE

    # R1 --------------------------------------------------------------
    if row.get("obsolete"):
        rejects.append(Reject.OBSOLETE)

    # R2 --------------------------------------------------------------
    code = (row.get("code") or "").strip()
    if not is_valid_gtin(code):
        rejects.append(Reject.BAD_BARCODE)

    # R4 --------------------------------------------------------------
    name = resolve_name(row.get("product_name"))
    if name is None or len(name) < config.MIN_NAME_LENGTH:
        rejects.append(Reject.NO_NAME)

    # R5 --------------------------------------------------------------
    if row.get("no_nutrition_data"):
        rejects.append(Reject.NO_NUTRITION_DATA)

    # R6 --------------------------------------------------------------
    pivoted = pivot_nutriments(row.get("nutriments"))
    kcal, energy_flags = resolve_energy_kcal(pivoted)
    if kcal is None:
        rejects.append(Reject.NO_ENERGY)
    else:
        flags |= energy_flags

    # R7 --------------------------------------------------------------
    protein = _leaf(pivoted.get("proteins"))
    carbs = _leaf(pivoted.get("carbohydrates"))
    fat = _leaf(pivoted.get("fat"))
    if protein is None or carbs is None or fat is None:
        rejects.append(Reject.MISSING_MACRO)

    fibre = _leaf(pivoted.get("fiber"))
    if fibre is None:
        fibre = _leaf(pivoted.get("fibre"))
    sugar = _leaf(pivoted.get("sugars"))

    sodium = _leaf(pivoted.get("sodium"))
    if sodium is None:
        salt = _leaf(pivoted.get("salt"))
        sodium = salt / config.SALT_TO_SODIUM if salt is not None else None

    # Bound the columns no rule constrains, before anything is scaled.
    fibre, fibre_bad = _bounded(fibre, config.MAX_NUTRIENT_G_PER_100G)
    sugar, sugar_bad = _bounded(sugar, config.MAX_NUTRIENT_G_PER_100G)
    sodium, sodium_bad = _bounded(sodium, config.MAX_NUTRIENT_G_PER_100G)
    if fibre_bad or sugar_bad or sodium_bad:
        flags |= QualityFlag.IMPLAUSIBLE_NUTRIENT

    # R8 --------------------------------------------------------------
    present = [
        value
        for value in (kcal, protein, carbs, fat, fibre, sugar, sodium)
        if value is not None
    ]
    if any(value < 0 for value in present):
        rejects.append(Reject.NEGATIVE_VALUE)

    # R9 --------------------------------------------------------------
    if kcal is not None and kcal > config.MAX_ENERGY_KCAL_PER_100G:
        rejects.append(Reject.ENERGY_IMPLAUSIBLE)

    # R10 -------------------------------------------------------------
    macros_known = protein is not None and carbs is not None and fat is not None
    if macros_known and protein + carbs + fat > config.MAX_MACRO_SUM_PER_100G:
        rejects.append(Reject.MACRO_SUM_IMPLAUSIBLE)

    # R11 -------------------------------------------------------------
    if kcal is not None and macros_known:
        atwater = protein * 4 + carbs * 4 + fat * 9
        mismatch = abs(atwater - kcal)
        relative = mismatch / kcal if kcal > 0 else 0.0

        if relative > config.ATWATER_REJECT_RELATIVE and mismatch > config.ATWATER_REJECT_ABSOLUTE:
            rejects.append(Reject.ATWATER_IMPLAUSIBLE)
        elif relative > config.ATWATER_FLAG_RELATIVE and mismatch > config.ATWATER_FLAG_ABSOLUTE:
            flags |= QualityFlag.ATWATER_MISMATCH

    # R12 -------------------------------------------------------------
    markets = resolve_markets(row.get("countries_tags"))
    if markets == 0:
        rejects.append(Reject.NO_MARKET)

    if rejects:
        ordered = sorted(rejects, key=lambda reason: list(Reject).index(reason))
        return Evaluation(None, ordered[0], frozenset(rejects), flags)

    # Accepted --------------------------------------------------------
    assert kcal is not None and protein is not None and carbs is not None and fat is not None
    serving_size = (row.get("serving_size") or "").strip() or None
    serving_quantity, serving_bad = _bounded(
        parse_serving_quantity(row.get("serving_quantity")), config.MAX_SERVING_G
    )
    if serving_bad:
        flags |= QualityFlag.IMPLAUSIBLE_NUTRIENT
    if serving_size is None and serving_quantity is None:
        flags |= QualityFlag.NO_SERVING_SIZE

    brand = (row.get("brands") or "").strip() or None

    product = Product(
        code=int(code),
        name=name,
        brand=brand,
        serving_size=serving_size,
        serving_g=round(serving_quantity * config.SERVING_G_SCALE) if serving_quantity else None,
        kcal=round(kcal * config.KCAL_SCALE),
        protein=round(protein * config.MACRO_SCALE),
        carbs=round(carbs * config.MACRO_SCALE),
        fat=round(fat * config.MACRO_SCALE),
        fibre=round(fibre * config.MACRO_SCALE) if fibre is not None else None,
        sugar=round(sugar * config.MACRO_SCALE) if sugar is not None else None,
        sodium=round(sodium * config.SODIUM_SCALE) if sodium is not None else None,
        markets=markets,
        rank=compute_rank(
            row.get("unique_scans_n"),
            row.get("completeness"),
            flagged=bool(flags & QualityFlag.ATWATER_MISMATCH),
        ),
        quality_flags=int(flags),
        last_modified=int(row["last_modified_t"]) if row.get("last_modified_t") else None,
        flags=flags,
    )
    return Evaluation(product, None, frozenset(), flags)


def evaluate(row: dict[str, Any]) -> tuple[Product | None, Reject | None]:
    """First-match form: exactly one of (product, None) / (None, reject)."""
    verdict = evaluate_full(row)
    return verdict.product, verdict.reject
