"""`python -m snapshot inspect` and `python -m snapshot build`.

The build prints its reject table, its quality-flag counts, **the thresholds
that produced them**, bytes per row and compressed size, every time. A rate
without the rule behind it is not evidence — it is a number that looks like one.
"""

from __future__ import annotations

import argparse
import sys
import time
from collections import Counter
from datetime import datetime, timezone
from pathlib import Path

from . import config, manifest as manifest_module, source_off
from .quality import QualityFlag, Reject, evaluate_full
from .writer import SnapshotWriter, compress


# --------------------------------------------------------------------------
# Reporting
# --------------------------------------------------------------------------


def _percent(count: int, total: int) -> str:
    return f"{(100.0 * count / total):6.2f}%" if total else "     —"


def print_thresholds() -> None:
    print("\nThresholds in force")
    print("-" * 78)
    print(f"  barcode lengths accepted      {sorted(config.VALID_BARCODE_LENGTHS)}")
    print(f"  minimum name length           {config.MIN_NAME_LENGTH}")
    print(f"  max energy                    {config.MAX_ENERGY_KCAL_PER_100G:g} kcal/100g")
    print(f"  max protein+carb+fat          {config.MAX_MACRO_SUM_PER_100G:g} g/100g")
    print(
        "  Atwater reject                "
        f"> {config.ATWATER_REJECT_RELATIVE:.0%} AND > {config.ATWATER_REJECT_ABSOLUTE:g} kcal"
    )
    print(
        "  Atwater flag (kept, downranked)"
        f" > {config.ATWATER_FLAG_RELATIVE:.0%} AND > {config.ATWATER_FLAG_ABSOLUTE:g} kcal"
    )
    print(f"  energy resolution order       energy-kcal -> energy-kj/{config.KJ_PER_KCAL} -> energy (unit-qualified)")
    print(f"  markets                       {', '.join(config.MARKET_BITS)}")
    print(f"  scaling                       kcal x{config.KCAL_SCALE}, macros x{config.MACRO_SCALE}, "
          f"sodium x{config.SODIUM_SCALE}, serving x{config.SERVING_G_SCALE}")


def print_rejects(
    first_match: Counter[Reject],
    independent: Counter[Reject],
    seen: int,
    accepted: int,
) -> None:
    """Two columns, because one of them is an artefact of rule ordering.

    `first match` explains the row count: each rule sees only what earlier rules
    let through, so the column sums to the rejected total. `independent` asks of
    every row whether that rule alone would have rejected it, so it does not sum
    to anything — rows fail several rules at once — but it is the column that
    describes the data rather than the sequence.

    The gap between them is largest on R12: it disqualifies roughly two thirds
    of the export on its own, so moving it earlier or later in the order shifts
    large percentages between rows without one row changing fate.
    """
    print("\nRejects by reason")
    print("-" * 78)
    print(f"  {'rule':<46} {'first match':>14} {'independent':>14}")
    print("-" * 78)
    for reason in Reject:
        first = first_match.get(reason, 0)
        alone = independent.get(reason, 0)
        print(f"  {reason.value:<46} {first:>7,d} {_percent(first, seen)} {alone:>7,d} {_percent(alone, seen)}")
    print("-" * 78)
    rejected = sum(first_match.values())
    print(f"  {'rejected':<46} {rejected:>7,d} {_percent(rejected, seen)}")
    print(f"  {'accepted':<46} {accepted:>7,d} {_percent(accepted, seen)}")


def print_flags(flags: Counter[QualityFlag], accepted: int) -> None:
    print("\nQuality flags (kept, downranked in search — never hidden)")
    print("-" * 78)
    for flag in QualityFlag:
        if flag is QualityFlag.NONE:
            continue
        count = flags.get(flag, 0)
        print(f"  {flag.name:<52} {count:>9,d} {_percent(count, accepted)}")


def print_breakdown(breakdown: dict[str, int], total: int) -> None:
    if not breakdown:
        print("\n  (dbstat unavailable in this SQLite build — no per-table breakdown)")
        return
    print("\nOn-disk breakdown")
    print("-" * 78)
    for name, size in breakdown.items():
        print(f"  {name:<52} {size / 1e6:>8.1f} MB {_percent(size, total)}")


# --------------------------------------------------------------------------
# Commands
# --------------------------------------------------------------------------


def command_inspect(args: argparse.Namespace) -> int:
    info = source_off.describe(args.source)
    print(f"source        {info.url}")
    print(f"rows          {info.num_rows:,d}")
    print(f"row groups    {info.num_row_groups:,d} (~{info.num_rows // max(info.num_row_groups, 1):,d} rows each)")
    print(f"columns       {info.num_columns} physical, {len(config.COLUMNS)} read")
    print(f"etag          {info.etag or '—'}")
    print("\ncolumns read")
    for column in config.COLUMNS:
        print(f"  {column}")
    return 0


