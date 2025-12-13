//
//  CelluloidTests.swift
//  CelluloidTests
//
//  Created by Jake Spurlock on 12/11/25.
//

import Testing
import Foundation
import CoreImage
@testable import Celluloid

struct CelluloidTests {

    // MARK: - FilterType Tests

    @Test func filterTypeHasCorrectCases() {
        let allFilters = CameraManager.FilterType.allCases
        #expect(allFilters.count == 10)
        #expect(allFilters.contains(.none))
        #expect(allFilters.contains(.blackMist))
        #expect(allFilters.contains(.noir))
    }

    @Test func filterTypeNoneHasNoCIFilter() {
        #expect(CameraManager.FilterType.none.ciFilterName == nil)
    }

    @Test func filterTypeBlackMistHasNoCIFilter() {
        // Black Mist is handled specially, not via ciFilterName
        #expect(CameraManager.FilterType.blackMist.ciFilterName == nil)
    }

    @Test func filterTypeNoirHasCorrectCIFilter() {
        #expect(CameraManager.FilterType.noir.ciFilterName == "CIPhotoEffectNoir")
    }

    @Test func filterTypeChromeHasCorrectCIFilter() {
        #expect(CameraManager.FilterType.chrome.ciFilterName == "CIPhotoEffectChrome")
    }

    @Test func filterTypeIdentifiableById() {
        let filter = CameraManager.FilterType.blackMist
        #expect(filter.id == "Black Mist")
        #expect(filter.rawValue == "Black Mist")
    }

    // MARK: - Reset Adjustments Test

    @Test @MainActor func resetAdjustmentsResetsToDefaults() async {
        let manager = CameraManager()

        // Give time for async init
        try? await Task.sleep(nanoseconds: 100_000_000)

        // Change values
        manager.brightness = 0.5
        manager.contrast = 2.0
        manager.saturation = 1.5
        manager.exposure = 1.0
        manager.temperature = 8000
        manager.sharpness = 1.0
        manager.selectedFilter = .noir

        // Reset
        manager.resetAdjustments()

        // Verify defaults
        #expect(manager.brightness == 0.0)
        #expect(manager.contrast == 1.0)
        #expect(manager.saturation == 1.0)
        #expect(manager.exposure == 0.0)
        #expect(manager.temperature == 6500)
        #expect(manager.sharpness == 0.0)
        #expect(manager.selectedFilter == .none)
    }

    // MARK: - Shared Constants Tests

    @Test func sharedConstantsHaveCorrectValues() {
        #expect(CelluloidShared.width == 1280)
        #expect(CelluloidShared.height == 720)
    }

    // MARK: - All Filter CIFilter Name Tests

    @Test func filterTypeFadeHasCorrectCIFilter() {
        #expect(CameraManager.FilterType.fade.ciFilterName == "CIPhotoEffectFade")
    }

    @Test func filterTypeInstantHasCorrectCIFilter() {
        #expect(CameraManager.FilterType.instant.ciFilterName == "CIPhotoEffectInstant")
    }

    @Test func filterTypeMonoHasCorrectCIFilter() {
        #expect(CameraManager.FilterType.mono.ciFilterName == "CIPhotoEffectMono")
    }

    @Test func filterTypeProcessHasCorrectCIFilter() {
        #expect(CameraManager.FilterType.process.ciFilterName == "CIPhotoEffectProcess")
    }

    @Test func filterTypeTonalHasCorrectCIFilter() {
        #expect(CameraManager.FilterType.tonal.ciFilterName == "CIPhotoEffectTonal")
    }

    @Test func filterTypeTransferHasCorrectCIFilter() {
        #expect(CameraManager.FilterType.transfer.ciFilterName == "CIPhotoEffectTransfer")
    }

    // MARK: - Filter Type Edge Cases

    @Test func allFiltersHaveUniqueIds() {
        let allFilters = CameraManager.FilterType.allCases
        let uniqueIds = Set(allFilters.map { $0.id })
        #expect(uniqueIds.count == allFilters.count)
    }

