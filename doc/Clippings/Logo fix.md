---
title: "Logo fix"
source: "https://gemini.google.com/app/d02fba78b64638d8"
author:
published:
created: 2026-10-20
description: "Gemini conversation with 76 messages"
tags:
  - "clippings"
---
The reason your macOS dock keeps displaying the default Flutter logo—even after you feel like you have updated everything—comes down to a combination of **macOS Asset Catalog requirements** and **aggressive OS-level icon caching via LaunchServices**. macOS stubbornly holds onto the old icon cache long after the binary has changed.

To successfully override the default Flutter logo for your **DN** and **SF** applications, follow this precise pipeline to fix both the configuration and the cache:

### Step 1: Configure the Icon via `flutter_launcher_icons`

The cleanest way to handle multi-platform icon generation (including macOS `.icns` requirements) without manually messing with Xcode asset catalogs is to use the `flutter_launcher_icons` package.

1. Add the dependency to your `pubspec.yaml` under `dev_dependencies`:
	YAML
	```
	dev_dependencies:
	  flutter_launcher_icons: ^0.14.4
	```
2. Configure the target source image at the root level of your `pubspec.yaml`. Make sure your source image is a clean, uncompressed **1024x1024 PNG**:
	YAML
	```
	flutter_launcher_icons:
	  image_path: "assets/icon/logo_master.png"
	  macos:
	    generate: true
	```
3. Run the generator commands in your terminal:
	Bash
	```
	flutter pub get
	dart run flutter_launcher_icons
	```
	*This automatically populates `macos/Runner/Assets.xcassets/AppIcon.appiconset/` with the correct `.icns` assets and maps them in the Xcode manifest.*

### Step 2: Verify the Info.plist Link

Open your app's `macos/Runner/Info.plist` file and make sure the primary icon file is explicitly pointed to your asset set:

XML

```
<key>CFBundleIconFile</key>
<string>AppIcon</string>
```

### Step 3: Clear the macOS Dock & LaunchServices Cache (The Crucial Fix)

If you have already tried changing the icon and the default Flutter logo *still* appears in the dock, **macOS is serving a cached version of the icon from its LaunchServices database.**

To force macOS to drop the cache and render your new custom artwork, run these exact commands in your terminal:

1. Clean your build artifacts:
	Bash
	```
	flutter clean
	flutter pub get
	```
2. Rebuild your application:
	Bash
	```
	flutter build macos --release
	```
3. **Flush the macOS Dock cache** so it rescans the application bundle:
	Bash
	```
	killall Dock
	```
4. If you have moved a compiled `.app` file into your system *Applications* folder, force a timestamp update on the bundle so the OS realizes it has changed:
	Bash
	```
	touch /Applications/SegForge.app   # (or path to your app bundle)
	```

![profile picture](https://lh3.googleusercontent.com/a/ACg8ocKfg4f8NhSJ8P0T9UUkdmilfE-HfY5j2i5JkpG44NDWvKhmL0Q=s64-c-v1-rj)