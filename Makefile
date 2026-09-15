APP        = Barttery
BRIDGE_INC = /opt/homebrew/include
BUNDLED_LIB_DIR = Sources/Resources/lib
BUNDLE     = Barttery.app
CONTENTS   = $(BUNDLE)/Contents
BIN_DIR    = .build/release
SIGN      ?= Apple Development: yura@yura.me (69Z678PHDM)

.PHONY: all build run install clean

all: build

build:
	rm -rf $(BUNDLE)
	swift build -c release --arch arm64
	@mkdir -p $(CONTENTS)/MacOS $(CONTENTS)/Resources
	@cp $(BIN_DIR)/$(APP) $(CONTENTS)/MacOS/$(APP)
	@chmod +x $(CONTENTS)/MacOS/$(APP)
	@cp Info.plist $(CONTENTS)/
	@cp AppIcon.icns $(CONTENTS)/Resources/
	@cp Sources/Resources/idevice_id Sources/Resources/ideviceinfo Sources/Resources/comptest Sources/Resources/bartbeat $(CONTENTS)/Resources/
	@cp Sources/Resources/lib/*.dylib $(CONTENTS)/Resources/
	@chmod +x $(CONTENTS)/Resources/idevice_id $(CONTENTS)/Resources/ideviceinfo $(CONTENTS)/Resources/comptest $(CONTENTS)/Resources/bartbeat
	@for f in $(CONTENTS)/Resources/*.dylib $(CONTENTS)/Resources/idevice_id $(CONTENTS)/Resources/ideviceinfo $(CONTENTS)/Resources/comptest $(CONTENTS)/Resources/bartbeat; do \
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

# Apple Development signatures look "damaged" on other Macs, so the DMG is unsigned.
dmg: build
	@VERSION=$$(defaults read "$(PWD)/$(CONTENTS)/Info" CFBundleShortVersionString); \
	DMG="Barttery-$$VERSION.dmg"; \
	STAGING=$$(mktemp -d); \
	ditto $(BUNDLE) "$$STAGING/$(BUNDLE)"; \
	find "$$STAGING/$(BUNDLE)" \( -name '*.dylib' -o -name Barttery -o -name idevice_id -o -name ideviceinfo -o -name comptest -o -name bartbeat \) -type f | while read f; do \
	  codesign --remove-signature "$$f" 2>/dev/null || true; \
	done; \
	codesign --remove-signature "$$STAGING/$(BUNDLE)" 2>/dev/null || true; \
	ln -s /Applications "$$STAGING/Applications"; \
	hdiutil create -volname "Barttery" -srcfolder "$$STAGING" -ov -format UDZO "$$DMG"; \
	rm -rf "$$STAGING"; \
	echo "=> $$DMG"

bartbeat:
	clang -o Sources/Resources/bartbeat bridge/bartbeat.c \
		-I$(BRIDGE_INC) \
		-L$(BUNDLED_LIB_DIR) \
		-limobiledevice-1.0.6 \
		-lusbmuxd-2.0.6 \
		-lplist-2.0.4 \
		-limobiledevice-glue-1.0.0 \
		-arch arm64
	@echo "=> Built bartbeat"

clean:
	rm -rf .build $(BUNDLE) Sources/Resources/bartbeat
