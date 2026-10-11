#!/bin/zsh
set -eu
root=${0:A:h:h}
app="$root/build/RendererHostTemplate.app"
python=${MACPIGEON_PYTHON:-python3.13}
"$python" - "$root" "$app" <<'PY'
import json, plistlib, shutil, sys
from pathlib import Path
root, app = map(Path, sys.argv[1:])
if app.exists():
    shutil.rmtree(app)
resources = app / 'Contents/Resources'
resources.mkdir(parents=True)
(app / 'Contents/MacOS').mkdir()
info = {'CFBundleIdentifier': 'local.macpigeon.native.renderer',
        'CFBundleName': 'MacPigeon Game', 'CFBundleExecutable': 'OriginalHost',
        'CFBundlePackageType': 'APPL', 'CFBundleVersion': '1',
        'LSMinimumSystemVersion': '14.0', 'NSHighResolutionCapable': True,
        'UIDeviceFamily': [1, 2], 'UIRequiresFullScreen': False,
        'UIApplicationSceneManifest': {'UIApplicationSupportsMultipleScenes': False,
            'UISceneConfigurations': {'UIWindowSceneSessionRoleApplication': [{
                'UISceneConfigurationName': 'Game', 'UISceneClassName': 'UIWindowScene',
                'UISceneDelegateClassName': 'NativeSceneDelegate'}]}}}
(app / 'Contents/Info.plist').write_bytes(plistlib.dumps(info))
sys.path.insert(0, str(root / 'scripts'))
from game_adapters import GAMES
(resources / 'macpigeon-game-registry.json').write_text(json.dumps({
    game: dict(title=title, scene=scene) for game, (title, scene) in GAMES.items()}))
PY
sdk=$(xcrun --sdk macosx --show-sdk-path)
xcrun clang -target arm64-apple-ios14.0-macabi -isysroot "$sdk" \
  -iframework "$sdk/System/iOSSupport/System/Library/Frameworks" \
  -L "$sdk/System/iOSSupport/usr/lib" -fobjc-arc "$root/source/OriginalHost.m" \
  -framework Foundation -framework UIKit -framework SpriteKit -framework SceneKit \
  -framework Messages -framework CoreText -framework CoreGraphics \
  -o "$app/Contents/MacOS/OriginalHost"
codesign --force --sign - --entitlements "$root/source/renderer-entitlements.plist" "$app"
