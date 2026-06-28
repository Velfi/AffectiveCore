import SwiftUI

struct DashboardView: View {
    @Bindable var model: BrainDashboardModel

    var body: some View {
        #if os(macOS)
        HStack(spacing: 0) {
            SidebarView(model: model)
                .frame(width: 240)
                .background(.bar)
            Divider()
            ToolWorkspaceView(model: model)
        }
        .alert("AffectiveCore", isPresented: Binding(
            get: { model.lastError != nil },
            set: { if !$0 { model.lastError = nil } }
        )) {
            Button("OK") { model.lastError = nil }
        } message: {
            Text(model.lastError ?? "")
        }
        .task {
            if !model.isConnected {
                await model.connect()
            }
        }
        #else
        NavigationSplitView {
            SidebarView(model: model)
                .navigationTitle("AffectiveCore")
        } detail: {
            ToolWorkspaceView(model: model)
                .navigationTitle("Workspace")
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Image(systemName: model.isConnected ? "checkmark.circle.fill" : "bolt.slash.circle")
                            .foregroundStyle(model.isConnected ? .green : .secondary)
                            .accessibilityLabel(model.status)
                    }
                }
        }
        .alert("AffectiveCore", isPresented: Binding(
            get: { model.lastError != nil },
            set: { if !$0 { model.lastError = nil } }
        )) {
            Button("OK") { model.lastError = nil }
        } message: {
            Text(model.lastError ?? "")
        }
        .task {
            if !model.isConnected {
                await model.connect()
            }
        }
        #endif
    }
}

struct SidebarView: View {
    @Bindable var model: BrainDashboardModel

    var body: some View {
        #if os(macOS)
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 6) {
                Label("AffectiveCore", systemImage: "sparkles")
                    .font(.title3.weight(.semibold))
                Text("Local brain studio")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 10) {
                Text("Connection")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
                Label(model.status, systemImage: model.isConnected ? "checkmark.circle.fill" : "xmark.circle.fill")
                    .foregroundStyle(model.isConnected ? .green : .secondary)
                DisclosureGroup {
                    TextField("Server path", text: $model.serverPath)
                        .textFieldStyle(.roundedBorder)
                        .font(.caption)
                } label: {
                    Label("Runtime details", systemImage: "terminal")
                        .font(.caption)
                }
                VStack(alignment: .leading, spacing: 8) {
                    Button {
                        Task { await model.connect() }
                    } label: {
                        Label("Connect", systemImage: "bolt.horizontal.circle")
                    }
                    .buttonStyle(.bordered)

                    Button(role: .destructive) {
                        Task { await model.disconnect() }
                    } label: {
                        Label("Disconnect", systemImage: "power")
                    }
                    .buttonStyle(.bordered)
                }
            }

            Divider()

            VStack(alignment: .leading, spacing: 10) {
                Text("Default Brain")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
                Label("data/brains/default", systemImage: "folder")
                    .font(.caption)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Button {
                    Task { await model.refresh() }
                } label: {
                    Label("Refresh State", systemImage: "arrow.clockwise")
                }
                Button {
                    Task { await model.runSelectedTool() }
                } label: {
                    Label("Run Selected Tool", systemImage: "play.circle")
                }
            }

            Divider()

