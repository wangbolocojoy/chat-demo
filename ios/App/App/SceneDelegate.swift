import UIKit
import Capacitor
import CapApp_SPM
import WebKit

class SceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?

    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options connectionOptions: UIScene.ConnectionOptions) {
        guard let windowScene = scene as? UIWindowScene else { return }

        window = UIWindow(windowScene: windowScene)
        window?.rootViewController = CAPBridgeViewController()
        window?.makeKeyAndVisible()

        configureWebView()
        registerVoiceDuplex()

        SceneDelegateProxy.shared.scene(scene, willConnectTo: session, options: connectionOptions)
    }

    /// 调整 Capacitor 默认 WebView 的行为，让页面更像原生 App。
    private func configureWebView() {
        guard let bridge = window?.rootViewController as? CAPBridgeViewController else { return }
        bridge.loadViewIfNeeded()
        guard let scrollView = bridge.webView?.scrollView else { return }

        // 页面自己管理安全区，不要再让 WebView 调整内边距
        scrollView.contentInsetAdjustmentBehavior = .never

        if #available(iOS 26.0, *) {
            // iOS 26 起滚动视图会在状态栏和底部叠一层渐变“边缘效果”，
            // 深色主题下会在屏幕顶部留下一条浅色带，这里全部关掉
            scrollView.topEdgeEffect.isHidden = true
            scrollView.bottomEdgeEffect.isHidden = true
            scrollView.leftEdgeEffect.isHidden = true
            scrollView.rightEdgeEffect.isHidden = true
        }
    }

    /// 全双工语音用的原生音频通道（Capacitor 只会自动注册 node_modules 里的插件）
    private func registerVoiceDuplex() {
        guard
            let bridge = (window?.rootViewController as? CAPBridgeViewController)?.bridge
                as? CapacitorBridge
        else {
            return
        }
        bridge.registerPluginInstance(VoiceDuplexPlugin())
    }

    func scene(_ scene: UIScene, openURLContexts URLContexts: Set<UIOpenURLContext>) {
        SceneDelegateProxy.shared.scene(scene, openURLContexts: URLContexts)
    }

    func scene(_ scene: UIScene, continue userActivity: NSUserActivity) {
        SceneDelegateProxy.shared.scene(scene, continue: userActivity)
    }
}
