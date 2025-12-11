//
//  CelluloidStreamSource.swift
//  CelluloidCameraExtension
//
//  Created by Jake Spurlock on 12/11/25.
//

import Foundation
import CoreMediaIO
import CoreVideo
import IOSurface
import Security
import os.log

// Shared constants - must match main app
struct CelluloidShared {
    static let width = 1280
    static let height = 720
    static let bytesPerRow = width * 4
    static let frameSize = bytesPerRow * height
    // App Group for shared UserDefaults - must match entitlements
    static let appGroupID = "36ERVRQ23S.com.jakespurlock.Celluloid"
    static let surfaceIDKey = "IOSurfaceID"
}

class CelluloidStreamSource: NSObject, CMIOExtensionStreamSource {

    private(set) var stream: CMIOExtensionStream!

    let device: CMIOExtensionDevice
    private let _streamFormat: CMIOExtensionStreamFormat

    private var _isStreaming = false
    private var frameTimer: DispatchSourceTimer?
    private let timerQueue = DispatchQueue(label: "com.celluloid.frameTimer", qos: .userInteractive)

    private var sequenceNumber: UInt64 = 0
    private var lastFrameTime = CMTime.zero

    // IOSurface for receiving frames from main app
    private var sharedSurface: IOSurface?
    private var lastKnownSurfaceID: IOSurfaceID = 0

    static let width = 1280
    static let height = 720
    static let frameRate = 30.0

    static var supportedFormats: [CMIOExtensionStreamFormat] {
        let formatDescription = try! CMFormatDescription(
            videoCodecType: .init(rawValue: kCVPixelFormatType_32BGRA),
            width: width,
            height: height
        )

        return [
            CMIOExtensionStreamFormat(
                formatDescription: formatDescription,
                maxFrameDuration: CMTime(value: 1, timescale: CMTimeScale(frameRate)),
                minFrameDuration: CMTime(value: 1, timescale: CMTimeScale(frameRate)),
                validFrameDurations: nil
            )
        ]
    }

    init(localizedName: String, streamID: UUID, streamFormat: CMIOExtensionStreamFormat, device: CMIOExtensionDevice) {
        self.device = device
        self._streamFormat = streamFormat
        super.init()

        stream = CMIOExtensionStream(
            localizedName: localizedName,
            streamID: streamID,
            direction: .source,
            clockType: .hostTime,
            source: self
        )
    }

    var formats: [CMIOExtensionStreamFormat] {
        return Self.supportedFormats
    }

    var activeFormatIndex: Int = 0

    var availableProperties: Set<CMIOExtensionProperty> {
        return [
            .streamActiveFormatIndex,
            .streamFrameDuration
        ]
    }

    func streamProperties(forProperties properties: Set<CMIOExtensionProperty>) throws -> CMIOExtensionStreamProperties {
        let streamProperties = CMIOExtensionStreamProperties(dictionary: [:])

        if properties.contains(.streamActiveFormatIndex) {
            streamProperties.activeFormatIndex = 0
        }

        if properties.contains(.streamFrameDuration) {
            streamProperties.frameDuration = CMTime(value: 1, timescale: CMTimeScale(Self.frameRate))
        }

        return streamProperties
    }

    func setStreamProperties(_ streamProperties: CMIOExtensionStreamProperties) throws {
        if let formatIndex = streamProperties.activeFormatIndex {
            activeFormatIndex = formatIndex
        }
    }

    func authorizedToStartStream(for client: CMIOExtensionClient) -> Bool {
        return true
    }

    func startStream() throws {
        guard !_isStreaming else { return }
        _isStreaming = true
        sequenceNumber = 0
        lastFrameTime = CMClockGetTime(CMClockGetHostTimeClock())

        logger.info("Starting stream")

        // Try to connect to IOSurface
        connectToIOSurface()

        frameTimer = DispatchSource.makeTimerSource(queue: timerQueue)
        frameTimer?.schedule(deadline: .now(), repeating: 1.0 / Self.frameRate)
        frameTimer?.setEventHandler { [weak self] in
            self?.generateFrame()
        }
        frameTimer?.resume()
    }

