#!/bin/zsh
# Builds 隨手SQLite.app without Xcode (Command Line Tools are enough).
# Usage:  ./build.sh            -> build/隨手SQLite.app
#         ./build.sh install    -> also copies it to /Applications
set -euo pipefail
cd "${0:A:h}"

APP=build/隨手SQLite.app
rm -rf "$APP" build/隨手庫.app   # the bundle was 隨手庫.app up to 2026.a22
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

[[ -f MenuSQLite/AppIcon.icns ]] || swift tools/make_icon.swift

swiftc -O -swift-version 5 -parse-as-library \
  -target "$(uname -m)-apple-macos13.0" \
  MenuSQLite/*.swift -o "$APP/Contents/MacOS/MenuSQLite"

cp MenuSQLite/AppIcon.icns "$APP/Contents/Resources/"

# LSUIElement keeps the app out of the Dock and ⌘-Tab; it lives only in the menu bar.
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleName</key><string>隨手SQLite</string>
	<key>CFBundleDisplayName</key><string>隨手SQLite</string>
	<key>CFBundleIdentifier</key><string>com.jeff.menusqlite</string>
	<key>CFBundleExecutable</key><string>MenuSQLite</string>
	<key>CFBundleIconFile</key><string>AppIcon</string>
	<key>CFBundlePackageType</key><string>APPL</string>
	<key>CFBundleShortVersionString</key><string>2026.a29</string>
	<key>CFBundleVersion</key><string>2026.a29</string>
	<key>CFBundleDevelopmentRegion</key><string>zh_TW</string>
	<key>LSMinimumSystemVersion</key><string>13.0</string>
	<key>LSApplicationCategoryType</key><string>public.app-category.developer-tools</string>
	<key>LSUIElement</key><true/>
	<key>CFBundleDocumentTypes</key>
	<array>
		<dict>
			<key>CFBundleTypeName</key><string>SQLite 資料庫</string>
			<key>CFBundleTypeRole</key><string>Editor</string>
			<key>LSHandlerRank</key><string>Alternate</string>
			<key>CFBundleTypeExtensions</key>
			<array><string>sqlite</string><string>sqlite3</string><string>db</string><string>db3</string></array>
		</dict>
	</array>
	<key>NSHighResolutionCapable</key><true/>
	<key>NSPrincipalClass</key><string>NSApplication</string>
</dict>
</plist>
PLIST

codesign --force --sign - "$APP"
echo "Built $APP"

if [[ "${1:-}" == "install" ]]; then
  if pgrep -x MenuSQLite >/dev/null; then
    osascript -e 'tell application id "com.jeff.menusqlite" to quit' >/dev/null 2>&1 || true
    for _ in {1..20}; do pgrep -x MenuSQLite >/dev/null || break; sleep 0.5; done
  fi
  rm -rf "/Applications/隨手庫.app" "/Applications/隨手SQLite.app"
  cp -R "$APP" /Applications/
  echo "Installed to /Applications/隨手SQLite.app"
fi
