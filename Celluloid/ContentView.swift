//
//  ContentView.swift
//  Celluloid
//
//  Created by Jake Spurlock on 12/11/25.
//

import SwiftUI

struct ContentView: View {
    @EnvironmentObject var cameraManager: CameraManager
    @ObservedObject var extensionManager = ExtensionManager.shared

    var body: some View {
        VStack(spacing: 0) {
            // Header (fixed at top)
            HStack {
                Text("Celluloid")
                    .font(.headline)
                Spacer()
                Button(action: {
                    NSApplication.shared.terminate(nil)
                }) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal)
            .padding(.vertical, 8)

            Divider()

            if cameraManager.permissionGranted {
                // Warning banner if extension needs enabling
                if extensionManager.needsCameraExtensionEnabled {
                    ExtensionWarningBanner(extensionManager: extensionManager)
                }

                // Scrollable content
                ScrollView {
                    VStack(spacing: 0) {
                        // Camera Preview with Crop Overlay (mirrored like a mirror)
                        ZStack {
                            CameraPreviewView(image: cameraManager.currentFrame)
                                .scaleEffect(x: -1, y: 1)
                            
                            CropOverlayView(cameraManager: cameraManager)
                                .scaleEffect(x: -1, y: 1)
                        }
                        .frame(width: 320, height: 180)
                        .cornerRadius(8)
                        .padding()

                        // Zoom slider (below video, above camera selector)
                        AdjustmentSlider(
                            title: "Zoom",
                            value: $cameraManager.zoomLevel,
                            range: 1.0...4.0,
                            icon: "magnifyingglass"
                        )
                        .padding(.horizontal)
                        .padding(.bottom, 8)

                        // Camera selector
                        if cameraManager.availableCameras.count > 1 {
                            Picker("Camera", selection: Binding(
                                get: { cameraManager.selectedCamera },
                                set: { if let device = $0 { cameraManager.switchCamera(to: device) } }
                            )) {
                                ForEach(cameraManager.availableCameras, id: \.uniqueID) { camera in
                                    Text(camera.localizedName).tag(camera as AVCaptureDevice?)
                                }
                            }
                            .pickerStyle(.menu)
                            .padding(.horizontal)
                        }

                        Divider()
                            .padding(.vertical, 8)

                        // Adjustments Section
                        AdjustmentsSection(cameraManager: cameraManager)
                            .padding(.horizontal)

                        Divider()
                            .padding(.vertical, 8)

                        // Filters Section
                        FiltersSection(cameraManager: cameraManager)
                            .padding(.horizontal)

                        Divider()
                            .padding(.vertical, 8)

                        // LUT Section
                        LUTSection(cameraManager: cameraManager)
                            .padding(.horizontal)

                        // Virtual Camera Section (always show for visibility)
                        Divider()
                            .padding(.vertical, 8)

                        VirtualCameraSection(extensionManager: extensionManager)
                            .padding(.horizontal)

                        Spacer()
                            .frame(height: 16)
                    }
                }

                Divider()

                // Bottom controls (fixed at bottom)
                HStack {
                    Button(action: {
                        cameraManager.resetAdjustments()
                    }) {
                        Label("Reset All", systemImage: "arrow.counterclockwise")
                    }
                    .buttonStyle(.bordered)

                    Spacer()

                    // Camera status indicator
                    HStack(spacing: 4) {
                        Circle()
                            .fill(cameraManager.isRunning ? Color.green : Color.red)
                            .frame(width: 8, height: 8)
                        Text(cameraManager.isRunning ? "Active" : "Standby")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
                .padding()

                // Credits
                CreditsView()
            } else {
                // Permission denied view
                VStack(spacing: 16) {
                    Image(systemName: "camera.fill")
                        .font(.system(size: 48))
                        .foregroundColor(.secondary)

                    Text("Camera Access Required")
                        .font(.headline)

                    Text("Please grant camera access in System Settings to use Celluloid.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)

                    Button("Open System Settings") {
                        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Camera") {
                            NSWorkspace.shared.open(url)
                        }
                    }
                    .buttonStyle(.borderedProminent)
                }
                .padding(32)
            }
        }
        .frame(width: 360, height: 700)
        .onAppear {
            cameraManager.previewWindowOpened()
        }
        .onDisappear {
            cameraManager.previewWindowClosed()
        }
    }
}

struct CameraPreviewView: View {
    let image: CGImage?

    var body: some View {
        if let image = image {
            Image(decorative: image, scale: 1.0)
                .resizable()
                .aspectRatio(contentMode: .fit)
        } else {
            ZStack {
                Color.black
                ProgressView()
                    .progressViewStyle(.circular)
            }
        }
    }
}

struct CropOverlayView: View {
    @ObservedObject var cameraManager: CameraManager
    @State private var isDragging = false
    @State private var dragStartOffsetX: Double = 0.0
    @State private var dragStartOffsetY: Double = 0.0
    
    // Drag sensitivity - controls responsiveness of drag gesture
    private let dragSensitivity: CGFloat = 1.0
    
    var body: some View {
        GeometryReader { geometry in
            ZStack {
                // Semi-transparent overlay showing zoom is active
                if cameraManager.zoomLevel > 1.0 {
                    // Dimmed area outside crop
                    Rectangle()
                        .fill(Color.black.opacity(0.3))
                    
                    // Calculate crop rectangle position
                    let cropWidth = geometry.size.width / cameraManager.zoomLevel
                    let cropHeight = geometry.size.height / cameraManager.zoomLevel
                    let maxOffsetX = (geometry.size.width - cropWidth) / 2
                    let maxOffsetY = (geometry.size.height - cropHeight) / 2
                    let centerX = geometry.size.width / 2 + cameraManager.cropOffsetX * maxOffsetX
                    let centerY = geometry.size.height / 2 + cameraManager.cropOffsetY * maxOffsetY

                    // Clear rectangle showing the crop area
                    Rectangle()
                        .fill(.clear)
                        .frame(width: cropWidth, height: cropHeight)
                        .position(x: centerX, y: centerY)
                        .blendMode(.destinationOut)
                    
                    // Crop frame border
                    Rectangle()
                        .strokeBorder(Color.white, lineWidth: 2)
                        .frame(width: cropWidth, height: cropHeight)
                        .position(x: centerX, y: centerY)

                    // Center crosshair for better visual feedback
                    Path { path in
                        path.move(to: CGPoint(x: centerX - 10, y: centerY))
                        path.addLine(to: CGPoint(x: centerX + 10, y: centerY))
                        path.move(to: CGPoint(x: centerX, y: centerY - 10))
                        path.addLine(to: CGPoint(x: centerX, y: centerY + 10))
                    }
                    .stroke(Color.white, lineWidth: 1)
                }
            }
            .compositingGroup()
            .gesture(
                DragGesture()
                    .onChanged { value in
                        if cameraManager.zoomLevel > 1.0 {
                            if !isDragging {
                                // Store the starting position when drag begins
                                isDragging = true
                                dragStartOffsetX = cameraManager.cropOffsetX
                                dragStartOffsetY = cameraManager.cropOffsetY
                            }

                            // Offset range is -1 to 1, allowing crop to reach edges
                            let maxNormalizedOffset = 1.0
                            
                            // Convert drag translation to normalized offset change
                            let cropWidth = geometry.size.width / cameraManager.zoomLevel
                            let cropHeight = geometry.size.height / cameraManager.zoomLevel
                            let maxOffsetX = (geometry.size.width - cropWidth) / 2
                            let maxOffsetY = (geometry.size.height - cropHeight) / 2
                            
                            if maxOffsetX > 0 {
                                // Calculate offset change from drag start position
                                let deltaX = (value.translation.width / maxOffsetX) * dragSensitivity
                                let newOffsetX = dragStartOffsetX + deltaX
                                cameraManager.cropOffsetX = max(-maxNormalizedOffset, min(maxNormalizedOffset, newOffsetX))
                            }
                            if maxOffsetY > 0 {
                                // Calculate offset change from drag start position
                                let deltaY = (value.translation.height / maxOffsetY) * dragSensitivity
                                let newOffsetY = dragStartOffsetY + deltaY
                                cameraManager.cropOffsetY = max(-maxNormalizedOffset, min(maxNormalizedOffset, newOffsetY))
                            }
                        }
                    }
                    .onEnded { _ in
                        isDragging = false
                    }
            )
        }
    }
}

struct AdjustmentsSection: View {
    @ObservedObject var cameraManager: CameraManager

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Adjustments")
                .font(.subheadline)
                .fontWeight(.semibold)

            AdjustmentSlider(
                title: "Brightness",
                value: $cameraManager.brightness,
                range: -1.0...1.0,
                icon: "sun.max"
            )

            AdjustmentSlider(
                title: "Contrast",
                value: $cameraManager.contrast,
                range: 0.25...4.0,
                icon: "circle.lefthalf.filled"
            )

            AdjustmentSlider(
                title: "Saturation",
                value: $cameraManager.saturation,
                range: 0.0...2.0,
                icon: "drop.fill"
            )

            AdjustmentSlider(
                title: "Exposure",
                value: $cameraManager.exposure,
                range: -2.0...2.0,
                icon: "plusminus.circle"
            )

            AdjustmentSlider(
                title: "Temperature",
                value: $cameraManager.temperature,
                range: 2000...10000,
                icon: "thermometer"
            )

            AdjustmentSlider(
                title: "Sharpness",
                value: $cameraManager.sharpness,
                range: 0.0...2.0,
                icon: "triangle"
            )

            AdjustmentSlider(
                title: "Vignette",
                value: $cameraManager.vignette,
                range: 0.0...1.0,
                icon: "circle.dashed"
            )
        }
    }
}

