# Snapmark

A fast, free screenshot and markup tool for macOS, inspired by the Snagit workflow.

> Early release: expect rough edges, and please open an issue if something breaks.

## Features

- **Smart capture** (⌃⇧1): hover to snap to windows, panels and buttons (scroll to pick a bigger area), or drag a region. A magnifier shows exact pixels and color; the toolbar under the selection lets you type an exact size. Arrows nudge, ⌥-arrows resize.
- **Scrolling capture** (S, or the Scrolling button): Snapmark scrolls the page and stitches it into one tall image, keeping sticky headers once. If an app ignores automatic scrolling, just scroll it yourself and press Done.
- **Fast**: the capture screen appears in about 0.1 s and captures open in the editor in under 0.1 s.
- **Window** (⌃⇧2) and **full screen** (⌃⇧3) capture, plus a 3-second delay.
- **Editor**: arrow, text, callout, shapes, numbered steps, highlight, blur, pixelate, redact, spotlight, magnify, stamps, crop, color picker.
- **Hide or show the mouse cursor** after capture.
- **Grab Text**: on-device OCR copies all text in a capture.
- **Pin**: float a screenshot above every window.
- **Effects**: border, shadow, rounded corners, gradient backdrop, rotate, flip, resize.
- **Export**: copy, drag out, PNG, JPEG, share sheet. Captures are kept in `~/Pictures/Snapmark`.

## Build

Requires macOS 14+ and the Xcode Command Line Tools (`xcode-select --install`). No Xcode project needed.

```bash
./build.sh           # builds Snapmark.app here
./build.sh install   # builds and installs to ~/Applications
```

## First launch

Snapmark needs **Screen Recording** (to capture) and, optionally, **Accessibility** (to snap to buttons and panels). On first launch a helper panel lets you drag the app icon straight into the right System Settings list.

Downloaded builds are not notarized. The first time, right-click Snapmark.app and choose **Open**, or run:

```bash
xattr -dr com.apple.quarantine /path/to/Snapmark.app
```

## License

MIT
