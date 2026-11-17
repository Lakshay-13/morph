# Contributing to Morph

Thanks for helping improve Morph. Keep changes focused and preserve the source file by default.

## Before opening a change

- Check the current conversion routes and engine conventions in [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md) and [`docs/ENGINE_REGISTRY.md`](docs/ENGINE_REGISTRY.md).
- Add or update a real-file check when changing conversion behavior. Verify output validity and that the source checksum is unchanged.
- Update the tested capability report only after running the conversion on actual files.
- Document new engine licenses and whether the engine is bundled or installed separately.

## Build and checks

```sh
swift build --product Morph
Scripts/run-checks.sh
```

The checks use local engines when installed. A missing optional tool may cause its specific check to be skipped; report that result rather than treating it as a pass.

## Pull requests

Include the user-visible behavior, the formats and engines affected, test output, and any licensing or security implications. Do not commit build products, app archives, signing credentials, user files or Homebrew bottles.

By contributing, you agree that your contributions are licensed under the project's Apache License 2.0.
