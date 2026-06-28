//
//  FullScreenToolbarAutoHide.swift
//  caddie
//
//  Created by Jeff Roberts on 6/28/26.
//

import AppKit
import SwiftUI

/// Makes the window's title bar + toolbar auto-hide in full screen and reveal on
/// hover (instead of staying pinned as a translucent strip over the map). Works by
/// becoming the window delegate just long enough to return `.autoHideToolbar` from
/// `willUseFullScreenPresentationOptions`, forwarding every other delegate call back
/// to SwiftUI's original delegate.
struct FullScreenToolbarAutoHide: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { [weak view] in
            guard let window = view?.window else { return }
            context.coordinator.attach(to: window)
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator: NSObject, NSWindowDelegate {
        private weak var window: NSWindow?
        private weak var previousDelegate: NSWindowDelegate?

        func attach(to window: NSWindow) {
            guard self.window !== window else { return }
            self.window = window
            previousDelegate = window.delegate
            window.delegate = self
        }

        func window(
            _ window: NSWindow,
            willUseFullScreenPresentationOptions proposedOptions: NSApplication.PresentationOptions = []
        ) -> NSApplication.PresentationOptions {
            var options = proposedOptions
            options.insert(.fullScreen)
            options.insert(.autoHideMenuBar)
            options.insert(.autoHideToolbar)
            return options
        }

        // Forward every other NSWindowDelegate message to SwiftUI's original delegate.
        override func responds(to aSelector: Selector!) -> Bool {
            if super.responds(to: aSelector) { return true }
            return previousDelegate?.responds(to: aSelector) ?? false
        }

        override func forwardingTarget(for aSelector: Selector!) -> Any? {
            if previousDelegate?.responds(to: aSelector) == true {
                return previousDelegate
            }
            return super.forwardingTarget(for: aSelector)
        }
    }
}
