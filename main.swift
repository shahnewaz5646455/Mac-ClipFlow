import Cocoa
import SwiftUI
import Carbon
import ServiceManagement

// MARK: - Models

struct ClipboardItem: Codable, Identifiable, Equatable {
    let id: UUID
    let text: String
    let timestamp: Date
    var isPinned: Bool
    
    var type: ItemType?
    var imagePath: String?
    var filePaths: [String]?
    
    enum ItemType: String, Codable {
        case text
        case image
        case file
    }
    
    var isURL: Bool {
        let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
        let matches = detector?.matches(in: text, options: [], range: NSRange(location: 0, length: text.utf16.count))
        return (matches?.count ?? 0) > 0 && text.lowercased().hasPrefix("http")
    }
}

// MARK: - Clipboard Store

class ClipboardStore: ObservableObject {
    @Published var items: [ClipboardItem] = []
    @Published var searchText: String = "" {
        didSet {
            selectedIndex = 0
        }
    }
    @Published var selectedIndex: Int = 0
    
    // Settings
    @Published var maxHistory: Int = 100
    @Published var ignorePasswords: Bool = true
    @Published var playSounds: Bool = true
    
    // UI & System State
    @Published var showSettings: Bool = false
    @Published var isAccessibilityTrusted: Bool = true
    @Published var isLaunchAtLoginEnabled: Bool = false
    
    private var timer: Timer?
    private var lastChangeCount = NSPasteboard.general.changeCount
    
    private var savePath: URL {
        let paths = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
        let appSupport = paths[0].appendingPathComponent("ClipFlow")
        try? FileManager.default.createDirectory(at: appSupport, withIntermediateDirectories: true)
        return appSupport.appendingPathComponent("history.json")
    }
    
    private var settingsPath: URL {
        let paths = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
        let appSupport = paths[0].appendingPathComponent("ClipFlow")
        try? FileManager.default.createDirectory(at: appSupport, withIntermediateDirectories: true)
        return appSupport.appendingPathComponent("settings.json")
    }
    
    private var imagesDir: URL {
        let paths = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
        let appSupport = paths[0].appendingPathComponent("ClipFlow").appendingPathComponent("images")
        try? FileManager.default.createDirectory(at: appSupport, withIntermediateDirectories: true)
        return appSupport
    }
    
    struct SettingsData: Codable {
        let maxHistory: Int
        let ignorePasswords: Bool
        let playSounds: Bool
    }
    
    var filteredItems: [ClipboardItem] {
        if searchText.isEmpty {
            return items
        } else {
            return items.filter { $0.text.localizedCaseInsensitiveContains(searchText) }
        }
    }
    
    init() {
        loadSettings()
        loadHistory()
        startMonitoring()
        checkAccessibility()
        checkLaunchAtLogin()
    }
    
    func checkAccessibility() {
        isAccessibilityTrusted = AXIsProcessTrusted()
    }
    
