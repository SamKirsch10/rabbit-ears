// iOS/ServerSetupView.swift
import SwiftUI

struct ServerSetupView: View {
    @AppStorage("tvhServerURL") private var savedServerURLString: String = ""
    @AppStorage("tvhUsername") private var savedUsername: String = ""
    @State private var input: String = ""
    @State private var usernameInput: String = ""
    @State private var passwordInput: String = ""
    @State private var errorMessage: String?

    var onSave: () -> Void

    var body: some View {
        Form {
            Section {
                TextField("http://192.168.1.10:9981", text: $input)
                    .keyboardType(.URL)
                    .textContentType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            } header: {
                Text("Server Address")
            } footer: {
                Text("The address of your TVHeadend server, including port.")
            }

            Section {
                TextField("Username", text: $usernameInput)
                    .textContentType(.username)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                SecureField("Password", text: $passwordInput)
                    .textContentType(.password)
            } header: {
                Text("Login (optional)")
            } footer: {
                Text("Only needed if your server requires login.")
            }

            if let errorMessage {
                Section {
                    Text(errorMessage)
                        .foregroundStyle(.red)
                }
            }
        }
        .navigationTitle("Connect to TVHeadend")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Save", action: save)
            }
        }
        .onAppear {
            input = savedServerURLString
            usernameInput = savedUsername
            passwordInput = KeychainStore.get(forKey: "tvhPassword")
        }
    }

    private func save() {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed), url.scheme != nil, url.host != nil else {
            errorMessage = "Enter a valid URL, e.g. http://192.168.1.10:9981"
            return
        }
        errorMessage = nil
        savedServerURLString = trimmed
        savedUsername = usernameInput.trimmingCharacters(in: .whitespacesAndNewlines)
        KeychainStore.set(passwordInput, forKey: "tvhPassword")
        onSave()
    }
}
