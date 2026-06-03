import SwiftUI

/// System Health tab — a 0–100 score and the individual checks. Read-only.
struct SystemHealthView: View {
    @ObservedObject var store: SystemHealthChecker
    let palette: BriefingPalette

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .center, spacing: 16) {
                scoreDial
                VStack(alignment: .leading, spacing: 3) {
                    Text(verdict).font(.system(size: 16, weight: .semibold, design: .serif)).foregroundColor(palette.ink)
                    Text("Kiểm tra đĩa · RAM · swap · bảo mật · ổ cứng — chỉ đọc, không thay đổi gì.")
                        .font(.system(size: 11)).foregroundColor(palette.ink3)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                AIAskButton(palette: palette) {
                    if let (s, p) = aiBuild() {
                        AIChatWindowController.shared.present(palette: palette, title: "AI đọc kết quả sức khoẻ",
                            system: s, context: p,
                            suggestions: ["Máy có vấn đề gì?", "Nên cải thiện gì trước?", "Có rủi ro bảo mật không?"])
                    }
                }.disabled(aiBuild() == nil)
                Button { store.run() } label: {
                    Label("Quét lại", systemImage: "arrow.clockwise").font(.system(size: 12, weight: .semibold))
                }
                .buttonStyle(.bordered).disabled(store.isRunning)
            }
            list
        }
        .onAppear { if store.checks.isEmpty { store.run() } }
    }

    private func aiBuild() -> (system: String, prompt: String)? {
        guard !store.checks.isEmpty else { return nil }
        let system = """
        Bạn là chuyên gia macOS. Trả lời tiếng Việt, súc tích, gạch đầu dòng. Dựa trên \
        kết quả kiểm tra sức khoẻ máy (điểm tổng + từng mục với trạng thái good/warn/bad), \
        nêu vấn đề đáng lưu ý và khuyến nghị cụ thể, khả thi. CHỉ dựa trên số liệu đưa ra.
        """
        let lines = store.checks.map { c -> String in
            let s = c.status == .good ? "good" : (c.status == .warn ? "warn" : "bad")
            return "- \(c.name): \(c.detail) [\(s)]"
        }.joined(separator: "\n")
        return (system, "Điểm sức khoẻ: \(store.score)/100\n\(lines)\n\nNên làm gì?")
    }

    private var scoreColor: Color {
        store.score >= 80 ? palette.moss : (store.score >= 55 ? palette.gold : palette.coral)
    }
    private var verdict: String {
        store.score >= 80 ? "Máy khoẻ" : (store.score >= 55 ? "Ổn, có vài điểm lưu ý" : "Cần chú ý")
    }

    private var scoreDial: some View {
        ZStack {
            Circle().stroke(palette.line, lineWidth: 8).frame(width: 72, height: 72)
            Circle().trim(from: 0, to: CGFloat(store.score) / 100)
                .stroke(scoreColor, style: StrokeStyle(lineWidth: 8, lineCap: .round))
                .rotationEffect(.degrees(-90)).frame(width: 72, height: 72)
                .animation(.easeOut(duration: 0.5), value: store.score)
            Text("\(store.score)").font(.system(size: 24, weight: .bold, design: .rounded)).foregroundColor(palette.ink)
        }
    }

    private var list: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(store.checks) { c in
                    HStack(spacing: 10) {
                        Circle().fill(color(c.status)).frame(width: 8, height: 8)
                        Text(c.name).font(.system(size: 12.5)).foregroundColor(palette.ink)
                        Spacer()
                        Text(c.detail).font(.system(size: 12, weight: .medium, design: .monospaced))
                            .foregroundColor(palette.ink2)
                    }
                    .padding(.vertical, 9).padding(.horizontal, 14)
                    Divider().overlay(palette.line)
                }
                if store.checks.isEmpty {
                    HStack { ProgressView().controlSize(.small); Text("Đang kiểm tra…").font(.system(size: 12)).foregroundColor(palette.ink3) }
                        .padding(.vertical, 16)
                }
            }
        }
        .background(RoundedRectangle(cornerRadius: 12).fill(palette.raisedSurface))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(palette.line, lineWidth: 1))
    }

    private func color(_ s: HealthCheck.Status) -> Color {
        switch s { case .good: return palette.moss; case .warn: return palette.gold; case .bad: return palette.coral }
    }
}