    func checkLaunchAtLogin() {
        if #available(macOS 13.0, *) {
            isLaunchAtLoginEnabled = SMAppService.mainApp.status == .enabled
        }
    }
    
    func toggleLaunchAtLogin(enabled: Bool) {
        if #available(macOS 13.0, *) {
            do {
                if enabled {
                    if SMAppService.mainApp.status != .enabled {
                        try SMAppService.mainApp.register()
                    }
                } else {
                    if SMAppService.mainApp.status == .enabled {
                        try SMAppService.mainApp.unregister()
                    }
                }
                isLaunchAtLoginEnabled = SMAppService.mainApp.status == .enabled
            } catch {
                print("Launch at login error: \(error)")
            }
        }
    }
    
    func loadHistory() {
        if let data = try? Data(contentsOf: savePath),
           let decoded = try? JSONDecoder().decode([ClipboardItem].self, from: data) {
            self.items = decoded
        }
    }
    
    func saveHistory() {
        if let data = try? JSONEncoder().encode(items) {
            try? data.write(to: savePath)
        }
    }
    
    func loadSettings() {
        if let data = try? Data(contentsOf: settingsPath),
           let decoded = try? JSONDecoder().decode(SettingsData.self, from: data) {
            self.maxHistory = decoded.maxHistory
            self.ignorePasswords = decoded.ignorePasswords
            self.playSounds = decoded.playSounds
        }
    }
    
    func saveSettings() {
        let settings = SettingsData(maxHistory: maxHistory, ignorePasswords: ignorePasswords, playSounds: playSounds)
        if let data = try? JSONEncoder().encode(settings) {
            try? data.write(to: settingsPath)
        }
    }
    
    func checkPasteboard() {
        let pb = NSPasteboard.general
        guard pb.changeCount != lastChangeCount else { return }
        lastChangeCount = pb.changeCount
        
        if ignorePasswords && isPasswordOrConcealed() {
            return
        }
        
        // 1. Check for files/URLs representing local files
        if let fileURLs = pb.readObjects(forClasses: [NSURL.self], options: [NSPasteboard.ReadingOptionKey.urlReadingFileURLsOnly: true]) as? [URL], !fileURLs.isEmpty {
            let paths = fileURLs.map { $0.path }
            DispatchQueue.main.async {
                self.addFileItem(paths: paths)
            }
            return
        }
        
        // 2. Check for images
        let imageTypes: [NSPasteboard.PasteboardType] = [.png, .tiff]
        if let availableType = pb.availableType(from: imageTypes),
           let imgData = pb.data(forType: availableType) {
            DispatchQueue.main.async {
                self.addImageItem(data: imgData, type: availableType)
            }
            return
        }
        
        // 3. Check for text
        if let text = pb.string(forType: .string) {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return }
            
            DispatchQueue.main.async {
                self.addItem(text: trimmed)
            }
        }
    }
    
    func startMonitoring() {
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            self?.checkPasteboard()
        }
    }
    
    func addItem(text: String) {
        if let index = items.firstIndex(where: { ($0.type ?? .text) == .text && $0.text == text }) {
            let isPinned = items[index].isPinned
            items.remove(at: index)
            let newItem = ClipboardItem(id: UUID(), text: text, timestamp: Date(), isPinned: isPinned, type: .text, imagePath: nil, filePaths: nil)
            items.insert(newItem, at: 0)
        } else {
            let newItem = ClipboardItem(id: UUID(), text: text, timestamp: Date(), isPinned: false, type: .text, imagePath: nil, filePaths: nil)
            items.insert(newItem, at: 0)
        }
        
        enforceLimit()
        saveHistory()
    }
    
    func addImageItem(data: Data, type: NSPasteboard.PasteboardType) {
        let filename = UUID().uuidString + (type == .png ? ".png" : ".tiff")
        let fileURL = imagesDir.appendingPathComponent(filename)
        do {
            try data.write(to: fileURL)
            let newItem = ClipboardItem(
                id: UUID(),
                text: "Copied Image (\(type == .png ? "PNG" : "TIFF"))",
                timestamp: Date(),
                isPinned: false,
                type: .image,
                imagePath: filename,
                filePaths: nil
            )
            items.insert(newItem, at: 0)
            enforceLimit()
            saveHistory()
        } catch {
            print("Failed to save image: \(error)")
        }
    }
    
    func addFileItem(paths: [String]) {
        let filesDescription = paths.map { URL(fileURLWithPath: $0).lastPathComponent }.joined(separator: ", ")
        if let index = items.firstIndex(where: { ($0.type ?? .text) == .file && $0.filePaths == paths }) {
            let isPinned = items[index].isPinned
            items.remove(at: index)
            let newItem = ClipboardItem(
                id: UUID(),
                text: filesDescription,
                timestamp: Date(),
                isPinned: isPinned,
                type: .file,
                imagePath: nil,
                filePaths: paths
            )
            items.insert(newItem, at: 0)
        } else {
            let newItem = ClipboardItem(
                id: UUID(),
                text: filesDescription,
                timestamp: Date(),
                isPinned: false,
                type: .file,
                imagePath: nil,
                filePaths: paths
            )
            items.insert(newItem, at: 0)
        }
        enforceLimit()
        saveHistory()
    }
    
    func deleteItem(item: ClipboardItem) {
        if let index = items.firstIndex(where: { $0.id == item.id }) {
            let removedItem = items.remove(at: index)
            if (removedItem.type ?? .text) == .image, let imagePath = removedItem.imagePath {
                let fileURL = imagesDir.appendingPathComponent(imagePath)
                try? FileManager.default.removeItem(at: fileURL)
            }
            saveHistory()
        }
    }
    
    func togglePin(item: ClipboardItem) {
        if let index = items.firstIndex(where: { $0.id == item.id }) {
            items[index].isPinned.toggle()
            enforceLimit()
            saveHistory()
        }
    }
    
    func clearAll() {
        items.removeAll()
        // Delete all saved images
        if let files = try? FileManager.default.contentsOfDirectory(at: imagesDir, includingPropertiesForKeys: nil) {
            for file in files {
                try? FileManager.default.removeItem(at: file)
            }
        }
        saveHistory()
    }
    
    func copyToClipboard(item: ClipboardItem) {
        let pb = NSPasteboard.general
        pb.clearContents()
        
        let type = item.type ?? .text
        switch type {
        case .text:
            pb.setString(item.text, forType: .string)
        case .image:
            if let imagePath = item.imagePath {
                let fileURL = imagesDir.appendingPathComponent(imagePath)
                if let data = try? Data(contentsOf: fileURL) {
                    let pbType: NSPasteboard.PasteboardType = imagePath.hasSuffix(".png") ? .png : .tiff
                    pb.setData(data, forType: pbType)
                }
            }
        case .file:
            if let filePaths = item.filePaths {
                let nsURLs = filePaths.map { NSURL(fileURLWithPath: $0) }
                pb.writeObjects(nsURLs)
            }
        }
        
        self.lastChangeCount = pb.changeCount // Sync change count
        
        // Move item to top
        if let index = items.firstIndex(where: { $0.id == item.id }) {
            let currentItem = items[index]
            items.remove(at: index)
            let updatedItem = ClipboardItem(
                id: currentItem.id,
                text: currentItem.text,
                timestamp: Date(),
                isPinned: currentItem.isPinned,
                type: currentItem.type,
                imagePath: currentItem.imagePath,
                filePaths: currentItem.filePaths
            )
            items.insert(updatedItem, at: 0)
            enforceLimit()
            saveHistory()
        }
        
        if playSounds {
            NSSound(named: "Tink")?.play()
        }
    }
    
    func copyAndPaste(item: ClipboardItem) {
        copyToClipboard(item: item)
        
        // Close popover and reactivate the target app immediately
        DispatchQueue.main.async {
            AppDelegate.shared.closePopover()
            if let previousApp = AppDelegate.shared.previousActiveApp {
                previousApp.activate(options: .activateIgnoringOtherApps)
            } else {
                NSApp.deactivate()
            }
        }
        
        // Wait 180ms to let focus transition complete, then post keyboard events
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) {
            let source = CGEventSource(stateID: .combinedSessionState)
            let vKeyCode: CGKeyCode = 9        // 'V'
            
            // Post Cmd+V down event
            let vDown = CGEvent(keyboardEventSource: source, virtualKey: vKeyCode, keyDown: true)
            vDown?.flags = .maskCommand
            
            // Post Cmd+V up event
            let vUp = CGEvent(keyboardEventSource: source, virtualKey: vKeyCode, keyDown: false)
            vUp?.flags = .maskCommand
            
            vDown?.post(tap: .cgSessionEventTap)
            vUp?.post(tap: .cgSessionEventTap)
        }
    }
    
    func enforceLimit() {
        let pinned = items.filter { $0.isPinned }
        let unpinned = items.filter { !$0.isPinned }
        
        let allowedUnpinnedCount = max(0, maxHistory - pinned.count)
        let trimmedUnpinned = Array(unpinned.prefix(allowedUnpinnedCount))
        
        let newItems = pinned.sorted(by: { $0.timestamp > $1.timestamp }) + trimmedUnpinned.sorted(by: { $0.timestamp > $1.timestamp })
        
        // Find items that are going to be removed and delete their images
        let newIds = Set(newItems.map { $0.id })
        for item in items {
            if !newIds.contains(item.id) {
                if (item.type ?? .text) == .image, let imagePath = item.imagePath {
                    let fileURL = imagesDir.appendingPathComponent(imagePath)
                    try? FileManager.default.removeItem(at: fileURL)
                }
            }
        }
        
        items = newItems
    }
    
    private func isPasswordOrConcealed() -> Bool {
        let pb = NSPasteboard.general
        let types = pb.types ?? []
        
        let sensitiveTypes = [
            "org.nspasteboard.ConcealedType",
            "com.agilebits.onepassword",
            "org.nspasteboard.TransientType",
            "org.nspasteboard.AutoGeneratedType"
        ]
        
        for type in sensitiveTypes {
            if types.contains(NSPasteboard.PasteboardType(type)) {
                return true
            }
        }
        return false
    }
}

