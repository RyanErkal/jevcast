import XCTest
@testable import LauncherCore

final class HyperKeyTests: XCTestCase {
    func testBindingsRoundTripThroughJSON() throws {
        let data = try JSONEncoder().encode(HyperLayer.defaults)
        XCTAssertEqual(try JSONDecoder().decode([HyperBinding].self, from: data), HyperLayer.defaults)
        let app = [HyperBinding(keyCode: 17, action: .openApp("com.apple.Terminal"))]
        XCTAssertEqual(try JSONDecoder().decode([HyperBinding].self, from: JSONEncoder().encode(app)), app)
    }

    func testDefaultsHaveNoDuplicatesAndKnownBuiltIns() {
        XCTAssertTrue(HyperLayer.duplicateKeys(HyperLayer.defaults).isEmpty)
        for binding in HyperLayer.defaults {
            if case .builtIn(let id) = binding.action { XCTAssertNotNil(HyperBuiltIn(rawValue: id), id) }
        }
        XCTAssertEqual(HyperBuiltIn.leftHalf.windowAction, .leftHalf)
        XCTAssertEqual(HyperBuiltIn.maximize.windowAction, .maximize)
        XCTAssertNil(HyperBuiltIn.mail.windowAction)
    }

    func testDuplicateKeysAreReportedAndFirstWins() {
        let bindings = [HyperBinding(keyCode: 46, action: .builtIn("mail")), HyperBinding(keyCode: 46, action: .sendKey(123))]
        XCTAssertEqual(HyperLayer.duplicateKeys(bindings), [46])
        XCTAssertEqual(HyperLayer.table(bindings)[46], .builtIn("mail"))
    }

    func testHyperKeyIsAlwaysSwallowedAndDrivesTheLight() {
        var state = HyperKeyState(table: [46: .builtIn("mail")])
        XCTAssertEqual(state.handle(.keyDown(79, isRepeat: false)), .init(swallow: true, light: true))
        XCTAssertEqual(state.handle(.keyDown(79, isRepeat: true)), .init(swallow: true))
        XCTAssertTrue(state.hyperDown)
        XCTAssertEqual(state.handle(.keyUp(79)), .init(swallow: true, light: false))
        XCTAssertFalse(state.hyperDown)
    }

    func testMappedKeySwallowsDownAndUpAndRunsOnce() {
        var state = HyperKeyState(table: [46: .builtIn("mail")])
        _ = state.handle(.keyDown(79, isRepeat: false))
        XCTAssertEqual(state.handle(.keyDown(46, isRepeat: false)), .init(swallow: true, perform: .builtIn("mail")))
        XCTAssertEqual(state.handle(.keyDown(46, isRepeat: true)), .init(swallow: true))
        // Hyper let go before the key: its up is still swallowed.
        _ = state.handle(.keyUp(79))
        XCTAssertEqual(state.handle(.keyUp(46)), .init(swallow: true))
        XCTAssertEqual(state.handle(.keyUp(46)), .pass)
    }

    func testSendKeyRepeatsWhileHeld() {
        var state = HyperKeyState(table: [4: .sendKey(123)])
        _ = state.handle(.keyDown(79, isRepeat: false))
        XCTAssertEqual(state.handle(.keyDown(4, isRepeat: false)).perform, .sendKey(123))
        XCTAssertEqual(state.handle(.keyDown(4, isRepeat: true)), .init(swallow: true, perform: .sendKey(123)))
    }

    func testUnmappedKeysAndKeysWithoutHyperPass() {
        var state = HyperKeyState(table: [46: .builtIn("mail")])
        XCTAssertEqual(state.handle(.keyDown(46, isRepeat: false)), .pass)
        XCTAssertEqual(state.handle(.keyUp(46)), .pass)
        _ = state.handle(.keyDown(79, isRepeat: false))
        XCTAssertEqual(state.handle(.keyDown(17, isRepeat: false)), .pass)
        XCTAssertEqual(state.handle(.keyUp(17)), .pass)
    }