            VStack(alignment: .leading, spacing: 10) {
                Text("LLM Quality")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
                Picker("LLM Quality", selection: $model.llmQuality) {
                    Text("Frugal").tag("frugal")
                    Text("Decide for me").tag("auto")
                    Text("Best").tag("best")
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                Button {
                    Task { await model.applyLlmQuality() }
                } label: {
                    Label("Apply Quality Setting", systemImage: "slider.horizontal.3")
                }
                .buttonStyle(.bordered)
                .disabled(!model.isConnected)
            }

            Divider()

            VStack(alignment: .leading, spacing: 8) {
                Text("Quick Tools")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
                ForEach(model.quickTools, id: \.self) { tool in
                    Text(tool)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer()
        }
        .padding(16)
        #else
        List {
            Section("Connection") {
                VStack(alignment: .leading, spacing: 8) {
                    Label(model.status, systemImage: model.isConnected ? "checkmark.circle.fill" : "xmark.circle.fill")
                        .foregroundStyle(model.isConnected ? .green : .secondary)
                    TextField("MCP server path", text: $model.serverPath)
                        .textFieldStyle(.roundedBorder)
                        #if os(iOS)
                        .textInputAutocapitalization(.never)
                        #endif
                }
                Button {
                    Task { await model.connect() }
                } label: {
                    Label("Connect", systemImage: "bolt.horizontal.circle")
                }
                Button(role: .destructive) {
                    Task { await model.disconnect() }
                } label: {
                    Label("Disconnect", systemImage: "power")
                }
            }

            Section("Quick Tools") {
                Button {
                    Task { await model.refresh() }
                } label: {
                    Label("Refresh State", systemImage: "arrow.clockwise")
                }
                Button {
                    Task { await model.runSelectedTool() }
                } label: {
                    Label("Run Selected Tool", systemImage: "play.circle")
                }
            }
        }
        #endif
    }
}

struct ToolWorkspaceView: View {
    @Bindable var model: BrainDashboardModel
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    #endif

    var body: some View {
        #if os(iOS)
        if horizontalSizeClass == .compact {
            CompactIOSWorkspaceView(model: model)
        } else {
            StudioWorkspaceScrollView(model: model)
        }
        #else
        StudioWorkspaceScrollView(model: model)
        #endif
    }
}

#if os(iOS)
private enum CompactWorkspaceTab: String, CaseIterable, Identifiable {
    case chat = "Chat"
    case studio = "Studio"

    var id: String { rawValue }
}

private struct CompactIOSWorkspaceView: View {
    @Bindable var model: BrainDashboardModel
    @State private var tab: CompactWorkspaceTab = .chat

    var body: some View {
        VStack(spacing: 0) {
            Picker("Section", selection: $tab) {
                ForEach(CompactWorkspaceTab.allCases) { section in
                    Text(section.rawValue).tag(section)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal)
            .padding(.vertical, 8)

            switch tab {
            case .chat:
                ChatResultsView(model: model)
            case .studio:
                StudioWorkspaceScrollView(model: model, includesChatPanels: false)
            }
        }
        .background(Color(.systemGroupedBackground))
    }
}

private struct ChatResultsView: View {
    @Bindable var model: BrainDashboardModel
    @State private var pinnedToBottom = true

    var body: some View {
        VStack(spacing: 0) {
            ResultsFeedView(
                records: model.records,
                listGeneration: model.recordsListGeneration,
                pinToBottom: $pinnedToBottom,
                emptyTitle: "No messages yet",
                emptySystemImage: "text.bubble"
            )

            Divider()
            MobileChatComposer(model: model) {
                pinnedToBottom = true
            }
        }
    }
}

private struct MobileChatComposer: View {
    @Bindable var model: BrainDashboardModel
    var onSend: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            TextField("Message", text: $model.userTextInput, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(2...5)
            Button {
                onSend()
                Task { await model.sendUserText() }
            } label: {
                Label("Send", systemImage: "paperplane.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .disabled(model.userTextInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .padding()
        .background(.bar)
    }
}
#endif

private struct StudioWorkspaceScrollView: View {
    @Bindable var model: BrainDashboardModel
    var includesChatPanels: Bool = true

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 18) {
                BrainStatusHeader(model: model)
                if includesChatPanels {
                    UserTextPanel(model: model)
                }
                BrainSeedPanel(model: model)
                MemoryPanel(model: model)
                ReminderPanel(model: model)
                RawToolPanel(model: model)
                if includesChatPanels {
                    ResultTimeline(records: model.records, listGeneration: model.recordsListGeneration)
                }
            }
            .padding()
            .frame(maxWidth: 1120, alignment: .leading)
        }
        .scrollIndicators(.visible)
        .scrollDismissesKeyboard(.interactively)
        .background(workspaceBackground)
    }

