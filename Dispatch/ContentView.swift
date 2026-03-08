import SwiftUI

struct ContentView: View {
    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            Text("dispatch.")
                .font(.system(size: 32, weight: .bold, design: .default))
                .foregroundColor(.white)
        }
    }
}

#Preview {
    ContentView()
}
