"""Exercise the real asset installer and cleanup with private synthetic files."""
from pathlib import Path
import subprocess
import tempfile
root = Path(__file__).resolve().parents[1]
with tempfile.TemporaryDirectory() as temporary:
    binary = Path(temporary) / 'asset-store-test'
    subprocess.run(['xcrun', 'clang', '-fobjc-arc', '-Wno-deprecated-declarations',
                    '-I', str(root / 'port/de'), str(root / 'tests/game_asset_store_test.m'),
                    str(root / 'port/de/GameAssetStore.m'), '-framework', 'Foundation', '-o', str(binary)], check=True)
    subprocess.run([str(binary)], check=True, timeout=20)
