import AppKit
import LimitGuardCore
import SwiftUI

/// What the About window shows — social profiles, ways to support the project, the app's name,
/// version and links, books, other projects and blogs — without its scroll view, size and
/// background: the About window (`AboutView`) and Settings → Support (`SupportSettingsView`) each
/// put it in their own.
struct AboutContentView: View {
    static let iconSize: CGFloat = 64

    @Environment(\.colorScheme) private var scheme
    private var palette: PanelPalette { PanelPalette.forScheme(scheme) }

    var body: some View {
        VStack(spacing: 20) {
            socialSection
            supportSection
            header
            section(L10n.About.books) {
                VStack(spacing: 8) {
                    ForEach(AboutData.books) { BookCard(book: $0, palette: palette) }
                }
            }
            section(L10n.About.openSource) {
                VStack(spacing: 8) {
                    ForEach(AboutData.projects) { project in
                        LinkRow(title: project.title, subtitle: project.subtitle, symbol: project.symbol,
                                url: project.url, palette: palette)
                    }
                    Text(L10n.About.fullList)
                        .font(.caption)
                        .foregroundStyle(palette.secondaryText)
                }
            }
            section(L10n.About.blogs) {
                VStack(spacing: 8) {
                    ForEach(AboutData.blogs) { blog in
                        LinkRow(title: blog.title, subtitle: blog.subtitle, symbol: "text.book.closed",
                                url: blog.url, palette: palette)
                    }
                }
            }
            footer
        }
    }

    private var socialSection: some View {
        section(L10n.About.findMeOnline) {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 6), spacing: 8) {
                ForEach(SocialProfile.all) { SocialButton(profile: $0, palette: palette) }
            }
        }
    }

    private var supportSection: some View {
        section(L10n.About.supportProject) {
            HStack(spacing: 8) {
                ForEach(AboutData.donations) { donation in
                    Button { NSWorkspace.shared.open(donation.url) } label: {
                        Label(donation.title, systemImage: donation.symbol)
                            .font(.callout.weight(.medium))
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 8)
                            .foregroundStyle(.white)
                            .background(LinearGradient(colors: [PanelPalette.teal, PanelPalette.indigo],
                                                       startPoint: .leading, endPoint: .trailing).opacity(0.85),
                                        in: RoundedRectangle(cornerRadius: 8))
                    }
                    .buttonStyle(.plain)
                    .help(donation.url.absoluteString)
                }
            }
        }
    }

    private var header: some View {
        VStack(spacing: 8) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .interpolation(.high)
                .frame(width: Self.iconSize, height: Self.iconSize)
                .accessibilityLabel(L10n.About.iconAccessibility(AppInfo.name))
            Text(AppInfo.name)
                .font(.title2.weight(.semibold))
                .foregroundStyle(palette.primaryText)
            Text(L10n.About.version(AppInfo.version))
                .foregroundStyle(palette.secondaryText)
                .textSelection(.enabled)
            VStack(spacing: 4) {
                Link(L10n.About.website, destination: AboutData.websiteURL)
                    .help(AboutData.websiteURL.absoluteString)
                HStack(spacing: 16) {
                    Link(L10n.About.sourceCode, destination: AppInfo.repositoryURL)
                    Link(L10n.About.license, destination: AppInfo.licenseURL)
                    Link(L10n.Common.changelog, destination: UpdateLinks.changelog)
                }
                Link(L10n.About.reportBug, destination: AboutData.issuesURL)
            }
            .tint(PanelPalette.teal)
            .font(.callout)
        }
    }

    private var footer: some View {
        VStack(spacing: 6) {
            if let copyright = AppInfo.copyright {
                Text(copyright).font(.caption)
            }
        }
        .foregroundStyle(palette.secondaryText)
        .multilineTextAlignment(.center)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title.localizedUppercase)
                .font(.caption.weight(.semibold))
                .tracking(0.8)
                .foregroundStyle(PanelPalette.teal)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct BookCard: View {
    let book: AboutData.Book
    let palette: PanelPalette

    var body: some View {
        HStack(spacing: 12) {
            AsyncImage(url: book.coverURL) { image in
                image.resizable().aspectRatio(contentMode: .fit)
            } placeholder: {
                Image(systemName: "book.closed.fill")
                    .foregroundStyle(palette.secondaryText)
            }
            .frame(width: 44, height: 62)
            .clipShape(RoundedRectangle(cornerRadius: 3))
            VStack(alignment: .leading, spacing: 6) {
                Text(book.titleLine)
                    .font(.callout.weight(.medium))
                    .foregroundStyle(palette.primaryText)
                    .multilineTextAlignment(.leading)
                HStack(spacing: 8) {
                    languageButton("🌐 English", url: book.englishURL)
                    languageButton("🇹🇷 Türkçe", url: book.turkishURL)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(8)
        .background(palette.hover.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(palette.hairline))
    }

    private func languageButton(_ title: String, url: URL) -> some View {
        Button { NSWorkspace.shared.open(url) } label: {
            Text(title)
                .font(.caption.weight(.semibold))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 5)
                .foregroundStyle(.white)
                .background(PanelPalette.indigo.opacity(0.85), in: RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .help(url.absoluteString)
    }
}

private struct LinkRow: View {
    let title: String
    let subtitle: String
    let symbol: String
    let url: URL
    let palette: PanelPalette

    var body: some View {
        Button { NSWorkspace.shared.open(url) } label: {
            HStack(spacing: 10) {
                Image(systemName: symbol)
                    .frame(width: 22)
                    .foregroundStyle(PanelPalette.teal)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(.callout.weight(.medium)).foregroundStyle(palette.primaryText)
                    Text(subtitle).font(.caption).foregroundStyle(palette.secondaryText)
                }
                Spacer(minLength: 0)
                Image(systemName: "arrow.up.right").font(.caption).foregroundStyle(palette.secondaryText)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(palette.hover.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(palette.hairline))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

private struct SocialButton: View {
    let profile: SocialProfile
    let palette: PanelPalette
    @State private var hovering = false

    var body: some View {
        Button { NSWorkspace.shared.open(profile.url) } label: {
            glyph
                .foregroundStyle(hovering ? PanelPalette.teal : palette.primaryText)
                .frame(maxWidth: .infinity)
                .frame(height: 40)
                .background(palette.hover.opacity(hovering ? 0.9 : 0.5), in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(palette.hairline))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(profile.name)
        .accessibilityLabel(profile.name)
    }

    @ViewBuilder private var glyph: some View {
        if let shape = SocialIcons.shape(for: profile.id) {
            shape.fill().frame(width: 20, height: 20)
        } else if !SocialIcons.hasPathData(for: profile.id) {
            // No brand glyph (Ekşi Sözlük isn't in Simple Icons): the name's initial, lowercased
            // like Ekşi Sözlük's own "e".
            Text(profile.name.prefix(1).lowercased())
                .font(.system(size: 24, weight: .bold, design: .rounded))
        } else {
            // Path data that doesn't parse: a neutral glyph rather than an empty button.
            Image(systemName: "globe").font(.system(size: 18))
        }
    }
}
