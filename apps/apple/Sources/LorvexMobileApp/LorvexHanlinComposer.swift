#if canImport(UIKit)
import SwiftUI
import UIKit
import HanlinChatUI
import HanlinPresentationKit
import LorvexHanlinAgent

/// The existing Hanlin Morph Composer and native editor. Lorvex supplies its
/// own draft, model choice and tools; the SDK owns material, layout and motion.
@MainActor
struct LorvexHanlinComposer: View {
    let draft: HanlinComposerDraft
    let availableHeight: CGFloat
    let modelName: String
    let isRunning: Bool
    let showModelSettings: () -> Void
    let showRemoteBridgeSettings: () -> Void
    let send: () -> Void
    let stop: () -> Void
    @State private var isExpanded = false
    @State private var activePage: Page?
    @State private var naturalEditorHeight: CGFloat = HanlinMorphStyle.editorMinimumHeight
    @State private var toolbarHeight: CGFloat = 44
    @State private var editorHandle = LorvexHanlinEditorHandle()

    enum Page: Hashable { case tools }

    private var layout: HanlinMorphGeometry.Layout {
        HanlinMorphGeometry.layout(availableHeight: availableHeight,
            accessoryNaturalHeight: 0, capabilitiesHeight: 0,
            naturalEditorHeight: naturalEditorHeight, toolbarHeight: toolbarHeight,
            isPanelExpanded: isExpanded, isEditorExpanded: false)
    }
    private var text: Binding<String> {
        Binding(get: { [draft] in draft.text }, set: { [draft] in draft.text = $0 })
    }

    var body: some View {
        HanlinMorphComposer(isExpanded: $isExpanded, activePage: $activePage,
            availableHeight: availableHeight, accessoryHeight: 0,
            inputHeight: layout.inputHeight,
            title: { $0 == .tools ? String(localized: "Task tools") : String(localized: "Lorvex") },
            subtitle: { _ in String(localized: "Plan with your tasks, lists, calendar and habits") },
            backIdentifier: { _ in "hanlin.composer.tools.back" },
            onOpen: { editorHandle.editor?.resignFirstResponder() },
            onBackgroundTap: { editorHandle.editor?.becomeFirstResponder() },
            onToolbarHeightChange: { toolbarHeight = $0 }) {
                VStack(alignment: .leading, spacing: 12) {
                    Button("Task tools", systemImage: "checklist") { activePage = .tools }
                        .accessibilityIdentifier("hanlin.composer.tools")
                    Button("Model settings", systemImage: "gearshape", action: showModelSettings)
                    Button("Connect to ChatGPT", systemImage: "network", action: showRemoteBridgeSettings)
                }
                .buttonStyle(.plain).font(HanlinTypography.body)
                .frame(maxWidth: .infinity, alignment: .leading)
            } detail: { _ in
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(LorvexHanlinToolCatalog.specs, id: \.alias) { tool in
                        Label {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(String(localized: String.LocalizationValue(tool.summary))).font(HanlinTypography.callout)
                                if tool.writes && !LorvexHanlinWritePolicy.mayAutomaticallyAuthorize(tool.alias) {
                                    Text("Asks for your approval").font(HanlinTypography.caption).foregroundStyle(.secondary)
                                }
                            }
                        } icon: {
                            Image(systemName: tool.writes ? "hand.raised" : "magnifyingglass")
                        }
                    }
                }
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("hanlin.composer.toolCatalog")
            } input: {
                VStack(spacing: HanlinMorphStyle.inputControlsSpacing) {
                    NativeMultilineTextEditor(text: text, textHeight: $naturalEditorHeight,
                        placeholderText: String(localized: "Ask Hanlin…"),
                        minHeight: HanlinMorphStyle.editorMinimumHeight,
                        maxHeight: layout.editorMaximumHeight, usesAutomaticLineLimits: true,
                        onSendMessage: send,
                        onLifecycleEvent: { view, event in
                            switch event {
                            case .attached: editorHandle.editor = view
                            case .detached: if editorHandle.editor === view { editorHandle.editor = nil }
                            case .focusChanged: break
                            }
                        },
                        readCurrentTextState: { [draft] in draft.snapshot })
                        .frame(height: layout.editorHeight)
                        .padding(.horizontal, HanlinMorphStyle.modelSourceHorizontalInset)
                    HStack(spacing: 8) {
                        Button(action: showModelSettings) {
                            Text(modelName.isEmpty ? String(localized: "Choose model") : modelName)
                                .font(HanlinTypography.caption).lineLimit(1).foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("hanlin.composer.model")
                        Spacer(minLength: 4)
                        Button(action: isRunning ? stop : send) {
                            Image(systemName: isRunning ? "stop.fill" : "arrow.up")
                                .font(HanlinTypography.body.weight(.semibold))
                                .frame(width: HanlinMorphStyle.sendButtonSize, height: HanlinMorphStyle.sendButtonSize)
                                .foregroundStyle(.white)
                                .background(HanlinMorphStyle.blue, in: Circle())
                                .frame(minWidth: HanlinMorphStyle.inputControlHitSize,
                                       minHeight: HanlinMorphStyle.inputControlHitSize)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .disabled(!isRunning && draft.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        .accessibilityLabel(isRunning ? String(localized: "Stop") : String(localized: "Send"))
                        .accessibilityIdentifier(isRunning ? "hanlin.composer.stop" : "hanlin.composer.send")
                    }
                    .padding(.leading, HanlinMorphStyle.modelSourceHorizontalInset)
                    .padding(.trailing, HanlinMorphStyle.inputControlsInset)
                }
                .padding(.top, HanlinMorphStyle.inputTopInset)
                .padding(.bottom, HanlinMorphStyle.inputControlsInset)
            }
    }
}
@MainActor
private final class LorvexHanlinEditorHandle {
    weak var editor: UITextView?
}
#endif
