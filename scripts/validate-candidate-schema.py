#!/usr/bin/env python3
"""Validate a release-candidate manifest with the repository JSON Schema.

Duplicate object keys and malformed JSON are rejected before semantic checks.
This script is deliberately separate from the shell semantic validator.
"""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

try:
    from jsonschema import Draft202012Validator, FormatChecker
    from jsonschema.exceptions import SchemaError, ValidationError
except ImportError as exc:  # pragma: no cover - exercised only without tooling
    print(f"ERROR: jsonschema is required: {exc}", file=sys.stderr)
    raise SystemExit(1)


class ManifestError(Exception):
    pass


def reject_duplicate_keys(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise ManifestError(f"duplicate JSON object key: {key}")
        result[key] = value
    return result


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--manifest", required=True)
    parser.add_argument("--schema", required=True)
    args = parser.parse_args()

    try:
        with open(args.manifest, encoding="utf-8") as handle:
            manifest = json.load(handle, object_pairs_hook=reject_duplicate_keys)
    except ManifestError as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        return 1
    except (OSError, json.JSONDecodeError) as exc:
        print(f"ERROR: malformed candidate JSON: {exc}", file=sys.stderr)
        return 1

    try:
        with open(args.schema, encoding="utf-8") as handle:
            schema = json.load(handle)
        Draft202012Validator.check_schema(schema)
    except (OSError, json.JSONDecodeError, SchemaError) as exc:
        print(f"ERROR: invalid candidate schema: {exc}", file=sys.stderr)
        return 1

    validator = Draft202012Validator(schema, format_checker=FormatChecker())
    errors = sorted(validator.iter_errors(manifest), key=lambda e: list(e.path))
    if errors:
        for error in errors[:10]:
            location = "/".join(str(part) for part in error.path) or "<root>"
            print(f"ERROR: schema violation at {location}: {error.message}", file=sys.stderr)
        return 1

    print("Candidate schema: PASS")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
