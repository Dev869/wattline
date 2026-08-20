PYTHON  := venv/bin/python
AGENT   := com.devinwilson.wattline
PLIST   := $(HOME)/Library/LaunchAgents/$(AGENT).plist
SWIFTBAR:= $(HOME)/.config/swiftbar

.PHONY: all install app agent agent-off test test-overlay run fake status clean

APP := Wattline.app

all: $(APP)

# A real app bundle, purely so macOS has an identity to hang Bluetooth
# permission on. A LaunchAgent running python bare is silently blocked:
# CoreBluetooth never powers on and every scan hangs forever.
$(APP): main.swift Menu.swift Overlay.swift Readout.swift PlanGraph.swift Settings.swift Branding.swift Info.plist AppIcon.icns
	mkdir -p $(APP)/Contents/MacOS $(APP)/Contents/Resources
	cp Info.plist $(APP)/Contents/Info.plist
	cp AppIcon.icns $(APP)/Contents/Resources/
	xcrun swiftc -O -o $(APP)/Contents/MacOS/Wattline main.swift Menu.swift Overlay.swift Readout.swift PlanGraph.swift Settings.swift Branding.swift
	codesign -s - --force --deep $(APP)
	touch $(APP)

AppIcon.icns: make_icon.swift
	rm -rf AppIcon.iconset
	xcrun swiftc -O -o /tmp/makeicon make_icon.swift && /tmp/makeicon
	iconutil -c icns AppIcon.iconset -o AppIcon.icns

# Put it where you would look for an app
/Applications/$(APP): $(APP)
	rm -rf "/Applications/$(APP)"
	cp -R $(APP) /Applications/
	@echo "installed /Applications/$(APP) - open it like any app"

venv:
	/opt/homebrew/bin/python3.12 -m venv venv
	venv/bin/pip -q install bleak

install: $(APP) venv
	@echo "built - now run 'make agent' to start it at login"

app: /Applications/$(APP)

# Start at login and stay up, scanning for sensors so they connect on their own.
agent: install app
	sed -e 's|__DIR__|$(CURDIR)|g' -e 's|__HOME__|$(HOME)|g' \
		com.devinwilson.wattline.plist > "$(PLIST)"
	-launchctl bootout gui/$(shell id -u)/$(AGENT) 2>/dev/null
	launchctl bootstrap gui/$(shell id -u) "$(PLIST)"
	@mkdir -p "$(SWIFTBAR)" && cp wattline.5s.sh "$(SWIFTBAR)/" && chmod +x "$(SWIFTBAR)/wattline.5s.sh"
	@sleep 1 && $(MAKE) --no-print-directory status

agent-off:
	-launchctl bootout gui/$(shell id -u)/$(AGENT)
	rm -f "$(PLIST)" "$(SWIFTBAR)/wattline.5s.sh"

status:
	@launchctl print gui/$(shell id -u)/$(AGENT) 2>/dev/null | grep -E "^\s+(state|pid) " || echo "agent not loaded"
	@lsof -nP -iTCP:51235 -sTCP:LISTEN >/dev/null 2>&1 \
		&& echo "	daemon listening on 51235" || echo "	daemon NOT listening"
	@tail -n 3 "$(HOME)/Library/Logs/wattline.log" 2>/dev/null

# Does it scan on its own, report what it hears, and decode a relayed ANT+ page?
test: venv
	$(PYTHON) test_scan_default.py
	$(PYTHON) test_nearby.py
	$(PYTHON) test_ant.py
	$(PYTHON) test_relay.py

# Does the overlay behave on screen? Drives the real menu and asserts against
# what the window server renders. Needs Accessibility and Screen Recording
# permission for your terminal, moves the overlay around, takes a few minutes.
test-overlay: overlay_test $(APP)
	./test_overlay.sh

overlay_test: overlay_test.swift
	xcrun swiftc -O -o $@ $<

run: venv
	$(PYTHON) daemon.py

fake: venv
	$(PYTHON) daemon.py --fake

clean:
	rm -f overlay_test
