import SwiftUI

struct MemoryTimelineView: View {
    @ObservedObject var viewModel: MemoryTimelineViewModel
    @ObservedObject var reminderManager: ReminderManager
    @State private var selectedMemory: MemoryTimelineItem?

    var body: some View {
        ZStack {
            AppBackground()

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    heroCard
                    searchCard
                    filterCard
                    remindersSection
                    memoriesSection
                }
                .padding(20)
            }
        }
        .navigationTitle("Memory")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $selectedMemory) { item in
            MemoryDetailView(item: item)
        }
    }

    private var heroCard: some View {
        GlassCard(padding: 22) {
            VStack(alignment: .leading, spacing: 16) {
                SectionHeader(
                    "Memory Timeline",
                    subtitle: "Search, filter, and revisit the moments Watersheep captured for you."
                )

                HStack(spacing: 10) {
                    StatusChip("\(viewModel.filteredItems.count) Visible", tone: .success)
                    StatusChip("\(viewModel.items.count) Total Memories", tone: .neutral)
                    StatusChip(viewModel.selectedDateFilter.rawValue, tone: .warning)
                }

                NavigationLink(destination: KnowledgeGraphView()) {
                    HStack(spacing: 8) {
                        Image(systemName: "point.3.connected.trianglepath.dotted")
                            .font(.system(size: 15, weight: .semibold))
                        Text("Knowledge Graph")
                            .font(.subheadline.weight(.semibold))
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .frame(maxWidth: .infinity)
                    .background(
                        LinearGradient(
                            colors: [.indigo.opacity(0.7), .purple.opacity(0.7)],
                            startPoint: .leading,
                            endPoint: .trailing
                        ),
                        in: RoundedRectangle(cornerRadius: 14, style: .continuous)
                    )
                }
            }
        }
    }

    private var searchCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 12) {
                SectionHeader("Search", subtitle: "Find memories by place, object, or summary text.")

                HStack(spacing: 12) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(Color.white.opacity(0.55))

                    TextField("Search memories, objects, places", text: $viewModel.searchText)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .foregroundStyle(.white)

                    if !viewModel.searchText.isEmpty {
                        Button {
                            viewModel.searchText = ""
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(Color.white.opacity(0.55))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 14)
                .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            }
        }
    }

    private var filterCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 16) {
                SectionHeader("Filters", subtitle: "Narrow the timeline by object, place, and time.")

                MemoryFilterSection(
                    title: "Object",
                    options: viewModel.objectFilters,
                    selection: $viewModel.selectedObjectFilter
                )

                MemoryFilterSection(
                    title: "Place",
                    options: viewModel.placeFilters,
                    selection: $viewModel.selectedPlaceFilter
                )

                VStack(alignment: .leading, spacing: 8) {
                    Text("DATE")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Color.white.opacity(0.5))

                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 10) {
                            ForEach(MemoryTimelineViewModel.DateFilter.allCases) { filter in
                                FilterChip(
                                    title: filter.rawValue,
                                    isSelected: viewModel.selectedDateFilter == filter
                                ) {
                                    viewModel.selectedDateFilter = filter
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    private var memoriesSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            SectionHeader("Timeline", subtitle: "Tap a memory card to open the full detail view.")

            if viewModel.filteredItems.isEmpty {
                GlassCard {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("No memories found")
                            .font(.headline)
                            .foregroundStyle(.white)
                        Text("Try clearing a filter or searching for a different object, place, or date.")
                            .foregroundStyle(Color.white.opacity(0.7))
                    }
                }
            } else {
                LazyVStack(spacing: 14) {
                    ForEach(viewModel.filteredItems) { item in
                        Button {
                            selectedMemory = item
                        } label: {
                            MemoryCardView(item: item)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    private var remindersSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            SectionHeader("Reminders", subtitle: "Local reminders scheduled from the assistant.")

            if reminderManager.upcomingReminders.isEmpty {
                GlassCard {
                    Text("No reminders scheduled yet.")
                        .foregroundStyle(Color.white.opacity(0.7))
                }
            } else {
                LazyVStack(spacing: 12) {
                    ForEach(reminderManager.upcomingReminders.prefix(5)) { reminder in
                        GlassCard {
                            VStack(alignment: .leading, spacing: 10) {
                                HStack {
                                    Text(reminder.title)
                                        .font(.headline)
                                        .foregroundStyle(.white)
                                    Spacer()
                                    Text(reminder.dueDate.formatted(date: .abbreviated, time: .shortened))
                                        .font(.caption)
                                        .foregroundStyle(Color.white.opacity(0.6))
                                }

                                Text(reminder.sourceText)
                                    .font(.subheadline)
                                    .foregroundStyle(Color.white.opacity(0.72))
                            }
                        }
                    }
                }
            }
        }
    }
}

private struct MemoryFilterSection: View {
    let title: String
    let options: [String]
    @Binding var selection: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title.uppercased())
                .font(.caption.weight(.semibold))
                .foregroundStyle(Color.white.opacity(0.5))

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(options, id: \.self) { option in
                        FilterChip(title: option, isSelected: selection == option) {
                            selection = option
                        }
                    }
                }
            }
        }
    }
}

