import SafariServices
import SwiftUI

struct FreeRepsSettingsView: View {
    @ObservedObject var vm: SettingsViewModel
    @ObservedObject private var tailscale = EmbeddedTailscale.shared
    @State private var loginPage: LoginPage?
    @State private var showSignOut = false

    private var usesTailscale: Bool { vm.config.connectionMode == .tailscale }
    private var signedIn: Bool {
        tailscale.isSignedIn && tailscale.phase != .signedOut
    }
    /// The server this page checks, or nil while there is nothing to check.
    private var server: String? {
        if usesTailscale {
            guard signedIn, !vm.config.tailnetHost.isEmpty else { return nil }
            return vm.config.tailnetHost
        }
        let host = vm.config.host.trimmingCharacters(in: .whitespaces)
        return host.isEmpty ? nil : host
    }

    var body: some View {
        Form {
            Section {
                Picker("Connect via", selection: $vm.config.connectionMode) {
                    Text("Tailscale Sign-In").tag(FreeRepsConfig.ConnectionMode.tailscale)
                    Text("Manual Address").tag(FreeRepsConfig.ConnectionMode.address)
                }
                .pickerStyle(.segmented)
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets())
            }

            statusSection

            if usesTailscale {
                if signedIn { serverSelection }
            } else {
                addressSection
            }
        }
        .navigationTitle("FreeReps Connection")
        .onChange(of: vm.config) { _, _ in
            vm.saveConfig()
            if vm.connectionTestState != .testing { vm.connectionTestState = .idle }
        }
        .onChange(of: server) { _, _ in
            // A typed address is checked on Done, not on every keystroke.
            if usesTailscale { checkIfPossible() }
        }
        .onChange(of: vm.config.connectionMode) { _, _ in checkIfPossible() }
        .onChange(of: tailscale.servers) { _, _ in chooseServerIfNeeded() }
        .onChange(of: tailscale.phase) { _, phase in
            switch phase {
            case .waitingForLogin(let url):
                if loginPage == nil { loginPage = LoginPage(url: url) }
            case .connected:
                loginPage = nil
                Task { await tailscale.findServers() }
            default:
                break
            }
        }
        .task {
            checkIfPossible()
            if usesTailscale, tailscale.isSignedIn {
                try? await tailscale.connectForSync()
                await tailscale.findServers()
            }
        }
        .sheet(item: $loginPage) { page in
            SafariView(url: page.url).ignoresSafeArea()
        }
        .confirmationDialog("Sign out of Tailscale?", isPresented: $showSignOut, titleVisibility: .visible) {
            Button("Sign Out", role: .destructive) {
                Task { await tailscale.signOut() }
            }
        } message: {
            Text("FreeReps stops syncing until you sign in again.")
        }
    }

    // MARK: - Status

    private var statusSection: some View {
        Section {
            HStack(spacing: 14) {
                Image(systemName: "server.rack")
                    .font(.system(size: 26))
                    .foregroundStyle(isConnected ? Color.green : Color.secondary)
                    .frame(width: 40)
                VStack(alignment: .leading, spacing: 2) {
                    Text(statusTitle).font(.headline)
                    Text(verbatim: statusSubtitle)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer()
                if isBusy { ProgressView() }
            }
            .padding(.vertical, 4)

            statusAction
        } footer: {
            if case .failure(let message) = vm.connectionTestState {
                Text(message)
            } else if case .failed(let message) = tailscale.phase, usesTailscale {
                Text(message)
            } else if usesTailscale && !signedIn {
                Text("Use the Tailscale account your server belongs to. Tailscale runs inside FreeReps, so other VPNs keep working.")
            }
        }
    }

    @ViewBuilder
    private var statusAction: some View {
        if usesTailscale, case .waitingForLogin(let url) = tailscale.phase {
            Button("Open Sign-In Page") { loginPage = LoginPage(url: url) }
        } else if usesTailscale && !signedIn {
            Button("Sign In with Tailscale") {
                Task { await tailscale.signIn() }
            }
            .disabled(tailscale.phase == .connecting)
            .accessibilityIdentifier("tailscale-sign-in")
        } else {
            Button("Check Connection") { vm.testConnection() }
                .disabled(server == nil || vm.connectionTestState == .testing)
                .accessibilityIdentifier("check-server-connection")
        }
    }

    private var isConnected: Bool {
        if case .success = vm.connectionTestState { return server != nil }
        return false
    }

    private var isBusy: Bool {
        vm.connectionTestState == .testing || (usesTailscale && tailscale.phase == .connecting)
    }

    private var statusTitle: String {
        if usesTailscale {
            if case .waitingForLogin = tailscale.phase { return "Signing In" }
            if tailscale.phase == .connecting { return "Connecting" }
            if !signedIn { return "Not Connected" }
        }
        guard server != nil else { return "Not Connected" }
        switch vm.connectionTestState {
        case .idle: return "Not Checked"
        case .testing: return "Checking"
        case .success: return "Connected"
        case .failure: return "Not Connected"
        }
    }

    private var statusSubtitle: String {
        if usesTailscale {
            if case .waitingForLogin = tailscale.phase { return "Finish on the Tailscale page." }
            if !signedIn { return "Sign in to reach your server." }
            guard let server else { return "Choose your server below." }
            return String(server.split(separator: ".").first ?? Substring(server))
        }
        return server ?? "Enter your server address below."
    }

    // MARK: - Tailscale

    private var serverSelection: some View {
        Section {
            if tailscale.isSearching && tailscale.servers.isEmpty {
                HStack {
                    Text("Searching for FreeReps servers…").foregroundStyle(.secondary)
                    Spacer()
                    ProgressView()
                }
            } else if tailscale.servers.isEmpty {
                Button("Search Again") { Task { await tailscale.findServers() } }
            }
            ForEach(tailscale.servers) { device in
                Button {
                    vm.config.tailnetHost = device.host
                } label: {
                    HStack {
                        Text(device.name).foregroundStyle(.primary)
                        Spacer()
                        if vm.config.tailnetHost == device.host {
                            Image(systemName: "checkmark").foregroundStyle(.tint)
                        }
                    }
                }
            }
            Button("Sign Out of Tailscale", role: .destructive) { showSignOut = true }
        } header: {
            Text("Server")
        } footer: {
            Text(!tailscale.isSearching && tailscale.servers.isEmpty
                 ? "No FreeReps server answered in your tailnet. Make sure it is running."
                 : "Tailscale runs inside FreeReps, so other VPNs keep working.")
        }
    }

    /// Picks the first server that answers unless a reachable one is already chosen.
    private func chooseServerIfNeeded() {
        let chosen = vm.config.tailnetHost
        guard usesTailscale, let first = tailscale.servers.first,
              !tailscale.devices.contains(where: { $0.host == chosen && $0.online }) else { return }
        vm.config.tailnetHost = first.host
    }

    /// Checks as soon as there is a server, so the status is never stale.
    private func checkIfPossible() {
        guard server != nil, vm.connectionTestState != .testing else { return }
        vm.testConnection()
    }

    // MARK: - Address

    private var addressSection: some View {
        Section {
            LabeledContent("Address") {
                TextField("freereps.your-tailnet.ts.net", text: $vm.config.host)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                    .multilineTextAlignment(.trailing)
                    .submitLabel(.done)
                    .onSubmit { vm.testConnection() }
            }
        } header: {
            Text("Server")
        } footer: {
            Text("Your iPhone must reach this address directly, for example on your home network or through a VPN.")
        }
    }
}

private struct LoginPage: Identifiable {
    let url: URL
    var id: String { url.absoluteString }
}

private struct SafariView: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> SFSafariViewController {
        SFSafariViewController(url: url)
    }

    func updateUIViewController(_ controller: SFSafariViewController, context: Context) {}
}
