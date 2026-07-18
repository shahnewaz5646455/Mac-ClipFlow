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

// MARK: - UI Components

struct AccessibilityWarningBanner: View {
    @State private var isTrusted = true
    
    var body: some View {
        if !isTrusted {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 5) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundColor(.orange)
                        .font(.system(size: 11))
                    Text("Auto-Paste is Disabled")
                        .font(.system(size: 11, weight: .bold))
                    Spacer()
                    Button(action: {
                        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
                        _ = AXIsProcessTrustedWithOptions(options as CFDictionary)
                    }) {
                        Text("Enable")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundColor(.blue)
                    }
                    .buttonStyle(PlainButtonStyle())
                }
                Text("ClipFlow requires Accessibility permission to automatically paste items into other applications.")
                    .font(.system(size: 9.5))
                    .foregroundColor(.secondary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
            }
            .padding(8)
            .background(Color.orange.opacity(0.08))
            .cornerRadius(6)
            .padding(.bottom, 4)
            .onAppear {
                isTrusted = AXIsProcessTrusted()
            }
        }
    }
}

struct SearchBar: View {
    @Binding var text: String
    
    var body: some View {
        HStack {
            Image(systemName: "magnifyingglass")
                .foregroundColor(.secondary)
            
            TextField("Search history...", text: $text)
                .textFieldStyle(PlainTextFieldStyle())
                .foregroundColor(.primary)
                .disableAutocorrection(true)
            
            if !text.isEmpty {
                Button(action: { text = "" }) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(.secondary)
                }
                .buttonStyle(PlainButtonStyle())
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Color(NSColor.controlBackgroundColor))
        .cornerRadius(8)
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.secondary.opacity(0.15), lineWidth: 1)
        )
    }
}

struct ClipboardRow: View {
    let item: ClipboardItem
    let index: Int
    let isSelected: Bool
    let onCopy: () -> Void
    let onDelete: () -> Void
    let onPin: () -> Void
    
    @State private var isHovered = false
    
    private var imagesDir: URL {
        let paths = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
        return paths[0].appendingPathComponent("ClipFlow").appendingPathComponent("images")
    }
    
    var body: some View {
        HStack(spacing: 10) {
            // Index badge for 1-9
            if index < 9 {
                Text("\(index + 1)")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundColor(isSelected ? .white : .secondary)
                    .frame(width: 16, height: 16)
                    .background(isSelected ? Color.white.opacity(0.25) : Color.primary.opacity(0.06))
                    .cornerRadius(4)
            } else {
                Spacer().frame(width: 16)
            }
            
            // Content preview based on type
            VStack(alignment: .leading, spacing: 3) {
                let type = item.type ?? .text
                switch type {
                case .text:
                    Text(item.text.prefix(300))
                        .font(.system(size: 12, weight: .regular))
                        .lineLimit(2)
                        .foregroundColor(isSelected ? .white : .primary)
                        .multilineTextAlignment(.leading)
                    
                    HStack(spacing: 6) {
                        if item.isURL {
                            HStack(spacing: 2) {
                                Image(systemName: "link")
                                    .font(.system(size: 8))
                                Text("URL")
                                    .font(.system(size: 8, weight: .bold))
                            }
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1.5)
                            .background(isSelected ? Color.white.opacity(0.2) : Color.blue.opacity(0.1))
                            .foregroundColor(isSelected ? .white : .blue)
                            .cornerRadius(3)
                        }
                        
                        Text(timeAgo(from: item.timestamp))
                            .font(.system(size: 9))
                            .foregroundColor(isSelected ? Color.white.opacity(0.7) : .secondary)
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
                                    .stroke(Color.secondary.opacity(0.2), lineWidth: 1)
                            )
                    } else {
                        HStack(spacing: 4) {
                            Image(systemName: "photo")
                                .font(.system(size: 12))
                            Text("Image (Unavailable)")
                                .font(.system(size: 12))
                        }
                        .foregroundColor(isSelected ? .white : .secondary)
                    }
                    
                    HStack(spacing: 6) {
                        HStack(spacing: 2) {
                            Image(systemName: "photo")
                                .font(.system(size: 8))
                            Text("IMAGE")
                                .font(.system(size: 8, weight: .bold))
                        }
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1.5)
                        .background(isSelected ? Color.white.opacity(0.2) : Color.purple.opacity(0.1))
                        .foregroundColor(isSelected ? .white : .purple)
                        .cornerRadius(3)
                        
                        Text(timeAgo(from: item.timestamp))
                            .font(.system(size: 9))
                            .foregroundColor(isSelected ? Color.white.opacity(0.7) : .secondary)
                    }
                    
                case .file:
                    HStack(spacing: 4) {
                        Image(systemName: "doc.on.doc")
                            .font(.system(size: 11))
                        Text(item.text.prefix(150))
                            .font(.system(size: 12, weight: .medium))
                            .lineLimit(1)
                    }
                    .foregroundColor(isSelected ? .white : .primary)
                    
                    HStack(spacing: 6) {
                        HStack(spacing: 2) {
                            Image(systemName: "folder")
                                .font(.system(size: 8))
                            Text("FILE")
                                .font(.system(size: 8, weight: .bold))
                        }
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1.5)
                        .background(isSelected ? Color.white.opacity(0.2) : Color.green.opacity(0.1))
                        .foregroundColor(isSelected ? .white : .green)
                        .cornerRadius(3)
                        
                        Text(timeAgo(from: item.timestamp))
                            .font(.system(size: 9))
                            .foregroundColor(isSelected ? Color.white.opacity(0.7) : .secondary)
                    }
                }
            }
            
            Spacer()
            
            // Hover/Selected actions
            if isHovered || isSelected {
                HStack(spacing: 8) {
                    Button(action: onPin) {
                        Image(systemName: item.isPinned ? "pin.fill" : "pin")
                            .foregroundColor(item.isPinned ? .orange : (isSelected ? .white : .secondary))
                    }
                    .buttonStyle(PlainButtonStyle())
                    
                    Button(action: onCopy) {
                        Image(systemName: "doc.on.doc")
                            .foregroundColor(isSelected ? .white : .secondary)
                    }
                    .buttonStyle(PlainButtonStyle())
                    
                    Button(action: onDelete) {
                        Image(systemName: "trash")
                            .foregroundColor(isSelected ? .white : .red)
                    }
                    .buttonStyle(PlainButtonStyle())
                }
                .font(.system(size: 11))
            } else if item.isPinned {
                Image(systemName: "pin.fill")
                    .foregroundColor(.orange)
                    .font(.system(size: 9))
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(
            ZStack {
                if isSelected {
                    LinearGradient(gradient: Gradient(colors: [Color.blue, Color.purple]), startPoint: .leading, endPoint: .trailing)
                } else if isHovered {
                    Color.primary.opacity(0.04)
                }
            }
            .cornerRadius(6)
        )
        .contentShape(Rectangle())
        .onHover { hover in
            withAnimation(.easeOut(duration: 0.1)) {
                isHovered = hover
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
                    .fill(Color.blue.opacity(0.08))
                    .frame(width: 60, height: 60)
                
                Image(systemName: "doc.on.clipboard")
                    .font(.system(size: 26))
                    .foregroundColor(.blue)
            }
            
            VStack(spacing: 4) {
                Text("ClipFlow is listening")
                    .font(.system(size: 13, weight: .bold))
                Text("Copy text or links and they will appear here.")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 30)
            }
            
            Spacer()
        }
    }
}

