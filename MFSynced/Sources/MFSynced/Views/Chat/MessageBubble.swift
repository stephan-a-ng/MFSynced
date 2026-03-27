import SwiftUI

struct MessageBubble: View {
    let message: Message
    @Environment(\.colorScheme) private var colorScheme

    private var bubbleColor: Color {
        if message.isFromMe {
            return colorScheme == .dark
                ? Color(red: 10 / 255, green: 132 / 255, blue: 255 / 255)  // #0A84FF
                : Color(red: 0, green: 122 / 255, blue: 255 / 255)          // #007AFF
        } else {
            return colorScheme == .dark
                ? Color(red: 44 / 255, green: 44 / 255, blue: 46 / 255)     // #2C2C2E
                : Color(red: 233 / 255, green: 233 / 255, blue: 235 / 255)  // #E9E9EB
        }
    }

    private var textColor: Color {
        if message.isFromMe {
            return .white
        } else {
            return colorScheme == .dark ? .white : .black
        }
    }

    private var bubbleShape: UnevenRoundedRectangle {
        if message.isFromMe {
            return UnevenRoundedRectangle(
                topLeadingRadius: 18,
                bottomLeadingRadius: 18,
                bottomTrailingRadius: 4,
                topTrailingRadius: 18
            )
        } else {
            return UnevenRoundedRectangle(
                topLeadingRadius: 18,
                bottomLeadingRadius: 4,
                bottomTrailingRadius: 18,
                topTrailingRadius: 18
            )
        }
    }

    var body: some View {
        if message.isTapback {
            tapbackView
        } else {
            normalBubble
        }
    }

    @ViewBuilder
    private var tapbackView: some View {
        if let label = message.tapbackLabel {
            Text(label)
                .font(.caption)
                .italic()
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: message.isFromMe ? .trailing : .leading)
                .padding(.horizontal, 16)
        }
    }

    private var normalBubble: some View {
        HStack {
            if message.isFromMe { Spacer(minLength: 60) }

            VStack(alignment: message.isFromMe ? .trailing : .leading, spacing: 2) {
                if let text = message.displayText {
                    Text(text)
                        .foregroundStyle(textColor)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(bubbleColor, in: bubbleShape)
                }

                if message.cacheHasAttachments, let names = message.attachmentNames {
                    Label(names, systemImage: "paperclip")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if message.dateEdited != nil {
                    Text("Edited")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }

            if !message.isFromMe { Spacer(minLength: 60) }
        }
        .padding(.horizontal, 8)
    }
}
