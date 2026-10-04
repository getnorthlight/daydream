import AppKit
import SwiftUI

@MainActor @main struct ScrollIndicatorChecks {
    static func scrolls(_ view: NSView) -> [NSScrollView] {
        (view as? NSScrollView).map { [$0] } ?? view.subviews.flatMap(scrolls)
    }

    static func main() {
        NSApplication.shared.setActivationPolicy(.prohibited)
        var checks = 0
        for never in [false, true] {
            let content = ScrollView(showsIndicators: false) {
                VStack(spacing: 0) {
                    ForEach(0..<80) { number in
                        Text("Row \(number)").frame(maxWidth: .infinity).frame(height: 36)
                    }
                }
            }.scrollIndicators(never ? .never : .hidden)
            let host = NSHostingView(rootView: content)
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 360, height: 320),
                                  styleMask: [.titled, .closable], backing: .buffered, defer: false)
            window.contentView = host
            window.setContentSize(NSSize(width: 360, height: 320))
            func settle() {
                RunLoop.main.run(until: Date().addingTimeInterval(0.08))
                host.layoutSubtreeIfNeeded()
            }
            settle()
            guard let scroll = scrolls(host).first else { fatalError("Missing native scroll view") }
            print("Initial \(never ? "never" : "hidden"): style=\(scroll.scrollerStyle.rawValue) has=\(scroll.hasVerticalScroller) hidden=\(scroll.verticalScroller?.isHidden.description ?? "nil") clip=\(scroll.contentView.frame.width)")
            for style in [NSScroller.Style.legacy, .overlay] {
                scroll.scrollerStyle = style
                for index in 0..<24 {
                    window.setContentSize(NSSize(width: index.isMultiple(of: 2) ? 360 : 380, height: 320))
                    settle()
                    if never {
                        precondition(!scroll.hasVerticalScroller || scroll.verticalScroller?.isHidden != false,
                                     "Never must suppress vertical chrome in style \(style.rawValue)")
                        precondition(!scroll.hasHorizontalScroller || scroll.horizontalScroller?.isHidden != false,
                                     "Never must suppress horizontal chrome")
                        checks += 2
                    }
                }
                scroll.contentView.scroll(to: NSPoint(x: 0, y: 100))
                scroll.reflectScrolledClipView(scroll.contentView)
                precondition(scroll.contentView.bounds.minY > 0, "Scrolling must remain available")
                checks += 1
                print("\(never ? "never" : "hidden") style=\(style.rawValue) has=\(scroll.hasVerticalScroller) hidden=\(scroll.verticalScroller?.isHidden.description ?? "nil") clip=\(scroll.contentView.frame.width) origin=\(scroll.contentView.bounds.minY)")
            }
            window.contentView = nil
        }
        print("PASS \(checks) native scrollbar checks; no global preferences changed")
    }
}
