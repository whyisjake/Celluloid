# Celluloid

A lightweight macOS menu bar app that adds real-time filters and adjustments to your webcam feed, outputting to a virtual camera for use in any video conferencing app.

## Features

### Real-time Adjustments
- **Brightness** - Lighten or darken your image (-1.0 to 1.0)
- **Contrast** - Adjust the difference between light and dark areas (0.25 to 4.0)
- **Saturation** - Control color intensity (0.0 to 2.0)
- **Exposure** - Simulate camera exposure compensation (-2.0 to 2.0 EV)
- **Temperature** - Warm up or cool down your image (2000K to 10000K)

### Filters
- **None** - Original camera feed
- **Noir** - Classic black and white film look
- **Chrome** - Vintage chrome processing
- **Fade** - Soft, faded aesthetic
- **Instant** - Polaroid-style instant film
- **Mono** - Clean monochrome
- **Process** - Cross-processed film effect
- **Tonal** - High-contrast black and white
- **Transfer** - Vintage transfer print look

### Virtual Camera
Celluloid installs a system camera extension that appears as "Celluloid Camera" in any app that uses video input - Zoom, Google Meet, FaceTime, OBS, and more.

## Requirements

- macOS 13.0 or later
- Apple Silicon or Intel Mac
- Camera access permission

## Installation

1. Download Celluloid.app
2. Move to /Applications folder (required for system extension)
3. Launch and grant camera permission
4. Click "Install" to enable the virtual camera
5. Approve the system extension in System Settings > Privacy & Security

## Usage

1. Launch Celluloid from Applications
2. Select your input camera from the dropdown
3. Adjust sliders and select filters to taste
4. In your video app (Zoom, Meet, etc.), select "Celluloid Camera" as your camera source

## Architecture

Celluloid consists of two components:

1. **Main App** - Captures video from your physical camera, applies Core Image filters, and writes processed frames to a shared location
2. **Camera Extension** - A CMIOExtension system extension that reads processed frames and presents them as a virtual camera device

## Development

Built with:
- SwiftUI for the interface
- AVFoundation for camera capture
- Core Image for real-time filtering
- CMIOExtension for virtual camera output

## License

MIT License - See LICENSE file for details
