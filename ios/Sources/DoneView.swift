import SwiftUI

struct DoneView: View {
  var body: some View {
    VStack(spacing: 12) {
      Image(systemName: "checkmark.circle.fill").font(.system(size: 56)).foregroundStyle(.green)
      Text("Colors matched").font(.title2)
      Text("You can put your phone down.").foregroundStyle(.secondary)
    }.padding()
  }
}
