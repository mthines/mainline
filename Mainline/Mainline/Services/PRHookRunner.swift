import Foundation

/// Impure shell for PR and issue hooks: turns poll events into agent launches, with a visible,
/// cancellable countdown. A hook is a prompt template with `on:` (see `PRHookEngine`).
extension PRManager {
    func handleHookEvents(_ events: [HookEvent]) async {
        guard !events.isEmpty else { return }
        let hooks = promptStore.templates.filter(PRHookEngine.isHook)
        guard !hooks.isEmpty, !isHookGateClosed(events.count, subject: "pr") else { return }   // no hooks: nothing to count
        let muted = settings.notifMutedNodeIds   // postponed PRs fire nothing
        let me = settings.githubUsername
        let live = events.filter { !muted.contains($0.pr.nodeId) }
        recordHookSkip("pr", reason: "muted", count: events.count - live.count)   // only Done-set events reach here postponed
        let launches = live.flatMap { event in
            hooks.filter { PRHookEngine.matches($0, event: event, myLogin: me) }.map { (hook: $0, event: event) }
        }
        recordHookMatching("pr", triggers: live.map { $0.trigger.rawValue },
                           matched: live.map { event in hooks.contains { PRHookEngine.matches($0, event: event, myLogin: me) } })
        guard !launches.isEmpty, await canCountDown(subject: "pr", count: launches.count) else { return }
        for (hook, event) in launches {
            guard hookThrottle.admit(key: PRHookEngine.Throttle.key(hook.fileName, event), now: Date()) else {
                TelemetryService.shared.recordHookDecision(subject: "pr", trigger: event.trigger.rawValue, decision: "throttled")
                continue
            }
            schedule(hook, for: event)
        }
    }

    /// Check hooks (flag `check-hooks`): templates with `on: check-failed` / `check-passed` and a `check:`.
    /// One launch per hook per check per PR, throttled per check name.
    func handleCheckHookEvents(_ events: [CheckHookEvent]) async {
        guard !events.isEmpty else { return }
        guard FeatureFlagRegistry.checkHooksEnabled else { recordHookSkip("check", reason: "flag_off", count: events.count); return }
        let hooks = promptStore.templates.filter(PRHookEngine.isCheckHook)
        guard !hooks.isEmpty, !isHookGateClosed(events.count, subject: "check") else { return }
        let me = settings.githubUsername
        let launches = events.flatMap { event in
            hooks.filter { PRHookEngine.matches($0, checkEvent: event, myLogin: me) }.map { (hook: $0, event: event) }
        }
        recordHookMatching("check", triggers: events.map { $0.trigger.rawValue },
                           matched: events.map { event in hooks.contains { PRHookEngine.matches($0, checkEvent: event, myLogin: me) } })
        guard !launches.isEmpty, await canCountDown(subject: "check", count: launches.count) else { return }
        for (hook, event) in launches {
            guard hookThrottle.admit(key: PRHookEngine.Throttle.key(hook.fileName, event), now: Date()) else {
                TelemetryService.shared.recordHookDecision(subject: "check", trigger: event.trigger.rawValue, decision: "throttled")
                continue
            }
            let pr = event.pr
            startCountdown(title: hook.name, body: "\(event.trigger.rawValue) \(event.check) on #\(pr.number) \(pr.title)",
                           url: pr.htmlUrl) { [weak self] id in
                self?.launchHook(hook, pr: pr, id: id, subject: "check",
                                 label: "\(hook.name) · \(pr.repoFullName)#\(pr.number)")
            }
        }
    }

