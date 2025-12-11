# Celluloid - Architecture Documentation

## Overview

Celluloid is a macOS virtual camera application that captures video from a physical camera, applies real-time filters and adjustments, and outputs the processed video as a virtual camera that other apps (Zoom, FaceTime, etc.) can use.

## Architecture

The app consists of two main components:

### 1. Main App (`Celluloid/`)

A SwiftUI menu bar application that:
- Captures video from physical cameras using AVFoundation
- Applies real-time image processing (brightness, contrast, saturation, exposure, temperature, filters)
- Writes processed frames to a shared location for the camera extension
- Manages the camera extension lifecycle (install/update)

**Key Files:**

- `CelluloidApp.swift` - App entry point, sets up menu bar presence
- `ContentView.swift` - Main UI with camera preview, adjustments, and filter controls
- `CameraManager.swift` - AVFoundation capture session, frame processing, shared frame output
- `ExtensionManager.swift` - SystemExtensions framework integration for installing/updating the camera extension

### 2. Camera Extension (`CelluloidCameraExtension/`)

A CMIOExtension (CoreMediaIO Extension) that:
- Registers as a virtual camera device in macOS
- Reads processed frames from the main app
- Provides video stream to any app requesting camera input

**Key Files:**

- `main.swift` - Extension entry point
- `CelluloidDeviceSource.swift` - CMIOExtension device provider
- `CelluloidStreamSource.swift` - Frame generation and streaming logic

## Inter-Process Communication Challenge

**The Core Problem:** The main app and camera extension run in completely separate process contexts:
- Main app runs as the logged-in user
- Camera extension runs as `_cmiodalassistants` system daemon

**Why File Sharing Doesn't Work:**

CMIOExtensions run in an extremely restrictive sandbox. They cannot read files from:
- `/Users/Shared/`
- `/var/tmp/`
- `/tmp/`
- App Group containers (different user context)

The extension CAN:
- Create pixel buffers in memory
- Generate graphics (test patterns)
- Send frames to the video system

**Current State:** Extension shows animated color bars (generated internally) because it cannot read the actual camera frames from the filesystem.

## Planned Solution: IOSurface

IOSurface provides shared GPU memory between processes. Implementation requires:

1. **Main App:**
   - Create IOSurface with unique ID
   - Write processed frames to IOSurface
   - Broadcast IOSurface ID via Darwin notifications or XPC

2. **Camera Extension:**
   - Receive IOSurface ID
   - Look up IOSurface by ID
   - Read frames directly from shared memory

This bypasses filesystem entirely and is the standard approach for video frame sharing on macOS.

## Build & Run

1. Open `Celluloid.xcodeproj` in Xcode
2. Build and run the main app
3. Copy the built app to `/Applications/` (required for system extensions)
4. Click "Install" in the app to activate the camera extension
5. The virtual camera "Celluloid Camera" will appear in video apps

## Code Signing Requirements

- Both app and extension must be signed with the same Team ID
- Extension requires `com.apple.developer.system-extension.install` entitlement
- Main app has sandbox disabled to allow frame writing
- Extension has sandbox enabled (required for CMIOExtensions)

## Technical Details

- **Video Format:** 1280x720 @ 30fps, BGRA pixel format
- **Frame Size:** 3,686,400 bytes (1280 * 720 * 4)
- **Filters:** CIFilter-based (CIColorControls, CIExposureAdjust, CITemperatureAndTint, photo effects)

## File Structure

```
Celluloid/
├── Celluloid/                      # Main app target
│   ├── CelluloidApp.swift          # App entry, menu bar setup
│   ├── ContentView.swift           # UI components
│   ├── CameraManager.swift         # Camera capture & processing
│   ├── ExtensionManager.swift      # Extension lifecycle management
│   ├── Celluloid.entitlements      # App entitlements
│   └── Info.plist                  # App configuration
├── CelluloidCameraExtension/       # Camera extension target
│   ├── main.swift                  # Extension entry point
│   ├── CelluloidDeviceSource.swift # Device provider
│   ├── CelluloidStreamSource.swift # Stream source & frame generation
│   ├── CelluloidCameraExtension.entitlements
│   └── Info.plist
└── Celluloid.xcodeproj/            # Xcode project
```

## Debugging

View extension logs:
```bash
log show --predicate 'subsystem contains "Celluloid"' --last 1m
```

Check extension status:
```bash
systemextensionsctl list
```

Check if frames are being written:
```bash
ls -la /tmp/Celluloid/
```
