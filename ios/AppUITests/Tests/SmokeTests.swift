import XCTest

/// 冒烟测试：验证键盘和语音输入的布局。
/// 单独跑：xcodebuild test -project ios/AppUITests/AppUITests.xcodeproj -scheme AppUITests \
///   -destination 'platform=iOS Simulator,id=<UDID>' -only-testing:AppUITests/SmokeTests/testKeyboardLayout
final class SmokeTests: XCTestCase {
    private func launchApp() -> XCUIApplication {
        let app = XCUIApplication(bundleIdentifier: "com.aicd.deepseekchat")
        app.launch()
        sleep(4)
        return app
    }

    func testKeyboardLayout() {
        let app = launchApp()

        // 找到输入框；找不到就点屏幕下方输入区的大致位置
        let composer = app.textViews.firstMatch
        if composer.waitForExistence(timeout: 5) {
            composer.tap()
        } else {
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.84)).tap()
        }

        sleep(3)
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5), "键盘没有弹出来")

        // 留时间给外部截图
        sleep(10)
    }

    func testVoiceInput() {
        let app = launchApp()

        // 输入区右侧的麦克风按钮
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.675, dy: 0.843)).tap()

        // 录音中：留时间给外部截图
        sleep(14)
    }
}
