APP        = Barttery
BUNDLE     = Barttery.app
CONTENTS   = $(BUNDLE)/Contents
BIN_DIR    = .build/release
SIGN      ?= Apple Development: yura@yura.me (69Z678PHDM)

.PHONY: all build run install clean

all: build

AppIcon.icns: img/icon.png
	@ICONSET=$$(mktemp -d)/AppIcon.iconset && mkdir "$$ICONSET" && \
	for size in 16 32 64 128 256 512; do \
	  sips -z $$size $$size img/icon.png --out "$$ICONSET/icon_$${size}x$${size}.png" > /dev/null; \
	  sips -z $$((size*2)) $$((size*2)) img/icon.png --out "$$ICONSET/icon_$${size}x$${size}@2x.png" > /dev/null; \
	done && \
	iconutil -c icns "$$ICONSET" -o AppIcon.icns

build: AppIcon.icns
	swift build -c release
	@mkdir -p $(CONTENTS)/MacOS $(CONTENTS)/Resources
	@cp $(BIN_DIR)/$(APP) $(CONTENTS)/MacOS/$(APP)
	@cp Info.plist $(CONTENTS)/
	@cp AppIcon.icns $(CONTENTS)/Resources/
	@cp -r .build/arm64-apple-macosx/release/Barttery_Barttery.bundle $(CONTENTS)/Resources/
	@BNDL=$(CONTENTS)/Resources/Barttery_Barttery.bundle; \
	for f in $$BNDL/*.dylib $$BNDL/idevice_id $$BNDL/ideviceinfo $$BNDL/comptest; do \
	  [ -f "$$f" ] && codesign --force --sign "$(SIGN)" "$$f"; \
	done; \
	codesign --force --sign "$(SIGN)" --entitlements Barttery.entitlements $(BUNDLE)
	@echo "=> Built $(BUNDLE)"

run: build
	open $(BUNDLE)

install: build
	cp -r $(BUNDLE) /Applications/
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
