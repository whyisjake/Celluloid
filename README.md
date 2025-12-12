# Celluloid

A macOS virtual camera app that captures your webcam feed, applies real-time filters, and outputs to a virtual camera for use in video conferencing apps like Zoom, Google Meet, and FaceTime.

## Features

- Real-time camera filters (Noir, Chrome, Fade, Instant, Mono, etc.)
- Adjustable brightness, contrast, saturation, exposure, and color temperature
- Works with any app that supports camera input
- Menubar app for easy access

## Architecture

```
┌─────────────────────┐                        ┌──────────────────────────┐
│   Celluloid App     │                        │   CMIO Extension         │
│                     │   CoreMediaIO          │                          │
│  - Captures camera  │   Sink Stream          │  Sink Stream (input)     │
│  - Applies filters  │ ──────────────────────▶│         │                │
│  - Sends to sink    │                        │         ▼                │
│                     │                        │  Source Stream (output)  │
│                     │                        │         │                │
└─────────────────────┘                        │         ▼                │
                                               │  Video Apps (Zoom, etc)  │
                                               └──────────────────────────┘
```

## Requirements

- macOS 13.0 or later
- Camera access permission

## Installation

1. Build the project in Xcode
2. Move Celluloid.app to /Applications
3. Launch the app and approve the system extension when prompted
4. Select "Celluloid Camera" in your video app's camera settings

## Future Enhancements

### Performance Optimizations

1. **Skip CGImage conversion** - Render CIImage directly to CVPixelBuffer instead of going through CGImage, eliminating an intermediate conversion step.

2. **CVPixelBufferPool** - Reuse pixel buffers from a pool instead of creating new ones each frame, reducing memory allocation overhead.

3. **IOSurface-backed buffers** - Use IOSurface for zero-copy frame transfer between the app and extension, avoiding memory copies entirely.

4. **Metal rendering** - Use Metal/GPU for filter processing instead of CPU-based Core Image rendering for better performance on complex filters.

### Feature Ideas

- Custom LUT (Look-Up Table) support for advanced color grading
- Face tracking and background blur
- Virtual backgrounds
- Recording/snapshot capability
- Preset management for filter combinations
- Keyboard shortcuts for quick filter switching

## License

MIT
