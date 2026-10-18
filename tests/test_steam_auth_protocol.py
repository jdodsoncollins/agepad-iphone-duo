#!/usr/bin/env python3
"""Compile and exercise real native Steam auth with an entirely offline transport."""
from pathlib import Path
import subprocess
ROOT = Path(__file__).resolve().parents[1]
out = ROOT / 'generated/steam-auth-regression'
out.mkdir(parents=True, exist_ok=True)
exe = out / 'steam_auth_protocol_test'
subprocess.run(['xcrun', 'clang', '-fobjc-arc', '-I', str(ROOT / 'port/steam-engine'),
    str(ROOT / 'tests/steam_auth_protocol_test.m'), '-framework', 'Foundation',
    '-framework', 'CoreImage', '-framework', 'CoreGraphics', '-framework', 'ImageIO',
    '-framework', 'Security', '-o', str(exe)], check=True)
subprocess.run([str(exe)], check=True, timeout=40)
