BOTTLE  := $(HOME)/Library/Application Support/CrossOver/Bottles/Steam-2
GTAV    := $(BOTTLE)/drive_c/Program Files (x86)/Steam/steamapps/common/Grand Theft Auto V
CXSTART := $(HOME)/Applications/CrossOver.app/Contents/SharedSupport/CrossOver/bin/cxstart
CC      := /opt/homebrew/bin/x86_64-w64-mingw32-gcc
PYTHON  := venv/bin/python

AGENT   := com.devinwilson.wattline
PLIST   := $(HOME)/Library/LaunchAgents/$(AGENT).plist
SWIFTBAR:= $(HOME)/.config/swiftbar

.PHONY: all install app agent agent-off test test-overlay check-bottle run fake e2e e2e-log status clean

APP := Wattline.app

all: DSI_SiUSBXp_3_1.DLL test_shim.exe $(APP)

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

DSI_SiUSBXp_3_1.DLL: si_shim.c
	$(CC) -shared -o $@ $< -lws2_32 -Os -s

test_shim.exe: test_shim.c
	$(CC) -o $@ $< -Os -s

venv:
	/opt/homebrew/bin/python3.12 -m venv venv
	venv/bin/pip -q install bleak

# The fake stick has to sit next to GTA5.exe: LoadLibrary searches the
# executable's directory, not the scripts folder ANT_Receiver.dll lives in.
install: DSI_SiUSBXp_3_1.DLL test_shim.exe $(APP) venv
	cp DSI_SiUSBXp_3_1.DLL "$(GTAV)/"
	cp DSI_SiUSBXp_3_1.DLL "$(BOTTLE)/drive_c/windows/system32/"
	cp test_shim.exe DSI_SiUSBXp_3_1.DLL "$(BOTTLE)/drive_c/"
	@echo "installed - now run 'make agent' to start it at login"

# Start at login and stay up. Restarts on crash, idles until GTA V connects.
app: /Applications/$(APP)

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

# Full run-through with a simulated rider: launch GTA V while this is up and
# the avatar should pedal on its own. `make agent` puts things back after.
e2e: install
	-launchctl bootout gui/$(shell id -u)/$(AGENT) 2>/dev/null
	-pkill -f ant_stick.py
	rm -f "$(BOTTLE)/drive_c/ant_shim.log"
	@echo "launch GTA V now - watch the log below, ctrl-c when done"
	$(PYTHON) ant_stick.py --fake

# What GT Bike V's ANT receiver actually did with the fake dongle
e2e-log:
	@echo "--- shim (inside the bottle) ---"
	@cat "$(BOTTLE)/drive_c/ant_shim.log" 2>/dev/null || echo "(never loaded - GT Bike V did not use the SiLabs path)"

status:
	@launchctl print gui/$(shell id -u)/$(AGENT) 2>/dev/null | grep -E "^\s+(state|pid) " || echo "agent not loaded"
	@lsof -nP -iTCP:51234 -sTCP:LISTEN >/dev/null 2>&1 \
		&& echo "	bridge listening on 51234" || echo "	bridge NOT listening"
	@tail -n 3 "$(HOME)/Library/Logs/wattline.log" 2>/dev/null

# Does the bridge behave like an ANT+ stick? (pure macOS, no game needed)
test: venv
	$(PYTHON) test_bridge.py

# Does the overlay behave on screen? Drives the real menu and asserts against
# what the window server renders. Needs Accessibility and Screen Recording
# permission for your terminal, moves the overlay around, takes a few minutes.
test-overlay: overlay_test $(APP)
	./test_overlay.sh

overlay_test: overlay_test.swift
	xcrun swiftc -O -o $@ $<

# Does Windows code inside the bottle reach the bridge? Needs 'make fake' first.
check-bottle: test_shim.exe
	cp test_shim.exe DSI_SiUSBXp_3_1.DLL "$(BOTTLE)/drive_c/"
	"$(CXSTART)" --bottle Steam-2 -- "C:\\test_shim.exe"

run: venv
	$(PYTHON) ant_stick.py --name Madone

fake: venv
	$(PYTHON) ant_stick.py --fake

clean:
	rm -f DSI_SiUSBXp_3_1.DLL test_shim.exe overlay_test