private struct FilterChip: View {
    let title: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(isSelected ? .black : .white)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(
                    isSelected ? Color.white : Color.white.opacity(0.08),
                    in: Capsule()
                )
        }
        .buttonStyle(.plain)
    }
}

private struct MemoryCardView: View {
    let item: MemoryTimelineItem

    var body: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .top, spacing: 14) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 20, style: .continuous)
                            .fill(gradient)
                            .frame(width: 82, height: 82)

                        Image(systemName: item.thumbnailSymbol ?? icon(for: item.kind))
                            .font(.system(size: 28, weight: .semibold))
                            .foregroundStyle(.white)
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        HStack(alignment: .top) {
                            Text(item.title)
                                .font(.headline)
                                .foregroundStyle(.white)
                                .multilineTextAlignment(.leading)
                            Spacer()
                            Text(item.timestamp.formatted(date: .abbreviated, time: .shortened))
                                .font(.caption)
                                .foregroundStyle(Color.white.opacity(0.55))
                        }

                        Text(item.summary)
                            .font(.subheadline)
                            .foregroundStyle(Color.white.opacity(0.78))
                            .lineLimit(3)

                        HStack(spacing: 10) {
                            Label(item.location, systemImage: "mappin.and.ellipse")
                            Text(item.kind.rawValue.capitalized)
                        }
                        .font(.caption.weight(.medium))
                        .foregroundStyle(Color.white.opacity(0.62))
                    }
                }

                if !item.detectedObjects.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(item.detectedObjects, id: \.self) { object in
                                Text(object.capitalized)
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.white)
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 8)
                                    .background(Color.white.opacity(0.07), in: Capsule())
                            }
                        }
                    }
                }
            }
        }
    }

    private var gradient: LinearGradient {
        switch item.kind {
        case .memory:
            return LinearGradient(colors: [.cyan, .blue], startPoint: .topLeading, endPoint: .bottomTrailing)
        case .system:
            return LinearGradient(colors: [.gray, .gray.opacity(0.7)], startPoint: .topLeading, endPoint: .bottomTrailing)
        case .connection:
            return LinearGradient(colors: [.mint, .teal], startPoint: .topLeading, endPoint: .bottomTrailing)
        case .scene:
            return LinearGradient(colors: [.green, .teal], startPoint: .topLeading, endPoint: .bottomTrailing)
        case .command:
            return LinearGradient(colors: [.orange, .pink], startPoint: .topLeading, endPoint: .bottomTrailing)
        case .assistant:
            return LinearGradient(colors: [.indigo, .purple], startPoint: .topLeading, endPoint: .bottomTrailing)
        }
    }

    private func icon(for kind: MemoryTimelineItem.Kind) -> String {
        switch kind {
        case .memory:
            return "photo.on.rectangle"
        case .system:
            return "gearshape.2"
        case .connection:
            return "dot.radiowaves.left.and.right"
        case .scene:
            return "camera.viewfinder"
        case .command:
            return "waveform"
        case .assistant:
            return "sparkles"
        }
    }
}

private struct MemoryDetailView: View {
    let item: MemoryTimelineItem
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ZStack {
                AppBackground()

                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        heroCard
                        metadataCard
                        objectsCard
                    }
                    .padding(20)
                }
            }
            .navigationTitle("Memory Detail")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
        }
    }

    private var heroCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 16) {
                ZStack {
                    RoundedRectangle(cornerRadius: 28, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [.cyan.opacity(0.95), .blue.opacity(0.8)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .frame(height: 220)

                    Image(systemName: item.thumbnailSymbol ?? "photo")
                        .font(.system(size: 62, weight: .bold))
                        .foregroundStyle(.white)
                }

                Text(item.title)
                    .font(.system(size: 30, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)

                Text(item.summary)
                    .foregroundStyle(Color.white.opacity(0.8))
            }
        }
    }

    private var metadataCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 12) {
                SectionHeader("Metadata", subtitle: "Core details attached to this memory snapshot.")
                DetailRow(title: "Location", value: item.location)
                DetailRow(title: "Timestamp", value: item.timestamp.formatted(date: .complete, time: .shortened))
                DetailRow(title: "Category", value: item.kind.rawValue.capitalized)
            }
        }
    }

    private var objectsCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 12) {
                SectionHeader("Detected Objects", subtitle: "Objects or concepts linked to this memory.")
                if item.detectedObjects.isEmpty {
                    Text("No detected objects were stored for this memory.")
                        .foregroundStyle(Color.white.opacity(0.7))
                } else {
                    FlowLayout(objects: item.detectedObjects)
                }
            }
        }
    }
}

private struct FlowLayout: View {
    let objects: [String]

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 110), spacing: 10)], spacing: 10) {
            ForEach(objects, id: \.self) { object in
                Text(object.capitalized)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 12)
                    .frame(maxWidth: .infinity)
                    .background(Color.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            }
        }
    }
}
