# Building VoiceInk (this fork)

This guide provides detailed instructions for building VoiceInk from source.

> **Fork note:** this repository is a fork of
> [Beingpax/VoiceInk](https://github.com/Beingpax/VoiceInk) with extra features
> (Claude Code / Antigravity subscription CLI providers, one-toggle AI
> Formatting, auto model download, `make dmg` packaging). Clone THIS repo, not
> upstream, to get them:
>
> ```bash
> git clone https://github.com/Royalcrist/VoiceInk.git
> cd VoiceInk
> make local        # builds without an Apple Developer account
> open ~/Downloads/VoiceInk.app
> ```
>
> If the build fails, jump to **[Known build issues & exact fixes](#known-build-issues--exact-fixes)**
> below — the common failures and their copy-paste solutions are documented there.

## Prerequisites

Before you begin, ensure you have:
- macOS 14.4 or later
- Xcode (latest version recommended)
- Swift (latest version recommended)
- Git (for cloning repositories)

## Quick Start with Makefile (Recommended)

The easiest way to build VoiceInk is using the included Makefile, which automates the entire build process including building and linking the whisper framework.

### Simple Build Commands

```bash
# Clone the repository
git clone https://github.com/Beingpax/VoiceInk.git
cd VoiceInk

# Build everything (recommended for first-time setup)
make all

# Or for development (build and run)
make dev
```

### Available Makefile Commands

- `make check` or `make healthcheck` - Verify all required tools are installed
- `make whisper` - Clone and build whisper.cpp XCFramework automatically
- `make setup` - Prepare the whisper framework for linking
- `make build` - Build the VoiceInk Xcode project
- `make local` - Build for local use (no Apple Developer certificate needed)
- `make run` - Launch the built VoiceInk app
- `make dev` - Build and run (ideal for development workflow)
- `make all` - Complete build process (default)
- `make clean` - Remove build artifacts and dependencies
- `make help` - Show all available commands

### How the Makefile Helps

The Makefile automatically:
1. **Manages Dependencies**: Creates a dedicated `~/VoiceInk-Dependencies` directory for all external frameworks
2. **Builds Whisper Framework**: Clones whisper.cpp and builds the XCFramework with the correct configuration
3. **Handles Framework Linking**: Sets up the whisper.xcframework in the proper location for Xcode to find
4. **Verifies Prerequisites**: Checks that git, xcodebuild, and swift are installed before building
5. **Streamlines Development**: Provides convenient shortcuts for common development tasks

This approach ensures consistent builds across different machines and eliminates manual framework setup errors.

---

## Building for Local Use (No Apple Developer Certificate)

If you don't have an Apple Developer certificate, use `make local`:

```bash
git clone https://github.com/Beingpax/VoiceInk.git
cd VoiceInk
make local
open ~/Downloads/VoiceInk.app
```

This builds VoiceInk with ad-hoc signing using a separate build configuration (`LocalBuild.xcconfig`) that requires no Apple Developer account.

### How It Works

The `make local` command uses:
- `LocalBuild.xcconfig` to override signing and entitlements settings
- `VoiceInk.local.entitlements` (stripped-down, no CloudKit/keychain groups)
- `LOCAL_BUILD` Swift compilation flag for conditional code paths

Your normal `make all` / `make build` commands are completely unaffected.

---

## Manual Build Process (Alternative)

If you prefer to build manually or need more control over the build process, follow these steps:

### Building whisper.cpp Framework

1. Clone and build whisper.cpp:
```bash
git clone https://github.com/ggerganov/whisper.cpp.git
cd whisper.cpp
./build-xcframework.sh
```
This will create the XCFramework at `build-apple/whisper.xcframework`.

### Building VoiceInk

1. Clone the VoiceInk repository:
```bash
git clone https://github.com/Beingpax/VoiceInk.git
cd VoiceInk
```

2. Add the whisper.xcframework to your project:
   - Drag and drop `../whisper.cpp/build-apple/whisper.xcframework` into the project navigator, or
   - Add it manually in the "Frameworks, Libraries, and Embedded Content" section of project settings

3. Build and Run
   - Build the project using Cmd+B or Product > Build
   - Run the project using Cmd+R or Product > Run

## Development Setup

1. **Xcode Configuration**
   - Ensure you have the latest Xcode version
   - Install any required Xcode Command Line Tools

2. **Dependencies**
   - The project uses [whisper.cpp](https://github.com/ggerganov/whisper.cpp) for transcription
   - Ensure the whisper.xcframework is properly linked in your Xcode project
   - Test the whisper.cpp installation independently before proceeding

3. **Building for Development**
   - Use the Debug configuration for development
   - Enable relevant debugging options in Xcode

4. **Testing**
   - Run the test suite before making changes
   - Ensure all tests pass after your modifications

## Known build issues & exact fixes

These are real failures encountered while building this fork, with the exact
commands that fix them. Work through them in order if `make local` fails.

### 1. whisper.cpp XCFramework build fails on Xcode 26 ("No CMAKE_C_COMPILER could be found")

`make` clones whisper.cpp and runs its `build-xcframework.sh`, which currently
fails with Xcode 26's CMake generator:

```
-- The C compiler identification is unknown
CMake Error at CMakeLists.txt:2 (project):
  No CMAKE_C_COMPILER could be found.
make: *** [whisper] Error 1
```

**Fix — use the prebuilt XCFramework from whisper.cpp's releases:**

```bash
# Find the latest xcframework asset (needs GitHub CLI, or browse the releases page)
gh api repos/ggml-org/whisper.cpp/releases/latest \
  --jq '.assets[] | select(.name | test("xcframework")) | .browser_download_url'

# Download and place it exactly where the Makefile expects it (adjust version):
curl -sL -o /tmp/whisper-xcframework.zip \
  https://github.com/ggml-org/whisper.cpp/releases/download/v1.9.1/whisper-v1.9.1-xcframework.zip
unzip -q -o /tmp/whisper-xcframework.zip -d /tmp/whisper-xcfw
mkdir -p ~/VoiceInk-Dependencies/whisper.cpp/build-apple
ditto /tmp/whisper-xcfw/build-apple/whisper.xcframework \
  ~/VoiceInk-Dependencies/whisper.cpp/build-apple/whisper.xcframework
```

Then run `make local` again — the Makefile skips the whisper build when the
framework already exists at that path.

### 2. xcodebuild fails with "A required plugin failed to load"

Seen after an Xcode update (e.g. `IDESimulatorFoundation` dlopen errors).
Xcode needs its first-launch component installation:

```bash
xcodebuild -runFirstLaunch
```

Then rebuild.

### 3. Running the test suite

The plain `test` action fails asking for a provisioning profile. Use the local
signing flags:

```bash
xcodebuild -project VoiceInk.xcodeproj -scheme VoiceInk -configuration Debug \
  -derivedDataPath .local-build \
  -xcconfig LocalBuild.xcconfig \
  CODE_SIGN_IDENTITY="-" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=YES \
  DEVELOPMENT_TEAM="" CODE_SIGN_STYLE=Manual PROVISIONING_PROFILE_SPECIFIER="" \
  CODE_SIGN_ENTITLEMENTS="$PWD/VoiceInk/VoiceInk.local.entitlements" \
  SWIFT_ACTIVE_COMPILATION_CONDITIONS='$(inherited) LOCAL_BUILD' \
  test -only-testing:VoiceInkTests
```

### 4. Permissions break after every rebuild (ad-hoc signing)

`make local` signs the app ad-hoc, so every rebuild produces a new code
signature. macOS ties Accessibility/Screen Recording grants to the signature,
which means **after each rebuild the Accessibility grant must be redone**:

```bash
tccutil reset Accessibility com.prakashjoshipax.VoiceInk
open ~/Downloads/VoiceInk.app
# then: System Settings → Privacy & Security → Accessibility → enable VoiceInk
```

The app re-arms its shortcut listener automatically within a couple of seconds
of the grant — no restart needed. If System Settings shows several stale
"VoiceInk" rows, remove them all with "−" first and let the app re-add itself.

Distributed builds (the DMG) are not affected: recipients install one stable
copy and grant once.

### 5. Building the shareable DMG

```bash
make dmg     # Release build + drag-to-Applications DMG at ./VoiceInk.dmg
```

The DMG contains the app, an Applications symlink, and a plain-language
install guide (including the one-time right-click → Open step that unsigned
apps need on first launch).

## General troubleshooting

If you encounter any other build issues:
1. Clean the build folder (Cmd+Shift+K)
2. Clean the build cache (Cmd+Shift+K twice)
3. Check Xcode and macOS versions
4. Verify all dependencies are properly installed
5. Make sure whisper.xcframework is properly built and linked

For more help, please check the [issues](https://github.com/Beingpax/VoiceInk/issues) section or create a new issue. 