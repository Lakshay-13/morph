# Security policy

## Reporting a vulnerability

Please report a security issue privately to the repository owner through GitHub's private vulnerability reporting feature, if enabled. Include the affected Morph version, macOS version, reproduction steps and impact. Do not attach private files or credentials.

## Current security boundaries

- Conversion is local. Morph does not send file contents to a service.
- The optional engine manager reads Homebrew formula metadata only after an Install action is selected. Package installation, update and uninstall each require an explicit confirmation.
- Process adapters use executable paths and argument arrays, not shell command strings.
- Conversions stage into unique temporary files, validate output and preserve the original.
- ZIP extraction rejects absolute and parent traversal member paths, extracts to a new staging directory and checks links before moving the result into place.
- Morph does not bundle external conversion engines.

Morph is not sandboxed in this first SwiftPM build. It needs file access to the user-selected input and configured output location. Treat third-party conversion engines as separate software and keep them updated through their package manager.
