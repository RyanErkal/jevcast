import SwiftUI

/// Quill's answer: a title, then the text, which can be selected and scrolls when long.
struct QuillAnswerView: View {
    let answer: QuillAnswer
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(answer.title, systemImage: "sparkles")
                .font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary).lineLimit(1)
            if let error = answer.error {
                Text(error).font(.system(size: 13)).foregroundStyle(.orange)
            } else if answer.isLoading {
                HStack(spacing: 8) { ProgressView().controlSize(.small); Text("Quill is writing…").foregroundStyle(.secondary) }
                    .font(.system(size: 13))
            } else {
                ScrollView {
                    Text(answer.text).font(.system(size: 13)).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 340)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, LauncherMetrics.gutter).padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}
