import AppKit
import SwiftUI

enum MouseButton { case left, right, other }

struct InputHandler {
    var mouseDown: (CGPoint, MouseButton, NSEvent.ModifierFlags, Int) -> Void = { _, _, _, _ in }
    var mouseDragged: (CGPoint, MouseButton, NSEvent.ModifierFlags) -> Void = { _, _, _ in }
    var mouseUp: (CGPoint, MouseButton) -> Void = { _, _ in }
    var scroll: (CGFloat, Bool, NSEvent.ModifierFlags, CGPoint) -> Void = { _, _, _, _ in }
    var magnify: (CGFloat, CGPoint) -> Void = { _, _ in }
    var hover: (CGPoint?) -> Void = { _ in }
    var key: (NSEvent) -> Bool = { _ in false }
}

/// Transparent AppKit view that captures the mouse, trackpad and keyboard events SwiftUI doesn't expose.
struct InputCatcher: NSViewRepresentable {
    var handler: InputHandler
    var cursor: NSCursor
    var takesFocus = false

    func makeNSView(context: Context) -> InputNSView {
        let view = InputNSView()
        view.handler = handler
        view.cursor = cursor
        view.takesFocusOnAppear = takesFocus
        return view
    }

    func updateNSView(_ view: InputNSView, context: Context) {
        view.handler = handler
        if view.cursor != cursor {
            view.cursor = cursor
            view.window?.invalidateCursorRects(for: view)
        }
    }
}

final class InputNSView: NSView {
    var handler = InputHandler()
    var cursor: NSCursor = .arrow
    var takesFocusOnAppear = false

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if takesFocusOnAppear {
            DispatchQueue.main.async { [weak self] in
                guard let self, let window = self.window else { return }
                if !(window.firstResponder is NSTextView) { window.makeFirstResponder(self) }
            }
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero,
                                       options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                                       owner: self))
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: cursor)
    }

    private func point(_ e: NSEvent) -> CGPoint { convert(e.locationInWindow, from: nil) }

    override func mouseDown(with e: NSEvent) {
        window?.makeFirstResponder(self)
        handler.mouseDown(point(e), .left, e.modifierFlags, e.clickCount)
    }
    override func mouseDragged(with e: NSEvent) { handler.mouseDragged(point(e), .left, e.modifierFlags) }
    override func mouseUp(with e: NSEvent) { handler.mouseUp(point(e), .left) }

    override func rightMouseDown(with e: NSEvent) {
        window?.makeFirstResponder(self)
        handler.mouseDown(point(e), .right, e.modifierFlags, e.clickCount)
    }
    override func rightMouseDragged(with e: NSEvent) { handler.mouseDragged(point(e), .right, e.modifierFlags) }
    override func rightMouseUp(with e: NSEvent) { handler.mouseUp(point(e), .right) }

    override func otherMouseDown(with e: NSEvent) { handler.mouseDown(point(e), .other, e.modifierFlags, e.clickCount) }
    override func otherMouseDragged(with e: NSEvent) { handler.mouseDragged(point(e), .other, e.modifierFlags) }
    override func otherMouseUp(with e: NSEvent) { handler.mouseUp(point(e), .other) }

    override func scrollWheel(with e: NSEvent) {
        handler.scroll(e.scrollingDeltaY, e.hasPreciseScrollingDeltas, e.modifierFlags, point(e))
    }

    override func magnify(with e: NSEvent) { handler.magnify(e.magnification, point(e)) }
    override func mouseMoved(with e: NSEvent) { handler.hover(point(e)) }
    override func mouseExited(with e: NSEvent) { handler.hover(nil) }

    override func keyDown(with e: NSEvent) {
        if !handler.key(e) { super.keyDown(with: e) }
    }
}
