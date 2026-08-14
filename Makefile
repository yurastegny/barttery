APP        = Barttery
BUNDLE     = Barttery.app
CONTENTS   = $(BUNDLE)/Contents
BIN_DIR    = .build/apple/Products/Release
SIGN      ?= Apple Development: yura@yura.me (69Z678PHDM)

.PHONY: all build run install clean

all: build

build:
	swift build -c release --arch arm64 --arch x86_64
	@mkdir -p $(CONTENTS)/MacOS $(CONTENTS)/Resources
	@cp $(BIN_DIR)/$(APP) $(CONTENTS)/MacOS/$(APP)
	@cp Info.plist $(CONTENTS)/
	@cp AppIcon.icns $(CONTENTS)/Resources/
	@cp -r $(BIN_DIR)/Barttery_Barttery.bundle $(CONTENTS)/Resources/
	@BNDL=$(CONTENTS)/Resources/Barttery_Barttery.bundle; \
	for f in $$BNDL/*.dylib $$BNDL/idevice_id $$BNDL/ideviceinfo $$BNDL/comptest; do \
	  [ -f "$$f" ] && codesign --force --sign "$(SIGN)" "$$f"; \
	done; \
	codesign --force --sign "$(SIGN)" --entitlements Barttery.entitlements $(BUNDLE)
	@echo "=> Built $(BUNDLE)"

run: build
	open $(BUNDLE)

install: build
	rm -rf /Applications/$(BUNDLE)
	ditto $(BUNDLE) /Applications/$(BUNDLE)
	xattr -dr com.apple.quarantine /Applications/$(BUNDLE) 2>/dev/null || true
	@echo "=> Installed to /Applications/$(BUNDLE)"

dmg: build
	@VERSION=$$(defaults read "$(PWD)/$(CONTENTS)/Info" CFBundleShortVersionString); \
	DMG="Barttery-$$VERSION.dmg"; \
	STAGING=$$(mktemp -d); \
	cp -r $(BUNDLE) "$$STAGING/"; \
	ln -s /Applications "$$STAGING/Applications"; \
	hdiutil create -volname "Barttery" -srcfolder "$$STAGING" -ov -format UDZO "$$DMG"; \
	rm -rf "$$STAGING"; \
	echo "=> $$DMG"

clean:
	rm -rf .build $(BUNDLE)
