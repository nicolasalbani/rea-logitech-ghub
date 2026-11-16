import XCTest
@testable import Hubless

final class ProtocolTests: XCTestCase {
    /// Real C922 VideoControl descriptors captured from the device (IF 0 class-specific part).
    func testParsesC922Descriptor() {
        let hex = "09 04 00 00 01 0e 01 00 00 0d 24 01 00 01 d6 00 00 a3 e1 11 01 01 12 24 02 01 01 02 00 00 00 00 00 00 00 00 03 2e 0a 02 0b 24 05 03 01 00 40 02 5b 17 00 09 24 03 04 01 01 00 03 00"
            .replacingOccurrences(of: " ", with: "")
        var bytes: [UInt8] = []
        var i = hex.startIndex
        while i < hex.endIndex { let j = hex.index(i, offsetBy: 2); bytes.append(UInt8(hex[i..<j], radix: 16)!); i = j }
        let r = UVCCamera.parse(configuration: bytes)
        XCTAssertEqual(r.units[.cameraTerminal], 1)
        XCTAssertEqual(r.units[.processingUnit], 3)
        XCTAssertEqual(r.controls[.cameraTerminal], 0x020a2e)
        XCTAssertEqual(r.controls[.processingUnit], 0x175b)
    }

    func testUVCValueCoding() {
        XCTAssertEqual(UVCCamera.encode(-36000, size: 4), [0x60, 0x73, 0xff, 0xff])
        XCTAssertEqual(UVCCamera.decode([0x60, 0x73, 0xff, 0xff][...], signed: true), -36000)
        XCTAssertEqual(UVCCamera.decode([0xa0, 0x0f][...], signed: false), 4000)
    }

    func testLightingParamsRoundTrip() {
        let breathing = ZoneLighting(effect: .breathing, color: RGB(r: 1, g: 2, b: 3), periodMs: 4000, intensity: 80)
        let p = breathing.parameterBytes()
        XCTAssertEqual(p, [1, 2, 3, 0x0f, 0xa0, 0, 80, 0, 0, 0])
        XCTAssertEqual(ZoneLighting.decode(effect: .breathing, params: p), breathing)

        let cycle = ZoneLighting(effect: .cycle, color: .logiBlue, periodMs: 5000, intensity: 100)
        XCTAssertEqual(cycle.parameterBytes(), [0, 0, 0, 0, 0, 0x13, 0x88, 100, 0, 0])
        // Matches what the G560 reported for its current state: static #8D40FF.
        let fixed = ZoneLighting.decode(effect: .fixed, params: [0x8d, 0x40, 0xff, 2, 0, 0, 0, 0, 0, 0])
        XCTAssertEqual(fixed.color, RGB(r: 0x8d, g: 0x40, b: 0xff))
    }

    func testPresetsClampToDeviceRange() {
        let g = EqualizerPreset.night.gains(bands: 10, range: -19...5)
        XCTAssertEqual(g.count, 10)
        XCTAssertTrue(g.allSatisfy { (-19...5).contains($0) })
    }

    func testCMIOModelParsing() {
        let r = CameraUsageMonitor.parseModel("UVC Camera VendorID_1133 ProductID_2140")
        XCTAssertEqual(r?.0, 1133)
        XCTAssertEqual(r?.1, 2140)
    }

    func testProfileLibraryRoundTrip() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("p.json")
        let storage = ProfileStorage(url: url)
        var lib = ProfileLibrary.initial()
        lib.profiles[0].speakers["046d:0a78"] = SpeakerSettings()
        lib.profiles[0].cameras["046d:085c"] = CameraSettings(values: ["zoom": 150])
        try storage.save(lib)
        let loaded = storage.load()
        XCTAssertEqual(loaded.profiles, lib.profiles)
        XCTAssertEqual(loaded.activeProfileID, lib.activeProfileID)
    }

    func testOldProfilesWithoutSubwooferStillDecode() throws {
        let json = #"{"brightness":100,"syncZones":true,"zones":[],"equalizer":[0,0,0,0,0,0,0,0,0,0],"equalizerPreset":"Flat"}"#
        let s = try JSONDecoder().decode(SpeakerSettings.self, from: Data(json.utf8))
        XCTAssertNil(s.subwoofer)
    }
}
