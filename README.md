# X-trans Darkroom

A native macOS RAW editor built around Fujifilm X-Trans files. It opens RAF files from cameras like the X-T5, gives you a Lightroom-style Develop panel, reads lens corrections straight out of the RAF, and can apply your Fujifilm film simulation recipes to a photo. It also opens Canon RAW, DNG (phones included), JPEG, HEIC, TIFF and PNG.

It is written in Swift and SwiftUI, renders on the GPU through Core Image and Metal, and runs only on Apple Silicon Macs.

## Why it exists

I shoot a Fujifilm X-T5 and a phone, and I wanted one editor on my Mac that treats X-Trans files as the main event instead of an afterthought. I wanted the Lightroom Classic workflow I already know (the panels, the keyboard shortcuts, before/after), without a subscription, and with my own film simulation recipes built in. So I wrote it.

It is a personal project. It works well for how I edit, and it is shared in case it works for you too.

## Download and install

1. Go to the [Releases](../../releases) page and download `X-trans-Darkroom-<version>-arm64.zip`.
2. Unzip it and drag **X-Trans Darkroom.app** into your Applications folder.
3. Open it once the way described below.

The app is signed ad hoc, not notarized by Apple, so macOS blocks the first launch with a message saying it can't verify the developer. To get past it:

1. Double-click the app and close the warning.
2. Open **System Settings > Privacy & Security**, scroll down, and click **Open Anyway** next to X-Trans Darkroom.
3. Confirm with your password or Touch ID.

You only do this once. If you prefer the terminal, this does the same thing:

```bash
xattr -dr com.apple.quarantine "/Applications/X-Trans Darkroom.app"
```

## Requirements

- A Mac with Apple Silicon (M1 or later). Intel Macs are not supported.
- macOS 26 or later.
- No account, no internet connection, no subscription.

## Supported files and cameras

| Kind | Extensions |
| --- | --- |
| RAW | `.raf` (Fujifilm), `.cr2` `.cr3` `.crw` (Canon), `.dng` (phones and other cameras) |
| Rendered | `.jpg` `.jpeg` `.heic` `.heif` `.hif` `.tif` `.tiff` `.png` |

RAW decoding uses Apple's own RAW engine, so any camera macOS can preview in Photos or Finder will open here. The app is tuned and tested for:

- Fujifilm X-Trans bodies (developed on an X-T5). These get the full set: film simulation recipes, a camera panel that shows the as-shot film simulation and settings read from the RAF, and lens corrections pulled from the file itself.
- Canon RAW and phone DNGs, including iPhone. These use the standard Develop tools plus built-in lens correction where macOS provides it.

Recipes and the camera panel only apply to genuine Fujifilm RAF files. The app checks the file header, so a renamed file won't fool it.

## Features

**Library**

- Add folders and browse them as a thumbnail grid with a cached preview for each photo.
- Star ratings, pick and reject flags, sorting and filtering.
- Copy develop settings from one photo and paste them onto many.

**Develop**

- Light: exposure, contrast, highlights, shadows, whites, blacks.
- Color: white balance with an eyedropper picker, saturation, vibrance, and a black and white treatment.
- Tone curve with composite and separate red, green and blue curves, drawn over a live histogram. The curve can't overshoot or reverse.
- Eight-band HSL mixer and three-way color grading.
- Effects: texture, clarity, dehaze, vignette, grain, and a soft glow in the style of the Photoshop "dreamy" look.
- Detail: sharpening, luminance and color noise reduction.
- Optics: on Fujifilm files, distortion, chromatic aberration and vignetting are corrected from tables stored in the RAF. That includes old and discontinued Fujinon lenses, which need no separate profile download.
- Geometry: crop with drag handles, straighten, perspective, rotate and flip.
- Camera profiles: load Adobe-format `.dcp` profiles and pick one per photo.
- Histogram with shadow and highlight clipping readouts, plus a clipping overlay on the image.
- Zoom from fit to 1600%, pan, and before/after views (side by side, top and bottom, or split).
- Undo and redo up to 100 steps. Edits are saved in a small `.xtd.json` sidecar file next to the photo and never touch the original.

**Fujifilm recipes**

Point the app at a spreadsheet (`.xlsx`) of your film simulation recipes, then browse them and apply one to a RAF file. Each row is a recipe. The app needs at least a `recipe_id` and a `name` column and understands the usual recipe fields, for example `film_simulation`, `wb_mode`, `wb_kelvin`, `wb_shift_r`, `wb_shift_b`, `dynamic_range`, `highlight_tone`, `shadow_tone`, `color`, `sharpness`, `noise_reduction`, `clarity`, `color_chrome_effect`, `color_chrome_fx_blue`, `grain_effect`, `grain_size` and `exposure_comp`. Put example photos in a folder named `examples` next to the spreadsheet.

**Export**

- Export one photo or a batch to JPEG or TIFF (8 or 16 bit), with resizing, output sharpening, metadata options (including stripping GPS), file naming and a destination of your choice (Downloads by default).
- Send to Phone: if the [Blip](https://blip.net) app is installed, one click renders a JPEG and hands it to Blip.

**Keyboard**

Most Lightroom Classic shortcuts work the same way: G for the grid, D for Develop, 0 to 5 for stars, P and X for flags, R for crop, Y for before/after, J for clipping, W for the white balance picker, and so on. Press ⌘/ in the app for the full list, or read [SHORTCUTS.md](SHORTCUTS.md).

## How it works

The window has two modes. **Library** is where you add folders, browse thumbnails, rate and flag. **Develop** shows one photo large in the middle with the editing panels in an inspector on the right. Press G and D (or Return) to move between them, Tab to hide the panels, and L to dim everything around the photo.

Every slider redraws a fast preview while you drag and then renders full resolution about a fifth of a second after you let go. On a 40 megapixel X-T5 file the full render takes under 100 ms on an M-series Mac.

## Building from source

You need the Xcode Command Line Tools with the macOS 26.5 SDK. Full Xcode is not required.

```bash
export SDKROOT=/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk
Scripts/verify.sh            # build everything, run the check suite, smoke-launch the app
Scripts/bundle.sh            # build build/XTransDarkroom.app
open build/XTransDarkroom.app
```

The SDK is pinned to 26.5 because the macOS 27 SDK that ships with the Command Line Tools is missing a SwiftUI macro plugin that only comes with full Xcode.

## Status

Version 0.1.0. Local adjustment masks (gradients, brush, color range) are in progress and will come in a later release.
