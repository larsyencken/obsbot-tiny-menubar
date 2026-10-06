APP = build/ObsbotBar.app
BIN = .build/release/ObsbotBar

.PHONY: all app run install clean $(BIN)

all: app

$(BIN):
	swift build -c release

app: $(BIN)
	rm -rf $(APP)
	mkdir -p $(APP)/Contents/MacOS $(APP)/Contents/Resources
	cp $(BIN) $(APP)/Contents/MacOS/ObsbotBar
	cp Info.plist $(APP)/Contents/Info.plist
	cp Resources/AppIcon.icns $(APP)/Contents/Resources/AppIcon.icns
	codesign --force --sign - $(APP)

run: app
	open $(APP)

install: app
	rm -rf /Applications/ObsbotBar.app
	cp -R $(APP) /Applications/

clean:
	rm -rf build .build
