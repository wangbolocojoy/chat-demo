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

extension SmokeTests {
    /// 全双工语音：点输入框的语音通话入口，确认通话界面出现
    func testVoiceCallOverlay() {
        let app = XCUIApplication(bundleIdentifier: "com.aicd.deepseekchat")
        app.launch()
        sleep(4)

        let entry = app.buttons["语音通话"]
        if entry.waitForExistence(timeout: 5) {
            entry.tap()
        } else {
            // 兜底：点输入框左下区域附近的入口
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.55, dy: 0.843)).tap()
        }

        // 留时间给外部截图 + 观察音频通道是否建立
        sleep(14)
        XCTAssertTrue(app.buttons["结束通话"].exists || app.buttons["Close voice call"].exists)
    }
}

extension SmokeTests {
    /// 打开语音通话后保持倾听，外部播放一段人声验证 VAD / ASR 链路
    func testVoiceCallCapture() {
        let app = XCUIApplication(bundleIdentifier: "com.aicd.deepseekchat")
        app.launch()
        sleep(4)
        let entry = app.buttons["语音通话"]
        if entry.waitForExistence(timeout: 5) {
            entry.tap()
        }
        sleep(30)
    }
}
