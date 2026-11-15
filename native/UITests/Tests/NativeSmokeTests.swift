import XCTest

/// 原生客户端的冒烟测试：走本地 mock 服务，验证流式渲染。
/// 跑之前先起 mock：python3 native/dev/mock-server.py
final class NativeSmokeTests: XCTestCase {
    func testStreamingChatWithMockServer() {
        let app = XCUIApplication(bundleIdentifier: "com.aicd.deepseeknative")
        app.launchEnvironment["DEEPSEEK_BASE_URL"] = "http://127.0.0.1:8099"
        app.launchEnvironment["DEEPSEEK_API_KEY"] = "mock-key"
        app.launch()
        sleep(2)

        // iPhone 上 NavigationSplitView 会记住上次打开的会话，先回到侧边栏
        if !app.textFields["composer-input"].exists, app.buttons["BackButton"].exists {
            app.buttons["BackButton"].tap()
            sleep(1)
        }
        if !app.textFields["composer-input"].exists, app.buttons["new-session"].exists {
            app.buttons["new-session"].tap()
            sleep(1)
        }

        let input = app.textFields["composer-input"]
        XCTAssertTrue(input.waitForExistence(timeout: 6), "输入框没有出现")
        input.tap()
        input.typeText("你好")
        app.buttons["send-message"].tap()

        // 留下时间给外部截图，验证流式输出
        sleep(18)
    }

    func testVoiceCallOverlayOpens() {
        let app = XCUIApplication(bundleIdentifier: "com.aicd.deepseeknative")
        app.launchEnvironment["DEEPSEEK_BASE_URL"] = "http://127.0.0.1:8099"
        app.launchEnvironment["DEEPSEEK_API_KEY"] = "mock-key"
        app.launch()
        sleep(2)
        if !app.buttons["open-voice"].exists, app.buttons["BackButton"].exists {
            app.buttons["BackButton"].tap()
            sleep(1)
        }
        app.buttons["open-voice"].tap()
        sleep(3)
        XCTAssertTrue(app.buttons["end-voice"].exists, "语音界面没有打开")
        sleep(34)
    }
}

extension NativeSmokeTests {
    /// 语音通话开始后按 Home，灵动岛/锁屏应当出现 Live Activity
    func testVoiceLiveActivityInDynamicIsland() {
        let app = XCUIApplication(bundleIdentifier: "com.aicd.deepseeknative")
        app.launchEnvironment["DEEPSEEK_BASE_URL"] = "http://127.0.0.1:8099"
        app.launchEnvironment["DEEPSEEK_API_KEY"] = "mock-key"
        app.launch()
        sleep(2)
        if !app.buttons["open-voice"].exists, app.buttons["BackButton"].exists {
            app.buttons["BackButton"].tap()
            sleep(1)
        }
        app.buttons["open-voice"].tap()
        sleep(4)
        XCUIDevice.shared.press(.home)
        sleep(12)
    }
}

extension NativeSmokeTests {
    /// 深链：deepseeknative://ask?text=...（分享扩展走这条路径）
    func testDeepLinkAsk() {
        let app = XCUIApplication(bundleIdentifier: "com.aicd.deepseeknative")
        app.launchEnvironment["DEEPSEEK_BASE_URL"] = "http://127.0.0.1:8099"
        app.launchEnvironment["DEEPSEEK_API_KEY"] = "mock-key"
        app.launch()
        sleep(26)
    }
}
