import Foundation
import SwiftUI

struct WindowLayout: Identifiable, Equatable, Decodable {
    let id: String
    let name: String
    let x: CGFloat
    let y: CGFloat
    let width: CGFloat
    let height: CGFloat

    enum CodingKeys: String, CodingKey {
        case id, name, x, y, width, height
    }
}
