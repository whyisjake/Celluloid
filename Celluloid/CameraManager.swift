//
//  CameraManager.swift
//  Celluloid
//
//  Created by Jake Spurlock on 12/11/25.
//

@preconcurrency import AVFoundation
import CoreImage
import SwiftUI
import Combine
import os.log
import IOSurface

private let logger = Logger(subsystem: "com.jakespurlock.Celluloid", category: "CameraManager")

// Shared constants for frame sharing
struct CelluloidShared {
    static let width = 1280
    static let height = 720
    static let bytesPerRow = width * 4
    static let frameSize = bytesPerRow * height
    // App Group for shared UserDefaults - must match entitlements
    static let appGroupID = "36ERVRQ23S.com.jakespurlock.Celluloid"
    static let surfaceIDKey = "IOSurfaceID"
}

class CameraManager: NSObject, ObservableObject {
    @MainActor @Published var currentFrame: CGImage?
    @MainActor @Published var isRunning = false
    @MainActor @Published var permissionGranted = false
    @MainActor @Published var availableCameras: [AVCaptureDevice] = []
    @MainActor @Published var selectedCamera: AVCaptureDevice?

    // Adjustment controls
    @MainActor @Published var brightness: Double = 0.0  // -1.0 to 1.0
    @MainActor @Published var contrast: Double = 1.0    // 0.25 to 4.0
    @MainActor @Published var saturation: Double = 1.0  // 0.0 to 2.0
    @MainActor @Published var exposure: Double = 0.0    // -2.0 to 2.0
    @MainActor @Published var temperature: Double = 6500 // 2000 to 10000 (Kelvin)

    // Filter
    @MainActor @Published var selectedFilter: FilterType = .none

    private let captureSession = AVCaptureSession()
    private let videoOutput = AVCaptureVideoDataOutput()
    private let sessionQueue = DispatchQueue(label: "com.celluloid.sessionQueue")
    private let context = CIContext()

    // IOSurface for sharing frames with the camera extension
    private var sharedSurface: IOSurface?
    private let surfaceQueue = DispatchQueue(label: "com.celluloid.surfaceQueue")
    private var surfaceID: IOSurfaceID = 0

    enum FilterType: String, CaseIterable, Identifiable, Sendable {
        case none = "None"
        case noir = "Noir"
        case chrome = "Chrome"
        case fade = "Fade"
        case instant = "Instant"
        case mono = "Mono"
        case process = "Process"
        case tonal = "Tonal"
        case transfer = "Transfer"

        var id: String { rawValue }

        var ciFilterName: String? {
            switch self {
            case .none: return nil
            case .noir: return "CIPhotoEffectNoir"
            case .chrome: return "CIPhotoEffectChrome"
            case .fade: return "CIPhotoEffectFade"
            case .instant: return "CIPhotoEffectInstant"
            case .mono: return "CIPhotoEffectMono"
            case .process: return "CIPhotoEffectProcess"
            case .tonal: return "CIPhotoEffectTonal"
            case .transfer: return "CIPhotoEffectTransfer"
            }
        }
    }

    override init() {
        super.init()
        setupIOSurface()
        Task { @MainActor in
            await checkPermission()
            loadAvailableCameras()
            // Auto-start camera if permission is granted
            if permissionGranted {
                startSession()
            }
        }
    }

    // Static storage for CFMessagePort callback
    private static var sharedSurfaceID: IOSurfaceID = 0

    private func setupIOSurface() {
        let properties: [IOSurfacePropertyKey: Any] = [
            .width: CelluloidShared.width,
            .height: CelluloidShared.height,
            .bytesPerElement: 4,
            .bytesPerRow: CelluloidShared.bytesPerRow,
            .allocSize: CelluloidShared.frameSize,
            .pixelFormat: kCVPixelFormatType_32BGRA
        ]

        guard let surface = IOSurface(properties: properties) else {
            logger.error("Failed to create IOSurface")
            return
        }

        sharedSurface = surface
        let newSurfaceID = IOSurfaceGetID(surface)
        surfaceID = newSurfaceID
        CameraManager.sharedSurfaceID = newSurfaceID

        logger.info("Created IOSurface with ID: \(newSurfaceID)")

        // Broadcast surface ID to extension via distributed notifications
        broadcastSurfaceID()
    }

    private func broadcastSurfaceID() {
        let currentSurfaceID = self.surfaceID

        // Write to the extension's own preferences domain
        // The extension should be able to read its own preferences
        let extensionBundleID = "jakespurlock.Celluloid.CelluloidCameraExtension" as CFString
        let key = CelluloidShared.surfaceIDKey as CFString

        CFPreferencesSetValue(key, currentSurfaceID as CFNumber, extensionBundleID, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)

        if CFPreferencesSynchronize(extensionBundleID, kCFPreferencesCurrentUser, kCFPreferencesAnyHost) {
            logger.info("Wrote IOSurface ID \(currentSurfaceID) to extension's preferences")
        } else {
            logger.error("Failed to write to extension's preferences")
        }

        // Also write to App Group UserDefaults as backup
        if let sharedDefaults = UserDefaults(suiteName: CelluloidShared.appGroupID) {
            sharedDefaults.set(Int(currentSurfaceID), forKey: CelluloidShared.surfaceIDKey)
            sharedDefaults.synchronize()
            logger.info("Also wrote IOSurface ID \(currentSurfaceID) to App Group UserDefaults")
        }
    }

