//
//  ContentPanGesture.swift
//

#if !os(macOS)
import SwiftUI
import UIKit
import UIKit.UIGestureRecognizerSubclass

/// Drags the BottomSheet by its main content, even when the content is (or contains) a ScrollView or List.
///
/// A SwiftUI gesture on the main content never sees touches that land on a UIKit backed ScrollView or List, so this
/// installs a UIKit pan recognizer above the content instead. For each vertical swipe it decides whether the scroll
/// view under the finger may scroll: only when the sheet is fully open and the scroll view's content is taller than
/// it. Every other swipe moves the sheet, and the scroll view is held still. A downward swipe on a scroll view that is
/// already scrolled to the top also moves the sheet, so a fully open sheet can be pulled down from its content.
internal struct ContentPanGesture: UIViewRepresentable {
    /// Switching it off cancels a pan in progress
    let isEnabled: Bool
    /// Whether the sheet is at its highest position, the only one where the content can scroll
    let isFullyOpen: Bool
    /// The vertical translation of the pan, in points
    let onChanged: (CGFloat) -> Void
    let onEnded: (CGFloat) -> Void

    func makeUIView(context: Context) -> ContentPanView {
        ContentPanView()
    }

    func updateUIView(_ view: ContentPanView, context: Context) {
        view.isEnabled = self.isEnabled
        view.isFullyOpen = self.isFullyOpen
        view.onChanged = self.onChanged
        view.onEnded = self.onEnded
    }

    static func dismantleUIView(_ view: ContentPanView, coordinator: ()) {
        view.uninstall()
    }
}

/// Sits behind the main content to mark out its area. The recognizers are attached to the root view, which the
/// content's UIKit views are inside of, and only take touches that start within this view's bounds.
internal final class ContentPanView: UIView, UIGestureRecognizerDelegate {
    /// A touch held still this long is a long press (a context menu, or lifting an item to drag and drop it), so
    /// moving it afterwards doesn't move the sheet
    private static let longPressDuration: TimeInterval = 0.4

    var isEnabled = true {
        didSet {
            self.panGesture.isEnabled = self.isEnabled
            self.touchGesture.isEnabled = self.isEnabled
            if !self.isEnabled {
                // A touch in progress won't report lifting any more
                self.releaseScrollView()
            }
        }
    }
    var isFullyOpen = false
    var onChanged: (CGFloat) -> Void = { _ in }
    var onEnded: (CGFloat) -> Void = { _ in }

    private enum Mode {
        case sheet
        case scroll
    }

    private lazy var panGesture: UIPanGestureRecognizer = {
        let gesture = UIPanGestureRecognizer(target: self, action: #selector(self.handlePan(_:)))
        gesture.delegate = self
        return gesture
    }()

    /// Sees every touch on the content, including ones that never become a pan, to keep the scroll view under it
    /// from scrolling when it shouldn't
    private lazy var touchGesture: TouchGestureRecognizer = {
        let gesture = TouchGestureRecognizer()
        gesture.delegate = self
        gesture.onBegan = { [weak self] touch in self?.touchBegan(touch) }
        gesture.onEnded = { [weak self] in self?.releaseScrollView() }
        return gesture
    }()

    private var mode: Mode = .sheet
    /// The scroll view under the touch
    private weak var scrollView: UIScrollView?
    /// The scroll view whose pan is switched off for the current touch
    private weak var suppressedScrollView: UIScrollView?
    /// Whether the scroll view is held at the top of its content while the sheet moves
    private var isHoldingAtTop = false
    private var touchStart: TimeInterval = 0
    /// The pan translation when the sheet started moving, for a pan that scrolled first
    private var sheetStartTranslation: CGFloat = 0
    private var lastTranslation: CGFloat = 0

    override init(frame: CGRect) {
        super.init(frame: frame)
        // Only marks out the area, the content above it gets the touches
        self.isUserInteractionEnabled = false
        self.backgroundColor = .clear
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        self.uninstall()
        // The root view rather than the window, so views presented over it (sheets, alerts) don't move this sheet
        guard let host = self.window?.rootViewController?.view ?? self.window else {
            return
        }
        host.addGestureRecognizer(self.panGesture)
        host.addGestureRecognizer(self.touchGesture)
    }

    func uninstall() {
        self.releaseScrollView()
        self.panGesture.view?.removeGestureRecognizer(self.panGesture)
        self.touchGesture.view?.removeGestureRecognizer(self.touchGesture)
    }

    // MARK: UIGestureRecognizerDelegate

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        guard self.window != nil, self.bounds.contains(touch.location(in: self)) else {
            return false
        }
        // Content often runs on under a tab bar, which keeps its own touches
        var view = touch.view
        while let current = view {
            if current is UITabBar {
                return false
            }
            view = current.superview
        }
        return true
    }

