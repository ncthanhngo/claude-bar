import AppKit
import SwiftUI

/// The GitLab pane of the Full popover: the latest pipeline for each watched
/// project, plus an inline add/remove form. Reads everything from
/// `PipelineStore`; the same store drives the menu-bar pipeline indicator.
struct GitLabPaneView: View {
    @EnvironmentObject private var pipelineStore: PipelineStore
    @State private var showAdd = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().opacity(0.3)
            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    if pipelineStore.watches.isEmpty {
                        emptyState
                    } else {
                        ForEach(pipelineStore.watches) { watch in
                            GitLabWatchRow(
                                watch: watch,
                                pipeline: pipelineStore.latest[watch.id],
                                onDelete: { pipelineStore.removeWatch(id: watch.id) }
                            )
                            Divider().opacity(0.15)
                        }
                    }
                    if showAdd {
                        GitLabWatchManager(onAdded: { showAdd = false })
                            .padding(.top, 4)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text("Pipelines")
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(.primary.opacity(0.78))
            if pipelineStore.anyRunning {
                Text("\(pipelineStore.runningCount) running")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(.orange)
            }
            Spacer()
            Button {
                Task { await pipelineStore.refresh() }
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.plain)
            .foregroundColor(.secondary)
            .help("Refresh pipelines now")
            Button {
                showAdd.toggle()
            } label: {
                Image(systemName: showAdd ? "xmark" : "plus")
            }
            .buttonStyle(.plain)
            .foregroundColor(.secondary)
            .help(showAdd ? "Close" : "Watch a project")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("No projects watched yet.")
                .font(.system(size: 12))
                .foregroundColor(.secondary)
            Text("Tap + to watch a GitLab project — its pipeline status will show here and in the menu bar while it runs.")
                .font(.system(size: 11))
                .foregroundColor(.secondary.opacity(0.8))
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 8)
    }
}

/// One watched project + its latest pipeline. Click the arrow to open the
/// pipeline in the browser; trash removes the watch.
private struct GitLabWatchRow: View {
    let watch: GitLabWatch
    let pipeline: Pipeline?
    let onDelete: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: pipeline?.status.sfSymbol ?? "questionmark.circle")
                .foregroundColor(pipeline?.status.tint ?? .secondary)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 2) {
                Text(watch.label)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                HStack(spacing: 6) {
                    if let ref = pipeline?.ref ?? watch.ref, !ref.isEmpty {
                        Text(ref).lineLimit(1)
                    }
                    if let sha = pipeline?.shortSHA, !sha.isEmpty {
                        Text(sha).monospaced()
                    }
                    if let created = pipeline?.createdAt {
                        Text(Self.relative(created))
                    }
                }
                .font(.system(size: 10))
                .foregroundColor(.secondary)
            }
            Spacer(minLength: 4)
            if let pipe = pipeline {
                Text(pipe.status.displayName)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(pipe.status.tint)
            } else {
                Text("—").font(.system(size: 10)).foregroundColor(.secondary)
            }
            if let urlStr = pipeline?.webUrl, let url = URL(string: urlStr) {
                Button {
                    NSWorkspace.shared.open(url)
                } label: {
                    Image(systemName: "arrow.up.right.square")
                }
                .buttonStyle(.plain)
                .foregroundColor(.secondary)
                .help("Open pipeline in browser")
            }
            Button {
                onDelete()
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.plain)
            .foregroundColor(.secondary)
            .help("Stop watching")
        }
        .padding(.vertical, 4)
    }

    private static func relative(_ date: Date) -> String {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        return f.localizedString(for: date, relativeTo: Date())
    }
}
