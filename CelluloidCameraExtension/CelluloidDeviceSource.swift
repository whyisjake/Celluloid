//
//  CelluloidDeviceSource.swift
//  CelluloidCameraExtension
//
//  Created by Jake Spurlock on 12/11/25.
//

import Foundation
import CoreMediaIO
import os.log

class CelluloidDeviceSource: NSObject, CMIOExtensionDeviceSource {

    private(set) var device: CMIOExtensionDevice!
    private var streamSource: CelluloidStreamSource!       // Output to video apps
    private var sinkStreamSource: CelluloidSinkStreamSource!  // Input from container app

    init(localizedName: String) {
        super.init()

        let deviceID = UUID()
        device = CMIOExtensionDevice(
            localizedName: localizedName,
            deviceID: deviceID,
            legacyDeviceID: nil,
            source: self
        )

        let formats = CelluloidStreamSource.supportedFormats

        // Create source stream (output to video apps like Zoom)
        streamSource = CelluloidStreamSource(
            localizedName: "Celluloid Camera Stream",
            streamID: UUID(),
            streamFormat: formats[0],
            device: device
        )

        // Create sink stream (input from container app)
        let sinkFormats = CelluloidSinkStreamSource.supportedFormats
        sinkStreamSource = CelluloidSinkStreamSource(
            localizedName: "Celluloid Camera Input",
            streamID: UUID(),
            streamFormat: sinkFormats[0],
            device: device
        )

        // Connect sink to source so received frames can be forwarded
        sinkStreamSource.sourceStream = streamSource
        streamSource.sinkStream = sinkStreamSource

        do {
            try device.addStream(streamSource.stream)
            logger.info("Successfully added source stream to device")
        } catch {
            logger.error("Failed to add source stream: \(error.localizedDescription)")
        }

        do {
            try device.addStream(sinkStreamSource.stream)
            logger.info("Successfully added sink stream to device")
        } catch {
            logger.error("Failed to add sink stream: \(error.localizedDescription)")
        }
    }

    var availableProperties: Set<CMIOExtensionProperty> {
        return [.deviceTransportType, .deviceModel]
    }

    func deviceProperties(forProperties properties: Set<CMIOExtensionProperty>) throws -> CMIOExtensionDeviceProperties {
        let deviceProperties = CMIOExtensionDeviceProperties(dictionary: [:])
        if properties.contains(.deviceTransportType) {
            deviceProperties.transportType = kIOAudioDeviceTransportTypeVirtual
        }
        if properties.contains(.deviceModel) {
            deviceProperties.model = "Celluloid Virtual Camera"
        }
        return deviceProperties
    }

    func setDeviceProperties(_ deviceProperties: CMIOExtensionDeviceProperties) throws {
        // No settable properties
    }

    func startStreaming() {
        streamSource.startStreaming()
    }

    func stopStreaming() {
        streamSource.stopStreaming()
    }
}
