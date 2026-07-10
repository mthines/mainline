import Foundation
import CryptoKit
import IOKit
import OpenTelemetryApi
import OpenTelemetrySdk
import OpenTelemetryProtocolExporterHttp

/// Anonymous, opt-in telemetry service using OpenTelemetry.
///
/// All methods are no-ops unless `MainlineSettings.telemetryEnabled` is true.
/// No personal data is collected — only bounded, low-cardinality values:
/// action types, counts, durations, error categories, and operational events.
///
/// ## Signal overview
/// - **Traces**: Poll lifecycle spans with real duration (start → complete/fail)
/// - **Metrics**: Poll counters + histograms, write action counters, triage interaction counters,
///               notification counters, shortcut/token counters
/// - **Logs**: Structured log records for key lifecycle events
///
/// ## User correlation
/// - `service.instance.id` — random UUID per install (changes on reinstall) from MainlineSettings.installationId
/// - `enduser.id` — HMAC-SHA256 of hardware UUID (stable across reinstalls, not reversible)
///
/// ## Swift SDK note
/// opentelemetry-swift 1.17.1 requires a wildcard `registerView(name: ".*")` for the
/// stable metrics API. Without it, instruments silently record to no-op storage.
/// See: https://github.com/open-telemetry/opentelemetry-swift/issues/500
final class TelemetryService {
    static let shared = TelemetryService()

    // MARK: - Configuration

    private static let config: [String: String] = {
        var env: [String: String] = [:]
        // 3. Info.plist (lowest priority — embedded at build time)
        if let token = Bundle.main.object(forInfoDictionaryKey: "Dash0AuthToken") as? String,
           !token.isEmpty {
            env["DASH0_AUTH_TOKEN"] = token
        }
        if let endpoint = Bundle.main.object(forInfoDictionaryKey: "OTelExporterEndpoint") as? String,
           !endpoint.isEmpty {
            env["OTEL_EXPORTER_OTLP_ENDPOINT"] = endpoint
        }
        // 2. .env file overrides Info.plist
        for (key, value) in loadDotEnv() {
            env[key] = value
        }
        // 1. Process environment overrides everything
        for (key, value) in ProcessInfo.processInfo.environment {
            env[key] = value
        }
        return env
    }()

    private static let endpoint: String = {
        config["OTEL_EXPORTER_OTLP_ENDPOINT"]
            ?? "https://ingress.us-east-2.aws.dash0.com"
    }()

    private static let serviceName: String = {
        config["OTEL_SERVICE_NAME"] ?? "mainline"
    }()

    private static let authHeaders: [(String, String)] = {
        if let raw = config["OTEL_EXPORTER_OTLP_HEADERS"], !raw.isEmpty {
            return raw.split(separator: ",").compactMap { pair in
                let parts = pair.split(separator: "=", maxSplits: 1)
                guard parts.count == 2 else { return nil }
                return (String(parts[0]).trimmingCharacters(in: .whitespaces),
                        String(parts[1]).trimmingCharacters(in: .whitespaces))
            }
        }
        if let token = config["DASH0_AUTH_TOKEN"],
           !token.isEmpty, token != "YOUR_AUTH_TOKEN" {
            return [("Authorization", "Bearer \(token)")]
        }
        return []
    }()

    // MARK: - Metric Instruments

    private var pollDurationHistogram: DoubleHistogramMeterSdk?
    private var pollEtagHitsCounter: LongCounterSdk?
    private var pollErrorsCounter: LongCounterSdk?
    private var appLaunchCounter: LongCounterSdk?
    private var writeActionsCounter: LongCounterSdk?
    private var triageInteractionsCounter: LongCounterSdk?
    private var notificationsFiredCounter: LongCounterSdk?
    private var notificationsSuppressedCounter: LongCounterSdk?
    private var globalShortcutCounter: LongCounterSdk?
    private var tokenInvalidCounter: LongCounterSdk?
    private var settingChangedCounter: LongCounterSdk?
    private var attentionPolicyChangedCounter: LongCounterSdk?

    // MARK: - Providers (kept alive for shutdown)

    private var meterProvider: StableMeterProviderSdk?
    private var tracerProvider: TracerProviderSdk?
    private var loggerProvider: LoggerProviderSdk?

