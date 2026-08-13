"""Every threshold, market bit, scale factor and column name in one place.

A reject rate is not evidence unless the rule that produced it is stated
alongside it, so the build prints the values from this module on every run. If
you are tuning, tune here — nothing below should be spelled inline anywhere else
in the package.
"""

from __future__ import annotations

from typing import Final

# --------------------------------------------------------------------------
# Source
# --------------------------------------------------------------------------

OFF_PARQUET_URL: Final = (
    "https://huggingface.co/datasets/openfoodfacts/product-database"
    "/resolve/main/food.parquet"
)

#: The only columns we read. The full file is 7.76 GB across 145 columns; this
#: projection is roughly 0.6 GB. `environmental_score_data` alone is 4.03 GB of
#: a column we never touch.
#:
#: `nutrition_data_per` is deliberately absent. It is 51% null, and of the rows
#: explicitly marked '100g' only 49.4% actually carry `energy-kcal.100g`. The
#: `100g` leaf inside `nutriments` is already normalised by OFF regardless, so
#: the field can tell us nothing we do not already know and can mislead.
COLUMNS: Final[tuple[str, ...]] = (
    "code",
    "product_name",
    "nutriments",
    "serving_size",
    "serving_quantity",
    "brands",
    "countries_tags",
    "obsolete",
    "no_nutrition_data",
    "unique_scans_n",
    "popularity_key",
    "completeness",
    "last_modified_t",
)

# --------------------------------------------------------------------------
# Markets
# --------------------------------------------------------------------------

#: Market bit positions, persisted in `off_products.markets` and read by the
#: app as a bitmask test.
#:
#: APPEND ONLY. Never reorder, never reuse a retired bit. An installed snapshot
#: outlives the build that made it, and a shifted bit silently changes which
#: products a user can find rather than failing loudly.
MARKET_BITS: Final[dict[str, int]] = {
    "AU": 0,
    "NZ": 1,
    "GB": 2,
    "IE": 3,
    "US": 4,
    "CA": 5,
}

#: `countries_tags` is en:-prefixed and 0.4% empty. `main_countries_tags` is not
#: used — it is far sparser and disagrees with the tag list.
COUNTRY_TAG_TO_MARKET: Final[dict[str, str]] = {
    "en:australia": "AU",
    "en:new-zealand": "NZ",
    "en:united-kingdom": "GB",
    "en:ireland": "IE",
    "en:united-states": "US",
    "en:canada": "CA",
}

# --------------------------------------------------------------------------
# Energy
# --------------------------------------------------------------------------

#: Thermochemical kilojoules per kilocalorie, the factor OFF itself uses.
KJ_PER_KCAL: Final = 4.184

#: The bare `energy` nutriment carries mixed units in a single column — kJ on
#: ~32.7k sampled rows, kcal on ~12.2k, null on ~70. It is read only through its
#: own `unit` field, never assumed. Treating it as kcal would inflate roughly
#: 2.7% of the database by 4.184x, and those rows still pass every plausibility
#: check below, so nothing downstream would catch it.
ENERGY_UNITS_KCAL: Final[frozenset[str]] = frozenset({"kcal"})
ENERGY_UNITS_KJ: Final[frozenset[str]] = frozenset({"kj"})

# --------------------------------------------------------------------------
# Reject thresholds
# --------------------------------------------------------------------------

VALID_BARCODE_LENGTHS: Final[frozenset[int]] = frozenset({8, 12, 13, 14})

MIN_NAME_LENGTH: Final = 2

#: Pure fat is 884 kcal/100 g. Anything above 900 is an error, not a food.
MAX_ENERGY_KCAL_PER_100G: Final = 900.0

#: Protein + carbohydrate + fat cannot exceed 100 g in 100 g. Five grams of
#: slack absorbs rounding on three independently rounded label figures.
MAX_MACRO_SUM_PER_100G: Final = 105.0

