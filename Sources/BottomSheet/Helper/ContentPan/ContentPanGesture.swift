//
//  ContentPanGesture.swift
//

#if !os(macOS)
import SwiftUI
import UIKit

/// Drags the BottomSheet by its main content, even when the content is (or contains) a ScrollView or List.
///
/// A SwiftUI gesture on the main content never sees touches that land on a UIKit backed ScrollView or List, so this
/// installs a UIKit pan recognizer above the content instead. For each vertical swipe it decides whether the scroll
/// view under the finger may scroll: only when the sheet is fully open and the scroll view's content is taller than
/// it. Every other swipe moves the sheet, and the scroll view is held still. A downward swipe on a scroll view that is
/// already scrolled to the top also moves the sheet, so a fully open sheet can be pulled down from its content.
internal struct ContentPanGesture: UIViewRepresentable {
    /// Whether the sheet is at its highest position, the only one where the content can scroll
    let isFullyOpen: Bool
    /// The vertical translation of the pan, in points
    let onChanged: (CGFloat) -> Void
    let onEnded: (CGFloat) -> Void

    func makeUIView(context: Context) -> ContentPanView {
        ContentPanView()
    }

    func updateUIView(_ view: ContentPanView, context: Context) {
        view.isFullyOpen = self.isFullyOpen
        view.onChanged = self.onChanged
        view.onEnded = self.onEnded
    }

    static func dismantleUIView(_ view: ContentPanView, coordinator: ()) {
        view.uninstall()
    }
}

/// Sits behind the main content to mark out its area. The recognizer is attached to the root view, which the content's
/// UIKit views are inside of, and only takes touches that start within this view's bounds.
internal final class ContentPanView: UIView, UIGestureRecognizerDelegate {
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

    private var mode: Mode = .sheet
    private weak var scrollView: UIScrollView?
    /// Where the scroll view is held while the sheet moves
    private var heldContentOffset: CGPoint = .zero
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
    }

    func uninstall() {
        self.panGesture.view?.removeGestureRecognizer(self.panGesture)
    }

    // MARK: UIGestureRecognizerDelegate

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        self.window != nil && self.bounds.contains(touch.location(in: self))
    }

    override func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard gestureRecognizer === self.panGesture else {
            return super.gestureRecognizerShouldBegin(gestureRecognizer)
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

    // MARK: Pan

    @objc private func handlePan(_ gesture: UIPanGestureRecognizer) {
        // In window coordinates, this view moves with the sheet
        let translation = gesture.translation(in: nil).y

        switch gesture.state {
        case .began:
            self.scrollView = self.verticalScrollView(at: gesture.location(in: gesture.view), in: gesture.view)
            self.lastTranslation = translation
            if let scrollView = self.scrollView, self.isFullyOpen, self.overflows(scrollView),
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
                self.holdScrollView()
                self.onChanged(translation - self.sheetStartTranslation)
            }
        case .ended, .cancelled, .failed:
            if self.mode == .sheet {
                self.holdScrollView()
                self.onEnded(translation - self.sheetStartTranslation)
            }
            self.mode = .sheet
            self.scrollView = nil
        default:
            break
        }
    }

    private func startMovingSheet(at translation: CGFloat) {
        self.mode = .sheet
        self.sheetStartTranslation = translation
        guard let scrollView = self.scrollView else {
            return
        }
        // Toggling the scroll view's pan cancels it, so it doesn't scroll or decelerate when the finger lifts
        scrollView.panGestureRecognizer.isEnabled = false
        scrollView.panGestureRecognizer.isEnabled = true
        var offset = scrollView.contentOffset
        offset.y = max(offset.y, -scrollView.adjustedContentInset.top)
        self.heldContentOffset = offset
        scrollView.setContentOffset(offset, animated: false)
    }

    private func holdScrollView() {
        guard let scrollView = self.scrollView, scrollView.contentOffset != self.heldContentOffset else {
            return
        }
        scrollView.setContentOffset(self.heldContentOffset, animated: false)
    }

    private func isAtTop(_ scrollView: UIScrollView) -> Bool {
        scrollView.contentOffset.y <= -scrollView.adjustedContentInset.top + 0.5
    }

    private func overflows(_ scrollView: UIScrollView) -> Bool {
        scrollView.contentSize.height + scrollView.adjustedContentInset.top + scrollView.adjustedContentInset.bottom >
            scrollView.bounds.height + 1
    }

    /// The innermost scroll view under the point that isn't a horizontal one, the one a vertical swipe would scroll
    private func verticalScrollView(at point: CGPoint, in host: UIView?) -> UIScrollView? {
        var view = host?.hitTest(point, with: nil)
        while let current = view, current !== host {
            if let scrollView = current as? UIScrollView, scrollView.isScrollEnabled,
               !(scrollView.contentSize.width > scrollView.bounds.width + 1 && !self.overflows(scrollView)) {
                return scrollView
            }
            view = current.superview
        }
        return nil
    }
}
#endif
