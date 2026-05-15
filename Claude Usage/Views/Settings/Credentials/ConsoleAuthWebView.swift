//
//  ConsoleAuthWebView.swift
//  Claude Usage
//
//  Created by Claude Code on 2026-03-01.
//

import SwiftUI
import WebKit
import Combine

// MARK: - Cookie Result

struct ConsoleCookieResult {
    let sessionKey: String
    let expiryDate: Date?
}

// MARK: - Sheet Controller

/// Bridge between `ConsoleAuthSheet`'s header buttons and the underlying
/// `WKWebView` Coordinator. Lets the sheet ask the Coordinator to capture
/// the current cookie immediately ("Done" button) as a fallback when the
/// URL/debounce-based finalization heuristic doesn't fire.
final class ConsoleAuthSheetController: ObservableObject {
    fileprivate var finalize: (() -> Void)?
    func requestFinalize() { finalize?() }
}

// MARK: - WKWebView Wrapper

struct ConsoleAuthWebView: NSViewRepresentable {
    let loginURL: URL
    let cookieDomain: String
    /// Name of the cookie to wait for. Default `sessionKey` for claude.ai /
    /// Anthropic Console; reclaude.ai uses `rc_sid`.
    var cookieName: String = "sessionKey"
    var controller: ConsoleAuthSheetController? = nil
    let onCookieFound: (ConsoleCookieResult) -> Void

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()
        config.preferences.javaScriptCanOpenWindowsAutomatically = true

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        webView.uiDelegate = context.coordinator
        context.coordinator.parentWebView = webView
        context.coordinator.startObservingCookies(for: config.websiteDataStore)

        // Wire the optional sheet "Done" button to the coordinator.
        if let controller = controller {
            controller.finalize = { [weak coordinator = context.coordinator] in
                coordinator?.userRequestedFinalize()
            }
        }

        // Clear cookies for the target domain (plus claude/anthropic, since
        // those frequently grant SSO into both) so the user always sees a
        // fresh login form. Google cookies stay so SSO popups work.
        let targetDomain = self.cookieDomain
        let cookieStore = config.websiteDataStore.httpCookieStore
        cookieStore.getAllCookies { cookies in
            let group = DispatchGroup()
            for cookie in cookies where cookie.domain.contains(targetDomain)
                || cookie.domain.contains("claude")
                || cookie.domain.contains("anthropic") {
                group.enter()
                cookieStore.delete(cookie) { group.leave() }
            }
            group.notify(queue: .main) {
                webView.load(URLRequest(url: self.loginURL))
            }
        }

