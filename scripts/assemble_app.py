"""Assemble the launcher and import template without embedding GamePigeon."""
import hashlib
import json
import os
import plistlib
import shutil
import sys
from pathlib import Path

root = Path(__file__).resolve().parents[1]
app = root / 'build/MacPigeon.app'
if app.exists():
    shutil.rmtree(app)
resources = app / 'Contents/Resources'
binary = app / 'Contents/MacOS'
resources.mkdir(parents=True)
binary.mkdir()
shutil.copy2(root / 'build/bin/NativeBridge', binary)
shutil.copy2(root / 'build/auth-target/release/macpigeon-auth', binary)
shutil.copy2(root / 'build/transport-target/release/macpigeon-transport', binary)
shutil.copy2(root / 'runtime/balloon/target/release/macpigeon-balloon-probe', resources / 'macpigeon-balloon')
shutil.copytree(root / 'build/RendererHostTemplate.app', resources / 'RendererHostTemplate.app', symlinks=True)
shutil.copytree(root / 'scripts/game_modes', resources / 'game_modes',
                ignore=shutil.ignore_patterns('__pycache__', '*.pyc'))
for name in ('local_play.py', 'export_native_state.py', 'sync_selected_game.py',
             'game_session.py', 'game_adapters.py', 'new_games.py', 'connect_codec.py',
             'game_rules.py', 'import_mac_game.py', 'install_local_ipa.py',
             'binary_adapter.py', 'decode_one_live_turn.py', 'local_anisette_worker.py',
             'push_bootstrap_worker.py'):
    shutil.copy2(root / 'scripts' / name, resources / name)
for path in (root / 'resources').iterdir():
    if path.is_file():
        shutil.copy2(path, resources / path.name)
shutil.copy2(root / 'source/vendor/apple-private-apis/LICENSE', resources / 'ApplePrivateAPIs-LICENSE.txt')
shutil.copy2(root / 'LICENSE', resources / 'LICENSE.txt')
shutil.copy2(root / 'THIRD_PARTY_NOTICES.md', resources / 'THIRD_PARTY_NOTICES.md')
shutil.copy2(Path(sys.argv[1]).resolve(), resources / 'apple-music-arm64-libs.zip')
# Public legacy bootstrap material is obtained from the pinned backend source.
# It remains confined to ignored build outputs and is never committed here.
backend = root / 'build/deps/rustpush'
names = ['certs/legacy-fairplay/fairplay.crt', 'certs/legacy-fairplay/fairplay.pem']
names += ['certs/root/' + name + '.cer' for name in (
    'AppleIncRootCertificate', 'AppleRootCA-G2', 'AppleRootCA-G3')]
manifest = {}
for name in names:
    source = backend / name
    destination = resources / 'PushBootstrapMaterial' / name
    destination.parent.mkdir(parents=True, exist_ok=True)
    shutil.copy2(source, destination)
    manifest[name] = hashlib.sha256(source.read_bytes()).hexdigest()
(resources / 'push-bootstrap-manifest.json').write_text(json.dumps(manifest))
info = {'CFBundleIdentifier': 'local.macpigeon.native', 'CFBundleName': 'MacPigeon',
        'CFBundleExecutable': 'NativeBridge', 'CFBundlePackageType': 'APPL',
        'CFBundleVersion': os.environ.get('MACPIGEON_BUILD_VERSION', '1'),
        'CFBundleShortVersionString': os.environ.get('MACPIGEON_VERSION', '0.1.0'),
        'LSMinimumSystemVersion': '26.0',
        'NSContactsUsageDescription': 'Find the address for the one contact name shown in your open Messages conversation.'}
(app / 'Contents/Info.plist').write_bytes(plistlib.dumps(info))