def command_build(args: argparse.Namespace) -> int:
    started = time.monotonic()
    out = Path(args.out)

    info = source_off.describe(args.source)
    groups = source_off.select_row_groups(info.num_row_groups, args.row_groups, args.stride)

    print(f"source        {info.url}")
    print(f"row groups    {len(groups):,d} of {info.num_row_groups:,d}"
          f"{' (strided across the file)' if args.stride and args.row_groups else ''}")
    if args.row_groups and not args.stride:
        print("  ! contiguous head sample: the export is ordered by barcode and therefore by")
        print("    country prefix, so these rates describe one region, not the database.")

    snapshot_id = args.snapshot_id or datetime.now(timezone.utc).strftime("%Y%m%d-%H%M%S")
    snapshot_path = out / f"caliper-foods-{config.SCHEMA_VERSION:03d}.sqlite"

    rejects: Counter[Reject] = Counter()
    independent: Counter[Reject] = Counter()
    flags: Counter[QualityFlag] = Counter()
    seen = 0
    accepted = 0

    with SnapshotWriter(snapshot_path) as writer:
        for row in source_off.iter_rows(
            args.source, args.row_groups, args.stride, args.workers, info.metadata
        ):
            seen += 1
            verdict = evaluate_full(row)
            independent.update(verdict.all_rejects)
            if verdict.reject is not None:
                rejects[verdict.reject] += 1
                continue
            product = verdict.product
            assert product is not None
            accepted += 1
            for flag in QualityFlag:
                if flag is not QualityFlag.NONE and product.flags & flag:
                    flags[flag] += 1
            writer.add(product)

            if args.progress and seen % 100_000 == 0:
                print(f"  ... {seen:,d} rows read, {accepted:,d} accepted", flush=True)

        writer.write_meta(
            {
                "schema_version": str(config.SCHEMA_VERSION),
                "snapshot_id": snapshot_id,
                "built_at": datetime.now(timezone.utc).isoformat().replace("+00:00", "Z"),
                "markets": ",".join(config.MARKET_BITS),
                "off.name": config.OFF_SOURCE_NAME,
                "off.url": config.OFF_SOURCE_URL,
                "off.licence": config.OFF_LICENCE,
                "off.licence_url": config.OFF_LICENCE_URL,
                # The notice travels inside the data. A snapshot separated from
                # its manifest still says who it came from and under what terms.
                "off.attribution": config.OFF_ATTRIBUTION,
                "usda.name": config.USDA_SOURCE_NAME,
                "usda.licence": config.USDA_LICENCE,
            }
        )
        result = writer.finish()

    print_thresholds()
    print_rejects(rejects, independent, seen, accepted)
    print_flags(flags, accepted)

    print("\nSnapshot")
    print("-" * 78)
    print(f"  rows                          {result.rows:,d}")
    print(f"  duplicate codes dropped (R3)  {result.duplicates:,d}")
    print(f"  on disk                       {result.bytes_on_disk / 1e6:.1f} MB")
    print(f"  bytes/row                     {result.bytes_per_row:.1f}")
    print_breakdown(result.page_breakdown, result.bytes_on_disk)

    compressed_path, compressed_size, compressed_digest = compress(snapshot_path)
    ratio = result.bytes_on_disk / compressed_size if compressed_size else 0
    print(f"\n  zstd-{config.ZSTD_LEVEL}                       {compressed_size / 1e6:.1f} MB ({ratio:.1f}x)")

    object_key = f"snapshots/{snapshot_id}/{compressed_path.name}"
    document = manifest_module.build_manifest(
        snapshot_id=snapshot_id,
        object_key=object_key,
        base_url=args.base_url,
        bytes_compressed=compressed_size,
        bytes_expanded=result.bytes_on_disk,
        sha256_expanded=result.sha256,
        sha256_compressed=compressed_digest,
        markets=list(config.MARKET_BITS),
        table_counts={"off_products": result.rows, "usda_foods": 0, "off_corrections": 0},
        source_url=info.url,
        source_etag=info.etag,
        source_rows=info.num_rows,
        accepted_rows=result.rows,
    )
    manifest_path = manifest_module.write_manifest(document, out / "manifest.json")

    print(f"  manifest                      {manifest_path}")
    print(f"  elapsed                       {time.monotonic() - started:.0f}s")

    if seen and args.row_groups:
        projected = int(info.num_rows * accepted / seen)
        print(f"\n  projected full build          ~{projected:,d} rows "
              f"(+/-10%; the first full build's measured number is the real one)")

    print("\nPublish")
    print("-" * 78)
    print(manifest_module.upload_hint(compressed_path, object_key))
    return 0


# --------------------------------------------------------------------------
# Entry point
# --------------------------------------------------------------------------


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(prog="snapshot", description=__doc__)
    subparsers = parser.add_subparsers(dest="command", required=True)

    common = argparse.ArgumentParser(add_help=False)
    common.add_argument("--source", default=config.OFF_PARQUET_URL,
                        help="local parquet path or https URL (default: the OFF export)")

    inspect = subparsers.add_parser("inspect", parents=[common],
                                    help="report what the source says about itself")
    inspect.set_defaults(func=command_inspect)

    build = subparsers.add_parser("build", parents=[common], help="build a snapshot and manifest")
    build.add_argument("--out", default="out", help="output directory")
    build.add_argument("--row-groups", type=int, default=None,
                       help="read only N row groups (development sample)")
    build.add_argument("--stride", action="store_true",
                       help="spread the sampled row groups across the file rather than "
                            "taking the head, which is ordered by barcode and so by country")
    build.add_argument("--snapshot-id", default=None, help="override the generated snapshot id")
    build.add_argument("--base-url", default="https://snapshots.caliper.app",
                       help="public base URL the manifest points at")
    build.add_argument("--workers", type=int, default=8,
                       help="row groups fetched concurrently; over HTTPS the cost is "
                            "round-trip latency, not bandwidth (default: 8)")
    build.add_argument("--progress", action="store_true", help="print progress every 100k rows")
    build.set_defaults(func=command_build)

    return parser


def main(argv: list[str] | None = None) -> int:
    args = build_parser().parse_args(argv)
    return int(args.func(args))


if __name__ == "__main__":
    sys.exit(main())