        return webView
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(cookieDomain: cookieDomain, cookieName: cookieName, onCookieFound: onCookieFound)
    }

    class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate, WKHTTPCookieStoreObserver {
        let cookieDomain: String
        let cookieName: String
        let onCookieFound: (ConsoleCookieResult) -> Void
        private var foundCookie = false
        /// Most-recently-observed cookie value. We don't latch on the first
        /// match — reclaude.ai rotates `rc_sid` once more after the dashboard
        /// loads (anti-session-fixation), so the first cookie we see is the
        /// short-lived pre-rotation one that the server immediately discards.
        /// Track the latest value and finalize only after the WebView has left
        /// the login URL and a short debounce window has elapsed.
        private var latestCookieValue: String?
        private var latestCookieExpiry: Date?
        private var pendingFinalizeWorkItem: DispatchWorkItem?
        /// Time the WKWebView most recently left the /login URL — used to
        /// gate finalization until at least one post-login navigation has settled.
        private var leftLoginPageAt: Date?
        weak var parentWebView: WKWebView?
        private var popupWindow: NSWindow?
        private var popupWebView: WKWebView?

        /// How long to wait after leaving /login before finalizing. Buys time
        /// for the dashboard's first XHR to provoke a cookie rotation.
        private let postLoginSettleDelay: TimeInterval = 1.5

        init(cookieDomain: String, cookieName: String, onCookieFound: @escaping (ConsoleCookieResult) -> Void) {
            self.cookieDomain = cookieDomain
            self.cookieName = cookieName
            self.onCookieFound = onCookieFound
        }

        func startObservingCookies(for dataStore: WKWebsiteDataStore) {
            dataStore.httpCookieStore.add(self)
        }

        // WKHTTPCookieStoreObserver — fires whenever any cookie changes
        func cookiesDidChange(in cookieStore: WKHTTPCookieStore) {
            guard !foundCookie else { return }
            cookieStore.getAllCookies { [weak self] cookies in
                guard let self = self, !self.foundCookie else { return }
                // DEBUG: dump every cookie matching the auth domain so we can
                // confirm whether companion cookies (csrf / refresh) get set.
                Self.debugDump(label: "cookiesDidChange", cookies: cookies, matching: self.cookieDomain)
                for cookie in cookies {
                    if cookie.name == self.cookieName && cookie.domain.contains(self.cookieDomain) {
                        // Always update — latching here is what caused reclaude.ai
                        // to fail (we kept the pre-rotation cookie).
                        self.latestCookieValue = cookie.value
                        self.latestCookieExpiry = cookie.expiresDate
                        DispatchQueue.main.async { [weak self] in
                            self?.scheduleFinalizeIfReady()
                        }
                        return
                    }
                }
            }
        }

        /// Temporary diagnostic helper — writes every cookie matching `domainFragment`
        /// to /tmp/reclaude-auth-debug.log so we can audit what the server
        /// actually sets during login. Remove once auth issue is solved.
        private static func debugDump(label: String, cookies: [HTTPCookie], matching domainFragment: String) {
            let matched = cookies.filter { $0.domain.contains(domainFragment) }
            guard !matched.isEmpty else { return }
            let ts = ISO8601DateFormatter().string(from: Date())
            let lines = matched.map { c -> String in
                let v = c.value
                let truncated = v.count > 24 ? "\(v.prefix(8))…(\(v.count) chars)…\(v.suffix(8))" : v
                let expiry = c.expiresDate.map { ISO8601DateFormatter().string(from: $0) } ?? "(session)"
                return "  name=\(c.name) domain=\(c.domain) path=\(c.path) secure=\(c.isSecure) httpOnly=\(c.isHTTPOnly) sameSite=\(c.sameSitePolicy?.rawValue ?? "nil") expires=\(expiry) value=\(truncated)"
            }
            let entry = "[\(ts)] \(label)\n" + lines.joined(separator: "\n") + "\n\n"
            if let data = entry.data(using: .utf8) {
                let url = URL(fileURLWithPath: "/tmp/reclaude-auth-debug.log")
                if let handle = try? FileHandle(forWritingTo: url) {
                    defer { try? handle.close() }
                    _ = try? handle.seekToEnd()
                    try? handle.write(contentsOf: data)
                } else {
                    try? data.write(to: url)
                }
            }
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            guard !foundCookie else { return }
            // Track when the WebView leaves the login page — that's our signal
            // the auth roundtrip has completed and the dashboard is loading.
            if let url = webView.url, !url.absoluteString.contains("/login") {
                if leftLoginPageAt == nil { leftLoginPageAt = Date() }
            }
            checkForSessionCookie(in: webView)
            scheduleFinalizeIfReady()
        }

        /// User-triggered "I'm signed in" escape hatch from the sheet header.
        /// Bypasses the URL/debounce gate and captures the current cookie.
        func userRequestedFinalize() {
            guard !foundCookie else { return }
            guard let webView = parentWebView ?? popupWebView else { return }
            webView.configuration.websiteDataStore.httpCookieStore.getAllCookies { [weak self] cookies in
                guard let self = self, !self.foundCookie else { return }
                if let cookie = cookies.first(where: { $0.name == self.cookieName && $0.domain.contains(self.cookieDomain) }) {
                    self.latestCookieValue = cookie.value
                    self.latestCookieExpiry = cookie.expiresDate
                }
                self.finalizeNow()
            }
        }

        /// Schedule a finalize attempt after `postLoginSettleDelay`. Repeated
        /// calls reset the timer so the most recent rotation always wins.
        private func scheduleFinalizeIfReady() {
            guard !foundCookie else { return }
            guard latestCookieValue != nil else { return }
            // Require navigation off /login first (or popup-flow Google SSO).
            // If the URL filter has been tripped we've cleared this gate.
            guard leftLoginPageAt != nil else { return }

            pendingFinalizeWorkItem?.cancel()
            let work = DispatchWorkItem { [weak self] in
                self?.finalizeNow()
            }
            pendingFinalizeWorkItem = work
            DispatchQueue.main.asyncAfter(deadline: .now() + postLoginSettleDelay, execute: work)
        }

        private func finalizeNow() {
            guard !foundCookie else { return }
            guard let value = latestCookieValue, !value.isEmpty else { return }
            foundCookie = true
            pendingFinalizeWorkItem?.cancel()
            let result = ConsoleCookieResult(
                sessionKey: value,
                expiryDate: latestCookieExpiry
            )
            DispatchQueue.main.async { [weak self] in
                self?.onCookieFound(result)
            }
        }

        func webView(
            _ webView: WKWebView,
            createWebViewWith configuration: WKWebViewConfiguration,
            for navigationAction: WKNavigationAction,
            windowFeatures: WKWindowFeatures
        ) -> WKWebView? {
            // Create a real popup WKWebView using the provided configuration
            // (preserves window.opener linkage and shared cookies for Google SSO)
            let popup = WKWebView(
                frame: CGRect(x: 0, y: 0, width: 500, height: 600),
                configuration: configuration
            )
            popup.navigationDelegate = self
            popup.uiDelegate = self

            let panel = NSPanel(
                contentRect: CGRect(x: 0, y: 0, width: 500, height: 600),
                styleMask: [.titled, .closable, .resizable],
                backing: .buffered,
                defer: false
            )
            panel.contentView = popup
            panel.title = "Sign In"
            panel.center()
            panel.makeKeyAndOrderFront(nil)

            self.popupWindow = panel
            self.popupWebView = popup

            return popup
        }

        // Handle window.close() from Google SSO popup after auth completes
        func webViewDidClose(_ webView: WKWebView) {
            if webView === popupWebView {
                popupWindow?.close()
                popupWindow = nil
                popupWebView = nil
            }
        }

        private func checkForSessionCookie(in webView: WKWebView) {
            webView.configuration.websiteDataStore.httpCookieStore.getAllCookies { [weak self] cookies in
                guard let self = self, !self.foundCookie else { return }
                let urlStr = (webView.url?.absoluteString) ?? "(no url)"
                Self.debugDump(label: "didFinish url=\(urlStr)", cookies: cookies, matching: self.cookieDomain)
                for cookie in cookies {
                    if cookie.name == self.cookieName && cookie.domain.contains(self.cookieDomain) {
                        // Refresh the latest cookie snapshot on each navigation —
                        // actual finalize is gated by URL + debounce.
                        self.latestCookieValue = cookie.value
                        self.latestCookieExpiry = cookie.expiresDate
                        return
                    }
                }
            }
        }
    }
}

// MARK: - Auth Sheet

struct ConsoleAuthSheet: View {
    let title: String
    let loginURL: URL
    let cookieDomain: String
    var cookieName: String = "sessionKey"
    let onSuccess: (ConsoleCookieResult) -> Void
    let onCancel: () -> Void

    @State private var isLoading = true
    @State private var hasError = false
    @StateObject private var controller = ConsoleAuthSheetController()

    var body: some View {
        VStack(spacing: 0) {
            // Title bar
            HStack {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                Button("common.done".localized) {
                    controller.requestFinalize()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .help("auth.sheet.done_help".localized)
                Button("common.cancel".localized) {
                    onCancel()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)

            Divider()

            // WebView
            ConsoleAuthWebView(
                loginURL: loginURL,
                cookieDomain: cookieDomain,
                cookieName: cookieName,
                controller: controller
            ) { result in
                onSuccess(result)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(width: 520, height: 680)
    }
}