    @Test func allFiltersHaveNonEmptyRawValues() {
        for filter in CameraManager.FilterType.allCases {
            #expect(!filter.rawValue.isEmpty)
        }
    }

    @Test func ciFiltersExistInCoreImage() {
        // Verify all CIFilter names map to real Core Image filters
        for filter in CameraManager.FilterType.allCases {
            if let filterName = filter.ciFilterName {
                let ciFilter = CIFilter(name: filterName)
                #expect(ciFilter != nil, "CIFilter '\(filterName)' should exist")
            }
        }
    }

    // MARK: - Settings Boundary Tests

    @Test @MainActor func settingsBrightnessRange() async {
        let manager = CameraManager()
        try? await Task.sleep(nanoseconds: 100_000_000)

        // Test boundary values
        manager.brightness = -1.0
        #expect(manager.brightness == -1.0)

        manager.brightness = 1.0
        #expect(manager.brightness == 1.0)

        manager.brightness = 0.0
        #expect(manager.brightness == 0.0)
    }

    @Test @MainActor func settingsContrastRange() async {
        let manager = CameraManager()
        try? await Task.sleep(nanoseconds: 100_000_000)

        // Test boundary values
        manager.contrast = 0.25
        #expect(manager.contrast == 0.25)

        manager.contrast = 4.0
        #expect(manager.contrast == 4.0)
    }

    @Test @MainActor func settingsTemperatureRange() async {
        let manager = CameraManager()
        try? await Task.sleep(nanoseconds: 100_000_000)

        // Test boundary values
        manager.temperature = 2000
        #expect(manager.temperature == 2000)

        manager.temperature = 10000
        #expect(manager.temperature == 10000)
    }

    // MARK: - HALD Constants Tests

    @Test func haldConstantsAreCorrect() {
        #expect(HALDConstants.imageSize == 512)
        #expect(HALDConstants.cubeDimension == 64)
        #expect(HALDConstants.gridSize == 8)
        // Verify the relationship: gridSize * cubeDimension = imageSize
        #expect(HALDConstants.gridSize * HALDConstants.cubeDimension == HALDConstants.imageSize)
    }

    // MARK: - CubeLUTParser Tests

    @Test func cubeLUTParserParsesValidFile() {
        // Create a minimal valid 2x2x2 cube file
        let cubeContent = """
        # Comment line
        TITLE "Test LUT"
        DOMAIN_MIN 0.0 0.0 0.0
        DOMAIN_MAX 1.0 1.0 1.0
        LUT_3D_SIZE 2

        0.0 0.0 0.0
        1.0 0.0 0.0
        0.0 1.0 0.0
        1.0 1.0 0.0
        0.0 0.0 1.0
        1.0 0.0 1.0
        0.0 1.0 1.0
        1.0 1.0 1.0
        """

        let result = CubeLUTParser.parse(cubeContent)

        switch result {
        case .success(let parseResult):
            #expect(parseResult.dimension == 2)
            // 2x2x2 cube = 8 entries, each with 4 floats (RGBA), each float is 4 bytes
            #expect(parseResult.data.count == 8 * 4 * MemoryLayout<Float>.size)
        case .failure(let error):
            Issue.record("Expected success but got error: \(error)")
        }
    }

    @Test func cubeLUTParserHandlesEmptyFile() {
        let result = CubeLUTParser.parse("")
        switch result {
        case .failure(.emptyFile):
            break // Expected
        default:
            Issue.record("Expected emptyFile error")
        }
    }

    @Test func cubeLUTParserHandlesOnlyComments() {
        let cubeContent = """
        # This is a comment
        # Another comment

        """
        let result = CubeLUTParser.parse(cubeContent)
        switch result {
        case .failure(.emptyFile):
            break // Expected
        default:
            Issue.record("Expected emptyFile error")
        }
    }

