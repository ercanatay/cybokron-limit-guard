import Foundation
import Testing
@testable import LimitGuardCore

/// `UpdateInstaller.verifySignature` and `verifyDiskImageSignature`: the staged app's signature
/// must be intact; when the running copy is Developer ID signed, the app and the disk image must
/// carry a Developer ID signature of its team — ad hoc signatures are refused.
@Suite("Update signature check")
struct UpdateSignatureTests {
    /// Answers codesign calls as for code signed with `requirement` (`codesign -d -r-`) and
    /// `details` (`codesign -dv`), verifying with `verification`. `-R` requirements are evaluated
    /// as codesign would for that signature (Apple-anchored, team, identifier), unless
    /// `requirementResult` overrides the answer.
    final class FakeCodesign: ToolRunning, @unchecked Sendable {
        private let lock = NSLock()
        private var _calls: [[String]] = []
        let verification: ToolResult
        let requirement: String
        let details: String
        let requirementResult: ToolResult?

        init(verification: ToolResult = ToolResult(status: 0, output: ""), requirement: String, details: String, requirementResult: ToolResult? = nil) {
            self.verification = verification
            self.requirement = requirement
            self.details = details
            self.requirementResult = requirementResult
        }

        var calls: [[String]] { lock.withLock { _calls } }

        /// The `-R` requirements asked for, without the leading "=".
        var testedRequirements: [String] {
            calls.compactMap { call in
                guard let index = call.firstIndex(of: "-R"), index + 1 < call.count else { return nil }
                return String(call[index + 1].dropFirst())
            }
        }

        func run(_ tool: URL, arguments: [String]) async throws -> ToolResult {
            lock.withLock { _calls.append(arguments) }
            guard tool == SystemTools.codesign else { return ToolResult(status: 1, output: "unexpected tool") }
            switch arguments.first {
            case "--verify" where arguments.contains("-R"):
                if let requirementResult { return requirementResult }
                guard verification.succeeded else { return verification }
                return satisfies(String(arguments[arguments.firstIndex(of: "-R")! + 1].dropFirst()))
                    ? ToolResult(status: 0, output: "")
                    : ToolResult(status: 3, output: "test-requirement: code failed to satisfy specified code requirement(s)")
            case "--verify": return verification
            case "-d": return ToolResult(status: 0, output: "Executable=/x/Contents/MacOS/x\n" + requirement)
            case "-dv": return ToolResult(status: 0, output: details)
            default: return ToolResult(status: 1, output: "unexpected arguments")
            }
        }

        /// Whether this signature meets a requirement written by `developerIDRequirement`.
        private func satisfies(_ tested: String) -> Bool {
            let signature = CodeSignature(requirementOutput: requirement, detailsOutput: details)
            guard signature.isAppleAnchored, let team = signature.teamIdentifier,
                  tested.contains("anchor apple generic"),
                  tested.contains(#"certificate leaf[subject.OU] = "\#(team)""#)
            else { return false }
            if let range = tested.range(of: #"identifier "[^"]*""#, options: .regularExpression) {
                return requirement.contains(String(tested[range]))
            }
            return true
        }
    }

    static let bundleIdentifier = "com.cybokron.limitguard"
    static let adHocRequirement = #"# designated => cdhash H"df808d7764783089ace6886a3ab7fc81fe9eae6e" or cdhash H"4feb446bc89811a3317ae7f38d3f53c1c3d969fc""#
    static let adHocDetails = "Identifier=com.cybokron.limitguard\nCodeDirectory v=20400 size=262 flags=0x2(adhoc) hashes=2+3 location=embedded\nSignature=adhoc\nTeamIdentifier=not set"

    static func developerIDRequirement(team: String) -> String {
        #"designated => anchor apple generic and identifier "com.cybokron.limitguard" and (certificate leaf[field.1.2.840.113635.100.6.1.9] /* exists */ or certificate 1[field.1.2.840.113635.100.6.2.6] /* exists */ and certificate leaf[field.1.2.840.113635.100.6.1.13] /* exists */ and certificate leaf[subject.OU] = "\#(team)")"#
    }

