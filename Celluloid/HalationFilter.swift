//
//  HalationFilter.swift
//  Celluloid
//
//  Simulates film halation - the red/orange glow around highlights
//  caused by light bouncing off the film base
//

import CoreImage

/// A CIFilter that simulates halation - the characteristic red/orange glow
/// around bright areas in film photography, caused by light passing through
/// the emulsion, reflecting off the film base, and re-exposing the emulsion.
///
/// This creates that dreamy, vintage look where highlights bleed with a warm color cast.
class HalationFilter: CIFilter {

    // MARK: - Input Parameters

    @objc dynamic var inputImage: CIImage?

    /// Threshold for what counts as a highlight (0.0 - 1.0). Default: 0.7
    @objc dynamic var inputHighlightThreshold: CGFloat = 0.7

    /// Size of the halation glow (blur radius). Default: 25.0
    @objc dynamic var inputRadius: CGFloat = 25.0

    /// Intensity of the halation effect (0.0 - 1.0). Default: 0.5
    @objc dynamic var inputIntensity: CGFloat = 0.5

    /// Red component of halation color (0.0 - 1.0). Default: 1.0
    @objc dynamic var inputRed: CGFloat = 1.0

    /// Green component of halation color (0.0 - 1.0). Default: 0.3
    @objc dynamic var inputGreen: CGFloat = 0.3

    /// Blue component of halation color (0.0 - 1.0). Default: 0.2
    @objc dynamic var inputBlue: CGFloat = 0.2

    // MARK: - Filter Output

    override var outputImage: CIImage? {
        guard let input = inputImage else { return nil }

        // Step 1: Extract highlights using luminance threshold
        guard let highlights = extractHighlights(from: input) else { return input }

        // Step 2: Blur the highlights to create the glow
        guard let blurredHighlights = blurImage(highlights, radius: inputRadius) else { return input }

        // Step 3: Tint the blurred highlights with halation color (red/orange)
        guard let tintedGlow = tintImage(blurredHighlights) else { return input }

        // Step 4: Blend the tinted glow back with the original using screen blend
        guard let blended = blendWithScreen(base: input, glow: tintedGlow) else { return input }

        return blended
    }

    // MARK: - Private Methods

    /// Extract bright areas from the image
    private func extractHighlights(from image: CIImage) -> CIImage? {
        // Use color matrix to extract luminance and threshold
        // First, convert to grayscale luminance
        guard let grayscaleFilter = CIFilter(name: "CIColorMatrix") else { return nil }

        // Luminance coefficients (Rec. 709)
        let luminanceR: CGFloat = 0.2126
        let luminanceG: CGFloat = 0.7152
        let luminanceB: CGFloat = 0.0722

        grayscaleFilter.setValue(image, forKey: kCIInputImageKey)
        grayscaleFilter.setValue(CIVector(x: luminanceR, y: luminanceR, z: luminanceR, w: 0), forKey: "inputRVector")
        grayscaleFilter.setValue(CIVector(x: luminanceG, y: luminanceG, z: luminanceG, w: 0), forKey: "inputGVector")
        grayscaleFilter.setValue(CIVector(x: luminanceB, y: luminanceB, z: luminanceB, w: 0), forKey: "inputBVector")
        grayscaleFilter.setValue(CIVector(x: 0, y: 0, z: 0, w: 1), forKey: "inputAVector")
        grayscaleFilter.setValue(CIVector(x: 0, y: 0, z: 0, w: 0), forKey: "inputBiasVector")

        guard let luminance = grayscaleFilter.outputImage else { return nil }

        // Apply a curves-like adjustment to isolate highlights
        // Using color polynomial to create a soft threshold
        guard let thresholdFilter = CIFilter(name: "CIColorPolynomial") else { return nil }

        // Polynomial coefficients to create highlight isolation
        // This creates a soft threshold that ramps up for bright values
        let threshold = inputHighlightThreshold
        let a0 = -threshold * threshold * threshold  // Offset to shift threshold point
        let a1: CGFloat = 3.0  // Steepness
        let a2: CGFloat = -3.0
        let a3: CGFloat = 1.0

        thresholdFilter.setValue(luminance, forKey: kCIInputImageKey)
        thresholdFilter.setValue(CIVector(x: a0, y: a1, z: a2, w: a3), forKey: "inputRedCoefficients")
        thresholdFilter.setValue(CIVector(x: a0, y: a1, z: a2, w: a3), forKey: "inputGreenCoefficients")
        thresholdFilter.setValue(CIVector(x: a0, y: a1, z: a2, w: a3), forKey: "inputBlueCoefficients")
        thresholdFilter.setValue(CIVector(x: 0, y: 1, z: 0, w: 0), forKey: "inputAlphaCoefficients")

        guard let thresholded = thresholdFilter.outputImage else { return nil }

        // Multiply with original to get colored highlights
        guard let multiplyFilter = CIFilter(name: "CIMultiplyCompositing") else { return nil }
        multiplyFilter.setValue(image, forKey: kCIInputImageKey)
        multiplyFilter.setValue(thresholded, forKey: kCIInputBackgroundImageKey)

        return multiplyFilter.outputImage?.cropped(to: image.extent)
    }

