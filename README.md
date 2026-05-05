# Highlight Anything

A tiny macOS menu bar app that lets you copy text from anywhere on screen, e.g. images, videos, PDFs and other apps by holding **Shift** and dragging a rectangle over it.

The selection is captured via ScreenCaptureKit, run through Vision OCR, and dropped onto your clipboard. A toast confirms what was copied.

## Requirements

- macOS 14+
- Xcode Command Line Tools (`xcode-select --install`)

## Build

```bash
./build.sh
open HighlightAnything.app
```

## Permissions

On first launch, grant Highlight Anything both:

1. **Accessibility** — to detect when Shift is held
2. **Screen Recording** — to capture pixels for OCR

After enabling both, quit from the 📋 menu bar item and relaunch.

## Usage

1. Hold **Shift**. The menu bar icon flips to ✂️ and a blue border appears around each screen.
2. Drag a rectangle over the text you want.
3. Release. The text is on your clipboard and a toast shows a preview.

Quit anytime via the menu bar icon → Quit Highlight Anything.

## License

MIT — see [LICENSE](LICENSE).
