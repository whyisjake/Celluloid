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
        #expect(allFilters.count == 12)
        #expect(allFilters.contains(.none))
        #expect(allFilters.contains(.blackMist))
        #expect(allFilters.contains(.gateWeave))
        #expect(allFilters.contains(.halation))
        #expect(allFilters.contains(.noir))
    }

    @Test func filterTypeNoneHasNoCIFilter() {
        #expect(CameraManager.FilterType.none.ciFilterName == nil)
    }

    @Test func filterTypeBlackMistHasNoCIFilter() {
        // Black Mist is handled specially, not via ciFilterName
        #expect(CameraManager.FilterType.blackMist.ciFilterName == nil)
    }

    @Test func filterTypeHalationHasNoCIFilter() {
        // Halation is handled specially, not via ciFilterName
        #expect(CameraManager.FilterType.halation.ciFilterName == nil)
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
        #expect(manager.zoomLevel == 1.0)
        #expect(manager.cropOffsetX == 0.0)
        #expect(manager.cropOffsetY == 0.0)
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
    
    // MARK: - Zoom and Crop Tests
    
    @Test @MainActor func zoomLevelDefaultsToOne() async {
        let manager = CameraManager()
        try? await Task.sleep(nanoseconds: 100_000_000)
        #expect(manager.zoomLevel == 1.0)
    }
    
    @Test @MainActor func zoomLevelCanBeSet() async {
        let manager = CameraManager()
        try? await Task.sleep(nanoseconds: 100_000_000)
        
        manager.zoomLevel = 2.0
        #expect(manager.zoomLevel == 2.0)
        
        manager.zoomLevel = 4.0
        #expect(manager.zoomLevel == 4.0)
    }
    
    @Test @MainActor func cropOffsetsDefaultToZero() async {
        let manager = CameraManager()
        try? await Task.sleep(nanoseconds: 100_000_000)
        #expect(manager.cropOffsetX == 0.0)
        #expect(manager.cropOffsetY == 0.0)
    }
    
    @Test @MainActor func cropOffsetsCanBeSet() async {
        let manager = CameraManager()
        try? await Task.sleep(nanoseconds: 100_000_000)
        
        manager.zoomLevel = 2.0  // Enable zoom first
        manager.cropOffsetX = 0.5
        manager.cropOffsetY = -0.3
        
        #expect(manager.cropOffsetX == 0.5)
        #expect(manager.cropOffsetY == -0.3)
    }
    
    @Test @MainActor func cropOffsetsClampedWhenZoomChanges() async {
        let manager = CameraManager()
        try? await Task.sleep(nanoseconds: 100_000_000)
        
        // Set high zoom with offsets
        manager.zoomLevel = 4.0
        manager.cropOffsetX = 0.5
        manager.cropOffsetY = 0.5
        
        // Reduce zoom - offsets should be clamped
        manager.zoomLevel = 2.0
        
        let maxOffset = (2.0 - 1.0) / 2.0  // 0.5
        #expect(manager.cropOffsetX <= maxOffset)
        #expect(manager.cropOffsetY <= maxOffset)
    }
    
    @Test @MainActor func resetAdjustmentsResetsZoomAndCrop() async {
        let manager = CameraManager()
        try? await Task.sleep(nanoseconds: 100_000_000)
        
        // Set zoom and crop
        manager.zoomLevel = 2.5
        manager.cropOffsetX = 0.4
        manager.cropOffsetY = -0.2
        
        // Reset
        manager.resetAdjustments()
        
        // Verify reset
        #expect(manager.zoomLevel == 1.0)
        #expect(manager.cropOffsetX == 0.0)
        #expect(manager.cropOffsetY == 0.0)
    }
}
