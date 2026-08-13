"""Streaming reader for the Open Food Facts parquet export.

One row group at a time, column-projected, from a local path or straight off
HTTPS via range requests. Peak memory stays in the low tens of megabytes
regardless of row count — the file is 7.76 GB and 4.67M rows, and nothing here
ever holds more than a single ~1,021-row group.
"""

from __future__ import annotations

import dataclasses
from collections.abc import Iterator
from typing import Any

import pyarrow.parquet as pq

from . import config


@dataclasses.dataclass(slots=True)
class SourceInfo:
    """What the export says about itself, for the manifest and for `inspect`."""

    url: str
    num_rows: int
    num_row_groups: int
    num_columns: int
    etag: str | None
    #: The parsed thrift footer, kept so callers can hand it straight to
    #: `iter_rows` instead of paying to parse ~102 MB of it a second time.
    metadata: Any = dataclasses.field(default=None, repr=False)


def _open(source: str):
    """Open a local path or an HTTPS URL as a seekable binary file."""
    if source.startswith(("http://", "https://")):
        import fsspec

        return fsspec.filesystem("https").open(source, "rb")
    return open(source, "rb")


def _etag(source: str) -> str | None:
    if not source.startswith(("http://", "https://")):
        return None
    try:
        import fsspec

        info = fsspec.filesystem("https").info(source)
    except Exception:
        # The etag is provenance, not correctness. A source that will not report
        # one still builds; the manifest simply records null.
        return None
    for key in ("ETag", "etag"):
        value = info.get(key)
        if value:
            return str(value).strip('"')
    return None


def select_row_groups(total: int, limit: int | None, stride: bool) -> list[int]:
    """Which row groups to read.

    `stride` spreads the selection evenly across the file, which matters more
    than it sounds: the export is ordered by barcode and therefore by GS1 country
    prefix, so the first N row groups are a sample of France and nothing else.
    A contiguous head would report a market distribution, a reject profile and a
    bytes-per-row figure that none of them generalise.
    """
    if limit is None or limit >= total:
        return list(range(total))
    if not stride:
        return list(range(limit))

    step = total / limit
    return sorted({min(total - 1, int(index * step)) for index in range(limit)})


def describe(source: str) -> SourceInfo:
    with _open(source) as handle:
        parquet = pq.ParquetFile(handle)
        metadata = parquet.metadata
        return SourceInfo(
            url=source,
            num_rows=metadata.num_rows,
            num_row_groups=metadata.num_row_groups,
            num_columns=metadata.num_columns,
            etag=_etag(source),
            metadata=metadata,
        )


def iter_rows(
    source: str,
    row_group_limit: int | None = None,
    stride: bool = False,
    workers: int = 8,
    metadata: Any = None,
) -> Iterator[dict[str, Any]]:
    """Yield decoded rows, one row group at a time.

    Only `config.COLUMNS` is read. Projecting at the parquet layer rather than
    after decoding is the difference between ~0.6 GB and 7.76 GB of transfer.

    Over HTTPS the cost is latency, not bandwidth: each row group needs one
    ranged read per column chunk, so a 13-column projection is thirteen
    round-trips before a single row is decoded. Reading groups concurrently
    turns a serial chain of round-trips into a handful of parallel ones and is
    worth roughly 6x wall-clock; nothing else about the streaming changes.

    **Results are yielded in row-group order regardless of completion order.**
    That is not cosmetic. Insert order decides which of two rows sharing a
    barcode survives R3, so an out-of-order build would produce a different
    file — and a different sha256 — from the same input.

    Peak memory stays bounded at `workers` row groups, each ~1,021 rows.
    """
    columns = list(config.COLUMNS)

    if metadata is None:
        with _open(source) as handle:
            metadata = pq.ParquetFile(handle).metadata

    groups = select_row_groups(metadata.num_row_groups, row_group_limit, stride)

    if workers <= 1 or len(groups) <= 1:
        with _open(source) as handle:
            parquet = pq.ParquetFile(handle, metadata=metadata)
            for index in groups:
                table = parquet.read_row_group(index, columns=columns)
                yield from table.to_pylist()
                del table
        return

    yield from _iter_rows_parallel(source, groups, columns, workers, metadata)


def _iter_rows_parallel(
    source: str,
    groups: list[int],
    columns: list[str],
    workers: int,
    metadata: Any = None,
) -> Iterator[dict[str, Any]]:
    """Read row groups on a small thread pool, yielding in order.

    Each worker keeps its own file handle. An fsspec HTTP file is a seekable
    cursor, not a thread-safe reader — sharing one across threads interleaves
    seeks and silently returns bytes from the wrong offset.

    The already-parsed `metadata` is handed to every worker. This export's
    thrift footer is ~102 MB — 4,567 row groups times 145 columns of statistics
    — so letting each worker rediscover it would transfer that eight times over
    before a single row was read, which was most of the wall-clock cost of the
    naive version.
    """
    import threading
    from concurrent.futures import ThreadPoolExecutor

    local = threading.local()
    handles: list[Any] = []
    handles_lock = threading.Lock()

    def reader() -> pq.ParquetFile:
        existing = getattr(local, "parquet", None)
        if existing is None:
            handle = _open(source)
            with handles_lock:
                handles.append(handle)
            existing = pq.ParquetFile(handle, metadata=metadata)
            local.parquet = existing
        return existing

    def read(index: int):
        return reader().read_row_group(index, columns=columns).to_pylist()

    try:
        with ThreadPoolExecutor(max_workers=workers) as pool:
            pending: list[Any] = []
            queue = list(groups)

            # A sliding window rather than submitting everything at once: with
            # 4,567 groups the eager form would queue every result in memory and
            # undo the streaming guarantee.
            while queue and len(pending) < workers:
                pending.append(pool.submit(read, queue.pop(0)))

            while pending:
                rows = pending.pop(0).result()
                if queue:
                    pending.append(pool.submit(read, queue.pop(0)))
                yield from rows
    finally:
        for handle in handles:
            try:
                handle.close()
            except Exception:
                pass
