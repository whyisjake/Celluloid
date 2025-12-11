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
    private var streamSource: CelluloidStreamSource!

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

        streamSource = CelluloidStreamSource(
            localizedName: "Celluloid Camera Stream",
            streamID: UUID(),
            streamFormat: formats[0],
            device: device
        )

        do {
            try device.addStream(streamSource.stream)
            logger.info("Successfully added stream to device")
        } catch {
            logger.error("Failed to add stream: \(error.localizedDescription)")
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
