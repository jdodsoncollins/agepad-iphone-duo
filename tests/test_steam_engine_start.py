#!/usr/bin/env python3
"""Exercise real engine initialization with offline synthetic vtable responses."""
from pathlib import Path
import subprocess
ROOT = Path(__file__).resolve().parents[1]
out = ROOT / 'generated/steam-engine-start-regression'
out.mkdir(parents=True, exist_ok=True)
exe = out / 'steam_engine_start_test'
subprocess.run(['xcrun', 'clang', '-std=c11', '-Wall', '-Wextra', '-Werror',
    '-I', str(ROOT / 'port/steam-engine'), str(ROOT / 'tests/steam_engine_start_test.c'),
    '-o', str(exe)], check=True)
subprocess.run([str(exe)], check=True, timeout=10)