    // MARK: - Tracer & Logger

    private var tracer: (any Tracer)?
    private var logger: (any OpenTelemetryApi.Logger)?

    // MARK: - Active Spans

    /// Keyed by query string (author/reviewer query) for real poll duration tracking.
    private var activePollSpans: [String: any Span] = [:]

    /// Session span — covers the full app lifecycle from launch to terminate.
    private var sessionSpan: (any Span)?

    // MARK: - Heartbeat timer

    private var heartbeatTimer: Timer?

    // MARK: - Init

    private init() {}

    // MARK: - Setup

    /// Call once at app startup when telemetry is enabled.
    /// Also called from `MainlineSettings.telemetryEnabled.didSet` on enable.
    func configure() {
        guard MainlineSettings.shared.telemetryEnabled else { return }
        setupOTel()
    }

    private func setupOTel() {
        guard meterProvider == nil else { return }
        guard !Self.authHeaders.isEmpty else {
            print("[Mainline][Telemetry] No auth headers — telemetry will not emit.")
            return
        }

        let resource = buildResource()

        // MARK: Metrics — stable API (wildcard view required for 1.17.1)

        let metricsEndpoint = URL(string: "\(Self.endpoint)/v1/metrics")!
        let metricsExporter = StableOtlpHTTPMetricExporter(
            endpoint: metricsEndpoint,
            aggregationTemporalitySelector: AggregationTemporality.deltaPreferred(),
            envVarHeaders: Self.authHeaders
        )
        let metricReader = StablePeriodicMetricReaderBuilder(exporter: metricsExporter)
            .setInterval(timeInterval: 30)
            .build()
        let stableMeterProvider = StableMeterProviderSdk.builder()
            .setResource(resource: resource)
            .registerView(
                selector: InstrumentSelector.builder().setInstrument(name: ".*").build(),
                view: StableView.builder().build()
            )
            .registerMetricReader(reader: metricReader)
            .build()
        meterProvider = stableMeterProvider
        OpenTelemetry.registerStableMeterProvider(meterProvider: stableMeterProvider)
        print("[Mainline][Telemetry] metrics exporter configured → \(metricsEndpoint)")

        // MARK: Traces

        let tracesEndpoint = URL(string: "\(Self.endpoint)/v1/traces")!
        let tracesExporter = OtlpHttpTraceExporter(
            endpoint: tracesEndpoint,
            envVarHeaders: Self.authHeaders
        )
        let spanProcessor = BatchSpanProcessor(spanExporter: tracesExporter)
        let tracerProviderSdk = TracerProviderBuilder()
            .with(resource: resource)
            .add(spanProcessor: spanProcessor)
            .build()
        tracerProvider = tracerProviderSdk
        OpenTelemetry.registerTracerProvider(tracerProvider: tracerProviderSdk)
        tracer = tracerProviderSdk.get(instrumentationName: Self.serviceName)

        // MARK: Logs

        let logsEndpoint = URL(string: "\(Self.endpoint)/v1/logs")!
        let logsExporter = OtlpHttpLogExporter(
            endpoint: logsEndpoint,
            envVarHeaders: Self.authHeaders
        )
        let logProcessor = BatchLogRecordProcessor(logRecordExporter: logsExporter)
        let loggerProviderSdk = LoggerProviderBuilder()
            .with(resource: resource)
            .with(processors: [logProcessor])
            .build()
        loggerProvider = loggerProviderSdk
        OpenTelemetry.registerLoggerProvider(loggerProvider: loggerProviderSdk)
        logger = loggerProviderSdk
            .loggerBuilder(instrumentationScopeName: Self.serviceName)
            .build()

        // MARK: Build metric instruments

        let meter = stableMeterProvider.get(name: Self.serviceName)

        pollDurationHistogram = meter
            .histogramBuilder(name: "mainline.poll.duration")
            .setDescription("Duration of poll operations in seconds")
            .setUnit("s")
            .build()

        pollEtagHitsCounter = meter
            .counterBuilder(name: "mainline.poll.etag_hits")
            .setDescription("Number of 304 Not Modified poll responses")
            .setUnit("1")
            .build()

        pollErrorsCounter = meter
            .counterBuilder(name: "mainline.poll.errors")
            .setDescription("Number of poll errors by category")
            .setUnit("1")
            .build()

        appLaunchCounter = meter
            .counterBuilder(name: "mainline.app.launch")
            .setDescription("Number of app launches")
            .setUnit("1")
            .build()

        writeActionsCounter = meter
            .counterBuilder(name: "mainline.write_actions")
            .setDescription("Number of write actions (approve/merge/request changes)")
            .setUnit("1")
            .build()

        triageInteractionsCounter = meter
            .counterBuilder(name: "mainline.triage_interactions")
            .setDescription("Number of triage interactions by type")
            .setUnit("1")
            .build()

        notificationsFiredCounter = meter
            .counterBuilder(name: "mainline.notifications.fired")
            .setDescription("Number of notifications fired by event type and attention level")
            .setUnit("1")
            .build()

        notificationsSuppressedCounter = meter
            .counterBuilder(name: "mainline.notifications.suppressed")
            .setDescription("Number of notifications suppressed")
            .setUnit("1")
            .build()

        globalShortcutCounter = meter
            .counterBuilder(name: "mainline.global_shortcut.used")
            .setDescription("Number of global shortcut activations")
            .setUnit("1")
            .build()

        tokenInvalidCounter = meter
            .counterBuilder(name: "mainline.token.invalid")
            .setDescription("Number of token invalid events")
            .setUnit("1")
            .build()

        settingChangedCounter = meter
            .counterBuilder(name: "mainline.setting.changed")
            .setDescription("App-wide preference changes by setting name")
            .setUnit("1")
            .build()

        attentionPolicyChangedCounter = meter
            .counterBuilder(name: "mainline.attention_policy.changed")
            .setDescription("Attention-policy changes by event type and chosen level")
            .setUnit("1")
            .build()

        // MARK: Start session span + heartbeat

        if let tracer = tracer {
            let span = tracer.spanBuilder(spanName: "mainline session")
                .setSpanKind(spanKind: .internal)
                .startSpan()
            span.setAttribute(key: "session.app_version", value: .string(appVersion()))
            sessionSpan = span
        }

        heartbeatTimer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in
            self?.emitHeartbeat()
        }
    }

    private func ensureSetup() {
        guard MainlineSettings.shared.telemetryEnabled else { return }
        if tracer == nil { setupOTel() }
    }

    // MARK: - Graceful Shutdown

    func shutdown() {
        heartbeatTimer?.invalidate()
        heartbeatTimer = nil

        guard MainlineSettings.shared.telemetryEnabled else { return }

        // End any orphaned poll spans
        for (_, span) in activePollSpans {
            span.setAttribute(key: "poll.result", value: .string("app_shutdown"))
            span.end()
        }
        activePollSpans.removeAll()

        // End session span
        if let sessionSpan = sessionSpan {
            sessionSpan.status = .ok
            sessionSpan.end()
            self.sessionSpan = nil
        }

        _ = meterProvider?.forceFlush()
        _ = meterProvider?.shutdown()
        tracerProvider?.shutdown()
    }

    // MARK: - App Lifecycle

    func recordAppLaunch() {
        guard MainlineSettings.shared.telemetryEnabled else { return }
        ensureSetup()
        appLaunchCounter?.add(value: 1, attribute: [:])
        emitLog(severity: .info, body: "App launched", attributes: [
            "app.version": .string(appVersion()),
        ])
        recordDeploymentIfChanged()
    }

    func recordSessionDuration(_ seconds: Double) {
        guard MainlineSettings.shared.telemetryEnabled else { return }
        ensureSetup()
        emitLog(severity: .info, body: "Session ended", attributes: [
            "session.duration_s": .double(seconds),
        ])
    }

    private func recordDeploymentIfChanged() {
        let current = appVersion()
        let previous = MainlineSettings.shared.lastLaunchedVersion
        defer { MainlineSettings.shared.lastLaunchedVersion = current }
        guard let previous, previous != current else { return }
        emitLog(severity: .info, body: "App upgraded", attributes: [
            "deployment.from_version": .string(previous),
            "deployment.to_version": .string(current),
        ])
    }

    private func emitHeartbeat() {
        guard MainlineSettings.shared.telemetryEnabled else { return }
        emitLog(severity: .info, body: "Session heartbeat", attributes: [:])
    }

    // MARK: - Polling

    /// Called when a poll starts for a given query type.
    func recordPollStarted(queryType: String) {
        guard MainlineSettings.shared.telemetryEnabled else { return }
        ensureSetup()
        guard let tracer = tracer else { return }

        // End any stale span for this query type (defensive)
        if let stale = activePollSpans.removeValue(forKey: queryType) {
            stale.setAttribute(key: "poll.result", value: .string("abandoned"))
            stale.end()
        }

        let span = tracer.spanBuilder(spanName: "mainline poll")
            .setSpanKind(spanKind: .internal)
            .startSpan()
        span.setAttribute(key: "poll.query_type", value: .string(queryType))
        activePollSpans[queryType] = span
    }

    /// Called when a poll completes successfully.
    func recordPollCompleted(queryType: String, resultCount: Int, duration: Double, etag304: Bool) {
        guard MainlineSettings.shared.telemetryEnabled else { return }
        ensureSetup()

        if etag304 {
            pollEtagHitsCounter?.add(value: 1, attribute: [
                "poll.query_type": .string(queryType),
            ])
        } else {
            let labels: [String: AttributeValue] = [
                "poll.query_type": .string(queryType),
                "poll.result": .string("success"),
            ]
            pollDurationHistogram?.record(value: duration, attributes: labels)
        }

        if let span = activePollSpans.removeValue(forKey: queryType) {
            span.setAttribute(key: "poll.result", value: .string(etag304 ? "etag_304" : "success"))
            span.setAttribute(key: "poll.result_count", value: .int(resultCount))
            span.setAttribute(key: "poll.duration_s", value: .double(duration))
            span.status = .ok
            span.end()
        }
    }

    /// Called when a poll fails with a GitHubAPIError.
    func recordPollFailed(queryType: String, error: GitHubAPIError, duration: Double) {
        guard MainlineSettings.shared.telemetryEnabled else { return }
        ensureSetup()

        let category = categorizeGitHubError(error)
        pollErrorsCounter?.add(value: 1, attribute: [
            "poll.query_type": .string(queryType),
            "error.type": .string(category),
        ])
        pollDurationHistogram?.record(value: duration, attributes: [
            "poll.query_type": .string(queryType),
            "poll.result": .string("failure"),
        ])

        if let span = activePollSpans.removeValue(forKey: queryType) {
            span.setAttribute(key: "poll.result", value: .string("failure"))
            span.setAttribute(key: "error.type", value: .string(category))
            span.setAttribute(key: "poll.duration_s", value: .double(duration))
            span.status = .error(description: category)
            span.end()
        }
    }

    // MARK: - Write Actions

    /// Record a write action (approve/merge/requestChanges).
    /// - Parameters:
    ///   - action: "approve" | "merge" | "request_changes"
    ///   - mergeMethod: resolved method for merge: "squash" | "merge" | "rebase" | nil
    ///   - result: "success" | "failure"
    ///   - duration: seconds from action start to completion
    ///   - failureCategory: error category when result == "failure"
    func recordWriteAction(
        _ action: String,
        mergeMethod: String?,
        result: String,
        duration: Double,
        failureCategory: String?
    ) {
        guard MainlineSettings.shared.telemetryEnabled else { return }
        ensureSetup()

        var attrs: [String: AttributeValue] = [
            "write.action": .string(action),
            "write.result": .string(result),
        ]
        if let mergeMethod = mergeMethod {
            attrs["write.merge_method"] = .string(mergeMethod)
        }
        if let category = failureCategory {
            attrs["error.type"] = .string(category)
        }

        writeActionsCounter?.add(value: 1, attribute: attrs)
        emitLog(
            severity: result == "failure" ? .warn : .info,
            body: "Write action \(result)",
            attributes: attrs.merging(["write.duration_s": .double(duration)]) { _, new in new }
        )
    }

    // MARK: - Triage Interactions

    /// Record a triage interaction.
    /// - Parameter interaction: bounded value — "snooze" | "unsnooze" | "mark_seen" | "dismiss" |
    ///   "open_in_browser" | "diff_preview" | "open_preview" | "tab_switch" |
    ///   "scope_filter_change" | "toggle_drafts" | "inbox_mute" | "inbox_unmute" |
    ///   "undo" | "refresh" | "multi_select_toggle"
    func recordTriageInteraction(_ interaction: String) {
        guard MainlineSettings.shared.telemetryEnabled else { return }
        ensureSetup()

        triageInteractionsCounter?.add(value: 1, attribute: [
            "interaction.type": .string(interaction),
        ])
    }

    // MARK: - Notifications

    func recordNotificationFired(eventType: String, attentionLevel: String) {
        guard MainlineSettings.shared.telemetryEnabled else { return }
        ensureSetup()

        notificationsFiredCounter?.add(value: 1, attribute: [
            "notification.event_type": .string(eventType),
            "notification.attention_level": .string(attentionLevel),
        ])
    }

    func recordNotificationSuppressed(count: Int) {
        guard MainlineSettings.shared.telemetryEnabled else { return }
        ensureSetup()
        guard count > 0 else { return }

        notificationsSuppressedCounter?.add(value: count, attribute: [:])
    }

    // MARK: - Token & Shortcut

    func recordTokenImport(method: String) {
        guard MainlineSettings.shared.telemetryEnabled else { return }
        ensureSetup()

        emitLog(severity: .info, body: "Token imported", attributes: [
            "token.import_method": .string(method),
        ])
    }

    func recordTokenInvalid() {
        guard MainlineSettings.shared.telemetryEnabled else { return }
        ensureSetup()

        tokenInvalidCounter?.add(value: 1, attribute: [:])
        emitLog(severity: .warn, body: "Token invalid", attributes: [:])
    }

    func recordGlobalShortcutUsed() {
        guard MainlineSettings.shared.telemetryEnabled else { return }
        ensureSetup()

        globalShortcutCounter?.add(value: 1, attribute: [:])
    }

    // MARK: - Settings

    func recordSettingChanged(name: String, enabled: Bool) {
        guard MainlineSettings.shared.telemetryEnabled else { return }
        ensureSetup()

        let attrs: [String: AttributeValue] = [
            "setting.name": .string(name),
            "setting.enabled": .bool(enabled),
        ]
        settingChangedCounter?.add(value: 1, attribute: attrs)
        emitLog(severity: .info, body: "Setting changed", attributes: attrs)
    }

    /// Record a change to the attention policy for a single PR event.
    /// - Parameters:
    ///   - event: the `PREvent` raw value (bounded — one of the enum cases)
    ///   - level: the chosen `AttentionLevel` raw value — "notify" | "quiet" | "off"
    func recordAttentionPolicyChanged(event: String, level: String) {
        guard MainlineSettings.shared.telemetryEnabled else { return }
        ensureSetup()

        let attrs: [String: AttributeValue] = [
            "attention.event": .string(event),
            "attention.level": .string(level),
        ]
        attentionPolicyChangedCounter?.add(value: 1, attribute: attrs)
        emitLog(severity: .info, body: "Attention policy changed", attributes: attrs)
    }

    // MARK: - Private Helpers

    private func buildResource() -> Resource {
        let version = appVersion()
        let osVersion = ProcessInfo.processInfo.operatingSystemVersionString
        let settings = MainlineSettings.shared

        var attrs: [String: AttributeValue] = [
            ResourceAttributes.serviceName.rawValue:      .string(Self.serviceName),
            ResourceAttributes.serviceNamespace.rawValue: .string("mainline"),
            ResourceAttributes.serviceVersion.rawValue:   .string(version),
            "service.instance.id":                         .string(settings.installationId),
            "enduser.id":                                  .string(Self.anonymousUserId()),
            ResourceAttributes.osType.rawValue:           .string("darwin"),
            ResourceAttributes.osVersion.rawValue:        .string(osVersion),
        ]

        #if DEBUG
        attrs["deployment.environment.name"] = .string("development")
        #else
        attrs["deployment.environment.name"] = .string("production")
        #endif

        if let raw = Self.config["OTEL_RESOURCE_ATTRIBUTES"] {
            for pair in raw.split(separator: ",") {
                let parts = pair.split(separator: "=", maxSplits: 1)
                guard parts.count == 2 else { continue }
                let key = String(parts[0]).trimmingCharacters(in: .whitespaces)
                let value = String(parts[1]).trimmingCharacters(in: .whitespaces)
                attrs[key] = .string(value)
            }
        }

        return Resource(attributes: attrs)
    }

    private func appVersion() -> String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "unknown"
        var version = short
        if let build = info?["CFBundleVersion"] as? String,
           !build.isEmpty, build != "0" {
            version += "+\(build)"
        }
        if let sha = gitCommitSHA() {
            version += ".g\(sha)"
        }
        return version
    }

    private func gitCommitSHA() -> String? {
        guard let raw = Bundle.main.infoDictionary?["GitCommitSHA"] as? String else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.hasPrefix("$(") else { return nil }
        return trimmed
    }

    /// HMAC-SHA256 of the machine's hardware UUID — stable across reinstalls, not reversible.
    /// Emitted as the `enduser.id` resource attribute so Dash0 can differentiate users
    /// per resource (matches SyncTray's approach). When the hardware UUID is unavailable
    /// (IOKit miss), it falls back to the stable per-install `installationId` rather than a
    /// fresh random UUID — otherwise `enduser.id` would change every launch and fragment
    /// the user into many one-off identities.
    private static func anonymousUserId() -> String {
        let key = SymmetricKey(data: Data("mainline-telemetry".utf8))
        let mac = HMAC<SHA256>.authenticationCode(for: Data(platformUUID().utf8), using: key)
        return Data(mac).map { String(format: "%02x", $0) }.joined()
    }

    /// The machine's hardware UUID (`IOPlatformUUID`) via IOKit — stable across reinstalls.
    /// Falls back to the persistent per-install `installationId` when IOKit returns nothing,
    /// so the derived `enduser.id` stays stable for the life of the install.
    private static func platformUUID() -> String {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPlatformExpertDevice"))
        defer { IOObjectRelease(service) }
        guard service != IO_OBJECT_NULL,
              let uuid = IORegistryEntryCreateCFProperty(service, "IOPlatformUUID" as CFString, kCFAllocatorDefault, 0)?
                .takeRetainedValue() as? String,
              !uuid.isEmpty else {
            return MainlineSettings.shared.installationId
        }
        return uuid
    }

    /// Type-safe categorization of GitHubAPIError for metric attributes.
    private func categorizeGitHubError(_ error: GitHubAPIError) -> String {
        switch error {
        case .unauthorized:              return "unauthorized"
        case .rateLimited:               return "rate_limited"
        case .serverError:               return "server_error"
        case .cancelled:                 return "cancelled"
        case .decodingError:             return "decoding"
        case .notModified:               return "not_modified"
        case .networkError:              return "network_error"
        case .actionFailed:              return "action_failed"
        case .unknown:                   return "unknown"
        }
    }

    private func emitLog(
        severity: Severity,
        body: String,
        attributes: [String: AttributeValue],
        spanContext: SpanContext? = nil
    ) {
        guard let logger = logger else { return }

        var builder = logger.logRecordBuilder()
            .setSeverity(severity)
            .setBody(.string(body))
            .setTimestamp(Date())
            .setAttributes(attributes)

        if let ctx = spanContext {
            builder = builder.setSpanContext(ctx)
        }

        builder.emit()
    }

    /// Loads key=value pairs from ~/.config/mainline/.env (developer convenience).
    private static func loadDotEnv() -> [String: String] {
        let envFile = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/mainline/.env")
        guard let contents = try? String(contentsOf: envFile, encoding: .utf8) else {
            return [:]
        }
        var result: [String: String] = [:]
        for line in contents.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }
            let parts = trimmed.split(separator: "=", maxSplits: 1)
            guard parts.count == 2 else { continue }
            let key = String(parts[0]).trimmingCharacters(in: .whitespaces)
            var value = String(parts[1]).trimmingCharacters(in: .whitespaces)
            if (value.hasPrefix("\"") && value.hasSuffix("\"")) ||
               (value.hasPrefix("'") && value.hasSuffix("'")) {
                value = String(value.dropFirst().dropLast())
            }
            result[key] = value
        }
        return result
    }
}
