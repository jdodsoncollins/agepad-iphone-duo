"""Check the production loaded-image entry guard without running a game/helper."""
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
with tempfile.TemporaryDirectory() as directory:
    binary = Path(directory) / 'ipc-entry-test'
    subprocess.run(['xcrun', 'clang', '-Wall', '-Wextra', '-Werror',
                    '-I', str(ROOT / 'port/de'), str(ROOT / 'tests/ipc_helper_entry_test.c'),
                    '-o', str(binary)], check=True)
    subprocess.run([str(binary)], check=True, timeout=10)
