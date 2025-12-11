//
//  main.swift
//  CelluloidCameraExtension
//
//  Created by Jake Spurlock on 12/11/25.
//

import Foundation
import CoreMediaIO

let providerSource = CelluloidProviderSource(clientQueue: nil)
CMIOExtensionProvider.startService(provider: providerSource.provider)

CFRunLoopRun()
