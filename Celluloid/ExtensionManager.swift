//
//  ExtensionManager.swift
//  Celluloid
//
//  Created by Jake Spurlock on 12/11/25.
//

import Foundation
import SystemExtensions
import AVFoundation
import AppKit
import Combine
import os.log

class ExtensionManager: NSObject, ObservableObject, OSSystemExtensionRequestDelegate {

    static let shared = ExtensionManager()

    @Published var extensionStatus: String = "Not Installed"
    @Published var isInstalled = false
    @Published var needsApproval = false
    @Published var needsCameraExtensionEnabled = false

    private let logger = Logger(subsystem: "com.jakespurlock.Celluloid", category: "ExtensionManager")
    private let extensionIdentifier = "jakespurlock.Celluloid.CelluloidCameraExtension"
    private var statusCheckTimer: Timer?

    override init() {
        super.init()
        checkForVirtualCamera()
        // Auto-activate extension on launch to ensure latest version is installed
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            self?.activateExtension()
        }
        // Start periodic status checks to detect when user enables extension
        startStatusPolling()
    }

    deinit {
        statusCheckTimer?.invalidate()
    }

    /// Start polling for extension status changes (checks every 10 seconds when extension needs enabling)
    private func startStatusPolling() {
        statusCheckTimer = Timer.scheduledTimer(withTimeInterval: 10.0, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            // Only poll frequently if extension needs user action
            if self.needsCameraExtensionEnabled || !self.isInstalled {
                self.checkForVirtualCamera()
            }
        }
    }

    func activateExtension() {
        logger.info("Requesting activation of camera extension: \(self.extensionIdentifier)")
        extensionStatus = "Activating..."

        let request = OSSystemExtensionRequest.activationRequest(
            forExtensionWithIdentifier: extensionIdentifier,
            queue: .main
        )
        request.delegate = self
        OSSystemExtensionManager.shared.submitRequest(request)
    }

    func checkForVirtualCamera() {
        let discoverySession = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.external, .builtInWideAngleCamera],
            mediaType: .video,
            position: .unspecified
        )

        let cameras = discoverySession.devices
        logger.info("Found \(cameras.count) cameras:")
        for camera in cameras {
            logger.info("  - \(camera.localizedName)")
            print("Camera found: \(camera.localizedName)")
        }

        let found = cameras.contains { $0.localizedName.contains("Celluloid") }

        DispatchQueue.main.async {
            if found {
                self.extensionStatus = "Active"
                self.isInstalled = true
                self.needsCameraExtensionEnabled = false
            } else {
                // Check if extension is installed but not enabled
                self.checkExtensionEnabledStatus()
            }
        }
    }

    /// Check if extension is installed but waiting for user to enable in System Settings
    private func checkExtensionEnabledStatus() {
        // Run systemextensionsctl to check status
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/systemextensionsctl")
        task.arguments = ["list"]

        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = pipe

        do {
            try task.run()
            task.waitUntilExit()

            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            if let output = String(data: data, encoding: .utf8) {
                if output.contains(extensionIdentifier) {
                    // Extension is installed
                    if output.contains("waiting for user") {
                        // Installed but not enabled in Camera Extensions settings
                        self.extensionStatus = "Enable in System Settings"
                        self.needsCameraExtensionEnabled = true
                        self.isInstalled = false
                        logger.info("Extension installed but needs to be enabled in System Settings")
                    } else if output.contains("activated enabled") {
                        // Enabled but camera not showing - may need app restart
                        self.extensionStatus = "Restart video apps to use"
                        self.isInstalled = true
                        self.needsCameraExtensionEnabled = false
                    } else {
                        self.extensionStatus = "Not Installed"
                        self.isInstalled = false
                        self.needsCameraExtensionEnabled = false
                    }
                } else {
                    self.extensionStatus = "Not Installed"
                    self.isInstalled = false
                    self.needsCameraExtensionEnabled = false
                }
            }
        } catch {
            logger.error("Failed to check extension status: \(error.localizedDescription)")
            self.extensionStatus = "Not Installed"
            self.isInstalled = false
        }
    }

    /// Open System Settings to Camera Extensions pane
    func openCameraExtensionSettings() {
        // macOS 13+ URL for Login Items & Extensions
        if let url = URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: - OSSystemExtensionRequestDelegate

    func request(_ request: OSSystemExtensionRequest, actionForReplacingExtension existing: OSSystemExtensionProperties, withExtension ext: OSSystemExtensionProperties) -> OSSystemExtensionRequest.ReplacementAction {
        logger.info("Replacing existing extension")
        return .replace
    }

    func requestNeedsUserApproval(_ request: OSSystemExtensionRequest) {
        logger.info("Extension needs user approval")
        DispatchQueue.main.async {
            self.extensionStatus = "Needs Approval"
            self.needsApproval = true
        }
    }

    func request(_ request: OSSystemExtensionRequest, didFinishWithResult result: OSSystemExtensionRequest.Result) {
        logger.info("Extension request finished: \(result.rawValue)")
        DispatchQueue.main.async {
            switch result {
            case .completed:
                self.extensionStatus = "Installed - Restart apps to use"
                self.isInstalled = true
                self.checkForVirtualCamera()
            case .willCompleteAfterReboot:
                self.extensionStatus = "Restart required"
            @unknown default:
                self.extensionStatus = "Unknown"
            }
        }
    }

    func request(_ request: OSSystemExtensionRequest, didFailWithError error: Error) {
        logger.error("Extension request failed: \(error.localizedDescription)")
        DispatchQueue.main.async {
            let nsError = error as NSError
            if nsError.domain == OSSystemExtensionErrorDomain {
                switch nsError.code {
                case 1, 3: // unsupportedParentBundleLocation - Not in /Applications
                    self.extensionStatus = "Move app to /Applications"
                case 4: // Missing entitlement
                    self.extensionStatus = "Signing error"
                case 8: // Extension not found
                    self.extensionStatus = "Extension not found"
                default:
                    self.extensionStatus = "Error: \(nsError.code)"
                }
            } else {
                self.extensionStatus = "Error"
            }
        }
    }
}
