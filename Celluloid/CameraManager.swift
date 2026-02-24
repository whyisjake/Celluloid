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
import Metal

private let logger = Logger(subsystem: "com.jakespurlock.Celluloid", category: "CameraManager")

// Shared constants for frame format
struct CelluloidShared {
    static let width = 1280
    static let height = 720
}

// MARK: - HALD CLUT Constants
struct HALDConstants {
    static let imageSize = 512       // 512x512 HALD image
    static let cubeDimension = 64    // 64x64x64 color cube
    static let gridSize = 8          // 8x8 grid of 64x64 blocks
}

// MARK: - LUT Info
struct LUTInfo: Hashable, Identifiable {
    let name: String
    let subdirectory: String?  // Subdirectory path relative to bundle resources (e.g., "LUT_pack" or "LUT_pack/Film Presets")
    let fileExtension: String  // "cube" or "png"
    
    // Use composite ID to ensure uniqueness (subdirectory is always set in our usage)
    var id: String { "\(subdirectory ?? "")/\(name).\(fileExtension)" }
}

// MARK: - Cube LUT Parser (Testable)
struct CubeLUTParser {
    enum ParseError: Error, Equatable {
        case emptyFile
        case missingLUTSize
        case invalidLUTSize
        case incorrectValueCount(expected: Int, actual: Int)
        case invalidRGBValues
    }

    struct ParseResult {
        let dimension: Int
        let data: Data
    }

