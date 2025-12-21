//
//  SkinSmoothFilter.swift
//  Celluloid
//
//  Custom CIFilter using Metal kernel for skin smoothing effect
//

import CoreImage

/// A custom CIFilter that applies skin smoothing using a Metal kernel.
///
/// The effect detects skin tones using YCbCr color space and applies
/// selective smoothing while preserving details in non-skin areas.
///
/// When the Metal kernel is available, this filter uses GPU-accelerated processing.
/// Falls back to CIFilter chain if the kernel cannot be loaded.
class SkinSmoothFilter: CIFilter {

    // MARK: - Input Parameters

    @objc dynamic var inputImage: CIImage?

    /// Strength of the smoothing effect (0.0 - 1.0). Default: 0.5
    @objc dynamic var inputStrength: CGFloat = 0.5

    /// Blur radius for the smoothing. Default: 3.0
    @objc dynamic var inputBlurRadius: CGFloat = 3.0

    /// How strictly to detect skin tones (0.0 = smooth everything, 1.0 = only skin). Default: 0.95
    @objc dynamic var inputSkinDetectStrength: CGFloat = 0.95

    /// How much high-frequency detail to preserve (0.0 - 1.0). Default: 0.6
    @objc dynamic var inputDetailPreserve: CGFloat = 0.6

    // MARK: - Metal Kernel

    /// Compiled Metal blend kernel (lazy initialization)
    private static var blendKernel: CIBlendKernel? = {
        guard let url = Bundle.main.url(forResource: "default", withExtension: "metallib"),
              let data = try? Data(contentsOf: url) else {
            print("SkinSmoothFilter: Could not load default.metallib")
            return nil
        }

        do {
            let kernel = try CIBlendKernel(functionName: "skinSmoothBlend", fromMetalLibraryData: data)
            print("SkinSmoothFilter: Metal kernel loaded successfully")
            return kernel
        } catch {
            print("SkinSmoothFilter: Failed to create kernel: \(error)")
            return nil
        }
    }()

    // MARK: - Filter Output

    override var outputImage: CIImage? {
        guard let input = inputImage else { return nil }

        // Step 1: Create blurred version using CIGaussianBlur
        guard let blurFilter = CIFilter(name: "CIGaussianBlur") else { return input }
        blurFilter.setValue(input, forKey: kCIInputImageKey)
        blurFilter.setValue(inputBlurRadius, forKey: kCIInputRadiusKey)
        guard let blurred = blurFilter.outputImage?.cropped(to: input.extent) else { return input }

        // Step 2: Apply the Metal blend kernel if available
        if let kernel = SkinSmoothFilter.blendKernel {
            if let result = kernel.apply(extent: input.extent,
                                         arguments: [input, blurred,
                                                    Float(inputStrength),
                                                    Float(inputSkinDetectStrength),
                                                    Float(inputDetailPreserve)]) {
                return result
            }
        }

        // Fallback: Use simple blur blend if Metal kernel not available
        return applyFallbackFilterChain(input: input, blurred: blurred)
    }

    // MARK: - Fallback Implementation

    /// Fallback implementation using standard CIFilters (less selective, but works without Metal)
    private func applyFallbackFilterChain(input: CIImage, blurred: CIImage) -> CIImage? {
        // Simple blend between original and blurred based on strength
        // Note: This fallback doesn't have skin detection - it smooths everything
        guard let blendFilter = CIFilter(name: "CISourceOverCompositing") else { return input }

        // Create a semi-transparent version of the blurred image
        let alpha = inputStrength
        guard let colorMatrix = CIFilter(name: "CIColorMatrix") else { return input }
        colorMatrix.setValue(blurred, forKey: kCIInputImageKey)
        colorMatrix.setValue(CIVector(x: 1, y: 0, z: 0, w: 0), forKey: "inputRVector")
        colorMatrix.setValue(CIVector(x: 0, y: 1, z: 0, w: 0), forKey: "inputGVector")
        colorMatrix.setValue(CIVector(x: 0, y: 0, z: 1, w: 0), forKey: "inputBVector")
        colorMatrix.setValue(CIVector(x: 0, y: 0, z: 0, w: alpha), forKey: "inputAVector")
        guard let adjustedBlur = colorMatrix.outputImage else { return input }

        blendFilter.setValue(adjustedBlur, forKey: kCIInputImageKey)
        blendFilter.setValue(input, forKey: kCIInputBackgroundImageKey)

        return blendFilter.outputImage?.cropped(to: input.extent)
    }

    // MARK: - Filter Attributes

    override var attributes: [String: Any] {
        return [
            kCIAttributeFilterDisplayName: "Skin Smooth",
            kCIAttributeFilterCategories: [kCICategoryStylize, kCICategoryVideo, kCICategoryStillImage],
            "inputStrength": [
                kCIAttributeDefault: 0.5,
                kCIAttributeMin: 0.0,
                kCIAttributeMax: 1.0,
                kCIAttributeType: kCIAttributeTypeScalar
            ],
            "inputBlurRadius": [
                kCIAttributeDefault: 8.0,
                kCIAttributeMin: 1.0,
                kCIAttributeMax: 30.0,
                kCIAttributeType: kCIAttributeTypeScalar
            ],
            "inputSkinDetectStrength": [
                kCIAttributeDefault: 0.7,
                kCIAttributeMin: 0.0,
                kCIAttributeMax: 1.0,
                kCIAttributeType: kCIAttributeTypeScalar
            ],
            "inputDetailPreserve": [
                kCIAttributeDefault: 0.3,
                kCIAttributeMin: 0.0,
                kCIAttributeMax: 1.0,
                kCIAttributeType: kCIAttributeTypeScalar
            ]
        ]
    }
}
