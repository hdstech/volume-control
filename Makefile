CONFIG ?= release
APP := build/VolumeControl.app

.PHONY: build app run install icon list test clean

build:
	swift build -c $(CONFIG)

app:
	./Scripts/bundle.sh $(CONFIG)

run: app
	-pkill -x VolumeControl
	open $(APP)

install: app
	-pkill -x VolumeControl
	rm -rf /Applications/VolumeControl.app
	cp -R $(APP) /Applications/VolumeControl.app
	open /Applications/VolumeControl.app

icon:
	swift Scripts/make-icon.swift Resources/AppIcon.png

list: build
	"$$(swift build -c $(CONFIG) --show-bin-path)/VolumeControl" --list

test:
	swift test

clean:
	rm -rf .build build
