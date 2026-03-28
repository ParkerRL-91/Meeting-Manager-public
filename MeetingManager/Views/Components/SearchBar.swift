import SwiftUI

struct SearchBar: View {
    @Binding var query: String

    var placeholder: String = "Search..."

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
                .imageScale(.medium)

            TextField(placeholder, text: $query)
                .textFieldStyle(.plain)
                .font(.body)

            if !query.isEmpty {
                Button {
                    query = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                        .imageScale(.medium)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(.quaternary)
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

#Preview("Empty") {
    SearchBar(query: .constant(""))
        .frame(width: 260)
        .padding()
}

#Preview("With Text") {
    SearchBar(query: .constant("Weekly standup"))
        .frame(width: 260)
        .padding()
}