    func testResetTurnsTheLightOffAndForgetsKeys() {
        var state = HyperKeyState(table: [46: .builtIn("mail")])
        _ = state.handle(.keyDown(79, isRepeat: false))
        _ = state.handle(.keyDown(46, isRepeat: false))
        XCTAssertEqual(state.reset(), .init(swallow: false, light: false))
        XCTAssertFalse(state.hyperDown)
        XCTAssertTrue(state.held.isEmpty)
        XCTAssertEqual(state.reset(), .pass)
    }

    func testParsesHidutilOutput() {
        XCTAssertEqual(HIDKeyMapping.parse("(null)\n"), [])
        XCTAssertEqual(HIDKeyMapping.parse(""), [])
        let plist = """
        (
                {
                HIDKeyboardModifierMappingDst = 30064771300;
                HIDKeyboardModifierMappingSrc = 30064771299;
            }
        )
        """
        XCTAssertEqual(HIDKeyMapping.parse(plist), [.init(src: 30064771299, dst: 30064771300)])
        let json = #"[{"HIDKeyboardModifierMappingSrc":"0x700000039","HIDKeyboardModifierMappingDst":30064771113}]"#
        XCTAssertEqual(HIDKeyMapping.parse(json), [.init(src: HIDKeyMapping.capsLock, dst: 30064771113)])
        XCTAssertNil(HIDKeyMapping.parse("garbage {"))
    }

    func testAddKeepsOtherMappingsAndRemembersCapsEntry() {
        let other = HIDKeyMapping.Entry(src: 0x7000000E3, dst: 0x7000000E2)
        let caps = HIDKeyMapping.Entry(src: HIDKeyMapping.capsLock, dst: 0x7000000E0)
        let added = HIDKeyMapping.adding(to: [other, caps])
        XCTAssertEqual(added.entries, [other, .init(src: HIDKeyMapping.capsLock, dst: HIDKeyMapping.f18)])
        XCTAssertEqual(added.replacedCaps, caps)
        XCTAssertTrue(HIDKeyMapping.isApplied(added.entries))
        // Applying again keeps one entry and does not treat its own entry as the user's.
        let again = HIDKeyMapping.adding(to: added.entries)
        XCTAssertEqual(again.entries, added.entries)
        XCTAssertNil(again.replacedCaps)
    }

    func testRemoveRestoresOnlyWhatWasThere() {
        let other = HIDKeyMapping.Entry(src: 0x7000000E3, dst: 0x7000000E2)
        let caps = HIDKeyMapping.Entry(src: HIDKeyMapping.capsLock, dst: 0x7000000E0)
        let ours = HIDKeyMapping.Entry(src: HIDKeyMapping.capsLock, dst: HIDKeyMapping.f18)
        XCTAssertEqual(HIDKeyMapping.removing(from: [other, ours], restore: caps), [other, caps])
        XCTAssertEqual(HIDKeyMapping.removing(from: [other, ours], restore: nil), [other])
        XCTAssertEqual(HIDKeyMapping.removing(from: [], restore: nil), [])
        // The user changed Caps Lock since: leave their entry alone.
        XCTAssertEqual(HIDKeyMapping.removing(from: [caps], restore: .init(src: HIDKeyMapping.capsLock, dst: 1)), [caps])
    }

    func testSetArgumentIsJSON() throws {
        let argument = HIDKeyMapping.setArgument([.init(src: HIDKeyMapping.capsLock, dst: HIDKeyMapping.f18)])
        XCTAssertEqual(argument, #"{"UserKeyMapping":[{"HIDKeyboardModifierMappingSrc":30064771129,"HIDKeyboardModifierMappingDst":30064771181}]}"#)
        XCTAssertNoThrow(try JSONSerialization.jsonObject(with: Data(argument.utf8)))
        XCTAssertEqual(HIDKeyMapping.setArgument([]), #"{"UserKeyMapping":[]}"#)
    }

    func testKeyNames() {
        XCTAssertEqual(HyperLayer.keyName(46), "M")
        XCTAssertEqual(HyperLayer.keyName(123), "←")
        XCTAssertEqual(HyperLayer.keyName(200), "Key 200")
    }
}