    override func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard gestureRecognizer === self.panGesture else {
            return super.gestureRecognizerShouldBegin(gestureRecognizer)
        }
        if ProcessInfo.processInfo.systemUptime - self.touchStart >= Self.longPressDuration {
            return false
        }
        // Horizontal swipes are left to the content (swipe actions, horizontal scrolling, the back swipe)
        let velocity = self.panGesture.velocity(in: nil)
        return abs(velocity.y) > abs(velocity.x)
    }

    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
    ) -> Bool {
        true
    }

    // MARK: Touches

    private func touchBegan(_ touch: UITouch) {
        self.touchStart = touch.timestamp
        self.releaseScrollView()
        self.scrollView = self.verticalScrollView(above: touch.view)
        // Unless the sheet is fully open and the content taller than it, the content doesn't scroll at all, whether
        // or not the touch goes on to move the sheet
        if let scrollView = self.scrollView, !self.canScroll(scrollView) {
            self.suppress(scrollView)
        }
    }

    private func canScroll(_ scrollView: UIScrollView) -> Bool {
        self.isFullyOpen && self.overflows(scrollView)
    }

    /// Switches the scroll view's pan off for the rest of the touch, which also cancels a scroll in progress
    private func suppress(_ scrollView: UIScrollView) {
        guard self.suppressedScrollView !== scrollView else {
            return
        }
        self.releaseScrollView()
        scrollView.panGestureRecognizer.isEnabled = false
        self.suppressedScrollView = scrollView
    }

    private func releaseScrollView() {
        self.suppressedScrollView?.panGestureRecognizer.isEnabled = true
        self.suppressedScrollView = nil
    }

    // MARK: Pan

    @objc private func handlePan(_ gesture: UIPanGestureRecognizer) {
        // In window coordinates, this view moves with the sheet
        let translation = gesture.translation(in: nil).y

        switch gesture.state {
        case .began:
            self.lastTranslation = translation
            if let scrollView = self.scrollView, self.canScroll(scrollView),
               !(self.isAtTop(scrollView) && gesture.velocity(in: nil).y > 0) {
                self.mode = .scroll
            } else {
                self.startMovingSheet(at: translation)
            }
        case .changed:
            if self.mode == .scroll, let scrollView = self.scrollView,
               self.isAtTop(scrollView), translation > self.lastTranslation {
                // Pulled down past the top of the content
                self.startMovingSheet(at: translation)
            }
            self.lastTranslation = translation
            if self.mode == .sheet {
                self.holdAtTop()
                self.onChanged(translation - self.sheetStartTranslation)
            }
        case .ended, .cancelled, .failed:
            if self.mode == .sheet {
                self.holdAtTop()
                self.onEnded(translation - self.sheetStartTranslation)
            }
            self.mode = .sheet
            self.isHoldingAtTop = false
        default:
            break
        }
    }

    private func startMovingSheet(at translation: CGFloat) {
        self.mode = .sheet
        self.sheetStartTranslation = translation
        guard let scrollView = self.scrollView, self.suppressedScrollView !== scrollView else {
            // Already still, and left where it is
            return
        }
        // It was scrolling and is at its top: stop it there, so it doesn't bounce or decelerate
        self.suppress(scrollView)
        self.isHoldingAtTop = true
        self.holdAtTop()
    }

    private func holdAtTop() {
        guard self.isHoldingAtTop, let scrollView = self.scrollView else {
            return
        }
        var offset = scrollView.contentOffset
        offset.y = -scrollView.adjustedContentInset.top
        if scrollView.contentOffset != offset {
            scrollView.setContentOffset(offset, animated: false)
        }
    }

    private func isAtTop(_ scrollView: UIScrollView) -> Bool {
        scrollView.contentOffset.y <= -scrollView.adjustedContentInset.top + 0.5
    }

    private func overflows(_ scrollView: UIScrollView) -> Bool {
        scrollView.contentSize.height + scrollView.adjustedContentInset.top + scrollView.adjustedContentInset.bottom >
            scrollView.bounds.height + 1
    }

    /// The innermost scroll view at or above the view that isn't a horizontal one, the one a vertical swipe would
    /// scroll
    private func verticalScrollView(above view: UIView?) -> UIScrollView? {
        var view = view
        while let current = view {
            if let scrollView = current as? UIScrollView, scrollView.isScrollEnabled,
               !(scrollView.contentSize.width > scrollView.bounds.width + 1 && !self.overflows(scrollView)) {
                return scrollView
            }
            view = current.superview
        }
        return nil
    }
}

/// Reports a touch going down and every touch lifting, without ever recognizing or getting in the way of the touches
private final class TouchGestureRecognizer: UIGestureRecognizer {
    var onBegan: (UITouch) -> Void = { _ in }
    var onEnded: () -> Void = {}
    private var touchCount = 0

    override init(target: Any?, action: Selector?) {
        super.init(target: target, action: action)
        self.cancelsTouchesInView = false
        self.delaysTouchesEnded = false
    }

    convenience init() {
        self.init(target: nil, action: nil)
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        if self.touchCount == 0, let touch = touches.first {
            self.onBegan(touch)
        }
        self.touchCount += touches.count
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
        self.touchesLifted(touches)
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) {
        self.touchesLifted(touches)
    }

    private func touchesLifted(_ touches: Set<UITouch>) {
        self.touchCount -= touches.count
        if self.touchCount <= 0 {
            self.onEnded()
            self.state = .failed
        }
    }

    override func reset() {
        super.reset()
        self.touchCount = 0
    }
}
#endif
