import SwiftUI

/// Thin draggable handle that controls a height binding by gesture. Used as
/// a bottom-edge resize affordance on panes that live inside a ScrollView,
/// where wrapping in `VSplitView` would fight the scroll behaviour.
///
/// Usage:
///
///     SomeView()
///         .frame(height: heightBinding.wrappedValue)
///         .overlay(alignment: .bottom) {
///             DraggableHeightHandle(
///                 height: heightBinding,
///                 minHeight: 200,
///                 maxHeight: 800
///             )
///         }
struct DraggableHeightHandle: View {
    @Binding var height: Double
    var minHeight: Double
    var maxHeight: Double

    @State private var dragStartHeight: Double? = nil
    @State private var isHovering: Bool = false

    var body: some View {
        Rectangle()
            .fill(Color.clear)
            .frame(height: 8)
            .overlay {
                Capsule()
                    .fill(isHovering ? Color.appAccent.opacity(0.55) : Color.appSeparator)
                    .frame(width: 36, height: 3)
            }
            .contentShape(Rectangle())
            .onHover { hovering in
                isHovering = hovering
                if hovering {
                    NSCursor.resizeUpDown.push()
                } else {
                    NSCursor.pop()
                }
            }
            .gesture(
                DragGesture(minimumDistance: 1)
                    .onChanged { value in
                        if dragStartHeight == nil { dragStartHeight = height }
                        let proposed = (dragStartHeight ?? height) + Double(value.translation.height)
                        height = min(max(proposed, minHeight), maxHeight)
                    }
                    .onEnded { _ in
                        dragStartHeight = nil
                    }
            )
            .accessibilityLabel("Resize handle")
            .accessibilityHint("Drag to adjust pane height")
    }
}
