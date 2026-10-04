import SwiftUI

/// App choices that didn't save: one sentence and the one button that fixes it. Settings › Apps to remember
/// and setup's Apps page show it above the choices.
public struct ChoiceProblemLine: View {
    private let text: String
    private let buttonTitle: String
    private let action: () -> Void

    public init(text: String, buttonTitle: String, action: @escaping () -> Void) {
        self.text = text
        self.buttonTitle = buttonTitle
        self.action = action
    }

    public var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 12)).foregroundStyle(.orange)
                .accessibilityHidden(true)
            Text(text).font(.system(size: 12.5)).fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            // The line's only action, in the accent colour, so it reads as the thing to press.
            Button(buttonTitle, action: action).buttonStyle(.borderedProminent).controlSize(.regular).fixedSize()
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(Color.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))
        .accessibilityElement(children: .contain)
    }
}

/// A one-line note about choices the app changed on its own (for example, after an update), shown until the
/// page closes.
public struct ChoiceNoticeLine: View {
    private let text: String
    private let buttonTitle: String?
    private let action: () -> Void

    /// `buttonTitle`: the one thing to do about it (for example Reconnect), or none.
    public init(text: String, buttonTitle: String? = nil, action: @escaping () -> Void = {}) {
        self.text = text
        self.buttonTitle = buttonTitle
        self.action = action
    }

    public var body: some View {
        HStack(alignment: buttonTitle == nil ? .firstTextBaseline : .center, spacing: 10) {
            Image(systemName: "info.circle").font(.system(size: 12)).foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text(text).font(.system(size: 12.5)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            if let buttonTitle {
                Button(buttonTitle, action: action).buttonStyle(.borderedProminent).controlSize(.regular).fixedSize()
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 10))
        .accessibilityElement(children: buttonTitle == nil ? .combine : .contain)
    }
}
