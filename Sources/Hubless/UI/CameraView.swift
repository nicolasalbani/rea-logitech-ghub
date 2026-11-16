import SwiftUI
import AVFoundation

struct CameraView: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var camera: CameraController
    @State private var showPreview = false
    @State private var tick = Timer.publish(every: 1.5, on: .main, in: .common).autoconnect()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header
                if let err = camera.lastError { ErrorBanner(message: err) }
                previewCard
                HStack(alignment: .top, spacing: 16) {
                    VStack(spacing: 16) {
                        framingCard
                        focusCard
                    }
                    VStack(spacing: 16) {
                        exposureCard
                        imageCard
                    }
                }
            }
            .padding(28)
            .frame(maxWidth: 1080, alignment: .leading)
        }
        .onReceive(tick) { _ in camera.refreshAutoValues() }
    }

    private var header: some View {
        HStack(spacing: 24) {
            CameraArt(size: 90).frame(width: 200)
            VStack(alignment: .leading, spacing: 6) {
                Text(camera.shortName).font(.system(size: 30, weight: .bold))
                Text(camera.name).foregroundStyle(Theme.secondaryText)
                HStack(spacing: 6) {
                    StatusDot(ok: camera.isReady)
                    Text("Connected · Profile: \(model.activeProfile.name)").font(.caption).foregroundStyle(Theme.secondaryText)
                }
            }
            Spacer()
            Button {
                model.update(camera) { $0 = camera.defaults }
            } label: { Label("Restore Defaults", systemImage: "arrow.counterclockwise") }
        }
    }

    // MARK: Preview

    private var previewCard: some View {
        Card(padding: 14) {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    SectionTitle(title: "Preview")
                    Spacer()
                    Toggle("Live preview", isOn: $showPreview).toggleStyle(.switch)
                }
                ZStack {
                    RoundedRectangle(cornerRadius: 10).fill(Color.black)
                    if showPreview {
                        CameraPreview(vendorID: camera.camera.vendorID, productID: camera.camera.productID)
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                    } else {
                        HStack(spacing: 8) {
                            Image(systemName: "video.slash")
                            Text("Preview is off — turn it on to see changes live").font(.caption)
                        }
                        .foregroundStyle(Theme.secondaryText)
                    }
                }
                .aspectRatio(showPreview ? 16 / 9 : 6, contentMode: .fit)
                .frame(maxHeight: showPreview ? 360 : 70)
            }
        }
    }

    // MARK: Groups

    private var framingCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 14) {
                SectionTitle(title: "Framing", subtitle: "Pan and tilt work when zoomed in")
                slider("zoom") { "\(String(format: "%.1f", Double($0) / 100))×" }
                slider("pan", disabled: (camera.settings.values["zoom"] ?? 100) <= (camera.values["zoom"]?.range.min ?? 100)) { "\($0 / 3600)°" }
                slider("tilt", disabled: (camera.settings.values["zoom"] ?? 100) <= (camera.values["zoom"]?.range.min ?? 100)) { "\($0 / 3600)°" }
                if camera.has("pan") {
                    HStack {
                        Spacer()
                        Button("Center") { model.update(camera) { $0.values["pan"] = 0; $0.values["tilt"] = 0 } }
                    }
                }
            }
        }
    }

    private var focusCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 14) {
                SectionTitle(title: "Focus")
                if camera.has("focusAuto") {
                    toggle("Autofocus", camera.autoFocus) { on in model.update(camera) { $0.values["focusAuto"] = on ? 1 : 0 } }
                }
                slider("focus", disabled: camera.autoFocus)
            }
        }
    }

    private var exposureCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 14) {
                SectionTitle(title: "Exposure & White Balance")
                if camera.has("aeMode") {
                    toggle("Auto exposure", camera.autoExposure) { on in
                        model.update(camera) { $0.values["aeMode"] = on ? camera.autoExposureMode : 1 }
                    }
                }
                slider("exposure", disabled: camera.autoExposure)
                if camera.has("aePriority") {
                    toggle("Low-light compensation", (camera.settings.values["aePriority"] ?? 0) != 0) { on in
                        model.update(camera) { $0.values["aePriority"] = on ? 1 : 0 }
                    }
                    .disabled(!camera.autoExposure).opacity(camera.autoExposure ? 1 : 0.4)
                }
                slider("gain")
                Divider().overlay(Theme.stroke)
                if camera.has("whiteBalanceAuto") {
                    toggle("Auto white balance", camera.autoWhiteBalance) { on in
                        model.update(camera) { $0.values["whiteBalanceAuto"] = on ? 1 : 0 }
                    }
                }
                slider("whiteBalance", disabled: camera.autoWhiteBalance) { "\($0)K" }
                if camera.has("powerLine") {
                    HStack {
                        Text("Anti-flicker").font(.system(size: 13, weight: .medium))
                        Spacer()
                        Picker("", selection: Binding(
                            get: { camera.settings.values["powerLine"] ?? 2 },
                            set: { v in model.update(camera) { $0.values["powerLine"] = v } })) {
                            let r = camera.values["powerLine"]!.range
                            if r.min <= 0 { Text("Off").tag(0) }
                            Text("50 Hz").tag(1)
                            Text("60 Hz").tag(2)
                            if r.max >= 3 { Text("Auto").tag(3) }
                        }
                        .pickerStyle(.segmented).labelsHidden().frame(width: 200)
                    }
                }
            }
        }
    }

    private var imageCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 14) {
                SectionTitle(title: "Image")
                slider("brightness")
                slider("contrast")
                slider("saturation")
                slider("sharpness")
                slider("hue")
                slider("gamma")
                if camera.has("backlight") {
                    toggle("Backlight compensation", (camera.settings.values["backlight"] ?? 0) != 0) { on in
                        model.update(camera) { $0.values["backlight"] = on ? (camera.values["backlight"]?.range.max ?? 1) : 0 }
                    }
                }
            }
        }
    }

    // MARK: Building blocks

    @ViewBuilder
    private func slider(_ key: String, disabled: Bool = false, format: @escaping (Int) -> String = { "\($0)" }) -> some View {
        if let info = camera.values[key] {
            ValueSlider(
                title: info.title,
                value: Binding(
                    get: { camera.settings.values[key] ?? info.range.defaultValue },
                    set: { v in model.update(camera) { $0.values[key] = v } }),
                range: info.range.min...info.range.max,
                step: info.range.step,
                format: format,
                disabled: disabled)
        }
    }

    private func toggle(_ title: String, _ value: Bool, _ set: @escaping (Bool) -> Void) -> some View {
        Toggle(isOn: Binding(get: { value }, set: set)) {
            Text(title).font(.system(size: 13, weight: .medium))
        }
        .toggleStyle(.switch)
    }
}

