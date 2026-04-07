import SwiftUI

struct ChatView: View {
    let conversation: Conversation
    let messages: [Message]
    var contact: Contact?
    var contactStore: ContactStore?
    @Environment(\.colorScheme) private var colorScheme

    @State private var showingContactPopover = false
    @State private var newFirstName = ""
    @State private var newLastName = ""
    @State private var isSaving = false

    private var filteredMessages: [Message] {
        messages.filter { !$0.isTapback }
    }

    private var groupedMessages: [(date: Date, messages: [Message])] {
        let calendar = Calendar.current
        let grouped = Dictionary(grouping: filteredMessages) { msg in
            calendar.startOfDay(for: msg.date)
        }
        return grouped
            .sorted { $0.key < $1.key }
            .map { (date: $0.key, messages: $0.value) }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Chat header
            chatHeader

            Divider()

            // Messages
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 4) {
                        ForEach(groupedMessages, id: \.date) { group in
                            DateSeparator(date: group.messages.first?.date ?? group.date)

                            ForEach(group.messages) { message in
                                MessageBubble(message: message)
                                    .id(message.id)
                            }
                        }

                        // Invisible anchor at the very bottom
                        Color.clear
                            .frame(height: 1)
                            .id("bottom")
                    }
                    .padding(.vertical, 8)
                }
                .onAppear {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                        proxy.scrollTo("bottom", anchor: .bottom)
                    }
                }
                .onChange(of: messages.count) {
                    withAnimation {
                        proxy.scrollTo("bottom", anchor: .bottom)
                    }
                }
            }

            // Compose bar
            ComposeBar(chatIdentifier: conversation.id)
                .animation(.none, value: 0)
        }
        .background(colorScheme == .dark ? Color.black : Color.white)
    }

    /// Whether the conversation ID looks like a phone number (not an email/group chat).
    private var isPhoneNumber: Bool {
        let digits = conversation.id.filter { $0.isNumber }
        return digits.count >= 7
    }

    /// Whether this contact is unresolved (showing a raw phone number instead of a name).
    private var isUnresolved: Bool {
        contact?.fullName == nil
    }

    private var chatHeader: some View {
        VStack(spacing: 4) {
            avatarSmall

            HStack(spacing: 4) {
                Text(contact?.fullName ?? conversation.title)
                    .font(.headline)

                if conversation.isCRMSynced {
                    Image(systemName: "arrow.triangle.2.circlepath.circle.fill")
                        .foregroundStyle(.green)
                        .font(.caption)
                }
            }

            // Show phone number below the name when we have a resolved contact name
            if isPhoneNumber, !isUnresolved {
                Text(conversation.id)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Text(conversation.service)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
        .onTapGesture {
            if isPhoneNumber && isUnresolved {
                newFirstName = ""
                newLastName = ""
                showingContactPopover = true
            }
        }
        .popover(isPresented: $showingContactPopover, arrowEdge: .bottom) {
            contactPopover
        }
    }

    private var contactPopover: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Create Contact")
                .font(.headline)

            Text(conversation.id)
                .font(.subheadline)
                .foregroundStyle(.secondary)

            TextField("First Name", text: $newFirstName)
                .textFieldStyle(.roundedBorder)

            TextField("Last Name", text: $newLastName)
                .textFieldStyle(.roundedBorder)

            HStack {
                Button("Cancel") {
                    showingContactPopover = false
                }
                .keyboardShortcut(.cancelAction)

                Spacer()

                Button("Save") {
                    guard !newFirstName.isEmpty || !newLastName.isEmpty else { return }
                    isSaving = true
                    Task {
                        do {
                            try await contactStore?.createContact(
                                firstName: newFirstName,
                                lastName: newLastName,
                                phoneNumber: conversation.id
                            )
                        } catch {
                            print("Failed to create contact: \(error)")
                        }
                        isSaving = false
                        showingContactPopover = false
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled((newFirstName.isEmpty && newLastName.isEmpty) || isSaving)
            }
        }
        .padding()
        .frame(width: 260)
    }

    private var avatarSmall: some View {
        let hash = abs(conversation.id.hashValue)
        let colors: [Color] = [
            .red, .orange, .yellow, .green, .mint,
            .teal, .cyan, .blue, .indigo, .purple, .pink,
        ]
        let avatarColor = colors[hash % colors.count]

        return Circle()
            .fill(avatarColor)
            .frame(width: 32, height: 32)
            .overlay(
                Text(conversation.initials)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white)
            )
    }
}
