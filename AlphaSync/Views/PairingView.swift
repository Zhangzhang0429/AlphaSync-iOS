import SwiftUI

/// 配对页：两步走。
/// 第 1 步连接相机后，相机屏会显示 6 位配对码；
/// 第 2 步把码输入到手机，相机核对一致即完成配对。
struct PairingView: View {
    @EnvironmentObject private var connection: ConnectionCenter
    @Environment(\.dismiss) private var dismiss

    @State private var code = ""
    @State private var submitting = false
    @State private var errorText: String?

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                Image(systemName: "link.badge.plus")
                    .font(.system(size: 48))
                    .foregroundStyle(.tint)
                Text("配对相机")
                    .font(.title2.weight(.semibold))

                VStack(spacing: 8) {
                    Text("1. 查看相机屏幕上的 6 位配对码")
                        .font(.body)
                    Text("2. 在下面输入，然后点「提交配对」")
                        .font(.body)
                }
                .multilineTextAlignment(.center)

                TextField("6 位数字", text: $code)
                    .keyboardType(.numberPad)
                    .font(.title2.monospacedDigit())
                    .multilineTextAlignment(.center)
                    .padding()
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 12))
                    .frame(maxWidth: 260)
                    .onChange(of: code) { _, newValue in
                        let digits = newValue.filter { $0.isWholeNumber }
                        code = String(digits.prefix(6))
                        errorText = nil
                    }

                if let errorText = errorText {
                    Text(errorText).font(.footnote).foregroundStyle(.red)
                }

                Button {
                    submit()
                } label: {
                    if submitting {
                        ProgressView().frame(width: 80)
                    } else {
                        Text("提交配对").frame(width: 120)
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(code.count != 6 || submitting)

                if case .pairing(false) = connection.state {
                    ProgressView("正在连接相机…")
                }
            }
            .padding()
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("取消") {
                        connection.cancelPair()
                        dismiss()
                    }
                }
            }
        }
        .interactiveDismissDisabled(true)
    }

    private func submit() {
        guard code.count == 6 else { return }
        submitting = true
        errorText = nil
        connection.submitPairCode(code: code)
        // 等待连接中心把状态切到 .connected / .error
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            submitting = false
            switch connection.state {
            case .connected:
                dismiss()
            case .pairing:
                errorText = connection.statusMessage ?? "配对码不正确或已失效，请重试"
            case .error(let e):
                errorText = e
            default:
                break
            }
        }
    }
}
