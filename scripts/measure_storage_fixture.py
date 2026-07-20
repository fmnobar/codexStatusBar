#!/usr/bin/env python3
"""Measure the frozen synthetic v2/v3 token-dimension fixture (no user data)."""

from __future__ import annotations

import argparse
import json
from pathlib import Path
import shutil
import sqlite3
import sys
import tempfile
import time


DIMENSION_KEYS = (
    "originator", "source_kind", "thread_source", "cli_version",
    "model_provider", "memory_mode", "approval_policy", "sandbox_type",
    "permission_profile", "realtime_active", "truncation_policy", "usage_mode",
)


def arguments() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--turns", type=int, default=10_000)
    parser.add_argument("--samples-per-turn", type=int, default=14)
    parser.add_argument("--dimension-sets", type=int, default=64)
    parser.add_argument("--output-dir", type=Path)
    parser.add_argument("--json-output", type=Path)
    parser.add_argument("--keep", action="store_true")
    return parser.parse_args()


def configure(database: sqlite3.Connection) -> None:
    database.executescript(
        "PRAGMA journal_mode=WAL; PRAGMA synchronous=OFF; "
        "PRAGMA temp_store=MEMORY; PRAGMA page_size=4096;"
    )


def create_sample_table(database: sqlite3.Connection, normalized: bool) -> None:
    dimension_column = (
        ", dimension_set_id INTEGER REFERENCES token_dimension_sets(set_id)"
        if normalized else ""
    )
    database.execute(
        f"""
        CREATE TABLE token_usage_samples (
            thread_id TEXT NOT NULL, turn_id TEXT NOT NULL, model TEXT,
            session_id TEXT, project_path TEXT, project_name TEXT, effort TEXT,
            source TEXT, received_at INTEGER NOT NULL, model_context_window INTEGER,
            last_input_tokens INTEGER NOT NULL, last_cached_input_tokens INTEGER NOT NULL,
            last_output_tokens INTEGER NOT NULL, last_reasoning_output_tokens INTEGER NOT NULL,
            last_total_tokens INTEGER NOT NULL, total_input_tokens INTEGER NOT NULL,
            total_cached_input_tokens INTEGER NOT NULL, total_output_tokens INTEGER NOT NULL,
            total_reasoning_output_tokens INTEGER NOT NULL, total_total_tokens INTEGER NOT NULL,
            observed_input_tokens INTEGER, observed_cached_input_tokens INTEGER,
            observed_output_tokens INTEGER, observed_reasoning_output_tokens INTEGER,
            observed_total_tokens INTEGER NOT NULL,
            is_retention_baseline INTEGER NOT NULL DEFAULT 0
            {dimension_column},
            PRIMARY KEY(thread_id, turn_id, total_total_tokens)
        )
        """
    )
    database.executescript(
        """
        CREATE INDEX idx_token_usage_samples_received_at
            ON token_usage_samples(received_at);
        CREATE INDEX idx_token_usage_samples_thread_total
            ON token_usage_samples(thread_id, total_total_tokens);
        """
    )
    if normalized:
        database.execute(
            "CREATE INDEX idx_token_usage_samples_dimension_set "
            "ON token_usage_samples(dimension_set_id) WHERE dimension_set_id IS NOT NULL"
        )


def create_legacy_schema(database: sqlite3.Connection) -> None:
    create_sample_table(database, normalized=False)
    database.executescript(
        """
        CREATE TABLE token_usage_dimensions (
            thread_id TEXT NOT NULL, turn_id TEXT NOT NULL,
            total_total_tokens INTEGER NOT NULL, dimension_key TEXT NOT NULL,
            dimension_value TEXT NOT NULL, seen_at INTEGER NOT NULL,
            PRIMARY KEY (
                thread_id, turn_id, total_total_tokens,
                dimension_key, dimension_value
            )
        );
        CREATE INDEX idx_token_usage_dimensions_key_value_seen
            ON token_usage_dimensions(dimension_key, dimension_value, seen_at DESC);
        """
    )


