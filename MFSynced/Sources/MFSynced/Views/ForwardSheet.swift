import SwiftUI

struct ForwardSheet: View {
    let conversation: Conversation
    let config: CRMConfig
    var contactName: String?
    var onDismiss: () -> Void

    @State private var teamMembers: [TeamMember] = []
    @State private var selectedMemberID: String?
    @State private var mode: ForwardMode = .action
    @State private var note: String = ""
    @State private var isLoading = true
    @State private var isForwarding = false
    @State private var didForward = false
    @State private var errorMessage: String?

    enum ForwardMode: String { case fyi, action }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Header
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Forward Thread")
                        .font(.headline)
                    Text(contactName ?? conversation.title)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
                Button { onDismiss() } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                        .font(.title3)
                }
                .buttonStyle(.plain)
            }

            Divider()

            // Mode
            VStack(alignment: .leading, spacing: 6) {
                Text("TYPE")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fontWeight(.semibold)
                Picker("Mode", selection: $mode) {
                    Text("Action needed").tag(ForwardMode.action)
                    Text("FYI only").tag(ForwardMode.fyi)
                }
                .pickerStyle(.segmented)
            }

            // Team member list
            VStack(alignment: .leading, spacing: 6) {
                Text("SEND TO")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fontWeight(.semibold)

                if isLoading {
                    HStack { Spacer(); ProgressView(); Spacer() }
                        .frame(height: 80)
                } else if teamMembers.isEmpty {
                    Text("No team members found")
                        .foregroundStyle(.secondary)
                        .font(.subheadline)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.vertical, 12)
                } else {
                    VStack(spacing: 0) {
                        ForEach(teamMembers) { member in
                            HStack(spacing: 10) {
                                Circle()
                                    .fill(Color.accentColor.opacity(0.15))
                                    .frame(width: 34, height: 34)
                                    .overlay(
                                        Text(String(member.name.prefix(1)).uppercased())
                                            .font(.caption.bold())
                                            .foregroundStyle(.accentColor)
                                    )
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(member.name).font(.subheadline)
                                    Text(member.email).font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                if selectedMemberID == member.id {
                                    Image(systemName: "checkmark.circle.fill")
                                        .foregroundStyle(.accentColor)
                                }
                            }
                            .padding(.vertical, 6)
                            .padding(.horizontal, 8)
                            .background(
                                selectedMemberID == member.id
                                    ? Color.accentColor.opacity(0.08)
                                    : Color.clear
                            )
                            .cornerRadius(6)
                            .contentShape(Rectangle())
                            .onTapGesture { selectedMemberID = member.id }
                        }
                    }
                }
            }

            // Note
            VStack(alignment: .leading, spacing: 6) {
                Text("NOTE (OPTIONAL)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fontWeight(.semibold)
                TextField("Add a note...", text: $note, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(1...3)
            }

            if let error = errorMessage {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            Spacer(minLength: 0)

            // Forward button
            Button(action: doForward) {
                Group {
                    if isForwarding {
                        HStack(spacing: 6) {
                            ProgressView().scaleEffect(0.75)
                            Text("Forwarding...")
                        }
                    } else if didForward {
                        Label("Forwarded", systemImage: "checkmark")
                    } else {
                        Text("Forward")
                    }
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(selectedMemberID == nil || isForwarding || didForward)
        }
        .padding(20)
        .frame(width: 340, height: 460)
        .task { await loadTeamMembers() }
    }

    // MARK: - Networking

    private func loadTeamMembers() async {
        guard let url = URL(string: "\(config.apiEndpoint)/v1/users") else {
            await MainActor.run { isLoading = false }
            return
        }
        var req = URLRequest(url: url)
        req.setValue("Bearer \(config.apiKey)", forHTTPHeaderField: "Authorization")
        do {
            let (data, _) = try await URLSession.shared.data(for: req)
            let decoded = try JSONDecoder().decode([UserDTO].self, from: data)
            await MainActor.run {
                teamMembers = decoded.map { TeamMember(id: $0.id, name: $0.name, email: $0.email) }
                isLoading = false
            }
        } catch {
            await MainActor.run { isLoading = false }
        }
    }

    private func doForward() {
        guard let recipientID = selectedMemberID else { return }
        isForwarding = true
        errorMessage = nil

        Task {
            guard let url = URL(string: "\(config.apiEndpoint)/v1/forward") else { return }
            var req = URLRequest(url: url)
            req.httpMethod = "POST"
            req.setValue("Bearer \(config.apiKey)", forHTTPHeaderField: "Authorization")
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")

            var body: [String: Any] = [
                "phone": conversation.id,
                "agent_id": config.agentID,
                "mode": mode.rawValue,
                "recipient_user_ids": [recipientID],
            ]
            if !note.isEmpty { body["note"] = note }
            req.httpBody = try? JSONSerialization.data(withJSONObject: body)

            do {
                let (_, response) = try await URLSession.shared.data(for: req)
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                await MainActor.run {
                    isForwarding = false
                    if status == 200 {
                        didForward = true
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { onDismiss() }
                    } else {
                        errorMessage = "Server returned \(status). Check that this conversation is synced."
                    }
                }
            } catch {
                await MainActor.run {
                    isForwarding = false
                    errorMessage = error.localizedDescription
                }
            }
        }
    }
}

// MARK: - Supporting types

private struct TeamMember: Identifiable {
    let id: String
    let name: String
    let email: String
}

private struct UserDTO: Decodable {
    let id: String
    let name: String
    let email: String
    let picture: String?
}
