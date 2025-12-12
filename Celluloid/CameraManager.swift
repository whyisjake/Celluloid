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

    // Track what's requesting the camera
    @MainActor private var previewWindowIsOpen = false
    @MainActor private var externalAppIsStreaming = false

    // Adjustment controls (persisted)
    @MainActor @Published var brightness: Double = 0.0 {  // -1.0 to 1.0
        didSet { saveSettings() }
    }
    @MainActor @Published var contrast: Double = 1.0 {    // 0.25 to 4.0
        didSet { saveSettings() }
    }
    @MainActor @Published var saturation: Double = 1.0 {  // 0.0 to 2.0
        didSet { saveSettings() }
    }
    @MainActor @Published var exposure: Double = 0.0 {    // -2.0 to 2.0
        didSet { saveSettings() }
    }
    @MainActor @Published var temperature: Double = 6500 { // 2000 to 10000 (Kelvin)
        didSet { saveSettings() }
    }
    @MainActor @Published var sharpness: Double = 0.0 {    // 0.0 to 2.0
        didSet { saveSettings() }
    }

    // Filter (persisted)
    @MainActor @Published var selectedFilter: FilterType = .none {
        didSet { saveSettings() }
    }

    // LUT support
    @MainActor @Published var selectedLUT: String? = nil {
        didSet {
            if let lutName = selectedLUT {
                loadLUT(named: lutName)
            } else {
                currentLUTData = nil
                currentLUTDimension = 64
            }
        }
    }
    @MainActor private var currentLUTData: Data?
    @MainActor private var currentLUTDimension: Int = 64

    // UserDefaults keys
    private enum SettingsKey {
        static let brightness = "celluloid.brightness"
        static let contrast = "celluloid.contrast"
        static let saturation = "celluloid.saturation"
        static let exposure = "celluloid.exposure"
        static let temperature = "celluloid.temperature"
        static let sharpness = "celluloid.sharpness"
        static let filter = "celluloid.filter"
        static let selectedCameraID = "celluloid.selectedCameraID"
    }

    // Flag to prevent saving while loading
    private var isLoadingSettings = false

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
        case blackMist = "Black Mist"
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
            case .none, .blackMist: return nil  // blackMist is handled specially
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

    // Darwin notification names (must match extension)
    private static let streamStartedNotification = "com.celluloid.streamStarted" as CFString
    private static let streamStoppedNotification = "com.celluloid.streamStopped" as CFString

    override init() {
        super.init()
        Task { @MainActor in
            loadSettings()
            await checkPermission()
            loadAvailableCameras()
            setupDarwinNotifications()
            // Camera starts OFF - will turn on when external app starts streaming
        }
    }

    // MARK: - Settings Persistence

    @MainActor
    private func loadSettings() {
        isLoadingSettings = true
        defer { isLoadingSettings = false }

        let defaults = UserDefaults.standard

        if defaults.object(forKey: SettingsKey.brightness) != nil {
            brightness = defaults.double(forKey: SettingsKey.brightness)
        }
        if defaults.object(forKey: SettingsKey.contrast) != nil {
            contrast = defaults.double(forKey: SettingsKey.contrast)
        }
        if defaults.object(forKey: SettingsKey.saturation) != nil {
            saturation = defaults.double(forKey: SettingsKey.saturation)
        }
        if defaults.object(forKey: SettingsKey.exposure) != nil {
            exposure = defaults.double(forKey: SettingsKey.exposure)
        }
        if defaults.object(forKey: SettingsKey.temperature) != nil {
            temperature = defaults.double(forKey: SettingsKey.temperature)
        }
        if defaults.object(forKey: SettingsKey.sharpness) != nil {
            sharpness = defaults.double(forKey: SettingsKey.sharpness)
        }
        if let filterName = defaults.string(forKey: SettingsKey.filter),
           let filter = FilterType(rawValue: filterName) {
            selectedFilter = filter
        }
    }

    @MainActor
    private func saveSettings() {
        guard !isLoadingSettings else { return }

        let defaults = UserDefaults.standard
        defaults.set(brightness, forKey: SettingsKey.brightness)
        defaults.set(contrast, forKey: SettingsKey.contrast)
        defaults.set(saturation, forKey: SettingsKey.saturation)
        defaults.set(exposure, forKey: SettingsKey.exposure)
        defaults.set(temperature, forKey: SettingsKey.temperature)
        defaults.set(sharpness, forKey: SettingsKey.sharpness)
        defaults.set(selectedFilter.rawValue, forKey: SettingsKey.filter)
    }

    @MainActor
    private func setupDarwinNotifications() {
        let notifyCenter = CFNotificationCenterGetDarwinNotifyCenter()

        // Listen for stream started (external app like Photo Booth selected Celluloid Camera)
        CFNotificationCenterAddObserver(
            notifyCenter,
            Unmanaged.passUnretained(self).toOpaque(),
            { (center, observer, name, object, userInfo) in
                guard let observer = observer else { return }
                let manager = Unmanaged<CameraManager>.fromOpaque(observer).takeUnretainedValue()
                logger.info("Darwin notification: streamStarted received")
                // Use DispatchQueue.main for more reliable background execution
                DispatchQueue.main.async {
                    Task { @MainActor in
                        logger.info("Processing streamStarted - externalAppIsStreaming was: \(manager.externalAppIsStreaming), isRunning: \(manager.isRunning)")
                        manager.externalAppIsStreaming = true
                        manager.updateCameraState()
                        logger.info("After updateCameraState - isRunning: \(manager.isRunning)")
                    }
                }
            },
            Self.streamStartedNotification,
            nil,
            .deliverImmediately
        )

        // Listen for stream stopped (external app stopped using Celluloid Camera)
        CFNotificationCenterAddObserver(
            notifyCenter,
            Unmanaged.passUnretained(self).toOpaque(),
            { (center, observer, name, object, userInfo) in
                guard let observer = observer else { return }
                let manager = Unmanaged<CameraManager>.fromOpaque(observer).takeUnretainedValue()
                logger.info("Darwin notification: streamStopped received")
                DispatchQueue.main.async {
                    Task { @MainActor in
                        logger.info("Processing streamStopped - externalAppIsStreaming was: \(manager.externalAppIsStreaming)")
                        manager.externalAppIsStreaming = false
                        manager.updateCameraState()
                    }
                }
            },
            Self.streamStoppedNotification,
            nil,
            .deliverImmediately
        )

        logger.info("Darwin notification observers registered")
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

            // Reset sink stream connection state so we reconnect on next start
            self.sinkConnectionQueue.sync {
                self.isConnectedToSinkStream = false
                self.sinkQueue = nil
                self.sinkStreamID = 0
                self.sinkDeviceID = 0
                self.readyToEnqueue = false
                self.sinkConnectionRetries = 0
                self.framesDroppedSinceLastSend = 0
            }

            Task { @MainActor [weak self] in
                self?.isRunning = false
                logger.info("Camera session stopped, sink stream connection reset")
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

    // MARK: - LUT Support

    @MainActor
    func getAvailableLUTs() -> [String] {
        var luts: [String] = []

        // Check root LUT_pack for .cube and .png files
        if let rootPath = Bundle.main.resourcePath.map({ $0 + "/LUT_pack" }),
           let files = try? FileManager.default.contentsOfDirectory(atPath: rootPath) {
            luts.append(contentsOf: files.filter { $0.hasSuffix(".cube") }.map { $0.replacingOccurrences(of: ".cube", with: "") })
            luts.append(contentsOf: files.filter { $0.hasSuffix(".png") }.map { $0.replacingOccurrences(of: ".png", with: "") })
        }

        // Check Film Presets
        if let filmPath = Bundle.main.resourcePath.map({ $0 + "/LUT_pack/Film Presets" }),
           let files = try? FileManager.default.contentsOfDirectory(atPath: filmPath) {
            luts.append(contentsOf: files.filter { $0.hasSuffix(".png") }.map { $0.replacingOccurrences(of: ".png", with: "") })
        }

        // Check Webcam Presets
        if let webcamPath = Bundle.main.resourcePath.map({ $0 + "/LUT_pack/Webcam Presets" }),
           let files = try? FileManager.default.contentsOfDirectory(atPath: webcamPath) {
            luts.append(contentsOf: files.filter { $0.hasSuffix(".png") }.map { $0.replacingOccurrences(of: ".png", with: "") })
        }

        // Check Contrast Filters
        if let contrastPath = Bundle.main.resourcePath.map({ $0 + "/LUT_pack/Contrast Filters" }),
           let files = try? FileManager.default.contentsOfDirectory(atPath: contrastPath) {
            luts.append(contentsOf: files.filter { $0.hasSuffix(".png") }.map { $0.replacingOccurrences(of: ".png", with: "") })
        }

        return luts.sorted()
    }

    @MainActor
    private func loadLUT(named name: String) {
        // Try .cube file first (in root LUT_pack folder)
        if let cubeURL = Bundle.main.url(forResource: name, withExtension: "cube", subdirectory: "LUT_pack") {
            loadCubeLUT(from: cubeURL, name: name)
            return
        }

        // Try PNG HALD CLUT in various subfolders
        guard let lutURL = Bundle.main.url(forResource: name, withExtension: "png", subdirectory: "LUT_pack/Film Presets")
                ?? Bundle.main.url(forResource: name, withExtension: "png", subdirectory: "LUT_pack/Webcam Presets")
                ?? Bundle.main.url(forResource: name, withExtension: "png", subdirectory: "LUT_pack/Contrast Filters")
                ?? Bundle.main.url(forResource: name, withExtension: "png", subdirectory: "LUT_pack") else {
            logger.error("LUT not found: \(name)")
            currentLUTData = nil
            return
        }

        loadPNGHaldLUT(from: lutURL, name: name)
    }

    @MainActor
    private func loadCubeLUT(from url: URL, name: String) {
        guard let content = try? String(contentsOf: url, encoding: .utf8) else {
            logger.error("Failed to read .cube file: \(name)")
            currentLUTData = nil
            return
        }

        let lines = content.components(separatedBy: .newlines)
        var dimension = 0
        var cubeValues: [Float] = []

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            // Skip empty lines and comments
            if trimmed.isEmpty || trimmed.hasPrefix("#") || trimmed.hasPrefix("TITLE") ||
               trimmed.hasPrefix("DOMAIN_MIN") || trimmed.hasPrefix("DOMAIN_MAX") {
                continue
            }

            // Parse LUT size
            if trimmed.hasPrefix("LUT_3D_SIZE") {
                let parts = trimmed.split(separator: " ")
                if parts.count >= 2, let size = Int(parts[1]) {
                    dimension = size
                }
                continue
            }

            // Parse RGB values
            let components = trimmed.split(separator: " ").compactMap { Float($0) }
            if components.count >= 3 {
                cubeValues.append(components[0])
                cubeValues.append(components[1])
                cubeValues.append(components[2])
                cubeValues.append(1.0)  // Alpha
            }
        }

        guard dimension > 0 else {
            logger.error("Invalid .cube file - no LUT_3D_SIZE: \(name)")
            currentLUTData = nil
            return
        }

        let expectedCount = dimension * dimension * dimension * 4
        guard cubeValues.count == expectedCount else {
            logger.error("Invalid .cube file - expected \(expectedCount) values, got \(cubeValues.count): \(name)")
            currentLUTData = nil
            return
        }

        currentLUTDimension = dimension
        currentLUTData = Data(bytes: cubeValues, count: cubeValues.count * MemoryLayout<Float>.size)
        logger.info("Loaded .cube LUT: \(name) (\(dimension)x\(dimension)x\(dimension))")
    }

    @MainActor
    private func loadPNGHaldLUT(from url: URL, name: String) {
        guard let lutImage = NSImage(contentsOf: url),
              let cgImage = lutImage.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            logger.error("Failed to load LUT image: \(name)")
            currentLUTData = nil
            return
        }

        // Convert HALD CLUT to color cube data
        let width = cgImage.width
        let height = cgImage.height

        guard width == 512 && height == 512 else {
            logger.error("LUT must be 512x512, got \(width)x\(height)")
            currentLUTData = nil
            return
        }

        // Create bitmap context to extract pixel data
        let bytesPerPixel = 4
        let bytesPerRow = width * bytesPerPixel
        var pixelData = [UInt8](repeating: 0, count: width * height * bytesPerPixel)

        guard let context = CGContext(
            data: &pixelData,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            logger.error("Failed to create context for LUT")
            currentLUTData = nil
            return
        }

        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))

        // Convert HALD CLUT to color cube format
        // HALD level 8 = 64x64x64 cube stored in 512x512 image (8x8 blocks of 64x64)
        let dimension = 64
        var cubeData = [Float](repeating: 0, count: dimension * dimension * dimension * 4)

        for b in 0..<dimension {
            for g in 0..<dimension {
                for r in 0..<dimension {
                    // Calculate position in HALD image
                    let blockX = (b % 8) * 64 + r
                    let blockY = (b / 8) * 64 + g

                    let pixelIndex = (blockY * width + blockX) * bytesPerPixel
                    let cubeIndex = (b * dimension * dimension + g * dimension + r) * 4

                    // Normalize to 0-1 range
                    cubeData[cubeIndex + 0] = Float(pixelData[pixelIndex + 0]) / 255.0  // R
                    cubeData[cubeIndex + 1] = Float(pixelData[pixelIndex + 1]) / 255.0  // G
                    cubeData[cubeIndex + 2] = Float(pixelData[pixelIndex + 2]) / 255.0  // B
                    cubeData[cubeIndex + 3] = 1.0  // A
                }
            }
        }

        currentLUTDimension = dimension
        currentLUTData = Data(bytes: cubeData, count: cubeData.count * MemoryLayout<Float>.size)
        logger.info("Loaded HALD LUT: \(name)")
    }

    // MARK: - Preview Window Control

    @MainActor
    func previewWindowOpened() {
        previewWindowIsOpen = true
        updateCameraState()
    }

    @MainActor
    func previewWindowClosed() {
        previewWindowIsOpen = false
        updateCameraState()
    }

    @MainActor
    private func updateCameraState() {
        let shouldBeRunning = previewWindowIsOpen || externalAppIsStreaming
        logger.info("updateCameraState: shouldBeRunning=\(shouldBeRunning), previewWindowIsOpen=\(self.previewWindowIsOpen), externalAppIsStreaming=\(self.externalAppIsStreaming), isRunning=\(self.isRunning), permissionGranted=\(self.permissionGranted)")

        if shouldBeRunning && !isRunning && permissionGranted {
            logger.info("Starting camera session...")
            startSession()
        } else if !shouldBeRunning && isRunning {
            logger.info("Stopping camera session...")
            stopSession()
        }
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

        // Apply Black Mist filter (special handling)
        // Emulates a Tiffen Black Pro-Mist: soft highlight bloom, reduced micro-contrast, rich blacks
        if selectedFilter == .blackMist {
            let base = outputImage
            let blurRadius: Double = 12.0
            let strength: Double = 0.5

            // 1. Create a blurred copy
            if let blurFilter = CIFilter(name: "CIGaussianBlur") {
                blurFilter.setValue(base, forKey: kCIInputImageKey)
                blurFilter.setValue(blurRadius, forKey: kCIInputRadiusKey)
                if var blurred = blurFilter.outputImage {
                    blurred = blurred.cropped(to: base.extent)

                    // 2. Slightly lift the blurred layer (bloom the highlights)
                    if let exposureFilter = CIFilter(name: "CIExposureAdjust") {
                        exposureFilter.setValue(blurred, forKey: kCIInputImageKey)
                        exposureFilter.setValue(0.30, forKey: kCIInputEVKey)
                        if let brightBlur = exposureFilter.outputImage {

                            // 3. Blend with soft light for that dreamy halation
                            if let blendFilter = CIFilter(name: "CISoftLightBlendMode") {
                                blendFilter.setValue(brightBlur, forKey: kCIInputImageKey)
                                blendFilter.setValue(base, forKey: kCIInputBackgroundImageKey)
                                if let misty = blendFilter.outputImage {

                                    // 4. Mix base + mist using alpha mask for strength control
                                    let maskColor = CIColor(red: 1, green: 1, blue: 1, alpha: strength)
                                    if let maskGen = CIFilter(name: "CIConstantColorGenerator") {
                                        maskGen.setValue(maskColor, forKey: kCIInputColorKey)
                                        if let mask = maskGen.outputImage?.cropped(to: base.extent) {

                                            if let mixFilter = CIFilter(name: "CIBlendWithAlphaMask") {
                                                mixFilter.setValue(misty, forKey: kCIInputImageKey)
                                                mixFilter.setValue(base, forKey: kCIInputBackgroundImageKey)
                                                mixFilter.setValue(mask, forKey: kCIInputMaskImageKey)
                                                if let mixed = mixFilter.outputImage {

                                                    // 5. Final subtle contrast/brightness tweak
                                                    if let controls = CIFilter(name: "CIColorControls") {
                                                        controls.setValue(mixed, forKey: kCIInputImageKey)
                                                        controls.setValue(0.95, forKey: kCIInputContrastKey)
                                                        controls.setValue(0.02, forKey: kCIInputBrightnessKey)
                                                        controls.setValue(1.02, forKey: kCIInputSaturationKey)
                                                        if let final = controls.outputImage?.cropped(to: base.extent) {
                                                            outputImage = final
                                                        }
                                                    }
                                                }
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }
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

        // Apply LUT if selected
        if let lutData = currentLUTData,
           let lutFilter = CIFilter(name: "CIColorCubeWithColorSpace") {
            lutFilter.setValue(outputImage, forKey: kCIInputImageKey)
            lutFilter.setValue(currentLUTDimension, forKey: "inputCubeDimension")
            lutFilter.setValue(lutData, forKey: "inputCubeData")
            lutFilter.setValue(CGColorSpaceCreateDeviceRGB(), forKey: "inputColorSpace")
            if let result = lutFilter.outputImage {
                outputImage = result
            }
        }

        return outputImage
    }

    // MARK: - CoreMediaIO Sink Stream Connection

    private var sinkConnectionRetries = 0
    private let maxSinkRetries = 5

    private func connectToSinkStream() {
        sinkConnectionQueue.async { [weak self] in
            self?.performSinkStreamConnection()
        }
    }

    private func retrySinkConnection() {
        sinkConnectionRetries += 1
        if sinkConnectionRetries <= maxSinkRetries {
            print("Retrying sink connection (attempt \(sinkConnectionRetries)/\(maxSinkRetries))...")
            sinkConnectionQueue.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                self?.performSinkStreamConnection()
            }
        } else {
            print("Failed to connect to sink stream after \(maxSinkRetries) attempts")
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

        print("Celluloid Camera device not found - will retry")
        retrySinkConnection()
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

        logger.info("Attempting to connect to sink stream ID: \(streamID)")

        let refCon = Unmanaged.passUnretained(self).toOpaque()
        var queue: Unmanaged<CMSimpleQueue>?

        let status = CMIOStreamCopyBufferQueue(
            streamID,
            { (streamID: CMIOStreamID, token: UnsafeMutableRawPointer?, refcon: UnsafeMutableRawPointer?) in
                guard let refcon = refcon else { return }
                let manager = Unmanaged<CameraManager>.fromOpaque(refcon).takeUnretainedValue()
                manager.readyToEnqueue = true
                print("Sink stream callback - ready to enqueue next frame")
            },
            refCon,
            &queue
        )

        logger.info("CMIOStreamCopyBufferQueue status: \(status)")

        if status == noErr, let simpleQueue = queue?.takeRetainedValue() {
            self.sinkQueue = simpleQueue
            logger.info("Got buffer queue, starting sink stream...")

            let startStatus = CMIODeviceStartStream(sinkDeviceID, streamID)

            logger.info("CMIODeviceStartStream status: \(startStatus)")

            if startStatus == noErr {
                self.isConnectedToSinkStream = true
                self.readyToEnqueue = true
                self.sinkConnectionRetries = 0  // Reset retry counter on success
                logger.info("Successfully connected to sink stream and ready to send frames")
            } else {
                logger.error("Failed to start sink stream: \(startStatus)")
            }
        } else {
            logger.error("Failed to get buffer queue: \(status)")
        }
    }

    private var framesSentCount = 0
    private var lastLoggedFrameCount = 0
    private var framesDroppedSinceLastSend = 0

    private func sendFrameToSinkStream(_ sampleBuffer: CMSampleBuffer) {
        guard isConnectedToSinkStream, let queue = sinkQueue else {
            if !isConnectedToSinkStream {
                logger.info("Not connected to sink stream, attempting connection...")
                connectToSinkStream()
            }
            return
        }

        guard readyToEnqueue else {
            framesDroppedSinceLastSend += 1
            // If we've dropped too many frames, force reconnection
            if framesDroppedSinceLastSend > 60 {  // 2 seconds at 30fps
                logger.warning("Dropped \(self.framesDroppedSinceLastSend) frames, forcing reconnection")
                isConnectedToSinkStream = false
                sinkQueue = nil
                readyToEnqueue = false
                framesDroppedSinceLastSend = 0
                connectToSinkStream()
            }
            return
        }

        framesDroppedSinceLastSend = 0
        readyToEnqueue = false

        let enqueueStatus = CMSimpleQueueEnqueue(queue, element: Unmanaged.passRetained(sampleBuffer).toOpaque())
        if enqueueStatus != noErr {
            logger.error("Failed to enqueue buffer: \(enqueueStatus)")
            readyToEnqueue = true
        } else {
            framesSentCount += 1
            if framesSentCount % 30 == 0 {
                logger.info("Sent \(self.framesSentCount) frames to sink stream")
                lastLoggedFrameCount = framesSentCount
            }
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
