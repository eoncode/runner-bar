// swiftlint:disable all
import Combine
import SwiftUI

final class PopoverOpenState: ObservableObject {
    @Published var isOpen: Bool = false

    func open() { isOpen = true }
    func close() { isOpen = false }
    func toggle() { isOpen.toggle() }
}