    @MainActor
    func checkPermission() async {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            permissionGranted = true
        case .notDetermined:
            permissionGranted = await AVCaptureDevice.requestAccess(for: .video)
        default:
            permissionGranted = false
        }
    }

    @MainActor
    func loadAvailableCameras() {
        let discoverySession = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera, .external],
            mediaType: .video,
            position: .unspecified
        )
        // Filter out our own virtual camera to prevent feedback loop
        availableCameras = discoverySession.devices.filter { !$0.localizedName.contains("Celluloid") }
        if selectedCamera == nil {
            selectedCamera = availableCameras.first
        }
    }

    @MainActor
    func startSession() {
        guard permissionGranted, let camera = selectedCamera else { return }

        sessionQueue.async { [weak self] in
            guard let self = self else { return }

            self.captureSession.beginConfiguration()
            self.captureSession.sessionPreset = .high

            // Remove existing inputs
            for input in self.captureSession.inputs {
                self.captureSession.removeInput(input)
            }

            // Add camera input
            do {
                let input = try AVCaptureDeviceInput(device: camera)
                if self.captureSession.canAddInput(input) {
                    self.captureSession.addInput(input)
                }
            } catch {
                print("Error setting up camera input: \(error)")
                return
            }

            // Add video output
            if self.captureSession.canAddOutput(self.videoOutput) {
                self.captureSession.addOutput(self.videoOutput)
                self.videoOutput.videoSettings = [
                    kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
                ]
                self.videoOutput.setSampleBufferDelegate(self, queue: DispatchQueue(label: "com.celluloid.videoQueue"))
                self.videoOutput.alwaysDiscardsLateVideoFrames = true
            }

            self.captureSession.commitConfiguration()
            self.captureSession.startRunning()

            Task { @MainActor in
                self.isRunning = true
            }
        }
    }

    @MainActor
    func stopSession() {
        sessionQueue.async { [weak self] in
            guard let self = self else { return }
            self.captureSession.stopRunning()
            Task { @MainActor [weak self] in
                self?.isRunning = false
            }
        }
    }

    @MainActor
    func switchCamera(to device: AVCaptureDevice) {
        selectedCamera = device
        if isRunning {
            stopSession()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                self?.startSession()
            }
        }
    }

    @MainActor
    func resetAdjustments() {
        brightness = 0.0
        contrast = 1.0
        saturation = 1.0
        exposure = 0.0
        temperature = 6500
        selectedFilter = .none
    }

    @MainActor
    private func applyFilters(to image: CIImage) -> CIImage {
        var outputImage = image

        // Apply color controls (brightness, contrast, saturation)
        if let colorControls = CIFilter(name: "CIColorControls") {
            colorControls.setValue(outputImage, forKey: kCIInputImageKey)
            colorControls.setValue(brightness, forKey: kCIInputBrightnessKey)
            colorControls.setValue(contrast, forKey: kCIInputContrastKey)
            colorControls.setValue(saturation, forKey: kCIInputSaturationKey)
            if let result = colorControls.outputImage {
                outputImage = result
            }
        }

        // Apply exposure adjustment
        if exposure != 0 {
            if let exposureFilter = CIFilter(name: "CIExposureAdjust") {
                exposureFilter.setValue(outputImage, forKey: kCIInputImageKey)
                exposureFilter.setValue(exposure, forKey: kCIInputEVKey)
                if let result = exposureFilter.outputImage {
                    outputImage = result
                }
            }
        }

        // Apply temperature adjustment
        if temperature != 6500 {
            if let tempFilter = CIFilter(name: "CITemperatureAndTint") {
                tempFilter.setValue(outputImage, forKey: kCIInputImageKey)
                let neutral = CIVector(x: CGFloat(temperature), y: 0)
                tempFilter.setValue(neutral, forKey: "inputNeutral")
                tempFilter.setValue(CIVector(x: 6500, y: 0), forKey: "inputTargetNeutral")
                if let result = tempFilter.outputImage {
                    outputImage = result
                }
            }
        }

        // Apply photo effect filter
        if let filterName = selectedFilter.ciFilterName,
           let photoFilter = CIFilter(name: filterName) {
            photoFilter.setValue(outputImage, forKey: kCIInputImageKey)
            if let result = photoFilter.outputImage {
                outputImage = result
            }
        }

        return outputImage
    }

    private func writeFrameToIOSurface(_ cgImage: CGImage) {
        guard let surface = sharedSurface else { return }

        surface.lock(options: [], seed: nil)
        defer { surface.unlock(options: [], seed: nil) }

        let baseAddress = surface.baseAddress
        let targetWidth = CelluloidShared.width
        let targetHeight = CelluloidShared.height
        let bytesPerRow = surface.bytesPerRow

        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                data: baseAddress,
                width: targetWidth,
                height: targetHeight,
                bitsPerComponent: 8,
                bytesPerRow: bytesPerRow,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
              ) else {
            logger.error("Failed to create CGContext for IOSurface")
            return
        }

        context.interpolationQuality = .high
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: targetWidth, height: targetHeight))
        // Frame is now available in the IOSurface - extension polls for it
    }
}

extension CameraManager: AVCaptureVideoDataOutputSampleBufferDelegate {
    nonisolated func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
            logger.error("No pixel buffer in sample buffer")
            return
        }

        let ciImage = CIImage(cvPixelBuffer: pixelBuffer)

        Task { @MainActor [weak self] in
            guard let self = self else { return }
            let processedImage = self.applyFilters(to: ciImage)

            if let cgImage = self.context.createCGImage(processedImage, from: processedImage.extent) {
                self.currentFrame = cgImage

                // Write to IOSurface for camera extension
                self.surfaceQueue.async { [weak self] in
                    self?.writeFrameToIOSurface(cgImage)
                }
            }
        }
    }
}
