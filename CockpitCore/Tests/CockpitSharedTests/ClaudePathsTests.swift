import XCTest
@testable import CockpitShared

final class ClaudePathsTests: XCTestCase {
    func testDerivedPaths() {
        let home = URL(fileURLWithPath: "/tmp/home")
        let p = ClaudePaths(home: home)
        XCTAssertEqual(p.claudeDir.path, "/tmp/home/.claude")
        XCTAssertEqual(p.libraryDir.path, "/tmp/home/.claude/skillmanager/library")
        XCTAssertTrue(p.isInsideHome(URL(fileURLWithPath: "/tmp/home/.claude/skills/x")))
        XCTAssertFalse(p.isInsideHome(URL(fileURLWithPath: "/etc/passwd")))
        XCTAssertFalse(p.isInsideHome(URL(fileURLWithPath: "/tmp/home2/x")))
    }

    func testConfigDirOverride() {
        let p = ClaudePaths(home: URL(fileURLWithPath: "/tmp/home"), configDir: URL(fileURLWithPath: "/tmp/cfg"))
        XCTAssertEqual(p.claudeDir.path, "/tmp/cfg")
        XCTAssertEqual(p.skillsDir.path, "/tmp/cfg/skills")
        XCTAssertEqual(p.appSupportDir.path, "/tmp/home/Library/Application Support/ClaudeCockpit")
    }
}

final class ClaudePathsSandboxTests: XCTestCase {
    func testExplicitAppSupportIsKeptApartFromHome() {
        let p = ClaudePaths(home: URL(fileURLWithPath: "/Users/x"),
                            appSupport: URL(fileURLWithPath: "/c/Data/Library/Application Support/ClaudeCockpit"))
        XCTAssertEqual(p.claudeDir.path, "/Users/x/.claude")
        XCTAssertEqual(p.appSupportDir.path, "/c/Data/Library/Application Support/ClaudeCockpit")
        XCTAssertEqual(p.rtkDatabaseCandidates.first?.path, "/Users/x/Library/Application Support/rtk/history.db")
    }

    func testRealHomeComesFromThePasswordDatabase() {
        let entry = getpwuid(getuid())
        XCTAssertNotNil(entry)
        XCTAssertEqual(ClaudePaths.realHome.path, String(cString: entry!.pointee.pw_dir))
        XCTAssertEqual(ClaudePaths.live.home, ClaudePaths.realHome)
        XCTAssertFalse(ClaudePaths.live.appSupportDir.path.isEmpty)
    }

    func testTildeExpandsAgainstTheGivenHome() {
        let home = URL(fileURLWithPath: "/Users/x")
        XCTAssertEqual(ClaudePaths.expandTilde("~", home: home), "/Users/x")
        XCTAssertEqual(ClaudePaths.expandTilde("~/DevApps", home: home), "/Users/x/DevApps")
        XCTAssertEqual(ClaudePaths.expandTilde("/opt/x", home: home), "/opt/x")
        XCTAssertEqual(ClaudePaths.expandTilde("~other/x", home: home), "~other/x")
    }

    func testConfigDirSettingWinsOverEnvironment() {
        let home = URL(fileURLWithPath: "/Users/x")
        let env = ["CLAUDE_CONFIG_DIR": "~/env-cfg"]
        XCTAssertEqual(ClaudePaths.resolveConfigDir(setting: "~/set-cfg", environment: env, home: home)?.path, "/Users/x/set-cfg")
        XCTAssertEqual(ClaudePaths.resolveConfigDir(setting: "  ", environment: env, home: home)?.path, "/Users/x/env-cfg")
        XCTAssertNil(ClaudePaths.resolveConfigDir(setting: nil, environment: [:], home: home))
    }

    func testRelativeConfigDirIsRefused() {
        let home = URL(fileURLWithPath: "/Users/x")
        XCTAssertTrue(ClaudePaths.isUsableConfigDirSetting(""))
        XCTAssertTrue(ClaudePaths.isUsableConfigDirSetting("~"))
        XCTAssertTrue(ClaudePaths.isUsableConfigDirSetting("~/cfg"))
        XCTAssertTrue(ClaudePaths.isUsableConfigDirSetting(" /Volumes/Data/claude "))
        XCTAssertFalse(ClaudePaths.isUsableConfigDirSetting("claude"))
        XCTAssertFalse(ClaudePaths.isUsableConfigDirSetting("./claude"))
        XCTAssertFalse(ClaudePaths.isUsableConfigDirSetting("~other/claude"))
        // A relative setting falls through to the variable, then to the default.
        XCTAssertEqual(ClaudePaths.resolveConfigDir(
            setting: "claude", environment: ["CLAUDE_CONFIG_DIR": "/env"], home: home)?.path, "/env")
        XCTAssertNil(ClaudePaths.resolveConfigDir(setting: "claude", environment: [:], home: home))
    }
}