def create_normalized_schema(
    database: sqlite3.Connection,
    set_count: int,
) -> list[list[tuple[str, str]]]:
    database.executescript(
        """
        PRAGMA foreign_keys=ON;
        CREATE TABLE token_dimension_values (
            value_id INTEGER PRIMARY KEY, dimension_key TEXT NOT NULL,
            dimension_value TEXT NOT NULL, first_seen_at INTEGER NOT NULL,
            last_seen_at INTEGER NOT NULL, UNIQUE(dimension_key, dimension_value)
        );
        CREATE TABLE token_dimension_sets (
            set_id INTEGER PRIMARY KEY, signature BLOB NOT NULL UNIQUE
        );
        CREATE TABLE token_dimension_set_members (
            set_id INTEGER NOT NULL REFERENCES token_dimension_sets(set_id) ON DELETE CASCADE,
            value_id INTEGER NOT NULL REFERENCES token_dimension_values(value_id) ON DELETE RESTRICT,
            PRIMARY KEY(set_id, value_id)
        );
        CREATE INDEX idx_token_dimension_values_key_value
            ON token_dimension_values(dimension_key, dimension_value);
        CREATE INDEX idx_token_dimension_set_members_value_set
            ON token_dimension_set_members(value_id, set_id);
        """
    )
    sets: list[list[tuple[str, str]]] = []
    value_ids: dict[tuple[str, str], int] = {}
    timestamp = 1_767_225_600
    for set_index in range(set_count):
        values = [
            (key, f"safe-{key}-{(set_index + key_index * 7) % set_count:02d}")
            for key_index, key in enumerate(DIMENSION_KEYS)
        ]
        sets.append(values)
        ids: list[int] = []
        for key, value in values:
            pair = (key, value)
            value_id = value_ids.get(pair)
            if value_id is None:
                value_id = len(value_ids) + 1
                value_ids[pair] = value_id
                database.execute(
                    "INSERT INTO token_dimension_values VALUES (?, ?, ?, ?, ?)",
                    (value_id, key, value, timestamp, timestamp),
                )
            ids.append(value_id)
        ids.sort()
        set_id = set_index + 1
        signature = json.dumps(ids, separators=(",", ":")).encode("utf-8")
        database.execute(
            "INSERT INTO token_dimension_sets(set_id, signature) VALUES (?, ?)",
            (set_id, signature),
        )
        database.executemany(
            "INSERT INTO token_dimension_set_members(set_id, value_id) VALUES (?, ?)",
            ((set_id, value_id) for value_id in ids),
        )
    create_sample_table(database, normalized=True)
    return sets


def sample_row(
    turn_index: int,
    sample_index: int,
    dimension_set_id: int | None,
) -> tuple[object, ...]:
    cumulative = (sample_index + 1) * 100
    values: list[object] = [
        f"019f-fixture-thread-{turn_index:010d}",
        f"019f-fixture-turn-{turn_index:010d}-{sample_index:02d}",
        "gpt-5.5-codex", f"fixture-session-{turn_index:010d}",
        f"/synthetic/projects/project-{turn_index % 128:03d}",
        f"project-{turn_index % 128:03d}",
        ("high", "xhigh")[turn_index % 2], "cli",
        1_767_225_600 + turn_index * 15 + sample_index, 258_400,
        70, 10, 15, 5, 100,
        cumulative * 7 // 10, cumulative // 10, cumulative * 15 // 100,
        cumulative * 5 // 100, cumulative,
        70, 10, 15, 5, 100, 0,
    ]
    if dimension_set_id is not None:
        values.append(dimension_set_id)
    return tuple(values)


def insert_fixture(
    database: sqlite3.Connection,
    turns: int,
    samples_per_turn: int,
    dimension_sets: list[list[tuple[str, str]]],
    normalized: bool,
) -> None:
    placeholders = ",".join("?" for _ in range(27 if normalized else 26))
    sample_insert = f"INSERT INTO token_usage_samples VALUES ({placeholders})"
    dimension_insert = "INSERT INTO token_usage_dimensions VALUES (?, ?, ?, ?, ?, ?)"
    database.execute("BEGIN IMMEDIATE")
    for turn_index in range(turns):
        samples: list[tuple[object, ...]] = []
        dimensions: list[tuple[object, ...]] = []
        for sample_index in range(samples_per_turn):
            set_index = (turn_index * 17 + sample_index * 5) % len(dimension_sets)
            row = sample_row(
                turn_index,
                sample_index,
                set_index + 1 if normalized else None,
            )
            samples.append(row)
            if not normalized:
                dimensions.extend(
                    (str(row[0]), str(row[1]), int(row[19]), key, value, int(row[8]))
                    for key, value in dimension_sets[set_index]
                )
        database.executemany(sample_insert, samples)
        if dimensions:
            database.executemany(dimension_insert, dimensions)
        if turn_index and turn_index % 250 == 0:
            database.commit()
            database.execute("BEGIN IMMEDIATE")
    database.commit()


