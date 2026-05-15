//
//  ReclaudeView.swift
//  Claude Usage — reclaude.ai carpool quota credentials
//
//  One-step email+password sign-in.
//
//  Background: reclaude.ai's `rc_sid` cookie has a ~1-2 minute server-side
//  lifetime and rotates frequently, so paste-a-cookie flows are unreliable
//  by the time the user finishes pasting. The only stable path — the one
//  claude-hud's Tier 3 also relies on — is POST /api/auth/login with
//  email + password. We do that here as the single configuration step:
//  enter creds, click sign in, App fetches a fresh cookie, verifies it
//  against carpool-quota, persists cookie + email to the profile and the
//  password to the macOS Keychain. From then on, `ReclaudeAPIService`'s
//  Tier 3 auto-relogin keeps the cookie fresh in the background.
//

import SwiftUI

struct ReclaudeView: View {
    @StateObject private var profileManager = ProfileManager.shared

    // Form state — flat @State for a single-card screen, no wizard structure.
    @State private var email: String = ""
    @State private var password: String = ""
    @State private var validationState: ValidationState = .idle
    @State private var lastQuota: ReclaudeAPIService.ReclaudeQuotaResponse?
    @State private var currentCredentials: ProfileCredentials?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DesignTokens.Spacing.section) {
                SettingsPageHeader(
                    title: "reclaude.title".localized,
                    subtitle: "reclaude.subtitle".localized
                )

                statusCard

                // Show the login card only when there are no working
                // reclaude credentials yet — once connected the status card
                // covers state + a "Re-sign-in" inline button is enough.
                if currentCredentials?.hasReclaude != true {
                    loginCard
                }

                Spacer()
            }
            .padding()
        }
        .onAppear {
            loadCurrentCredentials()
            // Pre-fill email from a previous successful save so re-auth (after
            // a password change, for example) is just type-password-and-go.
            if let savedEmail = currentCredentials?.reclaudeEmail, !savedEmail.isEmpty {
                email = savedEmail
            }
        }
        .onChange(of: profileManager.activeProfile?.id) { _, _ in
            loadCurrentCredentials()
            resetForm()
            if let savedEmail = currentCredentials?.reclaudeEmail, !savedEmail.isEmpty {
                email = savedEmail
            }
        }
    }

    // MARK: - Status card

    private var statusCard: some View {
        HStack(spacing: DesignTokens.Spacing.medium) {
            Circle()
                .fill(currentCredentials?.hasReclaude == true ? Color.green : Color.secondary.opacity(0.4))
                .frame(width: DesignTokens.StatusDot.standard, height: DesignTokens.StatusDot.standard)

            VStack(alignment: .leading, spacing: DesignTokens.Spacing.extraSmall) {
                Text(currentCredentials?.hasReclaude == true ? "general.connected".localized : "general.not_connected".localized)
                    .font(DesignTokens.Typography.bodyMedium)

                if let creds = currentCredentials, creds.hasReclaude {
                    Text(maskKey(creds.reclaudeSessionCookie ?? ""))
                        .font(DesignTokens.Typography.captionMono)
                        .foregroundColor(.secondary)
                    if let email = creds.reclaudeEmail, !email.isEmpty {
                        Text(email)
                            .font(DesignTokens.Typography.caption)
                            .foregroundColor(.secondary)
                    }
                }
            }

            Spacer()

            if currentCredentials?.hasReclaude == true {
                Button(action: removeCredentials) {
                    HStack(spacing: DesignTokens.Spacing.extraSmall) {
                        Image(systemName: "trash")
                            .font(.system(size: DesignTokens.Icons.small))
                        Text("common.remove".localized)
                            .font(DesignTokens.Typography.body)
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.regular)
                .foregroundColor(.red)
            }
        }
        .padding(DesignTokens.Spacing.medium)
        .background(DesignTokens.Colors.cardBackground)
        .cornerRadius(DesignTokens.Radius.card)
        .overlay(
            RoundedRectangle(cornerRadius: DesignTokens.Radius.card)
                .strokeBorder(DesignTokens.Colors.cardBorder, lineWidth: 1)
        )
    }

    // MARK: - Login card

    private var loginCard: some View {
        // Single-layer flat card matching the rest of Settings — no internal
        // "configuration" step header / divider (this is a one-step form,
        // not a wizard). All sizing / spacing / colors come from
        // `DesignTokens` so the page reads as the same surface as
        // GeneralSettingsView, ClaudeCodeView, etc.
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.medium) {
            Text("reclaude.login_description".localized)
                .font(DesignTokens.Typography.body)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            TextField("reclaude.email".localized, text: $email)
                .textFieldStyle(.plain)
                .font(DesignTokens.Typography.body)
                .padding(10)
                .background(DesignTokens.Colors.inputBackground)
                .cornerRadius(DesignTokens.Radius.small)
                .overlay(
                    RoundedRectangle(cornerRadius: DesignTokens.Radius.small)
                        .strokeBorder(DesignTokens.Colors.cardBorder, lineWidth: 1)
                )
                .disabled(validationState.isValidating)
                .disableAutocorrection(true)

            SecureField("reclaude.password".localized, text: $password)
                .textFieldStyle(.plain)
                .font(DesignTokens.Typography.body)
                .padding(10)
                .background(DesignTokens.Colors.inputBackground)
                .cornerRadius(DesignTokens.Radius.small)
                .overlay(
                    RoundedRectangle(cornerRadius: DesignTokens.Radius.small)
                        .strokeBorder(DesignTokens.Colors.cardBorder, lineWidth: 1)
                )
                .disabled(validationState.isValidating)
                .onSubmit(login)

            Text("reclaude.password_keychain_info".localized)
                .font(DesignTokens.Typography.caption)
                .foregroundColor(.secondary)

            switch validationState {
            case .validating:
                HStack(spacing: DesignTokens.Spacing.extraSmall) {
                    ProgressView().controlSize(.small)
                    Text("wizard.testing".localized)
                        .font(DesignTokens.Typography.caption)
                        .foregroundColor(.secondary)
                }
            case .error(let message):
                Text(message)
                    .font(DesignTokens.Typography.caption)
                    .foregroundColor(.red)
                    .fixedSize(horizontal: false, vertical: true)
            case .success:
                HStack(spacing: DesignTokens.Spacing.extraSmall) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(.green)
                    if let q = lastQuota {
                        Text(String(format: "reclaude.test_success_with_amount".localized,
                                    q.usedUsd, q.quotaUsd))
                            .font(DesignTokens.Typography.caption)
                    } else {
                        Text("wizard.test_success".localized)
                            .font(DesignTokens.Typography.caption)
                    }
                }
                .foregroundColor(.green)
            case .idle:
                EmptyView()
            }

            Button(action: login) {
                HStack(spacing: DesignTokens.Spacing.extraSmall) {
                    if validationState.isValidating {
                        ProgressView().controlSize(.small)
                    }
                    Text("reclaude.signin_button".localized)
                        .font(DesignTokens.Typography.bodyMedium)
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.regular)
            .disabled(!canLogin)
        }
        .padding(DesignTokens.Spacing.cardPadding)
        .background(DesignTokens.Colors.cardBackground)
        .cornerRadius(DesignTokens.Radius.card)
        .overlay(
            RoundedRectangle(cornerRadius: DesignTokens.Radius.card)
                .strokeBorder(DesignTokens.Colors.cardBorder, lineWidth: 1)
        )
    }

    // MARK: - Helpers

    private var canLogin: Bool {
        !email.trimmingCharacters(in: .whitespaces).isEmpty
            && !password.isEmpty
            && !validationState.isValidating
    }

    private func loadCurrentCredentials() {
        guard let profile = profileManager.activeProfile else { return }
        currentCredentials = try? ProfileStore.shared.loadProfileCredentials(profile.id)
    }

    private func resetForm() {
        email = ""
        password = ""
        validationState = .idle
        lastQuota = nil
    }

    private func maskKey(_ key: String) -> String {
        guard key.count > 12 else { return "•••••••••" }
        let prefix = String(key.prefix(6))
        let suffix = String(key.suffix(4))
        return "\(prefix)•••••\(suffix)"
    }

    private func removeCredentials() {
        guard let profileId = profileManager.activeProfile?.id else { return }
        do {
            try profileManager.removeReclaudeCredentials(for: profileId)
            currentCredentials = nil
            resetForm()
        } catch {
            LoggingService.shared.logError("ReclaudeView: Failed to remove credentials", error: error)
        }
    }

    // MARK: - Login action

    private func login() {
        let trimmedEmail = email.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedEmail.isEmpty, !password.isEmpty else { return }
        guard let profile = profileManager.activeProfile else {
            validationState = .error("reclaude.error.no_profile".localized)
            return
        }
        // Stash password locally — we clear `password` from the form ASAP
        // (UI security) but still need the value for Keychain on success.
        let stashedPassword = password
        validationState = .validating
        lastQuota = nil

        Task {
            do {
                // Step 1: hit /api/auth/login for a fresh rc_sid.
                let result = try await ReclaudeAPIService.shared.login(email: trimmedEmail, password: stashedPassword)
                // Step 2: verify the cookie actually pulls carpool data.
                //         (Catches "logged in but org has no carpool" cases.)
                let quota = try await ReclaudeAPIService.shared.fetchCarpoolQuota(cookie: result.cookie)
                // Step 3: persist profile + Keychain on main actor.
                await MainActor.run {
                    do {
                        try persist(cookie: result.cookie, email: trimmedEmail, password: stashedPassword, profileId: profile.id)
                        lastQuota = quota
                        validationState = .success("")
                    } catch {
                        validationState = .error(error.localizedDescription)
                    }
                }
            } catch let err as AppError {
                await MainActor.run { validationState = .error(err.message) }
            } catch {
                await MainActor.run { validationState = .error(error.localizedDescription) }
            }
        }
    }

    private func persist(cookie: String, email: String, password: String, profileId: UUID) throws {
        var creds = try profileManager.loadCredentials(for: profileId)
        creds.reclaudeSessionCookie = ReclaudeAPIService.normalizeCookieValue(cookie)
        creds.reclaudeEmail = email
        creds.reclaudeAutoRefresh = true
        creds.reclaudeApiUrl = nil  // default URL is what we just verified
        try profileManager.saveCredentials(for: profileId, credentials: creds)

        try KeychainService.shared.saveReclaudePassword(password, profileId: profileId)

        // Clear sensitive form state and refresh the status card.
        self.password = ""
        loadCurrentCredentials()
        NotificationCenter.default.post(name: .credentialsChanged, object: nil)
    }
}
