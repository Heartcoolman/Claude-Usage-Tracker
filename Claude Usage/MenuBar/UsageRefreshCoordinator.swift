//
//  UsageRefreshCoordinator.swift
//  Claude Usage
//
//  Created by Claude Code on 2025-12-20.
//

import Foundation
import Combine

/// Coordinates usage data refresh from API services
final class UsageRefreshCoordinator {
    private var refreshTimer: Timer?
    private var refreshIntervalObserver: NSKeyValueObservation?

    private let apiService: APIServiceProtocol
    private let statusService: ClaudeStatusService
    private let dataStore: StorageProvider
    private let notificationService: NotificationServiceProtocol

    weak var delegate: UsageRefreshCoordinatorDelegate?

    // MARK: - Initialization

    init(
        apiService: APIServiceProtocol = ClaudeAPIService(),
        statusService: ClaudeStatusService = ClaudeStatusService(),
        dataStore: StorageProvider = DataStore.shared,
        notificationService: NotificationServiceProtocol = NotificationManager.shared
    ) {
        self.apiService = apiService
        self.statusService = statusService
        self.dataStore = dataStore
        self.notificationService = notificationService
    }

    // MARK: - Lifecycle

    func start() {
        startAutoRefresh()
        observeRefreshIntervalChanges()
        LoggingService.shared.logInfo("Usage refresh coordinator started")
    }

    func stop() {
        refreshTimer?.invalidate()
        refreshTimer = nil
        refreshIntervalObserver?.invalidate()
        refreshIntervalObserver = nil
        LoggingService.shared.logInfo("Usage refresh coordinator stopped")
    }

    // MARK: - Refresh Logic

    func refreshUsage() {
        Task {
            // Fetch usage and status in parallel
            async let usageResult = apiService.fetchUsageData()
            async let statusResult = statusService.fetchStatus()

            do {
                let newUsage = try await usageResult

                await MainActor.run {
                    dataStore.saveUsage(newUsage)
                    delegate?.usageRefreshDidComplete(usage: newUsage)
                    notificationService.checkAndNotify(usage: newUsage)
                }
            } catch {
                LoggingService.shared.logAPIError("fetchUsageData", error: error)
            }

            // Fetch status separately (don't fail if usage fetch works)
            do {
                let newStatus = try await statusResult
                await MainActor.run {
                    delegate?.statusRefreshDidComplete(status: newStatus)
                }
            } catch {
                LoggingService.shared.logAPIError("fetchStatus", error: error)
            }

            // Fetch API usage if credentials are available
            if let apiSessionKey = dataStore.loadAPISessionKey(),
               let orgId = dataStore.loadAPIOrganizationId() {
                do {
                    let newAPIUsage = try await apiService.fetchAPIUsageData(organizationId: orgId, apiSessionKey: apiSessionKey)
                    await MainActor.run {
                        dataStore.saveAPIUsage(newAPIUsage)
                        delegate?.apiUsageRefreshDidComplete(apiUsage: newAPIUsage)
                    }
                } catch {
                    LoggingService.shared.logAPIError("fetchAPIUsageData", error: error)
                }
            }

            // Fetch reclaude.ai carpool quota if the active profile has rc_sid.
            // `fetchWithAutoRefresh` is @MainActor — it owns ProfileManager
            // reads/writes (including the cookie rotation on 401) so the
            // refresh path stays serialized with the rest of profile state.
            let reclaudeProfile = await MainActor.run { () -> (UUID, String, NotificationSettings)? in
                guard let p = ProfileManager.shared.activeProfile, p.hasReclaude else { return nil }
                return (p.id, p.name, p.notificationSettings)
            }
            if let (profileId, profileName, notifSettings) = reclaudeProfile {
                do {
                    let newReclaude = try await ReclaudeAPIService.shared.fetchWithAutoRefresh(profileId: profileId)
                    await MainActor.run {
                        DataStore.shared.saveReclaudeUsage(newReclaude)
                        ProfileManager.shared.saveReclaudeUsage(newReclaude, for: profileId)
                        delegate?.reclaudeUsageRefreshDidComplete(usage: newReclaude)
                        NotificationManager.shared.checkAndNotify(
                            reclaude: newReclaude,
                            profileName: profileName,
                            settings: notifSettings
                        )
                    }
                } catch let err as AppError where err.code == .reclaudeCooldownActive {
                    // Expected during the 5-min back-off after a failed login.
                    LoggingService.shared.log("Reclaude refresh skipped — cooldown active")
                } catch {
                    LoggingService.shared.logAPIError("fetchReclaudeUsage", error: error)
                }
            }
        }
    }

    // MARK: - Timer Management

    private func startAutoRefresh() {
        let interval = dataStore.loadRefreshInterval()
        refreshTimer?.invalidate()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            self?.refreshUsage()
        }
        LoggingService.shared.logInfo("Auto-refresh started with interval: \(interval)s")
    }

    private func observeRefreshIntervalChanges() {
        // Observe using DataStore.shared directly for KVO
        refreshIntervalObserver = DataStore.shared.userDefaults.observe(\.refreshIntervalValue, options: [.new]) { [weak self] _, change in
            if let newInterval = change.newValue, newInterval > 0 {
                self?.startAutoRefresh()
                LoggingService.shared.logInfo("Refresh interval changed to: \(newInterval)s")
            }
        }
    }
}

// MARK: - UserDefaults Extension for KVO

private extension UserDefaults {
    @objc var refreshIntervalValue: Double {
        return double(forKey: Constants.UserDefaultsKeys.refreshInterval)
    }
}

// MARK: - Delegate Protocol

protocol UsageRefreshCoordinatorDelegate: AnyObject {
    func usageRefreshDidComplete(usage: ClaudeUsage)
    func statusRefreshDidComplete(status: ClaudeStatus)
    func apiUsageRefreshDidComplete(apiUsage: APIUsage)
    func reclaudeUsageRefreshDidComplete(usage: ReclaudeUsage)
}

// NOTE: as of writing, `UsageRefreshCoordinator` is not instantiated
// anywhere — `MenuBarManager` runs its own inline refresh loop. If you
// wire this coordinator up, the adopter MUST repaint the menu bar icons
// inside `reclaudeUsageRefreshDidComplete` (the session icon repurposes
// reclaude USD% when the carpool is active), otherwise the icon will go
// stale on reclaude-only changes.
extension UsageRefreshCoordinatorDelegate {
    func reclaudeUsageRefreshDidComplete(usage: ReclaudeUsage) {}
}
