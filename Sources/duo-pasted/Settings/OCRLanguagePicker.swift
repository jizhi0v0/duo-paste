import SwiftUI
import Vision

struct LanguageMultiSelectPopover: View {
    let options: [OCRLanguageOption]
    let selectedIDs: Set<String>
    let onToggle: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("识别语言")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)

            ScrollView {
                VStack(spacing: 2) {
                    ForEach(options) { option in
                        Button {
                            onToggle(option.id)
                        } label: {
                            HStack(spacing: 8) {
                                Image(systemName: selectedIDs.contains(option.id) ? "checkmark.circle.fill" : "circle")
                                    .font(.system(size: 13, weight: .medium))
                                    .foregroundStyle(selectedIDs.contains(option.id) ? Color.accentColor : Color.secondary)
                                Text(option.title)
                                    .font(.system(size: 13))
                                    .foregroundStyle(.primary)
                                    .lineLimit(1)
                                Spacer(minLength: 0)
                            }
                            .padding(.horizontal, 8)
                            .frame(height: 30)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .background(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(selectedIDs.contains(option.id) ? Color.accentColor.opacity(0.12) : Color.clear)
                        )
                    }
                }
            }
            .frame(maxHeight: 260)
        }
    }
}

struct OCRLanguageOption: Identifiable, Equatable {
    let id: String
    let title: String
    let shortTitle: String

    static let defaultOption = OCRLanguageOption(
        id: "zh-Hans",
        title: "简体中文 (zh-Hans)",
        shortTitle: "简中"
    )

    static var allOptions: [OCRLanguageOption] {
        let supported = supportedLanguages
        var options: [OCRLanguageOption] = [
            defaultOption,
            OCRLanguageOption(id: "en-US", title: "English (en-US)", shortTitle: "EN"),
            OCRLanguageOption(id: "zh-Hant", title: "繁體中文 (zh-Hant)", shortTitle: "繁中"),
            OCRLanguageOption(id: "ja-JP", title: "日本語 (ja-JP)", shortTitle: "日本語"),
            OCRLanguageOption(id: "ko-KR", title: "한국어 (ko-KR)", shortTitle: "한국어")
        ].filter { option in
            supported.contains(option.id)
        }

        for language in supported where !options.contains(where: { $0.id == language }) {
            options.append(OCRLanguageOption(
                id: language,
                title: languageDisplayName(language),
                shortTitle: language
            ))
        }
        return options
    }

    private static var supportedLanguages: [String] {
        let accurateRequest = VNRecognizeTextRequest()
        accurateRequest.recognitionLevel = .accurate
        let fastRequest = VNRecognizeTextRequest()
        fastRequest.recognitionLevel = .fast
        let accurate = (try? accurateRequest.supportedRecognitionLanguages()) ?? []
        let fast = (try? fastRequest.supportedRecognitionLanguages()) ?? []
        let union = Set(accurate).union(fast)
        if union.isEmpty {
            return ["zh-Hans", "en-US", "ja-JP"]
        }
        return union.sorted { languageDisplayName($0) < languageDisplayName($1) }
    }

    private static func languageDisplayName(_ code: String) -> String {
        let locale = Locale.current
        if let name = locale.localizedString(forIdentifier: code) {
            return "\(name) (\(code))"
        }
        return code
    }
}
