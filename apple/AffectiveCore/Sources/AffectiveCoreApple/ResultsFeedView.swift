import SwiftUI

private let resultsBottomSentinelID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!

struct ResultsFeedView: View {
    let records: [ToolCallRecord]
    let listGeneration: UUID
    var pinToBottom: Binding<Bool>?
    var isEmbedded = false
    var emptyTitle: String = "No results yet"
    var emptySystemImage: String = "tray"

    @State private var scrollPosition: UUID?
    @State private var scrollRetryTask: Task<Void, Never>?
    @State private var scrollGeneration = 0
    @State private var ignoreVisibilityPinUpdates = false

    private var isPinned: Bool {
        pinToBottom?.wrappedValue ?? false
    }

    var body: some View {
        Group {
            if isEmbedded {
                resultsList
            } else {
                scrollContent
            }
        }
        .scrollDismissesKeyboard(isEmbedded ? .automatic : .interactively)
        .modifier(ResultsFeedPinDetectionModifier(
            records: records,
            pinToBottom: isEmbedded ? nil : pinToBottom,
            ignoreVisibilityPinUpdates: ignoreVisibilityPinUpdates
        ))
        .onChange(of: records.count) { _, _ in
            guard !isEmbedded, pinToBottom != nil, isPinned else { return }
            scrollToLatest(animated: true)
        }
        .onChange(of: listGeneration) { _, _ in
            guard !isEmbedded, pinToBottom != nil, isPinned else { return }
            scrollToLatest(animated: false)
        }
        .onAppear {
            guard !isEmbedded, pinToBottom != nil, isPinned else { return }
            scrollToLatest(animated: false)
        }
    }

    private var resultsList: some View {
        LazyVStack(alignment: .leading, spacing: 12) {
            if records.isEmpty {
                ContentUnavailableView(emptyTitle, systemImage: emptySystemImage)
                    .frame(maxWidth: .infinity)
            } else {
                ForEach(records) { record in
                    ResultRecordRow(record: record)
                        .id(record.id)
                }
            }
        }
        .id(listGeneration)
    }

    private var scrollContent: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 12) {
                if records.isEmpty {
                    ContentUnavailableView(emptyTitle, systemImage: emptySystemImage)
                        .frame(maxWidth: .infinity)
                        .padding(.top, 48)
                } else {
                    ForEach(records) { record in
                        ResultRecordRow(record: record)
                            .id(record.id)
                    }
                    Color.clear
                        .frame(height: 1)
                        .id(resultsBottomSentinelID)
                }
            }
            .padding()
            .id(listGeneration)
            .scrollTargetLayout()
        }
        .scrollPosition(id: $scrollPosition, anchor: .bottom)
    }

    private func scrollToLatest(animated: Bool) {
        scrollRetryTask?.cancel()
        scrollGeneration += 1
        let generation = scrollGeneration
        ignoreVisibilityPinUpdates = true

        let target = records.last?.id ?? resultsBottomSentinelID
        if animated {
            withAnimation(.easeOut(duration: 0.2)) {
                scrollPosition = target
            }
        } else {
            scrollPosition = target
        }

        scrollRetryTask = Task { @MainActor in
            defer {
                if generation == scrollGeneration {
                    ignoreVisibilityPinUpdates = false
                }
            }
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled, pinToBottom?.wrappedValue == true else { return }
            let retryTarget = records.last?.id ?? resultsBottomSentinelID
            guard scrollPosition != retryTarget else { return }
            scrollPosition = nil
            try? await Task.sleep(for: .milliseconds(50))
            guard !Task.isCancelled, pinToBottom?.wrappedValue == true else { return }
            withAnimation(.easeOut(duration: 0.15)) {
                scrollPosition = retryTarget
            }
        }
    }
}

private struct ResultsFeedPinDetectionModifier: ViewModifier {
    let records: [ToolCallRecord]
    let pinToBottom: Binding<Bool>?
    let ignoreVisibilityPinUpdates: Bool

    func body(content: Content) -> some View {
        if pinToBottom != nil {
            if #available(iOS 18.0, macOS 15.0, *) {
                content
                    .onScrollTargetVisibilityChange(idType: UUID.self) { visibleIDs in
                        guard !ignoreVisibilityPinUpdates else { return }
                        guard let lastID = records.last?.id else {
                            pinToBottom?.wrappedValue = records.isEmpty
                            return
                        }
                        pinToBottom?.wrappedValue = visibleIDs.contains(lastID)
                            || visibleIDs.contains(resultsBottomSentinelID)
                    }
            } else {
                content
                    .simultaneousGesture(
                        DragGesture(minimumDistance: 12).onChanged { _ in
                            pinToBottom?.wrappedValue = false
                        }
                    )
            }
        } else {
            content
        }
    }
}

struct ResultRecordRow: View {
    let record: ToolCallRecord
    @State private var showsDetailSheet = false

    private var bodyNeedsTruncation: Bool {
        record.body.count > 900 || record.body.filter(\.isNewline).count > 18
    }

    var body: some View {
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
                .lineLimit(18)
                .frame(maxWidth: .infinity, maxHeight: 280, alignment: .topLeading)
                .clipped()
                .padding(10)
                .background(.black.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
            if bodyNeedsTruncation {
                Button("Show full result") {
                    showsDetailSheet = true
                }
                .font(.caption)
            }
        }
        .padding(12)
        .background(PanelStyle.fill, in: RoundedRectangle(cornerRadius: 8))
        .sheet(isPresented: $showsDetailSheet) {
            ResultRecordDetailSheet(record: record)
        }
    }
}

struct ResultRecordDetailSheet: View {
    @Environment(\.dismiss) private var dismiss
    let record: ToolCallRecord

    var body: some View {
        NavigationStack {
            ScrollView {
                Text(record.body)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
            }
            .navigationTitle(record.title)
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
        }
    }
}

struct SeedDraftPreview: View {
    @Bindable var model: BrainDashboardModel

    var body: some View {
        Text(model.seedDraftPreview)
            .font(.system(.caption, design: .monospaced))
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, minHeight: 260, alignment: .topLeading)
            .padding(10)
            .background(.black.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))
            .onAppear {
                model.scheduleSeedPreviewUpdate()
            }
            .onChange(of: model.newBrainName) { _, _ in
                model.scheduleSeedPreviewUpdate()
            }
            .onChange(of: model.seedCoreValues) { _, _ in
                model.scheduleSeedPreviewUpdate()
            }
            .onChange(of: model.seedOperatingTendencies) { _, _ in
                model.scheduleSeedPreviewUpdate()
            }
            .onChange(of: model.seedWants) { _, _ in
                model.scheduleSeedPreviewUpdate()
            }
            .onChange(of: model.seedGoals) { _, _ in
                model.scheduleSeedPreviewUpdate()
            }
            .onChange(of: model.seedPrinciples) { _, _ in
                model.scheduleSeedPreviewUpdate()
            }
    }
}

struct UserTextRequestPreview: View {
    let userText: String

    @State private var displayedText = ""
    @State private var previewTask: Task<Void, Never>?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Request")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(displayedText)
                .font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.black.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))
        }
        .onAppear {
            schedulePreviewUpdate(for: userText)
        }
        .onChange(of: userText) { _, newValue in
            schedulePreviewUpdate(for: newValue)
        }
    }

    private func schedulePreviewUpdate(for text: String) {
        previewTask?.cancel()
        previewTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(200))
            guard !Task.isCancelled else { return }
            let sample = text.isEmpty ? "hello" : text
            displayedText = """
            { "text": "\(sample)" }
            """
        }
    }
}
