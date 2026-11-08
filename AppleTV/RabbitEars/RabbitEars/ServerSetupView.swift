// Sources/ServerSetupView.swift
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
        VStack(spacing: 24) {
            Text("Connect to TVHeadend")
                .font(.title)

            Text("Enter the address of your TVHeadend server, including port.")
                .font(.body)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)

            TextField("http://192.168.1.10:9981", text: $input)
                .frame(maxWidth: 600)

            VStack(spacing: 12) {
                Text("Username and password are optional — only needed if your server requires login.")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)

                TextField("Username (optional)", text: $usernameInput)
                    .frame(maxWidth: 600)

                SecureField("Password (optional)", text: $passwordInput)
                    .frame(maxWidth: 600)
            }

            if let errorMessage {
                Text(errorMessage)
                    .foregroundColor(.red)
            }

            Button("Save") {
                save()
            }
            .buttonStyle(.borderedProminent)
        }
        .padding(60)
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