    /// Parse a .cube file content and return the LUT data
    static func parse(_ content: String) -> Result<ParseResult, ParseError> {
        let lines = content.components(separatedBy: .newlines)
        var dimension = 0
        var cubeValues: [Float] = []
        var hasContent = false

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            // Skip empty lines and comments/metadata
            if trimmed.isEmpty || trimmed.hasPrefix("#") || trimmed.hasPrefix("TITLE") ||
               trimmed.hasPrefix("DOMAIN_MIN") || trimmed.hasPrefix("DOMAIN_MAX") {
                continue
            }

            hasContent = true

            // Parse LUT size
            if trimmed.hasPrefix("LUT_3D_SIZE") {
                let parts = trimmed.split(separator: " ")
                if parts.count >= 2, let size = Int(parts[1]), size > 0 {
                    dimension = size
                } else {
                    return .failure(.invalidLUTSize)
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

        if !hasContent {
            return .failure(.emptyFile)
        }

        guard dimension > 0 else {
            return .failure(.missingLUTSize)
        }

        let expectedCount = dimension * dimension * dimension * 4
        guard cubeValues.count == expectedCount else {
            return .failure(.incorrectValueCount(expected: expectedCount, actual: cubeValues.count))
        }

        let data = Data(bytes: cubeValues, count: cubeValues.count * MemoryLayout<Float>.size)
        return .success(ParseResult(dimension: dimension, data: data))
    }
}

// MARK: - HALD CLUT Parser (Testable)
struct HALDCLUTParser {
    enum ParseError: Error, Equatable {
        case invalidImageSize(width: Int, height: Int)
        case failedToCreateContext
        case failedToLoadImage
    }

    struct ParseResult {
        let dimension: Int
        let data: Data
    }

    /// Validate HALD image dimensions
    static func validateDimensions(width: Int, height: Int) -> Bool {
        return width == HALDConstants.imageSize && height == HALDConstants.imageSize
    }

    /// Convert pixel data from a 512x512 HALD image to color cube data
    static func convertPixelData(_ pixelData: [UInt8], width: Int, height: Int) -> Result<ParseResult, ParseError> {
        guard validateDimensions(width: width, height: height) else {
            return .failure(.invalidImageSize(width: width, height: height))
        }

        let dimension = HALDConstants.cubeDimension
        let gridSize = HALDConstants.gridSize
        let bytesPerPixel = 4
        var cubeData = [Float](repeating: 0, count: dimension * dimension * dimension * 4)

        for b in 0..<dimension {
            for g in 0..<dimension {
                for r in 0..<dimension {
                    // Calculate position in HALD image
                    let blockX = (b % gridSize) * dimension + r
                    let blockY = (b / gridSize) * dimension + g

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

        let data = Data(bytes: cubeData, count: cubeData.count * MemoryLayout<Float>.size)
        return .success(ParseResult(dimension: dimension, data: data))
    }
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

    // Adjustment controls (persisted with debouncing for slider drags)
    @MainActor @Published var brightness: Double = 0.0 {  // -1.0 to 1.0
        didSet { saveSettingsDebounced() }
    }
    @MainActor @Published var contrast: Double = 1.0 {    // 0.25 to 4.0
        didSet { saveSettingsDebounced() }
    }
    @MainActor @Published var saturation: Double = 1.0 {  // 0.0 to 2.0
        didSet { saveSettingsDebounced() }
    }
    @MainActor @Published var exposure: Double = 0.0 {    // -2.0 to 2.0
        didSet { saveSettingsDebounced() }
    }
    @MainActor @Published var temperature: Double = 6500 { // 2000 to 10000 (Kelvin)
        didSet { saveSettingsDebounced() }
    }
    @MainActor @Published var sharpness: Double = 0.0 {    // 0.0 to 2.0
        didSet { saveSettingsDebounced() }
    }

    // Zoom and crop controls (persisted with debouncing)
    @MainActor @Published var zoomLevel: Double = 1.0 {    // 1.0 to 4.0
        didSet {
            // Clamp crop position to valid range (-1 to 1)
            cropOffsetX = max(-1.0, min(1.0, cropOffsetX))
            cropOffsetY = max(-1.0, min(1.0, cropOffsetY))
            saveSettingsDebounced()
        }
    }
    @MainActor @Published var cropOffsetX: Double = 0.0 {  // -1.0 to 1.0 (normalized)
        didSet { saveSettingsDebounced() }
    }
    @MainActor @Published var cropOffsetY: Double = 0.0 {  // -1.0 to 1.0 (normalized)
        didSet { saveSettingsDebounced() }
    }

    // Filter (persisted)
    @MainActor @Published var selectedFilter: FilterType = .none {
        didSet { saveSettings() }
    }

    // LUT support
    @MainActor @Published var availableLUTs: [LUTInfo] = []
    @MainActor @Published var selectedLUT: String? = nil {
        didSet {
            if let lutName = selectedLUT {
                loadLUT(named: lutName)
            } else {
                currentLUTData = nil
                currentLUTDimension = 64
            }
            saveSettings()
        }
    }
    @MainActor private var currentLUTData: Data?
    
    // Helper to find LUT info by name
    @MainActor
    private func lutInfo(for name: String) -> LUTInfo? {
        availableLUTs.first { $0.name == name }
    }
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
        static let selectedLUT = "celluloid.selectedLUT"
        static let zoomLevel = "celluloid.zoomLevel"
        static let cropOffsetX = "celluloid.cropOffsetX"
        static let cropOffsetY = "celluloid.cropOffsetY"
    }

    // Flag to prevent saving while loading
    private var isLoadingSettings = false

    // Debounce timer for saving settings during drag operations
    private var saveSettingsWorkItem: DispatchWorkItem?

    private let captureSession = AVCaptureSession()
    private let videoOutput = AVCaptureVideoDataOutput()
    private let sessionQueue = DispatchQueue(label: "com.celluloid.sessionQueue")

    // Metal-backed CIContext for GPU-accelerated rendering
    private let metalDevice: MTLDevice?
    private let context: CIContext

    // CVPixelBufferPool for efficient buffer reuse
    private var pixelBufferPool: CVPixelBufferPool?

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
        case gateWeave = "Gate Weave"
        case halation = "Halation"
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
            case .none, .blackMist, .gateWeave, .halation: return nil  // These are handled specially
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
        // Initialize Metal device and CIContext before super.init()
        if let device = MTLCreateSystemDefaultDevice() {
            self.metalDevice = device
            self.context = CIContext(mtlDevice: device, options: [
                .cacheIntermediates: false,  // Reduce memory usage
                .priorityRequestLow: false   // Use high priority for real-time
            ])
            logger.info("Initialized Metal-backed CIContext with device: \(device.name)")
        } else {
            self.metalDevice = nil
            self.context = CIContext()
            logger.warning("Metal not available, falling back to CPU-based CIContext")
        }

        super.init()

        // Create pixel buffer pool for efficient buffer reuse
        createPixelBufferPool()

        Task { @MainActor in
            loadAvailableLUTs()
            loadSettings()
            await checkPermission()
            loadAvailableCameras()
            setupDarwinNotifications()
            // Camera starts OFF - will turn on when external app starts streaming
        }
    }

    private func createPixelBufferPool() {
        let poolAttributes: [CFString: Any] = [
            kCVPixelBufferPoolMinimumBufferCountKey: 3  // Keep 3 buffers in pool
        ]

        let pixelBufferAttributes: [CFString: Any] = [
            kCVPixelBufferWidthKey: CelluloidShared.width,
            kCVPixelBufferHeightKey: CelluloidShared.height,
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,  // IOSurface-backed for zero-copy
            kCVPixelBufferMetalCompatibilityKey: true  // Metal compatible
        ]

        let status = CVPixelBufferPoolCreate(
            kCFAllocatorDefault,
            poolAttributes as CFDictionary,
            pixelBufferAttributes as CFDictionary,
            &pixelBufferPool
        )

        if status == kCVReturnSuccess {
            logger.info("Created CVPixelBufferPool with IOSurface-backed, Metal-compatible buffers")
        } else {
            logger.error("Failed to create CVPixelBufferPool: \(status)")
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
        if defaults.object(forKey: SettingsKey.zoomLevel) != nil {
            zoomLevel = defaults.double(forKey: SettingsKey.zoomLevel)
        }
        if defaults.object(forKey: SettingsKey.cropOffsetX) != nil {
            cropOffsetX = defaults.double(forKey: SettingsKey.cropOffsetX)
        }
        if defaults.object(forKey: SettingsKey.cropOffsetY) != nil {
            cropOffsetY = defaults.double(forKey: SettingsKey.cropOffsetY)
        }
        if let filterName = defaults.string(forKey: SettingsKey.filter),
           let filter = FilterType(rawValue: filterName) {
            selectedFilter = filter
        }
        if let lutName = defaults.string(forKey: SettingsKey.selectedLUT) {
            selectedLUT = lutName
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
        defaults.set(zoomLevel, forKey: SettingsKey.zoomLevel)
        defaults.set(cropOffsetX, forKey: SettingsKey.cropOffsetX)
        defaults.set(cropOffsetY, forKey: SettingsKey.cropOffsetY)
        defaults.set(selectedFilter.rawValue, forKey: SettingsKey.filter)
        defaults.set(selectedLUT, forKey: SettingsKey.selectedLUT)
    }

    /// Debounced version of saveSettings for high-frequency updates (like drag gestures)
    @MainActor
    private func saveSettingsDebounced() {
        guard !isLoadingSettings else { return }

        // Cancel any pending save
        saveSettingsWorkItem?.cancel()

        // Schedule a new save after 200ms of inactivity
        let workItem = DispatchWorkItem { [weak self] in
            Task { @MainActor in
                self?.saveSettings()
            }
        }
        saveSettingsWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: workItem)
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
                // Darwin notification: streamStarted received
                // Use DispatchQueue.main for more reliable background execution
                DispatchQueue.main.async {
                    Task { @MainActor in
                        let wasStreaming = manager.externalAppIsStreaming
                        let wasRunning = manager.isRunning
                        manager.externalAppIsStreaming = true
                        manager.updateCameraState()
                        logger.info("streamStarted: externalAppIsStreaming changed from \(wasStreaming) to \(manager.externalAppIsStreaming), isRunning changed from \(wasRunning) to \(manager.isRunning)")
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
        zoomLevel = 1.0
        cropOffsetX = 0.0
        cropOffsetY = 0.0
        selectedFilter = .none
    }

    // MARK: - LUT Support

    /// Helper to collect LUT files from a directory
    private func collectLUTs(from subdirectory: String, extensions: [String]) -> [LUTInfo] {
        guard let resourcePath = Bundle.main.resourcePath else {
            return []
        }
        
        let directoryURL = URL(fileURLWithPath: resourcePath).appendingPathComponent(subdirectory)
        guard let files = try? FileManager.default.contentsOfDirectory(atPath: directoryURL.path) else {
            return []
        }
        
        return extensions.flatMap { ext in
            files.filter { $0.hasSuffix("." + ext) }.map { filename in
                let name = String(filename.dropLast(ext.count + 1))  // Remove .ext safely
                return LUTInfo(name: name,
                              subdirectory: subdirectory,
                              fileExtension: ext)
            }
        }
    }

    @MainActor
    private func loadAvailableLUTs() {
        var luts: [LUTInfo] = []

        // Check root LUT_pack for .cube and .png files
        luts.append(contentsOf: collectLUTs(from: "LUT_pack", extensions: ["cube", "png"]))
        
        // Check Film Presets
        luts.append(contentsOf: collectLUTs(from: "LUT_pack/Film Presets", extensions: ["png"]))
        
        // Check Webcam Presets
        luts.append(contentsOf: collectLUTs(from: "LUT_pack/Webcam Presets", extensions: ["png"]))
        
        // Check Contrast Filters
        luts.append(contentsOf: collectLUTs(from: "LUT_pack/Contrast Filters", extensions: ["png"]))

        availableLUTs = luts.sorted { $0.name < $1.name }
    }

    @MainActor
    private func loadLUT(named name: String) {
        // Find the LUT info with stored path
        guard let info = lutInfo(for: name) else {
            logger.error("LUT not found in availableLUTs: \(name)")
            currentLUTData = nil
            return
        }
        
        // Use stored subdirectory to avoid redundant lookups
        guard let lutURL = Bundle.main.url(forResource: info.name, 
                                           withExtension: info.fileExtension, 
                                           subdirectory: info.subdirectory) else {
            logger.error("LUT file not found: \(name) in \(info.subdirectory ?? "root")")
            currentLUTData = nil
            return
        }
        
        if info.fileExtension == "cube" {
            loadCubeLUT(from: lutURL, name: name)
        } else {
            loadPNGHaldLUT(from: lutURL, name: name)
        }
    }

    @MainActor
    private func loadCubeLUT(from url: URL, name: String) {
        // Move file reading and parsing to a background queue to avoid UI freezes
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let content = try? String(contentsOf: url, encoding: .utf8) else {
                logger.error("Failed to read .cube file: \(name)")
                DispatchQueue.main.async {
                    self?.currentLUTData = nil
                }
                return
            }

            switch CubeLUTParser.parse(content) {
            case .success(let result):
                logger.info("Loaded .cube LUT: \(name) (\(result.dimension)x\(result.dimension)x\(result.dimension))")
                DispatchQueue.main.async {
                    self?.currentLUTDimension = result.dimension
                    self?.currentLUTData = result.data
                }
            case .failure(let error):
                logger.error("Invalid .cube file '\(name)': \(String(describing: error))")
                DispatchQueue.main.async {
                    self?.currentLUTData = nil
                }
            }
        }
    }

    @MainActor
    private func loadPNGHaldLUT(from url: URL, name: String) {
        guard let lutImage = NSImage(contentsOf: url),
              let cgImage = lutImage.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            logger.error("Failed to load LUT image: \(name)")
            currentLUTData = nil
            return
        }

        let width = cgImage.width
        let height = cgImage.height

        guard HALDCLUTParser.validateDimensions(width: width, height: height) else {
            logger.error("LUT must be \(HALDConstants.imageSize)x\(HALDConstants.imageSize), got \(width)x\(height)")
            currentLUTData = nil
            return
        }

        // Move the heavy conversion to a background queue
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
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
                DispatchQueue.main.async {
                    logger.error("Failed to create context for LUT")
                    self?.currentLUTData = nil
                }
                return
            }

            context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))

            // Use the testable parser for conversion
            switch HALDCLUTParser.convertPixelData(pixelData, width: width, height: height) {
            case .success(let result):
                DispatchQueue.main.async {
                    self?.currentLUTDimension = result.dimension
                    self?.currentLUTData = result.data
                    logger.info("Loaded HALD LUT: \(name)")
                }
            case .failure(let error):
                DispatchQueue.main.async {
                    logger.error("Failed to convert HALD LUT '\(name)': \(String(describing: error))")
                    self?.currentLUTData = nil
                }
            }
        }
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
        // Keep running if: preview is open OR external app is streaming
        // Note: isConnectedToSinkStream is just a communication channel state, not a reason to keep camera on
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

    /// Apply zoom and crop to an already-filtered image
    @MainActor
    private func applyZoomAndCrop(to image: CIImage) -> CIImage {
        guard zoomLevel > 1.0 else { return image }

        var outputImage = image
        let imageWidth = outputImage.extent.width
        let imageHeight = outputImage.extent.height

        // The visible area is 1/zoomLevel of the original
        let croppedWidth = imageWidth / zoomLevel
        let croppedHeight = imageHeight / zoomLevel

        // Calculate center position with offsets
        // Offsets are normalized (-1 to 1), convert to pixel space
        let maxOffsetX = (imageWidth - croppedWidth) / 2
        let maxOffsetY = (imageHeight - croppedHeight) / 2
        let centerX = imageWidth / 2 + cropOffsetX * maxOffsetX
        // Negate cropOffsetY because CIImage has Y=0 at bottom, but UI has Y=0 at top
        let centerY = imageHeight / 2 - cropOffsetY * maxOffsetY

        // Calculate crop rectangle
        let cropX = centerX - croppedWidth / 2
        let cropY = centerY - croppedHeight / 2
        let cropRect = CGRect(x: cropX, y: cropY, width: croppedWidth, height: croppedHeight)

        // Crop to the desired area
        outputImage = outputImage.cropped(to: cropRect)

        // After cropping, the image extent is still at (cropX, cropY)
        // We need to translate it to origin (0,0) before scaling
        outputImage = outputImage.transformed(by: CGAffineTransform(translationX: -cropX, y: -cropY))

        // Scale back to original size (this creates the zoom effect)
        let scaleX = imageWidth / croppedWidth
        let scaleY = imageHeight / croppedHeight
        outputImage = outputImage.transformed(by: CGAffineTransform(scaleX: scaleX, y: scaleY))

        return outputImage
    }

    /// Apply color filters only (no zoom) - call once per frame
    @MainActor
    private func applyColorFilters(to image: CIImage) -> CIImage {
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

        // Apply Black Mist filter using custom filter class
        if selectedFilter == .blackMist {
            let blackMist = BlackMistFilter()
            blackMist.inputImage = outputImage
            if let result = blackMist.outputImage {
                outputImage = result
            }
        }

        // Apply Gate Weave filter (film projector instability)
        if selectedFilter == .gateWeave {
            let gateWeave = GateWeaveFilter()
            gateWeave.inputImage = outputImage
            if let result = gateWeave.outputImage {
                outputImage = result
            }
        }

        // Apply Halation filter (red/orange glow around highlights)
        if selectedFilter == .halation {
            let halation = HalationFilter()
            halation.inputImage = outputImage
            if let result = halation.outputImage {
                outputImage = result
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

        var dataSize = UInt32(MemoryLayout<CFString?>.size)
        var name: Unmanaged<CFString>?

        let status = withUnsafeMutablePointer(to: &name) { namePtr in
            CMIOObjectGetPropertyData(
                deviceID,
                &nameAddress,
                0,
                nil,
                dataSize,
                &dataSize,
                namePtr
            )
        }

        guard status == noErr, let unmanagedName = name else {
            return nil
        }

        return unmanagedName.takeUnretainedValue() as String
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

        var dataSize = UInt32(MemoryLayout<CFString?>.size)
        var name: Unmanaged<CFString>?

        let status = withUnsafeMutablePointer(to: &name) { namePtr in
            CMIOObjectGetPropertyData(streamID, &nameAddress, 0, nil, dataSize, &dataSize, namePtr)
        }

        guard status == noErr, let unmanagedName = name else {
            return nil
        }

        return unmanagedName.takeUnretainedValue() as String
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
    
    /// Maximum number of consecutive dropped frames before forcing a reconnection.
    /// Set to 60 frames, which represents approximately 2 seconds at 30fps.
    private let maxDroppedFramesBeforeReconnect = 60

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
            if framesDroppedSinceLastSend > maxDroppedFramesBeforeReconnect {
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

}

extension CameraManager: AVCaptureVideoDataOutputSampleBufferDelegate {
    nonisolated func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let inputPixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }

        let ciImage = CIImage(cvPixelBuffer: inputPixelBuffer)

        Task { @MainActor [weak self] in
            guard let self = self else { return }

            // Apply color filters ONCE (shared between preview and output)
            let filteredImage = self.applyColorFilters(to: ciImage)

            // Preview uses filtered image without zoom (shows full frame with crop overlay)
            let previewImage = filteredImage

            // Output applies zoom/crop on top of the filtered image
            let outputImage = self.applyZoomAndCrop(to: filteredImage)

            let outputWidth = CGFloat(CelluloidShared.width)
            let outputHeight = CGFloat(CelluloidShared.height)

            // Render preview image to CGImage for SwiftUI
            let previewScaleX = outputWidth / previewImage.extent.width
            let previewScaleY = outputHeight / previewImage.extent.height
            let scaledPreview = previewImage.transformed(by: CGAffineTransform(scaleX: previewScaleX, y: previewScaleY))

            if let previewBuffer = self.getPooledPixelBuffer() {
                self.context.render(
                    scaledPreview,
                    to: previewBuffer,
                    bounds: CGRect(x: 0, y: 0, width: outputWidth, height: outputHeight),
                    colorSpace: CGColorSpaceCreateDeviceRGB()
                )
                if let cgImage = self.createCGImage(from: previewBuffer) {
                    self.currentFrame = cgImage
                }
            }

            // Render output image (with zoom) for virtual camera
            if let outputBuffer = self.getPooledPixelBuffer() {
                let outputScaleX = outputWidth / outputImage.extent.width
                let outputScaleY = outputHeight / outputImage.extent.height
                let scaledOutput = outputImage.transformed(by: CGAffineTransform(scaleX: outputScaleX, y: outputScaleY))

                self.context.render(
                    scaledOutput,
                    to: outputBuffer,
                    bounds: CGRect(x: 0, y: 0, width: outputWidth, height: outputHeight),
                    colorSpace: CGColorSpaceCreateDeviceRGB()
                )

                // Send to sink stream
                nonisolated(unsafe) let sendBuffer = outputBuffer
                self.sinkConnectionQueue.async { [weak self] in
                    guard let self = self else { return }
                    if let sampleBuffer = self.createSampleBuffer(from: sendBuffer) {
                        self.sendFrameToSinkStream(sampleBuffer)
                    }
                }
            }
        }
    }

    /// Get a pixel buffer from the pool for rendering
    private func getPooledPixelBuffer() -> CVPixelBuffer? {
        guard let pool = pixelBufferPool else {
            logger.warning("Pixel buffer pool not available")
            return nil
        }

        var pixelBuffer: CVPixelBuffer?
        let status = CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &pixelBuffer)

        if status != kCVReturnSuccess {
            logger.warning("Failed to get pixel buffer from pool: \(status)")
            return nil
        }

        return pixelBuffer
    }

    /// Create CGImage from CVPixelBuffer efficiently
    private func createCGImage(from pixelBuffer: CVPixelBuffer) -> CGImage? {
        let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
        return context.createCGImage(ciImage, from: ciImage.extent)
    }

    /// Create sample buffer from CVPixelBuffer directly (no CGImage intermediate)
    private func createSampleBuffer(from pixelBuffer: CVPixelBuffer) -> CMSampleBuffer? {
        var formatDescription: CMFormatDescription?
        CMVideoFormatDescriptionCreateForImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: pixelBuffer,
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
            imageBuffer: pixelBuffer,
            formatDescription: format,
            sampleTiming: &timingInfo,
            sampleBufferOut: &sampleBuffer
        )

        return sampleBuffer
    }
}
