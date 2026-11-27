import SwiftUI

/// Diagnostic only. Never part of the product crop or the published film.
struct FilmAnimationControl: View {
    @State private var moved = false
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Native withAnimation control · 0.4 seconds")
                .font(.system(size: 11)).foregroundStyle(.black)
            ZStack(alignment: .leading) {
                Color(white: 0.94)
                Rectangle().fill(.black).frame(width: 24, height: 24)
                    .offset(x: moved ? 210 : 0)
            }
            .frame(width: 240, height: 32)
        }
        .padding(16).frame(width: 300, height: 90, alignment: .leading)
        .background(.white)
        .task {
            while !Task.isCancelled {
                do { try await Task.sleep(for: .milliseconds(800)) } catch { return }
                withAnimation(.linear(duration: 0.4)) { moved.toggle() }
            }
        }
    }
}