    static func developerIDDetails(team: String) -> String {
        "Identifier=com.cybokron.limitguard\nAuthority=Developer ID Application: Example (\(team))\nAuthority=Developer ID Certification Authority\nAuthority=Apple Root CA\nTeamIdentifier=\(team)"
    }

    /// How a release disk image's signature reads (signed under its file name).
    static func diskImageRequirement(team: String) -> String {
        #"designated => identifier "Cybokron-Limit-Guard-0.6.5-universal" and anchor apple generic and certificate 1[field.1.2.840.113635.100.6.2.6] /* exists */ and certificate leaf[field.1.2.840.113635.100.6.1.13] /* exists */ and certificate leaf[subject.OU] = \#(team)"#
    }

    private let app = URL(fileURLWithPath: "/tmp/staging/Cybokron Limit Guard.app", isDirectory: true)
    private let diskImage = URL(fileURLWithPath: "/tmp/downloads/Cybokron-Limit-Guard-0.6.5-universal.dmg")

    private func installer(_ tools: ToolRunning) -> UpdateInstaller {
        UpdateInstaller(directories: UpdateDirectories(root: URL(fileURLWithPath: "/tmp/unused")), tools: tools)
    }

    private func verify(_ tools: ToolRunning, expectedTeam: String?) async throws {
        try await installer(tools).verifySignature(ofStagedApp: app, bundleIdentifier: Self.bundleIdentifier, expectedTeamIdentifier: expectedTeam)
    }

    // MARK: - Simulated codesign: the staged app

    @Test func adHocSignaturesAreRefusedWhenTheRunningCopyIsDeveloperIDSigned() async throws {
        let tools = FakeCodesign(requirement: Self.adHocRequirement, details: Self.adHocDetails)

        // Signed ad hoc, the update has no signer to vouch for it: a Developer ID copy refuses it.
        await #expect(throws: UpdateInstallError.wrongSigner(found: "none", expected: "AAAAA11111")) {
            try await verify(tools, expectedTeam: "AAAAA11111")
        }
        #expect(tools.calls.first == ["--verify", "--strict", app.path])
        #expect(tools.testedRequirements == [UpdateInstaller.developerIDRequirement(teamIdentifier: "AAAAA11111", identifier: Self.bundleIdentifier)])
    }

    @Test func aRunningCopySignedAdHocStillAcceptsAnIntactSignature() async throws {
        // Up to 0.6.2 the running copy was signed ad hoc: it has no team to hold updates to.
        let adHoc = FakeCodesign(requirement: Self.adHocRequirement, details: Self.adHocDetails)
        let developerID = FakeCodesign(requirement: Self.developerIDRequirement(team: "AAAAA11111"), details: Self.developerIDDetails(team: "AAAAA11111"))

        try await verify(adHoc, expectedTeam: nil)
        try await verify(developerID, expectedTeam: nil)

        #expect(adHoc.calls == [["--verify", "--strict", app.path]])
        #expect(developerID.testedRequirements.isEmpty)
    }

