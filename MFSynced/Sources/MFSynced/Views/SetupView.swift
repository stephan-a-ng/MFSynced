import SwiftUI
import SQLite3

struct SetupView: View {
    @Binding var isPresented: Bool
    let authentication: AuthenticationController
    var onComplete: () -> Void

    @State private var step: Step = .checkingPermission
    @State private var ownerEmail: String = ""
    @State private var isCheckingDB = false

    enum Step {
        case checkingPermission
        case needsPermission
        case configureCRM
        case done
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack(spacing: 10) {
                Image(systemName: "message.fill")
                    .font(.title2)
                    .foregroundStyle(.blue)
                Text("Phone Sync Setup")
                    .font(.title2.bold())
            }
            .padding(.top, 32)
            .padding(.bottom, 8)

            Text("Let's get you set up in a few steps")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .padding(.bottom, 28)

            Divider()

            // Steps
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    stepRow(number: 1, title: "Full Disk Access", isComplete: step == .configureCRM || step == .done) {
                        permissionStep
                    }
                    stepRow(number: 2, title: "Sign in to Moon Five", isComplete: step == .done) {
                        crmStep
                    }
                }
                .padding(24)
            }

            Divider()

            // Footer
            HStack {
                Spacer()
                if step == .needsPermission {
                    Button("Check Again") {
                        retryPermissionCheck()
                    }
                    .buttonStyle(.bordered)
                }
                if step == .configureCRM {
                    Button("Close", role: .cancel) {
                        isPresented = false
                    }
                    .buttonStyle(.bordered)
                    Button("Save & Continue") {
                        saveCRMConfig()
                        finishSetup()
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!authentication.state.allowsSensitiveContent)
                }
                if step == .done {
                    Button("Done") {
                        isPresented = false
                        onComplete()
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
            .padding(16)
        }
        .frame(width: 540, height: 520)
        .onAppear { runPermissionCheck() }
    }

    // MARK: - Step 1: Permission

    @ViewBuilder
    private var permissionStep: some View {
        switch step {
        case .checkingPermission:
            HStack(spacing: 10) {
                ProgressView().scaleEffect(0.8)
                Text("Checking access to Messages database…")
                    .foregroundStyle(.secondary)
            }

        case .needsPermission:
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Full Disk Access is required")
                            .font(.headline)
                        Text("Phone Sync reads your iMessage history from ~/Library/Messages/chat.db. macOS blocks access until you grant Full Disk Access.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                VStack(alignment: .leading, spacing: 6) {
                    instructionRow("1", "Open System Settings → Privacy & Security → Full Disk Access")
                    instructionRow("2", "Click + and add Phone Sync (this binary), OR enable Terminal if you launched the app from a terminal")
                    instructionRow("3", "Toggle it ON and authenticate with your password")
                    instructionRow("4", "Click 'Check Again' below — no need to quit or relaunch")
                }

                Button("Open Privacy & Security Settings") {
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!)
                }
                .buttonStyle(.link)
            }
            .padding(12)
            .background(Color.orange.opacity(0.07))
            .clipShape(RoundedRectangle(cornerRadius: 8))

        case .configureCRM, .done:
            HStack(spacing: 8) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                Text("iMessage database is accessible")
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Step 2: CRM Config

    @ViewBuilder
    private var crmStep: some View {
        if step == .configureCRM || step == .done {
            VStack(alignment: .leading, spacing: 12) {
                Text("Connect Phone Sync to your Moon Five account to forward conversations to your team.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                if authentication.state.allowsSensitiveContent {
                    HStack(spacing: 8) {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                        Text(
                            authentication.state.authenticatedEmail.map { "Authenticated as \($0)" }
                                ?? "Authenticated with Moon Five"
                        )
                        .foregroundStyle(.secondary)
                    }
                } else {
                    HStack(spacing: 8) {
                        Image(systemName: "lock.shield.fill")
                            .foregroundStyle(.orange)
                        Text("Authentication is required before setup can continue")
                            .foregroundStyle(.secondary)
                    }
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text("Owner email")
                        .font(.caption.bold())
                        .foregroundStyle(.secondary)
                    TextField("you@example.com", text: $ownerEmail)
                        .textFieldStyle(.roundedBorder)
                }

                Text("The Message console account that owns this Mac's sync decisions.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        } else {
            Text("Complete step 1 first")
                .font(.callout)
                .foregroundStyle(.tertiary)
        }
    }

    // MARK: - Helpers

    private func stepRow<Content: View>(number: Int, title: String, isComplete: Bool, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                ZStack {
                    Circle()
                        .fill(isComplete ? Color.green : Color.accentColor)
                        .frame(width: 24, height: 24)
                    if isComplete {
                        Image(systemName: "checkmark")
                            .font(.caption.bold())
                            .foregroundStyle(.white)
                    } else {
                        Text("\(number)")
                            .font(.caption.bold())
                            .foregroundStyle(.white)
                    }
                }
                Text(title)
                    .font(.headline)
            }
            content()
                .padding(.leading, 34)
        }
    }

    private func instructionRow(_ number: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(number + ".")
                .font(.callout.bold())
                .foregroundStyle(.secondary)
                .frame(width: 16, alignment: .trailing)
            Text(text)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Logic

    private func runPermissionCheck() {
        isCheckingDB = true
        step = .checkingPermission
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 0.5) {
            let canRead = checkDBAccess()
            DispatchQueue.main.async {
                isCheckingDB = false
                if canRead {
                    let existing = CRMConfig.load()
                    ownerEmail = existing.ownerEmail
                    step = .configureCRM
                } else {
                    step = .needsPermission
                }
            }
        }
    }

    private func retryPermissionCheck() {
        runPermissionCheck()
    }

    private func saveCRMConfig() {
        var config = CRMConfig.load()
        config.ownerEmail = ownerEmail.trimmingCharacters(in: .whitespacesAndNewlines)
        config.isEnabled = authentication.state.allowsSensitiveContent
        config.save()
    }

    private func finishSetup() {
        UserDefaults.standard.set(true, forKey: "mfsynced_setup_complete")
        step = .done
        isPresented = false
        onComplete()
    }
}

private func checkDBAccess() -> Bool {
    let home = FileManager.default.homeDirectoryForCurrentUser.path
    let path = "\(home)/Library/Messages/chat.db"
    let uri = "file:\(path)?mode=ro"
    var db: OpaquePointer?
    let rc = sqlite3_open_v2(uri, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil)
    if rc == SQLITE_OK {
        sqlite3_close(db)
        return true
    }
    sqlite3_close(db)
    return false
}
