# Builds the tvOS app with xcodebuild. `make help` lists the targets.
#
# build and run ask which tvOS device or simulator to use. To skip the question, pass its
# id or name: `make run DEVICE=<id or name>`. Other variables can be overridden the same
# way, e.g. `make build CONFIG=Release`.

PROJECT   := AppleTV/Switft TVH Client/Switft TVH Client.xcodeproj
SCHEME    := Switft TVH Client
BUNDLE_ID := site.kirsch.Switft-TVH-Client

# Debug or Release.
CONFIG ?= Debug

# Extra xcodebuild arguments, e.g. XCFLAGS=-allowProvisioningUpdates.
XCFLAGS ?=

# xcode-select points at the Command Line Tools here, which can't build apps.
export DEVELOPER_DIR ?= /Applications/Xcode.app/Contents/Developer

XCODEBUILD = xcodebuild -project "$(PROJECT)" -scheme "$(SCHEME)" -configuration $(CONFIG) $(XCFLAGS)

# Shell code that sets $platform, $id and $name for the device to use: the one matching
# $DEVICE (an id or a name) if that is set, otherwise the one the user picks from a menu
# of the tvOS devices and simulators xcodebuild can build for. Recipes run it with
# `eval "$$PICK_DEVICE"`, so what it sets is visible to the rest of the recipe.
define PICK_DEVICE
echo "Looking for tvOS devices..."
devices=$$($(XCODEBUILD) -showdestinations 2>/dev/null | sed -n -E '/ncompatible/q; s/^[[:space:]]*\{ platform:(tvOS( Simulator)?), (arch:[^,]*, )?id:([0-9A-Fa-f-]+), (OS:[^,]*, )?name:(.*) \}$$/\1|\4|\6/p')
[ -n "$$devices" ] || { echo "No tvOS devices or simulators available." >&2; exit 1; }
menu() { printf '%s\n' "$$devices" | awk -F'|' '{ printf "  %d) %-40s %-15s %s\n", NR, $$3, $$1, $$2 }'; }
if [ -z "$$DEVICE" ]; then
	echo "Which device?"; menu
	[ -t 0 ] || { echo "Not a terminal: pass DEVICE=<id or name> to choose one." >&2; exit 1; }
	printf 'Device number [1-%s]: ' "$$(printf '%s\n' "$$devices" | awk 'END { print NR }')"
	read -r n || n=
	choice=$$(printf '%s\n' "$$devices" | awk -F'|' -v n="$$n" 'NR == n')
else
	choice=$$(printf '%s\n' "$$devices" | awk -F'|' -v d="$$DEVICE" '$$2 == d || $$3 == d { print; exit }')
fi
if [ -z "$$choice" ]; then echo "No such device. Available:" >&2; menu >&2; exit 1; fi
platform=$${choice%%|*}; choice=$${choice#*|}; id=$${choice%%|*}; name=$${choice#*|}
echo "Using $$name ($$id)"
endef
export PICK_DEVICE

DESTINATION = -destination "platform=$$platform,id=$$id"

# arm64 only: a Release build for the simulator defaults to arm64 + x86_64, and LibDovi's
# xcframework has no x86_64 simulator slice, so it would fail at link time.
BUILD = $(XCODEBUILD) $(DESTINATION) ARCHS=arm64 build

# Path of the built .app. DerivedData's folder name is hashed, so ask xcodebuild.
APP_PATH = "$$($(XCODEBUILD) $(DESTINATION) -showBuildSettings | awk -F ' = ' \
	'/^ *BUILT_PRODUCTS_DIR =/ {dir = $$2} /^ *FULL_PRODUCT_NAME =/ {name = $$2} END {print dir "/" name}')"

.DEFAULT_GOAL := build
.PHONY: build run clean help

build: ## Build for a device or simulator you pick
	eval "$$PICK_DEVICE" && $(BUILD)

run: ## Build, then install and launch on a device or simulator you pick
	eval "$$PICK_DEVICE" && $(BUILD) && \
	app=$(APP_PATH) && \
	if [ "$$platform" = "tvOS Simulator" ]; then \
		xcrun simctl bootstatus "$$id" -b >/dev/null && \
		xcrun simctl install "$$id" "$$app" && \
		xcrun simctl launch --terminate-running-process "$$id" $(BUNDLE_ID); \
	else \
		xcrun devicectl device install app --device "$$id" "$$app" && \
		xcrun devicectl device process launch --terminate-existing --device "$$id" $(BUNDLE_ID); \
	fi

clean: ## Remove build products and intermediates
	$(XCODEBUILD) -destination 'generic/platform=tvOS' clean
	$(XCODEBUILD) -destination 'generic/platform=tvOS Simulator' clean

help: ## Show this help
	@awk -F ':.*## ' '/^[a-z-]+:.*## / {printf "  make %-7s%s\n", $$1, $$2}' $(MAKEFILE_LIST)