    /// Blur an image with the specified radius
    private func blurImage(_ image: CIImage, radius: CGFloat) -> CIImage? {
        guard let blurFilter = CIFilter(name: "CIGaussianBlur") else { return nil }
        blurFilter.setValue(image, forKey: kCIInputImageKey)
        blurFilter.setValue(radius, forKey: kCIInputRadiusKey)
        return blurFilter.outputImage?.cropped(to: image.extent)
    }

    /// Tint the image with the halation color
    private func tintImage(_ image: CIImage) -> CIImage? {
        guard let colorMatrix = CIFilter(name: "CIColorMatrix") else { return nil }

        // Multiply RGB channels by halation color
        colorMatrix.setValue(image, forKey: kCIInputImageKey)
        colorMatrix.setValue(CIVector(x: inputRed, y: 0, z: 0, w: 0), forKey: "inputRVector")
        colorMatrix.setValue(CIVector(x: 0, y: inputGreen, z: 0, w: 0), forKey: "inputGVector")
        colorMatrix.setValue(CIVector(x: 0, y: 0, z: inputBlue, w: 0), forKey: "inputBVector")
        colorMatrix.setValue(CIVector(x: 0, y: 0, z: 0, w: 1), forKey: "inputAVector")
        colorMatrix.setValue(CIVector(x: 0, y: 0, z: 0, w: 0), forKey: "inputBiasVector")

        return colorMatrix.outputImage
    }

    /// Blend the glow with the original using screen mode
    private func blendWithScreen(base: CIImage, glow: CIImage) -> CIImage? {
        // First, adjust glow intensity
        guard let intensityFilter = CIFilter(name: "CIColorMatrix") else { return nil }
        intensityFilter.setValue(glow, forKey: kCIInputImageKey)
        let intensity = inputIntensity
        intensityFilter.setValue(CIVector(x: intensity, y: 0, z: 0, w: 0), forKey: "inputRVector")
        intensityFilter.setValue(CIVector(x: 0, y: intensity, z: 0, w: 0), forKey: "inputGVector")
        intensityFilter.setValue(CIVector(x: 0, y: 0, z: intensity, w: 0), forKey: "inputBVector")
        intensityFilter.setValue(CIVector(x: 0, y: 0, z: 0, w: 1), forKey: "inputAVector")
        intensityFilter.setValue(CIVector(x: 0, y: 0, z: 0, w: 0), forKey: "inputBiasVector")

        guard let adjustedGlow = intensityFilter.outputImage else { return nil }

        // Screen blend: result = 1 - (1 - base) * (1 - glow)
        // This brightens the image where the glow is present
        guard let screenFilter = CIFilter(name: "CIScreenBlendMode") else { return nil }
        screenFilter.setValue(adjustedGlow, forKey: kCIInputImageKey)
        screenFilter.setValue(base, forKey: kCIInputBackgroundImageKey)

        return screenFilter.outputImage?.cropped(to: base.extent)
    }

    // MARK: - Filter Attributes

    override var attributes: [String: Any] {
        return [
            kCIAttributeFilterDisplayName: "Halation",
            kCIAttributeFilterCategories: [kCICategoryStylize, kCICategoryVideo, kCICategoryStillImage],
            "inputHighlightThreshold": [
                kCIAttributeDefault: 0.7,
                kCIAttributeMin: 0.3,
                kCIAttributeMax: 0.95,
                kCIAttributeType: kCIAttributeTypeScalar
            ],
            "inputRadius": [
                kCIAttributeDefault: 25.0,
                kCIAttributeMin: 5.0,
                kCIAttributeMax: 100.0,
                kCIAttributeType: kCIAttributeTypeScalar
            ],
            "inputIntensity": [
                kCIAttributeDefault: 0.5,
                kCIAttributeMin: 0.0,
                kCIAttributeMax: 1.0,
                kCIAttributeType: kCIAttributeTypeScalar
            ],
            "inputRed": [
                kCIAttributeDefault: 1.0,
                kCIAttributeMin: 0.0,
                kCIAttributeMax: 1.0,
                kCIAttributeType: kCIAttributeTypeScalar
            ],
            "inputGreen": [
                kCIAttributeDefault: 0.3,
                kCIAttributeMin: 0.0,
                kCIAttributeMax: 1.0,
                kCIAttributeType: kCIAttributeTypeScalar
            ],
            "inputBlue": [
                kCIAttributeDefault: 0.2,
                kCIAttributeMin: 0.0,
                kCIAttributeMax: 1.0,
                kCIAttributeType: kCIAttributeTypeScalar
            ]
        ]
    }
}
