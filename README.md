# MacPigeon

Experimental macOS launcher for GamePigeon games, with local play and a Messages integration. Requires an Apple Silicon Mac running macOS 26 or later.

## Build

Install full Xcode, select its command-line tools, and install Rust and the native build dependencies. The command-line tools alone do not provide the Mac Catalyst frameworks used by the renderer.

```sh
brew install python@3.13 protobuf pkg-config openssl@3
```

The source build automatically downloads the Apple Music Android APK directly from Apple, verifies the pinned SHA-256 of the two required ARM64 libraries, and caches them at `.build-inputs/apple-music-arm64-libs.zip`. Later builds reuse the verified cache. If Apple changes the libraries, the build stops with a hash mismatch until the supported hashes are reviewed and updated. To use an existing archive, set `MACPIGEON_ANISSETTE_LIBS` to its location. The ZIP must contain:

- `lib/arm64-v8a/libCoreADI.so`
- `lib/arm64-v8a/libstoreservicescore.so`

The local Anisette provider uses these libraries in an emulator to generate Apple authentication headers for account sign-in. It does not call macOS's native Anisette APIs or a remote Anisette service. This archive is separate from the GamePigeon IPA and contains no account credentials. Apple's binaries are kept in ignored build inputs, rather than the source repository. The build bundles them into the resulting app, so users of a prebuilt app do not need to download or provide this archive.

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

Open the app and use Settings to import a **decrypted GamePigeon IPA with internal version 2.0.13, build 19**, containing the supported extension executable. These version numbers come from the IPA's internal metadata; a filename or download label is not sufficient to identify it. The executable must also match the SHA-256 recorded in `resources/supported-game-binary.json`, so a different executable with the same version number is rejected.

No GamePigeon executable, artwork, IPA, or fallback renderer payload is embedded in this source build. Encrypted IPAs are rejected. The importer adapts a local copy and leaves the supplied IPA unchanged.

Messages features require the relevant macOS permissions, account setup, and a matching conversation. Accessibility and Full Disk Access are configured in System Settings; Contacts lookup is optional. Account material is stored through the app's Keychain flow, and game state is stored locally in Application Support.

App data is stored under `~/Library/Application Support/MacPigeon`. On first launch, files from the historical `MacPigeon Lab` directory are copied into the new folder; existing destination files take precedence, and the old folder is retained as a recovery copy. Its `SelectedTest` subfolder becomes `Delivery`. Migration finishes before account or game helpers start, and an unsuccessful migration can be retried. Settings → Open Data Folder opens the folder in Finder. Account sessions and delivery keys remain in Keychain, and renderer data remains in its macOS sandbox container.

This is an experimental project that uses Apple's private interfaces. Game support and online behavior vary by adapter; the source catalog is in `scripts/game_adapters.py` and `scripts/game_modes`. A separate Mac or clean macOS VM should be used to check installation, permissions, import, and account behavior before distributing a build.

## Third-party code

The MacPigeon-authored material covered by [LICENSE](LICENSE) uses Apache 2.0 with the Commons Clause. The required attribution is `Copyright 2026 chimoochi`; recipients must retain the notice and license. The Commons Clause restricts selling MacPigeon or a product or service whose value derives substantially from it. This is source-available, not OSI-approved open source. Third-party components keep their own terms; see [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md). GamePigeon and Apple assets are supplied locally and have not been licensed by this repository.
