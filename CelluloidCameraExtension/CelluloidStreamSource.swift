//
//  CelluloidStreamSource.swift
//  CelluloidCameraExtension
//
//  Created by Jake Spurlock on 12/11/25.
//

import Foundation
import CoreMediaIO
import CoreVideo
import os.log

class CelluloidStreamSource: NSObject, CMIOExtensionStreamSource {

    private(set) var stream: CMIOExtensionStream!

    let device: CMIOExtensionDevice
    private let _streamFormat: CMIOExtensionStreamFormat

    private var _isStreaming = false
    private var frameTimer: DispatchSourceTimer?
    private let timerQueue = DispatchQueue(label: "com.celluloid.frameTimer", qos: .userInteractive)

    private var sequenceNumber: UInt64 = 0

    // Buffer received from sink stream (from container app)
    private var receivedBuffer: CMSampleBuffer?
    private let bufferLock = NSLock()
    private var receivedBufferCount = 0

    // Reference to sink stream to trigger consumption when source starts
    weak var sinkStream: CelluloidSinkStreamSource?

    // Cache last good pixel buffer for smooth playback
    private var lastGoodPixelBuffer: CVPixelBuffer?

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
        return [.streamActiveFormatIndex, .streamFrameDuration]
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
        logger.info("Source stream authorized - triggering sink consumption")
        sinkStream?.triggerConsumption(for: client)
        return true
    }

    private static let streamStartedNotification = "com.celluloid.streamStarted" as CFString
    private static let streamStoppedNotification = "com.celluloid.streamStopped" as CFString

    func startStream() throws {
        guard !_isStreaming else { return }
        _isStreaming = true
        sequenceNumber = 0

        logger.info("Starting stream - external app is using the camera")

        // Notify main app via Darwin notification (works across sandbox)
        let notifyCenter = CFNotificationCenterGetDarwinNotifyCenter()
        CFNotificationCenterPostNotification(notifyCenter, CFNotificationName(Self.streamStartedNotification), nil, nil, true)
        logger.info("Posted Darwin notification: streamStarted")

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
        logger.info("Stopping stream - external app stopped using the camera")

        // Notify main app via Darwin notification (works across sandbox)
        let notifyCenter = CFNotificationCenterGetDarwinNotifyCenter()
        CFNotificationCenterPostNotification(notifyCenter, CFNotificationName(Self.streamStoppedNotification), nil, nil, true)
        logger.info("Posted Darwin notification: streamStopped")

        frameTimer?.cancel()
        frameTimer = nil
    }

    func startStreaming() {
        try? startStream()
    }

    func stopStreaming() {
        try? stopStream()
    }

    // MARK: - Receiving frames from sink stream

    func enqueueReceivedBuffer(_ buffer: CMSampleBuffer) {
        bufferLock.lock()
        receivedBuffer = buffer
        receivedBufferCount += 1
        bufferLock.unlock()

        if receivedBufferCount % 30 == 0 {
            logger.info("Received \(self.receivedBufferCount) buffers from container app")
        }
    }

    private func dequeueReceivedPixelBuffer() -> CVPixelBuffer? {
        bufferLock.lock()
        if let buffer = receivedBuffer {
            if let pixelBuffer = CMSampleBufferGetImageBuffer(buffer) {
                lastGoodPixelBuffer = pixelBuffer
            }
            receivedBuffer = nil
            bufferLock.unlock()
            return lastGoodPixelBuffer
        }
        let pixelBuffer = lastGoodPixelBuffer
        bufferLock.unlock()
        return pixelBuffer
    }

    private func generateFrame() {
        guard _isStreaming else { return }

        let currentTime = CMClockGetTime(CMClockGetHostTimeClock())

        let pixelBuffer: CVPixelBuffer
        if let sinkBuffer = dequeueReceivedPixelBuffer() {
            pixelBuffer = sinkBuffer
        } else {
            pixelBuffer = createTestPatternBuffer()
        }

        guard let formatDescription = CMFormatDescription.forPixelBuffer(pixelBuffer) else {
            return
        }

        var timingInfo = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: CMTimeScale(Self.frameRate)),
            presentationTimeStamp: currentTime,
            decodeTimeStamp: .invalid
        )

        var sampleBuffer: CMSampleBuffer?
        CMSampleBufferCreateReadyWithImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: pixelBuffer,
            formatDescription: formatDescription,
            sampleTiming: &timingInfo,
            sampleBufferOut: &sampleBuffer
        )

        guard let buffer = sampleBuffer else { return }

        stream.send(
            buffer,
            discontinuity: [],
            hostTimeInNanoseconds: UInt64(currentTime.seconds * Double(NSEC_PER_SEC))
        )

        sequenceNumber += 1
    }

    // MARK: - Placeholder Image

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

        // Dark gray background
        for y in 0..<height {
            let rowStart = baseAddress.advanced(by: y * bytesPerRow)
            for x in 0..<width {
                let pixel = rowStart.advanced(by: x * 4).assumingMemoryBound(to: UInt8.self)
                pixel[0] = 40; pixel[1] = 40; pixel[2] = 40; pixel[3] = 255  // Dark gray BGRA
            }
        }

        // Draw "CELLULOID" centered
        drawTextWhite("CELLULOID", baseAddress: baseAddress, bytesPerRow: bytesPerRow, width: width, height: height, startX: width/2 - 180, startY: height/2 - 40)

        return buffer
    }

    private func drawTextWhite(_ text: String, baseAddress: UnsafeMutableRawPointer, bytesPerRow: Int, width: Int, height: Int, startX: Int, startY: Int) {
        let charPatterns: [Character: [[Int]]] = [
            "C": [[0,1,1,1,0],[1,0,0,0,1],[1,0,0,0,0],[1,0,0,0,0],[1,0,0,0,0],[1,0,0,0,1],[0,1,1,1,0]],
            "E": [[1,1,1,1,1],[1,0,0,0,0],[1,0,0,0,0],[1,1,1,1,0],[1,0,0,0,0],[1,0,0,0,0],[1,1,1,1,1]],
            "L": [[1,0,0,0,0],[1,0,0,0,0],[1,0,0,0,0],[1,0,0,0,0],[1,0,0,0,0],[1,0,0,0,0],[1,1,1,1,1]],
            "U": [[1,0,0,0,1],[1,0,0,0,1],[1,0,0,0,1],[1,0,0,0,1],[1,0,0,0,1],[1,0,0,0,1],[0,1,1,1,0]],
            "O": [[0,1,1,1,0],[1,0,0,0,1],[1,0,0,0,1],[1,0,0,0,1],[1,0,0,0,1],[1,0,0,0,1],[0,1,1,1,0]],
            "I": [[0,1,1,1,0],[0,0,1,0,0],[0,0,1,0,0],[0,0,1,0,0],[0,0,1,0,0],[0,0,1,0,0],[0,1,1,1,0]],
            "D": [[1,1,1,0,0],[1,0,0,1,0],[1,0,0,0,1],[1,0,0,0,1],[1,0,0,0,1],[1,0,0,1,0],[1,1,1,0,0]],
            " ": [[0,0,0,0,0],[0,0,0,0,0],[0,0,0,0,0],[0,0,0,0,0],[0,0,0,0,0],[0,0,0,0,0],[0,0,0,0,0]]
        ]

        let scale = 8
        var currentX = startX

        for char in text {
            guard let pattern = charPatterns[char] else { continue }
            for (rowIdx, row) in pattern.enumerated() {
                for (colIdx, pixel) in row.enumerated() {
                    if pixel == 1 {
                        for sy in 0..<scale {
                            for sx in 0..<scale {
                                let x = currentX + colIdx * scale + sx
                                let y = startY + rowIdx * scale + sy
                                if x >= 0 && x < width && y >= 0 && y < height {
                                    let pixelPtr = baseAddress.advanced(by: y * bytesPerRow + x * 4).assumingMemoryBound(to: UInt8.self)
                                    pixelPtr[0] = 200; pixelPtr[1] = 200; pixelPtr[2] = 200; pixelPtr[3] = 255  // Light gray
                                }
                            }
                        }
                    }
                }
            }
            currentX += 6 * scale
        }
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