// MARK: - HotKey Manager

class HotKeyManager {
    static let shared = HotKeyManager()
    private var hotKeyRef: EventHotKeyRef?
    var onTrigger: (() -> Void)?

    func register(keyCode: UInt32, modifiers: UInt32) {
        unregister()

        let hotKeyID = EventHotKeyID(signature: 1129468998, id: 1) // "CLPF"
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: OSType(kEventHotKeyReleased))
        
        let handler: EventHandlerUPP = { (_, event, _) -> OSStatus in
            HotKeyManager.shared.onTrigger?()
            return noErr
        }

        InstallEventHandler(GetApplicationEventTarget(), handler, 1, &eventType, nil, nil)
        RegisterEventHotKey(keyCode, modifiers, hotKeyID, GetApplicationEventTarget(), 0, &self.hotKeyRef)
    }

    func unregister() {
        if let ref = hotKeyRef {
            UnregisterEventHotKey(ref)
            hotKeyRef = nil
        }
    }
}

// MARK: - Theme & Typography

struct Theme {
    // 4-Color Static Palette from Reference
    static let midnight    = Color(red: 0x01/255.0, green: 0x07/255.0, blue: 0x36/255.0) // #010736: Midnight Obsidian base canvas
    static let darkNavy    = Color(red: 0x0D/255.0, green: 0x1C/255.0, blue: 0x42/255.0) // #0D1C42: Elevated surfaces, containers, search bar
    static let royalBlue   = Color(red: 0x22/255.0, green: 0x39/255.0, blue: 0x6F/255.0) // #22396F: Solid selection highlight, borders, focus
    static let warmCream   = Color(red: 0xFC/255.0, green: 0xF1/255.0, blue: 0xD0/255.0) // #FCF1D0: Accent brand, active badges, highlights
    
    // Supporting harmonious tones
    static let textLight   = Color(red: 0xF2/255.0, green: 0xF5/255.0, blue: 0xFB/255.0) // Crisp high-contrast light text
    static let textMuted   = Color(red: 0x88/255.0, green: 0x98/255.0, blue: 0xB5/255.0) // Elegant slate for secondary labels
    static let deleteRed   = Color(red: 0xEE/255.0, green: 0x5D/255.0, blue: 0x6E/255.0) // Coral red for destructive actions
}

