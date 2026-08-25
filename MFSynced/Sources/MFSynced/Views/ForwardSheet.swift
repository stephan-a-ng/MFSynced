import SwiftUI

struct ForwardSheet: View {
    let conversation: Conversation
    let config: CRMConfig
    var contactName: String?
    var onDismiss: () -> Void
    var onForwardSuccess: (() -> Void)? = nil

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
        VStack(alignment: .leading, spacing: 14) {
            headerSection
            Divider()
            modeSection
            recipientSection
            noteSection
            if let error = errorMessage {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
            forwardButton
        }
        .padding(16)
        .frame(width: 300)
        .task { await loadTeamMembers() }
    }

    // MARK: - Subviews

    private var headerSection: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Forward to Team")
                .font(.headline)
            Text(contactName ?? conversation.title)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }

    private var modeSection: some View {
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
    }

    private var recipientSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("SEND TO")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fontWeight(.semibold)
            recipientList
        }
    }

    @ViewBuilder
    private var recipientList: some View {
        if isLoading {
            HStack { Spacer(); ProgressView(); Spacer() }
                .frame(height: 60)
        } else if teamMembers.isEmpty {
            Text("No team members found")
                .foregroundStyle(.secondary)
                .font(.subheadline)
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.vertical, 8)
        } else {
            VStack(spacing: 2) {
                ForEach(teamMembers) { member in
                    MemberRow(member: member, isSelected: selectedMemberID == member.id) {
                        selectedMemberID = member.id
                    }
                }
            }
        }
    }

    private var noteSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("NOTE (OPTIONAL)")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fontWeight(.semibold)
            TextField("Add a note...", text: $note, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(1...3)
                .onSubmit { if selectedMemberID != nil { doForward() } }
        }
    }

    private var forwardButton: some View {
        Button(action: doForward) {
            forwardButtonLabel
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
        .disabled(selectedMemberID == nil || isForwarding || didForward)
    }

    @ViewBuilder
    private var forwardButtonLabel: some View {
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

    // MARK: - Networking

    /// Every network call below routes through the shared auth/endpoint
    /// resolution (`AuthService.shared.authorizationHeaderValue(for:)`):
    /// a validated OIDC (OpenID Connect) Bearer token for ANY target. The
    /// production shared auth service never falls back while signed out. This is
    /// the SAME resolution CRMSyncService's pushInbound/syncHistory use, so
    /// team-forward never falls back to a raw `config.apiKey` the way the
    /// pre-OIDC version of this view did (which meant a signed-in,
    /// no-legacy-key install could never forward at all).

    private func loadTeamMembers() async {
        guard let primary = config.targets.first,
              let url = URL(string: "\(primary.url.absoluteString)/users") else {
            await MainActor.run { isLoading = false }
            return
        }
        guard let authorization = await AuthService.shared.authorizationHeaderValue(for: primary) else {
            await MainActor.run { isLoading = false }
            return
        }
        var req = URLRequest(url: url)
        req.setValue(authorization, forHTTPHeaderField: "Authorization")
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
        guard let recipientID = selectedMemberID,
              let recipientEmail = teamMembers.first(where: { $0.id == recipientID })?.email,
              let primary = config.targets.first
        else { return }
        isForwarding = true
        errorMessage = nil

        Task {
            // Forward to primary using the already-loaded recipient ID.
            let primaryOK: Bool
            if let primaryAuthorization = await AuthService.shared.authorizationHeaderValue(for: primary) {
                primaryOK = await postForward(
                    target: primary, authorization: primaryAuthorization, recipientID: recipientID
                )
            } else {
                primaryOK = false
            }

            // Every additional target: resolve the recipient's UUID on
            // that backend by email (each backend has different UUIDs for
            // the same person), using THAT target's own resolved
            // credential — never the primary's.
            for mirrorTarget in config.targets.dropFirst() {
                Task {
                    guard let mirrorAuthorization = await AuthService.shared.authorizationHeaderValue(for: mirrorTarget) else {
                        return
                    }
                    if let mirrorRecipientID = await resolveUserID(
                        email: recipientEmail, target: mirrorTarget, authorization: mirrorAuthorization
                    ) {
                        _ = await postForward(
                            target: mirrorTarget, authorization: mirrorAuthorization, recipientID: mirrorRecipientID
                        )
                    }
                }
            }

            await MainActor.run {
                isForwarding = false
                if primaryOK {
                    didForward = true
                    onForwardSuccess?()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { onDismiss() }
                } else {
                    errorMessage = "Forward failed. Is this conversation synced?"
                }
            }
        }
    }

    /// Looks up a user's ID by email on one target's backend.
    private func resolveUserID(email: String, target: SyncTarget, authorization: String) async -> String? {
        guard let url = URL(string: "\(target.url.absoluteString)/users") else { return nil }
        var req = URLRequest(url: url)
        req.setValue(authorization, forHTTPHeaderField: "Authorization")
        guard let (data, _) = try? await URLSession.shared.data(for: req),
              let users = try? JSONDecoder().decode([UserDTO].self, from: data)
        else { return nil }
        return users.first(where: { $0.email == email })?.id
    }

    /// POSTs a forward request to one target. Returns true on HTTP 200.
    private func postForward(target: SyncTarget, authorization: String, recipientID: String) async -> Bool {
        guard let url = URL(string: "\(target.url.absoluteString)/forward") else { return false }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue(authorization, forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        var body: [String: Any] = [
            "phone": conversation.id,
            "mode": mode.rawValue,
            "recipient_user_ids": [recipientID],
        ]
        if !note.isEmpty { body["note"] = note }
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        do {
            let (_, response) = try await URLSession.shared.data(for: req)
            return (response as? HTTPURLResponse)?.statusCode == 200
        } catch {
            return false
        }
    }
}

// MARK: - Member Row

private struct MemberRow: View {
    let member: TeamMember
    let isSelected: Bool
    let onTap: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(Color.accentColor.opacity(0.15))
                .frame(width: 30, height: 30)
                .overlay(
                    Text(String(member.name.prefix(1)).uppercased())
                        .font(.caption.bold())
                        .foregroundStyle(Color.accentColor)
                )
            VStack(alignment: .leading, spacing: 1) {
                Text(member.name).font(.subheadline)
                Text(member.email).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if isSelected {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(Color.accentColor)
                    .font(.subheadline)
            }
        }
        .padding(.vertical, 5)
        .padding(.horizontal, 6)
        .background(isSelected ? Color.accentColor.opacity(0.08) : Color.clear)
        .cornerRadius(6)
        .contentShape(Rectangle())
        .onTapGesture { onTap() }
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
