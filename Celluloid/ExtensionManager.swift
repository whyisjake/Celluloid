//
//  ExtensionManager.swift
//  Celluloid
//
//  Created by Jake Spurlock on 12/11/25.
//

import Foundation
import SystemExtensions
import AVFoundation
import Combine
import os.log

class ExtensionManager: NSObject, ObservableObject, OSSystemExtensionRequestDelegate {

    static let shared = ExtensionManager()

    @Published var extensionStatus: String = "Not Installed"
    @Published var isInstalled = false
    @Published var needsApproval = false

    private let logger = Logger(subsystem: "com.jakespurlock.Celluloid", category: "ExtensionManager")
    private let extensionIdentifier = "jakespurlock.Celluloid.CelluloidCameraExtension"

    override init() {
        super.init()
        checkForVirtualCamera()
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
            } else {
                self.extensionStatus = "Not Installed"
                self.isInstalled = false
                print("Celluloid camera not found among \(cameras.count) cameras")
            }
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
                case 1: // Not in /Applications
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
