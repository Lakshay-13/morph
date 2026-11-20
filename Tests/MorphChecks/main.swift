import CoreGraphics
import CoreText
import CryptoKit
import CArchive
import CoreFoundation
import Darwin
import Foundation
import ImageIO
import MorphSandboxProbe
import UniformTypeIdentifiers
@testable import MorphCore
import PDFKit

struct CheckFailure: LocalizedError, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
    var errorDescription: String? { description }
}

final class MorphCheckSuite {
    let registry = EngineRegistry.discover()
    private let root = FileManager.default.temporaryDirectory.appendingPathComponent("morph-checks-\(UUID().uuidString)", isDirectory: true)
    private var passed = 0
    private var failed = 0
    private var skipped = 0

    init() throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    func run() {
        test("app and Finder helper quarantine generated files") { _ in try checkFileQuarantineConfiguration() }
        test("Keychain approvals require the exact Morph access group") { _ in try checkExactMorphAccessGroup() }
        test("Homebrew bottle-size authorization") { _ in try checkHomebrewBottleSizeAuthorization() }
        test("Homebrew package action flags") { try checkHomebrewPackageActions($0) }
        test("known vulnerable engine versions fail closed") { _ in try checkEngineSecurityFloors() }
        test("external engine sandbox denies network and sensitive IPC access") { _ in try checkLibreOfficeNetworkSandbox() }
        test("external engine sandbox limits writes to private stages") { try checkExternalEngineFileSandbox($0) }
        test("engine outputs reject hard links before publication") { try checkHardLinkedOutputRejection($0) }
        test("location metadata removal covers IPTC and QuickTime tags") { _ in try checkLocationMetadataPolicy() }
        test("engine trust rejects executable ACL write grants") { try checkEngineTrustRejectsWritableACL($0) }
        test("engine trust accepts protected Homebrew installation paths") { _ in try checkProtectedHomebrewPaths() }
        test("external engines require explicit executable approval") { try checkEngineTrustGate($0) }
        test("engine security versions are rechecked at execution") { try checkRuntimeEngineSecurityGate($0) }
        test("LibreOffice resolver requires the pinned vendor-signed bundle") { _ in try checkLibreOfficeResolverTrust() }
        test("7-Zip fails closed below its reviewed security floor") { try checkSevenZipSecurityGate($0) }
        test("direct video operations block an outdated FFmpeg") { try checkDirectVideoUtilitiesSecurityGate($0) }
        test("direct PDF compression blocks vulnerable Ghostscript") { try checkDirectGhostscriptSecurityGate($0) }
        test("private input snapshots reject special files and pin bytes") { try checkPrivateInputSnapshot($0) }
        test("Finder input preflight rejects folders and symbolic links") { try checkFinderInputPreflight($0) }
        test("unsafe output folders can be recognized for safe fallback") { try checkOutputDirectoryPolicy($0) }
        test("media output validation blocks an outdated FFprobe") { try checkMediaOutputValidationSecurityGate($0) }
        test("shared conversion history is serialized") { try checkConversionHistory($0) }
        test("bounded process output, timeouts, and process-group cancellation") { try checkProcessRunnerSafety($0) }
        test("cancellation never signals after process reap") { _ in try checkCancellationReapRace() }
        test("history rejects FIFOs without blocking") { try checkHistoryFIFO($0) }
        test("renamed output folders do not report dead result paths") { try checkRenamedOutputFolder($0) }
        test("conversion workspace rejects a moved output folder") { try checkConversionRejectsMovedOutputFolder($0) }
        test("PDF split rollback preserves a replaced directory") { try checkPDFSplitRollbackIdentity($0) }
        test("PDF split pins one output folder for the whole operation") { try checkPDFSplitRejectsMovedFolder($0) }
        test("ZIP publication rejects a moved output folder") { try checkZIPPublicationAfterMove($0) }
        test("structured-data output accepts a stable symlink folder") { try checkStructuredDataSymlinkOutput($0) }
        test("native images and PDF") { try checkImagesAndPDF($0) }
        test("ImageMagick strips GPS profiles when its route is available") { try checkImageMagickLocationRemoval($0) }
        test("multi-frame image conversion preserves every frame") { try checkMultiFrameImage($0) }
        test("route-aware conversion presets") { _ in try checkConversionPresets() }
        test("Finder conversion targets match the entire selection") { _ in try checkQuickConversionCatalog() }
        test("audio and video with FFmpeg") { try checkAudioVideo($0) }
        test("PDF page images adapt to page count") { try checkPDFPageImageZIP($0) }
        test("PDF and animated-image resource budgets") { try checkPDFAndImageResourceBudgets($0) }
        test("video trimming") { try checkVideoTrimming($0) }
        test("video compression") { try checkVideoCompression($0) }
        test("documents and PDF text") { try checkDocuments($0) }
        test("LibreOffice imports formula-like CSV text without evaluation") { try checkLibreOfficeCSVFormulaSafety($0) }
        test("LibreOffice routes require a successful private sandbox probe") { try checkLibreOfficeCapabilityProbe($0) }
        test("LibreOffice routes stay within compatible format families") { _ in try checkLibreOfficeRoutes() }
        test("PDF compression with Ghostscript") { try checkPDFCompression($0) }
        test("structured data") { try checkStructuredData($0) }
        test("archive snapshot revision check detects source changes") { try checkArchiveSnapshotRevision($0) }
        test("JSON date-shaped objects retain every field") { try checkJSONDateShapedObjects($0) }
        test("CSV CRLF parsing and extra-column rejection") { try checkDelimitedInputSafety($0) }
        test("CSV and TSV preserve explicit empty records") { try checkDelimitedEmptyRecords($0) }
        test("YAML and TOML transformations") { try checkYAMLAndTOML($0) }
        test("YAML aliases and complex keys are rejected safely") { try checkUnsafeYAML($0) }
        test("archive repackaging") { try checkArchives($0) }
        test("ZIP preflight rejects inconsistent and oversized entries") { try checkZIPPreflight($0) }
        test("ZIP UTF-8 names and symlink-selected output folders") { try checkZIPUnicodeAndSymlinkOutput($0) }
        test("7-Zip archive conversion") { try checkSevenZip($0) }
        test("archive traversal and symlink rejection") { try checkArchiveTraversal($0) }
        test("image resize, PDF pages, and ZIP extraction") { try checkFileOperations($0) }
        test("PDF page-range extraction") { try checkPDFPageRangeExtraction($0) }
        test("image and PDF metadata inspection") { try checkMetadataInspection($0) }
        test("safe metadata copy editing") { try checkMetadataEditing($0) }
        test("mixed batch, collisions, and source preservation") { try checkBatchAndCollisions($0) }
        test("batch rename copies preserve sources and avoid collisions") { try checkBatchRename($0) }
        test("invalid input and partial-output cleanup") { try checkInvalidInput($0) }
        test("private output staging rejects shared and inheriting folders") { try checkPrivateOutputStaging($0) }
        test("staging owner markers authenticate their directory and key") { _ in try checkStageMarkerAuthentication() }
        test("stale private staging cleanup is narrow and age bounded") { try checkStaleStageCleanup($0) }
        test("missing engine is reported before work starts") { try checkMissingEngine($0) }
        test("engine fallback and temporary cleanup") { try checkEngineFallback($0) }
        test("cancellation") { _ in try checkCancellation() }
        test("large image") { try checkLargeImage($0) }
        if let caseSensitiveRoot = ProcessInfo.processInfo.environment["MORPH_CASE_SENSITIVE_TEST_ROOT"] {
            test("case-sensitive archive extraction") { try checkCaseSensitiveArchiveExtraction(URL(fileURLWithPath: caseSensitiveRoot, isDirectory: true), fixtureFolder: $0) }
        }
        print("\nMorph checks: \(passed) passed, \(failed) failed, \(skipped) skipped")
        try? FileManager.default.removeItem(at: root)
        if failed > 0 { Darwin.exit(EXIT_FAILURE) }
    }

    private func test(_ name: String, body: (URL) throws -> Void) {
        if let filter = ProcessInfo.processInfo.environment["MORPH_ONLY_TEST"],
           !name.localizedCaseInsensitiveContains(filter) { return }
        let folder = root.appendingPathComponent(slug(name), isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try body(folder)
            passed += 1
            print("PASS  \(name)")
        } catch let error as CheckSkip {
            skipped += 1
            print("SKIP  \(name): \(error.description)")
        } catch {
            failed += 1
            print("FAIL  \(name): \(error.localizedDescription)")
        }
    }

    private func checkExactMorphAccessGroup() throws {
        let team = "ABCDE12345"
        let bundle = "com.lakshaychawla.Morph"
        let expected = "\(team).\(bundle)"
        let lookalike = "\(team).other.\(bundle)"
        try expect(
            EngineExecutableTrust.matchingAccessGroup(
                teamIdentifier: team,
                bundleIdentifier: bundle,
                groups: [lookalike, expected]
            ) == expected,
            "Morph should select only its exact team-scoped Keychain access group"
        )
        try expect(
            EngineExecutableTrust.matchingAccessGroup(
                teamIdentifier: team,
                bundleIdentifier: bundle,
                groups: [lookalike]
            ) == nil,
            "A same-team lookalike access group must not be accepted"
        )
        try expect(
            EngineExecutableTrust.matchingAccessGroup(
                teamIdentifier: "OTHERTEAM",
                bundleIdentifier: bundle,
                groups: [expected]
            ) == nil,
            "Another team's access group must not be accepted"
        )
    }

