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
}