    func stopStream() throws {
        guard _isStreaming else { return }
        _isStreaming = false

        logger.info("Stopping stream")

        frameTimer?.cancel()
        frameTimer = nil
    }

    func startStreaming() {
        try? startStream()
    }

    func stopStreaming() {
        try? stopStream()
    }

    private func connectToIOSurface() {
        var surfaceID: IOSurfaceID = 0

        // Try reading from own preferences using UserDefaults.standard
        // (which reads from the extension's own bundle ID preferences)
        let standardSurfaceID = UserDefaults.standard.integer(forKey: CelluloidShared.surfaceIDKey)
        if standardSurfaceID != 0 {
            surfaceID = IOSurfaceID(standardSurfaceID)
            logger.info("Read IOSurface ID \(surfaceID) from standard UserDefaults")
        } else {
            logger.info("Standard UserDefaults returned 0")
        }

        // Fallback to App Group UserDefaults
        if surfaceID == 0 {
            if let sharedDefaults = UserDefaults(suiteName: CelluloidShared.appGroupID) {
                surfaceID = IOSurfaceID(sharedDefaults.integer(forKey: CelluloidShared.surfaceIDKey))
                if surfaceID != 0 {
                    logger.info("Read IOSurface ID \(surfaceID) from App Group UserDefaults")
                } else {
                    logger.info("App Group UserDefaults returned 0")
                }
            }
        }

        guard surfaceID != 0 else {
            logger.info("No IOSurface ID available yet")
            return
        }

        // Skip if we're already connected to this surface
        if surfaceID == lastKnownSurfaceID && sharedSurface != nil {
            return
        }

        logger.info("Attempting IOSurfaceLookup for ID: \(surfaceID)")

        // Look up the IOSurface by ID
        if let surface = IOSurfaceLookup(surfaceID) {
            sharedSurface = surface
            lastKnownSurfaceID = surfaceID
            logger.info("Successfully connected to IOSurface!")
        } else {
            logger.warning("IOSurfaceLookup failed for ID: \(surfaceID)")
        }
    }

