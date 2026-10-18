#!/usr/bin/env python3
"""Inspect an existing private .app; never sign, install, provision, or upload."""
import argparse
import json
from pathlib import Path

from agepad_distribution import inspect_bundle

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('bundle', type=Path)
parser.add_argument('--mode', choices=('development', 'app-store'), default='app-store')
parser.add_argument('--output', type=Path, help='Fresh local JSON report')
args = parser.parse_args()
if args.output and args.output.exists():
    parser.error('Output already exists')
report = inspect_bundle(args.bundle, args.mode)
text = json.dumps(report, indent=2) + '\n'
if args.output:
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(text)
else:
    print(text, end='')
raise SystemExit(0 if report['ready'] else 1)
