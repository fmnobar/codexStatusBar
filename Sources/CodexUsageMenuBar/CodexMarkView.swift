import SwiftUI

struct CodexMarkView: View {
    var body: some View {
        Image("CodexMark")
            .renderingMode(.template)
            .resizable()
            .scaledToFit()
            .frame(width: 13, height: 13)
            .accessibilityHidden(true)
    }
}