struct AdjustmentSlider: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let icon: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Image(systemName: icon)
                    .frame(width: 20)
                    .foregroundColor(.secondary)
                Text(title)
                    .font(.caption)
                Spacer()
                Text(String(format: "%.2f", value))
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .monospacedDigit()
            }
            Slider(value: $value, in: range)
        }
    }
}

struct FiltersSection: View {
    @ObservedObject var cameraManager: CameraManager

    let columns = [
        GridItem(.adaptive(minimum: 70))
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Filters")
                .font(.subheadline)
                .fontWeight(.semibold)

            LazyVGrid(columns: columns, spacing: 8) {
                ForEach(CameraManager.FilterType.allCases) { filter in
                    FilterButton(
                        filter: filter,
                        isSelected: cameraManager.selectedFilter == filter
                    ) {
                        cameraManager.selectedFilter = filter
                    }
                }
            }
        }
    }
}

struct VirtualCameraSection: View {
    @ObservedObject var extensionManager: ExtensionManager

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Virtual Camera")
                .font(.subheadline)
                .fontWeight(.semibold)

            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Celluloid Camera")
                        .font(.caption)
                    Text(extensionManager.extensionStatus)
                        .font(.caption2)
                        .foregroundColor(statusColor)
                }

                Spacer()

                if extensionManager.isInstalled {
                    HStack(spacing: 8) {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundColor(.green)
                        Button("Update") {
                            extensionManager.activateExtension()
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                } else if extensionManager.needsCameraExtensionEnabled {
                    Button("Enable in Settings") {
                        extensionManager.openCameraExtensionSettings()
                    }
                    .buttonStyle(.borderedProminent)
                } else if extensionManager.needsApproval {
                    Button("Open Settings") {
                        extensionManager.openCameraExtensionSettings()
                    }
                    .buttonStyle(.borderedProminent)
                } else {
                    HStack(spacing: 8) {
                        Button("Install") {
                            extensionManager.activateExtension()
                        }
                        .buttonStyle(.borderedProminent)

                        Button(action: {
                            extensionManager.checkForVirtualCamera()
                        }) {
                            Image(systemName: "arrow.clockwise")
                        }
                        .buttonStyle(.bordered)
                    }
                }
            }
            .padding()
            .background(Color.secondary.opacity(0.1))
            .cornerRadius(8)

            // Help text based on state
            helpText
        }
    }

    private var statusColor: Color {
        if extensionManager.isInstalled {
            return .green
        } else if extensionManager.needsCameraExtensionEnabled {
            return .orange
        } else {
            return .secondary
        }
    }

    @ViewBuilder
    private var helpText: some View {
        if extensionManager.needsCameraExtensionEnabled {
            VStack(alignment: .leading, spacing: 4) {
                Text("Extension installed but needs to be enabled:")
                    .font(.caption2)
                    .foregroundColor(.orange)
                Text("System Settings → General → Login Items & Extensions → Camera Extensions → Enable Celluloid")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
        } else if extensionManager.needsApproval {
            Text("Click Open Settings, then enable Celluloid under Camera Extensions.")
                .font(.caption2)
                .foregroundColor(.orange)
        } else if !extensionManager.isInstalled {
            Text("Click Install to enable virtual camera. App must be in /Applications folder.")
                .font(.caption2)
                .foregroundColor(.secondary)
        } else {
            Text("Select 'Celluloid Camera' in Zoom, FaceTime, or other video apps.")
                .font(.caption2)
                .foregroundColor(.secondary)
        }
    }
}