struct LaunchAtLoginToggle: View {
    @State private var isEnabled = false
    
    var body: some View {
        Toggle(isOn: $isEnabled) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Launch at Login")
                    .font(.system(size: 13, weight: .semibold))
                Text("Start ClipFlow automatically on startup.")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            }
        }
        .toggleStyle(SwitchToggleStyle(tint: .blue))
        .onAppear {
            if #available(macOS 13.0, *) {
                isEnabled = SMAppService.mainApp.status == .enabled
            }
        }
        .onChange(of: isEnabled) { newValue in
            if #available(macOS 13.0, *) {
                do {
                    if newValue {
                        if SMAppService.mainApp.status != .enabled {
                            try SMAppService.mainApp.register()
                        }
                    } else {
                        if SMAppService.mainApp.status == .enabled {
                            try SMAppService.mainApp.unregister()
                        }
                    }
                } catch {
                    print("Launch at login error: \(error)")
                }
            }
        }
    }
}

struct SettingsView: View {
    @ObservedObject var store: ClipboardStore
    let onBack: () -> Void
    
    var body: some View {
        VStack(spacing: 12) {
            // Header
            HStack {
                Button(action: onBack) {
                    HStack(spacing: 3) {
                        Image(systemName: "chevron.left")
                        Text("Back")
                    }
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.blue)
                }
                .buttonStyle(PlainButtonStyle())
                
                Spacer()
                
                Text("Settings")
                    .font(.system(size: 14, weight: .bold))
                
                Spacer()
                Spacer().frame(width: 45)
            }
            .padding(.bottom, 4)
            
            Divider()
            
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    // History Limit
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text("History Limit")
                                .font(.system(size: 12, weight: .semibold))
                            Spacer()
                            Text("\(store.maxHistory) items")
                                .font(.system(size: 11))
                                .foregroundColor(.secondary)
                        }
                        
