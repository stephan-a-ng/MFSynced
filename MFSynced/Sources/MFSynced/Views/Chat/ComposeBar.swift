import SwiftUI

struct ComposeBar: View {
    let chatIdentifier: String
    @State private var text: String = ""
    @FocusState private var isFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            Divider()

            HStack(alignment: .bottom, spacing: 8) {
                Button(action: {}) {
                    Image(systemName: "plus")
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color.accentColor)
                .padding(.bottom, 6)

                TextField("Message", text: $text, axis: .vertical)
                    .lineLimit(1...5)
                    .textFieldStyle(.plain)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(Color(nsColor: .controlBackgroundColor))
                    .clipShape(RoundedRectangle(cornerRadius: 18))
                    .overlay(
                        RoundedRectangle(cornerRadius: 18)
                            .stroke(Color(nsColor: .separatorColor), lineWidth: 0.5)
                    )
                    .focused($isFocused)
                    .onSubmit {
                        sendMessage()
                    }
                    .onAppear {
                        isFocused = true
                    }

                Button(action: sendMessage) {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.title2)
                }
                .buttonStyle(.plain)
                .foregroundStyle(text.trimmingCharacters(in: .whitespaces).isEmpty ? .secondary : Color.accentColor)
                .disabled(text.trimmingCharacters(in: .whitespaces).isEmpty)
                .padding(.bottom, 4)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        .transaction { t in
            t.animation = nil
        }
    }

    private func sendMessage() {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        MessageSender.send(text: trimmed, to: chatIdentifier)
        text = ""
    }
}
