//
//  CelluloidProviderSource.swift
//  CelluloidCameraExtension
//
//  Created by Jake Spurlock on 12/11/25.
//

import Foundation
import CoreMediaIO
import IOKit.audio
import os.log

let logger = Logger(subsystem: "com.jakespurlock.Celluloid.Extension", category: "Provider")

class CelluloidProviderSource: NSObject, CMIOExtensionProviderSource {

    private(set) var provider: CMIOExtensionProvider!
    private var deviceSource: CelluloidDeviceSource!

    init(clientQueue: DispatchQueue?) {
        super.init()

        provider = CMIOExtensionProvider(source: self, clientQueue: clientQueue)
        deviceSource = CelluloidDeviceSource(localizedName: "Celluloid Camera")

        do {
            try provider.addDevice(deviceSource.device)
            logger.info("Successfully added Celluloid Camera device")
        } catch {
            logger.error("Failed to add device: \(error.localizedDescription)")
        }
    }

    func connect(to client: CMIOExtensionClient) throws {
        logger.info("Client connected")
    }

    func disconnect(from client: CMIOExtensionClient) {
        logger.info("Client disconnected")
    }

    var availableProperties: Set<CMIOExtensionProperty> {
        return [.providerManufacturer]
    }

    func providerProperties(forProperties properties: Set<CMIOExtensionProperty>) throws -> CMIOExtensionProviderProperties {
        let providerProperties = CMIOExtensionProviderProperties(dictionary: [:])
        if properties.contains(.providerManufacturer) {
            providerProperties.manufacturer = "Celluloid"
        }
        return providerProperties
    }

    func setProviderProperties(_ providerProperties: CMIOExtensionProviderProperties) throws {
        // No settable properties
    }
}
