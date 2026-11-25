import Foundation

/// Impure shell for PR and issue hooks: turns poll events into agent launches, with a visible,
/// cancellable countdown. A hook is a prompt template with `on:` (see `PRHookEngine`).
extension PRManager {
    func handleHookEvents(_ events: [HookEvent]) async {
        guard !settings.hooksPaused, RateLimitMonitor.shared.active == nil else { return }
        let hooks = promptStore.templates.filter(PRHookEngine.isHook)
        guard !hooks.isEmpty else { return }
        let muted = settings.notifMutedNodeIds   // postponed PRs fire nothing
        let me = settings.githubUsername
        let launches = events.filter { !muted.contains($0.pr.nodeId) }.flatMap { event in
            hooks.filter { PRHookEngine.matches($0, event: event, myLogin: me) }.map { (hook: $0, event: event) }
        }
        guard !launches.isEmpty, await canCountDown() else { return }
        for (hook, event) in launches {
            guard hookThrottle.admit(key: PRHookEngine.Throttle.key(hook.fileName, event), now: Date()) else { continue }
            schedule(hook, for: event)
        }
    }

    /// Issue hooks: templates whose `for:` covers issues, behind flag `issue-hooks`.
    func handleIssueHookEvents(_ events: [IssueHookEvent]) async {
        guard FeatureFlagRegistry.issueHooksEnabled, !settings.hooksPaused, RateLimitMonitor.shared.active == nil else { return }
        let hooks = promptStore.templates.filter(PRHookEngine.isIssueHook)
        guard !hooks.isEmpty else { return }
        let muted = Set(settings.mutedIssueIds)
        let me = settings.githubUsername
        let launches = events.filter { !muted.contains($0.issue.nodeId) }.flatMap { event in
            hooks.filter { PRHookEngine.matches($0, issueEvent: event, myLogin: me) }.map { (hook: $0, event: event) }
        }
        guard !launches.isEmpty, await canCountDown() else { return }
        for (hook, event) in launches {
            guard hookThrottle.admit(key: PRHookEngine.Throttle.key(hook.fileName, event), now: Date()) else { continue }
            let issue = event.issue
            startCountdown(title: hook.name, body: "\(event.trigger.rawValue) on #\(issue.number) \(issue.title)",
                           url: issue.url) { [weak self] id in
                self?.launchIssueHook(hook, event: event, id: id, label: "\(hook.name) · \(issue.repoFullName)#\(issue.number)")
            }
        }
    }

    /// The countdown's only Cancel button is on the macOS notification. With banners off a hook
    /// would start an agent nobody can stop, so hold it (and say why) rather than launch blind.
    /// Re-reads the state: the user may have turned banners off since launch.
    private func canCountDown() async -> Bool {
        guard settings.hookCountdownSeconds > 0 else { return true }
        await refreshNotificationAuthorization()
        guard notificationAuthorization.canDeliverBanners else {
            showInfoToast("Hook skipped: notifications are off, so it couldn't be cancelled. Enable them, or set the countdown to 0.",
                          symbol: "bell.slash", seconds: 8)
            return false
        }
        return true
    }

    func cancelHook(id: String) {
        guard let task = pendingHooks.removeValue(forKey: id) else { return }
        task.cancel()
        showInfoToast("Hook cancelled", symbol: "xmark.circle", seconds: 3)
    }

    private func schedule(_ hook: PromptTemplate, for event: HookEvent) {
        let pr = event.pr
        startCountdown(title: hook.name, body: "\(event.trigger.rawValue) on #\(pr.number) \(pr.title)", url: pr.htmlUrl) { [weak self] id in
            self?.launchHook(hook, event: event, id: id, label: "\(hook.name) · \(pr.repoFullName)#\(pr.number)")
        }
    }

    /// Posts the cancellable countdown banner, then calls `launch` with the hook-run id unless cancelled.
    private func startCountdown(title: String, body: String, url: String, launch: @escaping @MainActor (String) -> Void) {
        let id = "mainline.hook.\(UUID().uuidString)"
        let seconds = max(0, settings.hookCountdownSeconds)
        if seconds > 0 {
            notifications.postHook(id: id, title: "Hook starts in \(seconds)s: \(title)", body: body, url: url, cancellable: true)
        }
        pendingHooks[id] = Task { [weak self] in
            if seconds > 0 { try? await Task.sleep(nanoseconds: UInt64(seconds) * 1_000_000_000) }
            guard let self, !Task.isCancelled else { return }
            self.pendingHooks[id] = nil
            launch(id)
        }
    }

    private func launchHook(_ hook: PromptTemplate, event: HookEvent, id: String, label: String) {
        guard !settings.hooksPaused else { return }
        let config = promptStore.config
        let template = PromptEngine.effective(hook, config: config)
        do {
            if let error = PromptEngine.blockingErrors(template, config: config).first { throw error }
            let target = PromptTarget(anchor: event.pr, members: [event.pr], wholeStack: false)
            let context = target.context
            let prompt = try PromptEngine.renderBody(template, context: context)
            let summary = try PromptLauncher.run(
                prompt: prompt, harnessKey: template.harness, checkout: false,   // never: parallel hooks would switch branches in one clone
                pr: event.pr, context: context, config: config, terminal: settings.promptTerminal)
            TelemetryService.shared.recordTriageInteraction("run_hook")
            notifications.postHook(id: id, title: "Hook started: \(hook.name)", body: summary, url: event.pr.htmlUrl, cancellable: false)
        } catch {
            notifications.postHook(id: id, title: "Hook failed: \(label)", body: error.localizedDescription, url: event.pr.htmlUrl, cancellable: false)
        }
    }

    private func launchIssueHook(_ hook: PromptTemplate, event: IssueHookEvent, id: String, label: String) {
        guard !settings.hooksPaused, FeatureFlagRegistry.issueHooksEnabled else { return }
        let config = promptStore.config
        let template = PromptEngine.effective(hook, config: config)
        let issue = event.issue
        do {
            if let error = PromptEngine.blockingErrors(template, config: config).first { throw error }
            let target = PromptTarget(issues: [event.issue])
            let context = target.context
            let prompt = try PromptEngine.renderBody(template, context: context)
            let summary = try PromptLauncher.run(
                prompt: prompt, harnessKey: template.harness, checkout: false,   // an issue has no branch to check out
                repo: issue.repoFullName, context: context, config: config, terminal: settings.promptTerminal)
            TelemetryService.shared.recordTriageInteraction("run_hook_issue")
            notifications.postHook(id: id, title: "Hook started: \(hook.name)", body: summary, url: issue.url, cancellable: false)
        } catch {
            notifications.postHook(id: id, title: "Hook failed: \(label)", body: error.localizedDescription, url: issue.url, cancellable: false)
        }
    }
}
