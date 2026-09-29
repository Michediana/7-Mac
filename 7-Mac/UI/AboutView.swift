//
//  AboutView.swift
//  7-Mac
//
//  About 7-Mac: who made what, and under which terms.
//
//  The licences are shown from the files that ship, not retyped: 7-Zip's
//  three texts travel inside SevenZipKit.framework with the engine they
//  cover, and 7-Mac's own is a copy of the repository's LICENSE that a test
//  keeps identical. The unRAR restriction in particular has to be reproduced
//  word for word, which is easiest to get right by never writing it down.
//

import AppKit
import SwiftUI
import SevenZipKit

/// One licence text the window can show.
enum CreditDocument: String, CaseIterable, Identifiable {
    case app, sevenZip, lgpl, unRAR

    var id: Self { self }

    var title: LocalizedStringKey {
        switch self {
        case .app: "7-Mac"
        case .sevenZip: "7-Zip"
        case .lgpl: "GNU LGPL"
        case .unRAR: "unRAR"
        }
    }

    /// Where the text is: the app bundle for 7-Mac's own, the framework's
    /// resources for everything that came with the engine.
    var url: URL? {
        switch self {
        case .app: Bundle.main.url(forResource: "7-Mac-License", withExtension: "txt")
        case .sevenZip: Self.engine.url(forResource: "7-Zip-License", withExtension: "txt")
        case .lgpl: Self.engine.url(forResource: "7-Zip-copying", withExtension: "txt")
        case .unRAR: Self.engine.url(forResource: "7-Zip-unRarLicense", withExtension: "txt")
        }
    }

    /// The text, with 7-Zip's Windows line endings made ordinary.
    var text: String? {
        guard let url, let data = try? Data(contentsOf: url) else { return nil }
        let text = String(decoding: data, as: UTF8.self)
        return text.replacingOccurrences(of: "\r\n", with: "\n")
    }

    private static var engine: Bundle { Bundle(for: SZKEngine.self) }
}

struct AboutView: View {
    @State private var shown: CreditDocument = .app

    private var version: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return String(localized: "Version \(short) (\(build))")
    }

    var body: some View {
        VStack(spacing: 0) {
            header
                .padding(20)
            Divider()
            VStack(alignment: .leading, spacing: 10) {
                Picker("Licence", selection: $shown) {
                    ForEach(CreditDocument.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                Text(summary(of: shown))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                ScrollView {
                    Text(shown.text ?? String(localized: "This text is missing from the app. It should not be: please report it."))
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(10)
                }
                .background(.background.secondary, in: RoundedRectangle(cornerRadius: 6))
                .accessibilityLabel(Text("Licence text"))
            }
            .padding(20)
        }
        .frame(width: 600, height: 620)
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 16) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 80, height: 80)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text("7-Mac")
                    .font(.title.bold())
                Text(version)
                    .foregroundStyle(.secondary)
                Text("A native Mac app for 7-Zip, with the 7-Zip \(SZKEngine.upstreamVersion) engine built in.")
                    .padding(.top, 6)
                    .fixedSize(horizontal: false, vertical: true)
                Text("© 2026 Michediana. 7-Mac is free software under the MIT License.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(.top, 2)
                Text("7-Zip © 1999–2026 Igor Pavlov. unRAR code © Alexander Roshal.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                HStack(spacing: 14) {
                    Link("7-zip.org", destination: URL(string: "https://www.7-zip.org")!)
                    Link("7-Zip source", destination: URL(string: "https://github.com/ip7z/7zip")!)
                }
                .font(.callout)
                .padding(.top, 4)
            }
            Spacer(minLength: 0)
        }
    }

    private func summary(of document: CreditDocument) -> String {
        switch document {
        case .app:
            String(localized: "The app itself: its interface and the Swift code around the engine.")
        case .sevenZip:
            String(localized: "The 7-Zip engine is in SevenZipKit.framework, inside the app, and is covered by these terms. It is linked dynamically, so it can be replaced with another build of the same library.")
        case .lgpl:
            String(localized: "The GNU Lesser General Public License, version 2.1, that most of 7-Zip is distributed under.")
        case .unRAR:
            String(localized: "The RAR decoder comes with an extra restriction: it may not be used to re-create the RAR compression algorithm. 7-Mac reads RAR archives and never writes them.")
        }
    }
}

#Preview {
    AboutView()
}