struct ThemeFont {
    static func heavy(size: CGFloat) -> Font {
        .custom("Avenir Next", size: size).weight(.heavy)
    }
    static func bold(size: CGFloat) -> Font {
        .custom("Avenir Next", size: size).weight(.bold)
    }
    static func semibold(size: CGFloat) -> Font {
        .custom("Avenir Next", size: size).weight(.semibold)
    }
    static func medium(size: CGFloat) -> Font {
        .custom("Avenir Next", size: size).weight(.medium)
    }
    static func regular(size: CGFloat) -> Font {
        .custom("Avenir Next", size: size).weight(.regular)
    }
    static func code(size: CGFloat) -> Font {
        .system(size: size, weight: .semibold, design: .monospaced)
    }
}

// MARK: - UI Components

struct AccessibilityWarningBanner: View {
    @ObservedObject var store: ClipboardStore
    
    var body: some View {
        if !store.isAccessibilityTrusted {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 5) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundColor(Theme.warmCream)
                        .font(.system(size: 11))
                    Text("Auto-Paste is Disabled")
                        .font(ThemeFont.bold(size: 11))
                        .foregroundColor(Theme.warmCream)
                    Spacer()
                    Button(action: {
                        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
                        _ = AXIsProcessTrustedWithOptions(options as CFDictionary)
                        store.checkAccessibility()
                    }) {
                        Text("Enable")
                            .font(ThemeFont.bold(size: 10))
                            .foregroundColor(Theme.midnight)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 2)
                            .background(Theme.warmCream)
                            .cornerRadius(4)
                    }
                    .buttonStyle(PlainButtonStyle())
                }
                Text("ClipFlow requires Accessibility permission to automatically paste items into other applications.")
                    .font(ThemeFont.regular(size: 9.5))
                    .foregroundColor(Theme.textMuted)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
            }
            .padding(8)
            .background(Theme.darkNavy)
            .cornerRadius(6)
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(Theme.royalBlue, lineWidth: 1)
            )
            .padding(.bottom, 4)
            .onAppear {
                store.checkAccessibility()
            }
        }
    }
}

struct SearchBar: View {
    @Binding var text: String
    
    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(Theme.textMuted)
            
            TextField("Search history...", text: $text)
                .textFieldStyle(PlainTextFieldStyle())
                .font(ThemeFont.medium(size: 11.5))
                .foregroundColor(Theme.textLight)
                .disableAutocorrection(true)
            
            if !text.isEmpty {
                Button(action: { text = "" }) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(Theme.textMuted)
                        .font(.system(size: 11))
                }
                .buttonStyle(PlainButtonStyle())
            }
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 6)
        .background(Theme.darkNavy)
        .cornerRadius(7)
        .overlay(
            RoundedRectangle(cornerRadius: 7)
                .stroke(text.isEmpty ? Theme.royalBlue.opacity(0.5) : Theme.royalBlue, lineWidth: 1)
        )
    }
}

class RowHoverModel: ObservableObject {
    @Published var isHovered: Bool = false
}

struct ClipboardRow: View {
    let item: ClipboardItem
    let index: Int
    let isSelected: Bool
    let onCopy: () -> Void
    let onDelete: () -> Void
    let onPin: () -> Void
    
    @StateObject private var hover = RowHoverModel()
    
    private var imagesDir: URL {
        let paths = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
        return paths[0].appendingPathComponent("ClipFlow").appendingPathComponent("images")
    }
    