struct LUTSection: View {
    @ObservedObject var cameraManager: CameraManager

    // List of common photography/film acronyms that should remain uppercase in LUT preset names.
    // Add to this list any acronyms that are expected to appear in LUT file names and should not be capitalized as regular words.
    private let acronyms = ["CCD", "HD", "II", "BW"]

    private func formatLUTName(_ name: String) -> String {
        let words = name.replacingOccurrences(of: "_", with: " ").components(separatedBy: " ")
        return words.map { word in
            let upper = word.uppercased()
            if acronyms.contains(upper) {
                return upper
            }
            return word.capitalized
        }.joined(separator: " ")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Film LUTs")
                .font(.subheadline)
                .fontWeight(.semibold)

            Picker("LUT", selection: Binding(
                get: { cameraManager.selectedLUT ?? "None" },
                set: { cameraManager.selectedLUT = $0 == "None" ? nil : $0 }
            )) {
                Text("None").tag("None")
                ForEach(cameraManager.availableLUTs) { lut in
                    Text(formatLUTName(lut.name))
                        .tag(lut.name)
                }
            }
            .pickerStyle(.menu)
        }
    }
}

struct FilterButton: View {
    let filter: CameraManager.FilterType
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(filter.rawValue)
                .font(.caption)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
                .background(isSelected ? Color.accentColor : Color.secondary.opacity(0.2))
                .foregroundColor(isSelected ? .white : .primary)
                .cornerRadius(6)
        }
        .buttonStyle(.plain)
    }
}