    private var workspaceBackground: Color {
        #if os(macOS)
        Color(nsColor: .windowBackgroundColor)
        #else
        Color(.systemGroupedBackground)
        #endif
    }
}

struct BrainStatusHeader: View {
    @Bindable var model: BrainDashboardModel

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            Image(systemName: "circle.hexagongrid.circle.fill")
                .font(.system(size: 38))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.blue)

            VStack(alignment: .leading, spacing: 4) {
                Text("Default Brain")
                    .font(.title2.weight(.semibold))
                Text(model.isConnected ? "Open and connected to the local MCP runtime." : "Ready to connect to the local MCP runtime.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Label(model.status, systemImage: model.isConnected ? "checkmark.circle.fill" : "bolt.slash.circle")
                .font(.callout.weight(.medium))
                .foregroundStyle(model.isConnected ? .green : .secondary)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(.background, in: Capsule())
        }
        .padding(16)
        .background(PanelStyle.fill, in: RoundedRectangle(cornerRadius: 8))
    }
}

struct UserTextPanel: View {
    @Bindable var model: BrainDashboardModel

    var body: some View {
        Panel(title: "User Text", systemImage: "text.bubble") {
            Text("Send typed input through the `user_text` MCP tool. Results show the current outcome shape (`text`, `spoken_text`, activity fields, `awaiting_host_sense`).")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            TextField("Message", text: $model.userTextInput, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(3...6)

            HStack {
                Button {
                    Task { await model.sendUserText() }
                } label: {
                    Label("Send", systemImage: "paperplane.fill")
                }
                .buttonStyle(.borderedProminent)
                .disabled(model.userTextInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                Button {
                    model.applyDefaultArguments(for: "user_text")
                } label: {
                    Label("Load Raw Example", systemImage: "curlybraces")
                }
                .buttonStyle(.bordered)
            }

            VStack(alignment: .leading, spacing: 6) {
                UserTextRequestPreview(userText: model.userTextInput)
            }
        }
    }
}

struct BrainSeedPanel: View {
    @Bindable var model: BrainDashboardModel
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    #endif

    var body: some View {
        Panel(title: "New Brain", systemImage: "sparkles", initiallyExpanded: false) {
            #if os(iOS)
            if horizontalSizeClass == .compact {
                compactSeedContent
            } else {
                wideSeedContent
            }
            #else
            wideSeedContent
            #endif
        }
    }

    private var seedFields: some View {
        Group {
            VStack(alignment: .leading, spacing: 6) {
                Text("Starting Orientation")
                    .font(.headline)
                Text("Shape the first durable memories, wants, goals, and Superego principles before the brain begins learning from the room.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(alignment: .leading, spacing: 8) {
                Label("Identity", systemImage: "brain.head.profile")
                    .font(.subheadline.weight(.semibold))
                TextField("Brain name", text: $model.newBrainName)
                    .textFieldStyle(.roundedBorder)
            }

            SeedInputGroup(
                title: "Core Values",
                systemImage: "heart.text.square",
                prompt: "One value per line",
                minHeight: 66,
                text: $model.seedCoreValues
            )
            SeedInputGroup(
                title: "Operating Tendencies",
                systemImage: "slider.horizontal.3",
                prompt: "One tendency per line",
                minHeight: 58,
                text: $model.seedOperatingTendencies
            )
            SeedInputGroup(
                title: "Wants",
                systemImage: "scope",
                prompt: "One durable want per line",
                minHeight: 120,
                text: $model.seedWants
            )
            SeedInputGroup(
                title: "Goals",
                systemImage: "target",
                prompt: "One goal per line",
                minHeight: 92,
                text: $model.seedGoals
            )
            SeedInputGroup(
                title: "Superego Principles",
                systemImage: "checkmark.shield.fill",
                prompt: "One principle per line",
                minHeight: 66,
                text: $model.seedPrinciples
            )
        }
    }

    private var seedSidebar: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Seed Draft")
                    .font(.headline)
                Text("A seed is the first shape of the brain's self-model. The parser will turn each line into durable memory.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            BrainSeedMetricGrid(
                coreValues: model.seedCoreValues,
                operatingTendencies: model.seedOperatingTendencies,
                wants: model.seedWants,
                goals: model.seedGoals,
                principles: model.seedPrinciples
            )

            Button {
                Task { await model.createSeedDraft() }
            } label: {
                Label("Create Seed Draft", systemImage: "plus.circle.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)

            if let path = model.seedDraftPath {
                Label(displaySeedPath(path), systemImage: "doc.text")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .truncationMode(.middle)
            }

            VStack(alignment: .leading, spacing: 8) {
                Label("Live Preview", systemImage: "doc.text.magnifyingglass")
                    .font(.subheadline.weight(.semibold))
                SeedDraftPreview(model: model)
            }
        }
    }

    private var compactSeedContent: some View {
        VStack(alignment: .leading, spacing: 14) {
            seedFields
            seedSidebar
        }
    }

    private var wideSeedContent: some View {
        HStack(alignment: .top, spacing: 18) {
            VStack(alignment: .leading, spacing: 14) {
                seedFields
            }
            seedSidebar
                .frame(width: 330)
        }
    }

    private func displaySeedPath(_ path: String) -> String {
        if let range = path.range(of: "data/seeds/") {
            return "Draft ready at \(path[range.lowerBound...])"
        }
        return path
    }
}

struct BrainSeedMetricGrid: View {
    let coreValues: String
    let operatingTendencies: String
    let wants: String
    let goals: String
    let principles: String

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 8) {
            GridRow {
                SeedMetric(title: "Values", value: lineCount(coreValues), systemImage: "heart")
                SeedMetric(title: "Tendencies", value: lineCount(operatingTendencies), systemImage: "slider.horizontal.3")
            }
            GridRow {
                SeedMetric(title: "Wants", value: lineCount(wants), systemImage: "scope")
                SeedMetric(title: "Goals", value: lineCount(goals), systemImage: "target")
            }
            GridRow {
                SeedMetric(title: "Principles", value: lineCount(principles), systemImage: "checkmark.shield.fill")
            }
        }
    }

    private func lineCount(_ text: String) -> Int {
        text.split(whereSeparator: \.isNewline)
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .count
    }
}

struct SeedMetric: View {
    let title: String
    let value: Int
    let systemImage: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: systemImage)
                .foregroundStyle(.secondary)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 1) {
                Text("\(value)")
                    .font(.headline.monospacedDigit())
                Text(title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(8)
        .background(.background, in: RoundedRectangle(cornerRadius: 8))
    }
}

