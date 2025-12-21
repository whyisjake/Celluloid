//
//  GateWeaveFilter.swift
//  Celluloid
//
//  Simulates the subtle frame instability of old film projectors
//

import CoreImage
import Foundation

/// A CIFilter that simulates gate weave - the subtle frame instability
/// caused by film not sitting perfectly still in the projector gate.
///
/// The effect creates organic micro-jitter using smooth random motion
/// based on multiple sine waves at different frequencies.
class GateWeaveFilter: CIFilter {

    // MARK: - Input Parameters

    @objc dynamic var inputImage: CIImage?

    /// Overall strength of the effect (0.0 - 1.0). Default: 0.5
    @objc dynamic var inputStrength: CGFloat = 0.5

    /// Intensity of the horizontal weave (pixels). Default: 4.0
    @objc dynamic var inputHorizontalAmount: CGFloat = 4.0

    /// Intensity of the vertical weave (pixels). Default: 3.0
    @objc dynamic var inputVerticalAmount: CGFloat = 3.0

    /// Intensity of rotational weave (degrees). Default: 0.3
    @objc dynamic var inputRotationAmount: CGFloat = 0.3

    /// Speed of the weave motion. Default: 1.2
    @objc dynamic var inputSpeed: CGFloat = 1.2

    // MARK: - Internal State

    /// Time accumulator for animation
    private static var time: Double = 0.0
    private static let startTime = Date()

    // MARK: - Filter Output

    override var outputImage: CIImage? {
        guard let input = inputImage else { return nil }

        // Get elapsed time for smooth animation
        let elapsed = Date().timeIntervalSince(GateWeaveFilter.startTime) * Double(inputSpeed)

        // Generate smooth random motion using multiple sine waves
        // This creates organic, non-repeating motion
        // Apply inputStrength to scale all motion
        let strength = Double(inputStrength)
        let xOffset = calculateWeave(time: elapsed, frequencies: [0.7, 1.3, 2.1], amplitude: Double(inputHorizontalAmount) * strength)
        let yOffset = calculateWeave(time: elapsed, frequencies: [0.5, 1.1, 1.9], amplitude: Double(inputVerticalAmount) * strength)
        let rotation = calculateWeave(time: elapsed, frequencies: [0.3, 0.8, 1.5], amplitude: Double(inputRotationAmount) * .pi / 180.0 * strength)

        // Create transform centered on the image
        let centerX = input.extent.midX
        let centerY = input.extent.midY

        // Build the transform: translate to center, rotate, translate back, then apply offset
        var transform = CGAffineTransform.identity

        // Move to center
        transform = transform.translatedBy(x: centerX, y: centerY)

        // Apply rotation
        transform = transform.rotated(by: rotation)

        // Move back from center
        transform = transform.translatedBy(x: -centerX, y: -centerY)

        // Apply translation offset
        transform = transform.translatedBy(x: xOffset, y: yOffset)

        // Apply the transform
        let transformed = input.transformed(by: transform)

        // Crop back to original extent to avoid edge artifacts
        return transformed.cropped(to: input.extent)
    }

    // MARK: - Weave Calculation

    /// Calculate smooth organic motion using layered sine waves
    /// - Parameters:
    ///   - time: Current time in seconds
    ///   - frequencies: Array of frequencies for layered sine waves
    ///   - amplitude: Maximum displacement
    /// - Returns: Current offset value
    private func calculateWeave(time: Double, frequencies: [Double], amplitude: Double) -> CGFloat {
        var result: Double = 0.0

        // Layer multiple sine waves with different frequencies
        // This creates more organic, less predictable motion
        for (index, freq) in frequencies.enumerated() {
            let phase = Double(index) * 0.7  // Phase offset for each wave
            let weight = 1.0 / Double(index + 1)  // Higher frequencies have less influence
            result += sin(time * freq + phase) * weight
        }

        // Normalize and apply amplitude
        let normalizer = frequencies.enumerated().reduce(0.0) { $0 + 1.0 / Double($1.offset + 1) }
        result = (result / normalizer) * amplitude

        return CGFloat(result)
    }

    // MARK: - Filter Attributes

    override var attributes: [String: Any] {
        return [
            kCIAttributeFilterDisplayName: "Gate Weave",
            kCIAttributeFilterCategories: [kCICategoryDistortionEffect, kCICategoryVideo, kCICategoryStillImage],
            "inputHorizontalAmount": [
                kCIAttributeDefault: 4.0,
                kCIAttributeMin: 0.0,
                kCIAttributeMax: 15.0,
                kCIAttributeType: kCIAttributeTypeScalar
            ],
            "inputVerticalAmount": [
                kCIAttributeDefault: 3.0,
                kCIAttributeMin: 0.0,
                kCIAttributeMax: 15.0,
                kCIAttributeType: kCIAttributeTypeScalar
            ],
            "inputRotationAmount": [
                kCIAttributeDefault: 0.3,
                kCIAttributeMin: 0.0,
                kCIAttributeMax: 2.0,
                kCIAttributeType: kCIAttributeTypeScalar
            ],
            "inputSpeed": [
                kCIAttributeDefault: 1.2,
                kCIAttributeMin: 0.1,
                kCIAttributeMax: 3.0,
                kCIAttributeType: kCIAttributeTypeScalar
            ]
        ]
    }
}
