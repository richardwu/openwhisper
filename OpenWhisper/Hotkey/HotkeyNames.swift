import KeyboardShortcuts

extension KeyboardShortcuts.Name {
    static let toggleRecording = Self(
        "toggleRecording",
        default: .init(.l, modifiers: [.command])
    )

    static let cancelRecording = Self(
        "cancelRecording",
        default: .init(.escape)
    )
}
