# Celluloid - GitHub Copilot Instructions

## Project Overview

**Celluloid** is a macOS virtual camera application that captures video from physical cameras, applies real-time filters and adjustments, and outputs processed video as a virtual camera for use in video conferencing apps (Zoom, Google Meet, FaceTime, etc.).

**Key Facts:**
- **Language:** Swift 5.0
- **Frameworks:** SwiftUI, AVFoundation, CoreMediaIO (CMIOExtension), CoreImage
- **Deployment Target:** macOS 26.1+ (macOS 15 Sequoia)
- **Project Size:** ~2,500 lines of Swift code across 9 source files
- **Architecture:** Two-component system (Main App + System Extension)
- **Build System:** Xcode 26.1.1, no external build tools (no CocoaPods, SPM dependencies, or Carthage)
- **Code Signing:** Requires Team ID `36ERVRQ23S` for both app and extension

## Architecture

The app consists of two main components running in separate processes:

### 1. Main App (`Celluloid/` directory)
A SwiftUI menu bar application that:
- Captures video from physical cameras using AVFoundation
- Applies real-time image processing (brightness, contrast, saturation, exposure, temperature, filters, LUTs)
- Sends processed frames to the camera extension via CMIOExtension sink stream
- Manages the system extension lifecycle (install/update)

**Key Files:**
- `CelluloidApp.swift` (35 lines) - App entry point, menu bar setup
- `ContentView.swift` (449 lines) - Main UI with camera preview, adjustments, filter controls
- `CameraManager.swift` (1,202 lines) - **Core logic**: AVFoundation capture, filter processing, sink stream connection
- `ExtensionManager.swift` (125 lines) - SystemExtensions framework integration

### 2. Camera Extension (`CelluloidCameraExtension/` directory)
A CMIOExtension (CoreMediaIO System Extension) that:
- Registers as a virtual camera device named "Celluloid Camera" in macOS
- Receives processed frames from the main app via sink stream
- Provides video stream to any app requesting camera input

**Key Files:**
- `main.swift` (14 lines) - Extension entry point
- `CelluloidProviderSource.swift` (57 lines) - CMIOExtension provider
- `CelluloidDeviceSource.swift` (93 lines) - Device provider, connects sink and source streams
- `CelluloidSinkStream.swift` (203 lines) - Receives frames from main app
- `CelluloidStreamSource.swift` (314 lines) - Outputs frames to video apps

## Building and Testing

### Prerequisites
- **macOS 15.0 (Sequoia) or later** - This project ONLY builds on macOS
- **Xcode 26.1.1** or later
- Apple Developer account with valid Team ID for code signing

### Building the App

**⚠️ IMPORTANT:** The build process automatically installs the app to `/Applications/`. This is **REQUIRED** for system extensions to work. Running the app from Xcode's build directory will fail.

#### Build Commands

```bash
# Open project in Xcode
open Celluloid.xcodeproj

# Build from command line (Debug configuration)
xcodebuild -project Celluloid.xcodeproj -scheme Celluloid -configuration Debug build

# Build from command line (Release configuration)
xcodebuild -project Celluloid.xcodeproj -scheme Celluloid -configuration Release build

# Build and archive for distribution
xcodebuild -project Celluloid.xcodeproj -scheme Celluloid -configuration Release archive -archivePath ./build/Celluloid.xcarchive
```

**Build Output Locations:**
- Debug builds: `~/Library/Developer/Xcode/DerivedData/Celluloid-*/Build/Products/Debug/Celluloid.app`
- Release builds: `~/Library/Developer/Xcode/DerivedData/Celluloid-*/Build/Products/Release/Celluloid.app`

**Build Time:** Typical clean build takes 30-60 seconds on modern Mac hardware.

### Running the App

