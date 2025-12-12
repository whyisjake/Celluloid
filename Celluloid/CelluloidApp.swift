//
//  CelluloidApp.swift
//  Celluloid
//
//  Created by Jake Spurlock on 12/11/25.
//

import SwiftUI
import Combine

@main
struct CelluloidApp: App {
    @StateObject private var cameraManager = CameraManager()
    @StateObject private var extensionManager = ExtensionManager.shared
    @StateObject private var menuBarState = MenuBarState()

    var body: some Scene {
        MenuBarExtra {
            ContentView()
                .environmentObject(cameraManager)
                .onReceive(cameraManager.$isRunning) { isRunning in
                    menuBarState.isRunning = isRunning
                }
        } label: {
            Image(systemName: menuBarState.isRunning ? "camera.fill" : "camera")
                .symbolRenderingMode(.palette)
                .foregroundStyle(menuBarState.isRunning ? .green : .primary)
        }
        .menuBarExtraStyle(.window)
    }
}

class MenuBarState: ObservableObject {
    @Published var isRunning = false
}
