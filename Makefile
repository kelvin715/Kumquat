.PHONY: app run install test self-test previews icon zip dmg notarize cask clean

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

dmg: app
	@scripts/make-dmg.sh

# Developer ID signing + Apple notarization; setup steps are in scripts/notarize.sh.
notarize:
	@scripts/notarize.sh

# After publishing a release: VERSION=1.2.0 make cask points the Homebrew cask at it.
cask:
	@scripts/update-cask.sh

clean:
	rm -rf .build build
