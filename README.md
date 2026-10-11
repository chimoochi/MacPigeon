# MacPigeon

Experimental macOS launcher for GamePigeon games, with local play and a Messages integration. Requires an Apple Silicon Mac running macOS 26 or later.

## Build

Install full Xcode, select its command-line tools, and install Rust and the native build dependencies. The command-line tools alone do not provide the Mac Catalyst frameworks used by the renderer.

```sh
brew install python@3.13 protobuf pkg-config openssl@3
```

For a source build, provide an archive at `.build-inputs/apple-music-arm64-libs.zip`, or set `MACPIGEON_ANISSETTE_LIBS` to an existing archive's location. The ZIP must contain these ARM64 libraries from the Apple Music Android app:

- `lib/arm64-v8a/libCoreADI.so`
- `lib/arm64-v8a/libstoreservicescore.so`

The local Anisette provider uses these libraries to generate Apple authentication headers for account sign-in. This archive is separate from the GamePigeon IPA and contains no account credentials. The Apple libraries are not included in this repository, and the build does not download them. The build bundles them into the resulting app, so users of a prebuilt app do not need to provide this archive.

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

Messages features require the relevant macOS permissions, account setup, and a matching conversation. Accessibility and Full Disk Access are configured in System Settings; Contacts lookup is optional. Account material is stored through the app's Keychain flow, and game state is stored locally in Application Support. Some existing storage paths retain the historical `MacPigeon Lab` name for compatibility.

This is an experimental project that uses Apple's private interfaces. Game support and online behavior vary by adapter; the source catalog is in `scripts/game_adapters.py` and `scripts/game_modes`. A separate Mac or clean macOS VM should be used to check installation, permissions, import, and account behavior before distributing a build.

## Third-party code

See [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md) and the included license files. No new license has been selected for the original MacPigeon code; the included third-party code retains its own licenses. GamePigeon and Apple assets are supplied locally and have not been licensed by this repository.
