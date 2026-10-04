import SwiftUI

public struct SettingsSurface<Content:View>:View {
    @Environment(\.daydreamSettingsDetail) private var detailStyle
    let title:String; let content:Content
    public init(_ title:String,@ViewBuilder content:()->Content) { self.title=title; self.content=content() }
    public var body:some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment:.leading,spacing:detailStyle ? 14:16) {
                if !detailStyle {Text(title).font(.system(size:16,weight:.semibold))}
                content
            }.font(.system(size:14)).frame(maxWidth:detailStyle ? .infinity:520,alignment:.leading).padding(detailStyle ? 4:24).frame(maxWidth:.infinity,alignment:.top)
        }.background(detailStyle ? Color.clear:ReferenceColors.surface).buttonStyle(ReferenceButtonStyle()).disclosureGroupStyle(SettingsDisclosureStyle())
            .scrollIndicators(.hidden)
    }
}
public struct SettingsFrame<Content:View>:View {
    @Binding var selection:String
    let content:(String)->Content
    let close:(()->Void)?
    public init(selection:Binding<String>,close:(()->Void)?=nil,@ViewBuilder content:@escaping(String)->Content) { _selection=selection; self.close=close; self.content=content }
    public var body:some View {
        HStack(spacing:0) {
            VStack(alignment:.leading,spacing:4) {
                section("General",icon:"gearshape")
                section("Recording",icon:"record.circle")
                section("Memory",icon:"book.closed")
                section("Connections",icon:"point.3.connected.trianglepath.dotted")
            }.padding(12).frame(width:180).frame(maxHeight:.infinity,alignment:.top)
                .background(Color(nsColor:.windowBackgroundColor))
                .accessibilityElement(children:.contain).accessibilityLabel("Settings sections")
            Divider()
            VStack(spacing:0) {
                if let close {
                    HStack {Spacer();Button("Done",action:close).keyboardShortcut(.cancelAction)}
                        .padding(.horizontal,16).frame(height:44)
                }
                content(selection).frame(minWidth:0,maxWidth:.infinity,maxHeight:.infinity)
            }.frame(minWidth:0,maxWidth:.infinity,maxHeight:.infinity)
        }.background(ReferenceColors.surface).font(.system(size:14)).buttonStyle(ReferenceButtonStyle()).disclosureGroupStyle(SettingsDisclosureStyle())
            .scrollIndicators(.hidden)
    }
    private func section(_ title:String,icon:String)->some View {
        Button {selection=title} label:{
            Label(title,systemImage:icon).font(.system(size:13,weight:selection == title ? .semibold:.regular))
                .frame(maxWidth:.infinity,alignment:.leading).padding(.horizontal,10).frame(height:34)
                .foregroundStyle(selection == title ? Color.white:Color.primary)
                .background(selection == title ? Color.accentColor:Color.clear,in:RoundedRectangle(cornerRadius:6))
                .contentShape(Rectangle())
        }.buttonStyle(.plain).accessibilityLabel(title)
            .accessibilityAddTraits(selection == title ? .isSelected:[])
    }
}
public struct SettingsCard<Content:View>:View {
    @Environment(\.daydreamSettingsDetail) private var detailStyle
    let content:Content
    public init(@ViewBuilder content:()->Content) { self.content=content() }
    public var body:some View {
        if detailStyle {
            // Settings detail pages: the DayDream card (spec §1 tokens), as on the overview.
            VStack(alignment:.leading,spacing:12) { content }.frame(maxWidth:.infinity,alignment:.leading)
                .padding(.horizontal,18).padding(.vertical,16)
                .daydreamCard()
        } else {
            VStack(alignment:.leading,spacing:12) { content }.frame(maxWidth:.infinity,alignment:.leading).padding(14)
                .background(ReferenceColors.wash,in:RoundedRectangle(cornerRadius:8))
                .overlay(RoundedRectangle(cornerRadius:8).stroke(ReferenceColors.outline,lineWidth:1))
        }
    }
}
/// A card of `LinkRow`s on a Settings detail page (Advanced): tight padding so the rows' hover
/// fills sit just inside the card edge.
public struct SettingsListCard<Content:View>:View {
    let content:Content
    public init(@ViewBuilder content:()->Content) { self.content=content() }
    public var body:some View {
        VStack(spacing:2) { content }.frame(maxWidth:.infinity).padding(6).daydreamCard()
    }
}

// MARK: - Grouped rows (a macOS settings pane: one card, rows split by hairlines, each with its button on the right)

/// One group of `SettingsActionRow`s in a card, rows split by hairlines (`SettingsGroupDivider`). No scroll view: a
/// page built from groups is as tall as its rows, so the Settings sheet can fit it (`DaydreamSettingsPage.fitsContent`).
public struct SettingsGroup<Content:View>:View {
    let content:Content
    public init(@ViewBuilder content:()->Content) { self.content=content() }
    public var body:some View {
        VStack(alignment:.leading,spacing:0) { content }
            .frame(maxWidth:.infinity,alignment:.leading)
            .padding(.horizontal,16)
            .daydreamCard()
    }
}
/// The hairline between two rows of a `SettingsGroup`.
public struct SettingsGroupDivider:View {
    public init() {}
    public var body:some View { Rectangle().fill(DaydreamStyle.cardStroke).frame(height:1).accessibilityHidden(true) }
}
/// A row: its name, one short line under it, and its control on the right.
public struct SettingsActionRow<Control:View>:View {
    let title:String; let detail:String?; let control:Control
    public init(_ title:String,detail:String?=nil,@ViewBuilder control:()->Control) { self.title=title; self.detail=detail; self.control=control() }
    public var body:some View {
        HStack(alignment:.center,spacing:16) {
            VStack(alignment:.leading,spacing:3) {
                Text(title).font(.system(size:13,weight:.medium))
                if let detail {
                    Text(detail).font(.system(size:12)).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)
                }
            }
            Spacer(minLength:12)
            HStack(spacing:8) { control }.fixedSize()
        }
        .padding(.vertical,12).frame(minHeight:detail == nil ? 44:56)
        .accessibilityElement(children:.contain)
    }
}
/// The row buttons of a `SettingsGroup`: the capsule of the sheet's Done button, grey (or blue for the one to press).
public struct SettingsGroupButtonStyle:ButtonStyle {
    let prominent:Bool
    @Environment(\.isEnabled) private var enabled
    public init(prominent:Bool=false) { self.prominent=prominent }
    public func makeBody(configuration:Configuration)->some View {
        configuration.label
            .font(.system(size:12.5,weight:prominent ? .semibold:.medium)).lineLimit(1)
            .foregroundStyle(prominent ? Color.white:configuration.role == .destructive ? Color.red:Color.primary)
            .padding(.horizontal,prominent ? 14:13).frame(height:28)
            .background(prominent ? AnyShapeStyle(Color.accentColor.gradient):AnyShapeStyle(KitPalette.chip),in:Capsule())
            .overlay(Capsule().fill(Color.black.opacity(configuration.isPressed ? 0.12:0)))
            .contentShape(Capsule())
            .opacity(enabled ? 1:0.45)
    }
}
