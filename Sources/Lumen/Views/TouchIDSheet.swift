import SwiftUI
import AppKit
import LumenCore

struct TouchIDSheet: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var model: LibraryModel
    let machine: VirtualMachineRecord

    @State private var password = ""
    @State private var hasSaved = false
    @State private var statusMessage: String?
    @State private var isError = false

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(spacing: 12) {
                Image(systemName: "touchid")
                    .font(.system(size: 28))
                    .foregroundStyle(LumenStyle.mint)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Touch ID Login")
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.95))
                    Text(machine.name)
                        .font(.system(size: 13))
                        .foregroundStyle(LumenStyle.secondary)
                }
                Spacer()
                Button { dismiss() } label: { Image(systemName: "xmark") }
                    .buttonStyle(IconButtonStyle())
                    .keyboardShortcut(.cancelAction)
            }

            VStack(alignment: .leading, spacing: 10) {
                Text("Log into \(machine.operatingSystemName) using Touch ID or your Mac password.")
                    .font(.system(size: 12))
                    .foregroundStyle(LumenStyle.secondary)
                    .lineSpacing(3)

                Text("Newly saved passwords are protected by Keychain user-presence access control. Focus the guest password field before unlocking. Automatic typing requires a US guest keyboard layout and printable ASCII characters.")
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.4))
                    .lineSpacing(3)
            }
            .padding(14)
            .background(RoundedRectangle(cornerRadius: 12).fill(Color.white.opacity(0.04)))

            VStack(alignment: .leading, spacing: 8) {
                Text(hasSaved ? "Update Guest Password" : "Guest Password")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white.opacity(0.75))

                SecureField("Enter guest user password", text: $password)
                    .textFieldStyle(.plain)
                    .padding(10)
                    .background(RoundedRectangle(cornerRadius: 10).fill(Color.white.opacity(0.07)))
                    .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.white.opacity(0.12), lineWidth: 1))
            }

            if let msg = statusMessage {
                HStack(spacing: 8) {
                    Image(systemName: isError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                        .foregroundStyle(isError ? .red : LumenStyle.mint)
                    Text(msg)
                        .font(.system(size: 11))
                        .foregroundStyle(isError ? .red : LumenStyle.mint)
                }
                .padding(.vertical, 2)
            }

            HStack(spacing: 12) {
                if hasSaved {
                    Button(role: .destructive) {
                        model.deleteTouchIDPassword(for: machine)
                        hasSaved = false
                        password = ""
                        statusMessage = "Password removed from Keychain."
                        isError = false
                    } label: {
                        Text("Remove Password")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.red.opacity(0.85))
                    .font(.system(size: 12))
                }

                Spacer()

                if hasSaved && model.state(for: machine.id) == .running {
                    Button {
                        dismiss()
                        Task {
                            try? await Task.sleep(nanoseconds: 300_000_000)
                            await model.unlockWithTouchID(machine)
                        }
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "touchid")
                            Text("Unlock Now")
                        }
                    }
                    .buttonStyle(CapsuleButtonStyle(prominent: false))
                }

                Button {
                    guard !password.isEmpty else {
                        statusMessage = "Please enter your guest password."
                        isError = true
                        return
                    }
                    do {
                        try model.saveTouchIDPassword(password, for: machine)
                        hasSaved = true
                        password = ""
                        statusMessage = "Password saved securely. You can now unlock with Touch ID!"
                        isError = false
                    } catch {
                        statusMessage = error.localizedDescription
                        isError = true
                    }
                } label: {
                    Text(hasSaved ? "Update in Keychain" : "Save to Keychain")
                }
                .buttonStyle(CapsuleButtonStyle(prominent: true))
                .disabled(password.isEmpty)
            }
            .padding(.top, 8)
        }
        .padding(24)
        .frame(width: 480)
        .background { LumenBackground() }
        .preferredColorScheme(.dark)
        .onAppear {
            hasSaved = model.hasTouchIDPassword(for: machine)
        }
    }
}
