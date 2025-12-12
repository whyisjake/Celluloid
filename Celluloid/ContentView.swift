//
//  ContentView.swift
//  Celluloid
//
//  Created by Jake Spurlock on 12/11/25.
//

import SwiftUI

struct ContentView: View {
    @EnvironmentObject var cameraManager: CameraManager

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
                // Scrollable content
                ScrollView {
                    VStack(spacing: 0) {
                        // Camera Preview (mirrored like a mirror)
                        CameraPreviewView(image: cameraManager.currentFrame)
                            .scaleEffect(x: -1, y: 1)
                            .frame(width: 320, height: 180)
                            .cornerRadius(8)
                            .padding()

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
                            .padding(.bottom)
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
                        .foregroundColor(extensionManager.isInstalled ? .green : .secondary)
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
                } else if extensionManager.needsApproval {
                    Button("Open Settings") {
                        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension")!)
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

            if !extensionManager.isInstalled {
                if extensionManager.needsApproval {
                    Text("Click Open Settings, then enable Celluloid under Camera Extensions.")
                        .font(.caption2)
                        .foregroundColor(.orange)
                } else {
                    Text("Click Install to enable virtual camera. App must be in /Applications folder.")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
            } else {
                Text("Select 'Celluloid Camera' in Zoom or other video apps.")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
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

import AVFoundation

#Preview {
    ContentView()
        .environmentObject(CameraManager())
}
