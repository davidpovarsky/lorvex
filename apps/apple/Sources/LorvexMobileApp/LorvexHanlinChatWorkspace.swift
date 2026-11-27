#if canImport(UIKit)
import SwiftUI
import UIKit
import LorvexCore
import LorvexMobile
import LorvexHanlinAgent
import HanlinChatUI
import HanlinPresentationKit

/// Host composition only: the original SDK owns the shell, bubbles, Markdown,
/// native editor, Morph material, activity motion, sources and approval surface.
@MainActor
struct LorvexHanlinChatWorkspace: View {
    let assistant: LorvexHanlinAssistantState
    let store: MobileStore
    let draft: HanlinComposerDraft
    let modelName: String
    let showModelSettings: () -> Void
    let showRemoteBridgeSettings: () -> Void
    let send: () -> Void
    @State private var composerHeight: CGFloat = 110
    @State private var autoFollow = ChatAutoFollowController()

    var body: some View {
        GeometryReader { geometry in
            HanlinChatView(shell: .init(id: "lorvex.agent", title: "Hanlin AI")) {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 14) {
                            if assistant.messages.isEmpty {
                                ContentUnavailableView("Your tasks, with AI", systemImage: "sparkles",
                                    description: Text("Ask about your day or manage tasks, lists, calendar and habits."))
                                    .accessibilityIdentifier("hanlin.empty")
                            }
                            ForEach(assistant.messages) { entry in
                                LorvexHanlinMessageRow(message: entry, assistant: assistant, width: geometry.size.width - 32) {
                                    requestScroll(proxy)
                                }
                                .id(entry.id)
                                ForEach(entry.workspaces) { request in
                                    LorvexHanlinTaskWorkspaceCard(request: request, store: store)
                                }
                            }
                            if let summary = assistant.dashboard {
                                LorvexHanlinDashboard(summary: summary)
                            }
                            if let request = assistant.pendingApproval,
                               let requestID = assistant.pendingApprovalID {
                                HanlinInlineToolApproval(requestID: requestID.uuidString,
                                    toolName: request.tool, reviewText: request.description,
                                    displayTitle: String(localized: "Allow this change?"), scopeSummary: request.description,
                                    requiresDetailedReview: false) { allowed in
                                        assistant.resolveApproval(allowed, requestID: requestID)
                                    }
                                    .id(requestID)
                            }
                            if let error = assistant.errorMessage {
                                Text(error).font(.caption).foregroundStyle(.red)
                                    .accessibilityIdentifier("hanlin.error")
                            }
                            Color.clear.frame(height: 1).id("hanlin.transcript.bottom")
                        }
                        .padding(.horizontal, 16).padding(.top, 12)
                        .padding(.bottom, composerHeight + 12)
                    }
                    .scrollDismissesKeyboard(.interactively)
                    .onScrollGeometryChange(for: LorvexHanlinScrollMetrics.self) { value in
                        LorvexHanlinScrollMetrics(offset: value.contentOffset.y,
                            contentHeight: value.contentSize.height, viewportHeight: value.containerSize.height,
                            topInset: value.contentInsets.top, bottomInset: value.contentInsets.bottom)
                    } action: { previous, current in
                        autoFollow.updateLayout(current.layout)
                        if let nearBottom = current.layout.isNearBottom(contentOffsetY: current.offset) {
                            autoFollow.updateNearBottom(nearBottom)
                        }
                        if previous.layout != current.layout { requestScroll(proxy) }
                    }
                    .onScrollPhaseChange { _, phase in
                        if phase == .tracking || phase == .interacting { autoFollow.userInteractionBegan() }
                        if phase == .idle { autoFollow.userInteractionEnded() }
                    }
                    .onChange(of: assistant.contentRevision) { _, _ in requestScroll(proxy) }
                    .onChange(of: assistant.isRunning) { _, running in
                        if running { autoFollow.beginRun(); requestScroll(proxy) }
                    }
                    .onChange(of: assistant.pendingApprovalID) { _, _ in requestScroll(proxy) }
                    .onAppear { autoFollow.beginRun(); requestScroll(proxy) }
                    .onDisappear { autoFollow.cancelPendingScroll() }
                    .overlay(alignment: .bottomTrailing) {
                        if autoFollow.mode == .pausedByUser {
                            Button("Latest message", systemImage: "arrow.down") {
                                autoFollow.resumeFollowing()
                                requestScroll(proxy, force: true)
                            }
                            .buttonStyle(.bordered).labelStyle(.iconOnly)
                            .padding(.trailing, 20).padding(.bottom, composerHeight + 12)
                            .accessibilityIdentifier("hanlin.transcript.latest")
                        }
                    }
                    .accessibilityIdentifier("hanlin.transcript")
                }
            } composer: {
                LorvexHanlinComposer(draft: draft, availableHeight: geometry.size.height,
                    modelName: modelName, isRunning: assistant.isRunning,
                    showModelSettings: showModelSettings,
                    showRemoteBridgeSettings: showRemoteBridgeSettings,
                    send: send, stop: { _Concurrency.Task { await assistant.cancel() } })
                    .disabled(!assistant.isRunning && (assistant.isRestoringConversation ||
                              (assistant.conversationScope != nil && !assistant.isConversationReady)))
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height in
                        if height.isFinite, height > 0, abs(height - composerHeight) > 1 { composerHeight = height }
                    }
            }
        }
    }

    private func requestScroll(_ proxy: ScrollViewProxy, force: Bool = false) {
        autoFollow.scheduleScroll(animated: false, force: force) { animated in
            if animated {
                lorvexAnimated(.easeOut(duration: 0.2)) { proxy.scrollTo("hanlin.transcript.bottom", anchor: .bottom) }
            } else {
                proxy.scrollTo("hanlin.transcript.bottom", anchor: .bottom)
            }
        }
    }
}