    @Test func cubeLUTParserHandlesMissingLUTSize() {
        let cubeContent = """
        TITLE "No size"
        0.0 0.0 0.0
        1.0 1.0 1.0
        """
        let result = CubeLUTParser.parse(cubeContent)
        switch result {
        case .failure(.missingLUTSize):
            break // Expected
        default:
            Issue.record("Expected missingLUTSize error")
        }
    }

    @Test func cubeLUTParserHandlesInvalidLUTSize() {
        let cubeContent = """
        LUT_3D_SIZE invalid
        0.0 0.0 0.0
        """
        let result = CubeLUTParser.parse(cubeContent)
        switch result {
        case .failure(.invalidLUTSize):
            break // Expected
        default:
            Issue.record("Expected invalidLUTSize error")
        }
    }

    @Test func cubeLUTParserHandlesZeroLUTSize() {
        let cubeContent = """
        LUT_3D_SIZE 0
        """
        let result = CubeLUTParser.parse(cubeContent)
        switch result {
        case .failure(.invalidLUTSize):
            break // Expected
        default:
            Issue.record("Expected invalidLUTSize error")
        }
    }

    @Test func cubeLUTParserHandlesNegativeLUTSize() {
        let cubeContent = """
        LUT_3D_SIZE -5
        """
        let result = CubeLUTParser.parse(cubeContent)
        switch result {
        case .failure(.invalidLUTSize):
            break // Expected
        default:
            Issue.record("Expected invalidLUTSize error")
        }
    }

    @Test func cubeLUTParserHandlesIncorrectValueCount() {
        // 2x2x2 = 8 entries needed, but only providing 4
        let cubeContent = """
        LUT_3D_SIZE 2
        0.0 0.0 0.0
        1.0 0.0 0.0
        0.0 1.0 0.0
        1.0 1.0 0.0
        """
        let result = CubeLUTParser.parse(cubeContent)

        switch result {
        case .failure(.incorrectValueCount(let expected, let actual)):
            #expect(expected == 32) // 2*2*2*4 = 32 floats (RGBA)
            #expect(actual == 16)   // 4 entries * 4 floats = 16
        default:
            Issue.record("Expected incorrectValueCount error")
        }
    }

    @Test func cubeLUTParserSkipsMetadataLines() {
        let cubeContent = """
        TITLE "Test with metadata"
        DOMAIN_MIN 0.0 0.0 0.0
        DOMAIN_MAX 1.0 1.0 1.0
        # Comment in the middle
        LUT_3D_SIZE 2
        0.0 0.0 0.0
        1.0 0.0 0.0
        0.0 1.0 0.0
        1.0 1.0 0.0
        0.0 0.0 1.0
        1.0 0.0 1.0
        0.0 1.0 1.0
        1.0 1.0 1.0
        """

        let result = CubeLUTParser.parse(cubeContent)
        switch result {
        case .success(let parseResult):
            #expect(parseResult.dimension == 2)
        case .failure:
            Issue.record("Expected success parsing file with metadata")
        }
    }

    @Test func cubeLUTParserHandlesExtraWhitespace() {
        let cubeContent = """
        LUT_3D_SIZE 2
          0.0   0.0   0.0
        1.0 0.0 0.0
        0.0 1.0 0.0
        1.0 1.0 0.0
        0.0 0.0 1.0
        1.0 0.0 1.0
        0.0 1.0 1.0
        1.0 1.0 1.0
        """

        let result = CubeLUTParser.parse(cubeContent)
        switch result {
        case .success(let parseResult):
            #expect(parseResult.dimension == 2)
        case .failure:
            Issue.record("Expected success with extra whitespace")
        }
    }