def finish(database: sqlite3.Connection) -> None:
    database.execute("PRAGMA wal_checkpoint(TRUNCATE)")
    database.execute("VACUUM")
    database.execute("PRAGMA wal_checkpoint(TRUNCATE)")
    database.commit()


def object_bytes(database: sqlite3.Connection, tables: tuple[str, ...]) -> int:
    placeholders = ",".join("?" for _ in tables)
    return int(
        database.execute(
            f"""
            SELECT COALESCE(SUM(pgsize), 0) FROM dbstat
            WHERE name IN (
                SELECT name FROM sqlite_master WHERE tbl_name IN ({placeholders})
                UNION ALL
                SELECT name FROM sqlite_master WHERE name IN ({placeholders})
            )
            """,
            tables + tables,
        ).fetchone()[0]
    )


def file_set_bytes(path: Path) -> int:
    return sum(
        candidate.stat().st_size
        for candidate in (path, Path(f"{path}-wal"), Path(f"{path}-shm"))
        if candidate.exists()
    )


def main() -> int:
    args = arguments()
    if args.turns <= 0 or args.samples_per_turn <= 0 or args.dimension_sets <= 0:
        raise SystemExit("fixture counts must be positive")
    generated_directory = args.output_dir is None
    root = args.output_dir or Path(tempfile.mkdtemp(prefix="codex-storage-fixture-"))
    root.mkdir(parents=True, exist_ok=True)
    legacy_path = root / "usage-history-v2.sqlite3"
    normalized_path = root / "usage-history-v3.sqlite3"
    for path in (legacy_path, normalized_path):
        for candidate in (path, Path(f"{path}-wal"), Path(f"{path}-shm")):
            if candidate.exists():
                candidate.unlink()

    started = time.monotonic()
    normalized = sqlite3.connect(normalized_path)
    configure(normalized)
    sets = create_normalized_schema(normalized, args.dimension_sets)
    insert_fixture(normalized, args.turns, args.samples_per_turn, sets, normalized=True)
    finish(normalized)
    normalized_dimension_bytes = object_bytes(
        normalized,
        ("token_dimension_values", "token_dimension_sets", "token_dimension_set_members"),
    )
    normalized.close()

    legacy = sqlite3.connect(legacy_path)
    configure(legacy)
    create_legacy_schema(legacy)
    insert_fixture(legacy, args.turns, args.samples_per_turn, sets, normalized=False)
    finish(legacy)
    legacy_dimension_bytes = object_bytes(legacy, ("token_usage_dimensions",))
    legacy.close()

    legacy_total = file_set_bytes(legacy_path)
    normalized_total = file_set_bytes(normalized_path)
    dimension_reduction = 1 - normalized_dimension_bytes / max(legacy_dimension_bytes, 1)
    total_ratio = normalized_total / max(legacy_total, 1)
    result = {
        "fixture": {
            "turns": args.turns,
            "samples_per_turn": args.samples_per_turn,
            "samples": args.turns * args.samples_per_turn,
            "dimensions_per_sample": len(DIMENSION_KEYS),
            "legacy_dimension_rows": args.turns * args.samples_per_turn * len(DIMENSION_KEYS),
            "repeated_dimension_sets": args.dimension_sets,
            "synthetic_only": True,
        },
        "v2": {"dimension_bytes": legacy_dimension_bytes, "total_bytes": legacy_total},
        "v3": {"dimension_bytes": normalized_dimension_bytes, "total_bytes": normalized_total},
        "gates": {
            "dimension_reduction_fraction": dimension_reduction,
            "dimension_reduction_at_least_80_percent": dimension_reduction >= 0.80,
            "total_v3_to_v2_ratio": total_ratio,
            "total_v3_at_most_40_percent_of_v2": total_ratio <= 0.40,
        },
        "elapsed_seconds": time.monotonic() - started,
    }
    encoded = json.dumps(result, indent=2, sort_keys=True) + "\n"
    print(encoded, end="")
    if args.json_output:
        args.json_output.parent.mkdir(parents=True, exist_ok=True)
        args.json_output.write_text(encoded, encoding="utf-8")

    passed = (
        result["gates"]["dimension_reduction_at_least_80_percent"]
        and result["gates"]["total_v3_at_most_40_percent_of_v2"]
    )
    if generated_directory and not args.keep:
        shutil.rmtree(root)
    elif args.keep:
        print(f"fixture_directory={root}", file=sys.stderr)
    return 0 if passed else 1


if __name__ == "__main__":
    raise SystemExit(main())