                        Slider(value: Binding(
                            get: { Double(store.maxHistory) },
                            set: { store.maxHistory = Int($0); store.enforceLimit(); store.saveSettings() }
                        ), in: 10...250, step: 5)
                        .accentColor(.blue)
                    }
                    
                    // Sound effects
                    Toggle(isOn: Binding(
                        get: { store.playSounds },
                        set: { store.playSounds = $0; store.saveSettings() }
                    )) {
                        VStack(alignment: .leading, spacing: 1) {
                            Text("Play Sound on Copy")
                                .font(.system(size: 12, weight: .semibold))
                            Text("Plays a subtle click when items are copied.")
                                .font(.system(size: 10))
                                .foregroundColor(.secondary)
                        }
                    }
                    .toggleStyle(SwitchToggleStyle(tint: .blue))
                    
                    // Ignore password manager
                    Toggle(isOn: Binding(
                        get: { store.ignorePasswords },
                        set: { store.ignorePasswords = $0; store.saveSettings() }
                    )) {
                        VStack(alignment: .leading, spacing: 1) {
                            Text("Ignore Passwords")
                                .font(.system(size: 12, weight: .semibold))
                            Text("Avoid saving data from password managers.")
                                .font(.system(size: 10))
                                .foregroundColor(.secondary)
                        }
                    }
                    .toggleStyle(SwitchToggleStyle(tint: .blue))
                    
                    // Launch at Login
                    LaunchAtLoginToggle()
                    
                    Divider()
                    
                    // Shortcuts Panel
                    VStack(alignment: .leading, spacing: 5) {
                        Text("Keyboard Shortcuts")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(.secondary)
                        
                        HStack {
                            Text("Show/Hide ClipFlow")
                                .font(.system(size: 10.5))
                            Spacer()
                            Text("⌥ + V")
                                .font(.system(size: 9.5, weight: .bold))
                                .padding(.horizontal, 4)
                                .padding(.vertical, 1)
                                .background(Color.primary.opacity(0.06))
                                .cornerRadius(3)
                        }
                        
                        HStack {
                            Text("Copy Selected")
                                .font(.system(size: 10.5))
                            Spacer()
                            Text("Enter")
                                .font(.system(size: 9.5, weight: .bold))
                                .padding(.horizontal, 4)
                                .padding(.vertical, 1)
                                .background(Color.primary.opacity(0.06))
                                .cornerRadius(3)
                        }
                        
                        HStack {
                            Text("Quick Copy Items 1-9")
                                .font(.system(size: 10.5))
                            Spacer()
                            Text("1 - 9")
                                .font(.system(size: 9.5, weight: .bold))
                                .padding(.horizontal, 4)
                                .padding(.vertical, 1)
                                .background(Color.primary.opacity(0.06))
                                .cornerRadius(3)
                        }
                    }
                }
                .padding(.horizontal, 2)
            }
            
            Spacer()
            
            Divider()
            
            // Quit Button
            Button(action: {
                NSApplication.shared.terminate(nil)
            }) {
                HStack {
                    Spacer()
                    Image(systemName: "power")
                        .font(.system(size: 11))
                    Text("Quit ClipFlow")
                        .font(.system(size: 12, weight: .semibold))
                    Spacer()
                }
                .foregroundColor(.white)
                .padding(.vertical, 7)
                .background(Color.red.opacity(0.8))
                .cornerRadius(6)
            }
            .buttonStyle(PlainButtonStyle())
        }
        .padding(12)
    }
}

struct ContentView: View {
    @ObservedObject var store: ClipboardStore
    @State private var showSettings = false
    
    var body: some View {
        VStack(spacing: 0) {
            if showSettings {
                SettingsView(store: store, onBack: {
                    withAnimation(.easeInOut(duration: 0.15)) {
                        showSettings = false
                    }
                })
                .transition(.asymmetric(insertion: .move(edge: .trailing), removal: .move(edge: .trailing)))
            } else {
                VStack(spacing: 8) {
                    // Header
                    HStack(spacing: 6) {
                        Text("ClipFlow")
                            .font(.system(size: 14, weight: .black))
                            .foregroundColor(.primary)
                            .overlay(
                                LinearGradient(gradient: Gradient(colors: [.blue, .purple]), startPoint: .leading, endPoint: .trailing)
                                    .mask(Text("ClipFlow").font(.system(size: 14, weight: .black)))
                            )
                        
                        Circle()
                            .fill(Color.green)
                            .frame(width: 5, height: 5)
                        
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
                                    .foregroundColor(.secondary)
                                    .font(.system(size: 12))
                            }
                            .buttonStyle(PlainButtonStyle())
                            .help("Clear History")
                        }
                        
                        Button(action: {
                            withAnimation(.easeInOut(duration: 0.15)) {
                                showSettings = true
                            }
                        }) {
                            Image(systemName: "gearshape")
                                .foregroundColor(.secondary)
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
                    
                    AccessibilityWarningBanner()
                        .padding(.horizontal, 12)
                    
                    Divider()
                        .padding(.top, 2)
                    
                    // List
                    if store.filteredItems.isEmpty {
                        EmptyStateView()
                    } else {
                        ScrollViewReader { proxy in
                            ScrollView {
                                LazyVStack(spacing: 2) {
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
        .background(Color(NSColor.windowBackgroundColor))
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