struct ExtensionWarningBanner: View {
    @ObservedObject var extensionManager: ExtensionManager

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundColor(.orange)

            Text("Virtual camera needs to be enabled")
                .font(.caption)
                .fontWeight(.medium)

            Spacer()

            Button("Enable") {
                extensionManager.openCameraExtensionSettings()
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
        }
        .padding(10)
        .background(Color.orange.opacity(0.15))
    }
}

import AVFoundation

struct CreditsView: View {
    var body: some View {
        VStack(spacing: 6) {
            Divider()

            HStack(spacing: 4) {
                Text("Made with")
                    .font(.caption2)
                    .foregroundColor(.secondary)
                Image(systemName: "heart.fill")
                    .font(.caption2)
                    .foregroundColor(.red)
                Text("in California by Jake Spurlock")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }

            HStack(spacing: 16) {
                Link(destination: URL(string: "https://twitter.com/whyisjake")!) {
                    Image(systemName: "at")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                Link(destination: URL(string: "https://github.com/whyisjake")!) {
                    Image(systemName: "chevron.left.forwardslash.chevron.right")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                Link(destination: URL(string: "https://www.linkedin.com/in/jakespurlock")!) {
                    Image(systemName: "person.crop.square")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                Link(destination: URL(string: "https://jakespurlock.com")!) {
                    Image(systemName: "globe")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
        }
        .padding(.bottom, 8)
    }
}

#Preview {
    ContentView()
        .environmentObject(CameraManager())
}
