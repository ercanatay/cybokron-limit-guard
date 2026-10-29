# Shared SwiftPM settings for scripts/build-app.sh and scripts/test.sh. Source it; don't run it.
#
# With Xcode selected (xcode-select -p) nothing special is needed. With only the Command Line Tools:
#   * The macOS 27+ SDK declares SwiftUI's @State as a macro whose plugin ships with Xcode only, so
#     the newest SDK that doesn't need it is selected (override with SDKROOT=...).
#   * swift-testing's macro plugin lives in a subdirectory the compiler doesn't search by default.
# Set SWIFTPM_SCRATCH_PATH to build somewhere other than .build/.

DEVELOPER_DIR_PATH="$(xcode-select -p)"
SWIFTPM_FLAGS=()

if [[ "$DEVELOPER_DIR_PATH" == *CommandLineTools* ]]; then
    if [[ -z "${SDKROOT:-}" ]]; then
        state_macro_marker='module: "SwiftUIMacros", type: "StateMacro"'
        for sdk in $(ls -d "$DEVELOPER_DIR_PATH"/SDKs/MacOSX[0-9]*.sdk | sort -rV); do
            interface="$sdk/System/Library/Frameworks/SwiftUICore.framework/Versions/A/Modules/SwiftUICore.swiftmodule/arm64e-apple-macos.swiftinterface"
            if ! grep -qF "$state_macro_marker" "$interface" 2>/dev/null; then
                export SDKROOT="$sdk"
                break
            fi
        done
        if [[ -z "${SDKROOT:-}" ]]; then
            echo "error: no macOS SDK usable without Xcode was found; install Xcode or set SDKROOT." >&2
            exit 1
        fi
    fi
    testing_plugins="$DEVELOPER_DIR_PATH/usr/lib/swift/host/plugins/testing"
    if [[ -d "$testing_plugins" ]]; then
        SWIFTPM_FLAGS+=(-Xswiftc -plugin-path -Xswiftc "$testing_plugins")
    fi
    echo "Command Line Tools build; SDK: $SDKROOT" >&2
fi

# Optional build directory outside the repository, e.g. when the checkout lives in a synced folder
# where SwiftPM's build database reports "disk I/O error".
if [[ -n "${SWIFTPM_SCRATCH_PATH:-}" ]]; then
    SWIFTPM_FLAGS+=(--scratch-path "$SWIFTPM_SCRATCH_PATH")
fi
