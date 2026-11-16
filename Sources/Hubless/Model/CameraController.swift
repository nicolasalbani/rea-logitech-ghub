import Foundation
import IOKit

/// A user-facing camera value. Pan/tilt are split out of the single UVC panTilt control.
struct CameraValue: Identifiable, Hashable, Sendable {
    let key: String
    let title: String
    let spec: UVCControlSpec
    /// Index into the spec's value array (pan = 0, tilt = 1).
    let component: Int
    var range: UVCRange

    var id: String { key }
}

@MainActor
final class CameraController: ObservableObject, Identifiable {
    nonisolated let id: String
    let camera: UVCCamera
    let registryID: UInt64

    @Published private(set) var values: [String: CameraValue] = [:]
    @Published var settings = CameraSettings()
    @Published private(set) var isReady = false
    @Published private(set) var lastError: String?
    /// Value written to aeMode for "auto" (aperture-priority on most Logitech cams).
    private(set) var autoExposureMode = 8

    private let io = DispatchQueue(label: "camera.io")
    private var applied: [String: Int] = [:]
    private var pending: CameraSettings?
    private var writeScheduled = false

    init(camera: UVCCamera, registryID: UInt64) {
        self.camera = camera
        self.registryID = registryID
        id = "uvc-\(camera.modelKey)-\(camera.locationID)"
    }

    var name: String { camera.productName }
    var shortName: String {
        name.replacingOccurrences(of: " Pro Stream Webcam", with: "")
            .replacingOccurrences(of: " Webcam", with: "")
            .replacingOccurrences(of: "Logitech ", with: "")
    }
    var modelKey: String { camera.modelKey }

    func has(_ key: String) -> Bool { values[key] != nil }

    struct Snapshot: Sendable {
        var values: [String: CameraValue]
        var current: [String: Int]
        var autoExposureMode: Int
    }

    func probe() async -> Snapshot {
        let cam = camera
        return await withCheckedContinuation { cont in
            io.async {
                var values: [String: CameraValue] = [:]
                var current: [String: Int] = [:]
                for spec in cam.supportedControls {
                    guard let cur = try? cam.read(spec) else { continue }
                    let ranges = cam.ranges(spec) ?? cur.map { UVCRange(min: 0, max: 1, step: 1, defaultValue: $0) }
                    if spec.key == "panTilt" {
                        for (i, key) in ["pan", "tilt"].enumerated() where i < cur.count {
                            values[key] = CameraValue(key: key, title: key == "pan" ? "Pan" : "Tilt", spec: spec, component: i, range: ranges[i])
                            current[key] = cur[i]
                        }
                    } else {
                        values[spec.key] = CameraValue(key: spec.key, title: spec.title, spec: spec, component: 0, range: ranges[0])
                        current[spec.key] = cur[0]
                    }
                }
                let mask = cam.aeModeMask()
                let auto = [8, 2, 4].first { mask & $0 != 0 } ?? 8
                cont.resume(returning: Snapshot(values: values, current: current, autoExposureMode: auto))
            }
        }
    }

    func adopt(_ s: Snapshot) {
        values = s.values
        autoExposureMode = s.autoExposureMode
        applied = s.current
        settings = CameraSettings(values: s.current)
        isReady = true
    }

    /// Hardware defaults (GET_DEF) for every supported value.
    var defaults: CameraSettings {
        var d = CameraSettings()
        for (k, v) in values { d.values[k] = v.range.defaultValue }
        if values["aeMode"] != nil { d.values["aeMode"] = autoExposureMode }
        return d
    }

    // MARK: Convenience accessors used by the UI

    var autoExposure: Bool { (settings.values["aeMode"] ?? autoExposureMode) != 1 }
    var autoFocus: Bool { (settings.values["focusAuto"] ?? 1) != 0 }
    var autoWhiteBalance: Bool { (settings.values["whiteBalanceAuto"] ?? 1) != 0 }

    /// Write order matters: auto-mode switches first, zoom before pan/tilt, and manual values
    /// only when their auto mode is off (the camera STALLs otherwise).
    private static let order = ["aeMode", "aePriority", "focusAuto", "whiteBalanceAuto", "powerLine", "zoom", "pan", "tilt",
                                "exposure", "focus", "whiteBalance", "brightness", "contrast", "saturation", "sharpness",
                                "gain", "backlight", "hue", "gamma"]

    func apply(_ newSettings: CameraSettings, force: Bool = false) {
        var clamped = newSettings
        for (k, v) in clamped.values {
            guard let info = values[k], !["aeMode"].contains(k) else { continue }
            clamped.values[k] = min(info.range.max, max(info.range.min, v))
        }
        settings = clamped
        if force { applied = [:] }
        pending = clamped
        guard !writeScheduled else { return }
        writeScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.06) { [weak self] in self?.flush() }
    }

    private func flush() {
        writeScheduled = false
        guard let target = pending else { return }
        pending = nil
        let previous = applied
        let values = self.values
        let cam = camera
        var newApplied = previous
        var writes: [(UVCControlSpec, [Int], [String])] = []
        let autoExp = (target.values["aeMode"] ?? autoExposureMode) != 1
        let autoFocus = (target.values["focusAuto"] ?? 1) != 0
        let autoWB = (target.values["whiteBalanceAuto"] ?? 1) != 0

        var handledPanTilt = false
        for key in Self.order {
            guard let info = values[key], let v = target.values[key] else { continue }
            if key == "exposure" && autoExp { continue }
            if key == "focus" && autoFocus { continue }
            if key == "whiteBalance" && autoWB { continue }
            if key == "pan" || key == "tilt" {
                guard !handledPanTilt else { continue }
                let pan = target.values["pan"] ?? 0, tilt = target.values["tilt"] ?? 0
                if previous["pan"] != pan || previous["tilt"] != tilt {
                    writes.append((info.spec, [pan, tilt], ["pan", "tilt"]))
                    newApplied["pan"] = pan; newApplied["tilt"] = tilt
                }
                handledPanTilt = true
                continue
            }
            if previous[key] != v {
                writes.append((info.spec, [v], [key]))
                newApplied[key] = v
            }
        }
        applied = newApplied
        guard !writes.isEmpty else { return }
        io.async { [weak self] in
            var errors: [String] = []
            for (spec, vals, keys) in writes {
                do { try cam.write(spec, vals) } catch { errors.append("\(keys.joined(separator: "/")): \(error)") }
            }
            let message = errors.isEmpty ? nil : errors.joined(separator: "\n")
            DispatchQueue.main.async {
                guard let self else { return }
                self.lastError = message
                if message != nil { for (_, _, keys) in writes { for k in keys { self.applied[k] = nil } } }
            }
        }
    }

    /// Re-reads values the camera computes itself while in auto modes (exposure, focus, WB).
    func refreshAutoValues() {
        let cam = camera
        let specs = values.values.filter { ["exposure", "focus", "whiteBalance"].contains($0.key) }
        io.async { [weak self] in
            var read: [String: Int] = [:]
            for v in specs { if let r = try? cam.read(v.spec) { read[v.key] = r[v.component] } }
            DispatchQueue.main.async {
                guard let self else { return }
                for (k, v) in read {
                    let isAuto = (k == "exposure" && self.autoExposure) || (k == "focus" && self.autoFocus)
                        || (k == "whiteBalance" && self.autoWhiteBalance)
                    if isAuto { self.settings.values[k] = v; self.applied[k] = v }
                }
            }
        }
    }
}
