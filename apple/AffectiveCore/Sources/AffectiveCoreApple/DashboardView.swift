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
                .navigationTitle(model.status)
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

            VStack(alignment: .leading, spacing: 8) {
                Text("Quick Tools")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
                ForEach(model.quickTools.prefix(5), id: \.self) { tool in
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

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                BrainStatusHeader(model: model)
                BrainSeedPanel(model: model)
                MemoryPanel(model: model)
                ReminderPanel(model: model)
                RawToolPanel(model: model)
                ResultTimeline(records: model.records)
            }
            .padding()
            .frame(maxWidth: 1120, alignment: .leading)
        }
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
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 8))
    }
}

struct BrainSeedPanel: View {
    @Bindable var model: BrainDashboardModel

    var body: some View {
        Panel(title: "New Brain", systemImage: "sparkles") {
            HStack(alignment: .top, spacing: 18) {
                VStack(alignment: .leading, spacing: 14) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Starting Orientation")
                            .font(.headline)
                        Text("Shape the first durable memories, wants, and Superego principles before the brain begins learning from the room.")
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
                        minHeight: 58,
                        text: $model.seedWants
                    )
                    SeedInputGroup(
                        title: "Superego Principles",
                        systemImage: "checkmark.shield",
                        prompt: "One principle per line",
                        minHeight: 66,
                        text: $model.seedPrinciples
                    )
                }

                VStack(alignment: .leading, spacing: 14) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Seed Draft")
                            .font(.headline)
                        Text("A seed is the first shape of the brain's self-model. The parser will turn each line into durable memory.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    BrainSeedMetricGrid(model: model)

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
                        ScrollView {
                            Text(model.seedDraftMarkdown)
                                .font(.system(.caption, design: .monospaced))
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(10)
                        }
                        .frame(minHeight: 260)
                        .background(.black.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))
                    }
                }
                .frame(width: 330)
            }
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
    @Bindable var model: BrainDashboardModel

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 8) {
            GridRow {
                SeedMetric(title: "Values", value: lineCount(model.seedCoreValues), systemImage: "heart")
                SeedMetric(title: "Tendencies", value: lineCount(model.seedOperatingTendencies), systemImage: "slider.horizontal.3")
            }
            GridRow {
                SeedMetric(title: "Wants", value: lineCount(model.seedWants), systemImage: "scope")
                SeedMetric(title: "Principles", value: lineCount(model.seedPrinciples), systemImage: "checkmark.shield")
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
                .padding(6)
                .background(.background, in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(.quaternary))
        }
    }
}

struct MemoryPanel: View {
    @Bindable var model: BrainDashboardModel

    var body: some View {
        Panel(title: "Memory", systemImage: "brain.head.profile") {
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
                .frame(minHeight: 92)
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
            Button {
                model.selectedTool = "list_reminders"
                model.rawArguments = "{}"
                Task { await model.runSelectedTool() }
            } label: {
                Label("List Reminders", systemImage: "list.bullet.clipboard")
            }
        }
    }
}

struct RawToolPanel: View {
    @Bindable var model: BrainDashboardModel

    var body: some View {
        Panel(title: "Raw Tool", systemImage: "terminal") {
            Picker("Tool", selection: $model.selectedTool) {
                ForEach(model.quickTools, id: \.self) { tool in
                    Text(tool).tag(tool)
                }
            }
            .pickerStyle(.menu)
            TextEditor(text: $model.rawArguments)
                .font(.system(.body, design: .monospaced))
                .frame(minHeight: 88)
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

    var body: some View {
        Panel(title: "Results", systemImage: "text.alignleft") {
            if records.isEmpty {
                ContentUnavailableView("No results yet", systemImage: "tray")
            } else {
                LazyVStack(alignment: .leading, spacing: 12) {
                    ForEach(records) { record in
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Label(record.title, systemImage: "chevron.right.circle")
                                    .font(.headline)
                                Spacer()
                                Text(record.toolName)
                                    .font(.caption.monospaced())
                                    .foregroundStyle(.secondary)
                            }
                            Text(record.body)
                                .font(.system(.caption, design: .monospaced))
                                .textSelection(.enabled)
                                .padding(10)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(.black.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
                        }
                        .padding(12)
                        .background(.background, in: RoundedRectangle(cornerRadius: 8))
                    }
                }
            }
        }
    }
}

struct Panel<Content: View>: View {
    let title: String
    let systemImage: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(title, systemImage: systemImage)
                .font(.title3.bold())
            content
        }
        .padding()
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
    }
}

#Preview {
    DashboardView(model: BrainDashboardModel())
}