    private func checkHomebrewBottleSizeAuthorization() throws {
        let challenge = #"Bearer realm="https://ghcr.io/token",service="ghcr.io",scope="repository:homebrew/core/sevenzip:pull""#
        let request = HomebrewBottleSizeEstimator.tokenRequest(from: challenge, formula: "sevenzip")
        try expect(request?.httpMethod == nil || request?.httpMethod == "GET", "GHCR token requests must not mutate registry state")
        guard let request, let components = URLComponents(url: request.url!, resolvingAgainstBaseURL: false) else {
            throw CheckFailure("A valid GHCR pull challenge should produce a token request")
        }
        let query = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).compactMap { item in
            item.value.map { (item.name, $0) }
        })
        try expect(components.scheme == "https" && components.host == "ghcr.io" && components.path == "/token", "The token endpoint must remain on the trusted GHCR host")
        try expect(query["service"] == "ghcr.io" && query["scope"] == "repository:homebrew/core/sevenzip:pull", "The token request must be limited to this formula's pull scope")
        try expect(HomebrewBottleSizeEstimator.tokenRequest(from: challenge, formula: "sevenzip/other") == nil, "Formula names must not alter the expected repository scope")
        try expect(HomebrewBottleSizeEstimator.tokenRequest(from: challenge.replacingOccurrences(of: "https://ghcr.io/token", with: "https://attacker.example/token"), formula: "sevenzip") == nil, "The token endpoint must reject an untrusted host")
        try expect(HomebrewBottleSizeEstimator.tokenRequest(from: challenge.replacingOccurrences(of: "homebrew/core/sevenzip", with: "attacker/repo/sevenzip"), formula: "sevenzip") == nil, "The token scope must reject unrelated repositories")
        try expect(HomebrewBottleSizeEstimator.bearerToken(from: Data(#"{"token":"test-pull-token"}"#.utf8)) == "test-pull-token", "A registry pull token should be parsed")
        try expect(HomebrewBottleSizeEstimator.bearerToken(from: Data(#"{"access_token":"test-access-token"}"#.utf8)) == "test-access-token", "An access_token response should be supported")
        try expect(HomebrewBottleSizeEstimator.bearerToken(from: Data(#"{"token":"bad token"}"#.utf8)) == nil, "Whitespace-bearing tokens must be rejected")

        let blobURL = URL(string: "https://ghcr.io/blob")!
        let validResponse = HTTPURLResponse(url: blobURL, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Length": "1883515"])!
        let unauthorizedResponse = HTTPURLResponse(url: blobURL, statusCode: 401, httpVersion: "HTTP/1.1", headerFields: ["Content-Length": "73"])!
        let zeroLengthResponse = HTTPURLResponse(url: blobURL, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Length": "0"])!
        try expect(HomebrewBottleSizeEstimator.contentLength(from: validResponse) == 1_883_515, "A successful HEAD response should expose the compressed bottle length")
        try expect(HomebrewBottleSizeEstimator.contentLength(from: unauthorizedResponse) == nil, "An authentication error body must not be mistaken for the bottle length")
        try expect(HomebrewBottleSizeEstimator.contentLength(from: zeroLengthResponse) == nil, "A zero Content-Length is not a usable estimate")
    }

    private func checkHomebrewPackageActions(_ folder: URL) throws {
        try expect(EngineID.homebrewMetadataRefreshArguments == ["update"], "Engine update checks must have an explicit metadata-refresh action")
        let expected: [(EngineID, String, [String])] = [
            (.ffmpeg, "install", ["install", "--formula", "ffmpeg"]),
            (.imageMagick, "upgrade", ["upgrade", "--formula", "imagemagick"]),
            (.sevenZip, "uninstall", ["uninstall", "--formula", "sevenzip"]),
            (.libreOffice, "install", ["install", "--cask", "libreoffice"]),
            (.libreOffice, "outdated", ["outdated", "--quiet", "--cask", "libreoffice"]),
            (.libreOffice, "upgrade", ["upgrade", "--cask", "libreoffice"]),
            (.libreOffice, "uninstall", ["uninstall", "--cask", "libreoffice"]),
        ]
        for (engine, action, arguments) in expected {
            try expect(engine.homebrewArguments(action: action) == arguments, "Incorrect Homebrew \(action) invocation for \(engine.displayName)")
        }
        try expect(EngineID.pandoc.isHomebrewPackageOutdated(exitStatus: 1, standardOutput: "pandoc\n", standardError: ""), "Homebrew exit status 1 with the exact outdated package must be reported as outdated")
        try expect(!EngineID.pandoc.isHomebrewPackageOutdated(exitStatus: 0, standardOutput: "", standardError: ""), "An empty successful Homebrew result must be reported as current")
        try expect(EngineID.pandoc.isHomebrewPackageOutdated(exitStatus: 0, standardOutput: "pandoc\n", standardError: ""), "An exact package result must be accepted when Homebrew exits successfully")
        let homebrewEnvironment = HomebrewProcessEnvironment.overrides(from: [
            "https_proxy": "http://proxy.example:8443",
            "NO_PROXY": "localhost,.example.invalid",
            "HOMEBREW_NO_ANALYTICS": "0",
            "HOMEBREW_NO_AUTO_UPDATE": "0",
            "HOMEBREW_CASK_OPTS": "--no-quarantine",
            "PATH": "/attacker/bin",
            "http_proxy": "http://bad.example\nINJECTED=1",
        ])
        try expect(homebrewEnvironment["HOMEBREW_NO_ANALYTICS"] == "1", "Morph should disable Homebrew analytics")
        try expect(homebrewEnvironment["HOMEBREW_NO_AUTO_UPDATE"] == "1", "Morph should not trigger unapproved Homebrew self-updates")
        try expect(homebrewEnvironment["https_proxy"] == "http://proxy.example:8443" && homebrewEnvironment["NO_PROXY"] == "localhost,.example.invalid", "Morph did not preserve configured proxy settings")
        try expect(homebrewEnvironment["HOMEBREW_CASK_OPTS"] == nil && homebrewEnvironment["PATH"] == nil && homebrewEnvironment["http_proxy"] == nil, "Homebrew environment forwarding accepted an unsafe override")
        let environmentProbe = folder.appendingPathComponent("homebrew-environment-probe")
        try "#!/bin/sh\nprintf '%s|%s|%s' \"$HOMEBREW_NO_ANALYTICS\" \"$HOMEBREW_NO_AUTO_UPDATE\" \"$https_proxy\"\n".write(to: environmentProbe, atomically: true, encoding: .utf8)
        guard chmod(environmentProbe.path, mode_t(0o700)) == 0 else { throw CheckFailure("Could not mark the Homebrew environment probe executable") }
        let environmentResult = try ProcessRunner.run(
            executable: environmentProbe,
            arguments: [],
            environmentOverrides: homebrewEnvironment
        )
        try expect(environmentResult.status == 0 && environmentResult.stdout == "1|1|http://proxy.example:8443", "ProcessRunner did not pass the vetted Homebrew environment")
        for (status, stdout) in [(Int32(1), ""), (Int32(1), "another-package\n"), (Int32(2), "pandoc\n")] {
            do {
                _ = try EngineID.pandoc.isHomebrewPackageOutdated(exitStatus: status, standardOutput: stdout, standardError: "diagnostic")
                throw CheckFailure("Invalid Homebrew outdated result (status \(status), output \(stdout.debugDescription)) was accepted")
            } catch is CheckFailure {
                throw CheckFailure("Invalid Homebrew outdated result (status \(status), output \(stdout.debugDescription)) was accepted")
            } catch MorphError.processFailed {
                // Unexpected statuses and package names must be treated as check failures.
            }
        }
        try expect(EngineID.nativeImage.homebrewArguments(action: "install") == nil, "Built-in engines must not produce package-manager commands")
        try expect(EngineID.pandoc.homebrewArguments(action: "update") == nil, "A metadata refresh must not be confused with a package install or upgrade")
        try expect(EngineID.libreOffice.homebrewArguments(action: "run arbitrary") == nil, "Package action names must be constrained")

        let upgradeBatches = EngineID.homebrewUpgradeBatches(for: [.sevenZip, .ffmpeg, .libreOffice, .ffmpeg, .nativeImage])
        try expect(upgradeBatches == [
            ["upgrade", "--no-ask", "--formula", "ffmpeg", "sevenzip"],
            ["upgrade", "--no-ask", "--cask", "libreoffice"],
        ], "Update All must group only supported packages, deduplicate names, and keep formulae separate from casks")
        try expect(EngineID.homebrewUpgradeBatches(for: [.nativeImage, .nativePDF]).isEmpty, "Built-in engines must not appear in Update All package actions")
    }

    private func checkLibreOfficeNetworkSandbox() throws {
        guard FileManager.default.isExecutableFile(atPath: ExternalEngineSandbox.launcher.path) else {
            throw CheckSkip("macOS sandbox-exec is unavailable")
        }
        let preferenceDomain = "com.lakshaychawla.Morph.SandboxProbe.\(UUID().uuidString)"
        let readKey = "ReadCanary"
        let writeKey = "WriteCanary"
        let marker = UUID().uuidString
        let preferenceFile = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
            .appendingPathComponent("Library/Preferences/\(preferenceDomain).plist")
        guard !FileManager.default.fileExists(atPath: preferenceFile.path) else {
            throw CheckFailure("The unique sandbox preference fixture unexpectedly already exists")
        }
        var preferenceFixtureCreated = false
        defer {
            if preferenceFixtureCreated { try? FileManager.default.removeItem(at: preferenceFile) }
        }
        let preferenceData = try PropertyListSerialization.data(
            fromPropertyList: [readKey: marker],
            format: .binary,
            options: 0
        )
        try preferenceData.write(to: preferenceFile, options: .withoutOverwriting)
        preferenceFixtureCreated = true
        guard chmod(preferenceFile.path, mode_t(0o600)) == 0,
              (CFPreferencesCopyAppValue(readKey as CFString, preferenceDomain as CFString) as? String) == marker else {
            throw CheckFailure("Could not establish a positive-control user-preference fixture for the sandbox test")
        }

        let protectedServices = [
            "com.apple.cfprefsd.daemon",
            "com.apple.cfprefsd.agent",
            "com.apple.pasteboard.1",
            "com.apple.windowserver.active",
            "com.apple.CARenderServer",
        ]
        let availableProtectedServices = protectedServices.filter {
            morph_sandbox_attempt_mach_lookup($0) == KERN_SUCCESS
        }
        try expect(
            availableProtectedServices.contains(where: { $0 == "com.apple.cfprefsd.daemon" || $0 == "com.apple.cfprefsd.agent" }),
            "The preference sandbox probe has no reachable cfprefsd service for its Mach-lookup positive control"
        )
        let executable = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath().standardizedFileURL
        let result = try ProcessRunner.run(
            executable: executable,
            arguments: [
                "--external-engine-sandbox-network-probe", preferenceDomain, readKey, marker, writeKey,
            ] + availableProtectedServices,
            timeout: 10,
            restrictedSandbox: true
        )
        try expect(result.status == 0, "The external-engine sandbox did not execute its network and home-access probes (status \(result.status)): \(result.stderr)")
        guard let preferences = try PropertyListSerialization.propertyList(
            from: Data(contentsOf: preferenceFile),
            options: [],
            format: nil
        ) as? [String: Any] else {
            throw CheckFailure("The sandbox preference fixture became unreadable")
        }
        try expect(
            preferences[readKey] as? String == marker && preferences[writeKey] == nil,
            "A sandboxed process changed the private user-preference fixture"
        )
    }

    private func checkLibreOfficeResolverTrust() throws {
        guard let launcher = ExecutableLocator.resolve(["soffice"]) else {
            throw CheckSkip("LibreOffice's Homebrew launcher is not installed")
        }
        guard let executable = ExecutableLocator.resolveEngine(.libreOffice) else {
            throw CheckFailure("The installed LibreOffice launcher did not resolve to the pinned vendor-signed executable")
        }
        let bundle = executable
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let root = bundle.path
        let isExpectedLocation = root == "/Applications/LibreOffice.app"
            || ["/opt/homebrew/Caskroom/libreoffice/", "/usr/local/Caskroom/libreoffice/"]
                .contains(where: { root.hasPrefix($0) && root.hasSuffix("/LibreOffice.app") })
        try expect(isExpectedLocation, "LibreOffice resolved outside the supported Homebrew or Applications bundle locations: \(root)")
        try expect(FileManager.default.isExecutableFile(atPath: executable.path), "The pinned LibreOffice Mach-O is not executable")
        try expect(EngineExecutableTrust.requiredExecutables(for: .libreOffice) == [executable],
                   "LibreOffice digest approval does not cover the exact native executable Morph launches")
        try expect(launcher.path.hasSuffix("/soffice"), "LibreOffice launcher discovery returned an unexpected path")
    }

    private func checkExternalEngineFileSandbox(_ folder: URL) throws {
        let inputStage = try PrivateOutputStage(parentDirectory: folder, primaryFileName: "private-input.txt")
        let outputStage = try PrivateOutputStage(parentDirectory: folder, primaryFileName: "private-output.txt")
        let input = try inputStage.temporaryOutputURL()
        let output = try outputStage.temporaryOutputURL()
        try Data("approved input".utf8).write(to: input)
        let outsideRead = folder.appendingPathComponent("outside-stage.txt")
        try Data("must remain unreadable".utf8).write(to: outsideRead)
        let outsideWrite = folder.appendingPathComponent("outside-write.txt")
        let homeFixture = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
            .appendingPathComponent(".morph-sandbox-link-probe-\(UUID().uuidString)")
        try Data("must remain private".utf8).write(to: homeFixture, options: .withoutOverwriting)
        guard chmod(homeFixture.path, mode_t(0o600)) == 0 else {
            try? FileManager.default.removeItem(at: homeFixture)
            throw CheckFailure("Could not protect the home-directory sandbox fixture")
        }
        defer { try? FileManager.default.removeItem(at: homeFixture) }
        let hardLink = outputStage.directoryURL.appendingPathComponent("linked-home-file")
        let clone = outputStage.directoryURL.appendingPathComponent("cloned-home-file")
        let probeExecutable = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath().standardizedFileURL
        let result = try ProcessRunner.run(
            executable: probeExecutable,
            arguments: [
                "--external-engine-sandbox-probe", input.path, output.path, outsideRead.path,
                outsideWrite.path, homeFixture.path, hardLink.path, clone.path,
            ],
            timeout: 10,
            sandboxReadableDirectories: [inputStage.directoryURL],
            sandboxWritableDirectories: [outputStage.directoryURL],
            restrictedSandbox: true
        )
        let profile = try unwrap(
            ExternalEngineSandbox.profile(
                readableDirectories: [inputStage.directoryURL],
                writableDirectories: [outputStage.directoryURL],
                executable: probeExecutable
            ),
            "The external-engine sandbox profile could not be generated"
        )
        try expect(profile.contains("(deny file-write*)"), "The external-engine sandbox must deny writes outside declared stages")
        try expect(profile.contains("(allow process-exec (literal"), "The external-engine sandbox must allow only the reviewed engine executable")
        for requiredRule in [
            "(deny file-link file-clone)", "(deny appleevent-send)", "(deny job-creation)", "(deny lsopen)",
            "(deny process-exec)", "(deny process-fork)", "(deny signal (target others))",
            "(deny user-preference-read user-preference-write)",
            "(deny mach-lookup (global-name \"com.apple.cfprefsd.daemon\"))",
            "(deny mach-lookup (global-name \"com.apple.cfprefsd.agent\"))",
            "(deny mach-lookup (global-name \"com.apple.pasteboard.1\"))",
            "(deny mach-lookup (global-name \"com.apple.windowserver.active\"))",
            "(deny mach-lookup (global-name \"com.apple.CARenderServer\"))",
        ] {
            try expect(profile.contains(requiredRule), "The external-engine sandbox is missing \(requiredRule)")
        }
        try expect(result.status == 0, "The engine sandbox did not allow only declared private stages (status \(result.status)): \(result.stdout)\n\(result.stderr)\n\(profile)")
        try expect(try String(contentsOf: output, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines) == "scoped-output",
                   "The sandbox could not write inside the approved output stage")
        try expect(!FileManager.default.fileExists(atPath: outsideWrite.path), "The sandbox wrote outside its approved staging directories")
        try expect(!FileManager.default.fileExists(atPath: hardLink.path), "The sandbox hard-linked a home file into its output stage")
        try expect(!FileManager.default.fileExists(atPath: clone.path), "The sandbox cloned a home file into its output stage")

        let launchctl = URL(fileURLWithPath: "/bin/launchctl")
        guard FileManager.default.isExecutableFile(atPath: launchctl.path) else { throw CheckSkip("launchctl is unavailable") }
        let label = "com.lakshaychawla.morph-check-\(UUID().uuidString.lowercased())"
        let submittedMarker = folder.appendingPathComponent("launchd-job-ran")
        let submission = try ProcessRunner.run(
            executable: launchctl,
            arguments: ["submit", "-l", label, "--", "/usr/bin/touch", submittedMarker.path],
            timeout: 10,
            restrictedSandbox: true
        )
        if submission.status == 0 {
            _ = try? ProcessRunner.run(executable: launchctl, arguments: ["remove", label], timeout: 10)
        }
        try expect(submission.status != 0, "The sandbox allowed a conversion engine to submit a launchd job")
        try expect(!FileManager.default.fileExists(atPath: submittedMarker.path), "A launchd job escaped the engine sandbox")
    }

    private func checkHardLinkedOutputRejection(_ folder: URL) throws {
        let sourceStage = try PrivateOutputStage(parentDirectory: folder, primaryFileName: "engine-output.txt")
        let destinationStage = try PrivateOutputStage(parentDirectory: folder, primaryFileName: "published-copy.txt")
        let output = try sourceStage.temporaryOutputURL()
        try Data("engine output".utf8).write(to: output)
        let secondName = "second-link.txt"
        let secondLink = sourceStage.fileURL(named: secondName)
        let linkStatus = output.path.withCString { source in
            secondLink.path.withCString { destination in Darwin.link(source, destination) }
        }
        guard linkStatus == 0 else { throw CheckFailure("Could not create the private hard-link regression fixture: \(errno)") }
        defer { _ = secondLink.path.withCString { Darwin.unlink($0) } }

        try expect(!sourceStage.stagedFileStillMatchesPath(named: output.lastPathComponent, url: output),
                   "The stage accepted an engine output inode with more than one hard link")
        do {
            try destinationStage.copyValidatedFile(
                named: output.lastPathComponent,
                from: sourceStage,
                to: "published-copy.txt",
                for: destinationStage.fileURL(named: "published-copy.txt"),
                cancellation: CancellationToken()
            )
            throw CheckFailure("Morph copied a hard-linked engine output into the user output stage")
        } catch is CheckFailure {
            throw CheckFailure("Morph copied a hard-linked engine output into the user output stage")
        } catch { }
        try expect(!FileManager.default.fileExists(atPath: destinationStage.fileURL(named: "published-copy.txt").path),
                   "Rejecting a hard-linked output left a published copy")
    }

    private func checkLocationMetadataPolicy() throws {
        let iptc: [CFString: Any] = [
            kCGImagePropertyIPTCCity: "Sensitive city",
            kCGImagePropertyIPTCSubLocation: "Sensitive neighborhood",
            kCGImagePropertyIPTCProvinceState: "Sensitive state",
            kCGImagePropertyIPTCCountryPrimaryLocationName: "Sensitive country",
            kCGImagePropertyIPTCHeadline: "Keep this editorial headline",
        ]
        let properties: [CFString: Any] = [kCGImagePropertyIPTCDictionary: iptc]
        let stripped = NativeImageEngine.properties(preservingLocationMetadata: false, from: properties)
        let strippedIPTC = stripped[kCGImagePropertyIPTCDictionary] as? [CFString: Any]
        for key in [
            kCGImagePropertyIPTCCity,
            kCGImagePropertyIPTCSubLocation,
            kCGImagePropertyIPTCProvinceState,
            kCGImagePropertyIPTCCountryPrimaryLocationName,
        ] {
            try expect(strippedIPTC?[key] == nil, "ImageIO retained IPTC location key \(key)")
        }
        try expect(strippedIPTC?[kCGImagePropertyIPTCHeadline] as? String == "Keep this editorial headline", "Location stripping removed unrelated IPTC metadata")
        let preserved = NativeImageEngine.properties(preservingLocationMetadata: true, from: properties)
        let preservedIPTC = preserved[kCGImagePropertyIPTCDictionary] as? [CFString: Any]
        try expect(preservedIPTC?[kCGImagePropertyIPTCCity] as? String == "Sensitive city", "The opt-out failed to preserve IPTC location metadata")

        for tag in ["com.apple.quicktime.location.name", "com.apple.quicktime.location.body", "com.apple.quicktime.location.note"] {
            try expect(MediaMetadataPolicy.ffmpegLocationRemovalArguments.contains("\(tag)="), "FFmpeg location stripping omitted QuickTime tag \(tag)")
            try expect(MediaMetadataPolicy.ffmpegLocationRemovalArguments.filter { $0 == "\(tag)=" }.count == 2, "FFmpeg must strip QuickTime tag \(tag) from both container and stream metadata")
        }
    }

    private func checkFileQuarantineConfiguration() throws {
        let bundleInfoFiles = ["Resources/Info.plist", "Resources/MorphQuickConvert-Info.plist"]
        let supportPathExclusion = "~/Library/Application Support/Morph/*"
        for path in bundleInfoFiles {
            let url = URL(fileURLWithPath: path, relativeTo: URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true))
            let data = try Data(contentsOf: url)
            guard let info = try PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any] else {
                throw CheckFailure("\(path) is not a property list dictionary")
            }
            try expect(info["LSFileQuarantineEnabled"] as? Bool == true, "\(path) must enable Launch Services quarantine for generated files")
            let exclusions = info["LSFileQuarantineExcludedPathPatterns"] as? [String] ?? []
            try expect(exclusions.contains(supportPathExclusion), "\(path) should keep Morph's private support data out of quarantine")
        }
    }

    private func checkConversionHistory(_ folder: URL) throws {
        let historyURL = folder.appendingPathComponent("history.json")
        let failure = LockedOutcome()
        DispatchQueue.concurrentPerform(iterations: 24) { index in
            let entry = ConversionHistoryEntry(
                inputName: "input-\(index).png",
                outputPath: "/tmp/output-\(index).jpg",
                engineName: "Apple ImageIO",
                date: Date().addingTimeInterval(Double(index))
            )
            do {
                _ = try ConversionHistoryStore.merge([entry], into: historyURL)
            } catch {
                failure.set(error.localizedDescription)
            }
        }
        try expect(failure.value == nil, "Concurrent history update failed: \(failure.value ?? "unknown error")")
        let merged = try ConversionHistoryStore.load(from: historyURL)
        try expect(merged.count == 24 && Set(merged.map(\.id)).count == 24, "Concurrent app/helper history writes lost entries")
        _ = try ConversionHistoryStore.merge([merged[0]], into: historyURL)
        try expect(try ConversionHistoryStore.load(from: historyURL).count == 24, "History merge duplicated an existing entry")
        let attributes = try FileManager.default.attributesOfItem(atPath: historyURL.path)
        try expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600, "History file permissions are not private")
        try ConversionHistoryStore.clear(from: historyURL)
        try expect(try ConversionHistoryStore.load(from: historyURL).isEmpty, "Clearing history left file names or output paths in storage")
        let clearedAttributes = try FileManager.default.attributesOfItem(atPath: historyURL.path)
        try expect((clearedAttributes[.posixPermissions] as? NSNumber)?.intValue == 0o600, "Clearing history did not preserve private file permissions")

        let clearedHistoryURL = folder.appendingPathComponent("deleted-history.json")
        let cachedEntry = ConversionHistoryEntry(inputName: "cached.png", outputPath: "/tmp/cached.jpg", engineName: "Apple ImageIO", date: Date())
        _ = try ConversionHistoryStore.merge([cachedEntry], into: clearedHistoryURL)
        try FileManager.default.removeItem(at: clearedHistoryURL)
        let newEntry = ConversionHistoryEntry(inputName: "new.png", outputPath: "/tmp/new.jpg", engineName: "Apple ImageIO", date: Date())
        _ = try ConversionHistoryStore.merge([newEntry], into: clearedHistoryURL)
        let afterDeletion = try ConversionHistoryStore.load(from: clearedHistoryURL)
        try expect(afterDeletion.map(\.id) == [newEntry.id], "Appending new history after clearing restored cached entries")

        let target = folder.appendingPathComponent("history-target.json")
        try "preserve target".write(to: target, atomically: true, encoding: .utf8)
        let targetHash = try sha256(target)
        let symlink = folder.appendingPathComponent("history-link.json")
        try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: target)
        do {
            _ = try ConversionHistoryStore.merge([merged[0]], into: symlink)
            throw CheckFailure("History store followed a symbolic link")
        } catch is CheckFailure {
            throw CheckFailure("History store followed a symbolic link")
        } catch { }
        try expect(try sha256(target) == targetHash, "Rejected history symlink modified its target")

        let symlinkRoot = folder.appendingPathComponent("symlink-root", isDirectory: true)
        let realRoot = folder.appendingPathComponent("real-root", isDirectory: true)
        try FileManager.default.createDirectory(at: realRoot.appendingPathComponent("nested", isDirectory: true), withIntermediateDirectories: true)
        try "contained".write(to: realRoot.appendingPathComponent("nested/item.txt"), atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(at: symlinkRoot, withDestinationURL: realRoot)
        try ArchiveEngine.ensureExtractedItemsStayInside(symlinkRoot)
    }

    private func checkHistoryFIFO(_ folder: URL) throws {
        let fifo = folder.appendingPathComponent("history.fifo")
        guard mkfifo(fifo.path, mode_t(0o600)) == 0 else {
            throw CheckFailure("Could not create a FIFO history fixture: \(String(cString: strerror(errno)))")
        }
        let result = try ProcessRunner.run(
            executable: URL(fileURLWithPath: CommandLine.arguments[0]),
            arguments: ["--check-history-fifo", fifo.path],
            timeout: 3
        )
        try expect(result.status == 0, "Reading a FIFO as conversion history blocked or returned the wrong error: \(result.stderr)")
    }

    private func checkRenamedOutputFolder(_ folder: URL) throws {
        let selected = folder.appendingPathComponent("selected-output", isDirectory: true)
        let moved = folder.appendingPathComponent("selected-output-renamed", isDirectory: true)
        try FileManager.default.createDirectory(at: selected, withIntermediateDirectories: true)
        let resultURL = selected.appendingPathComponent("result.txt")
        do {
            let stage = try PrivateOutputStage(outputURL: resultURL)
            try Data("complete output".utf8).write(to: stage.temporaryOutputURL())
            try FileManager.default.moveItem(at: selected, to: moved)
            do {
                try stage.publishPrimary(to: resultURL)
                throw CheckFailure("Publishing to a renamed output folder returned a dead result path")
            } catch let error as MorphError {
                guard case .invalidOutput(let detail) = error,
                      detail.contains("folder moved") else {
                    throw CheckFailure("A renamed output folder returned the wrong error: \(error.localizedDescription)")
                }
            }
        }
        try expect(try FileManager.default.contentsOfDirectory(atPath: moved.path).isEmpty, "The moved output folder retained an unpublished result or staging directory")
    }

    private func checkConversionRejectsMovedOutputFolder(_ folder: URL) throws {
        let input = folder.appendingPathComponent("moving-output.png")
        try makePNG(at: input, width: 24, height: 18)
        let output = folder.appendingPathComponent("selected-output", isDirectory: true)
        let moved = folder.appendingPathComponent("selected-output-moved", isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

        let route = ConversionRoute(
            inputExtension: "png",
            output: MorphFormat("jpg", "JPEG", .image),
            engine: .nativeImage,
            description: "Test output-folder move"
        )
        let registry = EngineRegistry(
            statuses: [.nativeImage: EngineStatus(id: .nativeImage, supportedInputExtensions: ["png"], supportedOutputExtensions: ["jpg"])],
            routes: [route]
        )
        let service = ConversionService(
            registry: registry,
            engines: [OutputFolderMovingEngine(selectedOutput: output, movedOutput: moved)]
        )
        do {
            _ = try service.convert(ConversionRequest(inputURL: input, outputFormat: route.output, outputDirectory: output))
            throw CheckFailure("Conversion reported success after its output folder moved")
        } catch is CheckFailure {
            throw CheckFailure("Conversion reported success after its output folder moved")
        } catch MorphError.invalidOutput(let detail) {
            try expect(detail.localizedCaseInsensitiveContains("moved"), "A moved output folder returned an unclear error")
        }

        try expect(try FileManager.default.contentsOfDirectory(atPath: output.path).isEmpty, "Conversion wrote into the replacement output folder")
        try expect(try FileManager.default.contentsOfDirectory(atPath: moved.path).isEmpty, "Conversion left staging or output files in the moved folder")
    }

    private func checkProcessRunnerSafety(_ folder: URL) throws {
        let environment = try ProcessRunner.run(executable: URL(fileURLWithPath: "/usr/bin/env"), arguments: [])
        let childEnvironment = Set(environment.stdout.split(whereSeparator: \.isNewline).map(String.init))
        let expectedEnvironment: Set<String> = [
            "HOME=\(NSHomeDirectory())",
            "LC_ALL=en_US.UTF-8",
            "PATH=\(ExecutableLocator.engineSearchPath)",
            "TMPDIR=\(FileManager.default.temporaryDirectory.path)",
        ]
        try expect(childEnvironment == expectedEnvironment, "Conversion tools inherited environment variables beyond Morph's minimal allowlist")

        let inheritedFile = folder.appendingPathComponent("must-not-inherit.txt")
        try "private parent descriptor".write(to: inheritedFile, atomically: true, encoding: .utf8)
        let inheritedDescriptor = inheritedFile.path.withCString { open($0, O_RDONLY) }
        guard inheritedDescriptor >= 0 else { throw CheckFailure("Could not open the inherited-descriptor fixture") }
        defer { close(inheritedDescriptor) }
        let descriptorProbe = try ProcessRunner.run(
            executable: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "[ ! -e /dev/fd/$1 ]", "--", String(inheritedDescriptor)]
        )
        try expect(descriptorProbe.status == 0, "A conversion subprocess inherited an unrelated open file descriptor")

        var blockedSignals = sigset_t()
        var previousSignals = sigset_t()
        guard sigemptyset(&blockedSignals) == 0,
              sigaddset(&blockedSignals, SIGTERM) == 0,
              pthread_sigmask(SIG_BLOCK, &blockedSignals, &previousSignals) == 0 else {
            throw CheckFailure("Could not prepare the blocked-signal inheritance fixture")
        }
        defer { _ = pthread_sigmask(SIG_SETMASK, &previousSignals, nil) }
        let signalMaskProbe = try ProcessRunner.run(
            executable: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "kill -TERM $$; echo survived"]
        )
        try expect(signalMaskProbe.status != 0 && !signalMaskProbe.stdout.contains("survived"), "A child inherited a blocked SIGTERM mask from its worker thread")

        let bounded = try ProcessRunner.run(
            executable: URL(fileURLWithPath: "/usr/bin/head"),
            arguments: ["-c", "1200000", "/dev/zero"],
            maximumOutputBytes: 4_096
        )
        try expect(bounded.status == 0 && bounded.stdout.utf8.count == 4_096 && bounded.stdoutWasTruncated, "Process output was not bounded and marked as truncated")

        if let python = ExecutableLocator.resolve(["python3"]) {
            let generatedFile = folder.appendingPathComponent("limited-generated-output.bin")
            let writer = "import sys,time\nf=open(sys.argv[1], 'wb', buffering=0)\nwhile True:\n f.write(b'x' * 65536)\n time.sleep(0.01)"
            do {
                _ = try ProcessRunner.run(
                    executable: python,
                    arguments: ["-c", writer, generatedFile.path],
                    timeout: 5,
                    outputFileLimit: ProcessOutputFileLimit(url: generatedFile, maximumBytes: 128 * 1024)
                )
                throw CheckFailure("A subprocess exceeded its generated-file size limit")
            } catch is CheckFailure {
                throw CheckFailure("A subprocess exceeded its generated-file size limit")
            } catch MorphError.invalidOutput {
                let size = try FileManager.default.attributesOfItem(atPath: generatedFile.path)[.size] as? NSNumber
                try expect((size?.uint64Value ?? UInt64.max) <= 1024 * 1024, "The generated-file monitor allowed excessive output after crossing its cap")
            }

            let sentinel = folder.appendingPathComponent("must-not-follow-output-symlink.txt")
            let linkedOutput = folder.appendingPathComponent("preexisting-output-link")
            try "unchanged".write(to: sentinel, atomically: true, encoding: .utf8)
            try FileManager.default.createSymbolicLink(at: linkedOutput, withDestinationURL: sentinel)
            do {
                _ = try ProcessRunner.run(
                    executable: python,
                    arguments: ["-c", "import sys; open(sys.argv[1], 'wb').write(b'changed')", linkedOutput.path],
                    outputFileLimit: ProcessOutputFileLimit(url: linkedOutput, maximumBytes: 1024)
                )
                throw CheckFailure("A conversion subprocess was allowed to start with a symlink output path")
            } catch MorphError.invalidOutput {
                let contents = try String(contentsOf: sentinel, encoding: .utf8)
                try expect(contents == "unchanged", "A conversion followed a pre-existing output symlink")
            }
        }

        do {
            _ = try ProcessRunner.run(
                executable: URL(fileURLWithPath: "/bin/sleep"),
                arguments: ["10"],
                timeout: 0.1
            )
            throw CheckFailure("A timed-out child process was allowed to finish")
        } catch let failure as CheckFailure {
            throw failure
        } catch let error as MorphError {
            guard case .processFailed = error else { throw CheckFailure("Timeout returned the wrong process error: \(error.localizedDescription)") }
        }

        let pidFile = folder.appendingPathComponent("child.pid")
        let token = CancellationToken()
        let finished = DispatchSemaphore(value: 0)
        let outcome = LockedOutcome()
        let command = "(trap '' TERM; exec >/dev/null 2>&1; /bin/sleep 30) & echo $! > \(pidFile.path); wait"
        DispatchQueue.global().async {
            do {
                _ = try ProcessRunner.run(executable: URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", command], cancellation: token)
                outcome.set("unexpected success")
            } catch {
                outcome.set(error.localizedDescription)
            }
            finished.signal()
        }
        var childPID: pid_t?
        for _ in 0..<100 {
            if let text = try? String(contentsOf: pidFile, encoding: .utf8), let number = Int32(text.trimmingCharacters(in: .whitespacesAndNewlines)) {
                childPID = pid_t(number)
                break
            }
            Thread.sleep(forTimeInterval: 0.02)
        }
        guard let childPID else { token.cancel(); throw CheckFailure("The child process fixture did not start") }
        token.cancel()
        try expect(finished.wait(timeout: .now() + 4) == .success, "Cancellation did not stop the complete process group")
        try expect(outcome.value == MorphError.cancelled.localizedDescription, "Process-group cancellation returned an unexpected result")
        var childStopped = false
        for _ in 0..<50 {
            if kill(childPID, 0) == -1 && errno == ESRCH { childStopped = true; break }
            Thread.sleep(forTimeInterval: 0.02)
        }
        try expect(childStopped, "Cancelling Morph left a TERM-ignoring child running after its leader exited")

        let detachedMarker = folder.appendingPathComponent("detached-child-ran")
        _ = try ProcessRunner.run(
            executable: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "( /bin/sleep 0.8; /usr/bin/touch \"$1\" ) </dev/null >/dev/null 2>&1 & exit 0", "--", detachedMarker.path]
        )
        Thread.sleep(forTimeInterval: 1.0)
        try expect(!FileManager.default.fileExists(atPath: detachedMarker.path), "A successful process leader left its detached child running")

        if let perl = ExecutableLocator.resolve(["perl"]) {
            let escapedPIDFile = folder.appendingPathComponent("escaped-process-group.pid")
            let escapedCommand = "\"\(perl.path)\" -MPOSIX=setsid -e 'setsid(); open my $f, \">\", $ARGV[0] or die; print {$f} $$; close $f; sleep 30' \"$1\" & attempt=0; while [ ! -s \"$1\" ] && [ \"$attempt\" -lt 100 ]; do /bin/sleep 0.01; attempt=$((attempt + 1)); done; [ -s \"$1\" ] || exit 4; exit 0"
            let readerStopStarted = Date()
            let escapedResult = try ProcessRunner.run(
                executable: URL(fileURLWithPath: "/bin/sh"),
                arguments: ["-c", escapedCommand, "--", escapedPIDFile.path]
            )
            try expect(escapedResult.status == 0, "Could not exercise the reader-stop path with a child holding inherited pipes")
            try expect(Date().timeIntervalSince(readerStopStarted) < 4, "Reader shutdown waited indefinitely for an escaped descendant to close its pipes")
            if let pidText = try? String(contentsOf: escapedPIDFile, encoding: .utf8),
               let escapedPID = Int32(pidText.trimmingCharacters(in: .whitespacesAndNewlines)) {
                let killResult = kill(pid_t(escapedPID), SIGKILL)
                try expect(killResult == 0 || errno == ESRCH, "Could not clean up the escaped reader-test process")
            } else {
                throw CheckFailure("The escaped reader-test process did not report its PID")
            }
        }

        let uniqueExecutableName = "morph-untrusted-path-\(UUID().uuidString)"
        let fakeDirectory = folder.appendingPathComponent("untrusted-bin", isDirectory: true)
        try FileManager.default.createDirectory(at: fakeDirectory, withIntermediateDirectories: true)
        let fakeExecutable = fakeDirectory.appendingPathComponent(uniqueExecutableName)
        try "#!/bin/sh\nexit 0\n".write(to: fakeExecutable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fakeExecutable.path)
        let previousPath = getenv("PATH").map { String(cString: $0) }
        _ = setenv("PATH", fakeDirectory.path, 1)
        defer {
            if let previousPath { _ = setenv("PATH", previousPath, 1) }
            else { _ = unsetenv("PATH") }
        }
        try expect(ExecutableLocator.resolve([uniqueExecutableName]) == nil, "Executable discovery trusted a binary supplied only through PATH")
    }

    private func checkEngineTrustGate(_ folder: URL) throws {
        let marker = folder.appendingPathComponent("unapproved-engine-ran")
        let executable = folder.appendingPathComponent("unapproved-ffmpeg")
        try "#!/bin/sh\n/usr/bin/touch '\(marker.path)'\necho 'ffmpeg version 9.0.2'\n".write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)

        #if DEBUG
        EngineExecutableTrust.setTestingApprovalOverride { _, _ in false }
        defer { EngineExecutableTrust.setTestingApprovalOverride { _, _ in true } }
        #else
        throw CheckSkip("Executable approval injection is only available in debug checks")
        #endif

        do {
            try EngineSecurityPolicy.validateExecutable(executable, for: .ffmpeg)
            throw CheckFailure("Morph accepted an unapproved external executable")
        } catch is CheckFailure {
            throw CheckFailure("Morph accepted an unapproved external executable")
        } catch MorphError.processFailed(let detail) {
            try expect(detail.localizedCaseInsensitiveContains("not approved"), "An unapproved executable returned an unclear failure")
        }
        try expect(!FileManager.default.fileExists(atPath: marker.path), "Morph ran an external executable before approval")
    }

    private func checkEngineTrustRejectsWritableACL(_ folder: URL) throws {
        let trustedFixtureDirectory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
            .appendingPathComponent(".build/MorphChecks-engine-trust-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: trustedFixtureDirectory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let chmodTool = URL(fileURLWithPath: "/bin/chmod")
        defer {
            _ = try? ProcessRunner.run(executable: chmodTool, arguments: ["-N", trustedFixtureDirectory.path])
            try? FileManager.default.removeItem(at: trustedFixtureDirectory)
        }
        let executable = trustedFixtureDirectory.appendingPathComponent("acl-writable-engine")
        try "#!/bin/sh\nexit 0\n".write(to: executable, atomically: true, encoding: .utf8)
        guard chmod(executable.path, mode_t(0o700)) == 0 else {
            throw CheckFailure("Could not protect the engine trust fixture")
        }
        _ = try EngineExecutableTrust.fingerprint(for: executable)
        let owner = try EngineExecutableTrust.ownerSummary(for: executable)
        try expect(owner.contains("UID "), "Engine approval details did not expose the executable owner")

        let acl = try ProcessRunner.run(
            executable: chmodTool,
            arguments: ["+a", "everyone allow write", executable.path]
        )
        try expect(acl.status == 0, "Could not create a writable executable ACL fixture: \(acl.stderr)")
        let descriptor = executable.path.withCString { open($0, O_RDONLY | O_CLOEXEC | O_NOFOLLOW) }
        guard descriptor >= 0 else { throw CheckFailure("Could not open the executable ACL fixture") }
        defer { close(descriptor) }
        try expect(morph_acl_has_write_grant(descriptor) == 1, "The ACL inspector did not detect the writable executable ACL")
        do {
            _ = try EngineExecutableTrust.fingerprint(for: executable)
            throw CheckFailure("Engine trust accepted an executable ACL that grants write access")
        } catch is CheckFailure {
            throw CheckFailure("Engine trust accepted an executable ACL that grants write access")
        } catch { }

        let resetExecutableACL = try ProcessRunner.run(executable: chmodTool, arguments: ["-N", executable.path])
        try expect(resetExecutableACL.status == 0, "Could not clear the executable ACL fixture: \(resetExecutableACL.stderr)")
        let parentACL = try ProcessRunner.run(
            executable: chmodTool,
            arguments: ["+a", "everyone allow add_file,delete_child", trustedFixtureDirectory.path]
        )
        try expect(parentACL.status == 0, "Could not create a writable parent-directory ACL fixture: \(parentACL.stderr)")
        let parentDescriptor = trustedFixtureDirectory.path.withCString {
            open($0, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        }
        guard parentDescriptor >= 0 else { throw CheckFailure("Could not open the engine parent ACL fixture") }
        defer { close(parentDescriptor) }
        try expect(morph_acl_has_write_grant(parentDescriptor) == 1, "The ACL inspector did not detect the writable parent-directory ACL")
        do {
            _ = try EngineExecutableTrust.fingerprint(for: executable)
            throw CheckFailure("Engine trust accepted a parent ACL that grants write access")
        } catch is CheckFailure {
            throw CheckFailure("Engine trust accepted a parent ACL that grants write access")
        } catch { }

        try setACL("everyone allow read", on: executable, using: chmodTool)
        try expectACLInspection(of: executable, expected: "0", message: "Read-only executable ACE")
        try setACL("everyone allow write,only_inherit", on: trustedFixtureDirectory, using: chmodTool)
        try expectACLInspection(of: trustedFixtureDirectory, expected: "0", message: "Inherit-only parent ACE")
    }

    private func setACL(_ entry: String, on url: URL, using chmod: URL) throws {
        _ = try ProcessRunner.run(executable: chmod, arguments: ["-N", url.path])
        let result = try ProcessRunner.run(executable: chmod, arguments: ["+a", entry, url.path])
        try expect(result.status == 0, "Could not create ACL fixture '\(entry)': \(result.stderr)")
    }

    private func expectACLInspection(of url: URL, expected: String, message: String) throws {
        let result = try ProcessRunner.run(
            executable: URL(fileURLWithPath: CommandLine.arguments[0]),
            arguments: ["--inspect-acl-write-grant", url.path],
            timeout: 3
        )
        try expect(result.status == 0, "\(message) ACL inspection did not terminate successfully: \(result.stderr)")
        try expect(result.stdout.trimmingCharacters(in: .whitespacesAndNewlines) == expected,
                   "\(message) ACL inspection returned \(result.stdout.debugDescription), expected \(expected)")
    }

    private func checkProtectedHomebrewPaths() throws {
        let candidates = ["/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg"]
        guard let executable = candidates.map({ URL(fileURLWithPath: $0) }).first(where: {
            FileManager.default.isExecutableFile(atPath: $0.path)
        }) else { throw CheckSkip("No Homebrew FFmpeg installation is available") }
        _ = try EngineExecutableTrust.fingerprint(for: executable)
    }

    private func checkCancellationReapRace() throws {
        let group: pid_t = 42_424
        let events = LockedEventLog()
        let signalEntered = DispatchSemaphore(value: 0)
        let releaseSignal = DispatchSemaphore(value: 0)
        let cancellationStarted = DispatchSemaphore(value: 0)
        let cancellationFinished = DispatchSemaphore(value: 0)
        let reapFinished = DispatchSemaphore(value: 0)
        defer { releaseSignal.signal() }

        let token = CancellationToken(
            signalProcessGroup: { processGroup, signal in
                events.append("signal:\(processGroup):\(signal)")
                signalEntered.signal()
                _ = releaseSignal.wait(timeout: .now() + 5)
            },
            waitForProcess: { process, _, _ in
                events.append("reaped:\(process)")
                return process
            }
        )
        try token.attach(processGroup: group)
        DispatchQueue.global().async {
            var status: Int32 = 0
            _ = token.terminateAndReap(processGroup: group, processStatus: &status)
            reapFinished.signal()
        }
        try expect(signalEntered.wait(timeout: .now() + 2) == .success, "Process termination did not enter its synchronized signal section")
        DispatchQueue.global().async {
            cancellationStarted.signal()
            token.cancel()
            cancellationFinished.signal()
        }
        try expect(cancellationStarted.wait(timeout: .now() + 2) == .success, "The concurrent cancellation did not start")
        releaseSignal.signal()
        try expect(reapFinished.wait(timeout: .now() + 2) == .success, "The process-group completion did not finish")
        try expect(cancellationFinished.wait(timeout: .now() + 2) == .success, "The concurrent cancellation did not finish")
        try expect(events.values == ["signal:\(group):\(SIGKILL)", "reaped:\(group)"], "Cancellation signaled the process group after it had been reaped: \(events.values)")
    }

    private func checkImagesAndPDF(_ folder: URL) throws {
        let png = folder.appendingPathComponent("portrait.png")
        try makePNG(at: png, width: 48, height: 32)
        let originalHash = try sha256(png)
        let output = folder.appendingPathComponent("output", isDirectory: true)

        let cancelledImage = output.appendingPathComponent("cancelled.jpg")
        let cancelledImageToken = CancellationToken()
        cancelledImageToken.cancel()
        do {
            try NativeImageEngine.convert(input: png, output: cancelledImage, quality: 0.9, cancellation: cancelledImageToken)
            throw CheckFailure("ImageIO ignored cancellation before decoding")
        } catch MorphError.cancelled { }
        try expect(!FileManager.default.fileExists(atPath: cancelledImage.path), "Cancelled ImageIO conversion left output behind")

        let cancelledPDF = output.appendingPathComponent("cancelled.pdf")
        do {
            try NativePDFEngine.imageToPDF(input: png, output: cancelledPDF, cancellation: cancelledImageToken)
            throw CheckFailure("PDFKit image-to-PDF ignored cancellation before decoding")
        } catch MorphError.cancelled { }
        try expect(!FileManager.default.fileExists(atPath: cancelledPDF.path), "Cancelled PDFKit conversion left output behind")

        let jpeg = try convert(png, to: "jpg", category: .image, output: output)
        let jpegAttributes = try FileManager.default.attributesOfItem(atPath: jpeg.path)
        try expect((jpegAttributes[.posixPermissions] as? NSNumber)?.intValue == 0o600, "Published image output should retain Morph's private 0600 mode")
        guard let jpegSource = CGImageSourceCreateWithURL(jpeg as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(jpegSource, 0, nil) as? [CFString: Any] else {
            throw CheckFailure("JPEG did not decode")
        }
        try expect((properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue == 48, "JPEG width changed")
        try expect((properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue == 32, "JPEG height changed")

        let tiff = try convert(jpeg, to: "tiff", category: .image, output: output)
        try expect(CGImageSourceCreateWithURL(tiff as CFURL, nil) != nil, "TIFF did not decode")
        let pdf = try convert(png, to: "pdf", category: .document, output: output)
        try expect(PDFDocument(url: pdf)?.pageCount == 1, "Image PDF should contain one page")

        let locationImage = folder.appendingPathComponent("location.jpg")
        let jpegType = UTType.jpeg.identifier as CFString
        guard let source = CGImageSourceCreateWithURL(png as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
              let destination = CGImageDestinationCreateWithURL(locationImage as CFURL, jpegType, 1, nil) else {
            throw CheckFailure("Could not create the GPS metadata image fixture")
        }
        let locationProperties: [CFString: Any] = [
            kCGImagePropertyGPSDictionary: [
                kCGImagePropertyGPSLatitude: 37.3861,
                kCGImagePropertyGPSLatitudeRef: "N",
                kCGImagePropertyGPSLongitude: 122.0839,
                kCGImagePropertyGPSLongitudeRef: "W",
                kCGImagePropertyGPSProcessingMethod: "MORPH_LOCATION_CANARY_7C98E1",
            ] as [CFString: Any],
            kCGImagePropertyExifDictionary: [
                kCGImagePropertyExifUserComment: "Keep this non-location note",
            ] as [CFString: Any],
            kCGImagePropertyIPTCDictionary: [
                kCGImagePropertyIPTCCity: "MORPH_LOCATION_CANARY_7C98E1",
                kCGImagePropertyIPTCSubLocation: "Sensitive neighborhood",
                kCGImagePropertyIPTCExtLocationGPSLatitude: 37.3861,
                kCGImagePropertyIPTCHeadline: "Keep this editorial headline",
            ] as [CFString: Any],
        ]
        CGImageDestinationAddImage(destination, image, locationProperties as CFDictionary)
        try expect(CGImageDestinationFinalize(destination), "Could not finalize the GPS metadata image fixture")
        let canary = Data("MORPH_LOCATION_CANARY_7C98E1".utf8)
        let locationJPEGBytes = try Data(contentsOf: locationImage)
        try expect(locationJPEGBytes.range(of: canary) != nil,
                   "The JPEG metadata fixture did not serialize its location canary")
        let locationPDF = try convert(locationImage, to: "pdf", category: .document, output: output)
        let locationPDFBytes = try Data(contentsOf: locationPDF)
        try expect(locationPDFBytes.range(of: canary) == nil,
                   "Image-to-PDF conversion copied a location metadata canary into the PDF")
        if let pdfDocument = PDFDocument(url: locationPDF) {
            let metadataText = (pdfDocument.documentAttributes ?? [:]).values
                .map { String(describing: $0) }.joined(separator: " ")
            try expect(!metadataText.contains("MORPH_LOCATION_CANARY_7C98E1"),
                       "Image-to-PDF conversion copied location metadata into PDF document attributes")
        }
        let locationOutput = try convert(locationImage, to: "tiff", category: .image, output: output)
        guard let locationOutputSource = CGImageSourceCreateWithURL(locationOutput as CFURL, nil),
              let locationOutputProperties = CGImageSourceCopyPropertiesAtIndex(locationOutputSource, 0, nil) as? [CFString: Any] else {
            throw CheckFailure("The converted GPS metadata image could not be inspected")
        }
        try expect(locationOutputProperties[kCGImagePropertyGPSDictionary] == nil, "Image conversion retained GPS coordinates by default")
        let outputExif = locationOutputProperties[kCGImagePropertyExifDictionary] as? [CFString: Any]
        try expect(outputExif?[kCGImagePropertyExifUserComment] as? String == "Keep this non-location note", "Image conversion discarded non-location EXIF metadata")
        let outputIPTC = locationOutputProperties[kCGImagePropertyIPTCDictionary] as? [CFString: Any]
        try expect(outputIPTC?[kCGImagePropertyIPTCCity] == nil, "Image conversion retained IPTC city metadata by default")
        try expect(outputIPTC?[kCGImagePropertyIPTCSubLocation] == nil, "Image conversion retained IPTC sub-location metadata by default")
        try expect(outputIPTC?[kCGImagePropertyIPTCExtLocationGPSLatitude] == nil, "Image conversion retained IPTC extended GPS metadata by default")
        try expect(outputIPTC?[kCGImagePropertyIPTCHeadline] as? String == "Keep this editorial headline", "Image conversion discarded unrelated IPTC metadata")

        let locationKeptDirectory = folder.appendingPathComponent("location-kept", isDirectory: true)
        let locationKept = try convert(
            locationImage,
            to: "tiff",
            category: .image,
            output: locationKeptDirectory,
            stripLocationMetadata: false
        )
        let locationKeptSource = CGImageSourceCreateWithURL(locationKept as CFURL, nil)
        let locationKeptProperties = locationKeptSource.flatMap { CGImageSourceCopyPropertiesAtIndex($0, 0, nil) as? [CFString: Any] }
        try expect(locationKeptProperties?[kCGImagePropertyGPSDictionary] != nil, "Disabling location-metadata removal did not preserve GPS metadata")
        let keptIPTC = locationKeptProperties?[kCGImagePropertyIPTCDictionary] as? [CFString: Any]
        try expect(keptIPTC?[kCGImagePropertyIPTCCity] as? String == "MORPH_LOCATION_CANARY_7C98E1", "Disabling location-metadata removal did not preserve IPTC metadata")

        let mislabeledJPEG = folder.appendingPathComponent("png-content.jpg")
        try FileManager.default.copyItem(at: png, to: mislabeledJPEG)
        do {
            try NativeImageEngine.validateInput(mislabeledJPEG)
            throw CheckFailure("Image validation accepted PNG content with a JPEG extension")
        } catch is CheckFailure {
            throw CheckFailure("Image validation accepted PNG content with a JPEG extension")
        } catch { }
        do {
            _ = try MorphFileOperations.inspectMetadata(mislabeledJPEG)
            throw CheckFailure("Metadata inspection parsed an image whose contents do not match its extension")
        } catch is CheckFailure {
            throw CheckFailure("Metadata inspection parsed an image whose contents do not match its extension")
        } catch { }
        do {
            try OutputValidator.validate(
                mislabeledJPEG,
                format: MorphFormat("jpg", "JPEG", .image),
                engine: .nativeImage
            )
            throw CheckFailure("Output validation accepted PNG data under a JPEG extension")
        } catch is CheckFailure {
            throw CheckFailure("Output validation accepted PNG data under a JPEG extension")
        } catch { }

        for unsupportedExtension in ["cr2", "dng", "exr", "ktx", "nef", "psd"] {
            try expect(!registry.routes.contains(where: { $0.engine == .nativeImage && $0.inputExtension == unsupportedExtension }),
                       "ImageIO advertised an unreviewed .\(unsupportedExtension) input route")
        }

        let discoveredImageExtensions = Set(registry.routes
            .filter { $0.inputExtension == "png" && $0.output.category == .image }
            .map(\.output.fileExtension))
        if ExecutableLocator.resolve(["potrace"]) == nil {
            try expect(!discoveredImageExtensions.contains("svg"), "PNG → SVG must not be advertised when ImageMagick's potrace delegate is missing")
        }
        for fileExtension in discoveredImageExtensions.sorted() {
            _ = try convert(png, to: fileExtension, category: .image, output: output)
            print("  PASS  .png → .\(fileExtension) through an available image route")
        }
        try expect(try sha256(png) == originalHash, "Image source changed")

        if let route = registry.routes.first(where: { $0.engine == .imageMagick && $0.inputExtension == "png" && $0.output.fileExtension == "webp" }) {
            let isolatedRegistry = EngineRegistry(statuses: registry.statuses, routes: [route])
            let webpRequest = ConversionRequest(inputURL: png, outputFormat: route.output, outputDirectory: output)
            let webp = try ConversionService(registry: isolatedRegistry).convert(webpRequest)
            try OutputValidator.validate(webp.outputURL, format: route.output, engine: route.engine)
            try expect(try sha256(png) == originalHash, "ImageMagick changed the source image")
            print("  PASS  .png → .webp via ImageMagick")
        }

        if let route = registry.routes.first(where: { $0.engine == .imageMagick && $0.inputExtension == "png" && $0.output.fileExtension == "ico" }) {
            let isolatedRegistry = EngineRegistry(statuses: registry.statuses, routes: [route])
            let iconRequest = ConversionRequest(inputURL: png, outputFormat: route.output, outputDirectory: output)
            let icon = try ConversionService(registry: isolatedRegistry).convert(iconRequest)
            try expect(FileManager.default.fileExists(atPath: icon.outputURL.path), "ICO output is missing")
            try expect(try sha256(png) == originalHash, "ICO conversion changed the source image")
            let leftovers = try FileManager.default.contentsOfDirectory(atPath: output.path)
                .filter { $0.hasPrefix(".morph-") || $0.contains(".partial") }
            try expect(leftovers.isEmpty, "ICO conversion left staging artifacts: \(leftovers)")
            print("  PASS  .png → .ico via ImageMagick")
        }
    }

    private func checkImageMagickLocationRemoval(_ folder: URL) throws {
        guard registry.status(for: .imageMagick)?.canConvert == true else {
            throw CheckSkip("ImageMagick is not installed, approved, or available above Morph's security floor")
        }
        guard let route = registry.routes.first(where: {
            $0.engine == .imageMagick && $0.inputExtension == "jpg" && $0.output.fileExtension == "tiff"
        }) else {
            throw CheckFailure("Approved ImageMagick did not advertise the JPEG-to-TIFF route required for its metadata privacy test")
        }
        let png = folder.appendingPathComponent("pixels.png")
        let jpeg = folder.appendingPathComponent("location.jpg")
        try makePNG(at: png, width: 8, height: 6)
        guard let pngSource = CGImageSourceCreateWithURL(png as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(pngSource, 0, nil),
              let destination = CGImageDestinationCreateWithURL(jpeg as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else {
            throw CheckFailure("Could not create the ImageMagick GPS regression fixture")
        }
        let properties: [CFString: Any] = [
            kCGImagePropertyGPSDictionary: [
                kCGImagePropertyGPSLatitude: 37.3861,
                kCGImagePropertyGPSLatitudeRef: "N",
                kCGImagePropertyGPSLongitude: 122.0839,
                kCGImagePropertyGPSLongitudeRef: "W",
                kCGImagePropertyGPSProcessingMethod: "MORPH_MAGICK_LOCATION_CANARY",
            ] as [CFString: Any],
            kCGImagePropertyIPTCDictionary: [
                kCGImagePropertyIPTCCity: "MORPH_MAGICK_LOCATION_CANARY",
                kCGImagePropertyIPTCHeadline: "Keep this headline",
            ] as [CFString: Any],
        ]
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        try expect(CGImageDestinationFinalize(destination), "Could not finalize the ImageMagick GPS fixture")
        guard let inputSource = CGImageSourceCreateWithURL(jpeg as CFURL, nil),
              let inputProperties = CGImageSourceCopyPropertiesAtIndex(inputSource, 0, nil) as? [CFString: Any],
              inputProperties[kCGImagePropertyGPSDictionary] != nil,
              (inputProperties[kCGImagePropertyIPTCDictionary] as? [CFString: Any])?[kCGImagePropertyIPTCCity] as? String
                == "MORPH_MAGICK_LOCATION_CANARY" else {
            throw CheckFailure("ImageMagick GPS fixture did not contain the expected sensitive metadata")
        }

        let isolatedRegistry = EngineRegistry(statuses: registry.statuses, routes: [route])
        let outputDirectory = folder.appendingPathComponent("output", isDirectory: true)
        let stripped = try ConversionService(registry: isolatedRegistry).convert(
            ConversionRequest(inputURL: jpeg, outputFormat: route.output, outputDirectory: outputDirectory)
        )
        guard let strippedSource = CGImageSourceCreateWithURL(stripped.outputURL as CFURL, nil),
              let strippedProperties = CGImageSourceCopyPropertiesAtIndex(strippedSource, 0, nil) as? [CFString: Any] else {
            throw CheckFailure("ImageMagick's TIFF output metadata could not be inspected")
        }
        try expect(strippedProperties[kCGImagePropertyGPSDictionary] == nil,
                   "ImageMagick TIFF output retained GPS metadata by default")
        let strippedIPTC = strippedProperties[kCGImagePropertyIPTCDictionary] as? [CFString: Any] ?? [:]
        try expect(strippedIPTC[kCGImagePropertyIPTCCity] == nil,
                   "ImageMagick TIFF output retained IPTC location metadata by default")
    }

    private func checkMultiFrameImage(_ folder: URL) throws {
        let firstPNG = folder.appendingPathComponent("first.png")
        let secondPNG = folder.appendingPathComponent("second.png")
        try makePNG(at: firstPNG, width: 20, height: 12)
        var bluePixels = [UInt8](repeating: 0, count: 20 * 12 * 4)
        for index in stride(from: 0, to: bluePixels.count, by: 4) {
            bluePixels[index] = 20
            bluePixels[index + 1] = 80
            bluePixels[index + 2] = 230
            bluePixels[index + 3] = 255
        }
        let blueProvider = try unwrap(CGDataProvider(data: Data(bluePixels) as CFData), "Could not create blue frame data")
        let blueImage = try makeImage(provider: blueProvider, width: 20, height: 12)
        try writeImage(blueImage, to: secondPNG, type: "public.png")

        let tiff = folder.appendingPathComponent("animated.tiff")
        guard let firstSource = CGImageSourceCreateWithURL(firstPNG as CFURL, nil),
              let secondSource = CGImageSourceCreateWithURL(secondPNG as CFURL, nil),
              let firstImage = CGImageSourceCreateImageAtIndex(firstSource, 0, nil),
              let secondImage = CGImageSourceCreateImageAtIndex(secondSource, 0, nil),
              let destination = CGImageDestinationCreateWithURL(tiff as CFURL, "public.tiff" as CFString, 2, nil) else {
            throw CheckFailure("Could not construct a multi-frame TIFF fixture")
        }
        CGImageDestinationAddImage(destination, firstImage, nil)
        CGImageDestinationAddImage(destination, secondImage, nil)
        try expect(CGImageDestinationFinalize(destination), "Could not finish the multi-frame TIFF fixture")
        let sourceHash = try sha256(tiff)
        guard let source = CGImageSourceCreateWithURL(tiff as CFURL, nil) else { throw CheckFailure("Multi-frame TIFF did not decode") }
        try expect(CGImageSourceGetCount(source) == 2, "The source TIFF fixture must contain two frames")

        let output = folder.appendingPathComponent("output", isDirectory: true)
        let gif = try convert(tiff, to: "gif", category: .image, output: output)
        guard let generated = CGImageSourceCreateWithURL(gif as CFURL, nil) else { throw CheckFailure("Converted GIF did not decode") }
        try expect(CGImageSourceGetCount(generated) == 2, "TIFF → GIF dropped an image frame")
        let animatedPDF = try convert(gif, to: "pdf", category: .document, output: output)
        guard let pdfDocument = PDFDocument(url: animatedPDF) else { throw CheckFailure("Animated GIF → PDF did not decode") }
        try expect(pdfDocument.pageCount == 2, "Animated GIF → PDF did not preserve both frames as pages")
        try expect(try sha256(tiff) == sourceHash, "Multi-frame TIFF source changed")

        if registry.routes.contains(where: { $0.inputExtension == "gif" && $0.output.fileExtension == "mp4" && registry.isAvailable($0.engine) }) {
            let animatedVideo = try convert(gif, to: "mp4", category: .video, output: output)
            try validateWithFFprobe(animatedVideo, ffmpeg: try unwrap(ExecutableLocator.resolve(["ffmpeg"]), "FFmpeg route was advertised without an executable"))
            try expect((try Data(contentsOf: animatedVideo)).count > 0, "Animated GIF → MP4 produced an empty file")
        }

        let rejectedOutput = output.appendingPathComponent("animated.jpg")
        do {
            _ = try convert(tiff, to: "jpg", category: .image, output: output)
            throw CheckFailure("TIFF → JPEG silently dropped a frame")
        } catch is CheckFailure {
            throw CheckFailure("TIFF → JPEG silently dropped a frame")
        } catch { }
        try expect(!FileManager.default.fileExists(atPath: rejectedOutput.path), "Rejected lossy multi-frame conversion left a partial file")
        try expect(try sha256(tiff) == sourceHash, "Rejected multi-frame conversion changed its source")
    }

    private func checkConversionPresets() throws {
        try expect(ConversionPreset.imagesToJPEG.isAvailable(inputExtensions: ["PNG"], outputExtensions: ["jpg"]), "JPEG preset should accept a supported image and available output")
        try expect(ConversionPreset.imagesToWebP80.isAvailable(inputExtensions: ["png"], outputExtensions: ["webp"]), "WebP preset should be available when its route exists")
        try expect(ConversionPreset.imagesToWebP80.imageQualityOverride == 0.8, "WebP preset should use 80 percent quality")
        try expect(!ConversionPreset.imagesToWebP80.isAvailable(inputExtensions: ["png"], outputExtensions: ["jpg"]), "WebP preset should be hidden when WebP output is unavailable")
        try expect(!ConversionPreset.imagesToJPEG.isAvailable(inputExtensions: ["png", "docx"], outputExtensions: ["jpg"]), "Image preset should not accept a mixed non-image selection")
        try expect(ConversionPreset.videoToMP4H264.isAvailable(inputExtensions: ["mov"], outputExtensions: ["mp4"]), "H.264 preset should accept a supported video route")
        try expect(ConversionPreset.extractAudioToMP3.isAvailable(inputExtensions: ["mov", "wav"], outputExtensions: ["mp3"]), "Audio extraction preset should accept mixed audio and video inputs")
        try expect(!ConversionPreset.extractAudioToMP3.isAvailable(inputExtensions: ["docx"], outputExtensions: ["mp3"]), "Audio extraction preset should reject documents")
        try expect(!ConversionPreset.extractAudioToMP3.isAvailable(inputExtensions: ["gif"], outputExtensions: ["mp3"]), "Audio extraction preset should reject GIFs, which cannot contain audio")
        try expect(ConversionPreset.documentsToPDF.isAvailable(inputExtensions: ["docx"], outputExtensions: ["pdf"]), "Document preset should accept an available PDF route")
    }

    private func checkQuickConversionCatalog() throws {
        let discoveredTargets = QuickConversionCatalog.availableOutputs(
            for: [URL(fileURLWithPath: "/tmp/source.png")],
            registry: self.registry
        )
        try expect(discoveredTargets.contains { $0.fileExtension == "jpg" }, "The installed capability registry should offer PNG → JPEG")
        try expect(discoveredTargets.contains { $0.fileExtension == "pdf" }, "PNG should offer the native PDFKit route")
        try expect(discoveredTargets.allSatisfy { target in
            self.registry.routes(from: "png", to: target.fileExtension).contains { self.registry.isAvailable($0.engine) }
        }, "Finder advertised a route whose engine is unavailable or blocked")
        let pdfTargets = QuickConversionCatalog.availableOutputs(
            for: [URL(fileURLWithPath: "/tmp/source.pdf")],
            registry: self.registry
        )
        try expect(pdfTargets.contains { $0.fileExtension == "zip" && $0.displayName == "PNG images" }, "PDFs should offer a source-aware PNG images choice")

        let imageMagick = EngineStatus(
            id: .imageMagick,
            executableURL: URL(fileURLWithPath: "/usr/bin/magick"),
            version: "Version: ImageMagick 7.1.2-36 Q16"
        )
        let libreOffice = EngineStatus(
            id: .libreOffice,
            executableURL: URL(fileURLWithPath: "/usr/bin/soffice"),
            version: "LibreOffice 26.8.2.1"
        )
        let builtInStatuses: [EngineID: EngineStatus] = [
            .nativeImage: EngineStatus(id: .nativeImage),
            .nativePDF: EngineStatus(id: .nativePDF),
            .archive: EngineStatus(id: .archive),
        ]
        let routes = [
            ConversionRoute(inputExtension: "png", output: MorphFormat("jpg", "JPEG", .image), engine: .nativeImage, description: "Built-in image conversion"),
            ConversionRoute(inputExtension: "png", output: MorphFormat("webp", "WebP", .image), engine: .imageMagick, description: "Optional image conversion"),
            ConversionRoute(inputExtension: "png", output: MorphFormat("pdf", "PDF", .document), engine: .nativePDF, description: "Built-in PDF export"),
            ConversionRoute(inputExtension: "pdf", output: MorphFormat("zip", "PNG images", .archive), engine: .nativePDF, description: "Export PDF pages as PNG images"),
            ConversionRoute(inputExtension: "tiff", output: MorphFormat("jpg", "JPEG", .image), engine: .nativeImage, description: "Built-in image conversion"),
            ConversionRoute(inputExtension: "tar", output: MorphFormat("zip", "ZIP archive", .archive), engine: .archive, description: "Repackage archive"),
            ConversionRoute(inputExtension: "docx", output: MorphFormat("pdf", "PDF", .document), engine: .libreOffice, description: "Optional document conversion"),
        ]
        var allStatuses = builtInStatuses
        allStatuses[.imageMagick] = imageMagick
        allStatuses[.libreOffice] = libreOffice
        let registry = EngineRegistry(statuses: allStatuses, routes: routes)
        let png = URL(fileURLWithPath: "/tmp/source.png")
        let tiff = URL(fileURLWithPath: "/tmp/source.tiff")
        let tar = URL(fileURLWithPath: "/tmp/source.tar")
        let docx = URL(fileURLWithPath: "/tmp/source.docx")

        let pngTargets = QuickConversionCatalog.availableOutputs(for: [png], registry: registry)
        try expect(pngTargets.map(\.fileExtension) == ["jpg", "webp", "pdf"], "A PNG selection should show only its available image/PDF targets; got \(pngTargets.map(\.fileExtension))")
        try expect(!pngTargets.contains { $0.fileExtension == "mp3" }, "A PNG selection must not show unrelated audio outputs")
        let fixturePDFTargets = QuickConversionCatalog.availableOutputs(for: [URL(fileURLWithPath: "/tmp/source.pdf")], registry: registry)
        try expect(fixturePDFTargets.contains { $0.fileExtension == "zip" && $0.displayName == "PNG images" }, "PDF's image destination should have a concise, format-focused label")
        let archiveTargets = QuickConversionCatalog.availableOutputs(for: [tar], registry: registry)
        try expect(archiveTargets.contains { $0.fileExtension == "zip" && $0.displayName == "ZIP archive" }, "TAR → ZIP must be labeled as an archive, not PDF images")
        let mixedPDFArchive = QuickConversionCatalog.availableOutputs(for: [URL(fileURLWithPath: "/tmp/source.pdf"), tar], registry: registry)
        try expect(mixedPDFArchive.contains { $0.fileExtension == "zip" && $0.displayName == "ZIP archive or PDF page images" }, "A mixed ZIP target must explain that the output depends on its input type")

        let imageTargets = QuickConversionCatalog.availableOutputs(for: [png, tiff], registry: registry)
        try expect(imageTargets.map(\.fileExtension) == ["jpg"], "Finder should show only targets supported by every selected image; got \(imageTargets.map(\.fileExtension))")

        let mixedTargets = QuickConversionCatalog.availableOutputs(for: [png, docx], registry: registry)
        try expect(mixedTargets.map(\.fileExtension) == ["pdf"], "Finder should retain a shared target supported across mixed inputs")

        let noOptionalEngineRegistry = EngineRegistry(statuses: builtInStatuses, routes: routes)
        let installedOnlyTargets = QuickConversionCatalog.availableOutputs(for: [png], registry: noOptionalEngineRegistry)
        try expect(installedOnlyTargets.map(\.fileExtension) == ["jpg", "pdf"], "Finder must hide routes whose optional conversion engine is unavailable; got \(installedOnlyTargets.map(\.fileExtension))")

        let finderFallbackRegistry = EngineRegistry.discoverFinderSync()
        let zipTargets = QuickConversionCatalog.availableOutputs(
            for: [URL(fileURLWithPath: "/tmp/source.zip")],
            registry: finderFallbackRegistry
        )
        try expect(zipTargets.contains { $0.fileExtension == "tar.gz" }, "Finder's no-snapshot fallback should include the built-in ZIP → TAR.GZ route")

        let customizedTargets = QuickConversionCatalog.availableOutputs(
            for: [png],
            registry: registry,
            hiddenOutputExtensions: ["JPG", "pdf"]
        )
        try expect(customizedTargets.map(\.fileExtension) == ["webp"], "Finder should respect the user's hidden output formats; got \(customizedTargets.map(\.fileExtension))")
        let encodedRegistry = try JSONEncoder().encode(registry)
        let decodedRegistry = try JSONDecoder().decode(EngineRegistry.self, from: encodedRegistry)
        try expect(decodedRegistry.routes == registry.routes, "The Finder route snapshot should survive serialization")
        let snapshot = FinderSyncPreferencesSnapshot(
            registry: registry,
            hiddenOutputExtensions: ["PDF"],
            homeDirectoryPath: "/Users/example"
        )
        let decodedSnapshot = try JSONDecoder().decode(FinderSyncPreferencesSnapshot.self, from: JSONEncoder().encode(snapshot))
        try expect(decodedSnapshot.hiddenOutputExtensions == ["pdf"], "Finder preferences should preserve normalized hidden formats")
        try expect(decodedSnapshot.homeDirectoryPath == "/Users/example", "Finder preferences should preserve the user home path")
        try expect(QuickConversionCatalog.availableOutputs(for: [], registry: registry).isEmpty, "Finder should not offer formats for an empty selection")

        let firstRequestID = UUID().uuidString
        var requestLedger = FinderRequestIDLedger()
        try expect(requestLedger.register(firstRequestID), "Finder request ledger rejected a new request ID")
        try expect(!requestLedger.register(firstRequestID), "Finder request ledger accepted an in-process retry")
        try expect(!requestLedger.register(firstRequestID.lowercased()), "Finder request ledger treated case variants of the same UUID as different requests")
        var persistedLedger = try JSONDecoder().decode(FinderRequestIDLedger.self, from: JSONEncoder().encode(requestLedger))
        try expect(persistedLedger.contains(firstRequestID), "Finder request ID did not survive helper-state persistence")
        try expect(!persistedLedger.register(firstRequestID), "Finder request retry could replay after a helper restart")
    }

    private func checkFinderInputPreflight(_ folder: URL) throws {
        let regularFile = folder.appendingPathComponent("finder-input.txt")
        try "regular file".write(to: regularFile, atomically: true, encoding: .utf8)
        let directory = folder.appendingPathComponent("finder-folder", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let symlink = folder.appendingPathComponent("finder-link.txt")
        try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: regularFile)

        let inputs = try FinderInputPreflight.validate(paths: [regularFile.path])
        try expect(inputs == [regularFile.standardizedFileURL], "Finder input preflight changed a regular-file path")

        do {
            _ = try FinderInputPreflight.validate(paths: [directory.path])
            throw CheckFailure("Finder input preflight accepted a folder")
        } catch let failure as CheckFailure {
            throw failure
        } catch FinderInputPreflightError.notRegularFile { }

        do {
            _ = try FinderInputPreflight.validate(paths: [symlink.path])
            throw CheckFailure("Finder input preflight followed a symbolic link")
        } catch let failure as CheckFailure {
            throw failure
        } catch FinderInputPreflightError.symbolicLink { }
    }

    private func checkAudioVideo(_ folder: URL) throws {
        let ffmpeg = try requireSafeFFmpeg()
        let ffmpegStatus = registry.status(for: .ffmpeg)!
        try expect(FFmpegInputFormat.whitelist(for: "mp4") == "mov", "MP4 inputs should be restricted to the QuickTime/ISO BMFF demuxer")
        try expect(FFmpegInputFormat.whitelist(for: "unknown") == nil, "Unknown media extensions must not fall back to unrestricted demuxer detection")
        try expect(registry.routes.contains { $0.inputExtension == "mp3" && $0.output.fileExtension == "m4a" }, "The detected FFmpeg build should expose MP3 → M4A")
        try expect(registry.routes.contains { $0.inputExtension == "m4a" && $0.output.fileExtension == "mp3" }, "The detected FFmpeg build should expose the reverse M4A → MP3 route")
        try expect(!registry.routes.contains { $0.inputExtension == "gif" && $0.output.fileExtension == "mp3" }, "GIF must not advertise audio extraction")
        let output = folder.appendingPathComponent("output", isDirectory: true)
        let wav = folder.appendingPathComponent("tone.wav")
        let generatedAudio = try ProcessRunner.run(executable: ffmpeg, arguments: [
            "-hide_banner", "-loglevel", "error", "-y", "-f", "lavfi", "-i", "sine=frequency=440:duration=1", "-c:a", "pcm_s16le", wav.path,
        ])
        try expect(generatedAudio.status == 0, "Could not generate WAV fixture: \(generatedAudio.stderr)")
        let wavHash = try sha256(wav)
        let mp3 = try convert(wav, to: "mp3", category: .audio, output: output)
        let restoredWav = try convert(mp3, to: "wav", category: .audio, output: output)
        try validateWithFFprobe(mp3, ffmpeg: ffmpeg)
        try validateWithFFprobe(restoredWav, ffmpeg: ffmpeg)
        try expect(try sha256(wav) == wavHash, "WAV source changed")

        let mp3Hash = try sha256(mp3)
        let m4a = try convert(mp3, to: "m4a", category: .audio, output: output)
        let m4aHash = try sha256(m4a)
        let restoredMP3 = try convert(m4a, to: "mp3", category: .audio, output: output)
        try validateWithFFprobe(m4a, ffmpeg: ffmpeg)
        try validateWithFFprobe(restoredMP3, ffmpeg: ffmpeg)
        try expect(try sha256(mp3) == mp3Hash && sha256(m4a) == m4aHash, "MP3/M4A round-trip changed one of its source files")

        if ffmpegStatus.supportedInputExtensions.contains("aac") {
            let rawAAC = folder.appendingPathComponent("tone.aac")
            let generatedAAC = try ProcessRunner.run(executable: ffmpeg, arguments: [
                "-hide_banner", "-loglevel", "error", "-y", "-f", "lavfi", "-i", "sine=frequency=550:duration=1",
                "-c:a", "aac", "-f", "adts", rawAAC.path,
            ])
            try expect(generatedAAC.status == 0, "Could not generate AAC fixture: \(generatedAAC.stderr)")
            let rawAAChash = try sha256(rawAAC)
            let aacToMP3 = try convert(rawAAC, to: "mp3", category: .audio, output: output)
            try validateWithFFprobe(aacToMP3, ffmpeg: ffmpeg)
            try expect(try sha256(rawAAC) == rawAAChash, "AAC source changed during conversion")
        }

        if ffmpegStatus.supportedInputExtensions.contains("wma"), ffmpegStatus.supportedOutputExtensions.contains("wma") {
            let wma = folder.appendingPathComponent("tone.wma")
            let generatedWMA = try ProcessRunner.run(executable: ffmpeg, arguments: [
                "-hide_banner", "-loglevel", "error", "-y", "-i", wav.path, "-c:a", "wmav2", "-b:a", "64k", wma.path,
            ])
            try expect(generatedWMA.status == 0, "Could not generate WMA fixture: \(generatedWMA.stderr)")
            let wmaHash = try sha256(wma)
            let wmaToMP3 = try convert(wma, to: "mp3", category: .audio, output: output)
            let mp3ToWMA = try convert(mp3, to: "wma", category: .audio, output: output)
            try validateWithFFprobe(wmaToMP3, ffmpeg: ffmpeg)
            try validateWithFFprobe(mp3ToWMA, ffmpeg: ffmpeg)
            try expect(try sha256(wma) == wmaHash, "WMA source changed during conversion")
        }

        let mp4 = folder.appendingPathComponent("clip.mp4")
        let generatedVideo = try ProcessRunner.run(executable: ffmpeg, arguments: [
            "-hide_banner", "-loglevel", "error", "-y",
            "-f", "lavfi", "-i", "color=c=red:s=64x64:d=1",
            "-f", "lavfi", "-i", "sine=frequency=660:duration=1",
            "-shortest", "-c:v", "libx264", "-pix_fmt", "yuv420p", "-c:a", "aac",
            "-metadata", "title=Morph location metadata fixture",
            "-metadata", "location=+37.3861-122.0839/", mp4.path,
        ])
        try expect(generatedVideo.status == 0, "Could not generate MP4 fixture: \(generatedVideo.stderr)")
        let mp4Hash = try sha256(mp4)
        let disguisedPlaylist = folder.appendingPathComponent("playlist-disguised-as-video.mp4")
        try "ffconcat version 1.0\nfile '\(mp4.path)'\n".write(to: disguisedPlaylist, atomically: true, encoding: .utf8)
        let playlistSnapshot = try PrivateInputSnapshot(input: disguisedPlaylist, fileExtension: "mp4", cancellation: CancellationToken())
        let playlistStage = try PrivateOutputStage(parentDirectory: folder, primaryFileName: "playlist-output.mp3")
        let playlistOutput = try playlistStage.temporaryOutputURL()
        do {
            try FFmpegEngine.convert(executable: ffmpeg, input: playlistSnapshot.fileURL, output: playlistOutput, cancellation: CancellationToken())
            throw CheckFailure("FFmpeg accepted a concat playlist disguised as an MP4")
        } catch is CheckFailure {
            throw CheckFailure("FFmpeg accepted a concat playlist disguised as an MP4")
        } catch {
            try expect(!FileManager.default.fileExists(atPath: playlistOutput.path), "Rejected playlist input left an output file behind")
        }
        let webm = try convert(mp4, to: "webm", category: .video, output: output)
        let extractedAudio = try convert(mp4, to: "mp3", category: .audio, output: output)
        try validateWithFFprobe(webm, ffmpeg: ffmpeg)
        try validateWithFFprobe(extractedAudio, ffmpeg: ffmpeg)
        let ffprobe = ffmpeg.deletingLastPathComponent().appendingPathComponent("ffprobe")
        try expectMediaMetadataPolicy(webm, ffprobe: ffprobe, title: "Morph location metadata fixture", shouldKeepLocation: false)
        try expectMediaMetadataPolicy(extractedAudio, ffprobe: ffprobe, title: "Morph location metadata fixture", shouldKeepLocation: false)
        let locationKept = try convert(
            mp4,
            to: "webm",
            category: .video,
            output: folder.appendingPathComponent("location-kept", isDirectory: true),
            stripLocationMetadata: false
        )
        try expectMediaMetadataPolicy(locationKept, ffprobe: ffprobe, title: "Morph location metadata fixture", shouldKeepLocation: true)
        try expect(try sha256(mp4) == mp4Hash, "MP4 source changed")
    }

    private func checkVideoTrimming(_ folder: URL) throws {
        let ffmpeg = try requireSafeFFmpeg()
        guard let ffprobe = ExecutableLocator.resolve(["ffprobe"]) else {
            throw CheckSkip("FFmpeg/FFprobe is not installed")
        }
        let input = folder.appendingPathComponent("trim-source.mp4")
        let generated = try ProcessRunner.run(executable: ffmpeg, arguments: [
            "-hide_banner", "-loglevel", "error", "-y",
            "-f", "lavfi", "-i", "testsrc=size=96x64:rate=24:duration=2",
            "-f", "lavfi", "-i", "sine=frequency=440:duration=2",
            "-shortest", "-c:v", "libx264", "-pix_fmt", "yuv420p", "-c:a", "aac",
            "-metadata", "title=Morph trim metadata fixture",
            "-metadata", "location=+37.3861-122.0839/", input.path,
        ])
        try expect(generated.status == 0, "Could not generate trim fixture: \(generated.stderr)")
        let sourceHash = try sha256(input)
        let range = try MorphFileOperations.parseVideoTrimRange(start: " 0.25 ", end: " 0.9 ")
        try expect(abs(range.startSeconds - 0.25) < 0.0001 && abs(range.durationSeconds - 0.65) < 0.0001, "Video trim range parsing changed the requested interval")
        for invalid in [("-1", "1"), ("1", "1"), ("2", "1"), ("nan", "2")] {
            do {
                _ = try MorphFileOperations.parseVideoTrimRange(start: invalid.0, end: invalid.1)
                throw CheckFailure("Invalid video trim interval \(invalid) was accepted")
            } catch let failure as CheckFailure {
                throw failure
            } catch {
                // Invalid intervals must be rejected before any conversion starts.
            }
        }

        let outputDirectory = folder.appendingPathComponent("output", isDirectory: true)
        let trimmed = try MorphFileOperations.trimVideo(input, startSeconds: 0.25, endSeconds: 0.9, outputDirectory: outputDirectory)
        try OutputValidator.validate(trimmed, format: MorphFormat("mp4", "MP4", .video), engine: .ffmpeg)
        let durationResult = try ProcessRunner.run(executable: ffprobe, arguments: [
            "-v", "error", "-show_entries", "format=duration", "-of", "default=noprint_wrappers=1:nokey=1", trimmed.path,
        ])
        guard durationResult.status == 0,
              let duration = Double(durationResult.stdout.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            throw CheckFailure("FFprobe could not read the trimmed clip duration: \(durationResult.stderr)")
        }
        try expect(abs(duration - 0.65) <= 0.25, "Trimmed video has an unexpected duration: \(duration)")
        try expectMediaMetadataPolicy(trimmed, ffprobe: ffprobe, title: "Morph trim metadata fixture", shouldKeepLocation: false)
        try expect(try Data(contentsOf: trimmed).count > 0, "Trimmed MP4 is empty")
        let beforeOutOfBounds = try FileManager.default.contentsOfDirectory(atPath: outputDirectory.path)
        do {
            _ = try MorphFileOperations.trimVideo(input, startSeconds: 1.5, endSeconds: 2.5, outputDirectory: outputDirectory)
            throw CheckFailure("A trim ending beyond the source duration was accepted")
        } catch let failure as CheckFailure {
            throw failure
        } catch {
            // End times beyond the probed source duration must be rejected before encoding.
        }
        try expect(try FileManager.default.contentsOfDirectory(atPath: outputDirectory.path) == beforeOutOfBounds, "An out-of-bounds trim left a partial output")
        let secondTrim = try MorphFileOperations.trimVideo(input, startSeconds: 0.25, endSeconds: 0.9, outputDirectory: outputDirectory)
        try expect(secondTrim.lastPathComponent == "trim-source-trimmed-2.mp4", "Repeated video trim did not choose a collision-safe output name")
        try expect(try sha256(input) == sourceHash, "Video trimming changed the original source")
    }

    private func checkVideoCompression(_ folder: URL) throws {
        let ffmpeg = try requireSafeFFmpeg()
        guard let ffprobe = ExecutableLocator.resolve(["ffprobe"]) else {
            throw CheckSkip("FFmpeg/FFprobe is not installed")
        }
        let input = folder.appendingPathComponent("compression-source.mp4")
        let generated = try ProcessRunner.run(executable: ffmpeg, arguments: [
            "-hide_banner", "-loglevel", "error", "-y",
            "-f", "lavfi", "-i", "testsrc2=size=1920x1080:rate=24:duration=2",
            "-f", "lavfi", "-i", "sine=frequency=440:duration=2",
            "-shortest", "-c:v", "libx264", "-preset", "ultrafast", "-crf", "5", "-pix_fmt", "yuv420p",
            "-c:a", "aac", "-b:a", "320k",
            "-metadata", "title=Morph compression metadata fixture",
            "-metadata", "location=+37.3861-122.0839/", input.path,
        ])
        try expect(generated.status == 0, "Could not generate compression fixture: \(generated.stderr)")
        let sourceHash = try sha256(input)
        let sourceSize = try Data(contentsOf: input).count
        let outputDirectory = folder.appendingPathComponent("output", isDirectory: true)
        let compressed = try MorphFileOperations.compressVideo(
            input,
            options: VideoCompressionOptions(quality: .balanced, resolutionLimit: .hd),
            outputDirectory: outputDirectory
        )
        try expectMediaMetadataPolicy(compressed, ffprobe: ffprobe, title: "Morph compression metadata fixture", shouldKeepLocation: false)
        try OutputValidator.validate(compressed, format: MorphFormat("mp4", "MP4", .video), engine: .ffmpeg)

        let probe = try ProcessRunner.run(executable: ffprobe, arguments: [
            "-v", "error", "-show_entries", "stream=codec_type,codec_name,width,height",
            "-of", "json", compressed.path,
        ])
        guard probe.status == 0,
              let json = try JSONSerialization.jsonObject(with: Data(probe.stdout.utf8)) as? [String: Any],
              let streams = json["streams"] as? [[String: Any]],
              let stream = streams.first(where: { $0["codec_type"] as? String == "video" }),
              let codec = stream["codec_name"] as? String,
              let width = stream["width"] as? Int, let height = stream["height"] as? Int else {
            throw CheckFailure("FFprobe could not validate compressed video properties: \(probe.stderr)")
        }
        let audioCodec = streams.first(where: { $0["codec_type"] as? String == "audio" })?["codec_name"] as? String
        try expect(codec == "h264", "Video compression did not encode H.264")
        try expect(audioCodec == "aac", "Video compression did not encode the audio stream as AAC")
        try expect(width <= 1280 && height <= 720 && width > 0 && height > 0, "Compressed video exceeded the selected 720p limit")
        try expect(try Data(contentsOf: compressed).count < sourceSize, "The high-bitrate fixture was not reduced in size")
        let sourceDuration = try probeDuration(input, ffprobe: ffprobe)
        let outputDuration = try probeDuration(compressed, ffprobe: ffprobe)
        try expect(abs(sourceDuration - outputDuration) <= 0.25, "Video compression changed the source duration")
        try expect(try sha256(input) == sourceHash, "Video compression changed the original source")

        let rotatedInput = folder.appendingPathComponent("compression-rotated-source.mp4")
        let rotatedFixture = try ProcessRunner.run(executable: ffmpeg, arguments: [
            "-hide_banner", "-loglevel", "error", "-y", "-display_rotation:v:0", "90", "-i", input.path,
            "-c", "copy", rotatedInput.path,
        ])
        try expect(rotatedFixture.status == 0, "Could not create a rotated video fixture: \(rotatedFixture.stderr)")
        let rotatedHash = try sha256(rotatedInput)
        let rotatedOutput = try MorphFileOperations.compressVideo(
            rotatedInput,
            options: VideoCompressionOptions(quality: .balanced, resolutionLimit: .original),
            outputDirectory: outputDirectory
        )
        let rotatedProbe = try ProcessRunner.run(executable: ffprobe, arguments: [
            "-v", "error", "-show_entries", "stream=codec_type,width,height",
            "-of", "json", rotatedOutput.path,
        ])
        guard rotatedProbe.status == 0,
              let rotatedJSON = try JSONSerialization.jsonObject(with: Data(rotatedProbe.stdout.utf8)) as? [String: Any],
              let rotatedStreams = rotatedJSON["streams"] as? [[String: Any]],
              let rotatedStream = rotatedStreams.first(where: { $0["codec_type"] as? String == "video" }),
              let rotatedWidth = rotatedStream["width"] as? Int,
              let rotatedHeight = rotatedStream["height"] as? Int else {
            throw CheckFailure("FFprobe could not validate the rotated compressed video")
        }
        try expect(rotatedWidth == 1080 && rotatedHeight == 1920, "Keep original size did not preserve the display orientation and dimensions")
        try expect(try sha256(rotatedInput) == rotatedHash, "Rotated-video compression changed the original source")

        let second = try MorphFileOperations.compressVideo(
            input,
            options: VideoCompressionOptions(quality: .higherQuality, resolutionLimit: .original),
            outputDirectory: outputDirectory
        )
        try expect(second.lastPathComponent == "compression-source-compressed-2.mp4", "Repeated video compression did not choose a collision-safe output name")
        let remaining = try FileManager.default.contentsOfDirectory(atPath: outputDirectory.path)
        try expect(!remaining.contains(where: { $0.hasSuffix(".partial") }), "Video compression left a partial output")

        let invalid = folder.appendingPathComponent("invalid.mp4")
        try "not a video".write(to: invalid, atomically: true, encoding: .utf8)
        let beforeInvalid = try FileManager.default.contentsOfDirectory(atPath: outputDirectory.path)
        do {
            _ = try MorphFileOperations.compressVideo(invalid, outputDirectory: outputDirectory)
            throw CheckFailure("Invalid video input was accepted for compression")
        } catch let failure as CheckFailure {
            throw failure
        } catch {
            // Invalid media must fail before a final output is committed.
        }
        try expect(try FileManager.default.contentsOfDirectory(atPath: outputDirectory.path) == beforeInvalid, "Invalid video compression left an output behind")
        try expect(try sha256(input) == sourceHash, "A failed video compression changed the original source")
    }

    private func probeDuration(_ video: URL, ffprobe: URL) throws -> Double {
        let result = try ProcessRunner.run(executable: ffprobe, arguments: [
            "-v", "error", "-show_entries", "format=duration", "-of", "default=noprint_wrappers=1:nokey=1", video.path,
        ])
        guard result.status == 0,
              let duration = Double(result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            throw CheckFailure("FFprobe could not read video duration: \(result.stderr)")
        }
        return duration
    }

    private func requireSafeFFmpeg() throws -> URL {
        guard let status = registry.status(for: .ffmpeg), status.canConvert,
              let executable = status.executableURL else {
            throw CheckSkip(registry.status(for: .ffmpeg)?.securityNotice ?? "FFmpeg is not installed or its version could not be verified")
        }
        return executable
    }

    private func checkDocuments(_ folder: URL) throws {
        guard registry.isAvailable(.pandoc) else { throw CheckSkip("Pandoc is not installed") }
        let output = folder.appendingPathComponent("output", isDirectory: true)
        let markdown = folder.appendingPathComponent("notes.md")
        try "# Morph sample\n\nThis document survives conversion.\n".write(to: markdown, atomically: true, encoding: .utf8)
        let markdownHash = try sha256(markdown)
        let docx = try convert(markdown, to: "docx", category: .document, output: output)
        let html = try convert(docx, to: "html", category: .document, output: output)
        try expect(try String(contentsOf: html, encoding: .utf8).contains("survives conversion"), "Converted HTML lost document text")
        try expect(try sha256(markdown) == markdownHash, "Markdown source changed")

        try expect(registry.routes.contains {
            $0.inputExtension == "pdf" && $0.output.fileExtension == "txt" && $0.engine == .nativePDF
        }, "PDF text extraction should use the native PDFKit route")
        let pdf = folder.appendingPathComponent("text-sample.pdf")
        try makeTextPDF(at: pdf, text: "Morph PDF sample text")
        let pdfHash = try sha256(pdf)
        let text = try convert(pdf, to: "txt", category: .document, output: output)
        try expect(try String(contentsOf: text, encoding: .utf8).contains("Morph PDF sample text"), "PDF text was not preserved")
        try expect(try sha256(pdf) == pdfHash, "PDF source changed")

        if registry.isAvailable(.libreOffice) {
            let csv = folder.appendingPathComponent("budget.csv")
            try "item,total\nApples,12\nOranges,8\n".write(to: csv, atomically: true, encoding: .utf8)
            let csvHash = try sha256(csv)
            let workbook = try convert(csv, to: "xlsx", category: .spreadsheet, output: output)
            let restoredCSV = try convert(workbook, to: "csv", category: .spreadsheet, output: output)
            let restoredText = try String(contentsOf: restoredCSV, encoding: .utf8)
            try expect(restoredText.contains("Apples") && restoredText.contains("Oranges"), "Spreadsheet round trip lost cell text")
            try expect(try sha256(csv) == csvHash, "CSV source changed during spreadsheet conversion")
        }
    }

    private func checkLibreOfficeCSVFormulaSafety(_ folder: URL) throws {
        guard registry.isAvailable(.libreOffice) else {
            throw CheckSkip(registry.status(for: .libreOffice)?.availabilityNotice
                ?? registry.status(for: .libreOffice)?.securityNotice
                ?? "LibreOffice is not installed, reviewed, and available for conversions")
        }
        let input = folder.appendingPathComponent("formula-input.csv")
        try "value\n=1+1\n".write(to: input, atomically: true, encoding: .utf8)
        let originalHash = try sha256(input)
        let output = try convert(input, to: "xlsx", category: .spreadsheet, output: folder.appendingPathComponent("output", isDirectory: true))
        guard let unzip = ExecutableLocator.resolveSystemTool("unzip") else { throw CheckSkip("unzip is unavailable for spreadsheet validation") }
        let validationStage = try PrivateOutputStage(parentDirectory: folder, primaryFileName: "validated.xlsx")
        let stagedWorkbook = try validationStage.temporaryOutputURL()
        try FileManager.default.copyItem(at: output, to: stagedWorkbook)
        let sheet = try ProcessRunner.run(
            executable: unzip,
            arguments: ["-p", stagedWorkbook.path, "xl/worksheets/sheet1.xml"],
            sandboxReadableDirectories: [validationStage.directoryURL],
            restrictedSandbox: true
        )
        let sharedStrings = try ProcessRunner.run(
            executable: unzip,
            arguments: ["-p", stagedWorkbook.path, "xl/sharedStrings.xml"],
            sandboxReadableDirectories: [validationStage.directoryURL],
            restrictedSandbox: true
        )
        let worksheetXML = sheet.stdout + sharedStrings.stdout
        try expect(sheet.status == 0 && !worksheetXML.contains("<f>"), "CSV-to-XLSX evaluated or retained a formula cell")
        try expect(worksheetXML.contains("=1+1"), "CSV-to-XLSX changed formula-like source text instead of importing it as text")
        try expect(try sha256(input) == originalHash, "CSV formula import modified the original file")

        let packageStage = try PrivateOutputStage(parentDirectory: folder)
        let package = packageStage.directoryURL.appendingPathComponent("xlsx-package", isDirectory: true)
        try FileManager.default.createDirectory(at: package.appendingPathComponent("_rels", isDirectory: true), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: package.appendingPathComponent("xl/_rels", isDirectory: true), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: package.appendingPathComponent("xl/worksheets", isDirectory: true), withIntermediateDirectories: true)
        let xlsxParts: [(String, String)] = [
            ("[Content_Types].xml", """
            <?xml version="1.0" encoding="UTF-8"?>
            <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"><Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/><Default Extension="xml" ContentType="application/xml"/><Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/><Override PartName="/xl/worksheets/sheet1.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/></Types>
            """),
            ("_rels/.rels", """
            <?xml version="1.0" encoding="UTF-8"?>
            <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="xl/workbook.xml"/></Relationships>
            """),
            ("xl/workbook.xml", """
            <?xml version="1.0" encoding="UTF-8"?>
            <workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships"><sheets><sheet name="Sheet1" sheetId="1" r:id="rId1"/></sheets></workbook>
            """),
            ("xl/_rels/workbook.xml.rels", """
            <?xml version="1.0" encoding="UTF-8"?>
            <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet1.xml"/></Relationships>
            """),
            ("xl/worksheets/sheet1.xml", """
            <?xml version="1.0" encoding="UTF-8"?>
            <worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"><sheetData><row r="1"><c r="A1" t="inlineStr"><is><t>=1+1</t></is></c></row></sheetData></worksheet>
            """),
        ]
        for (path, contents) in xlsxParts {
            try contents.write(to: package.appendingPathComponent(path), atomically: true, encoding: .utf8)
        }
        let workbook = packageStage.directoryURL.appendingPathComponent("string-formula.xlsx")
        let zip = try unwrap(ExecutableLocator.resolveSystemTool("zip"), "zip is unavailable for the XLSX safety fixture")
        let created = try ProcessRunner.run(
            executable: zip,
            arguments: ["-qr", workbook.path, "[Content_Types].xml", "_rels", "xl"],
            currentDirectory: package,
            sandboxReadableDirectories: [packageStage.directoryURL],
            sandboxWritableDirectories: [packageStage.directoryURL],
            restrictedSandbox: true
        )
        try expect(created.status == 0, "Could not create a minimal XLSX string fixture")
        let exportedCSV = try convert(workbook, to: "csv", category: .spreadsheet, output: folder.appendingPathComponent("output", isDirectory: true))
        let exportedText = try String(contentsOf: exportedCSV, encoding: .utf8)
        try expect(exportedText.contains("'=1+1"), "LibreOffice CSV output was not formula-neutralized")
    }

    private func checkLibreOfficeCapabilityProbe(_ folder: URL) throws {
        guard let status = registry.status(for: .libreOffice), status.isInstalled else {
            throw CheckSkip("LibreOffice is not installed")
        }
        guard let executable = status.executableURL else {
            throw CheckFailure("The installed LibreOffice status has no executable path")
        }
        try expect(
            executable.path.hasSuffix("/LibreOffice.app/Contents/MacOS/soffice"),
            "LibreOffice must resolve to the app's native executable instead of its shell wrapper"
        )
        let header = [UInt8](try Data(contentsOf: executable).prefix(4))
        let machoMagics: [[UInt8]] = [
            [0xfe, 0xed, 0xfa, 0xce], [0xce, 0xfa, 0xed, 0xfe],
            [0xfe, 0xed, 0xfa, 0xcf], [0xcf, 0xfa, 0xed, 0xfe],
            [0xca, 0xfe, 0xba, 0xbe], [0xbe, 0xba, 0xfe, 0xca],
            [0xca, 0xfe, 0xba, 0xbf], [0xbf, 0xba, 0xfe, 0xca],
        ]
        try expect(machoMagics.contains(header), "LibreOffice resolved to a script instead of a Mach-O executable")
        do {
            _ = try EngineExecutableTrust.fingerprint(for: executable)
        } catch {
            throw CheckFailure("LibreOffice's native executable failed Morph's trust checks: \(error.localizedDescription)")
        }
        if status.availabilityNotice != nil {
            try expect(!registry.routes.contains(where: { $0.engine == .libreOffice }), "LibreOffice routes were advertised after its private sandbox conversion check failed")
            return
        }
        try expect(status.canConvert && !status.supportedInputExtensions.isEmpty, "LibreOffice routes require a passing sandbox conversion check")
        let inputStage = try PrivateOutputStage(parentDirectory: folder, primaryFileName: "sandbox-probe.csv")
        let outputStage = try PrivateOutputStage(parentDirectory: folder, primaryFileName: "sandbox-probe.xlsx")
        let input = try inputStage.temporaryOutputURL()
        let output = try outputStage.temporaryOutputURL()
        try "field,value\nMorph,1\n".write(to: input, atomically: true, encoding: .utf8)
        try LibreOfficeEngine.convert(
            executable: executable,
            input: input,
            output: output,
            cancellation: CancellationToken(),
            timeout: 30
        )
        try OutputValidator.validate(output, format: MorphFormat("xlsx", "Excel workbook", .spreadsheet), engine: .libreOffice)
        try expect(status.canConvert && !status.supportedInputExtensions.isEmpty, "LibreOffice passed a direct conversion but its route probe disabled conversion: \(status.availabilityNotice ?? status.securityNotice ?? "no engine notice")")
    }

    private func checkEngineSecurityFloors() throws {
        let cases: [(EngineID, String, String)] = [
            (.ffmpeg, "ffmpeg version 8.1.3 Copyright", "ffmpeg version 9.0.2 Copyright"),
            (.imageMagick, "Version: ImageMagick 7.1.2-35 Q16", "Version: ImageMagick 7.1.2-36 Q16"),
            (.libreOffice, "LibreOffice 26.2.6.2", "LibreOffice 26.2.7.1"),
            (.pandoc, "pandoc 3.13", "pandoc 3.14"),
            (.ghostscript, "10.07.1", "10.08.0"),
            (.sevenZip, "7-Zip (z) 26.05 (arm64)", "7-Zip (z) 26.06 (arm64)"),
        ]
        for (engine, vulnerableVersion, fixedVersion) in cases {
            try expect(
                EngineSecurityPolicy.notice(for: engine, version: vulnerableVersion) != nil,
                "Morph did not identify the vulnerable \(engine.displayName) version \(vulnerableVersion)"
            )
            try expect(
                EngineSecurityPolicy.notice(for: engine, version: fixedVersion) == nil,
                "Morph rejected the fixed \(engine.displayName) version \(fixedVersion)"
            )
        }
        try expect(EngineSecurityPolicy.notice(for: .ffmpeg, version: "ffmpeg version 9.0.1") != nil, "FFmpeg 9.0.1 should remain blocked")
        try expect(EngineSecurityPolicy.notice(for: .ffmpeg, version: "ffmpeg version 9.0.2") == nil, "FFmpeg 9.0.2 should be accepted")
        try expect(EngineSecurityPolicy.notice(for: .ffmpeg, version: "ffmpeg version 10.0.0") == nil, "A future FFmpeg major release should be accepted")
        try expect(EngineSecurityPolicy.notice(for: .ffmpeg, version: "ffprobe version 9.0.2") != nil, "FFmpeg status parsing must not accept an FFprobe banner")
        try expect(EngineSecurityPolicy.notice(for: .imageMagick, version: "unrecognized") != nil, "An unparseable ImageMagick version should fail closed")
        try expect(EngineSecurityPolicy.notice(for: .libreOffice, version: "LibreOffice 26.8.1.2") != nil, "LibreOffice 26.8.1 should remain blocked")
        try expect(EngineSecurityPolicy.notice(for: .libreOffice, version: "LibreOffice 26.8.2.1") == nil, "LibreOffice 26.8.2 should be accepted")
        try expect(EngineSecurityPolicy.notice(for: .pandoc, version: "pandoc 3.1.3") != nil, "Pandoc 3.1.3 should remain blocked")
        try expect(EngineSecurityPolicy.notice(for: .pandoc, version: "pandoc 3.14") == nil, "A current Pandoc release should be accepted")
        try expect(EngineSecurityPolicy.notice(for: .ghostscript, version: "10.07.1") != nil, "Ghostscript 10.07.1 should remain blocked")
        try expect(EngineSecurityPolicy.notice(for: .ghostscript, version: "10.08.0") == nil, "Ghostscript 10.08.0 should be accepted")
        try expect(EngineSecurityPolicy.notice(for: .ghostscript, version: "GPL Ghostscript 10.08.0 (2026-09-15)\nCompiler: clang 18.1.0") == nil, "A recognized Ghostscript banner should be accepted")
        try expect(EngineSecurityPolicy.notice(for: .sevenZip, version: "7-Zip 26.05") != nil, "7-Zip 26.05 should remain blocked")
        try expect(EngineSecurityPolicy.notice(for: .sevenZip, version: "7-Zip (z) 26.06 (arm64)") == nil, "A current 7-Zip banner should be accepted")

        let misleadingVersions: [(EngineID, String)] = [
            (.ffmpeg, "ffmpeg version unavailable\nlibavutil 59.8.100"),
            (.ffmpeg, "ffmpeg version unavailable\nffmpeg version 99.0.0"),
            (.imageMagick, "Version: ImageMagick unknown\nCompiler: clang 99.0.0"),
            (.imageMagick, "Version: ImageMagick unknown\nVersion: ImageMagick 99.0.0 Q16"),
            (.libreOffice, "LibreOffice unknown\nJRE Version: 99.0.0"),
            (.libreOffice, "LibreOffice unknown\nLibreOffice 99.0.0.0"),
            (.pandoc, "pandoc version unavailable\nGHC 99.0.0"),
            (.pandoc, "pandoc version unavailable\npandoc 99.0.0"),
            (.ghostscript, "Ghostscript version unavailable\n10.08.0"),
            (.ghostscript, "Ghostscript version unavailable\nGhostscript 99.0.0"),
            (.sevenZip, "7-Zip version unavailable\nGHC 99.0.0"),
            (.sevenZip, "7-Zip version unavailable\n7-Zip (z) 99.0.0 (arm64)"),
        ]
        for (engine, banner) in misleadingVersions {
            try expect(
                EngineSecurityPolicy.notice(for: engine, version: banner) != nil,
                "The (engine.displayName) floor accepted a different component's version number"
            )
        }

        let unsafeStatuses: [EngineID: EngineStatus] = [
            .ffmpeg: EngineStatus(
                id: .ffmpeg,
                executableURL: URL(fileURLWithPath: "/opt/homebrew/bin/ffmpeg"),
                version: "ffmpeg version 8.1.1",
                supportedInputExtensions: ["mp4"],
                supportedOutputExtensions: ["mov"]
            ),
            .imageMagick: EngineStatus(
                id: .imageMagick,
                executableURL: URL(fileURLWithPath: "/opt/homebrew/bin/magick"),
                version: "Version: ImageMagick 7.1.2-22 Q16",
                supportedInputExtensions: ["png"],
                supportedOutputExtensions: ["webp"]
            ),
            .libreOffice: EngineStatus(
                id: .libreOffice,
                executableURL: URL(fileURLWithPath: "/Applications/LibreOffice.app/Contents/MacOS/soffice"),
                version: "LibreOffice 26.2.3.2",
                supportedInputExtensions: ["docx"],
                supportedOutputExtensions: ["pdf"]
            ),
            .pandoc: EngineStatus(
                id: .pandoc,
                executableURL: URL(fileURLWithPath: "/opt/homebrew/bin/pandoc"),
                version: "pandoc 3.1.3",
                supportedInputExtensions: ["md"],
                supportedOutputExtensions: ["docx"]
            ),
            .ghostscript: EngineStatus(
                id: .ghostscript,
                executableURL: URL(fileURLWithPath: "/opt/homebrew/bin/gs"),
                version: "10.07.0",
                supportedInputExtensions: [],
                supportedOutputExtensions: []
            ),
            .sevenZip: EngineStatus(
                id: .sevenZip,
                executableURL: URL(fileURLWithPath: "/opt/homebrew/bin/7zz"),
                version: "7-Zip (z) 26.05 (arm64)",
                supportedInputExtensions: ["zip"],
                supportedOutputExtensions: ["7z"]
            ),
        ]
        let routes = ConversionCatalog.buildRoutes(statuses: unsafeStatuses)
        try expect(!routes.contains { unsafeStatuses[$0.engine]?.securityNotice != nil }, "The route catalog advertised a vulnerable engine")
        try expect(unsafeStatuses.values.allSatisfy { $0.isInstalled && !$0.canConvert }, "A vulnerable installed engine was misreported as usable or uninstalled")
    }

    private func checkSevenZipSecurityGate(_ folder: URL) throws {
        let executable = try makeEngineVersionFixture(named: "sevenzip-stale", executableName: "7zz", in: folder)

        let input = folder.appendingPathComponent("untrusted.zip")
        let outputDirectory = folder.appendingPathComponent("stale-sevenzip-output", isDirectory: true)
        try Data("not a parsed archive".utf8).write(to: input)
        let format = MorphFormat("7z", "7-Zip archive", .archive)
        let route = ConversionRoute(inputExtension: "zip", output: format, engine: .sevenZip, description: "stale 7-Zip registry route")
        let previouslySafeStatus = EngineStatus(
            id: .sevenZip,
            executableURL: executable,
            version: "7-Zip (z) 26.06 (arm64)",
            supportedInputExtensions: ["zip"],
            supportedOutputExtensions: ["7z"]
        )
        let service = ConversionService(
            registry: EngineRegistry(statuses: [.sevenZip: previouslySafeStatus], routes: [route]),
            engines: [SevenZipConversionEngine(executable: executable)]
        )
        do {
            _ = try service.convert(ConversionRequest(inputURL: input, outputFormat: format, outputDirectory: outputDirectory))
            throw CheckFailure("A stale registry allowed 7-Zip 26.05 to process an archive")
        } catch let error as MorphError {
            guard case .processFailed(let detail) = error, detail.contains("26.06") else {
                throw CheckFailure("The stale 7-Zip registry route returned an unexpected error: \(error.localizedDescription)")
            }
        }
        try expect(try FileManager.default.contentsOfDirectory(atPath: outputDirectory.path).isEmpty, "The rejected 7-Zip conversion left a partial output")
    }

    private func checkRuntimeEngineSecurityGate(_ folder: URL) throws {
        let executable = try makeEngineVersionFixture(named: "ffmpeg-stale", executableName: "ffmpeg", in: folder)

        do {
            try EngineSecurityPolicy.validateExecutable(executable, for: .ffmpeg)
            throw CheckFailure("The direct FFmpeg security gate accepted version 8.1.1")
        } catch let error as MorphError {
            guard case .processFailed(let detail) = error,
                  detail.contains("9.0.2") else {
                throw CheckFailure("The direct FFmpeg gate returned an unexpected error: \(error.localizedDescription)")
            }
        }
        let ffprobe = try makeEngineVersionFixture(named: "ffprobe-stale", executableName: "ffprobe", in: folder)
        do {
            try EngineSecurityPolicy.validateExecutable(ffprobe, for: .ffmpeg)
            throw CheckFailure("The direct FFprobe security gate accepted version 8.1.1")
        } catch let error as MorphError {
            guard case .processFailed(let detail) = error, detail.contains("9.0.2") else {
                throw CheckFailure("The direct FFprobe gate returned an unexpected error: \(error.localizedDescription)")
            }
        }
        let safeFFprobe = try makeEngineVersionFixture(named: "ffprobe-safe", executableName: "ffprobe", in: folder)
        try EngineSecurityPolicy.validateExecutable(safeFFprobe, for: .ffmpeg)
        let mismatchedFFprobe = try makeEngineVersionFixture(named: "ffprobe-mismatched", executableName: "ffprobe", in: folder)
        do {
            try EngineSecurityPolicy.validateExecutable(mismatchedFFprobe, for: .ffmpeg)
            throw CheckFailure("The FFprobe security gate accepted an FFmpeg banner from an ffprobe executable")
        } catch let error as MorphError {
            guard case .processFailed(let detail) = error, detail.localizedCaseInsensitiveContains("could not verify") else {
                throw CheckFailure("The mismatched FFprobe banner returned an unexpected error: \(error.localizedDescription)")
            }
        }

        let input = folder.appendingPathComponent("stale-engine-input.wav")
        let output = folder.appendingPathComponent("stale-engine-output", isDirectory: true)
        try Data([0x01, 0x02]).write(to: input)
        let route = ConversionRoute(inputExtension: "wav", output: MorphFormat("mp3", "MP3", .audio), engine: .ffmpeg, description: "stale registry route")
        let previouslyVerifiedStatus = EngineStatus(
            id: .ffmpeg,
            executableURL: executable,
            version: "ffmpeg version 9.0.2",
            supportedInputExtensions: ["wav"],
            supportedOutputExtensions: ["mp3"]
        )
        let staleRegistry = EngineRegistry(statuses: [.ffmpeg: previouslyVerifiedStatus], routes: [route])
        let service = ConversionService(registry: staleRegistry, engines: [FFmpegConversionEngine(executable: executable)])
        do {
            _ = try service.convert(ConversionRequest(inputURL: input, outputFormat: route.output, outputDirectory: output))
            throw CheckFailure("A stale safe registry allowed FFmpeg 8.1.1 to process an input")
        } catch let error as MorphError {
            guard case .processFailed(let detail) = error,
                  detail.contains("9.0.2") else {
                throw CheckFailure("The stale-registry conversion returned an unexpected error: \(error.localizedDescription)")
            }
        }
        try expect(try FileManager.default.contentsOfDirectory(atPath: output.path).isEmpty, "The rejected conversion left a partial output")

        for (engine, fixtureName, executableName, outputLine, minimum) in [
            (EngineID.pandoc, "pandoc-stale", "pandoc", "pandoc 3.13", "3.14"),
            (EngineID.ghostscript, "ghostscript-stale", "gs", "10.07.0", "10.08.0"),
        ] {
            let executable = try makeEngineVersionFixture(named: fixtureName, executableName: executableName, in: folder)
            do {
                try EngineSecurityPolicy.validateExecutable(executable, for: engine)
                throw CheckFailure("The direct \(engine.displayName) security gate accepted version \(outputLine)")
            } catch let error as MorphError {
                guard case .processFailed(let detail) = error, detail.contains(minimum) else {
                    throw CheckFailure("The direct \(engine.displayName) gate returned an unexpected error: \(error.localizedDescription)")
                }
            }
        }
    }

    private func makeEngineVersionFixture(named fixtureName: String, executableName: String, in folder: URL) throws -> URL {
        let fixtureDirectory = folder.appendingPathComponent("morph-engine-fixture-\(fixtureName)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: fixtureDirectory,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        let fixture = fixtureDirectory.appendingPathComponent(executableName)
        let testExecutable = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath().standardizedFileURL
        try FileManager.default.copyItem(at: testExecutable, to: fixture)
        guard chmod(fixture.path, mode_t(0o700)) == 0 else {
            throw CheckFailure("Could not prepare the native \(executableName) test fixture")
        }
        return fixture
    }

    private func checkDirectGhostscriptSecurityGate(_ folder: URL) throws {
        guard let status = registry.status(for: .ghostscript), status.isInstalled, status.securityNotice != nil else {
            throw CheckSkip("The installed Ghostscript is unavailable or meets Morph's reviewed security floor")
        }
        let input = folder.appendingPathComponent("untrusted.pdf")
        try makeTextPDF(at: input, text: "Morph must block vulnerable Ghostscript before PDF compression")
        let sourceHash = try sha256(input)
        let output = folder.appendingPathComponent("output", isDirectory: true)
        do {
            _ = try MorphFileOperations.compressPDF(input, outputDirectory: output)
            throw CheckFailure("PDF compression accepted an outdated Ghostscript")
        } catch is CheckFailure {
            throw CheckFailure("PDF compression accepted an outdated Ghostscript")
        } catch let error as MorphError {
            guard case .processFailed(let detail) = error, detail.contains("security floor (10.08.0)") else {
                throw CheckFailure("PDF compression failed for the wrong reason: \(error.localizedDescription)")
            }
        }
        try expect(!FileManager.default.fileExists(atPath: output.path), "Blocked PDF compression created an output folder")
        try expect(try sha256(input) == sourceHash, "Blocked PDF compression changed the source")
    }

    private func checkDirectVideoUtilitiesSecurityGate(_ folder: URL) throws {
        guard let status = registry.status(for: .ffmpeg),
              status.isInstalled,
              status.securityNotice != nil else {
            throw CheckSkip("The installed FFmpeg is at or above Morph's reviewed security floor")
        }
        let input = folder.appendingPathComponent("untrusted-empty-video.mp4")
        try Data().write(to: input)
        let sourceHash = try sha256(input)

        for (operation, outputDirectory) in [
            ("trim", folder.appendingPathComponent("trim-output", isDirectory: true)),
            ("compress", folder.appendingPathComponent("compress-output", isDirectory: true)),
        ] {
            do {
                if operation == "trim" {
                    _ = try MorphFileOperations.trimVideo(input, startSeconds: 0, endSeconds: 0.5, outputDirectory: outputDirectory)
                } else {
                    _ = try MorphFileOperations.compressVideo(input, outputDirectory: outputDirectory)
                }
                throw CheckFailure("Direct video \(operation) did not block an outdated FFmpeg")
            } catch let error as MorphError {
                guard case .processFailed(let detail) = error,
                      detail.contains("security floor") else {
                    throw CheckFailure("Direct video \(operation) failed for the wrong reason: \(error.localizedDescription)")
                }
            }
            try expect(!FileManager.default.fileExists(atPath: outputDirectory.path), "Rejected direct video \(operation) created an output directory")
            try expect(try sha256(input) == sourceHash, "Rejected direct video \(operation) changed its input")
        }
    }

    private func checkMediaOutputValidationSecurityGate(_ folder: URL) throws {
        guard let status = registry.status(for: .ffmpeg),
              status.isInstalled,
              status.securityNotice != nil,
              ExecutableLocator.resolve(["ffprobe"]) != nil else {
            throw CheckSkip("The installed FFmpeg/FFprobe pair is unavailable or meets Morph's reviewed security floor")
        }
        let generatedMedia = folder.appendingPathComponent("generated.mp4")
        try Data([0x01, 0x02, 0x03]).write(to: generatedMedia)
        do {
            try OutputValidator.validate(generatedMedia, format: MorphFormat("mp4", "MP4", .video), engine: .ffmpeg)
            throw CheckFailure("Media output validation accepted an outdated FFprobe")
        } catch is CheckFailure {
            throw CheckFailure("Media output validation accepted an outdated FFprobe")
        } catch let error as MorphError {
            guard case .processFailed(let detail) = error,
                  detail.localizedCaseInsensitiveContains("security floor")
                    || detail.localizedCaseInsensitiveContains("could not verify") else {
                throw CheckFailure("Media validation failed before the FFprobe version gate: \(error.localizedDescription)")
            }
        }
    }

    private func checkPDFSplitRollbackIdentity(_ folder: URL) throws {
        let output = folder.appendingPathComponent("page-001.pdf")
        let staging = try PrivateOutputStage(outputURL: output)
        try Data("Morph's generated page".utf8).write(to: staging.temporaryOutputURL())
        try staging.publishPrimary(to: output)
        guard let identity = staging.lastPublishedIdentity else {
            throw CheckFailure("The private output stage did not capture its published file identity")
        }

        try FileManager.default.removeItem(at: output)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: false)
        let sentinel = output.appendingPathComponent("do-not-delete.txt")
        try "unrelated item".write(to: sentinel, atomically: true, encoding: .utf8)

        try expect(!MorphFileOperations.rollbackSplitOutputs([identity]), "PDF rollback claimed it removed a replaced output directory")
        try expect(try String(contentsOf: sentinel, encoding: .utf8) == "unrelated item", "PDF rollback deleted an unrelated directory or its contents")
    }

    private func checkPDFSplitRejectsMovedFolder(_ folder: URL) throws {
        let first = folder.appendingPathComponent("split-first.pdf")
        let second = folder.appendingPathComponent("split-second.pdf")
        try makeTextPDF(at: first, text: "First split page")
        try makeTextPDF(at: second, text: "Second split page")
        let input = try MorphFileOperations.mergePDFs([first, second], outputDirectory: folder)
        let output = folder.appendingPathComponent("selected-split-output", isDirectory: true)
        let moved = folder.appendingPathComponent("selected-split-output-moved", isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

        do {
            _ = try MorphFileOperations.splitPDF(
                input,
                outputDirectory: output,
                cancellation: nil,
                beforePageProcessing: { index in
                    guard index == 1 else { return }
                    try FileManager.default.moveItem(at: output, to: moved)
                    try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
                }
            )
            throw CheckFailure("PDF split reported success after the output folder moved between pages")
        } catch is CheckFailure {
            throw CheckFailure("PDF split reported success after the output folder moved between pages")
        } catch MorphError.invalidOutput(let detail) {
            try expect(detail.localizedCaseInsensitiveContains("moved"), "PDF split returned an unclear error for a moved folder")
        }

        try expect(try FileManager.default.contentsOfDirectory(atPath: output.path).isEmpty, "PDF split published a page into the replacement folder")
        try expect(try FileManager.default.contentsOfDirectory(atPath: moved.path).isEmpty, "PDF split did not roll back its earlier page in the pinned folder")
    }

    private func checkZIPPublicationAfterMove(_ folder: URL) throws {
        let selected = folder.appendingPathComponent("selected-output", isDirectory: true)
        let moved = folder.appendingPathComponent("selected-output-moved", isDirectory: true)
        try FileManager.default.createDirectory(at: selected, withIntermediateDirectories: true)
        let parentDescriptor = selected.path.withCString { open($0, O_RDONLY | O_DIRECTORY | O_CLOEXEC) }
        guard parentDescriptor >= 0 else { throw CheckFailure("Could not pin the ZIP output directory") }
        defer { close(parentDescriptor) }

        let stagingName = ".morph-test-staging"
        guard stagingName.withCString({ mkdirat(parentDescriptor, $0, mode_t(0o700)) }) == 0 else {
            throw CheckFailure("Could not create the ZIP publication staging directory")
        }
        let stagingDescriptor = stagingName.withCString {
            openat(parentDescriptor, $0, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        }
        guard stagingDescriptor >= 0 else { throw CheckFailure("Could not open the ZIP publication staging directory") }
        defer { close(stagingDescriptor) }
        try "payload".write(to: selected.appendingPathComponent(stagingName).appendingPathComponent("payload.txt"), atomically: true, encoding: .utf8)

        do {
            _ = try MorphFileOperations.publishArchiveDirectory(
                baseName: "archive",
                parent: selected,
                parentDescriptor: parentDescriptor,
                stagingName: stagingName,
                stagingDescriptor: stagingDescriptor,
                afterRename: { try FileManager.default.moveItem(at: selected, to: moved) }
            )
            throw CheckFailure("ZIP extraction reported success after the selected output folder moved")
        } catch is CheckFailure {
            throw CheckFailure("ZIP extraction reported success after the selected output folder moved")
        } catch let error as MorphError {
            guard case .invalidOutput(let detail) = error,
                  detail.contains("moved") || detail.contains("verify") else {
                throw CheckFailure("ZIP publication returned the wrong error after an output-folder move: \(error.localizedDescription)")
            }
        }

        let publishedPayload = moved.appendingPathComponent("archive", isDirectory: true).appendingPathComponent("payload.txt")
        try expect(try String(contentsOf: publishedPayload, encoding: .utf8) == "payload", "The moved-folder fixture did not preserve the published data")
        try expect(!FileManager.default.fileExists(atPath: selected.appendingPathComponent("archive").path), "ZIP publication left a stale result path at the old location")
    }

    private func checkStructuredDataSymlinkOutput(_ folder: URL) throws {
        let input = folder.appendingPathComponent("record.json")
        try "{\"value\":\"stable symlink\"}".write(to: input, atomically: true, encoding: .utf8)
        let realOutput = folder.appendingPathComponent("real-output", isDirectory: true)
        let outputAlias = folder.appendingPathComponent("output-alias", isDirectory: true)
        try FileManager.default.createDirectory(at: realOutput, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: outputAlias, withDestinationURL: realOutput)
        let xml = try convert(input, to: "xml", category: .spreadsheet, output: outputAlias)
        try expect(FileManager.default.fileExists(atPath: xml.path), "JSON-to-XML rejected a stable symlinked output folder")
        try expect(try String(contentsOf: xml, encoding: .utf8).contains("stable symlink"), "JSON-to-XML lost content in a stable symlinked output folder")
    }

    private func checkLibreOfficeRoutes() throws {
        guard let status = registry.status(for: .libreOffice), status.canConvert else {
            throw CheckSkip(registry.status(for: .libreOffice)?.availabilityNotice
                ?? registry.status(for: .libreOffice)?.securityNotice
                ?? "LibreOffice is not installed or its version could not be verified")
        }
        let officeRoutes = registry.routes.filter { $0.engine == .libreOffice }
        func supports(_ input: String, _ output: String) -> Bool {
            officeRoutes.contains { $0.inputExtension == input && $0.output.fileExtension == output }
        }

        try expect(supports("docx", "pdf"), "LibreOffice should expose DOCX to PDF")
        try expect(supports("pptx", "pdf"), "LibreOffice should expose PPTX to PDF")
        try expect(supports("xlsx", "pdf"), "LibreOffice should expose XLSX to PDF")
        try expect(!supports("docx", "xlsx"), "LibreOffice must not advertise document-to-spreadsheet conversion")
        try expect(!supports("pptx", "xlsx"), "LibreOffice must not advertise presentation-to-spreadsheet conversion")
        try expect(!supports("xlsx", "docx"), "LibreOffice must not advertise spreadsheet-to-document conversion")
    }

    private func checkStructuredData(_ folder: URL) throws {
        let output = folder.appendingPathComponent("output", isDirectory: true)
        let json = folder.appendingPathComponent("records.json")
        try "[{\"name\":\"Ada Lovelace\",\"note\":\"comma, and \\\"quotes\\\"\",\"active\":true}]".write(to: json, atomically: true, encoding: .utf8)
        let jsonHash = try sha256(json)
        let symlinkTarget = folder.appendingPathComponent("symlink-target.json")
        let symlinkInput = folder.appendingPathComponent("symlink-input.json")
        let symlinkCSVInput = folder.appendingPathComponent("symlink-input.csv")
        try "{\"private\":true}".write(to: symlinkTarget, atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(at: symlinkInput, withDestinationURL: symlinkTarget)
        try FileManager.default.createSymbolicLink(at: symlinkCSVInput, withDestinationURL: symlinkTarget)
        let symlinkTargetHash = try sha256(symlinkTarget)
        do {
            try StructuredDataEngine.validateGeneratedOutput(symlinkInput, extension: "json")
            throw CheckFailure("Structured-data validation followed a symlink instead of pinning a regular output file")
        } catch is CheckFailure {
            throw CheckFailure("Structured-data validation followed a symlink instead of pinning a regular output file")
        } catch { }
        do {
            try StructuredDataEngine.sanitizeDelimitedFile(at: symlinkCSVInput)
            throw CheckFailure("Spreadsheet sanitization followed a symlink")
        } catch is CheckFailure {
            throw CheckFailure("Spreadsheet sanitization followed a symlink")
        } catch { }
        try expect(try sha256(symlinkTarget) == symlinkTargetHash, "Rejecting a symlink changed its target")
        let csv = try convert(json, to: "csv", category: .spreadsheet, output: output)
        let csvText = try String(contentsOf: csv, encoding: .utf8)
        try expect(csvText.contains("Ada Lovelace") && csvText.contains("comma, and"), "CSV lost input values")
        let restoredJSON = try convert(csv, to: "json", category: .spreadsheet, output: output)
        let records = try JSONSerialization.jsonObject(with: Data(contentsOf: restoredJSON)) as? [[String: Any]]
        try expect(records?.first?["name"] as? String == "Ada Lovelace", "CSV-to-JSON lost the name field")
        try expect(try sha256(json) == jsonHash, "JSON source changed")

        let xml = try convert(json, to: "xml", category: .spreadsheet, output: output)
        try expect(try String(contentsOf: xml, encoding: .utf8).contains("Ada Lovelace"), "XML lost input values")
        let fromXML = try convert(xml, to: "json", category: .spreadsheet, output: output)
        _ = try JSONSerialization.jsonObject(with: Data(contentsOf: fromXML))

        let ambiguousXML = folder.appendingPathComponent("reserved-text-field.xml")
        try "<root>parent text<_text>child text</_text></root>".write(to: ambiguousXML, atomically: true, encoding: .utf8)
        let ambiguousJSON = output.appendingPathComponent("reserved-text-field.json")
        do {
            _ = try convert(ambiguousXML, to: "json", category: .spreadsheet, output: output)
            throw CheckFailure("XML with a reserved _text child silently overwrote parent text")
        } catch is CheckFailure {
            throw CheckFailure("XML with a reserved _text child silently overwrote parent text")
        } catch let error as MorphError {
            guard error.localizedDescription.contains("_text") else {
                throw CheckFailure("Ambiguous XML was rejected for an unexpected reason: \(error.localizedDescription)")
            }
            try expect(!FileManager.default.fileExists(atPath: ambiguousJSON.path), "Rejected ambiguous XML left an output")
        }

        let repeatedXML = folder.appendingPathComponent("many-repeated-elements.xml")
        try ("<table>" + String(repeating: "<row>sample</row>", count: 16_000) + "</table>")
            .write(to: repeatedXML, atomically: true, encoding: .utf8)
        let repeatedJSON = try convert(repeatedXML, to: "json", category: .spreadsheet, output: output)
        let repeatedValue = try JSONSerialization.jsonObject(with: Data(contentsOf: repeatedJSON)) as? [String: [String]]
        try expect(repeatedValue?["row"]?.count == 16_000, "XML grouping lost repeated same-name sibling elements")

        let tooManyXML = folder.appendingPathComponent("too-many-elements.xml")
        try ("<table>" + String(repeating: "<row>x</row>", count: 100_001) + "</table>")
            .write(to: tooManyXML, atomically: true, encoding: .utf8)
        do {
            _ = try convert(tooManyXML, to: "json", category: .spreadsheet, output: output)
            throw CheckFailure("XML element-count limit was not enforced during parsing")
        } catch is CheckFailure {
            throw CheckFailure("XML element-count limit was not enforced during parsing")
        } catch { }

        let largeJSON = folder.appendingPathComponent("large-plain-string.json")
        let largeString = String(repeating: "m", count: 4_194_315)
        let largeInput = try JSONSerialization.data(withJSONObject: ["payload": largeString], options: [.sortedKeys])
        try largeInput.write(to: largeJSON)
        let largeXML = folder.appendingPathComponent("large-plain-string.xml")
        try StructuredDataEngine.convert(input: largeJSON, output: largeXML)
        try StructuredDataEngine.validateGeneratedOutput(largeXML, extension: "xml")
        let largeXMLSize = try FileManager.default.attributesOfItem(atPath: largeXML.path)[.size] as? NSNumber
        try expect((largeXMLSize?.intValue ?? Int.max) < 20 * 1024 * 1024, "XML size estimation rejected or expanded a valid plain-text payload beyond the output cap")

        let csv2 = folder.appendingPathComponent("table.csv")
        try "name,value\nGrace,3\n".write(to: csv2, atomically: true, encoding: .utf8)
        let tsv = try convert(csv2, to: "tsv", category: .spreadsheet, output: output)
        let csvAgain = try convert(tsv, to: "csv", category: .spreadsheet, output: output)
        try expect(try String(contentsOf: csvAgain, encoding: .utf8).contains("Grace,3"), "TSV round trip lost the row")

        let manyRowsCSV = folder.appendingPathComponent("many-rows.csv")
        let manyRows = 65_000
        try ("a,b,c,d\n" + String(repeating: "a,b,c,d\n", count: manyRows))
            .write(to: manyRowsCSV, atomically: true, encoding: .utf8)
        let manyRowsTSV = try convert(manyRowsCSV, to: "tsv", category: .spreadsheet, output: output)
        let serializedSize = try FileManager.default.attributesOfItem(atPath: manyRowsTSV.path)[.size] as? NSNumber
        try expect(serializedSize?.intValue == (manyRows + 1) * 8, "A valid 65,000-row CSV-to-TSV output was rejected or sized incorrectly")
    }

    private func checkDelimitedInputSafety(_ folder: URL) throws {
        let output = folder.appendingPathComponent("output", isDirectory: true)
        let crlf = folder.appendingPathComponent("windows-lines.csv")
        try "name,total\r\nApples,12\r\nOranges,8\r\n".write(to: crlf, atomically: true, encoding: .utf8)
        let sourceHash = try sha256(crlf)
        let jsonURL = try convert(crlf, to: "json", category: .spreadsheet, output: output)
        let records = try JSONSerialization.jsonObject(with: Data(contentsOf: jsonURL)) as? [[String: Any]]
        try expect(records?.count == 2, "CRLF parsing lost or duplicated CSV rows")
        try expect(records?.first?["name"] as? String == "Apples" && records?.last?["total"] as? String == "8", "CRLF parsing changed CSV cell values")
        try expect(try sha256(crlf) == sourceHash, "CRLF CSV source changed")

        let multilineJSON = folder.appendingPathComponent("multiline.json")
        try "[{\"note\":\"first\\r\\nsecond\"}]".write(to: multilineJSON, atomically: true, encoding: .utf8)
        let multilineCSV = try convert(multilineJSON, to: "csv", category: .spreadsheet, output: output)
        let multilineText = try String(contentsOf: multilineCSV, encoding: .utf8)
        try expect(multilineText.contains("\"first\r\nsecond\""), "CSV did not quote CRLF embedded in a field")
        let restoredMultilineJSON = try convert(multilineCSV, to: "json", category: .spreadsheet, output: output)
        let restoredMultiline = try JSONSerialization.jsonObject(with: Data(contentsOf: restoredMultilineJSON)) as? [[String: String]]
        try expect(restoredMultiline?.first?["note"] == "first\r\nsecond", "CSV round trip changed an embedded CRLF field")

        let combiningMarkJSON = folder.appendingPathComponent("combining-delimiter.json")
        let combiningValue = "a,\u{0301}b"
        let combiningInput = try JSONSerialization.data(withJSONObject: [["note": combiningValue]], options: [.fragmentsAllowed])
        try combiningInput.write(to: combiningMarkJSON)
        let combiningCSV = try convert(combiningMarkJSON, to: "csv", category: .spreadsheet, output: output)
        let combiningCSVText = try String(contentsOf: combiningCSV, encoding: .utf8)
        try expect(combiningCSVText.contains("\"a,\u{0301}b\""), "CSV failed to quote a delimiter followed by a combining mark")
        let restoredCombiningJSON = try convert(combiningCSV, to: "json", category: .spreadsheet, output: output)
        let restoredCombining = try JSONSerialization.jsonObject(with: Data(contentsOf: restoredCombiningJSON)) as? [[String: String]]
        try expect(restoredCombining?.first?["note"] == combiningValue, "CSV round trip changed a delimiter-plus-combining-mark value")

        let sparseCSV = folder.appendingPathComponent("sparse.csv")
        let wideHeader = (0..<1_000).map { "column\($0)" }.joined(separator: ",")
        try (wideHeader + "\n" + Array(repeating: "x", count: 600).joined(separator: "\n") + "\n")
            .write(to: sparseCSV, atomically: true, encoding: .utf8)
        let sparseOutput = output.appendingPathComponent("sparse.json")
        do {
            _ = try convert(sparseCSV, to: "json", category: .spreadsheet, output: output)
            throw CheckFailure("CSV row padding exceeded the cell budget without rejection")
        } catch is CheckFailure {
            throw CheckFailure("CSV row padding exceeded the cell budget without rejection")
        } catch { }
        try expect(!FileManager.default.fileExists(atPath: sparseOutput.path), "Rejected sparse CSV left a final output")

        let sparseJSON = folder.appendingPathComponent("sparse-records.json")
        let sparseRecords = (0..<1_000).map { index in ["field\(index % 600)": index] }
        try JSONSerialization.data(withJSONObject: sparseRecords).write(to: sparseJSON)
        do {
            _ = try convert(sparseJSON, to: "csv", category: .spreadsheet, output: output)
            throw CheckFailure("CSV export materialized a sparse row/key matrix above the cell budget")
        } catch is CheckFailure {
            throw CheckFailure("CSV export materialized a sparse row/key matrix above the cell budget")
        } catch { }

        let tooManyRecords = folder.appendingPathComponent("too-many-records.json")
        let oversizedRecords = (0..<100_001).map { ["value": $0] }
        try JSONSerialization.data(withJSONObject: oversizedRecords).write(to: tooManyRecords)
        do {
            _ = try convert(tooManyRecords, to: "csv", category: .spreadsheet, output: output)
            throw CheckFailure("CSV export accepted more than 100,000 records")
        } catch is CheckFailure {
            throw CheckFailure("CSV export accepted more than 100,000 records")
        } catch { }

        let extraColumn = folder.appendingPathComponent("extra-column.csv")
        try "name,total\nApples,12,unexpected\n".write(to: extraColumn, atomically: true, encoding: .utf8)
        let extraHash = try sha256(extraColumn)
        let expectedOutput = output.appendingPathComponent("extra-column.json")
        do {
            _ = try convert(extraColumn, to: "json", category: .spreadsheet, output: output)
            throw CheckFailure("CSV conversion silently discarded extra columns")
        } catch is CheckFailure {
            throw CheckFailure("CSV conversion silently discarded extra columns")
        } catch { }
        try expect(!FileManager.default.fileExists(atPath: expectedOutput.path), "Invalid CSV conversion left a final output")
        try expect(try sha256(extraColumn) == extraHash, "Rejected CSV source changed")

        let repeatedKeyCSV = folder.appendingPathComponent("repeated-long-header.csv")
        let repeatedHeader = String(repeating: "K", count: 4_000)
        let repeatedRows = repeatedHeader + "\n" + String(repeating: "x\n", count: 10_000)
        try repeatedRows.write(to: repeatedKeyCSV, atomically: true, encoding: .utf8)
        try expect(try Data(contentsOf: repeatedKeyCSV).count < 100_000, "CSV amplification fixture unexpectedly grew large")
        let amplifiedJSON = output.appendingPathComponent("repeated-long-header.json")
        do {
            _ = try convert(repeatedKeyCSV, to: "json", category: .spreadsheet, output: output)
            throw CheckFailure("CSV conversion materialized output above the global structured-data byte budget")
        } catch is CheckFailure {
            throw CheckFailure("CSV conversion materialized output above the global structured-data byte budget")
        } catch { }
        try expect(!FileManager.default.fileExists(atPath: amplifiedJSON.path), "Rejected amplified CSV left a final output")

        let formulas = folder.appendingPathComponent("formula-cells.json")
        let formulaRecord = [[
            "equals": "=1+1",
            "plus": "+SUM(1,2)",
            "at": "@SUM(1,2)",
            "positiveNumber": "+3.5",
            "phoneNumber": "+1 (555) 010-2030",
            "socialHandle": "@lakshay",
            "atCellReference": "@A1",
            "spaced": " \t=HYPERLINK(\"https://example.invalid\",\"open\")",
            "hiddenBOM": "\u{FEFF}=2+2",
            "hiddenZeroWidth": "\u{200B}=3+3",
            "\u{FEFF}=header": "safe",
            "negativeNumber": "-12.5",
            "negativeText": "-cmd|' /C calc'!A0",
        ]]
        try JSONSerialization.data(withJSONObject: formulaRecord).write(to: formulas)
        let sanitizedCSV = try convert(formulas, to: "csv", category: .spreadsheet, output: output)
        let sanitizedText = try String(contentsOf: sanitizedCSV, encoding: .utf8)
        try expect(sanitizedText.contains("'=1+1") && sanitizedText.contains("'+SUM(1,2)") && sanitizedText.contains("'@SUM(1,2)"), "CSV export left formula-leading cells executable")
        try expect(sanitizedText.contains("+3.5") && sanitizedText.contains("+1 (555) 010-2030") && sanitizedText.contains("@lakshay"), "CSV export changed legitimate signed numbers, phone numbers or @ handles")
        try expect(sanitizedText.contains("'@A1"), "CSV export left an @-prefixed cell reference unguarded")
        try expect(sanitizedText.contains("' \\t=HYPERLINK") || sanitizedText.contains("' \t=HYPERLINK"), "CSV export did not protect a whitespace-prefixed formula")
        try expect(sanitizedText.contains("-12.5") && sanitizedText.contains("'-cmd|"), "CSV export changed a negative number or left a formula-like minus value executable")
        try expect(sanitizedText.contains("'\u{FEFF}=2+2") && sanitizedText.contains("'\u{200B}=3+3"), "CSV export allowed a BOM or zero-width prefix to bypass formula protection")
        try expect(sanitizedText.contains("'\u{FEFF}=header"), "CSV export left a formula-like header unprotected")

        let generatedCSV = folder.appendingPathComponent("spreadsheet-generated.csv")
        try "label,value\nunsafe,\u{FEFF}=SUM(1+1)\n".write(to: generatedCSV, atomically: true, encoding: .utf8)
        try StructuredDataEngine.sanitizeDelimitedFile(at: generatedCSV)
        let sanitizedEngineCSV = try String(contentsOf: generatedCSV, encoding: .utf8)
        try expect(sanitizedEngineCSV.contains("'\u{FEFF}=SUM(1+1)"), "Spreadsheet CSV post-processing failed to neutralize a hidden-character formula")
    }

    private func checkPrivateInputSnapshot(_ folder: URL) throws {
        let source = folder.appendingPathComponent("source.json")
        try "{\"value\":1}".write(to: source, atomically: true, encoding: .utf8)
        let sourceHash = try sha256(source)
        let snapshot = try PrivateInputSnapshot(input: source, fileExtension: "json", cancellation: CancellationToken())
        let snapshotHash = try sha256(snapshot.fileURL)
        try expect(snapshotHash == sourceHash, "Private snapshot did not contain the selected source bytes")

        try "{\"value\":2}".write(to: source, atomically: true, encoding: .utf8)
        try expect(try sha256(snapshot.fileURL) == snapshotHash, "A later source edit changed the pinned snapshot")

        let symbolicLink = folder.appendingPathComponent("source-link.json")
        guard symlink(source.path, symbolicLink.path) == 0 else { throw CheckFailure("Could not create the symlink input fixture") }
        do {
            _ = try PrivateInputSnapshot(input: symbolicLink, fileExtension: "json", cancellation: CancellationToken())
            throw CheckFailure("A symlink input bypassed regular-file snapshot validation")
        } catch is CheckFailure {
            throw CheckFailure("A symlink input bypassed regular-file snapshot validation")
        } catch { }

        let fifo = folder.appendingPathComponent("source-fifo.json")
        guard mkfifo(fifo.path, mode_t(0o600)) == 0 else { throw CheckFailure("Could not create the FIFO input fixture") }
        do {
            _ = try PrivateInputSnapshot(input: fifo, fileExtension: "json", cancellation: CancellationToken())
            throw CheckFailure("A FIFO input was accepted for conversion")
        } catch is CheckFailure {
            throw CheckFailure("A FIFO input was accepted for conversion")
        } catch { }
        try expect(try sha256(source) != sourceHash, "The source fixture failed to change for snapshot isolation")
    }

    private func checkOutputDirectoryPolicy(_ folder: URL) throws {
        let localVolume = UInt64(MNT_LOCAL)
        try expect(OutputDirectorySecurity.supportsPrivateStaging(on: localVolume), "A writable local volume should support safe staging")
        try expect(!OutputDirectorySecurity.supportsPrivateStaging(on: localVolume | UInt64(MNT_RDONLY)), "A read-only volume should not support output staging")
        try expect(!OutputDirectorySecurity.supportsPrivateStaging(on: UInt64(0)), "A network or unknown volume should not support output staging")
        try expect(!OutputDirectorySecurity.supportsPrivateStaging(on: localVolume | UInt64(MNT_IGNORE_OWNERSHIP)), "A volume that ignores ownership should not support output staging")

        let privateDirectory = folder.appendingPathComponent("private-output", isDirectory: true)
        try FileManager.default.createDirectory(at: privateDirectory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try expect(OutputDirectoryPolicy.canSafelyStage(in: privateDirectory), "A private local output folder was rejected")

        let sharedDirectory = folder.appendingPathComponent("shared-output", isDirectory: true)
        try FileManager.default.createDirectory(at: sharedDirectory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o777])
        guard chmod(sharedDirectory.path, mode_t(0o777)) == 0 else { throw CheckFailure("Could not create a shared-output fixture") }
        try expect(!OutputDirectoryPolicy.canSafelyStage(in: sharedDirectory), "A non-sticky world-writable folder was considered safe for private staging")

        let stickyDirectory = folder.appendingPathComponent("sticky-output", isDirectory: true)
        try FileManager.default.createDirectory(at: stickyDirectory, withIntermediateDirectories: true)
        guard chmod(stickyDirectory.path, mode_t(0o1777)) == 0 else { throw CheckFailure("Could not create a sticky-output fixture") }
        try expect(OutputDirectoryPolicy.canSafelyStage(in: stickyDirectory), "A sticky temporary folder owned by the current user should allow safe staging")
    }

    private func checkDelimitedEmptyRecords(_ folder: URL) throws {
        let output = folder.appendingPathComponent("output", isDirectory: true)
        for fileExtension in ["csv", "tsv"] {
            let delimiter = fileExtension == "csv" ? "," : "\t"
            let input = folder.appendingPathComponent("explicit-empty-row.\(fileExtension)")
            let sourceText = "left\(delimiter)right\n\"\"\(delimiter)\"\"\n\nvalue\(delimiter)next\n"
            try sourceText.write(to: input, atomically: true, encoding: .utf8)
            let sourceHash = try sha256(input)

            let json = try convert(input, to: "json", category: .spreadsheet, output: output)
            let rows = try JSONSerialization.jsonObject(with: Data(contentsOf: json)) as? [[String: String]]
            try expect(rows?.count == 2, "\(fileExtension.uppercased()) conversion discarded an explicit empty record or kept a blank line")
            try expect(rows?.first?["left"] == "" && rows?.first?["right"] == "", "\(fileExtension.uppercased()) conversion changed explicitly empty fields")
            try expect(rows?.last?["left"] == "value" && rows?.last?["right"] == "next", "\(fileExtension.uppercased()) conversion changed the following record")

            let restored = try convert(json, to: fileExtension, category: .spreadsheet, output: output)
            let reparsed = try convert(restored, to: "json", category: .spreadsheet, output: output)
            let roundTrippedRows = try JSONSerialization.jsonObject(with: Data(contentsOf: reparsed)) as? [[String: String]]
            try expect(roundTrippedRows?.count == 2 && roundTrippedRows?.first?["right"] == "", "\(fileExtension.uppercased()) round trip did not preserve its explicit empty record")
            try expect(try sha256(input) == sourceHash, "\(fileExtension.uppercased()) empty-record conversion modified its source")

            let singleColumnInput = folder.appendingPathComponent("single-empty-record.\(fileExtension)")
            try "value\n\"\"\n".write(to: singleColumnInput, atomically: true, encoding: .utf8)
            let singleColumnJSON = try convert(singleColumnInput, to: "json", category: .spreadsheet, output: output)
            let singleColumnRows = try JSONSerialization.jsonObject(with: Data(contentsOf: singleColumnJSON)) as? [[String: String]]
            try expect(singleColumnRows?.count == 1 && singleColumnRows?.first?["value"] == "", "\(fileExtension.uppercased()) discarded a single-column empty record")

            let singleColumnRoundTrip = try convert(singleColumnJSON, to: fileExtension, category: .spreadsheet, output: output)
            let roundTripText = try String(contentsOf: singleColumnRoundTrip, encoding: .utf8)
            try expect(roundTripText == "value\n\"\"\n", "\(fileExtension.uppercased()) did not quote a single empty field")
            let singleColumnReparsed = try convert(singleColumnRoundTrip, to: "json", category: .spreadsheet, output: output)
            let reparsedRows = try JSONSerialization.jsonObject(with: Data(contentsOf: singleColumnReparsed)) as? [[String: String]]
            try expect(reparsedRows?.count == 1 && reparsedRows?.first?["value"] == "", "\(fileExtension.uppercased()) single-column round trip lost its empty record")
        }
    }

    private func checkYAMLAndTOML(_ folder: URL) throws {
        let output = folder.appendingPathComponent("output", isDirectory: true)
        let json = folder.appendingPathComponent("config.json")
        let jsonText = """
        {"name":"Ada Lovelace","active":true,"count":42,"note":"on","labels":["Math","Computing"],"settings":{"enabled":false}}
        """
        try jsonText.write(to: json, atomically: true, encoding: .utf8)
        let jsonHash = try sha256(json)

        let yaml = try convert(json, to: "yaml", category: .spreadsheet, output: output)
        let yamlText = try String(contentsOf: yaml, encoding: .utf8)
        try expect(!yamlText.isEmpty, "JSON-to-YAML produced empty output")
        let restoredJSON = try convert(yaml, to: "json", category: .spreadsheet, output: output)
        let restored = try JSONSerialization.jsonObject(with: Data(contentsOf: restoredJSON)) as? [String: Any]
        try expect(restored?["name"] as? String == "Ada Lovelace", "YAML-to-JSON lost the name")
        try expect(restored?["active"] as? Bool == true, "YAML-to-JSON changed a boolean")
        try expect(restored?["note"] as? String == "on", "YAML 1.2 parsing changed the string 'on' into a boolean")

        let toml = try convert(json, to: "toml", category: .spreadsheet, output: output)
        let tomlText = try String(contentsOf: toml, encoding: .utf8)
        try expect(tomlText.contains("Ada Lovelace") && tomlText.contains("active"), "JSON-to-TOML lost expected values")
        let restoredFromTOML = try convert(toml, to: "json", category: .spreadsheet, output: output)
        let tomlJSON = try JSONSerialization.jsonObject(with: Data(contentsOf: restoredFromTOML)) as? [String: Any]
        try expect(tomlJSON?["name"] as? String == "Ada Lovelace", "TOML-to-JSON lost the name")
        try expect(tomlJSON?["active"] as? Bool == true, "TOML-to-JSON changed a boolean")
        try expect(tomlJSON?["note"] as? String == "on", "TOML-to-JSON changed a string")

        let fixtureYAML = folder.appendingPathComponent("yaml-core.yaml")
        try "active: true\nlegacyWord: on\nbareDate: 2024-01-02\ncount: 42\n".write(to: fixtureYAML, atomically: true, encoding: .utf8)
        let yamlHash = try sha256(fixtureYAML)
        let yamlJSONURL = try convert(fixtureYAML, to: "json", category: .spreadsheet, output: output)
        let yamlJSON = try JSONSerialization.jsonObject(with: Data(contentsOf: yamlJSONURL)) as? [String: Any]
        try expect(yamlJSON?["active"] as? Bool == true, "YAML boolean was not parsed")
        try expect(yamlJSON?["legacyWord"] as? String == "on", "YAML 1.2 string semantics changed 'on'")
        try expect(yamlJSON?["bareDate"] as? String == "2024-01-02", "A bare YAML date should remain a string")
        try expect(yamlJSON?["count"] as? Int == 42, "YAML integer was not parsed")

        let yamlToml = try convert(fixtureYAML, to: "toml", category: .spreadsheet, output: output)
        let tomlYAML = try convert(yamlToml, to: "yml", category: .spreadsheet, output: output)
        let yamlRoundTripJSON = try convert(tomlYAML, to: "json", category: .spreadsheet, output: output)
        let roundTrip = try JSONSerialization.jsonObject(with: Data(contentsOf: yamlRoundTripJSON)) as? [String: Any]
        try expect(roundTrip?["legacyWord"] as? String == "on", "YAML → TOML → YAML changed the string 'on'")
        try expect(try sha256(json) == jsonHash, "Structured-data conversions changed the JSON source")
        try expect(try sha256(fixtureYAML) == yamlHash, "Structured-data conversions changed the YAML source")

        let multipleDocuments = folder.appendingPathComponent("multi.yaml")
        try "first: 1\n---\nsecond: 2\n".write(to: multipleDocuments, atomically: true, encoding: .utf8)
        let rejectedOutput = folder.appendingPathComponent("rejected.json")
        do {
            try StructuredDataEngine.convert(input: multipleDocuments, output: rejectedOutput)
            throw CheckFailure("Multi-document YAML should be rejected")
        } catch MorphError.invalidInput {
            try expect(!FileManager.default.fileExists(atPath: rejectedOutput.path), "Rejected YAML left a partial output")
        }

        let doubledBOMTOML = folder.appendingPathComponent("doubled-bom.toml")
        var doubledBOMData = Data([0xEF, 0xBB, 0xBF, 0xEF, 0xBB, 0xBF])
        doubledBOMData.append(contentsOf: "name = \"Ada\"\n".utf8)
        try doubledBOMData.write(to: doubledBOMTOML)
        let doubledBOMOutput = folder.appendingPathComponent("doubled-bom.json")
        do {
            try StructuredDataEngine.convert(input: doubledBOMTOML, output: doubledBOMOutput)
            throw CheckFailure("TOML with two UTF-8 BOMs should be rejected")
        } catch MorphError.invalidInput {
            try expect(!FileManager.default.fileExists(atPath: doubledBOMOutput.path), "Rejected TOML left a partial output")
        }
    }

    private func checkJSONDateShapedObjects(_ folder: URL) throws {
        let output = folder.appendingPathComponent("output", isDirectory: true)
        let input = folder.appendingPathComponent("date-shaped-object.json")
        try "[{\"year\":2024,\"month\":5,\"day\":1,\"sales\":100}]".write(to: input, atomically: true, encoding: .utf8)
        let originalHash = try sha256(input)

        for target in ["yaml", "toml", "xml"] {
            let converted = try convert(input, to: target, category: .spreadsheet, output: output)
            let restored = try convert(converted, to: "json", category: .spreadsheet, output: output)
            let restoredValue = try JSONSerialization.jsonObject(with: Data(contentsOf: restored))
            let record: [String: Any]?
            switch target {
            case "toml": record = ((restoredValue as? [String: Any])?["records"] as? [[String: Any]])?.first
            case "xml": record = (restoredValue as? [String: Any])?["item"] as? [String: Any]
            default: record = (restoredValue as? [[String: Any]])?.first
            }
            guard let record else {
                let convertedText = (try? String(contentsOf: converted, encoding: .utf8)) ?? "<unreadable output>"
                let restoredText = (try? String(contentsOf: restored, encoding: .utf8)) ?? "<unreadable output>"
                throw CheckFailure("JSON → \(target.uppercased()) changed a date-shaped object into a different root value. Output: \(convertedText.prefix(500)); restored: \(restoredText.prefix(500))")
            }
            let expectedValues = ["year": "2024", "month": "5", "day": "1", "sales": "100"]
            for (key, value) in expectedValues {
                let restoredField = record[key]
                let actualValue = target == "xml" ? restoredField as? String : (restoredField as? NSNumber)?.stringValue
                try expect(actualValue == value, "JSON → \(target.uppercased()) lost or changed the \(key) field")
            }
        }

        try expect(try sha256(input) == originalHash, "Date-shaped JSON conversion modified its source")
    }

    private func checkPDFAndImageResourceBudgets(_ folder: URL) throws {
        try expect(
            NativePDFEngine.addingMergedInputBytes(0, nextFileBytes: NativePDFEngine.maximumPDFInputBytes)
                == NativePDFEngine.maximumPDFInputBytes,
            "A single maximum-sized PDF should fit within the merge budget"
        )
        try expect(
            NativePDFEngine.addingMergedInputBytes(
                NativePDFEngine.maximumPDFInputBytes,
                nextFileBytes: NativePDFEngine.maximumPDFInputBytes
            ) == NativePDFEngine.maximumCombinedInputBytes,
            "Two maximum-sized PDFs should fit exactly within the combined merge budget"
        )
        for size in [UInt64(0), NativePDFEngine.maximumPDFInputBytes + 1] {
            do {
                _ = try NativePDFEngine.addingMergedInputBytes(0, nextFileBytes: size)
                throw CheckFailure("Invalid PDF merge input size \(size) was accepted")
            } catch is CheckFailure {
                throw CheckFailure("Invalid PDF merge input size \(size) was accepted")
            } catch { }
        }
        do {
            _ = try NativePDFEngine.addingMergedInputBytes(
                NativePDFEngine.maximumCombinedInputBytes,
                nextFileBytes: 1
            )
            throw CheckFailure("PDF merge inputs exceeded the aggregate byte budget")
        } catch is CheckFailure {
            throw CheckFailure("PDF merge inputs exceeded the aggregate byte budget")
        } catch { }
        do {
            _ = try MorphFileOperations.mergePDFs(
                Array(repeating: folder.appendingPathComponent("unused.pdf"), count: NativePDFEngine.maximumPageCount + 1),
                outputDirectory: folder
            )
            throw CheckFailure("PDF merge accepted more than the supported number of input files")
        } catch is CheckFailure {
            throw CheckFailure("PDF merge accepted more than the supported number of input files")
        } catch { }
        try NativePDFEngine.validatePageCount(1)
        try NativePDFEngine.validatePageCount(NativePDFEngine.maximumPageCount)
        for pageCount in [0, NativePDFEngine.maximumPageCount + 1] {
            do {
                try NativePDFEngine.validatePageCount(pageCount)
                throw CheckFailure("PDF page count \(pageCount) was accepted outside the supported limits")
            } catch is CheckFailure {
                throw CheckFailure("PDF page count \(pageCount) was accepted outside the supported limits")
            } catch { }
        }

        try NativeImageEngine.validateFramePixelCounts([1, NativeImageEngine.maximumFramePixels])
        for frameCounts in [
            [NativeImageEngine.maximumFramePixels + 1],
            Array(repeating: UInt64(1), count: NativeImageEngine.maximumFrameCount + 1),
            Array(repeating: NativeImageEngine.maximumFramePixels, count: 9),
        ] {
            do {
                try NativeImageEngine.validateFramePixelCounts(frameCounts)
                throw CheckFailure("An animated-image frame or total-pixel budget overflow was accepted")
            } catch is CheckFailure {
                throw CheckFailure("An animated-image frame or total-pixel budget overflow was accepted")
            } catch { }
        }

        let postscriptPDF = folder.appendingPathComponent("postscript-pdf-polyglot.pdf")
        try "%!PS-Adobe-3.0\n%PDF-1.7\nshowpage\n".write(to: postscriptPDF, atomically: true, encoding: .utf8)
        do {
            try NativePDFEngine.validateHeaderForGhostscript(postscriptPDF)
            throw CheckFailure("Ghostscript PDF validation accepted a PostScript/PDF polyglot")
        } catch let error as MorphError {
            guard case .invalidInput = error else { throw CheckFailure("PostScript/PDF polyglot returned the wrong validation error") }
        }

        let pdfHeader = folder.appendingPathComponent("pdf-header-only.pdf")
        try "%PDF-1.7\n".write(to: pdfHeader, atomically: true, encoding: .utf8)
        try NativePDFEngine.validateHeaderForGhostscript(pdfHeader)

        for (name, prefix) in [
            ("leading-whitespace.pdf", " %PDF-1.7\n"),
            ("late-header.pdf", String(repeating: " ", count: 1_019) + "%PDF-1.7\n"),
        ] {
            let invalidHeader = folder.appendingPathComponent(name)
            try prefix.write(to: invalidHeader, atomically: true, encoding: .utf8)
            do {
                try NativePDFEngine.validateHeaderForGhostscript(invalidHeader)
                throw CheckFailure("Ghostscript accepted a PDF header that does not start at byte zero")
            } catch is CheckFailure {
                throw CheckFailure("Ghostscript accepted a PDF header that does not start at byte zero")
            } catch MorphError.invalidInput { }
        }

        let oversizedOutput = folder.appendingPathComponent("oversized-generated-output")
        let oversizedOutputDescriptor = oversizedOutput.path.withCString {
            open($0, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, mode_t(0o600))
        }
        guard oversizedOutputDescriptor >= 0 else { throw CheckFailure("Could not create an oversized output safety fixture") }
        defer { close(oversizedOutputDescriptor) }
        guard ftruncate(oversizedOutputDescriptor, off_t(ConversionOutputLimits.maximumGeneratedBytes + 1)) == 0 else {
            throw CheckFailure("Could not size the oversized output safety fixture")
        }
        do {
            try ConversionOutputLimits.validate(oversizedOutput)
            throw CheckFailure("Morph accepted a generated file above its output size limit")
        } catch is CheckFailure {
            throw CheckFailure("Morph accepted a generated file above its output size limit")
        } catch MorphError.invalidOutput { }

        let fifo = folder.appendingPathComponent("named-pipe.pdf")
        guard mkfifo(fifo.path, mode_t(0o600)) == 0 else {
            throw CheckFailure("Could not create the PDF FIFO safety fixture")
        }
        do {
            try NativePDFEngine.validateInput(fifo)
            throw CheckFailure("A FIFO with a PDF extension was accepted as a regular PDF")
        } catch is CheckFailure {
            throw CheckFailure("A FIFO with a PDF extension was accepted as a regular PDF")
        } catch { }

        let oversized = folder.appendingPathComponent("oversized.pdf")
        let descriptor = oversized.path.withCString { open($0, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, mode_t(0o600)) }
        guard descriptor >= 0 else { throw CheckFailure("Could not create the oversized PDF safety fixture") }
        defer { close(descriptor) }
        guard ftruncate(descriptor, off_t(NativePDFEngine.maximumPDFInputBytes + 1)) == 0 else {
            throw CheckFailure("Could not size the oversized PDF safety fixture")
        }
        do {
            try NativePDFEngine.validateInput(oversized)
            throw CheckFailure("A sparse PDF beyond the input byte budget was accepted")
        } catch is CheckFailure {
            throw CheckFailure("A sparse PDF beyond the input byte budget was accepted")
        } catch { }
    }

    private func checkUnsafeYAML(_ folder: URL) throws {
        let output = folder.appendingPathComponent("output", isDirectory: true)
        let fixtures = [
            ("complex-key.yaml", "? [alpha, beta]\n: value\n"),
            ("nested-flow.yaml", String(repeating: "[", count: 140) + "0" + String(repeating: "]", count: 140)),
            ("combined-depth.yaml", String(repeating: " ", count: 100) + String(repeating: "[", count: 20) + String(repeating: "- ", count: 10) + "0" + String(repeating: "]", count: 20)),
        ]
        for (name, contents) in fixtures {
            let input = folder.appendingPathComponent(name)
            try contents.write(to: input, atomically: true, encoding: .utf8)
            let before = try sha256(input)
            let target = output.appendingPathComponent(input.deletingPathExtension().lastPathComponent + ".json")
            do {
                _ = try convert(input, to: "json", category: .spreadsheet, output: output)
                throw CheckFailure("Unsafe YAML fixture was accepted: \(name)")
            } catch is CheckFailure {
                throw CheckFailure("Unsafe YAML fixture was accepted: \(name)")
            } catch { }
            try expect(!FileManager.default.fileExists(atPath: target.path), "Rejected YAML left an output for \(name)")
            try expect(try sha256(input) == before, "Rejected YAML changed its input: \(name)")
        }

        let quotedText = String(repeating: "[", count: 140) + " quoted text " + String(repeating: "]", count: 140)
        let multilineQuoted = folder.appendingPathComponent("multiline-quoted-brackets.yaml")
        try "note: \"quoted scalar\n  \(quotedText)\n  still quoted\"\n".write(to: multilineQuoted, atomically: true, encoding: .utf8)
        let multilineOutput = try convert(multilineQuoted, to: "json", category: .spreadsheet, output: output)
        let multilineJSON = try JSONSerialization.jsonObject(with: Data(contentsOf: multilineOutput)) as? [String: String]
        try expect(multilineJSON?["note"]?.contains(quotedText) == true,
                   "YAML flow-depth scanning treated bracket characters in a multiline quoted scalar as structure")

        let explicitKeys = folder.appendingPathComponent("nested-explicit-keys.yaml")
        try (String(repeating: "? ", count: 140) + "leaf: value\n").write(to: explicitKeys, atomically: true, encoding: .utf8)
        do {
            _ = try convert(explicitKeys, to: "json", category: .spreadsheet, output: output)
            throw CheckFailure("The YAML pre-parser did not bound explicit-key nesting")
        } catch let error as MorphError {
            guard error.localizedDescription.contains("YAML inputs may not be nested") else {
                throw CheckFailure("Explicit-key YAML did not hit the pre-parser depth limit: \(error.localizedDescription)")
            }
        }

        let safeAliases = folder.appendingPathComponent("safe-aliases.yaml")
        try "base: &base [a, b, c]\nfirst: *base\nsecond: *base\n".write(to: safeAliases, atomically: true, encoding: .utf8)
        let safeAliasJSON = try convert(safeAliases, to: "json", category: .spreadsheet, output: output)
        let safeAliasText = try String(contentsOf: safeAliasJSON, encoding: .utf8)
        try expect(safeAliasText.contains("\"first\"") && safeAliasText.contains("\"second\""), "A bounded YAML alias did not retain its values")

        let literalBlock = folder.appendingPathComponent("literal-block.yaml")
        try "note: |\n  This literal text has [[brackets and { braces } that are not YAML flow collections.\n  It remains text.\n".write(to: literalBlock, atomically: true, encoding: .utf8)
        let literalJSON = try convert(literalBlock, to: "json", category: .spreadsheet, output: output)
        let literalText = try String(contentsOf: literalJSON, encoding: .utf8)
        try expect(literalText.contains("[[brackets") && literalText.contains("{ braces }"), "YAML literal-block punctuation was parsed as flow-collection nesting")

        let literalCRLF = folder.appendingPathComponent("literal-block-crlf.yaml")
        let literalSource = "note: |\n  This literal text has [[brackets and { braces } that are not YAML flow collections.\n  It remains text.\n"
        try literalSource.replacingOccurrences(of: "\n", with: "\r\n").write(to: literalCRLF, atomically: true, encoding: .utf8)
        let literalCRLFJSON = try convert(literalCRLF, to: "json", category: .spreadsheet, output: output)
        let literalCRLFValue = try JSONSerialization.jsonObject(with: Data(contentsOf: literalCRLFJSON)) as? [String: String]
        try expect(literalCRLFValue?["note"] == "This literal text has [[brackets and { braces } that are not YAML flow collections.\nIt remains text.\n", "CRLF YAML block scalars changed their text or were rejected by the safety scanner")

        var amplification = "level0: &a0 [x]\n"
        for level in 1...8 {
            let references = Array(repeating: "*a\(level - 1)", count: 5).joined(separator: ", ")
            amplification += "level\(level): &a\(level) [\(references)]\n"
        }
        let amplifiedAliases = folder.appendingPathComponent("amplified-aliases.yaml")
        try amplification.write(to: amplifiedAliases, atomically: true, encoding: .utf8)
        let amplifiedOutput = output.appendingPathComponent("amplified-aliases.json")
        do {
            try StructuredDataEngine.convert(input: amplifiedAliases, output: amplifiedOutput)
            throw CheckFailure("YAML alias expansion beyond the node budget was accepted")
        } catch is CheckFailure {
            throw CheckFailure("YAML alias expansion beyond the node budget was accepted")
        } catch MorphError.invalidInput {
            try expect(!FileManager.default.fileExists(atPath: amplifiedOutput.path), "Rejected YAML alias expansion left a partial output")
        }
    }

    private func checkPDFCompression(_ folder: URL) throws {
        guard let status = registry.status(for: .ghostscript), status.canConvert else {
            throw CheckSkip(registry.status(for: .ghostscript)?.securityNotice ?? "Ghostscript is not installed or its version could not be verified")
        }
        let input = folder.appendingPathComponent("report.pdf")
        let output = folder.appendingPathComponent("output", isDirectory: true)
        try makeTextPDF(at: input, text: "Morph PDF compression preserves this text")
        let originalHash = try sha256(input)
        let compressed = try MorphFileOperations.compressPDF(input, preset: .balanced, outputDirectory: output)
        guard let document = PDFDocument(url: compressed) else {
            throw CheckFailure("Compressed PDF could not be reopened")
        }
        try expect(document.pageCount == 1, "PDF compression changed the page count")
        try expect(document.page(at: 0)?.string?.contains("Morph PDF compression preserves this text") == true, "PDF compression lost page text")
        try OutputValidator.validate(compressed, format: MorphFormat("pdf", "PDF", .document), engine: .ghostscript)
        try expect(try sha256(input) == originalHash, "PDF compression changed the original")
        let outputNames = try FileManager.default.contentsOfDirectory(atPath: output.path)
        try expect(outputNames == [compressed.lastPathComponent], "PDF compression left a staging artifact")

        for preset in [PDFCompressionPreset.compact, .printQuality] {
            let presetOutput = folder.appendingPathComponent(preset.rawValue, isDirectory: true)
            let result = try MorphFileOperations.compressPDF(input, preset: preset, outputDirectory: presetOutput)
            try expect(PDFDocument(url: result)?.pageCount == 1, "\(preset.displayName) preset changed the PDF page count")
            try expect(PDFDocument(url: result)?.page(at: 0)?.string?.contains("Morph PDF compression preserves this text") == true, "\(preset.displayName) preset lost page text")
        }

        let cancelledOutput = folder.appendingPathComponent("cancelled", isDirectory: true)
        let cancellation = CancellationToken()
        cancellation.cancel()
        do {
            _ = try MorphFileOperations.compressPDF(input, outputDirectory: cancelledOutput, cancellation: cancellation)
            throw CheckFailure("PDF compression ignored a pre-cancelled token")
        } catch MorphError.cancelled {
            try expect(!FileManager.default.fileExists(atPath: cancelledOutput.path), "Cancelled PDF compression created an output folder before starting")
            try expect(try sha256(input) == originalHash, "Cancelled PDF compression changed the original")
        }
    }

    private func checkArchiveSnapshotRevision(_ folder: URL) throws {
        let input = folder.appendingPathComponent("archive-revision.bin")
        try Data(repeating: 0x41, count: 64).write(to: input)
        let descriptor = input.path.withCString { open($0, O_RDWR | O_CLOEXEC | O_NOFOLLOW) }
        guard descriptor >= 0 else { throw CheckFailure("Could not open the archive revision fixture") }
        defer { close(descriptor) }

        var before = stat()
        guard fstat(descriptor, &before) == 0 else { throw CheckFailure("Could not inspect the archive revision fixture") }
        try expect(ArchiveExtractor.sourceRevisionIsUnchanged(before, before), "An unchanged archive revision was rejected")

        var replacement: UInt8 = 0x42
        let writeCount = withUnsafePointer(to: &replacement) { pointer in
            pwrite(descriptor, pointer, 1, 0)
        }
        guard writeCount == 1, fsync(descriptor) == 0 else {
            throw CheckFailure("Could not mutate the archive revision fixture")
        }
        var after = stat()
        guard fstat(descriptor, &after) == 0 else { throw CheckFailure("Could not re-inspect the archive revision fixture") }
        try expect(!ArchiveExtractor.sourceRevisionIsUnchanged(before, after), "An archive changed during snapshotting could pass the revision check")
    }

    private func checkArchives(_ folder: URL) throws {
        let output = folder.appendingPathComponent("output", isDirectory: true)
        let sourceFolder = folder.appendingPathComponent("source", isDirectory: true)
        try FileManager.default.createDirectory(at: sourceFolder, withIntermediateDirectories: true)
        try "archive data retained".write(to: sourceFolder.appendingPathComponent("report.txt"), atomically: true, encoding: .utf8)
        let executable = sourceFolder.appendingPathComponent("executable.sh")
        try "#!/bin/sh\necho preserved\n".write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        let zip = folder.appendingPathComponent("bundle.zip")
        guard let zipTool = ExecutableLocator.resolve(["zip"]) else { throw CheckSkip("ZIP command is unavailable") }
        let created = try ProcessRunner.run(executable: zipTool, arguments: ["-qr", zip.path, "."], currentDirectory: sourceFolder)
        try expect(created.status == 0, "Could not create ZIP fixture: \(created.stderr)")
        let zipHash = try sha256(zip)
        guard let unzip = ExecutableLocator.resolve(["unzip"]) else { throw CheckSkip("unzip is unavailable") }
        guard let tarTool = ExecutableLocator.resolve(["tar"]) else { throw CheckSkip("TAR command is unavailable") }
        for target in ["tar", "tar.gz", "tar.bz2", "tar.xz"] {
            let archive = try convert(zip, to: target, category: .archive, output: output)
            try OutputValidator.validate(archive, format: MorphFormat(target, target.uppercased(), .archive), engine: .archive)
            let listing = try ProcessRunner.run(executable: tarTool, arguments: ["-tf", archive.path])
            try expect(listing.status == 0 && listing.stdout.contains("report.txt"), ".\(target) is missing its payload")
            let roundTripZip = try convert(archive, to: "zip", category: .archive, output: output)
            let zipListing = try ProcessRunner.run(executable: unzip, arguments: ["-Z1", roundTripZip.path])
            let payload = try ProcessRunner.run(executable: unzip, arguments: ["-p", roundTripZip.path])
            try expect(zipListing.status == 0 && zipListing.stdout.contains("report.txt"), "Repacked ZIP from .\(target) is missing its member")
            try expect(payload.status == 0 && payload.stdout.contains("archive data retained"), "Repacked ZIP from .\(target) changed the payload")
            let executableMode = try zipUnixMode(roundTripZip, memberName: "executable.sh")
            try expect(executableMode.map { $0 & 0o111 != 0 } == true, "Repackaging .\(target) discarded executable permission bits")
        }
        let directExtractionParent = folder.appendingPathComponent("direct-extraction", isDirectory: true)
        let directExtraction = try MorphFileOperations.extractZIP(zip, outputDirectory: directExtractionParent)
        let directFileAttributes = try FileManager.default.attributesOfItem(atPath: directExtraction.appendingPathComponent("executable.sh").path)
        let directPermissions = (directFileAttributes[.posixPermissions] as? NSNumber)?.intValue
        try expect(directPermissions.map { $0 & 0o777 } == 0o600, "Direct ZIP extraction should keep files private and non-executable")

        let inheritedACLStage = folder.appendingPathComponent("inherited-acl-stage", isDirectory: true)
        try FileManager.default.createDirectory(at: inheritedACLStage, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let inheritedACLResult = try ProcessRunner.run(
            executable: URL(fileURLWithPath: "/bin/chmod"),
            arguments: ["+a", "everyone allow read,file_inherit,directory_inherit", inheritedACLStage.path]
        )
        try expect(inheritedACLResult.status == 0, "Could not create an inheritable extraction ACL fixture: \(inheritedACLResult.stderr)")
        let inheritedStageDescriptor = inheritedACLStage.path.withCString {
            open($0, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        }
        guard inheritedStageDescriptor >= 0 else { throw CheckFailure("Could not open the ACL-inheriting extraction fixture") }
        defer { close(inheritedStageDescriptor) }
        try expect(OutputDirectorySecurity.hasExtendedACL(inheritedStageDescriptor) == true, "The extraction ACL fixture did not receive an inheritable permission")
        try ArchiveExtractor.extract(input: zip, to: inheritedACLStage, cancellation: CancellationToken())
        try expect(OutputDirectorySecurity.hasExtendedACL(inheritedStageDescriptor) == false, "Archive extraction did not clear the staging directory ACL")
        let inheritedFile = inheritedACLStage.appendingPathComponent("report.txt")
        let inheritedFileDescriptor = inheritedFile.path.withCString { open($0, O_RDONLY | O_CLOEXEC | O_NOFOLLOW) }
        guard inheritedFileDescriptor >= 0 else { throw CheckFailure("Could not open the extracted ACL test file") }
        defer { close(inheritedFileDescriptor) }
        let inheritedFileAttributes = try FileManager.default.attributesOfItem(atPath: inheritedFile.path)
        let inheritedFilePermissions = (inheritedFileAttributes[.posixPermissions] as? NSNumber)?.intValue
        try expect(OutputDirectorySecurity.hasExtendedACL(inheritedFileDescriptor) == false, "Extracted file retained an inherited ACL")
        try expect(inheritedFilePermissions.map { $0 & 0o777 } == 0o600, "Extracted file permissions changed while clearing inherited ACLs")

        let sharedParent = folder.appendingPathComponent("shared-output", isDirectory: true)
        try FileManager.default.createDirectory(at: sharedParent, withIntermediateDirectories: true)
        guard chmod(sharedParent.path, mode_t(0o777)) == 0 else { throw CheckFailure("Could not make the shared-output fixture writable") }
        do {
            _ = try MorphFileOperations.extractZIP(zip, outputDirectory: sharedParent)
            throw CheckFailure("ZIP extraction accepted a non-sticky world-writable output folder")
        } catch is CheckFailure {
            throw CheckFailure("ZIP extraction accepted a non-sticky world-writable output folder")
        } catch MorphError.invalidOutput { }
        try expect((try FileManager.default.contentsOfDirectory(atPath: sharedParent.path)).isEmpty, "Rejected shared output folder acquired a staging item")

        let stickyParent = folder.appendingPathComponent("sticky-output", isDirectory: true)
        try FileManager.default.createDirectory(at: stickyParent, withIntermediateDirectories: true)
        guard chmod(stickyParent.path, mode_t(0o1777)) == 0 else { throw CheckFailure("Could not make the sticky-output fixture") }
        let stickyExtraction = try MorphFileOperations.extractZIP(zip, outputDirectory: stickyParent)
        try expect(FileManager.default.fileExists(atPath: stickyExtraction.appendingPathComponent("report.txt").path), "ZIP extraction did not support a sticky shared output folder")

        let aclParent = folder.appendingPathComponent("acl-output", isDirectory: true)
        try FileManager.default.createDirectory(at: aclParent, withIntermediateDirectories: true)
        let chmodTool = URL(fileURLWithPath: "/bin/chmod")
        let aclResult = try ProcessRunner.run(executable: chmodTool, arguments: ["+a", "everyone allow delete_child", aclParent.path])
        try expect(aclResult.status == 0, "Could not create the ACL-protected ZIP output fixture: \(aclResult.stderr)")
        do {
            _ = try MorphFileOperations.extractZIP(zip, outputDirectory: aclParent)
            throw CheckFailure("ZIP extraction accepted an output ACL that allows other accounts to rename staging entries")
        } catch is CheckFailure {
            throw CheckFailure("ZIP extraction accepted an output ACL that allows other accounts to rename staging entries")
        } catch MorphError.invalidOutput { }
        try expect((try FileManager.default.contentsOfDirectory(atPath: aclParent.path)).isEmpty, "Rejected ACL output folder acquired a staging item")
        try expect(try sha256(zip) == zipHash, "Source ZIP changed")

        let tarAsGzip = folder.appendingPathComponent("uncompressed.tar.gz")
        let plainTarResult = try ProcessRunner.run(executable: tarTool, arguments: ["-cf", tarAsGzip.path, "-C", sourceFolder.path, "."])
        try expect(plainTarResult.status == 0, "Could not create the mismatched-filter TAR fixture: \(plainTarResult.stderr)")
        let mismatchStage = folder.appendingPathComponent("mismatch-stage", isDirectory: true)
        try FileManager.default.createDirectory(at: mismatchStage, withIntermediateDirectories: true)
        do {
            try ArchiveExtractor.extract(input: tarAsGzip, to: mismatchStage, cancellation: CancellationToken())
            throw CheckFailure("The archive reader accepted uncompressed TAR data with a .tar.gz suffix")
        } catch is CheckFailure {
            throw CheckFailure("The archive reader accepted uncompressed TAR data with a .tar.gz suffix")
        } catch { }

        if let arTool = ExecutableLocator.resolve(["ar"]) {
            let arNamedTar = folder.appendingPathComponent("ar-archive.tar")
            let arResult = try ProcessRunner.run(executable: arTool, arguments: ["-rcs", arNamedTar.path, "report.txt"], currentDirectory: sourceFolder)
            try expect(arResult.status == 0, "Could not create the mismatched-format archive fixture: \(arResult.stderr)")
            do {
                try ArchiveExtractor.extract(input: arNamedTar, to: mismatchStage, cancellation: CancellationToken())
                throw CheckFailure("The TAR reader accepted an AR archive")
            } catch is CheckFailure {
                throw CheckFailure("The TAR reader accepted an AR archive")
            } catch { }
        }
    }

    private func checkZIPPreflight(_ folder: URL) throws {
        guard let zipTool = ExecutableLocator.resolve(["zip"]) else { throw CheckSkip("ZIP command is unavailable") }
        let sourceDirectory = folder.appendingPathComponent("source", isDirectory: true)
        try FileManager.default.createDirectory(at: sourceDirectory, withIntermediateDirectories: true)
        try Data(repeating: 0x41, count: 64).write(to: sourceDirectory.appendingPathComponent("payload.txt"))
        let validArchive = folder.appendingPathComponent("valid.zip")
        let created = try ProcessRunner.run(executable: zipTool, arguments: ["-qr", validArchive.path, "payload.txt"], currentDirectory: sourceDirectory)
        try expect(created.status == 0, "Could not create ZIP preflight fixture: \(created.stderr)")
        try ArchiveEngine.validateZIP(validArchive)
        let sourceHash = try sha256(validArchive)

        var centralDirectoryGap = [UInt8](try Data(contentsOf: validArchive))
        guard let endRecord = findSignature([0x50, 0x4b, 0x05, 0x06], in: centralDirectoryGap) else {
            throw CheckFailure("ZIP fixture has no end-of-directory record")
        }
        let recordedOffset = UInt32(centralDirectoryGap[endRecord + 16])
            | UInt32(centralDirectoryGap[endRecord + 17]) << 8
            | UInt32(centralDirectoryGap[endRecord + 18]) << 16
            | UInt32(centralDirectoryGap[endRecord + 19]) << 24
        try expect(recordedOffset > 0, "ZIP fixture central-directory offset is invalid")
        putUInt32(Int(recordedOffset) - 1, at: endRecord + 16, in: &centralDirectoryGap)
        let gapArchive = folder.appendingPathComponent("central-directory-gap.zip")
        try Data(centralDirectoryGap).write(to: gapArchive)
        try expectZIPPreflightRejects(gapArchive, message: "ZIP preflight accepted data between the central directory and its end record")

        var nameMismatch = [UInt8](try Data(contentsOf: validArchive))
        guard let central = findSignature([0x50, 0x4b, 0x01, 0x02], in: nameMismatch) else {
            throw CheckFailure("ZIP fixture has no central-directory entry")
        }
        let nameLength = Int(nameMismatch[central + 28]) | Int(nameMismatch[central + 29]) << 8
        try expect(nameLength > 1 && central + 46 + nameLength <= nameMismatch.count, "ZIP fixture has an invalid central name")
        nameMismatch[central + 46] = nameMismatch[central + 46] == 0x70 ? 0x78 : 0x70
        let mismatchedArchive = folder.appendingPathComponent("mismatched-name.zip")
        try Data(nameMismatch).write(to: mismatchedArchive)
        try expectZIPPreflightRejects(mismatchedArchive, message: "ZIP preflight accepted mismatched local and central names")

        var oversized = [UInt8](try Data(contentsOf: validArchive))
        guard let oversizedCentral = findSignature([0x50, 0x4b, 0x01, 0x02], in: oversized) else {
            throw CheckFailure("ZIP fixture has no central-directory entry")
        }
        putUInt32(512 * 1024 * 1024 + 1, at: oversizedCentral + 24, in: &oversized)
        let oversizedArchive = folder.appendingPathComponent("oversized-entry.zip")
        try Data(oversized).write(to: oversizedArchive)
        let extractionDirectory = folder.appendingPathComponent("must-not-exist", isDirectory: true)
        try expectZIPExtractionRejected(oversizedArchive, outputDirectory: extractionDirectory, message: "ZIP preflight accepted an over-budget member")
        try expect(!FileManager.default.fileExists(atPath: extractionDirectory.path), "Oversized ZIP created an extraction directory")

        var inflatedPastDeclared = [UInt8](try Data(contentsOf: validArchive))
        guard let localHeader = findSignature([0x50, 0x4b, 0x03, 0x04], in: inflatedPastDeclared),
              let centralHeader = findSignature([0x50, 0x4b, 0x01, 0x02], in: inflatedPastDeclared) else {
            throw CheckFailure("ZIP fixture is missing its local or central file header")
        }
        putUInt32(1, at: localHeader + 22, in: &inflatedPastDeclared)
        putUInt32(1, at: centralHeader + 24, in: &inflatedPastDeclared)
        let inconsistentSizeArchive = folder.appendingPathComponent("stream-size-mismatch.zip")
        try Data(inflatedPastDeclared).write(to: inconsistentSizeArchive)
        let streamOutput = folder.appendingPathComponent("stream-output", isDirectory: true)
        try expectZIPExtractionRejected(inconsistentSizeArchive, outputDirectory: streamOutput, message: "ZIP extraction wrote payload bytes beyond the declared member size")
        try expect(!FileManager.default.fileExists(atPath: streamOutput.path), "Rejected streaming ZIP left an output directory")
        try expect(try sha256(validArchive) == sourceHash, "ZIP preflight modified the valid source archive")

        let fifo = folder.appendingPathComponent("archive-fifo")
        guard mkfifo(fifo.path, mode_t(0o600)) == 0 else { throw CheckFailure("Could not create a FIFO archive fixture") }
        let fifoStage = folder.appendingPathComponent("fifo-stage", isDirectory: true)
        try FileManager.default.createDirectory(at: fifoStage, withIntermediateDirectories: true)
        do {
            try ArchiveExtractor.extract(input: fifo, to: fifoStage, cancellation: CancellationToken())
            throw CheckFailure("Archive snapshotting accepted a FIFO input")
        } catch is CheckFailure {
            throw CheckFailure("Archive snapshotting accepted a FIFO input")
        } catch MorphError.invalidInput {
            try expect((try FileManager.default.contentsOfDirectory(atPath: fifoStage.path)).isEmpty, "Rejected FIFO archive left staged files")
        }

        let deepSource = folder.appendingPathComponent("deep-source", isDirectory: true)
        try FileManager.default.createDirectory(at: deepSource, withIntermediateDirectories: true)
        var deepPaths: [String] = []
        for branch in 0..<79 {
            var components = [String(format: "branch-%03d", branch)]
            components.append(contentsOf: (0..<126).map { String(format: "d%03d", $0) })
            let relativeFile = (components + ["payload.txt"]).joined(separator: "/")
            let file = deepSource.appendingPathComponent(relativeFile)
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data([UInt8(branch)]).write(to: file)
            deepPaths.append(relativeFile)
        }
        let implicitDirectoryArchive = folder.appendingPathComponent("implicit-directory-budget.zip")
        let deepArchiveResult = try ProcessRunner.run(
            executable: zipTool,
            arguments: ["-q", implicitDirectoryArchive.path] + deepPaths,
            currentDirectory: deepSource
        )
        try expect(deepArchiveResult.status == 0, "Could not create the implicit-directory budget fixture: \(deepArchiveResult.stderr)")
        let archiveListing = try ProcessRunner.run(executable: URL(fileURLWithPath: "/usr/bin/unzip"), arguments: ["-Z1", implicitDirectoryArchive.path])
        try expect(archiveListing.status == 0 && archiveListing.stdout.split(whereSeparator: \.isNewline).count == 79, "The implicit-directory fixture should contain fewer than 10,000 archive members")
        let deepOutput = folder.appendingPathComponent("implicit-directory-output", isDirectory: true)
        try expectZIPExtractionRejected(implicitDirectoryArchive, outputDirectory: deepOutput, message: "ZIP extraction exceeded its 10,000 filesystem-object budget through implicit directories")
        try expect(!FileManager.default.fileExists(atPath: deepOutput.path), "Rejected implicit-directory ZIP left an output folder")
    }

    private func checkZIPUnicodeAndSymlinkOutput(_ folder: URL) throws {
        let zipTool = URL(fileURLWithPath: "/usr/bin/zip")
        guard FileManager.default.isExecutableFile(atPath: zipTool.path) else { throw CheckSkip("macOS /usr/bin/zip is unavailable") }
        let source = folder.appendingPathComponent("source", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        let sourceFile = source.appendingPathComponent("café.txt")
        try "Unicode filename survives archive extraction".write(to: sourceFile, atomically: true, encoding: .utf8)
        let archive = folder.appendingPathComponent("unicode.zip")
        let created = try ProcessRunner.run(executable: zipTool, arguments: ["-q", archive.path, "café.txt"], currentDirectory: source)
        try expect(created.status == 0, "Could not create the macOS UTF-8 ZIP fixture: \(created.stderr)")
        let bytes = [UInt8](try Data(contentsOf: archive))
        guard let central = findSignature([0x50, 0x4b, 0x01, 0x02], in: bytes) else {
            throw CheckFailure("The Unicode ZIP fixture has no central directory record")
        }
        let flags = UInt16(bytes[central + 8]) | (UInt16(bytes[central + 9]) << 8)
        try expect(flags & 0x0800 == 0, "The macOS ZIP fixture no longer reproduces UTF-8 without the language flag")
        try ArchiveEngine.validateZIP(archive)

        let realOutput = folder.appendingPathComponent("selected-output", isDirectory: true)
        let outputAlias = folder.appendingPathComponent("selected-output-alias", isDirectory: true)
        try FileManager.default.createDirectory(at: realOutput, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: outputAlias, withDestinationURL: realOutput)
        let extracted = try MorphFileOperations.extractZIP(archive, outputDirectory: outputAlias)
        let extractedFile = extracted.appendingPathComponent("café.txt")
        try expect(try String(contentsOf: extractedFile, encoding: .utf8) == "Unicode filename survives archive extraction", "ZIP UTF-8 name or payload changed during extraction")
    }

    private func expectZIPPreflightRejects(_ archive: URL, message: String) throws {
        do {
            try ArchiveEngine.validateZIP(archive)
            throw CheckFailure(message)
        } catch let failure as CheckFailure {
            throw failure
        } catch let error as MorphError {
            guard case .invalidInput = error else { throw CheckFailure("ZIP preflight failed unexpectedly: \(error.localizedDescription)") }
        }
    }

    private func checkSevenZip(_ folder: URL) throws {
        guard let sevenZipTool = ExecutableLocator.resolve(["7zz", "7z"]) else {
            throw CheckSkip("7-Zip is not installed")
        }
        guard let zipTool = ExecutableLocator.resolve(["zip"]),
              let unzip = ExecutableLocator.resolve(["unzip"]) else {
            throw CheckSkip("ZIP tools are unavailable")
        }

        let sourceFolder = folder.appendingPathComponent("source", isDirectory: true)
        try FileManager.default.createDirectory(at: sourceFolder, withIntermediateDirectories: true)
        try "7-Zip keeps this archive payload intact".write(
            to: sourceFolder.appendingPathComponent("payload.txt"),
            atomically: true,
            encoding: .utf8
        )
        try "This is user data, not Morph's staging metadata.".write(
            to: sourceFolder.appendingPathComponent(StaleMorphStageCleanup.ownershipMarkerName),
            atomically: true,
            encoding: .utf8
        )
        let executableSource = sourceFolder.appendingPathComponent("tool.sh")
        try "#!/bin/sh\nexit 0\n".write(to: executableSource, atomically: true, encoding: .utf8)
        let expectedModificationDate = Date(timeIntervalSince1970: 1_700_000_000)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755, .modificationDate: expectedModificationDate],
            ofItemAtPath: executableSource.path
        )
        let sourceZip = folder.appendingPathComponent("bundle.zip")
        let created = try ProcessRunner.run(executable: zipTool, arguments: ["-qr", sourceZip.path, "."], currentDirectory: sourceFolder)
        try expect(created.status == 0, "Could not create ZIP fixture: \(created.stderr)")
        let sourceHash = try sha256(sourceZip)
        let output = folder.appendingPathComponent("output", isDirectory: true)

        let sevenZip = try convert(sourceZip, to: "7z", category: .archive, output: output)
        let checked = try ProcessRunner.run(executable: sevenZipTool, arguments: ["t", sevenZip.path])
        try expect(checked.status == 0, "Generated 7z failed integrity validation: \(checked.stderr)")
        let roundTripZip = try convert(sevenZip, to: "zip", category: .archive, output: output)
        let payload = try ProcessRunner.run(executable: unzip, arguments: ["-p", roundTripZip.path])
        try expect(payload.status == 0 && payload.stdout.contains("7-Zip keeps this archive payload intact"), "7-Zip round trip lost the archive payload")
        let markerNamedPayload = try ProcessRunner.run(
            executable: unzip,
            arguments: ["-p", roundTripZip.path, StaleMorphStageCleanup.ownershipMarkerName]
        )
        try expect(
            markerNamedPayload.status == 0 && markerNamedPayload.stdout.contains("This is user data"),
            "Archive conversion did not preserve a user file matching the former staging-marker name"
        )
        let metadataCheck = folder.appendingPathComponent("metadata-check", isDirectory: true)
        try FileManager.default.createDirectory(at: metadataCheck, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try ArchiveExtractor.extract(input: roundTripZip, to: metadataCheck, cancellation: CancellationToken(), preservePermissions: true)
        let restoredExecutable = metadataCheck.appendingPathComponent("tool.sh")
        let restoredAttributes = try FileManager.default.attributesOfItem(atPath: restoredExecutable.path)
        let restoredMode = (restoredAttributes[.posixPermissions] as? NSNumber)?.intValue
        let restoredDate = restoredAttributes[.modificationDate] as? Date
        try expect(restoredMode.map { $0 & 0o100 != 0 } == true, "ZIP ↔ 7z conversion discarded the owner's safe executable bit")
        try expect(restoredDate.map { abs($0.timeIntervalSince(expectedModificationDate)) <= 2 } == true, "ZIP ↔ 7z conversion discarded its source member modification time")
        try expect(try sha256(sourceZip) == sourceHash, "ZIP source changed during 7-Zip conversion")

        let outside = folder.appendingPathComponent("outside.txt")
        try "outside stays private".write(to: outside, atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(at: sourceFolder.appendingPathComponent("escape-link"), withDestinationURL: outside)
        let linkArchive = folder.appendingPathComponent("linked.7z")
        let linkCreated = try ProcessRunner.run(
            executable: sevenZipTool,
            arguments: ["a", "-snl", linkArchive.path, "escape-link"],
            currentDirectory: sourceFolder
        )
        guard linkCreated.status == 0 else { throw CheckSkip("Installed 7-Zip could not create a symbolic-link fixture") }
        do {
            _ = try convert(linkArchive, to: "zip", category: .archive, output: output)
            throw CheckFailure("7z extraction followed a symbolic link")
        } catch is CheckFailure {
            throw CheckFailure("7z extraction followed a symbolic link")
        } catch let error as MorphError {
            switch error {
            case .invalidInput, .processFailed: break
            default: throw CheckFailure("7z link rejection failed unexpectedly: \(error.localizedDescription)")
            }
        }
        try expect(try String(contentsOf: outside, encoding: .utf8) == "outside stays private", "7z symlink input changed its outside target")
        try expect(!FileManager.default.fileExists(atPath: output.appendingPathComponent("linked.zip").path), "Rejected 7z symlink conversion left an output")
    }

    private func checkArchiveTraversal(_ folder: URL) throws {
        guard let zipTool = ExecutableLocator.resolve(["zip"]),
              let unzip = ExecutableLocator.resolve(["unzip"]) else {
            throw CheckSkip("ZIP tools are unavailable")
        }
        let archiveSource = folder.appendingPathComponent("archive-source", isDirectory: true)
        try FileManager.default.createDirectory(at: archiveSource, withIntermediateDirectories: true)
        let outside = folder.appendingPathComponent("outside.txt")
        try "outside file remains untouched".write(to: outside, atomically: true, encoding: .utf8)
        let outsideHash = try sha256(outside)

        let traversalArchive = folder.appendingPathComponent("path-traversal.zip")
        let traversalFixture = try ProcessRunner.run(
            executable: zipTool,
            arguments: ["-q", traversalArchive.path, "../outside.txt"],
            currentDirectory: archiveSource
        )
        try expect(traversalFixture.status == 0, "Could not create traversal ZIP fixture: \(traversalFixture.stderr)")
        let traversalListing = try ProcessRunner.run(executable: unzip, arguments: ["-Z1", traversalArchive.path])
        try expect(traversalListing.status == 0 && traversalListing.stdout.contains("../outside.txt"), "Traversal ZIP fixture does not contain its unsafe path")
        let traversalOutput = folder.appendingPathComponent("traversal-output", isDirectory: true)
        try expectZIPExtractionRejected(traversalArchive, outputDirectory: traversalOutput, message: "ZIP extraction accepted a parent-traversal path")
        try expect(!FileManager.default.fileExists(atPath: traversalOutput.path), "Rejected traversal archive created an output directory")
        try expect(try sha256(outside) == outsideHash, "Rejected traversal archive changed a file outside its output")

        let link = archiveSource.appendingPathComponent("escape-link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
        let linkArchive = folder.appendingPathComponent("symlink-escape.zip")
        let linkFixture = try ProcessRunner.run(
            executable: zipTool,
            arguments: ["-qy", linkArchive.path, "escape-link"],
            currentDirectory: archiveSource
        )
        try expect(linkFixture.status == 0, "Could not create symlink ZIP fixture: \(linkFixture.stderr)")
        let linkListing = try ProcessRunner.run(executable: unzip, arguments: ["-Z1", linkArchive.path])
        try expect(linkListing.status == 0 && linkListing.stdout.contains("escape-link"), "Symlink ZIP fixture is missing its link")
        let linkOutput = folder.appendingPathComponent("symlink-output", isDirectory: true)
        try expectZIPExtractionRejected(linkArchive, outputDirectory: linkOutput, message: "ZIP extraction accepted a link that escapes its output folder")
        try expect(!FileManager.default.fileExists(atPath: linkOutput.path), "Rejected symlink archive left an extraction folder")
        try expect(try sha256(outside) == outsideHash, "Rejected symlink archive changed its target")
    }

    private func expectZIPExtractionRejected(_ archive: URL, outputDirectory: URL, message: String) throws {
        do {
            _ = try MorphFileOperations.extractZIP(archive, outputDirectory: outputDirectory)
            throw CheckFailure(message)
        } catch let failure as CheckFailure {
            throw failure
        } catch let error as MorphError {
            guard case .invalidInput = error else {
                throw CheckFailure("ZIP extraction failed for an unexpected reason: \(error.localizedDescription)")
            }
        } catch {
            throw CheckFailure("ZIP extraction failed for an unexpected reason: \(error.localizedDescription)")
        }
    }

    private func checkFileOperations(_ folder: URL) throws {
        let output = folder.appendingPathComponent("output", isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

        let image = folder.appendingPathComponent("resize-me.png")
        try makePNG(at: image, width: 160, height: 80)
        let imageHash = try sha256(image)
        let resized = try MorphFileOperations.resizeImage(image, scale: 0.5, outputDirectory: output)
        guard let resizedSource = CGImageSourceCreateWithURL(resized as CFURL, nil),
              let resizedProperties = CGImageSourceCopyPropertiesAtIndex(resizedSource, 0, nil) as? [CFString: Any] else {
            throw CheckFailure("Resized image did not decode")
        }
        try expect((resizedProperties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue == 80, "Resize width is wrong")
        try expect((resizedProperties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue == 40, "Resize height is wrong")
        try expect(try sha256(image) == imageHash, "Resize changed the original image")

        let imageAlias = folder.appendingPathComponent("resize-alias.png")
        try FileManager.default.createSymbolicLink(at: imageAlias, withDestinationURL: image)
        do {
            _ = try MorphFileOperations.resizeImage(imageAlias, scale: 0.5, outputDirectory: output)
            throw CheckFailure("Image resize followed a symbolic-link input")
        } catch is CheckFailure {
            throw CheckFailure("Image resize followed a symbolic-link input")
        } catch { }

        let longName = String(repeating: "long-name-", count: 21) + ".png"
        let longImage = folder.appendingPathComponent(longName)
        try makePNG(at: longImage, width: 24, height: 16)
        let longResized = try MorphFileOperations.resizeImage(longImage, scale: 0.5, outputDirectory: output)
        try expect(longResized.lastPathComponent.utf8.count < 255, "Resize staging failed for a long but valid source filename")
        try expect(CGImageSourceCreateWithURL(longResized as CFURL, nil) != nil, "Long-filename resize output is not a valid image")

        let firstPDF = folder.appendingPathComponent("first.pdf")
        let secondPDF = folder.appendingPathComponent("second.pdf")
        try makeTextPDF(at: firstPDF, text: "First page")
        try makeTextPDF(at: secondPDF, text: "Second page")
        let firstHash = try sha256(firstPDF)
        let secondHash = try sha256(secondPDF)
        let merged = try MorphFileOperations.mergePDFs([firstPDF, secondPDF], outputDirectory: output)
        try expect(PDFDocument(url: merged)?.pageCount == 2, "Merged PDF should contain two pages")
        let split = try MorphFileOperations.splitPDF(merged, outputDirectory: output)
        try expect(split.count == 2 && split.allSatisfy { PDFDocument(url: $0)?.pageCount == 1 }, "Split PDF should produce two one-page documents")
        try expect(try sha256(firstPDF) == firstHash && sha256(secondPDF) == secondHash, "PDF inputs changed")
        let beforeCancelledSplit = try FileManager.default.contentsOfDirectory(atPath: output.path).sorted()
        let cancelledSplit = CancellationToken()
        cancelledSplit.cancel()
        do {
            _ = try MorphFileOperations.splitPDF(merged, outputDirectory: output, cancellation: cancelledSplit)
            throw CheckFailure("Cancelled PDF splitting unexpectedly completed")
        } catch is CheckFailure {
            throw CheckFailure("Cancelled PDF splitting unexpectedly completed")
        } catch { }
        try expect(try FileManager.default.contentsOfDirectory(atPath: output.path).sorted() == beforeCancelledSplit, "Cancelled PDF split left a partial page file")

        let sourceFolder = folder.appendingPathComponent("zip-source", isDirectory: true)
        try FileManager.default.createDirectory(at: sourceFolder, withIntermediateDirectories: true)
        try "extracted safely".write(to: sourceFolder.appendingPathComponent("payload.txt"), atomically: true, encoding: .utf8)
        let zip = folder.appendingPathComponent("extract-me.zip")
        guard let zipTool = ExecutableLocator.resolve(["zip"]) else { throw CheckSkip("ZIP command is unavailable") }
        let created = try ProcessRunner.run(executable: zipTool, arguments: ["-qr", zip.path, "."], currentDirectory: sourceFolder)
        try expect(created.status == 0, "Could not create extraction fixture: \(created.stderr)")
        let zipHash = try sha256(zip)
        let beforeCancelledExtract = try FileManager.default.contentsOfDirectory(atPath: output.path).sorted()
        let cancelledExtract = CancellationToken()
        cancelledExtract.cancel()
        do {
            _ = try MorphFileOperations.extractZIP(zip, outputDirectory: output, cancellation: cancelledExtract)
            throw CheckFailure("Cancelled ZIP extraction unexpectedly completed")
        } catch let failure as CheckFailure {
            throw failure
        } catch let error as MorphError {
            guard case .cancelled = error else { throw CheckFailure("Cancelled ZIP extraction returned the wrong error") }
        }
        try expect(try FileManager.default.contentsOfDirectory(atPath: output.path).sorted() == beforeCancelledExtract, "Cancelled ZIP extraction left output behind")
        let extracted = try MorphFileOperations.extractZIP(zip, outputDirectory: output)
        let payload = extracted.appendingPathComponent("payload.txt")
        try expect(try String(contentsOf: payload, encoding: .utf8) == "extracted safely", "ZIP extraction lost file content")
        try expect(try sha256(zip) == zipHash, "ZIP source changed")

        let hiddenArchive = folder.appendingPathComponent(".config.zip")
        try FileManager.default.copyItem(at: zip, to: hiddenArchive)
        let visibleExtraction = try MorphFileOperations.extractZIP(hiddenArchive, outputDirectory: output)
        try expect(visibleExtraction.lastPathComponent == "config", "Extracting a dot-prefixed archive should not create an unexpected hidden output folder")
    }

    private func checkPDFPageImageZIP(_ folder: URL) throws {
        let first = folder.appendingPathComponent("first.pdf")
        let second = folder.appendingPathComponent("second.pdf")
        try makeTextPDF(at: first, text: "First page image content")
        try makeTextPDF(at: second, text: "Second page image content")
        let output = folder.appendingPathComponent("output", isDirectory: true)
        let source = try MorphFileOperations.mergePDFs([first, second], outputDirectory: output)
        let sourceHash = try sha256(source)
        guard let route = registry.routes.first(where: {
            $0.inputExtension == "pdf" && $0.output.fileExtension == "zip" && $0.engine == .nativePDF
        }) else {
            throw CheckFailure("The PDF page-image ZIP route was not registered")
        }
        let result = try ConversionService(registry: registry).convert(
            ConversionRequest(inputURL: source, outputFormat: route.output, outputDirectory: output)
        )
        try OutputValidator.validate(result.outputURL, format: route.output, engine: route.engine)
        try expect(PDFDocument(url: source)?.pageCount == 2, "Page-image conversion changed the source PDF")
        try expect(try sha256(source) == sourceHash, "Page-image conversion changed the PDF bytes")

        guard let unzip = ExecutableLocator.resolve(["unzip"]) else { throw CheckSkip("unzip is unavailable") }
        let listing = try ProcessRunner.run(executable: unzip, arguments: ["-Z1", result.outputURL.path])
        try expect(listing.status == 0, "The page-image ZIP could not be listed")
        try expect(listing.stdout.contains("page-1.png") && listing.stdout.contains("page-2.png"), "The page-image ZIP must contain one PNG for each PDF page")

        let extracted = folder.appendingPathComponent("rendered-pages", isDirectory: true)
        try FileManager.default.createDirectory(at: extracted, withIntermediateDirectories: true)
        let extraction = try ProcessRunner.run(executable: unzip, arguments: ["-q", result.outputURL.path, "-d", extracted.path])
        try expect(extraction.status == 0, "The page-image ZIP could not be extracted")
        let pageImages = try FileManager.default.contentsOfDirectory(at: extracted, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension.lowercased() == "png" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        try expect(pageImages.count == 2, "The page-image ZIP contains \(pageImages.count) PNGs instead of two")
        var imageHashes: [String] = []
        for imageURL in pageImages {
            guard let imageSource = CGImageSourceCreateWithURL(imageURL as CFURL, nil),
                  let image = CGImageSourceCreateImageAtIndex(imageSource, 0, nil) else {
                throw CheckFailure("Generated page image \(imageURL.lastPathComponent) is not a valid PNG")
            }
            try expect(image.width > 0 && image.height > 0, "Generated page image has empty dimensions")
            imageHashes.append(try sha256(imageURL))
        }
        try expect(Set(imageHashes).count == 2, "Different PDF pages produced identical PNG images")

        let singlePage = folder.appendingPathComponent("single-page.pdf")
        try makeTextPDF(at: singlePage, text: "Single page image content")
        let singlePageHash = try sha256(singlePage)
        let singlePageResult = try ConversionService(registry: registry).convert(
            ConversionRequest(inputURL: singlePage, outputFormat: route.output, outputDirectory: output)
        )
        try expect(singlePageResult.outputURL.pathExtension == "png", "A one-page PDF should produce a PNG rather than an archive")
        try OutputValidator.validate(singlePageResult.outputURL, format: MorphFormat("png", "PNG image", .image), engine: singlePageResult.engine)
        try expect(try sha256(singlePage) == singlePageHash, "Single-page PDF image export changed its source")
        try expect(!FileManager.default.fileExists(atPath: output.appendingPathComponent("single-page.zip").path), "A one-page PDF should not create an archive")
    }

    private func checkBatchAndCollisions(_ folder: URL) throws {
        let output = folder.appendingPathComponent("output", isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let first = folder.appendingPathComponent("same.png")
        let nested = folder.appendingPathComponent("nested", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        let second = nested.appendingPathComponent("same.tiff")
        try makePNG(at: first, width: 40, height: 30)
        try makeTIFF(at: second, width: 24, height: 18)
        let firstHash = try sha256(first)
        let secondHash = try sha256(second)
        try Data([0x01, 0x02, 0x03]).write(to: output.appendingPathComponent("same.jpg"))

        let resultA = try convert(first, to: "jpg", category: .image, output: output)
        let resultB = try convert(second, to: "jpg", category: .image, output: output)
        try expect(resultA.lastPathComponent == "same-2.jpg", "First collision was not renamed safely")
        try expect(resultB.lastPathComponent == "same-3.jpg", "Second collision was not renamed safely")
        try expect(try sha256(first) == firstHash && sha256(second) == secondHash, "Batch conversion changed an original")

        let racedOutput = output.appendingPathComponent("race-safe.jpg")
        let transaction = try PrivateOutputTransaction(outputURL: racedOutput, temporaryFileName: "race-safe.partial.jpg")
        try Data("Morph conversion result".utf8).write(to: transaction.temporaryOutputURL)
        let racedFileContents = Data("A concurrent writer owns this path".utf8)
        try racedFileContents.write(to: racedOutput)
        let uniquePublishedOutput = try transaction.publishUnique()
        try expect(uniquePublishedOutput.lastPathComponent == "race-safe-2.jpg", "A publication race did not allocate the next safe output name")
        try expect(try Data(contentsOf: racedOutput) == racedFileContents, "A publication race replaced the concurrent writer's file")
        try expect(try String(contentsOf: uniquePublishedOutput, encoding: .utf8) == "Morph conversion result", "The raced conversion did not publish its complete output")
    }

    private func checkBatchRename(_ folder: URL) throws {
        let firstFolder = folder.appendingPathComponent("first", isDirectory: true)
        let secondFolder = folder.appendingPathComponent("second", isDirectory: true)
        let output = folder.appendingPathComponent("output", isDirectory: true)
        try FileManager.default.createDirectory(at: firstFolder, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: secondFolder, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

        let first = firstFolder.appendingPathComponent("photo.png")
        let second = secondFolder.appendingPathComponent("photo.png")
        let archive = firstFolder.appendingPathComponent("bundle.tar.gz")
        try Data("first photo".utf8).write(to: first)
        try Data("second photo".utf8).write(to: second)
        try Data("archive bytes".utf8).write(to: archive)
        let sources = [first, second, archive]
        let sourceHashes = try sources.map(sha256)

        let existing = output.appendingPathComponent("Trip-001-photo.png")
        try Data("keep existing output".utf8).write(to: existing)
        let targets = try MorphFileOperations.planBatchRenamedCopies(
            inputs: sources,
            prefix: "Trip",
            outputDirectories: Array(repeating: output, count: sources.count)
        )
        try expect(targets.map { $0.outputURL.lastPathComponent } == [
            "Trip-001-2-photo.png",
            "Trip-002-photo.png",
            "Trip-003-bundle.tar.gz",
        ], "Batch rename preview did not preserve full filenames or resolve an existing collision")

        let copies = try targets.map { try MorphFileOperations.createRenamedCopy($0) }
        try expect(copies.allSatisfy { FileManager.default.fileExists(atPath: $0.path) }, "A renamed copy is missing")
        for copy in copies {
            let attributes = try FileManager.default.attributesOfItem(atPath: copy.path)
            try expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600, "Batch-renamed output should retain Morph's private 0600 mode")
        }
        try expect(try zip(copies, sources).allSatisfy { try sha256($0.0) == sha256($0.1) }, "A renamed copy did not preserve source bytes")
        try expect(try sources.map(sha256) == sourceHashes, "Batch rename changed an original")
        try expect(try String(contentsOf: existing, encoding: .utf8) == "keep existing output", "Batch rename replaced an existing destination")
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: output.path)
            .filter { $0.hasPrefix(".morph-rename-") || $0.hasSuffix(".partial") }
        try expect(leftovers.isEmpty, "Batch rename left staging files behind")

        do {
            _ = try MorphFileOperations.planBatchRenamedCopies(
                inputs: sources,
                prefix: "../escape",
                outputDirectories: Array(repeating: output, count: sources.count)
            )
            throw CheckFailure("An unsafe batch rename prefix was accepted")
        } catch is CheckFailure {
            throw CheckFailure("An unsafe batch rename prefix was accepted")
        } catch {
            try expect(try sources.map(sha256) == sourceHashes, "Invalid rename input changed a source")
        }

        let lateCollisionTarget = try MorphFileOperations.planBatchRenamedCopies(
            inputs: [first],
            prefix: "Late",
            outputDirectories: [output]
        )[0]
        try Data("arrived after preview".utf8).write(to: lateCollisionTarget.outputURL)
        do {
            _ = try MorphFileOperations.createRenamedCopy(lateCollisionTarget)
            throw CheckFailure("Batch rename replaced an output created after preview")
        } catch is CheckFailure {
            throw CheckFailure("Batch rename replaced an output created after preview")
        } catch {
            try expect(try String(contentsOf: lateCollisionTarget.outputURL, encoding: .utf8) == "arrived after preview", "A late collision was overwritten")
        }

        do {
            _ = try MorphFileOperations.createRenamedCopy(BatchRenameTarget(inputURL: first, outputURL: first))
            throw CheckFailure("Batch rename accepted the source path as its output")
        } catch is CheckFailure {
            throw CheckFailure("Batch rename accepted the source path as its output")
        } catch {
            try expect(try sha256(first) == sourceHashes[0], "Refusing an output-over-source target changed the source")
        }

        let cancelledTarget = try MorphFileOperations.planBatchRenamedCopies(
            inputs: [first],
            prefix: "Cancelled",
            outputDirectories: [output]
        )[0]
        let cancelled = CancellationToken()
        cancelled.cancel()
        do {
            _ = try MorphFileOperations.createRenamedCopy(cancelledTarget, cancellation: cancelled)
            throw CheckFailure("A cancelled batch rename created an output")
        } catch MorphError.cancelled {
            try expect(!FileManager.default.fileExists(atPath: cancelledTarget.outputURL.path), "Cancelled rename left an output")
        } catch is CheckFailure {
            throw CheckFailure("A cancelled batch rename created an output")
        } catch {
            throw CheckFailure("Cancellation returned an unexpected error: \(error.localizedDescription)")
        }

        let selectedFolder = folder.appendingPathComponent("selected-output", isDirectory: true)
        let movedFolder = folder.appendingPathComponent("moved-output", isDirectory: true)
        try FileManager.default.createDirectory(at: selectedFolder, withIntermediateDirectories: false)
        let movedTarget = try MorphFileOperations.planBatchRenamedCopies(
            inputs: [first],
            prefix: "Moved",
            outputDirectories: [selectedFolder]
        )[0]
        do {
            _ = try MorphFileOperations.createRenamedCopy(
                movedTarget,
                cancellation: nil,
                beforePublication: {
                    try FileManager.default.moveItem(at: selectedFolder, to: movedFolder)
                    try FileManager.default.createDirectory(at: selectedFolder, withIntermediateDirectories: false)
                }
            )
            throw CheckFailure("Batch rename reported success after its output folder moved")
        } catch is CheckFailure {
            throw CheckFailure("Batch rename reported success after its output folder moved")
        } catch MorphError.invalidOutput { }
        try expect(try FileManager.default.contentsOfDirectory(atPath: selectedFolder.path).isEmpty, "Batch rename wrote into a replacement output folder")
        try expect(try FileManager.default.contentsOfDirectory(atPath: movedFolder.path).isEmpty, "Batch rename wrote into the moved output folder after its path changed")
        try expect(try sha256(first) == sourceHashes[0], "Batch rename changed its source while rejecting a moved output folder")

        let symbolicLink = folder.appendingPathComponent("linked-photo.png")
        try FileManager.default.createSymbolicLink(at: symbolicLink, withDestinationURL: first)
        do {
            _ = try MorphFileOperations.planBatchRenamedCopies(
                inputs: [symbolicLink],
                prefix: "Trip",
                outputDirectories: [output]
            )
            throw CheckFailure("A symbolic-link input was accepted for batch rename")
        } catch is CheckFailure {
            throw CheckFailure("A symbolic-link input was accepted for batch rename")
        } catch { }

        try expect(try sources.map(sha256) == sourceHashes, "A failed or cancelled rename changed an original")
        let remainingStaging = try FileManager.default.contentsOfDirectory(atPath: output.path)
            .filter { $0.hasPrefix(".morph-rename-") || $0.hasSuffix(".partial") }
        try expect(remainingStaging.isEmpty, "A failed or cancelled rename left staging files")
    }

    private func checkMetadataInspection(_ folder: URL) throws {
        let image = folder.appendingPathComponent("metadata-image.png")
        try makePNG(at: image, width: 52, height: 34)
        let imageHash = try sha256(image)
        let imageEntries = try MorphFileOperations.inspectMetadata(image)
        let imageFields = Dictionary(uniqueKeysWithValues: imageEntries.map { ($0.label, $0.value) })
        try expect(imageFields["Name"] == image.lastPathComponent, "Image metadata omitted its filename")
        try expect(imageFields["Dimensions"] == "52 × 34 pixels", "Image metadata reported incorrect dimensions")
        try expect(imageFields["File size"] != nil, "Image metadata omitted file size")
        try expect(try sha256(image) == imageHash, "Metadata inspection changed the image")

        let pdf = folder.appendingPathComponent("metadata-document.pdf")
        try makeTextPDF(at: pdf, text: "Metadata stays local")
        guard let document = PDFDocument(url: pdf) else { throw CheckFailure("Could not reopen PDF fixture") }
        document.documentAttributes = [
            PDFDocumentAttribute.titleAttribute: "Morph metadata fixture",
            PDFDocumentAttribute.authorAttribute: "Morph Checks",
        ]
        try expect(document.write(to: pdf), "Could not write PDF metadata fixture")
        let pdfHash = try sha256(pdf)
        let pdfEntries = try MorphFileOperations.inspectMetadata(pdf)
        let pdfFields = Dictionary(uniqueKeysWithValues: pdfEntries.map { ($0.label, $0.value) })
        try expect(pdfFields["Pages"] == "1", "PDF metadata reported an incorrect page count")
        try expect(pdfFields["Title"] == "Morph metadata fixture", "PDF title metadata was not reported")
        try expect(pdfFields["Author"] == "Morph Checks", "PDF author metadata was not reported")
        try expect(try sha256(pdf) == pdfHash, "Metadata inspection changed the PDF")

        let invalidImage = folder.appendingPathComponent("invalid.png")
        try Data("not an image".utf8).write(to: invalidImage)
        let invalidHash = try sha256(invalidImage)
        do {
            _ = try MorphFileOperations.inspectMetadata(invalidImage)
            throw CheckFailure("Invalid image metadata was accepted")
        } catch is CheckFailure {
            throw CheckFailure("Invalid image metadata was accepted")
        } catch {
            try expect(try sha256(invalidImage) == invalidHash, "Failed inspection changed invalid input")
        }
    }

    private func checkMetadataEditing(_ folder: URL) throws {
        let output = folder.appendingPathComponent("output", isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let imageEdits = FileMetadataEdits(
            title: "Updated Morph title",
            subject: "Locally edited metadata",
            keywords: ["morph", "local"]
        )
        let pdfEdits = FileMetadataEdits(
            title: "Updated Morph title",
            author: "Morph Checks",
            subject: "Locally edited metadata",
            keywords: ["morph", "local"]
        )

        let png = folder.appendingPathComponent("source.png")
        try makePNG(at: png, width: 52, height: 34)
        let pngHash = try sha256(png)
        do {
            _ = try MorphFileOperations.writeMetadataCopy(png, edits: imageEdits, outputDirectory: output)
            throw CheckFailure("PNG metadata editing was accepted outside the documented JPEG/TIFF scope")
        } catch is CheckFailure {
            throw CheckFailure("PNG metadata editing was accepted outside the documented JPEG/TIFF scope")
        } catch { }

        let jpeg = try convert(png, to: "jpg", category: .image, output: output)
        let tiff = try convert(png, to: "tiff", category: .image, output: output)
        let jpegHash = try sha256(jpeg)
        let tiffHash = try sha256(tiff)
        do {
            _ = try MorphFileOperations.writeMetadataCopy(
                jpeg,
                edits: FileMetadataEdits(author: "Morph Checks"),
                outputDirectory: output
            )
            throw CheckFailure("Image author editing was accepted without verified native support")
        } catch is CheckFailure {
            throw CheckFailure("Image author editing was accepted without verified native support")
        } catch { }
        let jpegCopy = try MorphFileOperations.writeMetadataCopy(jpeg, edits: imageEdits, outputDirectory: output)
        let tiffCopy = try MorphFileOperations.writeMetadataCopy(tiff, edits: imageEdits, outputDirectory: output)

        for (source, copy, sourceHash) in [(jpeg, jpegCopy, jpegHash), (tiff, tiffCopy, tiffHash)] {
            try expect(FileManager.default.fileExists(atPath: copy.path), "Image metadata output is missing")
            let attributes = try FileManager.default.attributesOfItem(atPath: copy.path)
            try expect((attributes[.size] as? NSNumber)?.int64Value ?? 0 > 0, "Image metadata output is empty")
            guard let sourceImage = CGImageSourceCreateWithURL(source as CFURL, nil),
                  let editedImage = CGImageSourceCreateWithURL(copy as CFURL, nil),
                  let properties = CGImageSourceCopyPropertiesAtIndex(editedImage, 0, nil) as? [CFString: Any] else {
                throw CheckFailure("Edited JPEG/TIFF could not be reopened")
            }
            try expect(CGImageSourceGetType(sourceImage) == CGImageSourceGetType(editedImage), "Metadata editing changed the image format")
            try expect(CGImageSourceGetCount(sourceImage) == CGImageSourceGetCount(editedImage), "Metadata editing changed the image frame count")
            try expect((properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue == 52, "Metadata editing changed image width")
            try expect((properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue == 34, "Metadata editing changed image height")
            let imageFields = Dictionary(uniqueKeysWithValues: try MorphFileOperations.inspectMetadata(copy).map { ($0.label, $0.value) })
            try expect(imageFields["Title"] == imageEdits.title, "Image title metadata was not retained")
            try expect(imageFields["Subject"] == imageEdits.subject, "Image subject metadata was not retained")
            try expect(imageFields["Keywords"] != nil, "Image keywords were not retained")
            try expect(try sha256(source) == sourceHash, "Metadata editing changed the original image")
        }

        let jpegCopyHash = try sha256(jpegCopy)
        let jpegCollisionCopy = try MorphFileOperations.writeMetadataCopy(jpeg, edits: imageEdits, outputDirectory: output)
        try expect(jpegCollisionCopy != jpegCopy, "Metadata editing reused an existing output path")
        try expect(try sha256(jpegCopy) == jpegCopyHash, "A collision changed an existing metadata output")
        try expect(try sha256(png) == pngHash, "A rejected PNG edit changed the original")

        let pdf = folder.appendingPathComponent("source.pdf")
        try makeTextPDF(at: pdf, text: "Metadata copy preserves page text")
        let pdfHash = try sha256(pdf)
        let pdfCopy = try MorphFileOperations.writeMetadataCopy(pdf, edits: pdfEdits, outputDirectory: output)
        guard let sourceDocument = PDFDocument(url: pdf),
              let editedDocument = PDFDocument(url: pdfCopy),
              let firstPageText = editedDocument.page(at: 0)?.string else {
            throw CheckFailure("Edited PDF could not be reopened or has no first page")
        }
        let pdfAttributes = editedDocument.documentAttributes ?? [:]
        try expect(sourceDocument.pageCount == editedDocument.pageCount, "Metadata editing changed the PDF page count")
        try expect(firstPageText.contains("Metadata copy preserves page text"), "Metadata editing changed PDF page text")
        try expect(pdfAttributes[PDFDocumentAttribute.titleAttribute] as? String == pdfEdits.title, "PDF title was not retained")
        try expect(pdfAttributes[PDFDocumentAttribute.authorAttribute] as? String == pdfEdits.author, "PDF author was not retained")
        try expect(pdfAttributes[PDFDocumentAttribute.subjectAttribute] as? String == pdfEdits.subject, "PDF subject was not retained")
        try expect(pdfAttributes[PDFDocumentAttribute.keywordsAttribute] as? [String] == pdfEdits.keywords, "PDF keywords were not retained")
        try expect(try sha256(pdf) == pdfHash, "Metadata editing changed the original PDF")

        do {
            _ = try MorphFileOperations.writeMetadataCopy(jpeg, edits: FileMetadataEdits(), outputDirectory: output)
            throw CheckFailure("An empty metadata edit created an output")
        } catch is CheckFailure {
            throw CheckFailure("An empty metadata edit created an output")
        } catch { }

        let invalidJPEG = folder.appendingPathComponent("invalid.jpg")
        try Data("not an image".utf8).write(to: invalidJPEG)
        let invalidHash = try sha256(invalidJPEG)
        do {
            _ = try MorphFileOperations.writeMetadataCopy(invalidJPEG, edits: imageEdits, outputDirectory: output)
            throw CheckFailure("Invalid JPEG metadata input was accepted")
        } catch is CheckFailure {
            throw CheckFailure("Invalid JPEG metadata input was accepted")
        } catch {
            try expect(try sha256(invalidJPEG) == invalidHash, "Failed metadata editing changed invalid input")
        }

        let leftovers = try FileManager.default.contentsOfDirectory(atPath: output.path)
            .filter { $0.contains(".morph-") || $0.hasSuffix(".partial") }
        try expect(leftovers.isEmpty, "Metadata editing left staging files: \(leftovers)")
    }

    private func checkPDFPageRangeExtraction(_ folder: URL) throws {
        try expect(try MorphFileOperations.parsePDFPageRanges(" 1 - 2, 4 ", pageCount: 5) == [1, 2, 4], "Page-range parser did not preserve the requested order")
        for invalidSelection in ["", "0", "3", "2-1", "1, 1", "1,,2", "a"] {
            do {
                _ = try MorphFileOperations.parsePDFPageRanges(invalidSelection, pageCount: 2)
                throw CheckFailure("Invalid PDF page selection was accepted: \(invalidSelection)")
            } catch is CheckFailure {
                throw CheckFailure("Invalid PDF page selection was accepted: \(invalidSelection)")
            } catch { }
        }

        let first = folder.appendingPathComponent("first.pdf")
        let second = folder.appendingPathComponent("second.pdf")
        try makeTextPDF(at: first, text: "First selected page")
        try makeTextPDF(at: second, text: "Second selected page")
        let source = try MorphFileOperations.mergePDFs([first, second], outputDirectory: folder)
        let sourceHash = try sha256(source)
        let cancelledDirectory = folder.appendingPathComponent("cancelled-pages", isDirectory: true)
        let cancelledToken = CancellationToken()
        cancelledToken.cancel()
        do {
            _ = try MorphFileOperations.extractPDFPages(source, pageRange: "1-2", outputDirectory: cancelledDirectory, cancellation: cancelledToken)
            throw CheckFailure("Cancelled PDF page extraction unexpectedly completed")
        } catch let failure as CheckFailure {
            throw failure
        } catch let error as MorphError {
            guard case .cancelled = error else { throw CheckFailure("Cancelled PDF page extraction returned the wrong error") }
        }
        try expect(!FileManager.default.fileExists(atPath: cancelledDirectory.path), "Cancelled PDF page extraction created an output folder")
        let extracted = try MorphFileOperations.extractPDFPages(source, pageRange: "2, 1", outputDirectory: folder)
        guard let result = PDFDocument(url: extracted), result.pageCount == 2 else {
            throw CheckFailure("Extracted PDF did not contain both requested pages")
        }
        try expect(result.page(at: 0)?.string?.contains("Second selected page") == true, "Extracted page order did not match the selection")
        try expect(result.page(at: 1)?.string?.contains("First selected page") == true, "Second extracted page did not match the selection")
        try expect(try sha256(source) == sourceHash, "Page extraction changed the source PDF")
        let collision = try MorphFileOperations.extractPDFPages(source, pageRange: "1", outputDirectory: folder)
        try expect(collision != extracted && PDFDocument(url: collision)?.pageCount == 1, "Page extraction did not create a collision-safe output")
    }

    private func checkInvalidInput(_ folder: URL) throws {
        let input = folder.appendingPathComponent("bad.png")
        let output = folder.appendingPathComponent("output", isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        try Data("not an image".utf8).write(to: input)
        let originalHash = try sha256(input)
        do {
            _ = try convert(input, to: "jpg", category: .image, output: output)
            throw CheckFailure("Invalid image unexpectedly converted")
        } catch is CheckFailure {
            throw CheckFailure("Invalid image unexpectedly converted")
        } catch {
            try expect(try sha256(input) == originalHash, "Invalid input was modified")
            let files = try FileManager.default.contentsOfDirectory(atPath: output.path)
            try expect(files.isEmpty, "Failed conversion left a partial output")
        }
    }

    private func checkPrivateOutputStaging(_ folder: URL) throws {
        let input = folder.appendingPathComponent("source.png")
        try makePNG(at: input, width: 16, height: 12)
        let originalHash = try sha256(input)

        let shared = folder.appendingPathComponent("shared", isDirectory: true)
        try FileManager.default.createDirectory(at: shared, withIntermediateDirectories: true)
        guard chmod(shared.path, mode_t(0o777)) == 0 else { throw CheckFailure("Could not make the shared conversion-output fixture") }
        do {
            _ = try convert(input, to: "jpg", category: .image, output: shared)
            throw CheckFailure("Conversion accepted a non-sticky shared output folder")
        } catch is CheckFailure {
            throw CheckFailure("Conversion accepted a non-sticky shared output folder")
        } catch MorphError.invalidOutput { }
        try expect((try FileManager.default.contentsOfDirectory(atPath: shared.path)).isEmpty, "Rejected shared output acquired a staging entry")

        let inheriting = folder.appendingPathComponent("inheriting", isDirectory: true)
        try FileManager.default.createDirectory(at: inheriting, withIntermediateDirectories: true)
        let chmodTool = URL(fileURLWithPath: "/bin/chmod")
        let aclResult = try ProcessRunner.run(
            executable: chmodTool,
            arguments: ["+a", "everyone allow read,file_inherit,directory_inherit", inheriting.path]
        )
        try expect(aclResult.status == 0, "Could not create the inherited-read ACL fixture: \(aclResult.stderr)")
        do {
            _ = try convert(input, to: "jpg", category: .image, output: inheriting)
            throw CheckFailure("Conversion accepted an output folder that inherits reader access to temporary files")
        } catch is CheckFailure {
            throw CheckFailure("Conversion accepted an output folder that inherits reader access to temporary files")
        } catch MorphError.invalidOutput { }
        try expect((try FileManager.default.contentsOfDirectory(atPath: inheriting.path)).isEmpty, "Rejected ACL output acquired a staging entry")
        try expect(try sha256(input) == originalHash, "Rejected conversions changed the source image")

        for permission in ["add_file", "add_subdirectory", "delete_child", "writesecurity"] {
            let aclFolder = folder.appendingPathComponent("acl-\(permission)", isDirectory: true)
            try FileManager.default.createDirectory(at: aclFolder, withIntermediateDirectories: true)
            let aclResult = try ProcessRunner.run(
                executable: chmodTool,
                arguments: ["+a", "everyone allow \(permission)", aclFolder.path]
            )
            try expect(aclResult.status == 0, "Could not create the \(permission) ACL fixture: \(aclResult.stderr)")
            let descriptor = aclFolder.path.withCString { open($0, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW) }
            guard descriptor >= 0 else { throw CheckFailure("Could not open the \(permission) ACL fixture") }
            defer { close(descriptor) }
            do {
                try OutputDirectorySecurity.validate(descriptor)
                throw CheckFailure("Output-directory validation accepted an ACL grant for \(permission)")
            } catch let failure as CheckFailure {
                throw failure
            } catch MorphError.invalidOutput { }
        }

        try expect(
            ArchivePathCollision.key("Folder/Report.txt", caseSensitiveFileSystem: true)
                != ArchivePathCollision.key("folder/report.txt", caseSensitiveFileSystem: true),
            "Case-sensitive filesystems must permit names that differ by case"
        )
        try expect(
            ArchivePathCollision.key("Folder/Report.txt", caseSensitiveFileSystem: false)
                == ArchivePathCollision.key("folder/report.txt", caseSensitiveFileSystem: false),
            "Case-insensitive filesystems must treat names that differ by case as collisions"
        )
    }

    private func checkStaleStageCleanup(_ folder: URL) throws {
        let parentDescriptor = folder.path.withCString { open($0, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW) }
        guard parentDescriptor >= 0 else { throw CheckFailure("Could not open the staging fixture parent") }
        defer { close(parentDescriptor) }

        func makeStage(
            _ name: String,
            mode: Int16 = 0o700,
            withContents: Bool = true,
            withOwnerMarker: Bool = false
        ) throws -> URL {
            let stage = folder.appendingPathComponent(name, isDirectory: true)
            try FileManager.default.createDirectory(at: stage, withIntermediateDirectories: false)
            if withContents {
                try "private staged data".write(to: stage.appendingPathComponent("partial"), atomically: true, encoding: .utf8)
            }
            if withOwnerMarker {
                let descriptor = stage.path.withCString { open($0, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW) }
                guard descriptor >= 0 else { throw CheckFailure("Could not open the staging fixture") }
                defer { close(descriptor) }
                try StaleMorphStageCleanup.createOwnershipMarker(
                    in: parentDescriptor,
                    directoryDescriptor: descriptor,
                    directoryName: name
                )
            }
            guard chmod(stage.path, mode_t(mode)) == 0 else {
                throw CheckFailure("Could not set staging fixture permissions")
            }
            return stage
        }

        func ageDirectory(_ directory: URL, by age: TimeInterval) throws {
            var times = [timespec](repeating: timespec(tv_sec: 0, tv_nsec: 0), count: 2)
            let now = Date().timeIntervalSince1970
            times[0].tv_sec = Int(now)
            times[1].tv_sec = Int(now - age)
            let result = directory.path.withCString { path in
                times.withUnsafeBufferPointer { buffer in
                    utimensat(AT_FDCWD, path, buffer.baseAddress, 0)
                }
            }
            guard result == 0 else { throw CheckFailure("Could not age staging fixture") }
        }

        let stale = try makeStage(".morph-\(UUID().uuidString).staging", withOwnerMarker: true)
        try expect(
            !FileManager.default.fileExists(atPath: stale.appendingPathComponent(StaleMorphStageCleanup.ownershipMarkerName).path),
            "The authenticated staging marker must stay outside files an engine may archive"
        )
        try ageDirectory(stale, by: StaleMorphStageCleanup.defaultMinimumAge + 60)

        let unmarkedLookalike = try makeStage(".morph-\(UUID().uuidString).staging")
        try ageDirectory(unmarkedLookalike, by: StaleMorphStageCleanup.defaultMinimumAge + 60)

        let fresh = try makeStage(".morph-\(UUID().uuidString).staging")
        let unrelated = try makeStage("customer-data-\(UUID().uuidString)")
        let malformedName = try makeStage(".morph-not-a-uuid.staging")
        let unsafeMode = try makeStage(".morph-\(UUID().uuidString).staging", mode: 0o750)
        try ageDirectory(unsafeMode, by: StaleMorphStageCleanup.defaultMinimumAge + 60)

        let symlinkTarget = try makeStage("symlink-target")
        let symlinkName = folder.appendingPathComponent(".morph-\(UUID().uuidString).staging")
        try FileManager.default.createSymbolicLink(at: symlinkName, withDestinationURL: symlinkTarget)
        try ageDirectory(symlinkName, by: StaleMorphStageCleanup.defaultMinimumAge + 60)

        StaleMorphStageCleanup.remove(in: folder)

        let authenticatedCleanupAvailable = EngineExecutableTrust.authenticatedStageMarker(for: "cleanup-test") != nil
        let staleMarkerPath = folder.appendingPathComponent(
            StaleMorphStageCleanup.ownershipMarkerName(for: stale.lastPathComponent)
        )
        if authenticatedCleanupAvailable {
            try expect(!FileManager.default.fileExists(atPath: stale.path), "Cleanup did not remove an old, authenticated Morph staging directory")
            try expect(!FileManager.default.fileExists(atPath: staleMarkerPath.path), "Cleanup left the authenticated staging marker behind")
        } else {
            try expect(FileManager.default.fileExists(atPath: stale.path), "Cleanup removed a stale staging directory without authenticated ownership")
            try expect(FileManager.default.fileExists(atPath: staleMarkerPath.path), "Cleanup removed a marker without authenticated ownership")
        }
        for preserved in [unmarkedLookalike, fresh, unrelated, malformedName, unsafeMode, symlinkName, symlinkTarget] {
            try expect(FileManager.default.fileExists(atPath: preserved.path), "Cleanup removed a fresh, unrelated, unsafe, or symlinked path: \(preserved.lastPathComponent)")
        }
        try expect(try String(contentsOf: symlinkTarget.appendingPathComponent("partial"), encoding: .utf8) == "private staged data", "Cleanup followed a staging-name symlink and changed its target")
    }

    private func checkStageMarkerAuthentication() throws {
        let key = Data((0..<32).map(UInt8.init))
        guard let first = EngineExecutableTrust.stageMarker(for: "Morph-archive-123", keyData: key),
              let repeated = EngineExecutableTrust.stageMarker(for: "Morph-archive-123", keyData: key),
              let renamed = EngineExecutableTrust.stageMarker(for: "Morph-archive-456", keyData: key),
              let changedKey = EngineExecutableTrust.stageMarker(for: "Morph-archive-123", keyData: Data(repeating: 0xA5, count: 32)) else {
            throw CheckFailure("Could not generate a staging marker with a valid key")
        }
        try expect(first == repeated, "The same staging directory and key did not produce a stable marker")
        try expect(first != renamed, "A staging marker was not bound to its directory name")
        try expect(first != changedKey, "A staging marker was not bound to its authentication key")
        try expect(EngineExecutableTrust.stageMarker(for: "Morph-archive-123", keyData: Data(repeating: 0, count: 31)) == nil, "A short key was accepted for a staging marker")
    }

    private func checkCaseSensitiveArchiveExtraction(_ destinationRoot: URL, fixtureFolder: URL) throws {
        let destinationDescriptor = destinationRoot.path.withCString {
            open($0, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        }
        guard destinationDescriptor >= 0 else { throw CheckFailure("Could not open the case-sensitive test volume") }
        defer { close(destinationDescriptor) }
        try expect(ArchivePathCollision.isCaseSensitive(volumeDescriptor: destinationDescriptor), "The supplied test volume is not case-sensitive")

        let archive = fixtureFolder.appendingPathComponent("case-collisions.zip")
        guard let python = ExecutableLocator.resolve(["python3"]) else { throw CheckSkip("Python is unavailable for the case-collision fixture") }
        let script = "import sys, zipfile; z=zipfile.ZipFile(sys.argv[1], 'w'); z.writestr('Upper/note.txt', 'upper'); z.writestr('upper/note.txt', 'lower'); z.close()"
        let created = try ProcessRunner.run(executable: python, arguments: ["-c", script, archive.path])
        try expect(created.status == 0, "Could not create the case-collision ZIP fixture: \(created.stderr)")

        let caseInsensitiveDescriptor = fixtureFolder.path.withCString {
            open($0, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        }
        guard caseInsensitiveDescriptor >= 0 else { throw CheckFailure("Could not open the case-insensitive test volume") }
        defer { close(caseInsensitiveDescriptor) }
        try expect(!ArchivePathCollision.isCaseSensitive(volumeDescriptor: caseInsensitiveDescriptor), "The fixture folder was expected to use a case-insensitive filesystem")
        let caseInsensitiveStage = fixtureFolder.appendingPathComponent("case-insensitive-stage", isDirectory: true)
        try FileManager.default.createDirectory(at: caseInsensitiveStage, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        do {
            try ArchiveExtractor.extract(input: archive, to: caseInsensitiveStage, cancellation: CancellationToken())
            throw CheckFailure("A case-insensitive volume accepted two archive paths that differ only by case")
        } catch is CheckFailure {
            throw CheckFailure("A case-insensitive volume accepted two archive paths that differ only by case")
        } catch MorphError.invalidInput { }

        let output = destinationRoot.appendingPathComponent("morph-case-sensitive-output-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: output) }
        try ArchiveExtractor.extract(input: archive, to: output, cancellation: CancellationToken())
        let upper = output.appendingPathComponent("Upper/note.txt")
        let lower = output.appendingPathComponent("upper/note.txt")
        try expect(try String(contentsOf: upper, encoding: .utf8) == "upper", "The uppercase archive path was not preserved")
        try expect(try String(contentsOf: lower, encoding: .utf8) == "lower", "The lowercase archive path was not preserved")

        let route = ConversionRoute(
            inputExtension: "zip",
            output: MorphFormat("tar", "TAR archive", .archive),
            engine: .archive,
            description: "Case-sensitive archive conversion test"
        )
        let service = ConversionService(
            registry: EngineRegistry(
                statuses: [.archive: EngineStatus(id: .archive, supportedInputExtensions: ["zip"], supportedOutputExtensions: ["tar"])],
                routes: [route]
            ),
            engines: [ArchiveConversionEngine()]
        )
        let tar = try service.convert(ConversionRequest(inputURL: archive, outputFormat: route.output, outputDirectory: output)).outputURL
        let tarTool = try unwrap(ExecutableLocator.resolve(["tar"]), "TAR is unavailable for the case-sensitive round-trip")
        let listing = try ProcessRunner.run(executable: tarTool, arguments: ["-tf", tar.path])
        try expect(listing.status == 0 && listing.stdout.contains("Upper/note.txt") && listing.stdout.contains("upper/note.txt"), "Archive conversion did not preserve case-distinct paths")
    }

    private func checkMissingEngine(_ folder: URL) throws {
        let input = folder.appendingPathComponent("sample.wav")
        let output = folder.appendingPathComponent("output", isDirectory: true)
        try Data([0x01, 0x02]).write(to: input)
        let route = ConversionRoute(inputExtension: "wav", output: MorphFormat("mp3", "MP3", .audio), engine: .ffmpeg, description: "test route")
        let registry = EngineRegistry(statuses: [.ffmpeg: EngineStatus(id: .ffmpeg)], routes: [route])
        do {
            _ = try ConversionService(registry: registry).convert(ConversionRequest(inputURL: input, outputFormat: route.output, outputDirectory: output))
            throw CheckFailure("Missing engine was not reported")
        } catch MorphError.missingEngine(.ffmpeg) {
            try expect(!FileManager.default.fileExists(atPath: output.path), "Missing engine created an output folder")
        }
    }

    private func checkEngineFallback(_ folder: URL) throws {
        let input = folder.appendingPathComponent("fallback.png")
        let output = folder.appendingPathComponent("output", isDirectory: true)
        try makePNG(at: input, width: 32, height: 24)
        let imageMagickRoute = ConversionRoute(inputExtension: "png", output: MorphFormat("jpg", "JPEG", .image), engine: .imageMagick, description: "preferred route fails")
        let nativeRoute = ConversionRoute(inputExtension: "png", output: imageMagickRoute.output, engine: .nativeImage, description: "fallback route")
        let statuses: [EngineID: EngineStatus] = [
            .nativeImage: EngineStatus(id: .nativeImage),
            .imageMagick: EngineStatus(id: .imageMagick, executableURL: URL(fileURLWithPath: "/bin/false")),
        ]
        let registry = EngineRegistry(statuses: statuses, routes: [imageMagickRoute, nativeRoute])
        let service = ConversionService(registry: registry, engines: [AlwaysFailingEngine(id: .imageMagick)])
        let result = try service.convert(ConversionRequest(inputURL: input, outputFormat: nativeRoute.output, outputDirectory: output))
        try expect(result.engine == .nativeImage, "Conversion did not use its fallback engine")
        try expect(CGImageSourceCreateWithURL(result.outputURL as CFURL, nil) != nil, "Fallback output did not decode")
        let files = try FileManager.default.contentsOfDirectory(atPath: output.path)
        try expect(files.count == 1 && files[0] == "fallback.jpg", "Failed engine left a temporary output")
    }

    private func checkCancellation() throws {
        let token = CancellationToken()
        let completion = DispatchSemaphore(value: 0)
        let outcome = LockedOutcome()
        DispatchQueue.global().async {
            do {
                _ = try ProcessRunner.run(executable: URL(fileURLWithPath: "/bin/sleep"), arguments: ["10"], cancellation: token)
                outcome.set("unexpected success")
            } catch {
                outcome.set(error.localizedDescription)
            }
            completion.signal()
        }
        Thread.sleep(forTimeInterval: 0.2)
        token.cancel()
        try expect(completion.wait(timeout: .now() + 3) == .success, "Cancelled process did not stop promptly")
        try expect(outcome.value == MorphError.cancelled.localizedDescription, "Cancellation did not report a cancelled operation")
    }

    private func checkLargeImage(_ folder: URL) throws {
        let input = folder.appendingPathComponent("large.png")
        let output = folder.appendingPathComponent("output", isDirectory: true)
        try makePNG(at: input, width: 2048, height: 2048, noisy: true)
        let inputSize = try FileManager.default.attributesOfItem(atPath: input.path)[.size] as? NSNumber
        try expect((inputSize?.intValue ?? 0) >= 12_000_000, "Large fixture is unexpectedly small")
        let hash = try sha256(input)
        _ = try convert(input, to: "jpg", category: .image, output: output)
        try expect(try sha256(input) == hash, "Large image source changed")
    }

    private func convert(
        _ input: URL,
        to outputExtension: String,
        category: FormatCategory,
        output: URL,
        stripLocationMetadata: Bool = true
    ) throws -> URL {
        let known = Set(registry.routes.map(\.inputExtension))
        guard let inputExtension = input.morphExtension(knownExtensions: known) else { throw CheckFailure("No route recognizes \(input.lastPathComponent)") }
        guard let route = registry.routes(from: inputExtension, to: outputExtension).first else {
            throw CheckFailure("Missing conversion route: .\(inputExtension) → .\(outputExtension)")
        }
        try expect(route.output.category == category, "Unexpected output category for .\(inputExtension) → .\(outputExtension)")
        let before = try sha256(input)
        let request = ConversionRequest(
            inputURL: input,
            outputFormat: route.output,
            outputDirectory: output,
            imageQuality: 0.9,
            stripLocationMetadata: stripLocationMetadata
        )
        let result = try ConversionService(registry: registry).convert(request)
        let size = try FileManager.default.attributesOfItem(atPath: result.outputURL.path)[.size] as? NSNumber
        try expect(FileManager.default.fileExists(atPath: result.outputURL.path) && (size?.intValue ?? 0) > 0, "Output is missing or empty")
        let needsScopedExternalValidation = [.archive, .audio, .video].contains(route.output.category)
            || ([.pandoc, .libreOffice].contains(route.engine) && ["docx", "odt", "epub", "pptx", "xlsx"].contains(route.output.fileExtension))
        if needsScopedExternalValidation {
            let validationStage = try PrivateOutputStage(
                parentDirectory: FileManager.default.temporaryDirectory,
                primaryFileName: "validation.\(route.output.fileExtension)"
            )
            let validationURL = try validationStage.temporaryOutputURL()
            try FileManager.default.copyItem(at: result.outputURL, to: validationURL)
            try OutputValidator.validate(validationURL, format: route.output, engine: route.engine)
        } else {
            try OutputValidator.validate(result.outputURL, format: route.output, engine: route.engine)
        }
        try expect(try sha256(input) == before, "Input changed during conversion")
        print("  PASS  .\(inputExtension) → .\(outputExtension) via \(route.engine.displayName)")
        return result.outputURL
    }

    private func makePNG(at url: URL, width: Int, height: Int, noisy: Bool = false) throws {
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        var state: UInt32 = 0x12345678
        for index in stride(from: 0, to: pixels.count, by: 4) {
            if noisy {
                state = state &* 1_664_525 &+ 1_013_904_223
                pixels[index] = UInt8(truncatingIfNeeded: state >> 24)
                state = state &* 1_664_525 &+ 1_013_904_223
                pixels[index + 1] = UInt8(truncatingIfNeeded: state >> 24)
                state = state &* 1_664_525 &+ 1_013_904_223
                pixels[index + 2] = UInt8(truncatingIfNeeded: state >> 24)
                pixels[index + 3] = 255
            } else {
                pixels[index] = 220; pixels[index + 1] = 60; pixels[index + 2] = 40; pixels[index + 3] = 255
            }
        }
        let provider = try unwrap(CGDataProvider(data: Data(pixels) as CFData), "Could not create image data provider")
        let image = try makeImage(provider: provider, width: width, height: height)
        try writeImage(image, to: url, type: "public.png")
    }

    private func makeTIFF(at url: URL, width: Int, height: Int) throws {
        var pixels = [UInt8](repeating: 127, count: width * height * 4)
        for index in stride(from: 3, to: pixels.count, by: 4) { pixels[index] = 255 }
        let provider = try unwrap(CGDataProvider(data: Data(pixels) as CFData), "Could not create TIFF data provider")
        let image = try makeImage(provider: provider, width: width, height: height)
        try writeImage(image, to: url, type: "public.tiff")
    }

    private func makeImage(provider: CGDataProvider, width: Int, height: Int) throws -> CGImage {
        try unwrap(CGImage(
            width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent
        ), "Could not create test image")
    }

    private func writeImage(_ image: CGImage, to url: URL, type: String) throws {
        let destination = try unwrap(CGImageDestinationCreateWithURL(url as CFURL, type as CFString, 1, nil), "Could not create image destination")
        CGImageDestinationAddImage(destination, image, nil)
        try expect(CGImageDestinationFinalize(destination), "Could not write image fixture")
    }

    private func makeTextPDF(at url: URL, text: String) throws {
        var bounds = CGRect(x: 0, y: 0, width: 612, height: 792)
        let consumer = try unwrap(CGDataConsumer(url: url as CFURL), "Could not create PDF data consumer")
        let context = try unwrap(CGContext(consumer: consumer, mediaBox: &bounds, nil), "Could not create PDF context")
        context.beginPDFPage(nil)
        context.textPosition = CGPoint(x: 50, y: 700)
        let font = CTFontCreateWithName("Helvetica" as CFString, 18, nil)
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [NSAttributedString.Key(kCTFontAttributeName as String): font]))
        CTLineDraw(line, context)
        context.endPDFPage()
        context.closePDF()
    }

    private func validateWithFFprobe(_ url: URL, ffmpeg: URL) throws {
        let ffprobe = ffmpeg.deletingLastPathComponent().appendingPathComponent("ffprobe")
        let result = try ProcessRunner.run(executable: ffprobe, arguments: ["-v", "error", "-show_entries", "format=format_name", "-of", "default=noprint_wrappers=1:nokey=1", url.path])
        try expect(result.status == 0 && !result.stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, "FFprobe could not validate \(url.lastPathComponent): \(result.stderr)")
    }

    private func expectMediaMetadataPolicy(
        _ url: URL,
        ffprobe: URL,
        title: String,
        shouldKeepLocation: Bool
    ) throws {
        let result = try ProcessRunner.run(
            executable: ffprobe,
            arguments: ["-v", "error", "-show_entries", "format_tags:stream_tags", "-of", "json", url.path]
        )
        try expect(result.status == 0, "FFprobe could not inspect metadata in \(url.lastPathComponent): \(result.stderr)")
        guard let data = result.stdout.data(using: .utf8),
              let document = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CheckFailure("FFprobe returned malformed metadata for \(url.lastPathComponent)")
        }
        var tags = (document["format"] as? [String: Any])?["tags"] as? [String: String] ?? [:]
        for stream in document["streams"] as? [[String: Any]] ?? [] {
            for (key, value) in stream["tags"] as? [String: String] ?? [:] where tags[key] == nil {
                tags[key] = value
            }
        }
        let locationKeys = tags.keys.filter {
            let key = $0.lowercased()
            return key.contains("location") || key.contains("gps")
        }
        try expect(locationKeys.isEmpty == !shouldKeepLocation, "Location tags in \(url.lastPathComponent) were \(shouldKeepLocation ? "not preserved" : "not removed"): \(locationKeys)")
        try expect(tags["title"] == title, "Non-location title metadata was not preserved in \(url.lastPathComponent)")
    }

    private func findSignature(_ signature: [UInt8], in bytes: [UInt8]) -> Int? {
        guard !signature.isEmpty, bytes.count >= signature.count else { return nil }
        for index in 0...(bytes.count - signature.count) where Array(bytes[index..<(index + signature.count)]) == signature {
            return index
        }
        return nil
    }

    private func zipUnixMode(_ archive: URL, memberName: String) throws -> UInt16? {
        let bytes = [UInt8](try Data(contentsOf: archive))
        var index = findSignature([0x50, 0x4b, 0x01, 0x02], in: bytes) ?? bytes.count
        while index + 46 <= bytes.count, Array(bytes[index..<(index + 4)]) == [0x50, 0x4b, 0x01, 0x02] {
            let nameLength = Int(bytes[index + 28]) | Int(bytes[index + 29]) << 8
            let extraLength = Int(bytes[index + 30]) | Int(bytes[index + 31]) << 8
            let commentLength = Int(bytes[index + 32]) | Int(bytes[index + 33]) << 8
            let nameEnd = index + 46 + nameLength
            guard nameEnd <= bytes.count else { throw CheckFailure("ZIP central directory has a truncated filename") }
            let name = String(bytes: bytes[(index + 46)..<nameEnd], encoding: .utf8) ?? ""
            if name == memberName || name.hasSuffix("/\(memberName)") {
                let attributes = UInt32(bytes[index + 38]) | UInt32(bytes[index + 39]) << 8
                    | UInt32(bytes[index + 40]) << 16 | UInt32(bytes[index + 41]) << 24
                return UInt16((attributes >> 16) & 0xffff)
            }
            index += 46 + nameLength + extraLength + commentLength
        }
        return nil
    }

    private func putUInt32(_ value: Int, at index: Int, in bytes: inout [UInt8]) {
        let value = UInt32(value)
        for offset in 0..<4 { bytes[index + offset] = UInt8((value >> (offset * 8)) & 0xff) }
    }

    private func sha256(_ url: URL) throws -> String {
        SHA256.hash(data: try Data(contentsOf: url)).map { String(format: "%02x", $0) }.joined()
    }

    private func expect(_ condition: Bool, _ message: String) throws {
        if !condition { throw CheckFailure(message) }
    }

    private func unwrap<T>(_ value: T?, _ message: String) throws -> T {
        guard let value else { throw CheckFailure(message) }
        return value
    }

    private func slug(_ name: String) -> String { name.lowercased().replacingOccurrences(of: " ", with: "-") }
}

struct CheckSkip: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

private final class LockedOutcome: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: String?
    var value: String? { lock.lock(); defer { lock.unlock() }; return storage }
    func set(_ value: String) { lock.lock(); storage = value; lock.unlock() }
}

private final class LockedEventLog: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []
    var values: [String] { lock.lock(); defer { lock.unlock() }; return storage }
    func append(_ event: String) { lock.lock(); storage.append(event); lock.unlock() }
}

private struct AlwaysFailingEngine: ConversionEngine {
    let id: EngineID
    func convert(context: ConversionContext) throws {
        throw MorphError.processFailed("Intentional fallback test failure")
    }
}

private struct OutputFolderMovingEngine: ConversionEngine {
    let id: EngineID = .nativeImage
    let selectedOutput: URL
    let movedOutput: URL

    func convert(context: ConversionContext) throws {
        guard context.request.outputDirectory.standardizedFileURL.path
                != selectedOutput.standardizedFileURL.path else {
            throw CheckFailure("Conversion exposed the selected output folder to an engine.")
        }
        try FileManager.default.moveItem(at: selectedOutput, to: movedOutput)
        try FileManager.default.createDirectory(at: selectedOutput, withIntermediateDirectories: true)
        try NativeImageEngine.convert(
            input: context.request.inputURL,
            output: context.temporaryOutputURL,
            quality: context.request.imageQuality
        )
    }
}

private func runExternalEngineSandboxProbe(_ arguments: [String]) -> Never {
    guard arguments.count == 9 else { Darwin.exit(30) }
    let input = URL(fileURLWithPath: arguments[2])
    let output = URL(fileURLWithPath: arguments[3])
    let outsideRead = URL(fileURLWithPath: arguments[4])
    let outsideWrite = URL(fileURLWithPath: arguments[5])
    let homeFixture = URL(fileURLWithPath: arguments[6])
    let hardLink = URL(fileURLWithPath: arguments[7])
    let clone = URL(fileURLWithPath: arguments[8])

    guard (try? String(contentsOf: input, encoding: .utf8)) == "approved input" else { Darwin.exit(31) }
    guard (try? Data("scoped-output".utf8).write(to: output)) != nil else { Darwin.exit(32) }
    if (try? Data(contentsOf: outsideRead)) != nil { Darwin.exit(33) }
    if (try? Data("denied".utf8).write(to: outsideWrite)) != nil { Darwin.exit(34) }
    if (try? Data(contentsOf: homeFixture)) != nil { Darwin.exit(52) }

    let linkStatus = homeFixture.path.withCString { source in
        hardLink.path.withCString { destination in Darwin.link(source, destination) }
    }
    if linkStatus == 0 {
        _ = hardLink.path.withCString { Darwin.unlink($0) }
        Darwin.exit(37)
    }
    guard errno == EPERM || errno == EACCES else { Darwin.exit(38) }

    let cloneStatus = homeFixture.path.withCString { source in
        clone.path.withCString { destination in clonefile(source, destination, 0) }
    }
    if cloneStatus == 0 {
        _ = clone.path.withCString { Darwin.unlink($0) }
        Darwin.exit(39)
    }
    guard errno == EPERM || errno == EACCES else { Darwin.exit(49) }

    let forked = morph_sandbox_attempt_fork()
    if forked == 0 { Darwin.exit(0) }
    if forked > 0 {
        _ = kill(forked, SIGKILL)
        _ = waitpid(forked, nil, 0)
        Darwin.exit(50)
    }
    guard errno == EPERM || errno == EACCES else { Darwin.exit(51) }
    if morph_sandbox_check_unfiltered("process-fork") != 1 { Darwin.exit(53) }
    if kill(getpid(), 0) != 0 { Darwin.exit(60) }
    let otherProcessSignalCheck = kill(getppid(), 0)
    if otherProcessSignalCheck == 0 { Darwin.exit(61) }
    guard errno == EPERM || errno == EACCES else { Darwin.exit(62) }

    var processID: pid_t = 0
    var childArguments: [UnsafeMutablePointer<CChar>?] = [strdup("true"), nil]
    defer { childArguments.compactMap { $0 }.forEach { free($0) } }
    var childEnvironment: [UnsafeMutablePointer<CChar>?] = [nil]
    let spawnStatus = "/usr/bin/true".withCString { path in
        childArguments.withUnsafeMutableBufferPointer { argv in
            childEnvironment.withUnsafeMutableBufferPointer { envp in
                posix_spawn(&processID, path, nil, nil, argv.baseAddress!, envp.baseAddress!)
            }
        }
    }
    if spawnStatus == 0 {
        _ = kill(processID, SIGKILL)
        _ = waitpid(processID, nil, 0)
        Darwin.exit(35)
    }
    guard spawnStatus == EPERM || spawnStatus == EACCES else { Darwin.exit(36) }
    Darwin.exit(EXIT_SUCCESS)
}

private func runExternalEngineSandboxNetworkProbe(_ arguments: [String]) -> Never {
    guard arguments.count >= 6 else { Darwin.exit(30) }
    let preferenceDomain = arguments[2] as CFString
    let readKey = arguments[3] as CFString
    let preferenceMarker = arguments[4]
    let writeKey = arguments[5] as CFString
    for service in [
        "com.apple.cfprefsd.daemon",
        "com.apple.cfprefsd.agent",
        "com.apple.pasteboard.1",
        "com.apple.windowserver.active",
        "com.apple.CARenderServer",
    ] where morph_sandbox_check_global_name("mach-lookup", service) != 1 {
        Darwin.exit(55)
    }
    for domain in ["com.apple.Terminal", "com.lakshaychawla.Morph"] {
        if morph_sandbox_check_preference_domain("user-preference-read", domain) != 1 { Darwin.exit(56) }
        if morph_sandbox_check_preference_domain("user-preference-write", domain) != 1 { Darwin.exit(57) }
    }
    if morph_sandbox_check_unfiltered("appleevent-send") != 1 { Darwin.exit(58) }
    if morph_sandbox_check_unfiltered("lsopen") != 1 { Darwin.exit(59) }

    for service in arguments.dropFirst(6) where morph_sandbox_attempt_mach_lookup(service) == KERN_SUCCESS {
        Darwin.exit(63)
    }
    if (CFPreferencesCopyAppValue(readKey, preferenceDomain) as? String) == preferenceMarker { Darwin.exit(64) }
    CFPreferencesSetAppValue(writeKey, preferenceMarker as CFString, preferenceDomain)
    _ = CFPreferencesAppSynchronize(preferenceDomain)

    let homeDescriptor = NSHomeDirectory().withCString { open($0, O_RDONLY | O_DIRECTORY | O_CLOEXEC) }
    if homeDescriptor >= 0 {
        close(homeDescriptor)
        Darwin.exit(40)
    }
    guard errno == EPERM || errno == EACCES else { Darwin.exit(41) }

    let server = socket(AF_INET, SOCK_STREAM, 0)
    guard server >= 0 else { Darwin.exit(42) }
    defer { close(server) }
    var localAddress = sockaddr_in()
    localAddress.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    localAddress.sin_family = sa_family_t(AF_INET)
    localAddress.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
    localAddress.sin_port = 0
    let bindStatus = withUnsafePointer(to: &localAddress) { address in
        address.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            Darwin.bind(server, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
        }
    }
    if bindStatus == 0 {
        let listenStatus = Darwin.listen(server, 1)
        if listenStatus == 0 { Darwin.exit(43) }
        guard errno == EPERM || errno == EACCES else { Darwin.exit(44) }
    } else {
        guard errno == EPERM || errno == EACCES else { Darwin.exit(45) }
    }

    let client = socket(AF_INET, SOCK_DGRAM, 0)
    guard client >= 0 else { Darwin.exit(46) }
    defer { close(client) }
    var remoteAddress = sockaddr_in()
    remoteAddress.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    remoteAddress.sin_family = sa_family_t(AF_INET)
    remoteAddress.sin_port = in_port_t(53).bigEndian
    remoteAddress.sin_addr = in_addr(s_addr: inet_addr("1.1.1.1"))
    let payload: [UInt8] = [0x4d]
    let sent = payload.withUnsafeBufferPointer { buffer in
        withUnsafePointer(to: &remoteAddress) { address in
            address.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.sendto(client, buffer.baseAddress, buffer.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
    }
    if sent >= 0 { Darwin.exit(47) }
    guard errno == EPERM || errno == EACCES else { Darwin.exit(48) }
    Darwin.exit(EXIT_SUCCESS)
}

private func engineVersionFixtureBanner() -> String? {
    let executable = URL(fileURLWithPath: CommandLine.arguments[0])
    let directoryName = executable.deletingLastPathComponent().lastPathComponent
    guard directoryName.hasPrefix("morph-engine-fixture-") else { return nil }
    return switch String(directoryName.dropFirst("morph-engine-fixture-".count)) {
    case "ffmpeg-stale": "ffmpeg version 8.1.1"
    case "ffprobe-stale": "ffprobe version 8.1.1"
    case "ffprobe-safe": "ffprobe version 9.0.2"
    case "ffprobe-mismatched": "ffmpeg version 9.0.2"
    case "pandoc-stale": "pandoc 3.13"
    case "ghostscript-stale": "10.07.0"
    case "sevenzip-stale": "7-Zip (z) 26.05 (arm64)"
    default: nil
    }
}

if let banner = engineVersionFixtureBanner() {
    print(banner)
    Darwin.exit(EXIT_SUCCESS)
} else if CommandLine.arguments.count == 9, CommandLine.arguments[1] == "--external-engine-sandbox-probe" {
    runExternalEngineSandboxProbe(CommandLine.arguments)
} else if CommandLine.arguments.count >= 2, CommandLine.arguments[1] == "--external-engine-sandbox-network-probe" {
    runExternalEngineSandboxNetworkProbe(CommandLine.arguments)
} else if CommandLine.arguments.count == 3, CommandLine.arguments[1] == "--inspect-acl-write-grant" {
    let descriptor = CommandLine.arguments[2].withCString { open($0, O_RDONLY | O_CLOEXEC | O_NOFOLLOW) }
    guard descriptor >= 0 else {
        FileHandle.standardError.write(Data("Could not open the ACL fixture.\n".utf8))
        Darwin.exit(EXIT_FAILURE)
    }
    defer { close(descriptor) }
    let status = morph_acl_has_write_grant(descriptor)
    FileHandle.standardOutput.write(Data("\(status)\n".utf8))
    Darwin.exit(status < 0 ? EXIT_FAILURE : EXIT_SUCCESS)
} else if CommandLine.arguments.count == 3, CommandLine.arguments[1] == "--check-history-fifo" {
    do {
        _ = try ConversionHistoryStore.load(from: URL(fileURLWithPath: CommandLine.arguments[2]))
        FileHandle.standardError.write(Data("A FIFO was unexpectedly accepted as conversion history.\n".utf8))
        Darwin.exit(EXIT_FAILURE)
    } catch MorphError.invalidInput {
        Darwin.exit(EXIT_SUCCESS)
    } catch {
        FileHandle.standardError.write(Data("FIFO history validation returned the wrong error: \(error.localizedDescription)\n".utf8))
        Darwin.exit(EXIT_FAILURE)
    }
} else if CommandLine.arguments.count == 3, CommandLine.arguments[1] == "--estimate-homebrew-bottle" {
    let formula = CommandLine.arguments[2]
    if let bytes = await HomebrewBottleSizeEstimator.estimate(formula: formula) {
        print("Homebrew bottle size for \(formula): \(bytes) bytes")
    } else {
        FileHandle.standardError.write(Data("Could not estimate the \(formula) bottle size for this macOS and architecture.\n".utf8))
        Darwin.exit(EXIT_FAILURE)
    }
} else {
    do {
        #if DEBUG
        EngineExecutableTrust.setTestingApprovalOverride { _, _ in true }
        #endif
        let suite = try MorphCheckSuite()
        suite.run()
    } catch {
        FileHandle.standardError.write(Data("Could not start Morph checks: \(error.localizedDescription)\n".utf8))
        Darwin.exit(EXIT_FAILURE)
    }
}
