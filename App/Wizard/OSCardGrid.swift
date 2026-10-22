import SwiftUI
import VMPaneCore
import VMPaneUI

/// One card per system the new-VM sheet makes (and the empty library offers): a click chooses it.
struct OSCardGrid: View {
    let selected: WizardModel.Card?
    let choose: (WizardModel.Card) -> Void
    /// The card with keyboard focus (Full Keyboard Access). It follows the choice: the grid opens with focus on the
    /// chosen card, and a click moves it along. Its ring shows only on a card that is not chosen: the chosen card's own
    /// border marks it, and two looked busy.
    @FocusState private var focused: WizardModel.Card?

    var body: some View {
        HStack(spacing: 10) {
            ForEach(WizardModel.Card.allCases) { card($0) }
        }
        // After AppKit gives the sheet's first control focus, which happens after onAppear.
        .task { focused = selected }
    }

    private func card(_ card: WizardModel.Card) -> some View {
        let chosen = selected == card
        return Button {
            choose(card)
            focused = card
        } label: {
            VStack(spacing: 6) {
                Image(systemName: OSBadge.symbol(card.os)).font(.system(size: 28))
                Text(card.title).font(.headline)
                Text(card.detail).font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity, minHeight: 120)
            .padding(6)
            .background(chosen ? Color.accentColor.opacity(0.12) : .clear, in: RoundedRectangle(cornerRadius: 10))
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(chosen ? Color.accentColor : Color.secondary.opacity(0.3), lineWidth: chosen ? 2 : 1)
            )
            .overlay(alignment: .topTrailing) {
                if chosen { Image(systemName: "checkmark.circle.fill").foregroundStyle(Color.accentColor).padding(5) }
            }
            .padding(3)
            .overlay(
                RoundedRectangle(cornerRadius: 13)
                    .strokeBorder(Color(nsColor: .keyboardFocusIndicatorColor), lineWidth: focused == card && !chosen ? 3 : 0)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .focused($focused, equals: card)
        .accessibilityLabel(card.title)
        .accessibilityHint(card.detail)
        .accessibilityAddTraits(chosen ? .isSelected : [])
    }
}
