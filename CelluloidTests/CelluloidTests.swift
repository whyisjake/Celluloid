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
}
