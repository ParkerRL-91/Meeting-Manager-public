import SwiftUI

struct ErrorAlertModifier: ViewModifier {
    @Binding var errorMessage: String?

    func body(content: Content) -> some View {
        content
            .alert("Error", isPresented: .init(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            )) {
                Button("OK") { errorMessage = nil }
            } message: {
                if let errorMessage {
                    Text(errorMessage)
                }
            }
    }
}

extension View {
    func errorAlert(_ errorMessage: Binding<String?>) -> some View {
        modifier(ErrorAlertModifier(errorMessage: errorMessage))
    }
}
