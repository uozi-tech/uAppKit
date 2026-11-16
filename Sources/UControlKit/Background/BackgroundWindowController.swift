// macOS 专用：整份文件用平台条件包住，理由同 `UAppKitBridge`。
#if os(macOS)

import AppKit
import Foundation
import SwiftUI

/// 把 GUI 叫出来时，该让哪个窗口到最前。
///
/// 输入必须是 `NSApp.orderedWindows`：`NSApp.windows` 不保证顺序，实测欢迎窗常排第一。两个列表
/// 都留着已关闭和已隐藏的窗口，所以还要筛。有可见窗口就用最靠前的，全部最小化时才还原一个。
@MainActor
public enum ReopenWindowPicker {
    public static func pick(frontToBack windows: [NSWindow]) -> NSWindow? {
        let candidates = windows.filter { !($0 is NSPanel) }
        return candidates.first(where: \.isVisible) ?? candidates.first(where: \.isMiniaturized)
    }

    /// 后台唤起时窗口在视图出现之前就被藏起来了（`hideAll` 早于 SwiftUI 第一次布局），开窗入口因此一直没装上。
    /// 这时没有入口可调，只能把 SwiftUI 已经建好、藏着的窗口拿出来：它的视图一出现就会装上入口。
    public static func pickHidden(_ windows: [NSWindow]) -> NSWindow? {
        windows.first { !($0 is NSPanel) && $0.styleMask.contains(.titled) }
    }
}

/// 转入后台时藏起来的窗口。`orderOut` 后的窗口和已关闭的窗口外观上分不开，只能自己记。
@MainActor
public final class BackgroundedWindows: NSObject {
    private var windows: [NSWindow] = []

    override public init() {
        super.init()
        NotificationCenter.default.addObserver(
            self, selector: #selector(windowWillClose), name: NSWindow.willCloseNotification, object: nil)
    }

    /// 记下当前可见的窗口（从前到后），再把全部窗口 `orderOut`。
    public func hideAll() {
        windows = NSApp.orderedWindows.filter(\.isVisible) + windows
        NSApp.windows.forEach { $0.orderOut(nil) }
    }

    /// 按原来的前后顺序放回。
    public func restore() {
        windows.reversed().forEach { $0.orderFront(nil) }
        windows = []
    }

    /// 后台期间关掉的窗口（会话结束之类）不能再放出来。
    @objc private func windowWillClose(_ notification: Notification) {
        windows.removeAll { $0 === notification.object as AnyObject? }
    }
}

/// 后台模式的窗口生命周期：后台启动时藏起窗口、转入后台、被重新打开时把界面叫回来。
///
/// 由 app 的 `NSApplicationDelegate` 转调：
///
/// ```swift
/// func applicationWillFinishLaunching(_:)  { BackgroundWindowController.shared.applicationWillFinishLaunching() }
/// func applicationDidFinishLaunching(_:)   { BackgroundWindowController.shared.applicationDidFinishLaunching() }
/// func applicationShouldHandleReopen(_:hasVisibleWindows:) -> Bool {
///     BackgroundWindowController.shared.applicationShouldHandleReopen()
/// }
/// ```
///
/// 窗口恢复以 uTerm 的实现为准：记住藏起的窗口按原顺序放回；没有可放回的窗口时调 `openPrimaryWindow`；
/// 连它都没有（后台启动时 SwiftUI 没建初始窗口、入口没装上）就把 SwiftUI 藏着的窗口拿出来，
/// 一扇都没有再请系统发一次 reopen，让 SwiftUI 走默认流程开窗。
@MainActor
public final class BackgroundWindowController {
    public static let shared = BackgroundWindowController()

    public enum GUIPresentation: Equatable, Sendable {
        case shown
        /// 没有窗口可露出、也没有开窗入口。
        case nothingToShow
    }

    /// 露出界面之前调（uTerm 用它恢复后台期间没建窗口的终端会话）。
    public var onWillShowGUI: (@MainActor () -> Void)?
    /// 没有可放回的窗口时，用它开主窗口（通常是 SwiftUI 的 `openWindow`，由视图出现时装上）。
    public var openPrimaryWindow: (@MainActor () -> Void)?
    /// 请系统重新打开失败时的日志出口。
    public var log: (@MainActor (String) -> Void)?

