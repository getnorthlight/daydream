import SwiftUI
import AppKit

/// The label and chevron share one native button, including keyboard activation.
public struct SettingsDisclosureStyle: DisclosureGroupStyle {
    @Environment(\.accessibilityReduceMotion) private var reducedMotion
    public init() {}
    public func makeBody(configuration: Configuration) -> some View {
        VStack(alignment:.leading,spacing:8) {
            Button {
                withAnimation(reducedMotion ? nil : .easeInOut(duration:0.15)) {configuration.isExpanded.toggle()}
            } label: {
                HStack(spacing:8) {
                    configuration.label.font(DaydreamType.body)
                    Spacer(minLength:8)
                    Image(systemName:configuration.isExpanded ? "chevron.down":"chevron.right")
                        .font(.system(size:11,weight:.medium)).foregroundStyle(.secondary)
                }.frame(maxWidth:.infinity,minHeight:36,alignment:.leading).contentShape(Rectangle())
            }.buttonStyle(.plain).accessibilityValue(configuration.isExpanded ? "Expanded":"Collapsed")
            if configuration.isExpanded {
                VStack(alignment:.leading,spacing:10) {configuration.content}
                    .font(DaydreamType.body).multilineTextAlignment(.leading)
                    .frame(maxWidth:.infinity,alignment:.leading).padding(.bottom,12)
            }
        }.frame(maxWidth:.infinity,alignment:.leading)
    }
}

