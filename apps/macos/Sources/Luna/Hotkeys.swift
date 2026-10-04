import KeyboardShortcuts

extension KeyboardShortcuts.Name {
    static let toggleInput = Self("toggleInput", default: .init(.space, modifiers: [.option]))
    static let openLastResult = Self("openLastResult", default: .init(.space, modifiers: [.option, .shift]))
    static let toggleTasks = Self("toggleTasks", default: .init(.space, modifiers: [.option, .command]))
}
