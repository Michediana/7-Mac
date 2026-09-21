//
//  JobRow.swift
//  7-Mac
//
//  One line of the queue: what is happening, how fast, and how to stop it.
//

import AppKit
import SwiftUI

struct JobRow: View {
    let job: Job

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundStyle(tint)
                .frame(width: 22)
                .padding(.top, 2)

            VStack(alignment: .leading, spacing: 4) {
                Text(job.title)
                    .font(.body.weight(.medium))
                    .lineLimit(1)
                    .truncationMode(.middle)

                if job.state == .running {
                    ProgressView(value: job.fractionCompleted)
                        .progressViewStyle(.linear)
                }

                Text(job.statusLine)
                    .font(.caption)
                    .foregroundStyle(job.state == .failed ? Color.red : .secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)

                if job.state == .running, !job.currentPath.isEmpty {
                    Text(job.currentPath)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }

            Spacer(minLength: 8)
            controls
        }
        .padding(.vertical, 6)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(job.title), \(job.statusLine)")
    }

    @ViewBuilder
    private var controls: some View {
        switch job.state {
        case .waiting, .running:
            Button("Cancel", systemImage: "xmark.circle.fill") { job.cancel() }
                .buttonStyle(.borderless)
                .labelStyle(.iconOnly)
                .foregroundStyle(.secondary)
        case .finished:
            if let url = job.resultURL {
                Button("Show in Finder", systemImage: "magnifyingglass.circle.fill") {
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                }
                .buttonStyle(.borderless)
                .labelStyle(.iconOnly)
                .foregroundStyle(.secondary)
            }
        case .failed, .cancelled:
            EmptyView()
        }
    }

    private var icon: String {
        switch job.state {
        case .waiting:   "clock"
        case .running:   job.isExtraction ? "arrow.down.document" : "archivebox"
        case .finished:  "checkmark.circle.fill"
        case .failed:    "exclamationmark.triangle.fill"
        case .cancelled: "slash.circle"
        }
    }

    private var tint: Color {
        switch job.state {
        case .finished: .green
        case .failed:   .red
        case .running:  .accentColor
        default:        .secondary
        }
    }
}
