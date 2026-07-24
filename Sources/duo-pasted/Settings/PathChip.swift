import SwiftUI
import AppKit

struct PathChip: View {
    let path: String

    var body: some View {
        HStack(spacing: 6) {
            Text(compactPath)
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .layoutPriority(1)

            Button {
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
            } label: {
                Image(systemName: "arrow.up.forward.app")
                    .font(.system(size: 10, weight: .medium))
                    .frame(width: 18, height: 18)
            }
            .modifier(NativeGlassButtonChrome(isProminent: false))
            .foregroundStyle(Color.secondary)
            .help("在 Finder 中显示")
        }
        .padding(.leading, 9)
        .padding(.trailing, 5)
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(Color.primary.opacity(0.045))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .strokeBorder(Color.white.opacity(0.07), lineWidth: 1)
        )
        .help(path)
    }

    private var compactPath: String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let display = path.hasPrefix(home)
            ? "~" + path.dropFirst(home.count)
            : path
        guard display.count > 44 else { return display }

        let parts = display.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard let duoIndex = parts.lastIndex(of: "duo-paste") else {
            return "…/" + parts.suffix(3).joined(separator: "/")
        }
        let tail = parts.suffix(from: duoIndex).joined(separator: "/")
        return "~/…/" + tail
    }
}