    @Test func cubeLUTParserPreservesRGBValues() {
        let tolerance: Float = 0.001
        let cubeContent = """
        LUT_3D_SIZE 2
        0.1 0.2 0.3
        0.4 0.5 0.6
        0.7 0.8 0.9
        0.11 0.22 0.33
        0.44 0.55 0.66
        0.77 0.88 0.99
        0.111 0.222 0.333
        0.444 0.555 0.666
        """

        let result = CubeLUTParser.parse(cubeContent)
        switch result {
        case .success(let parseResult):
            // Verify first RGB value is preserved
            parseResult.data.withUnsafeBytes { buffer in
                let floatStride = MemoryLayout<Float>.stride
                let r = buffer.load(fromByteOffset: 0, as: Float.self)
                let g = buffer.load(fromByteOffset: floatStride, as: Float.self)
                let b = buffer.load(fromByteOffset: floatStride * 2, as: Float.self)
                let a = buffer.load(fromByteOffset: floatStride * 3, as: Float.self)
                #expect(abs(r - 0.1) < tolerance) // R
                #expect(abs(g - 0.2) < tolerance) // G
                #expect(abs(b - 0.3) < tolerance) // B
                #expect(a == 1.0) // Alpha should be 1.0
            }
        case .failure:
            Issue.record("Expected success")
        }
    }

    // MARK: - HALDCLUTParser Tests

    @Test func haldCLUTParserValidatesDimensions() {
        #expect(HALDCLUTParser.validateDimensions(width: 512, height: 512) == true)
        #expect(HALDCLUTParser.validateDimensions(width: 256, height: 256) == false)
        #expect(HALDCLUTParser.validateDimensions(width: 512, height: 256) == false)
        #expect(HALDCLUTParser.validateDimensions(width: 1024, height: 1024) == false)
        #expect(HALDCLUTParser.validateDimensions(width: 0, height: 0) == false)
    }

    @Test func haldCLUTParserRejectsInvalidSize() {
        let pixelData = [UInt8](repeating: 0, count: 256 * 256 * 4)
        let result = HALDCLUTParser.convertPixelData(pixelData, width: 256, height: 256)

        switch result {
        case .failure(.invalidImageSize(let width, let height)):
            #expect(width == 256)
            #expect(height == 256)
        default:
            Issue.record("Expected invalidImageSize error")
        }
    }

    @Test func haldCLUTParserConvertsValidImage() {
        // Create a 512x512 pixel buffer (all black)
        let pixelData = [UInt8](repeating: 0, count: 512 * 512 * 4)
        let result = HALDCLUTParser.convertPixelData(pixelData, width: 512, height: 512)

        switch result {
        case .success(let parseResult):
            #expect(parseResult.dimension == HALDConstants.cubeDimension)
            // 64x64x64 cube * 4 floats * 4 bytes = 4,194,304 bytes
            let expectedSize = 64 * 64 * 64 * 4 * MemoryLayout<Float>.size
            #expect(parseResult.data.count == expectedSize)
        case .failure:
            Issue.record("Expected success converting valid image")
        }
    }

    @Test func haldCLUTParserNormalizesPixelValues() {
        // Create pixel data with known values at position (0,0)
        var pixelData = [UInt8](repeating: 0, count: 512 * 512 * 4)
        // Set first pixel to R=255, G=128, B=64, A=255
        pixelData[0] = 255  // R
        pixelData[1] = 128  // G
        pixelData[2] = 64   // B
        pixelData[3] = 255  // A

        let result = HALDCLUTParser.convertPixelData(pixelData, width: 512, height: 512)

        switch result {
        case .success(let parseResult):
            parseResult.data.withUnsafeBytes { buffer in
                let floatStride = MemoryLayout<Float>.stride
                let r = buffer.load(fromByteOffset: 0, as: Float.self)
                let g = buffer.load(fromByteOffset: floatStride, as: Float.self)
                let b = buffer.load(fromByteOffset: floatStride * 2, as: Float.self)
                let a = buffer.load(fromByteOffset: floatStride * 3, as: Float.self)
                // First cube entry (r=0, g=0, b=0) maps to pixel (0,0)
                #expect(abs(r - 1.0) < 0.01)    // R: 255/255 = 1.0
                #expect(abs(g - 0.502) < 0.01) // G: 128/255 ≈ 0.502
                #expect(abs(b - 0.251) < 0.01) // B: 64/255 ≈ 0.251
                #expect(a == 1.0)              // Alpha always 1.0
            }
        case .failure:
            Issue.record("Expected success")
        }
    }

