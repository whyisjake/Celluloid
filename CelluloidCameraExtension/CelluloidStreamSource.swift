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

    func startStream() throws {
        guard !_isStreaming else { return }
        _isStreaming = true
        sequenceNumber = 0

        logger.info("Starting stream")

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

    // MARK: - Test Pattern

    private static let extensionVersion = "V45"

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

        // Color bars
        let colors: [(UInt8, UInt8, UInt8, UInt8)] = [
            (255, 255, 255, 255), (255, 255, 0, 255), (0, 255, 255, 255), (0, 255, 0, 255),
            (255, 0, 255, 255), (255, 0, 0, 255), (0, 0, 255, 255), (0, 0, 0, 255)
        ]

        let barWidth = width / colors.count

        for y in 0..<height {
            let rowStart = baseAddress.advanced(by: y * bytesPerRow)
            for x in 0..<width {
                let colorIndex = min(x / barWidth, colors.count - 1)
                let color = colors[colorIndex]
                let pixel = rowStart.advanced(by: x * 4).assumingMemoryBound(to: UInt8.self)
                pixel[0] = color.2; pixel[1] = color.1; pixel[2] = color.0; pixel[3] = color.3
            }
        }

        // Draw version
        drawText(Self.extensionVersion, baseAddress: baseAddress, bytesPerRow: bytesPerRow, width: width, height: height, startX: 50, startY: 50)
        drawText("rcv:\(receivedBufferCount)", baseAddress: baseAddress, bytesPerRow: bytesPerRow, width: width, height: height, startX: 50, startY: 100)

        return buffer
    }

    private func drawText(_ text: String, baseAddress: UnsafeMutableRawPointer, bytesPerRow: Int, width: Int, height: Int, startX: Int, startY: Int) {
        let charPatterns: [Character: [[Int]]] = [
            "V": [[1,0,0,0,1],[1,0,0,0,1],[1,0,0,0,1],[0,1,0,1,0],[0,1,0,1,0],[0,0,1,0,0],[0,0,1,0,0]],
            "r": [[0,0,0,0,0],[0,0,0,0,0],[1,0,1,1,0],[1,1,0,0,0],[1,0,0,0,0],[1,0,0,0,0],[1,0,0,0,0]],
            "c": [[0,0,0,0,0],[0,0,0,0,0],[0,1,1,1,0],[1,0,0,0,0],[1,0,0,0,0],[1,0,0,0,0],[0,1,1,1,0]],
            "v": [[0,0,0,0,0],[0,0,0,0,0],[1,0,0,0,1],[1,0,0,0,1],[0,1,0,1,0],[0,1,0,1,0],[0,0,1,0,0]],
            ":": [[0,0,0,0,0],[0,0,1,0,0],[0,0,1,0,0],[0,0,0,0,0],[0,0,1,0,0],[0,0,1,0,0],[0,0,0,0,0]],
            " ": [[0,0,0,0,0],[0,0,0,0,0],[0,0,0,0,0],[0,0,0,0,0],[0,0,0,0,0],[0,0,0,0,0],[0,0,0,0,0]],
            "0": [[0,1,1,1,0],[1,0,0,0,1],[1,0,0,0,1],[1,0,0,0,1],[1,0,0,0,1],[1,0,0,0,1],[0,1,1,1,0]],
            "1": [[0,0,1,0,0],[0,1,1,0,0],[0,0,1,0,0],[0,0,1,0,0],[0,0,1,0,0],[0,0,1,0,0],[0,1,1,1,0]],
            "2": [[0,1,1,1,0],[1,0,0,0,1],[0,0,0,0,1],[0,0,1,1,0],[0,1,0,0,0],[1,0,0,0,0],[1,1,1,1,1]],
            "3": [[0,1,1,1,0],[1,0,0,0,1],[0,0,0,0,1],[0,0,1,1,0],[0,0,0,0,1],[1,0,0,0,1],[0,1,1,1,0]],
            "4": [[0,0,0,1,0],[0,0,1,1,0],[0,1,0,1,0],[1,0,0,1,0],[1,1,1,1,1],[0,0,0,1,0],[0,0,0,1,0]],
            "5": [[1,1,1,1,1],[1,0,0,0,0],[1,1,1,1,0],[0,0,0,0,1],[0,0,0,0,1],[1,0,0,0,1],[0,1,1,1,0]],
            "6": [[0,1,1,1,0],[1,0,0,0,0],[1,0,0,0,0],[1,1,1,1,0],[1,0,0,0,1],[1,0,0,0,1],[0,1,1,1,0]],
            "7": [[1,1,1,1,1],[0,0,0,0,1],[0,0,0,1,0],[0,0,1,0,0],[0,1,0,0,0],[0,1,0,0,0],[0,1,0,0,0]],
            "8": [[0,1,1,1,0],[1,0,0,0,1],[1,0,0,0,1],[0,1,1,1,0],[1,0,0,0,1],[1,0,0,0,1],[0,1,1,1,0]],
            "9": [[0,1,1,1,0],[1,0,0,0,1],[1,0,0,0,1],[0,1,1,1,1],[0,0,0,0,1],[0,0,0,0,1],[0,1,1,1,0]]
        ]

        let scale = 6
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
                                if x < width && y < height {
                                    let pixelPtr = baseAddress.advanced(by: y * bytesPerRow + x * 4).assumingMemoryBound(to: UInt8.self)
                                    pixelPtr[0] = 0; pixelPtr[1] = 0; pixelPtr[2] = 0; pixelPtr[3] = 255
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
