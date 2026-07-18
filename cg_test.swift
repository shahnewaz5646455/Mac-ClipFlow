import Cocoa
import CoreGraphics

print("Testing CoreGraphics CGEvent compilation...")
let source = CGEventSource(stateID: .combinedSessionState)
let cmdVDown = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: true)
cmdVDown?.flags = .maskCommand
cmdVDown?.post(tap: .cgSessionEventTap)
print("CoreGraphics test compiled successfully!")
