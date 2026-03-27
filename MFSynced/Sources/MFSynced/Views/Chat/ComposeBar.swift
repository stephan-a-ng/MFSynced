import SwiftUI

struct ComposeBar: View {
    let chatIdentifier: String
    @State private var text: String = ""

    var body: some View {
        VStack(spacing: 0) {
            Divider()

            HStack(spacing: 8) {
                Button(action: {}) {
                    Image(systemName: "plus")
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color.accentColor)

                TextField("Message", text: $text)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit {
                        sendMessage()
                    }

                Button(action: sendMessage) {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.title2)
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color.accentColor)
                .disabled(text.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
    }

    private func sendMessage() {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        print("TODO: Send '\(trimmed)' to \(chatIdentifier)")
        text = ""
    }
}
