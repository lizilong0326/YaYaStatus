import AppKit

@MainActor
enum BrandIcon {
    static let mark: NSImage? = image(named: "StatusMark")

    static let menuBar: NSImage? = {
        guard let icon = image(named: "MenuBarMark") else { return nil }
        icon.isTemplate = true
        icon.size = NSSize(width: 18, height: 18)
        return icon
    }()

    private static func image(named name: String) -> NSImage? {
        guard let url = Bundle.main.url(forResource: name, withExtension: "png") else { return nil }
        return NSImage(contentsOf: url)
    }
}
