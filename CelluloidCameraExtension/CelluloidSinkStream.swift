//
//  CelluloidSinkStream.swift
//  CelluloidCameraExtension
//
//  Created by Jake Spurlock on 12/11/25.
//

import Foundation
import CoreMediaIO
import os.log

// Use the shared logger from CelluloidProviderSource.swift

/// Sink stream that receives frames from the container app
class CelluloidSinkStreamSource: NSObject, CMIOExtensionStreamSource {

    private(set) var stream: CMIOExtensionStream!

    let device: CMIOExtensionDevice
    private let _streamFormat: CMIOExtensionStreamFormat

    // Reference to source stream to forward received buffers
    weak var sourceStream: CelluloidStreamSource?

    // Store the client for consuming buffers
    private var sinkClient: CMIOExtensionClient?
    private var isConsuming = false
    private var isStreamingStarted = false  // Track if startStream() was called

    // Debug counters - shared with source stream
    static var authCount = 0
    static var startCount = 0
    static var consumeCallbackCount = 0

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
            direction: .sink,  // KEY: This is a sink (input) stream
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
        // Store the client for later use in consuming buffers
        // This should be the container app (Celluloid) connecting to send us frames
        sinkClient = client
        Self.authCount += 1
        logger.info("Sink stream authorized for CONTAINER APP client (auth #\(Self.authCount)) - ready to receive frames")
        return true
    }

    func startStream() throws {
        Self.startCount += 1
        isStreamingStarted = true
        logger.info("Sink stream started #\(Self.startCount) - stream is now in streaming state")
        // Start consuming buffers from the container app
        startConsuming()
    }

    func stopStream() throws {
        logger.info("Sink stream stopped")
        isStreamingStarted = false
        isConsuming = false
        sinkClient = nil
    }

    // MARK: - Consuming frames from container app

    /// Start the buffer consumption loop
    private var consumeCount = 0
    func startConsuming() {
        guard let client = sinkClient else {
            logger.warning("No client available for consuming buffers")
            return
        }

        logger.info("Starting buffer consumption loop")
        isConsuming = true
        consumeNextBuffer(from: client)
    }

    /// Triggered by source stream when a client (like Photo Booth) connects
    /// This does NOT override the sink client - we only consume from the container app
    func triggerConsumption(for client: CMIOExtensionClient) {
        logger.info("Source stream client connected - checking if sink stream is ready")

        // Only consume if the sink stream is in a streaming state AND we have a client
        guard isStreamingStarted else {
            logger.info("Sink stream not yet started - container app needs to call CMIODeviceStartStream first")
            return
        }

        if let existingClient = sinkClient {
            logger.info("Using existing sink client (container app) for consumption")
            if !isConsuming {
                isConsuming = true
                consumeNextBuffer(from: existingClient)
            }
        } else {
            logger.warning("No sink client yet - container app hasn't connected to sink stream")
        }
    }

    /// Recursively consume buffers from the container app
    private func consumeNextBuffer(from client: CMIOExtensionClient) {
        guard isConsuming, isStreamingStarted else { return }

        // This call pulls a frame from the container app's queue
        stream.consumeSampleBuffer(from: client) { [weak self] sampleBuffer, sequenceNumber, discontinuity, hasMoreSampleBuffers, error in
            guard let self = self else { return }

            self.consumeCount += 1
            Self.consumeCallbackCount += 1

            if let error = error {
                // Log error periodically
                if self.consumeCount % 30 == 1 {
                    logger.error("consumeSampleBuffer error: \(error.localizedDescription)")
                }
                if self.isConsuming {
                    // Retry after a short delay
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.033) {
                        self.consumeNextBuffer(from: client)
                    }
                }
                return
            }

            if let sampleBuffer = sampleBuffer {
                // Forward the buffer to the source stream
                self.sourceStream?.enqueueReceivedBuffer(sampleBuffer)
                if self.consumeCount % 30 == 0 {
                    logger.info("Forwarded \(self.consumeCount) buffers to source stream")
                }
            }

            // Continue consuming if there are more buffers or we're still streaming
            if self.isConsuming {
                self.consumeNextBuffer(from: client)
            }
        }
    }
}
