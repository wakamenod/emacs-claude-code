"""Summarise records files by their first column."""

from __future__ import annotations

import argparse
import logging
from collections import Counter
from dataclasses import dataclass, field
from pathlib import Path

from reader import read_records

log = logging.getLogger(__name__)


@dataclass
class Summary:
    """What a file held, counted by key."""

    path: Path
    rows: int = 0
    keys: Counter[str] = field(default_factory=Counter)

    def most_common(self, n: int = 5) -> list[tuple[str, int]]:
        return self.keys.most_common(n)


def summarise(path: Path, delimiter: str = ",") -> Summary:
    """Count the rows of PATH by their first field."""
    summary = Summary(path)
    for fields in read_records(path, delimiter):
        if not fields or not fields[0]:
            log.warning("%s: a row with no key", path)
            continue
        summary.rows += 1
        summary.keys[fields[0]] += 1
    return summary


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("paths", nargs="+", type=Path)
    parser.add_argument("-d", "--delimiter", default=",")
    args = parser.parse_args(argv)
    for path in args.paths:
        summary = summarise(path, args.delimiter)
        print(f"{path}: {summary.rows} rows")
        for key, count in summary.most_common():
            print(f"  {key}\t{count}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