    var body: some View {
        HStack(spacing: 9) {
            // Index badge for 1-9
            if index < 9 {
                Text("\(index + 1)")
                    .font(ThemeFont.code(size: 9))
                    .foregroundColor(isSelected ? Theme.midnight : Theme.textMuted)
                    .frame(width: 17, height: 17)
                    .background(isSelected ? Theme.warmCream : Theme.darkNavy)
                    .cornerRadius(4)
                    .overlay(
                        RoundedRectangle(cornerRadius: 4)
                            .stroke(isSelected ? Theme.warmCream : Theme.royalBlue.opacity(0.4), lineWidth: 0.8)
                    )
            } else {
                Spacer().frame(width: 17)
            }
            
            // Content preview based on type
            VStack(alignment: .leading, spacing: 3) {
                let type = item.type ?? .text
                switch type {
                case .text:
                    Text(item.text.prefix(300))
                        .font(ThemeFont.regular(size: 11.5))
                        .lineLimit(2)
                        .foregroundColor(isSelected ? Theme.textLight : Theme.textLight.opacity(0.92))
                        .multilineTextAlignment(.leading)
                    
                    HStack(spacing: 6) {
                        if item.isURL {
                            HStack(spacing: 3) {
                                Image(systemName: "link")
                                    .font(.system(size: 7.5, weight: .bold))
                                Text("URL")
                                    .font(ThemeFont.bold(size: 7.5))
                            }
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1.5)
                            .background(isSelected ? Theme.midnight.opacity(0.35) : Theme.darkNavy)
                            .foregroundColor(isSelected ? Theme.warmCream : Theme.warmCream.opacity(0.9))
                            .cornerRadius(3)
                            .overlay(
                                RoundedRectangle(cornerRadius: 3)
                                    .stroke(Theme.royalBlue.opacity(0.6), lineWidth: 0.6)
                            )
                        }
                        
                        Text(timeAgo(from: item.timestamp))
                            .font(ThemeFont.medium(size: 9))
                            .foregroundColor(isSelected ? Theme.textLight.opacity(0.7) : Theme.textMuted)
                    }
                    
                case .image:
                    if let imagePath = item.imagePath,
                       let nsImage = NSImage(contentsOf: imagesDir.appendingPathComponent(imagePath)) {
                        Image(nsImage: nsImage)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(maxWidth: 150, maxHeight: 80)
                            .cornerRadius(4)
                            .overlay(
                                RoundedRectangle(cornerRadius: 4)
                                    .stroke(Theme.royalBlue.opacity(0.5), lineWidth: 1)
                            )
                    } else {
                        HStack(spacing: 4) {
                            Image(systemName: "photo")
                                .font(.system(size: 12))
                            Text("Image (Unavailable)")
                                .font(ThemeFont.regular(size: 11.5))
                        }
                        .foregroundColor(isSelected ? Theme.textLight : Theme.textMuted)
                    }
                    
                    HStack(spacing: 6) {
                        HStack(spacing: 3) {
                            Image(systemName: "photo")
                                .font(.system(size: 7.5, weight: .bold))
                            Text("IMAGE")
                                .font(ThemeFont.bold(size: 7.5))
                        }
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1.5)
                        .background(isSelected ? Theme.midnight.opacity(0.35) : Theme.darkNavy)
                        .foregroundColor(isSelected ? Theme.warmCream : Theme.warmCream.opacity(0.9))
                        .cornerRadius(3)
                        .overlay(
                            RoundedRectangle(cornerRadius: 3)
                                .stroke(Theme.royalBlue.opacity(0.6), lineWidth: 0.6)
                        )
                        
                        Text(timeAgo(from: item.timestamp))
                            .font(ThemeFont.medium(size: 9))
                            .foregroundColor(isSelected ? Theme.textLight.opacity(0.7) : Theme.textMuted)
                    }
                    
                case .file:
                    HStack(spacing: 4) {
                        Image(systemName: "doc.on.doc")
                            .font(.system(size: 11))
                        Text(item.text.prefix(150))
                            .font(ThemeFont.medium(size: 11.5))
                            .lineLimit(1)
                    }
                    .foregroundColor(isSelected ? Theme.textLight : Theme.textLight.opacity(0.92))
                    
                    HStack(spacing: 6) {
                        HStack(spacing: 3) {
                            Image(systemName: "folder")
                                .font(.system(size: 7.5, weight: .bold))
                            Text("FILE")
                                .font(ThemeFont.bold(size: 7.5))
                        }
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1.5)
                        .background(isSelected ? Theme.midnight.opacity(0.35) : Theme.darkNavy)
                        .foregroundColor(isSelected ? Theme.warmCream : Theme.warmCream.opacity(0.9))
                        .cornerRadius(3)
                        .overlay(
                            RoundedRectangle(cornerRadius: 3)
                                .stroke(Theme.royalBlue.opacity(0.6), lineWidth: 0.6)
                        )
                        
                        Text(timeAgo(from: item.timestamp))
                            .font(ThemeFont.medium(size: 9))
                            .foregroundColor(isSelected ? Theme.textLight.opacity(0.7) : Theme.textMuted)
                    }
                }
            }
            
            Spacer()
            
            // Hover/Selected actions
            if hover.isHovered || isSelected {
                HStack(spacing: 8) {
                    Button(action: onPin) {
                        Image(systemName: item.isPinned ? "pin.fill" : "pin")
                            .foregroundColor(item.isPinned ? Theme.warmCream : (isSelected ? Theme.textLight : Theme.textMuted))
                    }
                    .buttonStyle(PlainButtonStyle())
                    
                    Button(action: onCopy) {
                        Image(systemName: "doc.on.doc")
                            .foregroundColor(isSelected ? Theme.textLight : Theme.textMuted)
                    }
                    .buttonStyle(PlainButtonStyle())
                    
                    Button(action: onDelete) {
                        Image(systemName: "trash")
                            .foregroundColor(Theme.deleteRed)
                    }
                    .buttonStyle(PlainButtonStyle())
                }
                .font(.system(size: 11))
            } else if item.isPinned {
                Image(systemName: "pin.fill")
                    .foregroundColor(Theme.warmCream)
                    .font(.system(size: 9))
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(isSelected ? Theme.royalBlue : (hover.isHovered ? Theme.darkNavy : Color.clear))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(isSelected ? Theme.royalBlue : (hover.isHovered ? Theme.royalBlue.opacity(0.3) : Color.clear), lineWidth: 1)
        )
        .contentShape(Rectangle())
        .onHover { h in
            withAnimation(.easeOut(duration: 0.1)) {
                hover.isHovered = h
            }
        }
        .onTapGesture {
            onCopy()
        }
    }
    
    private func timeAgo(from date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: date, relativeTo: Date())
    }
}

