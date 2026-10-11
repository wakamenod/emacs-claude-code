"""Read records from delimited text files."""

from pathlib import Path


def parse_line(line, delimiter=","):
    """Split LINE into fields, stripped of spaces."""
    fields = line.rstrip("\n").split(delimiter)
    if fields and fields[-1].strip() == "":
        fields.pop()
    return [field.strip() for field in fields]


def read_records(path, delimiter=","):
    """Yield the fields of each line of PATH.

    Blank lines and lines starting with # are
    skipped."""
    with Path(path).open(encoding="utf-8") as f:
        for line in f:
            if line.strip() and line[0] != "#":
                yield parse_line(line, delimiter)