    @Test func haldCLUTParserOutputDimensionMatchesConstant() {
        let pixelData = [UInt8](repeating: 128, count: 512 * 512 * 4)
        let result = HALDCLUTParser.convertPixelData(pixelData, width: 512, height: 512)

        switch result {
        case .success(let parseResult):
            #expect(parseResult.dimension == 64)
            #expect(parseResult.dimension == HALDConstants.cubeDimension)
        case .failure:
            Issue.record("Expected success")
        }
    }

    // MARK: - BlackMistFilter Tests

    @Test func blackMistFilterReturnsNilForNilInput() {
        let filter = BlackMistFilter()
        filter.inputImage = nil
        #expect(filter.outputImage == nil)
    }

    @Test func blackMistFilterReturnsOutputForValidInput() {
        let filter = BlackMistFilter()
        // Create a simple 100x100 red test image
        let color = CIColor(red: 1.0, green: 0.0, blue: 0.0)
        guard let colorGen = CIFilter(name: "CIConstantColorGenerator") else {
            Issue.record("Failed to create color generator")
            return
        }
        colorGen.setValue(color, forKey: kCIInputColorKey)
        guard let testImage = colorGen.outputImage?.cropped(to: CGRect(x: 0, y: 0, width: 100, height: 100)) else {
            Issue.record("Failed to create test image")
            return
        }

        filter.inputImage = testImage
        let output = filter.outputImage

        #expect(output != nil, "Filter should produce output for valid input")
        #expect(output?.extent == testImage.extent, "Output extent should match input extent")
    }

    @Test func blackMistFilterHasCorrectDefaultValues() {
        let filter = BlackMistFilter()

        #expect(filter.inputStrength == 0.5)
        #expect(filter.inputBlurRadius == 12.0)
        #expect(filter.inputExposureBoost == 0.30)
        #expect(filter.inputContrast == 0.95)
        #expect(filter.inputBrightness == 0.02)
        #expect(filter.inputSaturation == 1.02)
    }

    @Test func blackMistFilterAcceptsCustomParameters() {
        let filter = BlackMistFilter()

        // Set custom values
        filter.inputStrength = 0.8
        filter.inputBlurRadius = 20.0
        filter.inputExposureBoost = 0.5
        filter.inputContrast = 1.1
        filter.inputBrightness = 0.1
        filter.inputSaturation = 1.5

        // Verify they were set
        #expect(filter.inputStrength == 0.8)
        #expect(filter.inputBlurRadius == 20.0)
        #expect(filter.inputExposureBoost == 0.5)
        #expect(filter.inputContrast == 1.1)
        #expect(filter.inputBrightness == 0.1)
        #expect(filter.inputSaturation == 1.5)
    }

    @Test func blackMistFilterProducesOutputWithCustomParameters() {
        let filter = BlackMistFilter()

        // Create test image
        let color = CIColor(red: 0.5, green: 0.5, blue: 0.5)
        guard let colorGen = CIFilter(name: "CIConstantColorGenerator") else {
            Issue.record("Failed to create test image")
            return
        }
        colorGen.setValue(color, forKey: kCIInputColorKey)
        guard let testImage = colorGen.outputImage?.cropped(to: CGRect(x: 0, y: 0, width: 50, height: 50)) else {
            Issue.record("Failed to create test image")
            return
        }

        // Apply with custom parameters
        filter.inputImage = testImage
        filter.inputStrength = 1.0
        filter.inputBlurRadius = 5.0

        let output = filter.outputImage
        #expect(output != nil, "Filter should produce output with custom parameters")
    }