    @Test func developerIDSignaturesMustComeFromTheRunningTeam() async throws {
        let tools = FakeCodesign(requirement: Self.developerIDRequirement(team: "AAAAA11111"), details: Self.developerIDDetails(team: "AAAAA11111"))

        try await verify(tools, expectedTeam: "AAAAA11111")
        await #expect(throws: UpdateInstallError.wrongSigner(found: "AAAAA11111", expected: "BBBBB22222")) {
            try await verify(tools, expectedTeam: "BBBBB22222")
        }
    }

    @Test func anotherAppOfTheSameTeamIsRefused() async throws {
        let requirement = Self.developerIDRequirement(team: "AAAAA11111").replacingOccurrences(of: "com.cybokron.limitguard", with: "com.example.other")
        let tools = FakeCodesign(requirement: requirement, details: Self.developerIDDetails(team: "AAAAA11111"))

        await #expect(throws: UpdateInstallError.invalidSignature("test-requirement: code failed to satisfy specified code requirement(s)")) {
            try await verify(tools, expectedTeam: "AAAAA11111")
        }
    }

    @Test func theRequirementPinsAppleTheDeveloperIDCertificateTheTeamAndTheIdentifier() {
        #expect(UpdateInstaller.developerIDRequirement(teamIdentifier: "AAAAA11111", identifier: "com.cybokron.limitguard")
            == #"anchor apple generic and identifier "com.cybokron.limitguard" and certificate 1[field.1.2.840.113635.100.6.2.6] exists and certificate leaf[field.1.2.840.113635.100.6.1.13] exists and certificate leaf[subject.OU] = "AAAAA11111""#)
        #expect(UpdateInstaller.developerIDRequirement(teamIdentifier: "AAAAA11111")
            == #"anchor apple generic and certificate 1[field.1.2.840.113635.100.6.2.6] exists and certificate leaf[field.1.2.840.113635.100.6.1.13] exists and certificate leaf[subject.OU] = "AAAAA11111""#)
    }

    @Test func malformedIdentifiersNeverReachTheRequirement() async throws {
        let tools = FakeCodesign(requirement: Self.developerIDRequirement(team: "AAAAA11111"), details: Self.developerIDDetails(team: "AAAAA11111"))

        await #expect(throws: UpdateInstallError.self) {
            try await verify(tools, expectedTeam: #"AAAAA11111" or anchor apple or ""#)
        }
        await #expect(throws: UpdateInstallError.self) {
            try await installer(tools).verifySignature(ofStagedApp: app, bundleIdentifier: #"x" or anchor apple or identifier "y"#, expectedTeamIdentifier: "AAAAA11111")
        }
        #expect(tools.testedRequirements.isEmpty)
        #expect(UpdateInstaller.isWellFormedTeamIdentifier("AAAAA11111"))
        #expect(!UpdateInstaller.isWellFormedTeamIdentifier("aaaaa11111"))
        #expect(!UpdateInstaller.isWellFormedTeamIdentifier("AAAAA1111"))
        #expect(UpdateInstaller.isWellFormedBundleIdentifier("com.cybokron.limitguard"))
        #expect(!UpdateInstaller.isWellFormedBundleIdentifier(""))
    }

    @Test func whenTheRequirementCantBeEvaluatedTheSignatureIsRefused() async {
        let unevaluated = ToolResult(status: 1, output: "error: invalid or corrupted code requirement(s)")
        let developerID = FakeCodesign(requirement: Self.developerIDRequirement(team: "AAAAA11111"), details: Self.developerIDDetails(team: "AAAAA11111"), requirementResult: unevaluated)
        let adHoc = FakeCodesign(requirement: Self.adHocRequirement, details: Self.adHocDetails, requirementResult: unevaluated)

        // Even a description that names the expected team doesn't stand in for the requirement.
        await #expect(throws: UpdateInstallError.invalidSignature("error: invalid or corrupted code requirement(s)")) {
            try await verify(developerID, expectedTeam: "AAAAA11111")
        }
        await #expect(throws: UpdateInstallError.invalidSignature("error: invalid or corrupted code requirement(s)")) {
            try await verify(adHoc, expectedTeam: "AAAAA11111")
        }
    }

    @Test func aPinnedTeamWinsOverTheRunningSignature() {
        #expect(UpdateInstaller.expectedTeamIdentifier(pinned: "AAAAA11111", running: "BBBBB22222") == "AAAAA11111")
        // The running app's signature can't be read: the pinned team still holds the update to it.
        #expect(UpdateInstaller.expectedTeamIdentifier(pinned: "AAAAA11111", running: nil) == "AAAAA11111")
        #expect(UpdateInstaller.expectedTeamIdentifier(pinned: nil, running: "BBBBB22222") == "BBBBB22222")
        #expect(UpdateInstaller.expectedTeamIdentifier(pinned: "", running: "BBBBB22222") == "BBBBB22222")
        #expect(UpdateInstaller.expectedTeamIdentifier(pinned: nil, running: nil) == nil)
    }

    @Test func aBrokenSignatureIsRefused() async {
        let tools = FakeCodesign(
            verification: ToolResult(status: 1, output: "/tmp/x.app: a sealed resource is missing or invalid"),
            requirement: Self.adHocRequirement,
            details: Self.adHocDetails
        )

        await #expect(throws: UpdateInstallError.invalidSignature("/tmp/x.app: a sealed resource is missing or invalid")) {
            try await verify(tools, expectedTeam: nil)
        }
        #expect(tools.calls.count == 1, "nothing more is asked of a broken signature")
    }

    @Test func signaturesAreReadFromCodesignsOutput() {
        let adHoc = CodeSignature(requirementOutput: Self.adHocRequirement, detailsOutput: Self.adHocDetails)
        let developerID = CodeSignature(requirementOutput: Self.developerIDRequirement(team: "AAAAA11111"), detailsOutput: Self.developerIDDetails(team: "AAAAA11111"))
        let diskImage = CodeSignature(requirementOutput: Self.diskImageRequirement(team: "AAAAA11111"), detailsOutput: "TeamIdentifier=AAAAA11111")

        #expect(adHoc == CodeSignature(isAppleAnchored: false, teamIdentifier: nil))
        #expect(adHoc.signingTeam == nil)
        #expect(developerID == CodeSignature(isAppleAnchored: true, teamIdentifier: "AAAAA11111"))
        #expect(developerID.signingTeam == "AAAAA11111")
        #expect(diskImage.signingTeam == "AAAAA11111")
        // A team without Apple's anchor vouches for nothing.
        #expect(CodeSignature(requirementOutput: Self.adHocRequirement, detailsOutput: "TeamIdentifier=CCCCC33333").signingTeam == nil)
    }

    @Test func messagesNameTheProblem() {
        #expect(UpdateInstallError.invalidSignature("code object is not signed at all").localizedDescription
            == "The downloaded app's code signature isn't valid, so it wasn't installed: code object is not signed at all")
        #expect(UpdateInstallError.wrongSigner(found: "AAAAA11111", expected: "BBBBB22222").localizedDescription
            == "The downloaded app is signed by another developer (team AAAAA11111 instead of BBBBB22222), so it wasn't installed.")
    }

    // MARK: - Simulated codesign: the disk image, before it's mounted

    /// Codesign answers from `codesign`; hdiutil and ditto from `diskImageTools`. Records every
    /// call's tool in order.
    final class RoutingTools: ToolRunning, @unchecked Sendable {
        private let lock = NSLock()
        private var _tools: [String] = []
        let codesign: FakeCodesign
        let diskImageTools: FakeDiskImageTools

        init(codesign: FakeCodesign, diskImageTools: FakeDiskImageTools) {
            self.codesign = codesign
            self.diskImageTools = diskImageTools
        }

        var tools: [String] { lock.withLock { _tools } }

        func run(_ tool: URL, arguments: [String]) async throws -> ToolResult {
            lock.withLock { _tools.append(tool.lastPathComponent) }
            return tool == SystemTools.codesign
                ? try await codesign.run(tool, arguments: arguments)
                : try await diskImageTools.run(tool, arguments: arguments)
        }
    }

    @Test func anAdHocDiskImageIsNeverMountedByADeveloperIDCopy() async throws {
        let temporary = try TemporaryDirectory()
        defer { temporary.remove() }
        let tools = RoutingTools(
            codesign: FakeCodesign(requirement: Self.adHocRequirement, details: Self.adHocDetails),
            diskImageTools: FakeDiskImageTools(diskImageApp: nil)
        )
        let installer = UpdateInstaller(directories: UpdateDirectories(root: temporary.url.appending(path: "updates")), tools: tools)

        await #expect(throws: UpdateInstallError.wrongSigner(found: "none", expected: "AAAAA11111")) {
            try await installer.stageApp(fromDiskImage: diskImage, appName: "Cybokron Limit Guard", expectedTeamIdentifier: "AAAAA11111")
        }
        #expect(!tools.tools.contains("hdiutil"), "the disk image was mounted before its signature was checked")
        #expect(tools.codesign.testedRequirements == [UpdateInstaller.developerIDRequirement(teamIdentifier: "AAAAA11111")])
        #expect(tools.codesign.calls.first == ["--verify", "--strict", diskImage.path])
    }

    @Test func aDiskImageOfTheRunningTeamIsCheckedThenMounted() async throws {
        let temporary = try TemporaryDirectory()
        defer { temporary.remove() }
        let tools = RoutingTools(
            codesign: FakeCodesign(requirement: Self.diskImageRequirement(team: "AAAAA11111"), details: "TeamIdentifier=AAAAA11111"),
            diskImageTools: FakeDiskImageTools(diskImageApp: nil)
        )
        let installer = UpdateInstaller(directories: UpdateDirectories(root: temporary.url.appending(path: "updates")), tools: tools)

        // The fake image holds no app; what matters is that it was checked, then mounted.
        await #expect(throws: UpdateInstallError.appNotFound) {
            try await installer.stageApp(fromDiskImage: diskImage, appName: "Cybokron Limit Guard", expectedTeamIdentifier: "AAAAA11111")
        }
        #expect(Array(tools.tools.prefix(3)) == ["codesign", "codesign", "hdiutil"])

        await #expect(throws: UpdateInstallError.wrongSigner(found: "AAAAA11111", expected: "BBBBB22222")) {
            try await installer.verifyDiskImageSignature(diskImage, expectedTeamIdentifier: "BBBBB22222")
        }
    }

    @Test func aCopySignedAdHocMountsTheDiskImageUnchecked() async throws {
        let temporary = try TemporaryDirectory()
        defer { temporary.remove() }
        let tools = RoutingTools(
            codesign: FakeCodesign(requirement: Self.adHocRequirement, details: Self.adHocDetails),
            diskImageTools: FakeDiskImageTools(diskImageApp: nil)
        )
        let installer = UpdateInstaller(directories: UpdateDirectories(root: temporary.url.appending(path: "updates")), tools: tools)

        await #expect(throws: UpdateInstallError.appNotFound) {
            try await installer.stageApp(fromDiskImage: diskImage, appName: "Cybokron Limit Guard", expectedTeamIdentifier: nil)
        }
        #expect(tools.tools.first == "hdiutil")
        #expect(!tools.tools.contains("codesign"))
    }

    // MARK: - Real codesign

    /// An app bundle whose executable is a copy of `/usr/bin/true` (a real Mach-O), signed ad hoc
    /// as the releases up to 0.6.2 were.
    private func signedApp(in temporary: TemporaryDirectory) async throws -> URL {
        let app = temporary.url.appending(path: "Cybokron Limit Guard.app", directoryHint: .isDirectory)
        let macOS = app.appending(components: "Contents", "MacOS", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: macOS, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: URL(fileURLWithPath: "/usr/bin/true"), to: macOS.appending(path: "Cybokron Limit Guard"))
        let info: [String: Any] = [
            "CFBundleIdentifier": "com.cybokron.limitguard",
            "CFBundleShortVersionString": "0.7.0",
            "CFBundleExecutable": "Cybokron Limit Guard",
            "CFBundlePackageType": "APPL",
        ]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            .write(to: app.appending(components: "Contents", "Info.plist"))
        let signing = try await SystemToolRunner().run(SystemTools.codesign, arguments: ["--force", "--sign", "-", app.path])
        try #require(signing.succeeded, "\(signing.output)")
        return app
    }

    /// A disk image holding `folder`, signed ad hoc when `signed`.
    private func diskImage(of folder: URL, in temporary: TemporaryDirectory, signed: Bool) async throws -> URL {
        let image = temporary.url.appending(path: "update-\(UUID().uuidString).dmg")
        let created = try await SystemToolRunner().run(UpdateInstaller.hdiutil, arguments: [
            "create", "-quiet", "-volname", "Cybokron Signature Test", "-srcfolder", folder.path, "-format", "UDZO", "-ov", image.path,
        ])
        try #require(created.succeeded, "hdiutil create: \(created.output)")
        if signed {
            let signing = try await SystemToolRunner().run(SystemTools.codesign, arguments: ["--force", "--sign", "-", image.path])
            try #require(signing.succeeded, "\(signing.output)")
        }
        return image
    }

    @Test func anIntactAdHocSignaturePassesOnlyForACopySignedAdHoc() async throws {
        let temporary = try TemporaryDirectory()
        defer { temporary.remove() }
        let app = try await signedApp(in: temporary)
        let installer = installer(SystemToolRunner())

        try await installer.verifySignature(ofStagedApp: app, bundleIdentifier: Self.bundleIdentifier, expectedTeamIdentifier: nil)
        #expect(await installer.signature(ofAppAt: app) == CodeSignature(isAppleAnchored: false, teamIdentifier: nil))
    }

    @Test func realCodesignRefusesAnAdHocAppForADeveloperIDCopy() async throws {
        let temporary = try TemporaryDirectory()
        defer { temporary.remove() }
        let app = try await signedApp(in: temporary)

        await #expect(throws: UpdateInstallError.wrongSigner(found: "none", expected: "AAAAA11111")) {
            try await installer(SystemToolRunner()).verifySignature(ofStagedApp: app, bundleIdentifier: Self.bundleIdentifier, expectedTeamIdentifier: "AAAAA11111")
        }
    }

    @Test func realCodesignRefusesAnAdHocOrUnsignedDiskImageBeforeMounting() async throws {
        let temporary = try TemporaryDirectory()
        defer { temporary.remove() }
        let source = try TemporaryDirectory(base: temporary.url)
        _ = try await signedApp(in: source)
        let adHocImage = try await diskImage(of: source.url, in: temporary, signed: true)
        let unsignedImage = try await diskImage(of: source.url, in: temporary, signed: false)
        let installer = UpdateInstaller(directories: UpdateDirectories(root: temporary.url.appending(path: "updates")), tools: SystemToolRunner())

        await #expect(throws: UpdateInstallError.wrongSigner(found: "none", expected: "AAAAA11111")) {
            try await installer.stageApp(fromDiskImage: adHocImage, appName: "Cybokron Limit Guard", expectedTeamIdentifier: "AAAAA11111")
        }
        do {
            _ = try await installer.stageApp(fromDiskImage: unsignedImage, appName: "Cybokron Limit Guard", expectedTeamIdentifier: "AAAAA11111")
            Issue.record("an unsigned disk image was mounted")
        } catch let UpdateInstallError.invalidSignature(reason) {
            #expect(reason.contains("not signed"))
        }
        // Nothing was mounted: no mount point was ever made.
        #expect(!FileManager.default.fileExists(atPath: installer.directories.mounts.path))
    }

    @Test func aModifiedAppIsRefused() async throws {
        let temporary = try TemporaryDirectory()
        defer { temporary.remove() }
        let app = try await signedApp(in: temporary)
        let plist = app.appending(components: "Contents", "Info.plist")
        let handle = try FileHandle(forWritingTo: plist)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("<!-- changed -->\n".utf8))
        try handle.close()

        await #expect(throws: UpdateInstallError.self) {
            try await installer(SystemToolRunner()).verifySignature(ofStagedApp: app, bundleIdentifier: Self.bundleIdentifier, expectedTeamIdentifier: nil)
        }
    }

    @Test func anUnsignedAppIsRefused() async throws {
        let temporary = try TemporaryDirectory()
        defer { temporary.remove() }
        let app = try temporary.makeScriptAppBundle(named: "Unsigned")

        do {
            try await installer(SystemToolRunner()).verifySignature(ofStagedApp: app, bundleIdentifier: Self.bundleIdentifier, expectedTeamIdentifier: nil)
            Issue.record("an unsigned app passed")
        } catch let UpdateInstallError.invalidSignature(reason) {
            #expect(reason.contains("not signed"))
        }
    }
}