    /// 后台唤起的实例已经被要求露出过界面。之后装好开窗入口时，app 可据此接回内容。
    public private(set) var hasShownGUI = false

    private let startsHidden: Bool
    private let backgroundedWindows = BackgroundedWindows()

    public init(startsHidden: Bool = BackgroundLaunchMode.shouldStartHidden) {
        self.startsHidden = startsHidden
    }

    /// 后台启动：不进 Dock、不抢焦点。
    public func applicationWillFinishLaunching() {
        if startsHidden {
            NSApp.setActivationPolicy(.accessory)
        }
    }

    /// 后台启动：把 SwiftUI 已经建好的窗口藏起来（记住，用户打开 app 时放回）。
    public func applicationDidFinishLaunching() {
        guard startsHidden else { return }
        backgroundedWindows.hideAll()
    }

    /// `applicationShouldHandleReopen` 的返回值。
    ///
    /// `showGUI` 处理完就返回 false：返回 true 时 AppKit 还会走默认流程，可能再还原一个窗口或多开一个。
    /// 例外是一扇窗口都拿不出来（后台隐藏启动时 SwiftUI 不建初始窗口，开窗入口也就没装上）：这时让 AppKit
    /// 走默认流程，SwiftUI 会开主窗口，它的视图出现时装上入口。
    public func applicationShouldHandleReopen() -> Bool {
        precondition(BackgroundLaunchMode.reopenPresentation == .foreground)
        return showGUI(handlingReopen: true) == .nothingToShow
    }

    /// 露出界面：回到常规 app（进 Dock）、激活、放回藏起的窗口，把最前面的一扇设为 key。
    @discardableResult
    public func showGUI(handlingReopen: Bool = false) -> GUIPresentation {
        hasShownGUI = true
        onWillShowGUI?()
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        backgroundedWindows.restore()
        if let window = ReopenWindowPicker.pick(frontToBack: NSApp.orderedWindows) {
            window.makeKeyAndOrderFront(nil)
        } else if let openPrimaryWindow {
            openPrimaryWindow()
        } else if let hidden = ReopenWindowPicker.pickHidden(NSApp.windows) {
            hidden.makeKeyAndOrderFront(nil)
        } else {
            // 一扇窗口都没有：不在 reopen 里的话，请 LaunchServices 给自己发一次 reopen，走上面那条默认流程。
            if !handlingReopen { requestReopen() }
            return .nothingToShow
        }
        return .shown
    }

    /// 转入后台：藏起全部窗口（记住它们），退出 Dock。本机服务照常运行。
    public func moveToBackground() {
        backgroundedWindows.hideAll()
        NSApp.setActivationPolicy(.accessory)
    }

    public func quitCompletely() {
        NSApp.terminate(nil)
    }

    /// 让系统按「用户又打开了 app」给这个实例发一次 reopen（不会另起一个实例）。
    private func requestReopen() {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        configuration.createsNewApplicationInstance = false
        let log = self.log
        NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: configuration) { _, error in
            guard let error else { return }
            let message = "请系统重新打开 app 失败：\(error.localizedDescription)"
            Task { @MainActor in log?(message) }
        }
    }
}

/// 把 app 菜单里的「退出」换成两项：转入后台、完全退出（⌘Q）。
///
/// 菜单标题由调用方传入：包内字符串收不进 app 的 String Catalog。
@MainActor
public struct BackgroundLifecycleCommands: Commands {
    private let moveToBackgroundTitle: String
    private let quitTitle: String
    private let controller: BackgroundWindowController

    /// - Parameters:
    ///   - appName: 拼进默认的「完全退出 <appName>」。
    ///   - moveToBackgroundTitle: 默认「转入后台」。
    ///   - quitTitle: 默认「完全退出 <appName>」。
    public init(
        appName: String,
        moveToBackgroundTitle: String = "转入后台",
        quitTitle: String? = nil,
        controller: BackgroundWindowController = .shared
    ) {
        self.moveToBackgroundTitle = moveToBackgroundTitle
        self.quitTitle = quitTitle ?? "完全退出 \(appName)"
        self.controller = controller
    }

    public var body: some Commands {
        CommandGroup(replacing: .appTermination) {
            Button(moveToBackgroundTitle) { controller.moveToBackground() }
            Divider()
            Button(quitTitle) { controller.quitCompletely() }
                .keyboardShortcut("q", modifiers: .command)
        }
    }
}

#endif