1. **Build the app** using Xcode (⌘+B) or xcodebuild
2. **Copy to /Applications/**: The app MUST be in `/Applications/` for system extensions to work
3. **Launch** the app from `/Applications/Celluloid.app`
4. **Approve system extension** when prompted (first launch only)
5. The virtual camera "Celluloid Camera" will appear in video apps after approval

**Note:** The app runs as a menu bar app (LSUIElement = true), so it won't appear in the Dock.

### Testing

The project uses Swift Testing framework (not XCTest).

**Test Files:**
- `CelluloidTests/CelluloidTests.swift` (482 lines)
- Tests cover: FilterType enum, settings boundaries, LUT parsers (Cube and HALD CLUT), adjustment resets

**Running Tests:**

```bash
# Run all tests from Xcode
# Use Test Navigator (⌘+6) or Product > Test (⌘+U)

# Run tests from command line
xcodebuild test -project Celluloid.xcodeproj -scheme Celluloid -destination 'platform=macOS'

# Run specific test
xcodebuild test -project Celluloid.xcodeproj -scheme Celluloid -destination 'platform=macOS' -only-testing:CelluloidTests/CelluloidTests/filterTypeHasCorrectCases
```

**Test Execution Time:** Full test suite runs in ~2-5 seconds.

**UI Tests:** The `CelluloidUITests/` directory exists but is currently empty. UI testing is not yet implemented.

## Code Organization

### Directory Structure
```
Celluloid/
├── Celluloid/                          # Main app target
│   ├── CelluloidApp.swift              # App entry, menu bar setup
│   ├── ContentView.swift               # UI: preview, sliders, filters, LUTs
│   ├── CameraManager.swift             # Camera capture, processing, sink stream connection
│   ├── ExtensionManager.swift          # System extension lifecycle management
│   ├── Celluloid.entitlements          # App entitlements (camera, system-extension.install)
│   ├── Info.plist                      # App configuration (LSUIElement, camera usage)
│   └── Assets.xcassets/                # App icons and assets
├── CelluloidCameraExtension/           # Camera extension target
│   ├── main.swift                      # Extension entry point
│   ├── CelluloidProviderSource.swift   # CMIOExtension provider
│   ├── CelluloidDeviceSource.swift     # Device provider
│   ├── CelluloidSinkStream.swift       # Input stream from main app
│   ├── CelluloidStreamSource.swift     # Output stream to video apps
│   ├── CelluloidCameraExtension.entitlements  # Extension entitlements (sandboxed)
│   └── Info.plist                      # Extension configuration
├── CelluloidTests/                     # Unit tests (Swift Testing)
│   └── CelluloidTests.swift            # Filter, LUT, and settings tests
├── CelluloidUITests/                   # UI tests (empty)
├── LUT_pack/                           # LUT resources bundled with app
│   ├── Film Presets/                   # PNG HALD LUTs (512x512)
│   ├── Webcam Presets/                 # Cube LUTs
│   └── Contrast Filters/               # Additional LUTs
├── screenshots/                        # App screenshots for README
├── Celluloid.xcodeproj/               # Xcode project file
├── README.md                          # User-facing documentation
└── CLAUDE.md                          # Architecture documentation
```

### Important File Locations
- **Entitlements:** `Celluloid/Celluloid.entitlements`, `CelluloidCameraExtension/CelluloidCameraExtension.entitlements`
- **Info.plist files:** `Celluloid/Info.plist`, `CelluloidCameraExtension/Info.plist`
- **Project settings:** `Celluloid.xcodeproj/project.pbxproj`
- **LUT resources:** `LUT_pack/` (bundled as resources, referenced in ContentView.swift)

## Critical Technical Details

### Code Signing Requirements
- **Both targets** (app and extension) MUST be signed with the **same Team ID** (`36ERVRQ23S`)
- **Main app entitlements:**
  - `com.apple.developer.system-extension.install` = true (required to install extension)
  - `com.apple.security.device.camera` = true (camera access)
  - `com.apple.security.app-sandbox` = false (disabled to allow sink stream connection)
  - Application group: `36ERVRQ23S.com.jakespurlock.Celluloid`
- **Extension entitlements:**
  - `com.apple.security.app-sandbox` = true (REQUIRED for system extensions)
  - Application groups: `36ERVRQ23S.com.jakespurlock.Celluloid`, `group.com.jakespurlock.Celluloid`

### Video Format Specifications
- **Resolution:** 1280x720 (720p)
- **Frame Rate:** 30 fps
- **Pixel Format:** kCVPixelFormatType_32BGRA (BGRA, 4 bytes per pixel)
- **Frame Size:** 3,686,400 bytes (1280 × 720 × 4)

### Inter-Process Communication
The main app and extension communicate via **CMIOExtension sink/source streams** (not files):
- Main app creates sink stream client and sends CMSampleBuffer frames
- Extension receives frames via sink stream, forwards to source stream
- Video apps consume from source stream

**Historical Note:** Earlier versions attempted file-based communication, but this doesn't work due to sandbox restrictions. The current implementation uses CMIOExtension's built-in sink/source mechanism.

### Filter Processing Pipeline
Filters are applied in `CameraManager.applyFilters(to:)` in this order:
1. Basic adjustments (brightness, contrast, saturation) - CIColorControls
2. Exposure adjustment - CIExposureAdjust
3. Temperature/tint - CITemperatureAndTint
4. Sharpness - CISharpenLuminance
5. Selected filter (Noir, Chrome, Fade, etc.) or Black Mist (custom bloom effect)
6. LUT (if selected) - CIColorCube or CIColorCubeWithColorSpace

### LUT Support
The app supports two LUT formats:
- **Cube LUTs** (.cube files) - Parsed by `CubeLUTParser` in CameraManager.swift
- **HALD CLUTs** (.png files, 512x512) - Parsed by `HALDCLUTParser` in CameraManager.swift
- LUTs are loaded from `LUT_pack/` directory at runtime

## Common Tasks and Pitfalls

### Making Code Changes

**ALWAYS test on macOS with Xcode.** This project cannot be built on Linux or Windows.

**When modifying the main app:**
1. Edit Swift files in `Celluloid/` directory
2. Build in Xcode (⌘+B)
3. Copy built app to `/Applications/` (can use Release scheme's post-build script)
4. Launch app from `/Applications/` to test with system extension

**When modifying the camera extension:**
1. Edit Swift files in `CelluloidCameraExtension/` directory
2. Build in Xcode (⌘+B) - extension is embedded in app bundle
3. The app will automatically update the extension on next launch
4. You may need to approve extension replacement in System Settings

**Common Build Errors:**
- **"Code signing failed"** - Verify Team ID is set to `36ERVRQ23S` in both targets
- **"Extension not found"** - Extension must be embedded in app bundle at `Contents/Library/SystemExtensions/`
- **"Permission denied" accessing camera** - Ensure `com.apple.security.device.camera` entitlement is present

### Debugging

**Main App Logs:**
```bash
# View app logs (last 5 minutes)
log show --predicate 'subsystem contains "com.jakespurlock.Celluloid"' --last 5m

# Continuous logging
log stream --predicate 'subsystem contains "com.jakespurlock.Celluloid"'
```

**Extension Logs:**
```bash
# View extension logs
log show --predicate 'subsystem contains "com.jakespurlock.Celluloid.Extension"' --last 5m

# Check extension status
systemextensionsctl list
```

**Common Runtime Issues:**
- **Virtual camera not appearing** - Extension may not be activated. Check `systemextensionsctl list`
- **Black screen in video apps** - Check if sink stream is connected in CameraManager logs
- **Camera not starting** - Verify camera permissions in System Settings > Privacy & Security > Camera

### Performance Considerations
- **Filter processing** is CPU-intensive. CIImage operations are performed on CPU, not GPU (Metal rendering not yet implemented)
- **Frame rate** may drop on older Macs with complex filter combinations
- **Memory usage** increases with LUT size (64³ cube = ~1MB per LUT in memory)

## CI/CD and Workflows

**Currently:** There are no GitHub Actions workflows or CI/CD pipelines configured.

**Future:** If adding CI/CD:
- Must run on macOS runners (GitHub Actions macOS runners or self-hosted)
- Consider notarization requirements for distribution
- Archive and export IPA for distribution: `xcodebuild -exportArchive`

## Key Constants and Configuration

**Bundle Identifiers:**
- Main app: `jakespurlock.Celluloid`
- Extension: `jakespurlock.Celluloid.CelluloidCameraExtension`

**Version Numbers:**
- Marketing version: `1.0`
- Build version (app): `51`
- Build version (extension): `48`

**Shared Constants** (in `CameraManager.swift`):
```swift
struct CelluloidShared {
    static let width = 1280
    static let height = 720
}
```

## Dependencies

**No external dependencies.** The project uses only Apple frameworks:
- SwiftUI (UI)
- AVFoundation (camera capture)
- CoreMediaIO (CMIOExtension for virtual camera)
- CoreImage (filter processing)
- SystemExtensions (extension management)
- CoreVideo (pixel buffer handling)
- Combine (reactive updates)

## Final Notes

**Trust these instructions.** This document was created by thoroughly exploring the codebase. Only search for additional information if you find these instructions incomplete or incorrect.

**System Extension Complexity:** CMIOExtensions are advanced macOS system components. The documentation is sparse, and debugging is challenging. The current sink/source stream implementation is the result of significant experimentation.

**Development Workflow:** Always build → copy to /Applications → test. Running from Xcode's DerivedData will not work for system extension functionality.

**Camera Permissions:** The app requires explicit camera permission. If permission is denied, the app will show a permission error. Users must grant permission in System Settings.
