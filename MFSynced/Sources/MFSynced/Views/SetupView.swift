import SwiftUI
import SQLite3

struct SetupView: View {
    @Binding var isPresented: Bool
    var onComplete: () -> Void

    @State private var step: Step = .checkingPermission
    @State private var apiEndpoint: String = ""
    @State private var apiKey: String = ""
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
                Text("MFSynced Setup")
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
                    stepRow(number: 2, title: "Connect to Backend", isComplete: step == .done) {
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
                    Button("Skip for Now") {
                        finishSetup()
                    }
                    .buttonStyle(.bordered)
                    Button("Save & Continue") {
                        saveCRMConfig()
                        finishSetup()
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(apiEndpoint.isEmpty || apiKey.isEmpty)
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
                        Text("MFSynced reads your iMessage history from ~/Library/Messages/chat.db. macOS blocks access until you grant Full Disk Access.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                VStack(alignment: .leading, spacing: 6) {
                    instructionRow("1", "Open System Settings → Privacy & Security → Full Disk Access")
                    instructionRow("2", "Click + and add MFSynced (this binary), OR enable Terminal if you launched the app from a terminal")
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
                Text("Connect MFSynced to your backend to forward conversations to your team.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                VStack(alignment: .leading, spacing: 8) {
                    Text("API Endpoint")
                        .font(.caption.bold())
                        .foregroundStyle(.secondary)
                    TextField("https://your-backend.example.com", text: $apiEndpoint)
                        .textFieldStyle(.roundedBorder)
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text("API Key")
                        .font(.caption.bold())
                        .foregroundStyle(.secondary)
                    SecureField("mfs_...", text: $apiKey)
                        .textFieldStyle(.roundedBorder)
                }

                Text("You can find your API key in the web portal under Settings → Mac App.")
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
                    apiEndpoint = existing.apiEndpoint
                    apiKey = existing.apiKey
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
        config.apiEndpoint = apiEndpoint
        config.apiKey = apiKey
        config.isEnabled = !apiEndpoint.isEmpty && !apiKey.isEmpty
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
