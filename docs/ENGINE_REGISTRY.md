# Registering formats and engines

Morph's format graph is in `Sources/MorphCore/EngineRegistry.swift`; models and engine metadata are in `Models.swift`; adapters are registered by `ConversionService.defaultEngines(for:)` in `ConversionService.swift`.

## Add a format

1. Add a `MorphFormat` entry to `ConversionCatalog.formats` with its extension, display label and `FormatCategory`.
2. Add the extension mapping to the relevant capability probe. Do not add a route for a format that the adapter cannot read or write.
3. Add input/output route creation in `ConversionCatalog.buildRoutes` with the category check and required engine capability.
4. Add the extension to the adapter's format mapping and implement any required codec parameters.
5. Extend `OutputValidator` so generated outputs of a structured or container format receive a format-specific validity check where practical.
6. Add actual fixture-based conversions and verify output properties and the input checksum in `Tests/MorphChecks/main.swift`.
7. Update `docs/TEST_REPORT.md`, the README format table and known limitations only after the conversion is executed.

Multi-part extensions such as `.tar.gz` are recognized by `URL.morphExtension(knownExtensions:)`, which tries longer registered suffixes first.

LibreOffice routes are constrained to text-document, presentation or spreadsheet families, with PDF export from each family. Do not generate a Cartesian product across all office extensions: a file extension alone does not make cross-family conversions meaningful or supported.

## Add an engine

1. Add an `EngineID` case, display name, Homebrew formula (if appropriate), executable candidates and plain-language summary in `Models.swift`.
2. Add a capability probe in `EngineRegistry.probeCapabilities`. Probe actual runtime support; do not infer codecs from container names alone.
3. Add a `ConversionEngine` adapter in `ConversionService.swift`. It receives a `ConversionContext` and must write only to `temporaryOutputURL`.
4. Register the adapter in `defaultEngines(for:)` and create routes only when its engine and input/output capabilities are present.
5. Use `ProcessRunner` with an executable URL and individual arguments. Do not use `/bin/sh`, interpolate untrusted input into a command string, or run commands embedded in files.
6. Ensure cancellation reaches child processes, outputs are validated, and failure removes staged files. Use temporary working directories for tools that write to their input basename.
7. Add consent-aware install/update/uninstall UI only if Morph has a safe package path and the engine's license is documented in `docs/THIRD_PARTY.md`.
8. Add positive, failure, malformed-input and source-preservation checks.

## Engine contract

`ConversionEngine.convert(context:)` is synchronous and runs on a background task. It should throw `MorphError` with a useful message, honor `context.cancellation`, never replace the original, and never publish a partial destination. When more than one route exists, the service tries them in deterministic priority order and falls back after an adapter failure. New adapters may be supplied to `ConversionService` for tests; they augment the default adapters and can replace one by engine ID.
