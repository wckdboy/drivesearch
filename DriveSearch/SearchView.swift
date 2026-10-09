import ProviderKit
import SwiftUI
import UIKit

struct RootView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        Group {
            if horizontalRegular {
                NavigationSplitView {
                    AccountsView()
                } detail: {
                    SearchView()
                }
            } else {
                TabView {
                    SearchView()
                        .tabItem { Label("Search", systemImage: "magnifyingglass") }
                    AccountsView()
                        .tabItem { Label("Accounts", systemImage: "externaldrive") }
                }
            }
        }
        .sheet(isPresented: Binding(
            get: { model.quickLookURL != nil },
            set: { if !$0 { model.quickLookURL = nil } }
        )) {
            if let url = model.quickLookURL {
                NavigationStack {
                    QuickLookPreview(url: url)
                        .ignoresSafeArea()
                        .navigationTitle(url.lastPathComponent)
                        .navigationBarTitleDisplayMode(.inline)
                        .toolbar {
                            ToolbarItem(placement: .cancellationAction) {
                                Button("Done") { model.quickLookURL = nil }
                            }
                        }
                }
            }
        }
    }

    @Environment(\.horizontalSizeClass) private var sizeClass
    private var horizontalRegular: Bool { sizeClass == .regular }
}

struct SearchView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        NavigationStack {
            VStack(spacing: 0) {
                chipRow
                if let message = model.statusMessage {
                    Text(message)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal)
                        .padding(.bottom, 6)
                }
                List(model.results) { result in
                    Button {
                        Task { await model.open(result) }
                    } label: {
                        ResultRow(result: result)
                    }
                    .contextMenu {
                        Button("Quick Look") { Task { await model.download(result) } }
                        if let url = result.webURL {
                            Button("Open in browser") { Task { await UIApplication.shared.open(url) } }
                        }
                    }
                }
                .overlay {
                    if model.results.isEmpty {
                        ContentUnavailableView(
                            "Search your drives",
                            systemImage: "magnifyingglass",
                            description: Text("Names are indexed on this device. Try ext:pdf, type:image, size:>5mb, mtime:<7d, or in:Docs.")
                        )
                    }
                }
            }
            .navigationTitle("DriveSearch")
            .searchable(text: $model.query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Name, ext:, size:, in:")
            .onChange(of: model.query) { _, _ in model.scheduleSearch() }
        }
    }

    private var chipRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                chip("All", selected: model.selected.isEmpty) { model.clearSelection() }
                ForEach(model.accounts) { account in
                    chip(account.displayName, selected: model.selected.contains(account.id)) {
                        model.toggle(account.id)
                    }
                }
            }
            .padding(.horizontal)
            .padding(.vertical, 8)
        }
    }

    private func chip(_ title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.subheadline.weight(.medium))
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(selected ? Color.accentColor.opacity(0.18) : Color.secondary.opacity(0.12), in: Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

private struct ResultRow: View {
    let result: SearchResult

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Image(systemName: result.kind == .folder ? "folder" : "doc")
                .foregroundStyle(.secondary)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(result.name)
                    .foregroundStyle(.primary)
                Text("\(result.accountName) · \(result.path)")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 2) {
                if result.kind == .file {
                    Text(ByteCountFormatter.string(fromByteCount: Int64(clamping: result.size), countStyle: .file))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                Text(result.modified, format: .dateTime.year().month().day())
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 2)
    }
}
