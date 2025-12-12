//
//  CelluloidApp.swift
//  Celluloid
//
//  Created by Jake Spurlock on 12/11/25.
//

import SwiftUI

@main
struct CelluloidApp: App {
    @StateObject private var cameraManager = CameraManager()

    var body: some Scene {
        MenuBarExtra("Celluloid", systemImage: "camera.filters") {
            ContentView()
                .environmentObject(cameraManager)
        }
        .menuBarExtraStyle(.window)
    }
}
