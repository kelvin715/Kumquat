.PHONY: app run install test self-test previews icon zip notarize clean

app:
	@scripts/build-app.sh

run: app
	@open build/Kumquat.app

install: app
	@rm -rf /Applications/Kumquat.app
	@cp -R build/Kumquat.app /Applications/
	@echo "Installed to /Applications/Kumquat.app"

test:
	swift test

self-test:
	swift build && .build/debug/Kumquat self-test

previews:
	swift build && .build/debug/Kumquat render-previews docs/images

icon:
	swift scripts/make-icon.swift build/AppIcon.iconset && iconutil -c icns build/AppIcon.iconset -o Resources/AppIcon.icns

zip: app
	@cd build && ditto -c -k --sequesterRsrc --keepParent Kumquat.app Kumquat.zip && echo "build/Kumquat.zip"

# Developer ID signing + Apple notarization (see README › Signing and notarization).
notarize:
	@scripts/notarize.sh

clean:
	rm -rf .build build
