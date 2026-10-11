# MacPigeon

Experimental macOS launcher for GamePigeon games, with local play and a Messages integration. Requires an Apple Silicon Mac running macOS 26 or later.

## Build

Install full Xcode, select its command-line tools, and install Rust and the native build dependencies. The command-line tools alone do not provide the Mac Catalyst frameworks used by the renderer.

```sh
brew install python@3.13 protobuf pkg-config openssl@3
```

Provide your local ARM64 Anisette library archive at `.build-inputs/apple-music-arm64-libs.zip`, or set `MACPIGEON_ANISSETTE_LIBS` to its location. This archive contains Apple Music authentication libraries used by the local Anisette provider. It is not included in the repository, and the build does not download it for you.

```sh
export MACPIGEON_PYTHON="$(brew --prefix python@3.13)/bin/python3.13"
export OPENSSL_DIR="$(brew --prefix openssl@3)"
zsh scripts/build_native.sh
```

The build fetches RustPush and its submodules at fixed commits into the ignored `build/deps` directory, installs the pinned Python dependencies, and produces `build/MacPigeon.app`. Network access is needed on the first build. Build tools are not required on a user's Mac: Python and the helper dependencies are bundled in the app.

The default output is ad-hoc signed. It is not Developer ID signed or notarized. The transport still uses legacy push bootstrap material from the pinned backend; building successfully does not establish that an installer is ready for public redistribution.

Optional build settings:

- `MACPIGEON_ANISSETTE_LIBS`: path to the local ARM64 library archive.
- `MACPIGEON_PYTHON`: framework Python 3.13 executable used for packaging.
- `MACPIGEON_PYTHON_FRAMEWORK`: Python framework version directory, if it differs from that interpreter's base prefix.
- `MACPIGEON_VERSION` and `MACPIGEON_BUILD_VERSION`: app version and build number.

## First run

Open the app and use Settings to import your compatible decrypted GamePigeon IPA. No GamePigeon executable, artwork, IPA, or fallback renderer payload is embedded in this source build. The importer checks the extension executable against `resources/supported-game-binary.json`; encrypted IPAs and other executable hashes are rejected. It adapts a local copy and leaves the supplied IPA unchanged.

Messages features require the relevant macOS permissions, account setup, and a matching conversation. Accessibility and Full Disk Access are configured in System Settings; Contacts lookup is optional. Account material is stored through the app's Keychain flow, and game state is stored locally in Application Support. Some existing storage paths retain the historical `MacPigeon Lab` name for compatibility.

This is an experimental project that uses Apple's private interfaces. Game support and online behavior vary by adapter; the source catalog is in `scripts/game_adapters.py` and `scripts/game_modes`. A separate Mac or clean macOS VM should be used to check installation, permissions, import, and account behavior before distributing a build.

## Third-party code

See [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md) and the included license files. No new license has been selected for the original MacPigeon code; the included third-party code retains its own licenses. GamePigeon and Apple assets are supplied locally and have not been licensed by this repository.