#: No nutrient can exceed the mass it is measured in. The same five grams of
#: slack as MAX_MACRO_SUM_PER_100G, for the same reason.
#:
#: R9 bounds energy and R10 bounds protein+carbohydrate+fat, but fibre, sugar
#: and sodium were bounded by nothing at all until a full build found sodium at
#: 788 g/100 g. An unbounded column is not merely wrong, it is an overflow: the
#: value is scaled and handed to SQLite, which rejects anything past int64 —
#: seventy minutes into a build, with no indication of which row did it.
MAX_NUTRIENT_G_PER_100G: Final = 105.0

#: A serving above five kilograms is a data-entry error, not a catering pack.
MAX_SERVING_G: Final = 5_000.0

#: Atwater cross-check. A mismatch is measured against the stated energy both
#: relatively and absolutely; a row must breach both to be actioned, so a 60%
#: mismatch on a 12 kcal celery product is ignored.
ATWATER_REJECT_RELATIVE: Final = 0.50
ATWATER_REJECT_ABSOLUTE: Final = 100.0
ATWATER_FLAG_RELATIVE: Final = 0.30
ATWATER_FLAG_ABSOLUTE: Final = 50.0

# --------------------------------------------------------------------------
# Storage scaling
# --------------------------------------------------------------------------

#: Nutrients are stored as scaled integers rather than REAL, which measured 17%
#: smaller on a full build. Every factor here is at or below the precision OFF's
#: own labels carry, so nothing real is lost in the rounding.
KCAL_SCALE: Final = 1
MACRO_SCALE: Final = 10
SODIUM_SCALE: Final = 100
SERVING_G_SCALE: Final = 10

#: Salt to sodium. Used only when the `sodium` nutriment is absent and `salt` is
#: present; sodium is never a reject reason, so a missing value stays null
#: rather than being guessed at.
SALT_TO_SODIUM: Final = 2.5

# --------------------------------------------------------------------------
# Ranking
# --------------------------------------------------------------------------

#: Search must surface the trustworthy entry first rather than the first
#: alphabetical duplicate. Scan count dominates; completeness breaks ties.
RANK_SCANS_CLAMP: Final = 10_000
RANK_SCANS_WEIGHT: Final = 100
RANK_COMPLETENESS_WEIGHT: Final = 100

#: A row carrying a quality flag is downranked rather than hidden. See ADR-0017.
RANK_FLAGGED_DIVISOR: Final = 4

# --------------------------------------------------------------------------
# Snapshot identity
# --------------------------------------------------------------------------

#: Bumped whenever the SQLite schema changes shape. The app refuses a snapshot
#: whose `min_app_schema` exceeds what it understands, rather than mis-reading a
#: column that moved.
SCHEMA_VERSION: Final = 1

#: The oldest app schema version that can read a snapshot built by this code.
MIN_APP_SCHEMA: Final = 1

COMPRESSION: Final = "zstd"
ZSTD_LEVEL: Final = 19

# --------------------------------------------------------------------------
# Attribution
# --------------------------------------------------------------------------

#: Stored inside the snapshot itself, and repeated in the manifest.
#:
#: Docs/LICENSING.md requires a per-food source badge and an Attribution screen
#: naming Open Food Facts with a link and the licence notice. Driving that from
#: data that ships with the database means the notice cannot drift from the rows
#: actually installed — a hardcoded string in the app would survive a snapshot
#: swap that changed the source.
OFF_SOURCE_NAME: Final = "Open Food Facts"
OFF_SOURCE_URL: Final = "https://openfoodfacts.org"
OFF_LICENCE: Final = "Open Database License (ODbL) 1.0"
OFF_LICENCE_URL: Final = "https://opendatacommons.org/licenses/odbl/1-0/"

OFF_ATTRIBUTION: Final = (
    "Contains information from Open Food Facts (https://openfoodfacts.org), "
    "made available under the Open Database License (ODbL) 1.0 "
    "(https://opendatacommons.org/licenses/odbl/1-0/)."
)

USDA_SOURCE_NAME: Final = "USDA FoodData Central"
USDA_SOURCE_URL: Final = "https://fdc.nal.usda.gov"
USDA_LICENCE: Final = "Public domain (CC0)"
