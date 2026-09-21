//
//  PasswordSheet.swift
//  7-Mac
//
//  The password never leaves this process: it goes from this field straight
//  into `ICryptoGetTextPassword2`. No argv, no temporary file, no subprocess.
//

import SwiftUI

struct PasswordSheet: View {
    @Bindable var prompt: PasswordPrompt
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "lock.document")
                    .font(.system(size: 28))
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 4) {
                    Text(prompt.incorrect ? "That password did not work" : "This archive is encrypted")
                        .font(.headline)
                    Text(prompt.archiveName)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .truncationMode(.middle)
                }
            }

            SecureField("Password", text: $prompt.password)
                .textFieldStyle(.roundedBorder)
                .focused($focused)
                .onSubmit(prompt.submit)

            if prompt.offersKeychain {
                Toggle("Remember this password in my keychain", isOn: $prompt.remember)
                    .toggleStyle(.checkbox)
                    .font(.callout)
            }

            HStack {
                Spacer()
                Button("Cancel", role: .cancel, action: prompt.cancel)
                    .keyboardShortcut(.cancelAction)
                Button("Unlock", action: prompt.submit)
                    .keyboardShortcut(.defaultAction)
                    .disabled(prompt.password.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 400)
        .onAppear { focused = true }
        .interactiveDismissDisabled()
    }
}