struct EmptyStateView: View {
    var body: some View {
        VStack(spacing: 12) {
            Spacer()
            
            ZStack {
                Circle()
                    .fill(Theme.darkNavy)
                    .frame(width: 58, height: 58)
                    .overlay(
                        Circle()
                            .stroke(Theme.royalBlue, lineWidth: 1.5)
                    )
                
                Image(systemName: "doc.on.clipboard")
                    .font(.system(size: 24))
                    .foregroundColor(Theme.warmCream)
            }
            
            VStack(spacing: 4) {
                Text("ClipFlow is listening")
                    .font(ThemeFont.bold(size: 13))
                    .foregroundColor(Theme.textLight)
                Text("Copy text, images, or files and they will appear here.")
                    .font(ThemeFont.regular(size: 11))
                    .foregroundColor(Theme.textMuted)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 28)
            }
            
            Spacer()
        }
    }
}

struct LaunchAtLoginToggle: View {
    @ObservedObject var store: ClipboardStore
    
    var body: some View {
        Toggle(isOn: Binding(
            get: { store.isLaunchAtLoginEnabled },
            set: { store.toggleLaunchAtLogin(enabled: $0) }
        )) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Launch at Login")
                    .font(ThemeFont.semibold(size: 12))
                    .foregroundColor(Theme.textLight)
                Text("Start ClipFlow automatically on startup.")
                    .font(ThemeFont.regular(size: 10.5))
                    .foregroundColor(Theme.textMuted)
            }
        }
        .toggleStyle(SwitchToggleStyle(tint: Theme.royalBlue))
        .onAppear {
            store.checkLaunchAtLogin()
        }
    }
}

struct SettingsView: View {
    @ObservedObject var store: ClipboardStore
    let onBack: () -> Void
    
    var body: some View {
        VStack(spacing: 9) {
            // Header
            HStack {
                Button(action: onBack) {
                    HStack(spacing: 4) {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 10, weight: .bold))
                        Text("Back")
                            .font(ThemeFont.medium(size: 12))
                    }
                    .foregroundColor(Theme.warmCream)
                }
                .buttonStyle(PlainButtonStyle())
                
                Spacer()
                
                Text("Settings")
                    .font(ThemeFont.bold(size: 13.5))
                    .foregroundColor(Theme.textLight)
                
                Spacer()
                Spacer().frame(width: 45)
            }
            .padding(.bottom, 2)
            
            Divider()
                .background(Theme.royalBlue.opacity(0.35))
            
            ScrollView {
                VStack(alignment: .leading, spacing: 9) {
                    // History Limit
                    VStack(alignment: .leading, spacing: 5) {
                        HStack {
                            Text("History Limit")
                                .font(ThemeFont.semibold(size: 11.5))
                                .foregroundColor(Theme.textLight)
                            Spacer()
                            Text("\(store.maxHistory) items")
                                .font(ThemeFont.medium(size: 11))
                                .foregroundColor(Theme.warmCream)
                        }
                        
                        Slider(value: Binding(
                            get: { Double(store.maxHistory) },
                            set: { store.maxHistory = Int($0); store.enforceLimit(); store.saveSettings() }
                        ), in: 10...250, step: 5)
                        .accentColor(Theme.warmCream)
                    }
                    .padding(8)
                    .background(Theme.darkNavy)
                    .cornerRadius(7)
                    .overlay(
                        RoundedRectangle(cornerRadius: 7)
                            .stroke(Theme.royalBlue.opacity(0.4), lineWidth: 0.8)
                    )
                    
                    // Options Card
                    VStack(spacing: 8) {
                        // Sound effects
                        Toggle(isOn: Binding(
                            get: { store.playSounds },
                            set: { store.playSounds = $0; store.saveSettings() }
                        )) {
                            VStack(alignment: .leading, spacing: 1) {
                                Text("Play Sound on Copy")
                                    .font(ThemeFont.semibold(size: 11.5))
                                    .foregroundColor(Theme.textLight)
                                Text("Plays a subtle click when items are copied.")
                                    .font(ThemeFont.regular(size: 9.5))
                                    .foregroundColor(Theme.textMuted)
                            }
                        }
                        .toggleStyle(SwitchToggleStyle(tint: Theme.royalBlue))
                        
                        Divider()
                            .background(Theme.royalBlue.opacity(0.25))
                        
                        // Ignore password manager
                        Toggle(isOn: Binding(
                            get: { store.ignorePasswords },
                            set: { store.ignorePasswords = $0; store.saveSettings() }
                        )) {
                            VStack(alignment: .leading, spacing: 1) {
                                Text("Ignore Passwords")
                                    .font(ThemeFont.semibold(size: 11.5))
                                    .foregroundColor(Theme.textLight)
                                Text("Avoid saving data from password managers.")
                                    .font(ThemeFont.regular(size: 9.5))
                                    .foregroundColor(Theme.textMuted)
                            }
                        }
                        .toggleStyle(SwitchToggleStyle(tint: Theme.royalBlue))
                        
                        Divider()
                            .background(Theme.royalBlue.opacity(0.25))
                        
                        // Launch at Login
                        LaunchAtLoginToggle(store: store)
                    }
                    .padding(8)
                    .background(Theme.darkNavy)
                    .cornerRadius(7)
                    .overlay(
                        RoundedRectangle(cornerRadius: 7)
                            .stroke(Theme.royalBlue.opacity(0.4), lineWidth: 0.8)
                    )
                    
                    // Shortcuts Card
                    VStack(alignment: .leading, spacing: 5) {
                        Text("Keyboard Shortcuts")
                            .font(ThemeFont.semibold(size: 10.5))
                            .foregroundColor(Theme.textMuted)
                        
                        shortcutRow(label: "Show/Hide ClipFlow", shortcut: "⌥ V")
                        shortcutRow(label: "Copy Selected", shortcut: "Enter")
                        shortcutRow(label: "Quick Copy Items 1-9", shortcut: "1 - 9")
                    }
                    .padding(8)
                    .background(Theme.darkNavy)
                    .cornerRadius(7)
                    .overlay(
                        RoundedRectangle(cornerRadius: 7)
                            .stroke(Theme.royalBlue.opacity(0.4), lineWidth: 0.8)
                    )
                }
            }
            
