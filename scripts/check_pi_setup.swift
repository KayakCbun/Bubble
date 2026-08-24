import Foundation

func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else {
        FileHandle.standardError.write(Data("FAIL: \(message)\n".utf8))
        exit(1)
    }
}

func expectContains(_ haystack: String, _ needle: String, _ message: String) {
    expect(haystack.contains(needle), "\(message)\n---\n\(haystack)\n---")
}

@main
struct PiSetupCheck {
    static func main() {
        if ProcessInfo.processInfo.environment["BUBBLE_WRITE_EXTENSION"] == "1" {
            BubbleConfig.ensureWorkspaceExtension()
        }
        testParseNodeVersion()
        testNodeVersionAtLeast()
        testSetupCard()
        testSteeringExtension()
        testBranchExtension()
        print("PASS: pi setup diagnose")
    }

    static func testParseNodeVersion() {
        expect(PiSetup.parseNodeVersion("v22.19.0")! == (22, 19, 0), "strip v prefix")
        expect(PiSetup.parseNodeVersion("22.19.0")! == (22, 19, 0), "plain semver")
        expect(PiSetup.parseNodeVersion("v24.1.2")! == (24, 1, 2), "newer major")
        expect(PiSetup.parseNodeVersion("22.19")! == (22, 19, 0), "missing patch is 0")
        expect(PiSetup.parseNodeVersion("  v22.19.1\n")! == (22, 19, 1), "trim whitespace")
        expect(PiSetup.parseNodeVersion("nope") == nil, "garbage")
        expect(PiSetup.parseNodeVersion("v22") == nil, "major only")
        expect(PiSetup.parseNodeVersion("") == nil, "empty")
    }

    static func testNodeVersionAtLeast() {
        expect(PiSetup.nodeVersionAtLeast("v22.19.0"), "exact minimum")
        expect(PiSetup.nodeVersionAtLeast("22.19.1"), "same minor, newer patch")
        expect(PiSetup.nodeVersionAtLeast("v22.20.0"), "newer minor")
        expect(PiSetup.nodeVersionAtLeast("v24.0.0"), "newer major")
        expect(!PiSetup.nodeVersionAtLeast("v22.18.0"), "older minor")
        expect(!PiSetup.nodeVersionAtLeast("v20.11.1"), "older major")
        expect(PiSetup.nodeVersionAtLeast("v22.19"), "two-part 22.19 counts as 22.19.0")
        expect(!PiSetup.nodeVersionAtLeast("not-a-version"), "garbage is unsupported")
    }

    static func testSetupCard() {
        let missingNode = PiSetup.Report(
            nodeInstalled: false,
            nodeVersion: nil,
            nodeSupported: false,
            piInstalled: false,
            acpInstalled: false,
            acpAvailable: false,
            credentialProviders: []
        )
        let missingCard = PiSetup.setupCard(missingNode)
        expectContains(missingCard, "/setup", "missing node points at /setup")
        expectContains(missingCard, "nodejs.org", "missing node names the download site")
        expectContains(missingCard, "Install Node first", "missing node asks for Node before install")

        let oldNode = PiSetup.Report(
            nodeInstalled: true,
            nodeVersion: "v20.11.1",
            nodeSupported: false,
            piInstalled: false,
            acpInstalled: false,
            acpAvailable: false,
            credentialProviders: []
        )
        let oldCard = PiSetup.setupCard(oldNode)
        expectContains(oldCard, "v20.11.1", "old node shows the installed version")
        expectContains(oldCard, "22.19.0", "old node names the minimum")
        expectContains(oldCard, "/setup", "old node still uses /setup")

        let canInstall = PiSetup.Report(
            nodeInstalled: true,
            nodeVersion: "v22.19.0",
            nodeSupported: true,
            piInstalled: false,
            acpInstalled: false,
            acpAvailable: false,
            credentialProviders: []
        )
        let installCard = PiSetup.setupCard(canInstall)
        expectContains(installCard, "installed (v22.19.0)", "supported node is marked installed")
        expectContains(installCard, "~/.bubble/runtime", "install target is ~/.bubble/runtime")
        expectContains(installCard, "Type /setup to install Pi", "ready-to-install card is one command")
        expect(!installCard.contains("Install Node first"), "supported node does not ask to install Node")
    }

    static func testSteeringExtension() {
        let source = BubbleConfig.workspaceExtensionSource
        expectContains(source, "pi.sendUserMessage(content, { deliverAs: \"steer\" })", "extension uses native steering")
        expectContains(source, "if (!steeringBusy) throw new Error(\"steer-unavailable\")", "extension rejects closed steering windows")
        expectContains(source, "path.join(os.homedir(), \".bubble\", \"steering\")", "extension publishes a session-local endpoint")
        expectContains(source, "request.token !== steeringToken || request.generation !== steeringGeneration", "steering endpoint is bound to one turn")
        expectContains(source, "steeringGeneration += 1", "each active turn gets a new steering generation")
    }

    static func testBranchExtension() {
        let source = BubbleConfig.workspaceExtensionSource
        expectContains(source, "pi.registerCommand(\"bubble-navigate\"", "extension owns hidden branch navigation")
        expectContains(source, "ctx.navigateTree(targetId, { summarize: false })", "branch navigation keeps the current Pi session")
    }
}