private struct LorvexHanlinScrollMetrics: Equatable {
    let offset: Double
    let contentHeight: Double
    let viewportHeight: Double
    let topInset: Double
    let bottomInset: Double
    var layout: ChatAutoFollowLayout {
        .init(contentHeight: contentHeight, viewportHeight: viewportHeight,
              topInset: topInset, bottomInset: bottomInset)
    }
}

@MainActor
private struct LorvexHanlinMessageRow: View {
    @Environment(\.openURL) private var openURL
    let message: LorvexHanlinMessage
    let assistant: LorvexHanlinAssistantState
    let width: CGFloat
    let onRendered: @MainActor @Sendable () -> Void
    @State private var showsSources = false

    private var sources: [HanlinSourceReference] {
        message.sources.map { .init(id: $0.id, title: $0.title, url: $0.url) }
    }

    var body: some View {
        Group {
            if message.role == .user {
                HStack {
                    Spacer()
                    HanlinUserMessageBubble(text: message.text, containerWidth: width) {
                        Button("Copy", systemImage: "square.on.square") { UIPasteboard.general.string = message.text }
                    }
                }
            } else if message.role == .assistant {
                HanlinAssistantMessageBubble(isResponding: message.status == .streaming) {
                    Text("Hanlin").font(HanlinTypography.caption).foregroundStyle(.secondary)
                    if !message.reasoning.isEmpty || !message.activities.isEmpty {
                        LorvexHanlinActivityView(message: message, assistant: assistant)
                    }
                    if !message.text.isEmpty {
                        HanlinMarkdownView(text: message.text, onRendered: onRendered)
                    } else if message.status == .streaming {
                        HanlinActivityTitle(String(localized: "Working…"), font: HanlinTypography.body, isActive: true)
                    } else if message.status == .cancelled {
                        Text("Stopped").font(HanlinTypography.caption).foregroundStyle(.secondary)
                    }
                    HanlinSourcesButton(sources: sources, title: String(localized: "Sources")) { showsSources = true }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                Text(message.text).font(HanlinTypography.caption).foregroundStyle(.secondary)
            }
        }
        .sheet(isPresented: $showsSources) {
            HanlinSourcesList(sources: sources, title: String(localized: "Sources")) { source in
                if let url = source.url { openURL(url) }
            }
        }
    }
}

@MainActor
private struct LorvexHanlinActivityView: View {
    let message: LorvexHanlinMessage
    let assistant: LorvexHanlinAssistantState

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if !message.reasoning.isEmpty {
                DisclosureGroup(isExpanded: Binding(
                    get: { message.reasoningExpanded },
                    set: { assistant.setReasoningExpanded($0, messageID: message.id) })) {
                    HanlinMarkdownView(text: message.reasoning)
                } label: {
                    HanlinActivityHierarchyHeader(title: String(localized: "Thinking"), symbol: "brain",
                        isExpanded: message.reasoningExpanded,
                        isActive: message.status == .streaming && message.text.isEmpty)
                }
                .disclosureGroupStyle(HanlinActivityDisclosureStyle())
            }
            ForEach(message.activities) { activity in
                LorvexHanlinToolRow(activity: activity,
                    expanded: message.expandedActivityIDs.contains(activity.id)) { expanded in
                    assistant.setActivityExpanded(expanded, messageID: message.id, activityID: activity.id)
                }
            }
        }
    }
}

@MainActor
private struct LorvexHanlinToolRow: View {
    let activity: LorvexHanlinToolActivity
    let expanded: Bool
    let onExpanded: (Bool) -> Void

    private var title: String {
        String(localized: String.LocalizationValue(
            LorvexHanlinToolCatalog.specs.first { $0.alias == activity.name }?.summary ?? activity.name))
    }
    private var status: String {
        switch activity.phase {
        case .preparing: String(localized: "Preparing")
        case .awaitingApproval: String(localized: "Awaiting approval")
        case .running: String(localized: "Running")
        case .completed: String(localized: "Complete")
        case .failed: String(localized: "Failed")
        case .denied: String(localized: "Denied")
        case .cancelled: String(localized: "Stopped")
        case .incomplete: String(localized: "No result received")
        }
    }
    private var symbol: String {
        if activity.name.contains("event") { return "calendar" }
        if activity.name.contains("habit") { return "repeat" }
        if activity.name == "get_summary" { return "chart.bar" }
        return "checklist"
    }

    var body: some View {
        DisclosureGroup(isExpanded: Binding(get: { expanded }, set: onExpanded)) {
            if !activity.arguments.isEmpty {
                HanlinToolDetailsText(activity.arguments, maximumHeight: 180,
                    accessibilityIdentifier: "hanlin.activity.arguments")
            }
            if !activity.result.isEmpty {
                HanlinToolDetailsText(activity.result, maximumHeight: 240,
                    accessibilityIdentifier: "hanlin.activity.result")
            }
        } label: {
            HanlinToolActivityHeader(title: title, status: status, symbol: symbol,
                isActive: activity.phase.isActive, isExpanded: expanded,
                isFailure: activity.phase == .failed || activity.phase == .incomplete,
                isCancelled: activity.phase == .cancelled || activity.phase == .denied,
                startedAt: activity.startedAt, completedAt: activity.completedAt)
        }
        .disclosureGroupStyle(HanlinActivityDisclosureStyle(isTool: true))
        .accessibilityIdentifier("hanlin.activity." + activity.id)
    }
}
#endif
