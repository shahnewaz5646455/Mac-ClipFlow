#!/bin/bash
set -e

echo "Building ClipFlow clipboard manager..."

# 1. Clean previous build if exists
rm -rf ClipFlow.app
rm -f ClipFlow

# 2. Create directory structure
mkdir -p ClipFlow.app/Contents/MacOS
mkdir -p ClipFlow.app/Contents/Resources

# 3. Create Info.plist
cat <<EOF > ClipFlow.app/Contents/Info.plist
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key>
    <string>com.antigravity.ClipFlow</string>
    <key>CFBundleName</key>
    <string>ClipFlow</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>LSMinimumSystemVersion</key>
    <string>13.0</string>
    <key>LSUIElement</key>
    <true/>
</dict>
</plist>
EOF

# 4. Compile the application
echo "Compiling Swift code..."
swiftc -O -sdk "$(xcrun --show-sdk-path)" -target arm64-apple-macosx13.0 main.swift -o ClipFlow.app/Contents/MacOS/ClipFlow
# 5. Codesign the application
echo "Signing the application..."
if security find-identity -p codesigning | grep -q "ClipFlow Local Signer"; then
    echo "Signing with stable certificate 'ClipFlow Local Signer'..."
    codesign --force --deep --sign "ClipFlow Local Signer" ClipFlow.app
else
    echo "Warning: Stable certificate 'ClipFlow Local Signer' not found. Fallback to ad-hoc signing..."
    codesign --force --deep --sign - ClipFlow.app
fi

echo "Successfully built ClipFlow.app!"
echo "You can open it using: open ClipFlow.app"
