import Foundation

/// Impure shell for PR hooks: turns poll events into agent launches, with a visible,
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
        guard !launches.isEmpty else { return }

        // The countdown's only Cancel button is on the macOS notification. With banners off a hook
        // would start an agent nobody can stop, so hold it (and say why) rather than launch blind.
        // Re-read the state: the user may have turned banners off since launch.
        if settings.hookCountdownSeconds > 0 {
            await refreshNotificationAuthorization()
            guard notificationAuthorization.canDeliverBanners else {
                showInfoToast("Hook skipped: notifications are off, so it couldn't be cancelled. Enable them, or set the countdown to 0.",
                              symbol: "bell.slash", seconds: 8)
                return
            }
        }
        for (hook, event) in launches {
            guard hookThrottle.admit(key: PRHookEngine.Throttle.key(hook.fileName, event), now: Date()) else { continue }
            schedule(hook, for: event)
        }
    }

    func cancelHook(id: String) {
        guard let task = pendingHooks.removeValue(forKey: id) else { return }
        task.cancel()
        showInfoToast("Hook cancelled", symbol: "xmark.circle", seconds: 3)
    }

    private func schedule(_ hook: PromptTemplate, for event: HookEvent) {
        let id = "mainline.hook.\(UUID().uuidString)"
        let pr = event.pr
        let label = "\(hook.name) · \(pr.repoFullName)#\(pr.number)"
        let seconds = max(0, settings.hookCountdownSeconds)
        if seconds > 0 {
            notifications.postHook(id: id, title: "Hook starts in \(seconds)s: \(hook.name)",
                                   body: "\(event.trigger.rawValue) on #\(pr.number) \(pr.title)", url: pr.htmlUrl, cancellable: true)
        }
        pendingHooks[id] = Task { [weak self] in
            if seconds > 0 { try? await Task.sleep(nanoseconds: UInt64(seconds) * 1_000_000_000) }
            guard let self, !Task.isCancelled else { return }
            self.pendingHooks[id] = nil
            self.launchHook(hook, event: event, id: id, label: label)
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
}