            Spacer()
            
            Divider()
                .background(Theme.royalBlue.opacity(0.35))
            
            // Quit Button
            Button(action: {
                NSApplication.shared.terminate(nil)
            }) {
                HStack {
                    Spacer()
                    Image(systemName: "power")
                        .font(.system(size: 11, weight: .bold))
                    Text("Quit ClipFlow")
                        .font(ThemeFont.semibold(size: 12))
                    Spacer()
                }
                .foregroundColor(.white)
                .padding(.vertical, 7)
                .background(Theme.deleteRed.opacity(0.85))
                .cornerRadius(6)
            }
            .buttonStyle(PlainButtonStyle())
        }
        .padding(12)
        .background(Theme.midnight)
    }
    
    private func shortcutRow(label: String, shortcut: String) -> some View {
        HStack {
            Text(label)
                .font(ThemeFont.regular(size: 10.5))
                .foregroundColor(Theme.textLight)
            Spacer()
            Text(shortcut)
                .font(ThemeFont.code(size: 9.5))
                .foregroundColor(Theme.warmCream)
                .padding(.horizontal, 5)
                .padding(.vertical, 2)
                .background(Theme.midnight)
                .cornerRadius(3)
                .overlay(
                    RoundedRectangle(cornerRadius: 3)
                        .stroke(Theme.royalBlue.opacity(0.5), lineWidth: 0.6)
                )
        }
    }
}

struct ContentView: View {
    @ObservedObject var store: ClipboardStore
    
    var body: some View {
        VStack(spacing: 0) {
            if store.showSettings {
                SettingsView(store: store, onBack: {
                    withAnimation(.easeInOut(duration: 0.15)) {
                        store.showSettings = false
                    }
                })
                .transition(.asymmetric(insertion: .move(edge: .trailing), removal: .move(edge: .trailing)))
            } else {
                VStack(spacing: 8) {
                    // Header
                    HStack(spacing: 6) {
                        Text("ClipFlow")
                            .font(ThemeFont.heavy(size: 15))
                            .foregroundColor(Theme.warmCream)
                        
                        Circle()
                            .fill(Theme.warmCream)
                            .frame(width: 5, height: 5)
                            .opacity(0.85)
                        
                        Spacer()
                        
                        if !store.items.isEmpty {
                            Button(action: {
                                let alert = NSAlert()
                                alert.messageText = "Clear History?"
                                alert.informativeText = "Are you sure you want to clear your clipboard history?"
                                alert.alertStyle = .warning
                                alert.addButton(withTitle: "Clear All")
                                alert.addButton(withTitle: "Cancel")
                                if alert.runModal() == .alertFirstButtonReturn {
                                    store.clearAll()
                                }
                            }) {
                                Image(systemName: "trash")
                                    .foregroundColor(Theme.textMuted)
                                    .font(.system(size: 12))
                            }
                            .buttonStyle(PlainButtonStyle())
                            .help("Clear History")
                        }
                        
                        Button(action: {
                            withAnimation(.easeInOut(duration: 0.15)) {
                                store.showSettings = true
                            }
                        }) {
                            Image(systemName: "gearshape")
                                .foregroundColor(Theme.textMuted)
                                .font(.system(size: 12.5))
                        }
                        .buttonStyle(PlainButtonStyle())
                        .help("Settings")
                        .padding(.leading, 4)
                    }
                    .padding(.horizontal, 12)
                    .padding(.top, 10)
                    
                    // Search Bar
                    SearchBar(text: $store.searchText)
                        .padding(.horizontal, 12)
                    
                    AccessibilityWarningBanner(store: store)
                        .padding(.horizontal, 12)
                    
                    Divider()
                        .background(Theme.royalBlue.opacity(0.35))
                        .padding(.top, 2)
                    
                    // List
                    if store.filteredItems.isEmpty {
                        EmptyStateView()
                    } else {
                        ScrollViewReader { proxy in
                            ScrollView {
                                LazyVStack(spacing: 3) {
                                    ForEach(Array(store.filteredItems.enumerated()), id: \.element.id) { index, item in
                                        ClipboardRow(
                                            item: item,
                                            index: index,
                                            isSelected: store.selectedIndex == index,
                                            onCopy: {
                                                store.copyAndPaste(item: item)
                                            },
                                            onDelete: {
                                                store.deleteItem(item: item)
                                            },
                                            onPin: {
                                                store.togglePin(item: item)
                                            }
                                        )
                                        .id(item.id)
                                    }
                                }
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                            }
                            .onChange(of: store.selectedIndex) { newIndex in
                                if newIndex >= 0 && newIndex < store.filteredItems.count {
                                    withAnimation(.easeOut(duration: 0.1)) {
                                        proxy.scrollTo(store.filteredItems[newIndex].id, anchor: nil)
                                    }
                                }
                            }
                        }
                    }
                }
                .transition(.asymmetric(insertion: .move(edge: .leading), removal: .move(edge: .leading)))
            }
        }
        .frame(width: 320, height: 440)
        .background(Theme.midnight)
    }
}