/// AppKit preserves the requested font on macOS segmented controls.
public struct SettingsSegmentedPicker: NSViewRepresentable {
    @Environment(\.isEnabled) private var enabled
    @Binding var selection:String
    let labels:[String]
    public init(selection:Binding<String>,labels:[String]) {_selection=selection;self.labels=labels}
    public func makeCoordinator()->Coordinator {Coordinator(self)}
    public func makeNSView(context:Context)->NSSegmentedControl {
        let control=NSSegmentedControl(labels:labels,trackingMode:.selectOne,target:context.coordinator,action:#selector(Coordinator.changed(_:)))
        control.segmentDistribution = .fillEqually
        control.segmentStyle = .rounded
        control.setAccessibilityLabel("Summarizer provider")
        return control
    }
    public func updateNSView(_ control:NSSegmentedControl,context:Context) {
        context.coordinator.parent=self
        control.font = .systemFont(ofSize:16)
        control.controlSize = .large
        control.isEnabled=enabled
        control.selectedSegment=labels.firstIndex(of:selection) ?? -1
    }
    public final class Coordinator:NSObject {
        var parent:SettingsSegmentedPicker
        init(_ parent:SettingsSegmentedPicker) {self.parent=parent}
        @objc func changed(_ sender:NSSegmentedControl) {
            guard parent.labels.indices.contains(sender.selectedSegment) else{return}
            parent.selection=parent.labels[sender.selectedSegment]
        }
    }
}

/// Flat surfaces and light outlines from the September 13 screenshot reference.
/// Scoped to our shell/settings; does not change the activity owner's layout.
public enum ReferenceColors {
    public static let surface=Color(nsColor:NSColor(name:nil) {$0.bestMatch(from:[.darkAqua,.aqua]) == .darkAqua ? NSColor(white:0.11,alpha:1):.white})
    public static let wash=Color(nsColor:NSColor(name:nil) {$0.bestMatch(from:[.darkAqua,.aqua]) == .darkAqua ? NSColor(white:0.16,alpha:1):NSColor(srgbRed:247/255,green:247/255,blue:248/255,alpha:1)})
    public static let outline=Color(nsColor:NSColor(name:nil) {$0.bestMatch(from:[.darkAqua,.aqua]) == .darkAqua ? NSColor(white:0.28,alpha:1):NSColor(srgbRed:229/255,green:229/255,blue:231/255,alpha:1)})
}

/// Onboarding buttons: grey capsule for secondary actions, accent for the primary one.
public struct ReferenceButtonStyle:ButtonStyle {
    @Environment(\.isEnabled) private var enabled
    @Environment(\.isFocused) private var focused
    let primary:Bool
    public init(primary:Bool=false) {self.primary=primary}
    public func makeBody(configuration:Configuration)->some View {
        let pressed=configuration.isPressed && enabled
        let radius:CGFloat=primary ? 8:14
        let filled=primary && enabled
        return configuration.label.font(.system(size:13,weight:primary ? .medium:.regular))
            .multilineTextAlignment(.center).fixedSize(horizontal:false,vertical:true)
            .foregroundStyle(filled ? Color.white:primary ? Color.secondary:configuration.role == .destructive ? Self.destructive:Color.primary)
            .padding(.horizontal,primary ? 15:13).padding(.vertical,5).frame(minHeight:primary ? 30:28)
            .background(filled ? Color.accentColor.opacity(pressed ? 0.75:1):pressed ? DaydreamStyle.pillPressed:DaydreamStyle.pillFill,
                        in:RoundedRectangle(cornerRadius:radius))
            .shadow(color:.black.opacity(filled ? 0.1:0),radius:3,y:2)
            .overlay(RoundedRectangle(cornerRadius:radius+3).stroke(Color.accentColor,lineWidth:2).padding(-3).opacity(focused ? 1:0))
            .opacity(enabled || primary ? 1:0.45).contentShape(RoundedRectangle(cornerRadius:radius))
    }
    /// System red, deepened for legible text on the grey pill.
    private static let destructive=Color(nsColor:NSColor(name:nil) {$0.bestMatch(from:[.darkAqua,.aqua]) == .darkAqua ? NSColor(srgbRed:1,green:0.42,blue:0.38,alpha:1):NSColor(srgbRed:0.76,green:0.12,blue:0.1,alpha:1)})
}

/// Use inside a native Menu. Native keyboard navigation and Escape stay intact.
public struct ReferenceMenuLabel:View {
    let title:String
    public init(_ title:String) {self.title=title}
    public var body:some View {
        HStack(spacing:8) {Text(title);Image(systemName:"chevron.down").font(.system(size:10,weight:.medium)).foregroundStyle(.secondary)}
            .font(DaydreamType.body).frame(minHeight:24)
            .contentShape(Rectangle())
    }
}

public struct SettingsRow<Control:View>:View {
    let label:String;let secondary:String?;let control:Control
    public init(_ label:String,secondary:String?=nil,@ViewBuilder control:()->Control) {self.label=label;self.secondary=secondary;self.control=control()}
    public var body:some View {
        HStack(spacing:8) {VStack(alignment:.leading,spacing:3) {Text(label);if let secondary {Text(secondary).font(DaydreamType.detail).foregroundStyle(.secondary)}};Spacer(minLength:8);control}
            .font(DaydreamType.body).frame(minHeight:secondary == nil ? 36:52)
    }
}
public struct ReferenceToggleStyle:ToggleStyle {
    @Environment(\.isEnabled) private var enabled
    @Environment(\.accessibilityReduceMotion) private var reduced
    public init() {}
    public func makeBody(configuration:Configuration)->some View {
        HStack {configuration.label;Spacer(minLength:8);Button {if enabled {configuration.isOn.toggle()}} label:{
            Capsule().fill(configuration.isOn ? Color.accentColor:Self.track).opacity(enabled ? 1:0.5)
                .overlay(Capsule().strokeBorder(Color.primary.opacity(configuration.isOn ? 0:0.1),lineWidth:0.5))
                .overlay(alignment:configuration.isOn ? .trailing:.leading) {
                    Circle().fill(enabled ? Color.white:Self.disabledKnob).overlay(Circle().strokeBorder(Color.black.opacity(0.12),lineWidth:0.5))
                        .frame(width:12,height:12).shadow(color:.black.opacity(enabled ? 0.2:0.08),radius:1,y:1).padding(2)
                }
                .frame(width:26,height:16).frame(width:40,height:32).contentShape(Rectangle())
        }.buttonStyle(SwitchButtonStyle()).accessibilityLabel(Text("Toggle" )).accessibilityValue(configuration.isOn ? "On":"Off")}
            .animation(reduced ? nil:.easeInOut(duration:0.2),value:configuration.isOn)
            .accessibilityRepresentation {Toggle(isOn:Binding(get:{configuration.isOn},set:{if enabled {configuration.isOn=$0}})) {configuration.label}.toggleStyle(.switch).disabled(!enabled)}
    }
    private static let track=Color(nsColor:NSColor(name:nil) {$0.bestMatch(from:[.darkAqua,.aqua]) == .darkAqua ? NSColor(white:1,alpha:0.2):NSColor(white:0,alpha:0.17)})
    private static let disabledKnob=Color(nsColor:NSColor(name:nil) {$0.bestMatch(from:[.darkAqua,.aqua]) == .darkAqua ? NSColor(white:0.6,alpha:1):.white})
    /// .plain would fade a disabled switch a second time, leaving it invisible on light cards.
    private struct SwitchButtonStyle:ButtonStyle {
        func makeBody(configuration:Configuration)->some View {configuration.label.opacity(configuration.isPressed ? 0.85:1)}
    }
}
public struct ReferenceInputStyle:TextFieldStyle {
    @Environment(\.isEnabled) private var enabled
    @FocusState private var focused:Bool
    public init() {}
    public func _body(configuration:TextField<Self._Label>)->some View {
        configuration.textFieldStyle(.plain).focused($focused).font(DaydreamType.body).padding(.horizontal,10).frame(height:32)
            .background(Color.clear.daydreamField(focused:focused).opacity(enabled ? 1:0.5))
    }
}
