import SwiftUI
import AppKit
import MemoryUI

@MainActor final class ControlState:ObservableObject {
    @Published var enabled=true
    @Published var count=0
}
struct ControlFixture:View {
    @ObservedObject var state:ControlState
    @FocusState private var focused:Bool
    var body:some View {
        VStack {
            Button("Reference action") {state.count+=1}
                .buttonStyle(ReferenceButtonStyle()).disabled(!state.enabled)
                .keyboardShortcut("r",modifiers:.command).focused($focused)
            TextField("Focus target",text:.constant("Synthetic")).accessibilityLabel("Focus target")
            Menu {Button("No operation") {}} label:{ReferenceMenuLabel("Options")}
                .menuStyle(.borderlessButton).menuIndicator(.hidden)
        }.padding().onAppear {focused=true}
    }
}
@main struct ReferenceControlsCheck {
    @MainActor static func main() {
        _=NSApplication.shared;NSApp.setActivationPolicy(.accessory)
        let state=ControlState()
        let window=NSWindow(contentRect:NSRect(x:0,y:0,width:400,height:240),styleMask:[.titled],backing:.buffered,defer:false)
        window.contentView=NSHostingView(rootView:ControlFixture(state:state));window.makeKeyAndOrderFront(nil)
        defer {window.orderOut(nil)}
        RunLoop.main.run(until:Date().addingTimeInterval(0.3))
        func press() {
            let event=NSEvent.keyEvent(with:.keyDown,location:.zero,modifierFlags:.command,timestamp:0,windowNumber:window.windowNumber,context:nil,characters:"r",charactersIgnoringModifiers:"r",isARepeat:false,keyCode:15)!
            _=window.performKeyEquivalent(with:event)
            RunLoop.main.run(until:Date().addingTimeInterval(0.1))
        }
        press();precondition(state.count==1,"Enabled custom button must retain native key equivalent")
        precondition(window.firstResponder != nil,"Native responder chain exists")
        state.enabled=false;RunLoop.main.run(until:Date().addingTimeInterval(0.1))
        press();precondition(state.count==1,"Disabled custom button must not act")
        state.enabled=true;RunLoop.main.run(until:Date().addingTimeInterval(0.1))
        press();precondition(state.count==2,"Re-enabled custom button works")
        print("PASS native enabled/disabled/re-enabled keyboard activation and responder-chain checks. Synthetic controls only.")
    }
}
