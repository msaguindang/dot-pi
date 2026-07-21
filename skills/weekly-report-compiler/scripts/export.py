#!/usr/bin/env python3
"""
Converts a weekly report .md to .docx via pandoc.
Uses reference.docx (Lexend font) if available.
"""

import argparse
import json
import os
import subprocess
import sys
from pathlib import Path


def load_config() -> dict:
    config_path = Path(__file__).parent / "config.json"
    with open(config_path, "r", encoding="utf-8") as f:
        return json.load(f)


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--report-path", required=True, help="Absolute path to the .md report file")
    args = parser.parse_args()

    report_path = Path(args.report_path).resolve()
    if not report_path.exists():
        print(f"Error: report not found: {report_path}", file=sys.stderr)
        sys.exit(1)

    config = load_config()
    docx_dir = Path(config["docx_output_dir"]).expanduser().resolve()
    docx_dir.mkdir(parents=True, exist_ok=True)

    docx_filename = report_path.stem + ".docx"
    docx_path = docx_dir / docx_filename

    reference_docx = Path(__file__).parent / "reference.docx"

    cmd = ["pandoc", str(report_path), "-o", str(docx_path)]
    if reference_docx.exists():
        cmd += [f"--reference-doc={reference_docx}"]
    else:
        print("Warning: reference.docx not found — using pandoc default styles. Run make_reference.py to generate it.", file=sys.stderr)

    result = subprocess.run(cmd, capture_output=True, text=True)
    if result.returncode != 0:
        print(f"pandoc error: {result.stderr}", file=sys.stderr)
        sys.exit(1)

    print(f"Exported: {docx_path}")


if __name__ == "__main__":
    main()