/// Live AVFoundation preview of the matching capture device.
struct CameraPreview: NSViewRepresentable {
    let vendorID: Int
    let productID: Int

    func makeNSView(context: Context) -> PreviewNSView {
        let v = PreviewNSView()
        v.start(vendorID: vendorID, productID: productID)
        return v
    }

    func updateNSView(_ nsView: PreviewNSView, context: Context) {}

    static func dismantleNSView(_ nsView: PreviewNSView, coordinator: ()) {
        nsView.stop()
    }
}

final class PreviewNSView: NSView {
    private let session = AVCaptureSession()
    private let label = NSTextField(labelWithString: "")

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        label.textColor = .secondaryLabelColor
        label.alignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([label.centerXAnchor.constraint(equalTo: centerXAnchor), label.centerYAnchor.constraint(equalTo: centerYAnchor)])
    }

    required init?(coder: NSCoder) { fatalError() }

    func start(vendorID: Int, productID: Int) {
        let begin = { [weak self] in
            guard let self else { return }
            let discovery = AVCaptureDevice.DiscoverySession(deviceTypes: [.external], mediaType: .video, position: .unspecified)
            let token = "VendorID_\(vendorID) ProductID_\(productID)"
            guard let device = discovery.devices.first(where: { $0.modelID.contains(token) }) ?? discovery.devices.first,
                  let input = try? AVCaptureDeviceInput(device: device), self.session.canAddInput(input) else {
                self.label.stringValue = "Camera not available"
                return
            }
            self.session.addInput(input)
            let preview = AVCaptureVideoPreviewLayer(session: self.session)
            preview.videoGravity = .resizeAspect
            preview.frame = self.bounds
            preview.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
            self.layer?.addSublayer(preview)
            DispatchQueue.global(qos: .userInitiated).async { self.session.startRunning() }
        }
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: begin()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { ok in
                DispatchQueue.main.async { ok ? begin() : (self.label.stringValue = "Camera access denied") }
            }
        default:
            label.stringValue = "Allow camera access in System Settings › Privacy & Security › Camera"
        }
    }

    func stop() {
        let s = session
        DispatchQueue.global(qos: .userInitiated).async { s.stopRunning() }
    }
}
