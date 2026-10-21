import SwiftUI

/// About tab: version, project links and credits. Owns its `NavigationStack`
/// for the settings toolbar.
struct AboutView: View {
    /// Observed so labels redraw when the language changes.
    @EnvironmentObject private var loc: Localizer

    @State private var showSettings = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 18) {
                    header.cascadeItem(0)
                    summary.cascadeItem(1)
                    thanks.cascadeItem(2)
                    builtWith.cascadeItem(3)
                }
                .padding(20)
            }
            // Uses the same bright backdrop level as the Install tab.
            .background(AppBackground())
            .toolbar { settingsToolbarItem(isPresented: $showSettings) }
            .sheet(isPresented: $showSettings) { SettingsView() }
        }
    }

    // MARK: Header

    private var header: some View {
        BrandHeader(icon: "info.circle.fill", image: "AppLogo", title: "Side+",
                    subtitle: L("an app by Frizzle")) {
            StatusPill(text: versionText, systemImage: "tag.fill", color: Theme.accent2)
        }
    }

    /// Version and build number, read from the app bundle.
    private var versionText: String {
        let short = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1"
        return L("Version %@ (%@)", short, build)
    }

    // MARK: What it is

    private var summary: some View {
        PanelCard {
            VStack(alignment: .leading, spacing: 10) {
                sectionTitle(L("About"), systemImage: "info.circle.fill")
                Text(L("SideInstaller installs SideStore and LiveContainer straight onto your iPhone, with no PC involved."))
                    .font(.subheadline)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: Special thanks

    private var thanks: some View {
        PanelCard {
            VStack(alignment: .leading, spacing: 16) {
                sectionTitle(L("Special thanks"), systemImage: "heart.fill")
                AboutRow(systemImage: "hammer.fill",
                         tint: Theme.accent,
                         title: "jkcoxson",
                         detail: L("For idevice, the library SideInstaller talks to your iPhone through. None of this exists without it."),
                         urlString: "https://github.com/jkcoxson/idevice")
                AboutRow(systemImage: "ladybug.fill",
                         tint: .orange,
                         title: "Vexon",
                         detail: L("For the support, and for spotting the bugs that got fixed because of it."))
                AboutRow(systemImage: "character.bubble.fill",
                         tint: Color(red: 0.95, green: 0.35, blue: 0.45),
                         title: "so-5699",
                         detail: L("For the Japanese translation."),
                         urlString: "https://github.com/so-5699")
            }
        }
    }

    // MARK: Built with

    private var builtWith: some View {
        PanelCard {
            VStack(alignment: .leading, spacing: 16) {
                sectionTitle(L("Built with"), systemImage: "shippingbox.fill")
                Text(L("The open source work this app is built on:"))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                AboutRow(systemImage: "iphone.gen3",
                         tint: Theme.accent2,
                         title: "idevice",
                         detail: L("Pairing, the tunnel and the install itself. By jkcoxson, MIT."),
                         urlString: "https://github.com/jkcoxson/idevice")
                AboutRow(systemImage: "signature",
                         tint: Theme.accent2,
                         title: "isideload",
                         detail: L("Apple ID sign in, certificates and signing on the device. By nab138, MIT."),
                         urlString: "https://github.com/nab138/isideload")
                AboutRow(systemImage: "shippingbox.fill",
                         tint: .green,
                         title: "SideStore",
                         detail: L("The sideloading app this installs for you."),
                         urlString: "https://github.com/SideStore/SideStore")
                AboutRow(systemImage: "square.stack.3d.up.fill",
                         tint: .green,
                         title: "LiveContainer",
                         detail: L("Runs sideloaded apps without spending an app slot on each one."),
                         urlString: "https://github.com/LiveContainer/LiveContainer")
                AboutRow(systemImage: "gamecontroller.fill",
                         tint: .green,
                         title: "Madeira",
                         detail: L("Runs Windows PC games on your iPhone. By Will Faust, GPL-3.0."),
                         urlString: "https://github.com/willfaust/Madeira")
                AboutRow(systemImage: "externaldrive.fill",
                         tint: .purple,
                         title: "DeveloperDiskImage",
                         detail: L("The developer disk image location spoofing mounts. Mirrored by doronz88."),
                         urlString: "https://github.com/doronz88/DeveloperDiskImage")
            }
        }
    }

    // MARK: Helpers

    private func sectionTitle(_ title: String, systemImage: String) -> some View {
        Label {
            Text(title).font(.headline)
        } icon: {
            Image(systemName: systemImage)
                .foregroundStyle(Theme.brand)
        }
    }
}

// MARK: - Row

/// A row with a tinted icon, a title and an optional detail line. Rows with a
/// `urlString` open it and show an arrow; rows with an `action` run it and
/// show a chevron.
private struct AboutRow: View {
    var systemImage: String
    var tint: Color
    var title: String
    var detail: String? = nil
    var urlString: String? = nil
    var action: (() -> Void)? = nil

    @Environment(\.openURL) private var openURL

    var body: some View {
        if let action {
            Button(action: action) { content(accessory: "chevron.right") }
                .buttonStyle(.plain)
        } else if let url = urlString.flatMap(URL.init(string:)) {
            Button { openURL(url) } label: { content(accessory: "arrow.up.right") }
                // `.plain` keeps the row from using the accent color.
                .buttonStyle(.plain)
        } else {
            content(accessory: nil)
        }
    }

    private func content(accessory: String?) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: systemImage)
                .font(.title3)
                .foregroundStyle(Theme.gradient(tint))
                // Fixed width so the icons line up.
                .frame(width: 26, alignment: .leading)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                if let detail {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 8)
            if let accessory {
                Image(systemName: accessory)
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.tertiary)
            }
        }
        .foregroundStyle(.primary)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }
}
