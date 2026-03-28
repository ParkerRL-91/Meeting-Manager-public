import SwiftUI

struct LoadingOverlay: ViewModifier {
    let isLoading: Bool
    let message: String

    func body(content: Content) -> some View {
        ZStack {
            content

            if isLoading {
                Color.black.opacity(0.4)
                    .ignoresSafeArea()

                VStack(spacing: 16) {
                    ProgressView()
                        .controlSize(.large)

                    Text(message)
                        .font(.body)
                        .foregroundStyle(.white)
                }
                .padding(24)
                .background(.ultraThinMaterial)
                .clipShape(RoundedRectangle(cornerRadius: 12))
            }
        }
        .animation(.easeInOut, value: isLoading)
    }
}

extension View {
    func loadingOverlay(isLoading: Bool, message: String = "Loading...") -> some View {
        modifier(LoadingOverlay(isLoading: isLoading, message: message))
    }
}

#Preview("Loading") {
    Text("Background Content")
        .frame(width: 400, height: 300)
        .loadingOverlay(isLoading: true, message: "Processing meeting...")
}

#Preview("Not Loading") {
    Text("Background Content")
        .frame(width: 400, height: 300)
        .loadingOverlay(isLoading: false)
}
