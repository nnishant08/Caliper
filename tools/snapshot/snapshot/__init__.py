"""Caliper food-database snapshot pipeline.

Turns the Open Food Facts parquet export into the read-only SQLite snapshot the
app downloads on first launch, plus the manifest that points at it.

Runs offline, on a developer machine. Nothing here ships in the app.
"""