    @Test func blackMistFilterAttributesContainsRequiredKeys() {
        let filter = BlackMistFilter()
        let attrs = filter.attributes

        // Check display name
        #expect(attrs[kCIAttributeFilterDisplayName] as? String == "Black Mist")

        // Check categories
        if let categories = attrs[kCIAttributeFilterCategories] as? [String] {
            #expect(categories.contains(kCICategoryStylize))
            #expect(categories.contains(kCICategoryVideo))
            #expect(categories.contains(kCICategoryStillImage))
        } else {
            Issue.record("Filter should have categories")
        }

        // Check parameter attributes exist
        #expect(attrs["inputStrength"] != nil)
        #expect(attrs["inputBlurRadius"] != nil)
        #expect(attrs["inputExposureBoost"] != nil)
        #expect(attrs["inputContrast"] != nil)
        #expect(attrs["inputBrightness"] != nil)
        #expect(attrs["inputSaturation"] != nil)
    }

    @Test func blackMistFilterAttributesHaveCorrectRanges() {
        let filter = BlackMistFilter()
        let attrs = filter.attributes

        // Check inputStrength range
        if let strengthAttrs = attrs["inputStrength"] as? [String: Any] {
            #expect(strengthAttrs[kCIAttributeDefault] as? Double == 0.5)
            #expect(strengthAttrs[kCIAttributeMin] as? Double == 0.0)
            #expect(strengthAttrs[kCIAttributeMax] as? Double == 1.0)
        } else {
            Issue.record("inputStrength should have attributes")
        }

        // Check inputBlurRadius range
        if let blurAttrs = attrs["inputBlurRadius"] as? [String: Any] {
            #expect(blurAttrs[kCIAttributeDefault] as? Double == 12.0)
            #expect(blurAttrs[kCIAttributeMin] as? Double == 0.0)
            #expect(blurAttrs[kCIAttributeMax] as? Double == 100.0)
        } else {
            Issue.record("inputBlurRadius should have attributes")
        }
    }

    @Test func blackMistFilterPreservesImageExtent() {
        let filter = BlackMistFilter()

        // Create test images of different sizes
        let sizes: [CGSize] = [
            CGSize(width: 100, height: 100),
            CGSize(width: 200, height: 150),
            CGSize(width: 1280, height: 720)
        ]

        for size in sizes {
            let color = CIColor(red: 0.3, green: 0.6, blue: 0.9)
            guard let colorGen = CIFilter(name: "CIConstantColorGenerator") else { continue }
            colorGen.setValue(color, forKey: kCIInputColorKey)
            guard let testImage = colorGen.outputImage?.cropped(to: CGRect(origin: .zero, size: size)) else { continue }

            filter.inputImage = testImage
            let output = filter.outputImage

            #expect(output?.extent.size == size, "Output size should match input size \(size)")
        }
    }

    @Test func blackMistFilterHandlesEdgeCaseParameters() {
        let filter = BlackMistFilter()

        // Create test image
        let color = CIColor(red: 1.0, green: 1.0, blue: 1.0)
        guard let colorGen = CIFilter(name: "CIConstantColorGenerator") else {
            Issue.record("Failed to create test image")
            return
        }
        colorGen.setValue(color, forKey: kCIInputColorKey)
        guard let testImage = colorGen.outputImage?.cropped(to: CGRect(x: 0, y: 0, width: 50, height: 50)) else {
            Issue.record("Failed to create test image")
            return
        }

        filter.inputImage = testImage

        // Test with minimum strength (should be nearly passthrough)
        filter.inputStrength = 0.0
        #expect(filter.outputImage != nil, "Should handle zero strength")

        // Test with maximum strength
        filter.inputStrength = 1.0
        #expect(filter.outputImage != nil, "Should handle max strength")

        // Test with zero blur radius
        filter.inputBlurRadius = 0.0
        #expect(filter.outputImage != nil, "Should handle zero blur radius")
    }
}
