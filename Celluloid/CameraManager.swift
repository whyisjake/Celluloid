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
import CoreMediaIO

private let logger = Logger(subsystem: "com.jakespurlock.Celluloid", category: "CameraManager")

// Shared constants for frame format
struct CelluloidShared {
    static let width = 1280
    static let height = 720
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
    @MainActor @Published var sharpness: Double = 0.0    // 0.0 to 2.0

    // Filter
    @MainActor @Published var selectedFilter: FilterType = .none

    private let captureSession = AVCaptureSession()
    private let videoOutput = AVCaptureVideoDataOutput()
    private let sessionQueue = DispatchQueue(label: "com.celluloid.sessionQueue")
    private let context = CIContext()

    // CoreMediaIO sink stream for sending frames to the camera extension
    private var sinkStreamID: CMIOStreamID = 0
    private var sinkDeviceID: CMIODeviceID = 0
    private var sinkQueue: CMSimpleQueue?
    private var isConnectedToSinkStream = false
    private var readyToEnqueue = false
    private let sinkConnectionQueue = DispatchQueue(label: "com.celluloid.sinkConnection")

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
        Task { @MainActor in
            await checkPermission()
            loadAvailableCameras()
            if permissionGranted {
                startSession()
            }
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
                logger.error("Error setting up camera input: \(error.localizedDescription)")
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

            // Connect to the virtual camera's sink stream
            self.connectToSinkStream()

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
        sharpness = 0.0
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

        // Apply sharpness adjustment
        if sharpness > 0 {
            if let sharpenFilter = CIFilter(name: "CISharpenLuminance") {
                sharpenFilter.setValue(outputImage, forKey: kCIInputImageKey)
                sharpenFilter.setValue(sharpness, forKey: kCIInputSharpnessKey)
                if let result = sharpenFilter.outputImage {
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

    // MARK: - CoreMediaIO Sink Stream Connection

    private func connectToSinkStream() {
        sinkConnectionQueue.async { [weak self] in
            self?.performSinkStreamConnection()
        }
    }

    private func performSinkStreamConnection() {
        // Allow apps to access camera extensions
        var allow: UInt32 = 1
        var propAddress = CMIOObjectPropertyAddress(
            mSelector: CMIOObjectPropertySelector(kCMIOHardwarePropertyAllowScreenCaptureDevices),
            mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
            mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain)
        )
        CMIOObjectSetPropertyData(
            CMIOObjectID(kCMIOObjectSystemObject),
            &propAddress,
            0,
            nil,
            UInt32(MemoryLayout<UInt32>.size),
            &allow
        )

        // Get all devices
        var dataSize: UInt32 = 0
        var devicesAddress = CMIOObjectPropertyAddress(
            mSelector: CMIOObjectPropertySelector(kCMIOHardwarePropertyDevices),
            mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
            mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain)
        )

        var status = CMIOObjectGetPropertyDataSize(
            CMIOObjectID(kCMIOObjectSystemObject),
            &devicesAddress,
            0,
            nil,
            &dataSize
        )

        guard status == noErr else {
            logger.error("Failed to get devices data size: \(status)")
            return
        }

        let deviceCount = Int(dataSize) / MemoryLayout<CMIODeviceID>.size
        var deviceIDs = [CMIODeviceID](repeating: 0, count: deviceCount)

        status = CMIOObjectGetPropertyData(
            CMIOObjectID(kCMIOObjectSystemObject),
            &devicesAddress,
            0,
            nil,
            dataSize,
            &dataSize,
            &deviceIDs
        )

        guard status == noErr else {
            logger.error("Failed to get devices: \(status)")
            return
        }

        logger.info("Found \(deviceCount) CMIO devices")

        // Find Celluloid Camera device
        for deviceID in deviceIDs {
            if let name = getDeviceName(deviceID), name.contains("Celluloid") {
                logger.info("Found Celluloid Camera device: \(name)")
                findSinkStream(for: deviceID)
                return
            }
        }

        logger.info("Celluloid Camera device not found - extension may not be loaded")
    }

    private func getDeviceName(_ deviceID: CMIODeviceID) -> String? {
        var nameAddress = CMIOObjectPropertyAddress(
            mSelector: CMIOObjectPropertySelector(kCMIOObjectPropertyName),
            mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
            mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain)
        )

        var name: CFString?
        var dataSize = UInt32(MemoryLayout<CFString?>.size)

        let status = CMIOObjectGetPropertyData(
            deviceID,
            &nameAddress,
            0,
            nil,
            dataSize,
            &dataSize,
            &name
        )

        guard status == noErr, let deviceName = name else {
            return nil
        }

        return deviceName as String
    }

    private func findSinkStream(for deviceID: CMIODeviceID) {
        self.sinkDeviceID = deviceID

        var streamsAddress = CMIOObjectPropertyAddress(
            mSelector: CMIOObjectPropertySelector(kCMIODevicePropertyStreams),
            mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
            mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain)
        )

        var dataSize: UInt32 = 0
        var status = CMIOObjectGetPropertyDataSize(deviceID, &streamsAddress, 0, nil, &dataSize)

        guard status == noErr else {
            logger.error("Failed to get streams data size: \(status)")
            return
        }

        let streamCount = Int(dataSize) / MemoryLayout<CMIOStreamID>.size
        var streamIDs = [CMIOStreamID](repeating: 0, count: streamCount)

        status = CMIOObjectGetPropertyData(deviceID, &streamsAddress, 0, nil, dataSize, &dataSize, &streamIDs)

        guard status == noErr else {
            logger.error("Failed to get streams: \(status)")
            return
        }

        logger.info("Found \(streamCount) streams for Celluloid device")

        // Find the sink stream by name "Input"
        for streamID in streamIDs {
            if let name = getStreamName(streamID), name.contains("Input") {
                logger.info("Found sink stream: \(name)")
                connectToStream(streamID)
                return
            }
        }

        logger.warning("No sink stream found on Celluloid device")
    }

