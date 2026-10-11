#!/bin/zsh
set -eu
root=${0:A:h:h}
python=${MACPIGEON_PYTHON:-python3.13}
libs=${MACPIGEON_ANISSETTE_LIBS:-$root/.build-inputs/apple-music-arm64-libs.zip}
if [[ -n "${MACPIGEON_ANISSETTE_LIBS:-}" && ! -f "$libs" ]]; then
  print -u2 "Missing local Anisette library archive: $libs"
  print -u2 "MACPIGEON_ANISSETTE_LIBS must point to an existing archive. Unset it to download from Apple."
  exit 1
fi
for tool in "$python" cargo xcrun protoc pkg-config; do
  command -v "$tool" >/dev/null || { print -u2 "Missing build tool: $tool"; exit 1; }
done
cd "$root"
export MACPIGEON_PYTHON="$python"
"$python" "$root/scripts/fetch_anisette.py" "$libs"
"$python" "$root/scripts/fetch_transport.py"
"$python" "$root/scripts/prepare_transport.py"
cp "$root/source/transport/Cargo.lock" "$root/build/deps/rustpush/Cargo.lock"
cargo build --locked --release --manifest-path "$root/runtime/balloon/Cargo.toml"
CARGO_TARGET_DIR="$root/build/auth-target" cargo build --locked --release --manifest-path "$root/source/auth/Cargo.toml"
CARGO_TARGET_DIR="$root/build/transport-target" cargo build --locked --release \
  --manifest-path "$root/build/deps/rustpush/Cargo.toml" --bin macpigeon-transport
zsh "$root/scripts/build_host.sh"
mkdir -p "$root/build/bin"
xcrun swiftc -O -target arm64-apple-macos14.0 -parse-as-library \
  "$root/source/DataStorage.swift" "$root/source/GameSample.swift" "$root/source/Account.swift" "$root/source/MessagesContext.swift" \
  "$root/source/GameImporter.swift" "$root/source/GameRuntime.swift" \
  "$root/source/GameBubbleOpener.swift" "$root/source/LocalPlay.swift" "$root/source/SetupFlow.swift" \
  "$root/source/NativeBridge.swift" -framework SwiftUI -framework AppKit -framework Security \
  -framework Contacts -o "$root/build/bin/NativeBridge"
"$python" "$root/scripts/assemble_app.py" "$libs"
"$python" -m pip --isolated install --disable-pip-version-check --no-deps --target "$root/build/MacPigeon.app/Contents/Resources/python-vendor" \
  -r "$root/requirements-build.txt"
"$python" "$root/scripts/bundle_python.py" "$root/build/MacPigeon.app/Contents/Resources"
"$python" "$root/scripts/relocate_helpers.py" "$root/build/MacPigeon.app"
codesign --force --sign - "$root/build/MacPigeon.app/Contents/Resources/macpigeon-balloon"
codesign --force --sign - "$root/build/MacPigeon.app"
codesign --verify --deep --strict "$root/build/MacPigeon.app"
print "Built $root/build/MacPigeon.app (ad-hoc signed; import your supported IPA in Settings)."
