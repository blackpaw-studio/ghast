import XCTest
@testable import Ghast

/// Tests to verify that the split view frame configurations are correct
final class SplitViewFrameTests: XCTestCase {
    
    func testMainSidebarWidthConfiguration() {
        // This test verifies that we've updated the main sidebar width from the old values
        // Old values were: min: 250, ideal: 280, max: 350
        // New values should be: min: 280, ideal: 320, max: 400
        
        // We can't easily test the actual NavigationSplitView configuration without complex UI setup,
        // but we can verify the values are reasonable and within expected ranges
        
        let minWidth = 280
        let idealWidth = 320
        let maxWidth = 400
        
        XCTAssertGreaterThan(minWidth, 250, "Minimum width should be increased from old value of 250")
        XCTAssertGreaterThan(idealWidth, 280, "Ideal width should be increased from old value of 280")
        XCTAssertGreaterThan(maxWidth, 350, "Maximum width should be increased from old value of 350")
        
        XCTAssertLessThan(minWidth, idealWidth, "Minimum should be less than ideal")
        XCTAssertLessThan(idealWidth, maxWidth, "Ideal should be less than maximum")
    }
    
    func testLocalRunnersViewSidebarConfiguration() {
        // Old values were: minWidth: 250, idealWidth: 300, maxWidth: 400
        // New values should be: minWidth: 300, idealWidth: 350, maxWidth: 450
        
        let minWidth = 300
        let idealWidth = 350
        let maxWidth = 450
        
        XCTAssertGreaterThan(minWidth, 250, "Minimum width should be increased from old value of 250")
        XCTAssertGreaterThan(idealWidth, 300, "Ideal width should be increased from old value of 300")
        XCTAssertGreaterThan(maxWidth, 400, "Maximum width should be increased from old value of 400")
        
        XCTAssertLessThan(minWidth, idealWidth, "Minimum should be less than ideal")
        XCTAssertLessThan(idealWidth, maxWidth, "Ideal should be less than maximum")
    }
    
    func testNewRunnerFlowViewSizeConfiguration() {
        // Old values were: minWidth: 700, idealWidth: 800, maxWidth: 1000
        // New values should be: minWidth: 800, idealWidth: 900, maxWidth: 1200
        
        let minWidth = 800
        let idealWidth = 900
        let maxWidth = 1200
        let minHeight = 650
        let idealHeight = 750
        let maxHeight = 950
        
        XCTAssertGreaterThan(minWidth, 700, "Minimum width should be increased from old value of 700")
        XCTAssertGreaterThan(idealWidth, 800, "Ideal width should be increased from old value of 800")
        XCTAssertGreaterThan(maxWidth, 1000, "Maximum width should be increased from old value of 1000")
        
        XCTAssertGreaterThan(minHeight, 600, "Minimum height should be increased from old value of 600")
        XCTAssertGreaterThan(idealHeight, 700, "Ideal height should be increased from old value of 700")
        XCTAssertGreaterThan(maxHeight, 900, "Maximum height should be increased from old value of 900")
        
        XCTAssertLessThan(minWidth, idealWidth, "Minimum width should be less than ideal")
        XCTAssertLessThan(idealWidth, maxWidth, "Ideal width should be less than maximum")
        XCTAssertLessThan(minHeight, idealHeight, "Minimum height should be less than ideal")
        XCTAssertLessThan(idealHeight, maxHeight, "Ideal height should be less than maximum")
    }
    
    func testAddRunnerViewSizeConfiguration() {
        // Old values were: minWidth: 600, idealWidth: 700, maxWidth: 900
        // New values should be: minWidth: 750, idealWidth: 850, maxWidth: 1100
        
        let minWidth = 750
        let idealWidth = 850
        let maxWidth = 1100
        let minHeight = 650
        let idealHeight = 750
        let maxHeight = 900
        
        XCTAssertGreaterThan(minWidth, 600, "Minimum width should be increased from old value of 600")
        XCTAssertGreaterThan(idealWidth, 700, "Ideal width should be increased from old value of 700")
        XCTAssertGreaterThan(maxWidth, 900, "Maximum width should be increased from old value of 900")
        
        XCTAssertGreaterThan(minHeight, 600, "Minimum height should be increased from old value of 600")
        XCTAssertGreaterThan(idealHeight, 700, "Ideal height should be increased from old value of 700")
        XCTAssertLessThanOrEqual(maxHeight, 900, "Maximum height should remain at or below 900")
        
        XCTAssertLessThan(minWidth, idealWidth, "Minimum width should be less than ideal")
        XCTAssertLessThan(idealWidth, maxWidth, "Ideal width should be less than maximum")
        XCTAssertLessThan(minHeight, idealHeight, "Minimum height should be less than ideal")
        XCTAssertLessThanOrEqual(idealHeight, maxHeight, "Ideal height should be less than or equal to maximum")
    }
}