    private func generateFrame() {
        guard _isStreaming else { return }

        let currentTime = CMClockGetTime(CMClockGetHostTimeClock())

        // Periodically try to connect to IOSurface if not connected
        if sharedSurface == nil && sequenceNumber % 30 == 0 {
            connectToIOSurface()
        }

        // Try to read frame from IOSurface, otherwise generate test pattern
        let pixelBuffer: CVPixelBuffer
        if let ioSurfaceBuffer = readFromIOSurface() {
            pixelBuffer = ioSurfaceBuffer
        } else {
            pixelBuffer = createTestPatternBuffer()
        }

        guard let formatDescription = CMFormatDescription.forPixelBuffer(pixelBuffer) else {
            logger.error("Failed to create format description")
            return
        }

        let timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: CMTimeScale(Self.frameRate)),
            presentationTimeStamp: currentTime,
            decodeTimeStamp: .invalid
        )

        do {
            var sampleBuffer: CMSampleBuffer?
            var timingInfo = timing
            CMSampleBufferCreateReadyWithImageBuffer(
                allocator: kCFAllocatorDefault,
                imageBuffer: pixelBuffer,
                formatDescription: formatDescription,
                sampleTiming: &timingInfo,
                sampleBufferOut: &sampleBuffer
            )

            guard let buffer = sampleBuffer else {
                logger.error("Failed to create sample buffer")
                return
            }

            stream.send(
                buffer,
                discontinuity: [],
                hostTimeInNanoseconds: UInt64(currentTime.seconds * Double(NSEC_PER_SEC))
            )

            sequenceNumber += 1
        }
    }

    private func readFromIOSurface() -> CVPixelBuffer? {
        guard let surface = sharedSurface else {
            if sequenceNumber % 30 == 0 {
                logger.info("No IOSurface connection")
            }
            return nil
        }

        // Lock the surface for reading
        surface.lock(options: .readOnly, seed: nil)
        defer { surface.unlock(options: .readOnly, seed: nil) }

        let baseAddress = surface.baseAddress

        // Create a pixel buffer backed by IOSurface
        var pixelBuffer: CVPixelBuffer?
        let attrs: [CFString: Any] = [
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary
        ]

        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            Self.width,
            Self.height,
            kCVPixelFormatType_32BGRA,
            attrs as CFDictionary,
            &pixelBuffer
        )

        guard status == kCVReturnSuccess, let buffer = pixelBuffer else {
            logger.error("Failed to create pixel buffer: \(status)")
            return nil
        }

        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }

        guard let dstAddress = CVPixelBufferGetBaseAddress(buffer) else {
            return nil
        }

        let srcBytesPerRow = surface.bytesPerRow
        let dstBytesPerRow = CVPixelBufferGetBytesPerRow(buffer)

        // Copy row by row to handle stride differences
        for row in 0..<Self.height {
            let srcOffset = row * srcBytesPerRow
            let dstOffset = row * dstBytesPerRow
            memcpy(
                dstAddress.advanced(by: dstOffset),
                baseAddress.advanced(by: srcOffset),
                min(srcBytesPerRow, dstBytesPerRow)
            )
        }

        if sequenceNumber % 30 == 0 {
            logger.info("Successfully read frame from IOSurface")
        }

        return buffer
    }

    private func createTestPatternBuffer() -> CVPixelBuffer {
        var pixelBuffer: CVPixelBuffer?
        let attrs: [CFString: Any] = [
            kCVPixelBufferCGImageCompatibilityKey: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey: true,
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary
        ]

        CVPixelBufferCreate(
            kCFAllocatorDefault,
            Self.width,
            Self.height,
            kCVPixelFormatType_32BGRA,
            attrs as CFDictionary,
            &pixelBuffer
        )

        guard let buffer = pixelBuffer else {
            fatalError("Failed to create pixel buffer")
        }

        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }

        let baseAddress = CVPixelBufferGetBaseAddress(buffer)!
        let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
        let height = CVPixelBufferGetHeight(buffer)
        let width = CVPixelBufferGetWidth(buffer)

        // Generate color bars test pattern
        let colors: [(UInt8, UInt8, UInt8, UInt8)] = [
            (255, 255, 255, 255), // White
            (255, 255, 0, 255),   // Yellow
            (0, 255, 255, 255),   // Cyan
            (0, 255, 0, 255),     // Green
            (255, 0, 255, 255),   // Magenta
            (255, 0, 0, 255),     // Red
            (0, 0, 255, 255),     // Blue
            (0, 0, 0, 255)        // Black
        ]

        let barWidth = width / colors.count

        for y in 0..<height {
            let rowStart = baseAddress.advanced(by: y * bytesPerRow)
            for x in 0..<width {
                let colorIndex = min(x / barWidth, colors.count - 1)
                let color = colors[colorIndex]
                let pixel = rowStart.advanced(by: x * 4).assumingMemoryBound(to: UInt8.self)
                pixel[0] = color.2 // B
                pixel[1] = color.1 // G
                pixel[2] = color.0 // R
                pixel[3] = color.3 // A
            }
        }

        // Add animated indicator
        let frameNum = Int(sequenceNumber % 60)
        let indicatorY = 50
        let indicatorHeight = 20
        let indicatorWidth = 100 + frameNum * 2

        for y in indicatorY..<min(indicatorY + indicatorHeight, height) {
            let rowStart = baseAddress.advanced(by: y * bytesPerRow)
            for x in 50..<min(50 + indicatorWidth, width) {
                let pixel = rowStart.advanced(by: x * 4).assumingMemoryBound(to: UInt8.self)
                pixel[0] = 128 // B
                pixel[1] = 0   // G
                pixel[2] = 128 // R - Purple indicator
                pixel[3] = 255 // A
            }
        }

        return buffer
    }
}

extension CMFormatDescription {
    static func forPixelBuffer(_ pixelBuffer: CVPixelBuffer) -> CMFormatDescription? {
        var formatDescription: CMFormatDescription?
        CMVideoFormatDescriptionCreateForImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: pixelBuffer,
            formatDescriptionOut: &formatDescription
        )
        return formatDescription
    }
}