    /// Issue hooks: templates whose `for:` covers issues, behind flag `issue-hooks`.
    func handleIssueHookEvents(_ events: [IssueHookEvent]) async {
        guard !events.isEmpty else { return }
        guard FeatureFlagRegistry.issueHooksEnabled else { recordHookSkip("issue", reason: "flag_off", count: events.count); return }
        let hooks = promptStore.templates.filter(PRHookEngine.isIssueHook)
        guard !hooks.isEmpty, !isHookGateClosed(events.count, subject: "issue") else { return }
        let muted = Set(settings.mutedIssueIds)
        let me = settings.githubUsername
        let live = events.filter { !muted.contains($0.issue.nodeId) }
        recordHookSkip("issue", reason: "muted", count: events.count - live.count)
        let launches = PRHookEngine.issueLaunches(hooks, events: live, myLogin: me)
        recordHookMatching("issue", triggers: live.map { $0.trigger.rawValue },
                           matched: live.map { event in hooks.contains { PRHookEngine.matches($0, issueEvent: event, myLogin: me) } })
        guard !launches.isEmpty, await canCountDown(subject: "issue", count: launches.count) else { return }
        for (hook, event) in launches {
            guard hookThrottle.admit(key: PRHookEngine.Throttle.key(hook.fileName, event), now: Date()) else {
                TelemetryService.shared.recordHookDecision(subject: "issue", trigger: event.trigger.rawValue, decision: "throttled")
                continue
            }
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
    private func canCountDown(subject: String, count: Int) async -> Bool {
        guard settings.hookCountdownSeconds > 0 else { return true }
        await refreshNotificationAuthorization()
        guard notificationAuthorization.canDeliverBanners else {
            TelemetryService.shared.recordHookDecision(subject: subject, trigger: nil, decision: "held",
                                                       reason: "notifications_off", count: count)
            showInfoToast("Hook skipped: notifications are off, so it couldn't be cancelled. Enable them, or set the countdown to 0.",
                          symbol: "bell.slash", seconds: 8)
            return false
        }
        return true
    }

    /// True (after counting it) when hooks are paused or the API is rate limited, so a user asking
    /// "why did nothing happen" can see how many events were dropped and why.
    private func isHookGateClosed(_ count: Int, subject: String) -> Bool {
        if settings.hooksPaused { recordHookSkip(subject, reason: "paused", count: count); return true }
        if RateLimitMonitor.shared.active != nil { recordHookSkip(subject, reason: "rate_limited", count: count); return true }
        return false
    }

    private func recordHookSkip(_ subject: String, reason: String, count: Int) {
        TelemetryService.shared.recordHookDecision(subject: subject, trigger: nil, decision: "skipped", reason: reason, count: count)
    }

    /// One decision per event: `matched` when some hook claims it, else `no_match`. `triggers[i]`
    /// and `matched[i]` describe the same event (trigger values are fixed enums).
    private func recordHookMatching(_ subject: String, triggers: [String], matched: [Bool]) {
        for (trigger, isMatched) in zip(triggers, matched) {
            TelemetryService.shared.recordHookDecision(subject: subject, trigger: trigger,
                                                       decision: isMatched ? "matched" : "no_match")
        }
    }

    func cancelHook(id: String) {
        guard let task = pendingHooks.removeValue(forKey: id) else { return }
        TelemetryService.shared.recordHookDecision(subject: nil, trigger: nil, decision: "cancelled")
        task.cancel()
        showInfoToast("Hook cancelled", symbol: "xmark.circle", seconds: 3)
    }

    private func schedule(_ hook: PromptTemplate, for event: HookEvent) {
        let pr = event.pr
        startCountdown(title: hook.name, body: "\(event.trigger.rawValue) on #\(pr.number) \(pr.title)", url: pr.htmlUrl) { [weak self] id in
            self?.launchHook(hook, pr: pr, id: id, subject: "pr", label: "\(hook.name) · \(pr.repoFullName)#\(pr.number)")
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

    private func launchHook(_ hook: PromptTemplate, pr: PRSnapshot, id: String, subject: String, label: String) {
        guard !settings.hooksPaused else { recordHookSkip(subject, reason: "paused", count: 1); return }
        let config = promptStore.config
        let template = PromptEngine.effective(hook, config: config)
        do {
            if let error = PromptEngine.blockingErrors(template, config: config).first { throw error }
            let target = PromptTarget(anchor: pr, members: [pr], wholeStack: false)
            let context = target.context
            let prompt = try PromptEngine.renderBody(template, context: context)
            let summary = try PromptLauncher.run(
                prompt: prompt, harnessKey: template.harness, checkout: false,   // never: parallel hooks would switch branches in one clone
                pr: pr, context: context, config: config, terminal: settings.promptTerminal)
            TelemetryService.shared.recordTriageInteraction("run_hook")
            TelemetryService.shared.recordAgentRun(origin: "hook", subject: subject, result: "success")
            notifications.postHook(id: id, title: "Hook started: \(hook.name)", body: summary, url: pr.htmlUrl, cancellable: false)
        } catch {
            TelemetryService.shared.recordAgentRun(origin: "hook", subject: subject, result: "failure",
                                                   errorType: PromptError.telemetryType(of: error))
            notifications.postHook(id: id, title: "Hook failed: \(label)", body: error.localizedDescription, url: pr.htmlUrl, cancellable: false)
        }
    }

    private func launchIssueHook(_ hook: PromptTemplate, event: IssueHookEvent, id: String, label: String) {
        guard !settings.hooksPaused else { recordHookSkip("issue", reason: "paused", count: 1); return }
        guard FeatureFlagRegistry.issueHooksEnabled else { recordHookSkip("issue", reason: "flag_off", count: 1); return }
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
            TelemetryService.shared.recordAgentRun(origin: "hook", subject: "issue", result: "success")
            notifications.postHook(id: id, title: "Hook started: \(hook.name)", body: summary, url: issue.url, cancellable: false)
        } catch {
            TelemetryService.shared.recordAgentRun(origin: "hook", subject: "issue", result: "failure",
                                                   errorType: PromptError.telemetryType(of: error))
            notifications.postHook(id: id, title: "Hook failed: \(label)", body: error.localizedDescription, url: issue.url, cancellable: false)
        }
    }
}
