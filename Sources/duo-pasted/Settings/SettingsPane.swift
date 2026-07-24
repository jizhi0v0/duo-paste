import SwiftUI

/// Settings 的一页。从 `SettingsView` 里提出来单独放,让 pane 各自的文件不用反向依赖外壳。
///
/// `subtitle` 是页面大标题下面那行,用来说清"这一页管什么"——旧版 TabView 时代没有
/// 位置放这句话。
enum SettingsPane: String, CaseIterable, Hashable, Identifiable {
    case general, ocr, about

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: return "常规"
        case .ocr:     return "OCR"
        case .about:   return "关于"
        }
    }

    var icon: String {
        switch self {
        case .general: return "gearshape"
        case .ocr:     return "text.viewfinder"
        case .about:   return "info.circle"
        }
    }


    var subtitle: String {
        switch self {
        case .general: return "快捷键、同步、捕获守门与设备配对。"
        case .ocr:     return "把图片里的文字写进搜索索引,以及本机索引队列的状态。"
        case .about:   return "进程、凭据、证书与本机存储。"
        }
    }

    /// `关于` 是纯只读页,没有可编辑 config → 不挂 ApplyBar。
    var editsConfig: Bool { self != .about }
}