// MARK: - App Delegate & Entry Point

class AppDelegate: NSObject, NSApplicationDelegate {
    static var shared: AppDelegate!
    
    var statusItem: NSStatusItem!
    let popover = NSPopover()
    let store = ClipboardStore()
    var previousActiveApp: NSRunningApplication?
    
    func applicationDidFinishLaunching(_ notification: Notification) {
        AppDelegate.shared = self
        
        // Check and prompt for accessibility permissions on startup
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
        _ = AXIsProcessTrustedWithOptions(options as CFDictionary)
        
        // Set accessory policy so it doesn't show in the Dock
        NSApp.setActivationPolicy(.accessory)
        
        // Popover configuration
        popover.contentSize = NSSize(width: 320, height: 440)
        popover.behavior = .transient
        popover.appearance = NSAppearance(named: .darkAqua)
        popover.contentViewController = NSHostingController(rootView: ContentView(store: store))
        
        // Menu Bar Item
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "doc.on.clipboard", accessibilityDescription: "ClipFlow")
            button.action = #selector(togglePopover(_:))
        }
        
        // Register Global Hotkey (⌥ + V)
        registerGlobalHotkey()
        
        // Monitor local keyboard events in the popover
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self = self, self.popover.isShown else { return event }
            
            // Escape key to close
            if event.keyCode == 53 {
                self.closePopover()
                return nil
            }
            
            // 1-9 keys for fast copying (only works when search text isn't active/focused or if empty)
            // Wait, to prevent conflicts when typing numbers in the search field, we only handle
            // numbers if search text is empty OR if command or option is pressed.
            // Actually, we can check if the search field has focus. However, in SwiftUI, it's easier to only copy on digits
            // if the search text is empty, OR if command/control is held down. Let's make it so:
            // If the user presses Command + Digit (e.g. ⌘1), we copy. That is extremely safe and doesn't interfere with typing search terms!
            // Let's implement BOTH: Option+Digit or Command+Digit or just raw Digit when search field is empty.
            let hasModifiers = event.modifierFlags.contains(.command) || event.modifierFlags.contains(.option)
            if let characters = event.characters, let num = Int(characters), num >= 1 && num <= 9 {
                if self.store.searchText.isEmpty || hasModifiers {
                    let index = num - 1
                    let filtered = self.store.filteredItems
                    if index < filtered.count {
                        self.store.copyAndPaste(item: filtered[index])
                        return nil
                    }
                }
            }
            
            // Arrow Keys and Enter
            switch event.keyCode {
            case 125: // Arrow Down
                let maxIdx = self.store.filteredItems.count - 1
                if maxIdx >= 0 {
                    self.store.selectedIndex = min(self.store.selectedIndex + 1, maxIdx)
                }
                return nil
            case 126: // Arrow Up
                if self.store.filteredItems.count > 0 {
                    self.store.selectedIndex = max(self.store.selectedIndex - 1, 0)
                }
                return nil
            case 36: // Enter
                let filtered = self.store.filteredItems
                if self.store.selectedIndex >= 0 && self.store.selectedIndex < filtered.count {
                    self.store.copyAndPaste(item: filtered[self.store.selectedIndex])
                }
                return nil
            default:
                break
            }
            
            return event
        }
    }
    
    @objc func togglePopover(_ sender: AnyObject?) {
        if popover.isShown {
            closePopover()
        } else {
            showPopover()
        }
    }
    
    func showPopover() {
        // Save the currently active application so we can switch back to it on close
        if let activeApp = NSWorkspace.shared.frontmostApplication {
            let myPid = ProcessInfo.processInfo.processIdentifier
            if activeApp.processIdentifier != myPid {
                self.previousActiveApp = activeApp
            }
        }
        
        if let button = statusItem.button {
            store.searchText = ""
            store.selectedIndex = 0
            store.showSettings = false
            store.checkAccessibility()
            
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }
    
    func closePopover() {
        popover.performClose(nil)
    }
    
    func registerGlobalHotkey() {
        HotKeyManager.shared.onTrigger = { [weak self] in
            DispatchQueue.main.async {
                self?.togglePopover(nil)
            }
        }
        // Option + V (keycode 9, option modifier = 2048)
        HotKeyManager.shared.register(keyCode: 9, modifiers: UInt32(optionKey))
    }
}

// Start application
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