    private func getStreamName(_ streamID: CMIOStreamID) -> String? {
        var nameAddress = CMIOObjectPropertyAddress(
            mSelector: CMIOObjectPropertySelector(kCMIOObjectPropertyName),
            mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
            mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain)
        )

        var name: CFString?
        var dataSize = UInt32(MemoryLayout<CFString?>.size)

        let status = CMIOObjectGetPropertyData(streamID, &nameAddress, 0, nil, dataSize, &dataSize, &name)

        guard status == noErr, let streamName = name else {
            return nil
        }

        return streamName as String
    }

    private func connectToStream(_ streamID: CMIOStreamID) {
        self.sinkStreamID = streamID

        let refCon = Unmanaged.passUnretained(self).toOpaque()
        var queue: Unmanaged<CMSimpleQueue>?

        let status = CMIOStreamCopyBufferQueue(
            streamID,
            { (streamID: CMIOStreamID, token: UnsafeMutableRawPointer?, refcon: UnsafeMutableRawPointer?) in
                guard let refcon = refcon else { return }
                let manager = Unmanaged<CameraManager>.fromOpaque(refcon).takeUnretainedValue()
                manager.readyToEnqueue = true
            },
            refCon,
            &queue
        )

        if status == noErr, let simpleQueue = queue?.takeRetainedValue() {
            self.sinkQueue = simpleQueue

            let startStatus = CMIODeviceStartStream(sinkDeviceID, streamID)

            if startStatus == noErr {
                self.isConnectedToSinkStream = true
                self.readyToEnqueue = true
                logger.info("Connected to sink stream")
            } else {
                logger.error("Failed to start sink stream: \(startStatus)")
            }
        } else {
            logger.error("Failed to get buffer queue: \(status)")
        }
    }

    private var framesSentCount = 0

    private func sendFrameToSinkStream(_ sampleBuffer: CMSampleBuffer) {
        guard isConnectedToSinkStream, let queue = sinkQueue else {
            if !isConnectedToSinkStream {
                connectToSinkStream()
            }
            return
        }

        guard readyToEnqueue else { return }

        readyToEnqueue = false

        let enqueueStatus = CMSimpleQueueEnqueue(queue, element: Unmanaged.passRetained(sampleBuffer).toOpaque())
        if enqueueStatus != noErr {
            logger.error("Failed to enqueue buffer: \(enqueueStatus)")
            readyToEnqueue = true
        } else {
            framesSentCount += 1
        }
    }

    private func createSampleBuffer(from cgImage: CGImage) -> CMSampleBuffer? {
        let width = CelluloidShared.width
        let height = CelluloidShared.height

        var pixelBuffer: CVPixelBuffer?
        let attrs: [CFString: Any] = [
            kCVPixelBufferCGImageCompatibilityKey: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey: true,
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary
        ]

        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            width,
            height,
            kCVPixelFormatType_32BGRA,
            attrs as CFDictionary,
            &pixelBuffer
        )

        guard status == kCVReturnSuccess, let buffer = pixelBuffer else {
            return nil
        }

        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }

        guard let context = CGContext(
            data: CVPixelBufferGetBaseAddress(buffer),
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        ) else {
            return nil
        }

        context.interpolationQuality = .high
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))

        var formatDescription: CMFormatDescription?
        CMVideoFormatDescriptionCreateForImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: buffer,
            formatDescriptionOut: &formatDescription
        )

        guard let format = formatDescription else { return nil }

        let currentTime = CMClockGetTime(CMClockGetHostTimeClock())
        var timingInfo = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: 30),
            presentationTimeStamp: currentTime,
            decodeTimeStamp: .invalid
        )

        var sampleBuffer: CMSampleBuffer?
        CMSampleBufferCreateReadyWithImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: buffer,
            formatDescription: format,
            sampleTiming: &timingInfo,
            sampleBufferOut: &sampleBuffer
        )

        return sampleBuffer
    }
}

extension CameraManager: AVCaptureVideoDataOutputSampleBufferDelegate {
    nonisolated func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }

        let ciImage = CIImage(cvPixelBuffer: pixelBuffer)

        Task { @MainActor [weak self] in
            guard let self = self else { return }
            let processedImage = self.applyFilters(to: ciImage)

            if let cgImage = self.context.createCGImage(processedImage, from: processedImage.extent) {
                self.currentFrame = cgImage

                self.sinkConnectionQueue.async { [weak self] in
                    guard let self = self else { return }
                    if let sampleBuffer = self.createSampleBuffer(from: cgImage) {
                        self.sendFrameToSinkStream(sampleBuffer)
                    }
                }
            }
        }
    }
}
