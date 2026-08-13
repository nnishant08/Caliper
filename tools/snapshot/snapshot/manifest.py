"""The manifest: the one mutable object clients poll, and the trust root.

Layout on Cloudflare R2:

    manifest.json                                   max-age=60, must-revalidate
    snapshots/<id>/caliper-foods-NNN.sqlite.zst     max-age=31536000, immutable

Artifacts are immutable under versioned keys and cached forever; only the small
manifest is ever revalidated. R2 costs nothing in egress, which is why a ~63 MB
download per install is affordable at all, and it honours range requests, which
is what M2's resumable download needs.

**No signing.** There is no backend and no accounts (§2 of the brief), so the
manifest is the trust root and HTTPS plus write access to the bucket is the
whole security model. That is a decision, not an omission: the worst outcome an
attacker with bucket write access achieves here is wrong macronutrients, not
code execution — the payload is opened as a read-only SQLite file, never
evaluated. Signing would need a key shipped in the binary and a revocation story
neither of which exists in v1, and it would buy less than the CDN's own TLS.
"""

from __future__ import annotations

import json
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

from . import config


def build_manifest(
    *,
    snapshot_id: str,
    object_key: str,
    base_url: str,
    bytes_compressed: int,
    bytes_expanded: int,
    sha256_expanded: str,
    sha256_compressed: str,
    markets: list[str],
    table_counts: dict[str, int],
    source_url: str,
    source_etag: str | None,
    source_rows: int,
    accepted_rows: int,
    built_at: datetime | None = None,
) -> dict[str, Any]:
    built = built_at or datetime.now(timezone.utc)

    return {
        "manifest_version": 1,
        # An older build must REFUSE a newer snapshot rather than mis-read a
        # column that moved. The app compares its own schema understanding
        # against this and declines rather than guessing.
        "min_app_schema": config.MIN_APP_SCHEMA,
        "snapshot": {
            "id": snapshot_id,
            "schema_version": config.SCHEMA_VERSION,
            "built_at": built.isoformat().replace("+00:00", "Z"),
            "url": f"{base_url.rstrip('/')}/{object_key.lstrip('/')}",
            "compression": config.COMPRESSION,
            "bytes_compressed": bytes_compressed,
            "bytes_expanded": bytes_expanded,
            # Of the expanded file — what actually gets opened.
            "sha256": sha256_expanded,
            # Of the transferred bytes — verifies the download itself.
            "sha256_compressed": sha256_compressed,
            "markets": markets,
            "tables": table_counts,
        },
        # Not decoration. Docs/LICENSING.md requires a per-food source badge and
        # an Attribution screen naming Open Food Facts with a link and the ODbL
        # notice. Driving that UI from this block rather than from hardcoded
        # strings means the notice cannot drift from the data actually installed.
        "sources": [
            {
                "id": "off",
                "name": config.OFF_SOURCE_NAME,
                "url": config.OFF_SOURCE_URL,
                "licence": config.OFF_LICENCE,
                "licence_url": config.OFF_LICENCE_URL,
                "attribution": config.OFF_ATTRIBUTION,
                "export_url": source_url,
                "export_etag": source_etag,
                "export_rows": source_rows,
                "rows": accepted_rows,
            },
            {
                "id": "usda",
                "name": config.USDA_SOURCE_NAME,
                "url": config.USDA_SOURCE_URL,
                "licence": config.USDA_LICENCE,
                "licence_url": None,
                "attribution": None,
                "export_url": None,
                "export_etag": None,
                "export_rows": 0,
                "rows": table_counts.get("usda_foods", 0),
            },
        ],
    }


def write_manifest(manifest: dict[str, Any], path: Path) -> Path:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(manifest, indent=2, sort_keys=False) + "\n", encoding="utf-8")
    return path


def upload_hint(snapshot_path: Path, object_key: str, bucket: str = "caliper-snapshots") -> str:
    """How to publish what was just built. Printed, never executed.

    Uploading is a deliberate act with a cost attached, so the build stops at
    telling you the command.
    """
    return (
        "# Artifact first, manifest second — a manifest pointing at an object\n"
        "# that is not there yet is the one ordering that breaks live clients.\n"
        f"rclone copyto {snapshot_path} r2:{bucket}/{object_key} \\\n"
        '  --header-upload "Cache-Control: public, max-age=31536000, immutable"\n'
        f"rclone copyto out/manifest.json r2:{bucket}/manifest.json \\\n"
        '  --header-upload "Cache-Control: public, max-age=60, must-revalidate"'
    )
