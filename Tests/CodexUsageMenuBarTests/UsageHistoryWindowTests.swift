import CoreGraphics
import SQLite3
import XCTest

extension UsageHistoryStoreTests {
    func testHistoryWindowFrameClampsOffscreenSavedFrame() async {
        let visibleFrame = CGRect(x: 0, y: 0, width: 1000, height: 700)
        let restoredFrame = CGRect(x: -320, y: -80, width: 880, height: 640)

        let frame = UsageHistoryWindowFrame.clampedFrame(
            restoredFrame,
            minimumSize: CGSize(width: 700, height: 520),
            visibleFrame: visibleFrame
        )

        XCTAssertEqual(frame, CGRect(x: 0, y: 0, width: 880, height: 640))
    }

    func testHistoryWindowFrameFitsVisibleScreenBeforeMinimumSize() async {
        let visibleFrame = CGRect(x: 100, y: 50, width: 640, height: 480)
        let restoredFrame = CGRect(x: 80, y: 20, width: 500, height: 300)

        let frame = UsageHistoryWindowFrame.clampedFrame(
            restoredFrame,
            minimumSize: CGSize(width: 700, height: 520),
            visibleFrame: visibleFrame
        )

        XCTAssertEqual(frame, visibleFrame)
    }

    func testTokenDashboardWindowFrameClampsLikeHistoryWindow() async {
        let visibleFrame = CGRect(x: 100, y: 50, width: 900, height: 620)
        let restoredFrame = CGRect(x: 20, y: -40, width: 1040, height: 700)

        let frame = TokenDashboardWindowFrame.clampedFrame(
            restoredFrame,
            minimumSize: CGSize(width: 780, height: 560),
            visibleFrame: visibleFrame
        )

        XCTAssertEqual(frame, visibleFrame)
    }
}
