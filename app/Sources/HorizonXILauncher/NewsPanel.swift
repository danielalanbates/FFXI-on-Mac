import SwiftUI
import AppKit

/// The left panel's news: the selected world's own posts, newest first (`ServerFeeds.news`).
/// Each row is the post's category chip, its title and when; patch notes add a line or two of
/// summary. A click opens the post in a sheet (`NewsSheet`). Shown only when there are posts:
/// a world without a feed has no panel at all, and nothing here is ever written by the launcher.
struct NewsPanel: View {
    let items: [NewsItem]
    /// `Server.newsPageURL`, for the sheet's link to the post on the world's site.
    let pageTemplate: String
    /// About six rows; the rest scroll.
    var maxHeight: CGFloat = 318

    @State private var open: NewsItem?
    @State private var hover: String?
    @State private var contentHeight: CGFloat = 0

    var body: some View {
        ScrollView(.vertical, showsIndicators: true) {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(items.enumerated()), id: \.element.id) { n, item in
                    if n > 0 { Rectangle().fill(Vana.stroke).frame(height: 1).padding(.horizontal, 10) }
                    row(item)
                }
            }
            .background(GeometryReader { g in
                Color.clear.preference(key: NewsHeightKey.self, value: g.size.height)
            })
        }
        .onPreferenceChange(NewsHeightKey.self) { contentHeight = $0 }
        .frame(height: contentHeight > 0 ? min(contentHeight, maxHeight) : maxHeight)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.black.opacity(0.22)))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Vana.stroke))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .sheet(item: $open) { item in
            NewsSheet(item: item, page: News.pageURL(template: pageTemplate, slug: item.slug))
        }
    }

    private func row(_ item: NewsItem) -> some View {
        Button { open = item } label: {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    NewsChip(item: item)
                    Spacer(minLength: 4)
                    Text(News.shortDate(item.date, fallback: item.printDate))
                        .font(.system(size: 11)).foregroundStyle(Vana.muted)
                        .help(item.printDate)
                }
                Text(item.title)
                    .font(.system(size: 13, weight: .medium)).foregroundStyle(Vana.text)
                    .lineLimit(2).multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                if item.showsExcerpt {
                    Text(item.excerpt)
                        .font(.system(size: 12)).foregroundStyle(Vana.muted)
                        .lineLimit(2).multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 9)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(hover == item.id ? Vana.crystal.opacity(0.07) : Color.clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { inside in
            hover = inside ? item.id : (hover == item.id ? nil : hover)
            if inside { NSCursor.pointingHand.set() } else { NSCursor.arrow.set() }
        }
    }
}

private struct NewsHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

/// "PATCH NOTES", "SERVER NOTICE": the feed's own category, tinted by kind.
struct NewsChip: View {
    let item: NewsItem

    private var tint: Color {
        switch item.category {
        case "patch-notes": return Vana.gold
        case "server-notices": return Vana.crystal
        case "known-issues": return Vana.ember
        default: return Vana.muted
        }
    }

    var body: some View {
        Text(item.label.uppercased())
            .font(.system(size: 10, weight: .semibold)).tracking(1)
            .foregroundStyle(tint)
            .lineLimit(1)
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(Capsule().fill(tint.opacity(0.14)))
            .overlay(Capsule().stroke(tint.opacity(0.35), lineWidth: 0.5))
    }
}

/// One post, read in the launcher: its blocks (`NewsHTML`), nothing loaded from anywhere. The
/// post's own page on the world's site is one click away when the world publishes one.
struct NewsSheet: View {
    let item: NewsItem
    let page: URL?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                NewsChip(item: item)
                Text([item.printDate, item.author].filter { !$0.isEmpty }.joined(separator: " · "))
                    .font(.system(size: 12)).foregroundStyle(Vana.muted)
                Spacer()
            }
            Text(item.title)
                .font(.system(size: 19, weight: .semibold, design: .serif))
                .foregroundStyle(Vana.text)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
            if !item.body.isEmpty {
                Rectangle().fill(Vana.stroke).frame(height: 1)
                ScrollView {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(Array(item.body.enumerated()), id: \.offset) { _, b in block(b) }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
                }
                .frame(maxHeight: 420)
            }
            HStack {
                if let page {
                    Link(destination: page) {
                        Label(page.host ?? "Open", systemImage: "arrow.up.forward.square")
                            .font(.system(size: 12))
                    }
                    .help(page.absoluteString)
                }
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(22)
        .frame(width: 540)
        .background(Vana.backdrop)
    }

    @ViewBuilder private func block(_ b: NewsBlock) -> some View {
        switch b {
        case .heading(let a):
            Text(a).font(.system(size: 14, weight: .semibold, design: .serif))
                .foregroundStyle(Vana.gold).padding(.top, 6)
                .fixedSize(horizontal: false, vertical: true)
        case .paragraph(let a):
            Text(a).font(.system(size: 13)).foregroundStyle(Vana.text)
                .fixedSize(horizontal: false, vertical: true)
        case .bullet(let level, let a):
            HStack(alignment: .firstTextBaseline, spacing: 7) {
                Text(level == 0 ? "•" : "◦").font(.system(size: 13)).foregroundStyle(Vana.crystalDim)
                Text(a).font(.system(size: 13)).foregroundStyle(Vana.text)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.leading, CGFloat(level) * 16)
        }
    }
}