struct SeedInputGroup: View {
    let title: String
    let systemImage: String
    let prompt: String
    let minHeight: CGFloat
    @Binding var text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label(title, systemImage: systemImage)
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Text(prompt)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            TextEditor(text: $text)
                .frame(minHeight: minHeight)
                .scrollContentBackground(.hidden)
                #if os(iOS)
                .scrollDisabled(true)
                #endif
                .padding(6)
                .background(.background, in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(.quaternary))
        }
    }
}

struct MemoryPanel: View {
    @Bindable var model: BrainDashboardModel
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    #endif

    private var memoryEditorMinHeight: CGFloat {
        #if os(iOS)
        horizontalSizeClass == .compact ? 72 : 92
        #else
        92
        #endif
    }

    var body: some View {
        Panel(title: "Memory", systemImage: "brain.head.profile", initiallyExpanded: false) {
            Text("Recall and reminders route natural-language requests through `user_text`. Use Remember for durable experience logging via `send_experience_event`.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            #if os(iOS)
            if horizontalSizeClass == .compact {
                Text("Scroll the studio workspace to reach the full memory field.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            #endif
            TextField("Query memories", text: $model.query)
                .textFieldStyle(.roundedBorder)
            TextField("Tags, comma-separated", text: $model.memoryTags)
                .textFieldStyle(.roundedBorder)
            HStack {
                Button {
                    Task { await model.recallMemory() }
                } label: {
                    Label("Recall", systemImage: "magnifyingglass")
                }
                Button {
                    Task { await model.rememberMemory() }
                } label: {
                    Label("Remember", systemImage: "plus.circle")
                }
            }
            TextEditor(text: $model.memoryText)
                .frame(minHeight: memoryEditorMinHeight)
                #if os(iOS)
                .scrollDisabled(true)
                #endif
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(.quaternary))
        }
    }
}

struct ReminderPanel: View {
    @Bindable var model: BrainDashboardModel

    var body: some View {
        Panel(title: "Reminders", systemImage: "bell.badge") {
            HStack {
                TextField("Schedule", text: $model.reminderSchedule)
                    .textFieldStyle(.roundedBorder)
                Button {
                    Task { await model.setReminder() }
                } label: {
                    Label("Set", systemImage: "calendar.badge.plus")
                }
            }
            TextField("Reminder text", text: $model.reminderText)
                .textFieldStyle(.roundedBorder)
        }
    }
}

struct RawToolPanel: View {
    @Bindable var model: BrainDashboardModel
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    #endif

    private var rawEditorMinHeight: CGFloat {
        #if os(iOS)
        horizontalSizeClass == .compact ? 72 : 88
        #else
        88
        #endif
    }

    var body: some View {
        Panel(title: "Raw Tool", systemImage: "terminal", initiallyExpanded: false) {
            Text("MCP tools mirror the host contract. `user_text` returns a flat outcome object; embedded dispatch wraps the same fields in `{ \"kind\": \"user_text\", \"outcome\": ... }`.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            #if os(iOS)
            if horizontalSizeClass == .compact {
                Text("Scroll the studio workspace to reach the full JSON editor.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            #endif
            Picker("Tool", selection: $model.selectedTool) {
                ForEach(model.allTools, id: \.self) { tool in
                    Text(tool).tag(tool)
                }
            }
            .pickerStyle(.menu)
            .onChange(of: model.selectedTool) { _, newTool in
                Task { @MainActor in
                    model.rawArguments = BrainDashboardModel.defaultArguments(for: newTool)
                }
            }
            TextEditor(text: $model.rawArguments)
                .font(.system(.body, design: .monospaced))
                .frame(minHeight: rawEditorMinHeight)
                #if os(iOS)
                .scrollDisabled(true)
                #endif
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(.quaternary))
            Button {
                Task { await model.runSelectedTool() }
            } label: {
                Label("Run", systemImage: "play.fill")
            }
        }
    }
}

struct ResultTimeline: View {
    let records: [ToolCallRecord]
    let listGeneration: UUID

    var body: some View {
        Panel(title: "Results", systemImage: "text.alignleft") {
            ResultsFeedView(
                records: records,
                listGeneration: listGeneration,
                pinToBottom: nil,
                isEmbedded: true
            )
        }
    }
}

enum PanelStyle {
    static var fill: Color {
        #if os(macOS)
        Color(nsColor: .controlBackgroundColor)
        #else
        Color(.secondarySystemGroupedBackground)
        #endif
    }
}

struct Panel<Content: View>: View {
    let title: String
    let systemImage: String
    let initiallyExpanded: Bool
    @ViewBuilder let content: Content
    @State private var isExpanded: Bool

    init(
        title: String,
        systemImage: String,
        initiallyExpanded: Bool = true,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.systemImage = systemImage
        self.initiallyExpanded = initiallyExpanded
        self.content = content()
        _isExpanded = State(initialValue: initiallyExpanded)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                isExpanded.toggle()
            } label: {
                HStack {
                    Label(title, systemImage: systemImage)
                        .font(.title3.bold())
                    Spacer()
                    Image(systemName: "chevron.down")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(isExpanded ? 0 : -90))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if isExpanded {
                content
                    .padding(.top, 12)
            }
        }
        .padding()
        .background(PanelStyle.fill, in: RoundedRectangle(cornerRadius: 8))
    }
}

#Preview {
    DashboardView(model: BrainDashboardModel())
}
