# CT Viewer

A native macOS (SwiftUI) viewer for CT DICOM studies, with no external dependencies.

- Opens folders (e.g. a copied patient CD), individual DICOM files or mountable `.iso` disc images
- Axial / coronal / sagittal multiplanar reconstruction with linked crosshairs
- Window presets (lung, mediastinum, soft tissue, bone, liver, brain), invert, cine playback
- Distance measurements in mm, Hounsfield-unit probe under the cursor
- DICOM attribute inspector with filter
- Uncompressed DICOM (implicit/explicit VR, little/big endian); JPEG and JPEG 2000 via ImageIO

**For viewing only — not for diagnostic use.**

## Build

Requires macOS 14+ and the Xcode Command Line Tools (full Xcode is not needed).

```bash
./scripts/build-app.sh
open "build/CT Viewer.app"
```

## Controls

| Input | Action |
| --- | --- |
| Scroll / ↑ ↓ | Previous / next slice (PgUp/PgDn ±10, Home/End) |
| Left drag | Active tool (W window/level, P pan, Z zoom, M measure, C crosshair) |
| Right drag · pinch · ⌘-scroll | Zoom |
| ⌥ drag · middle drag | Pan |
| Double-click / F | Maximize view ↔ three planes |
| 1–6 | Window presets |
| I · R · X · Space | Invert · reset · toggle crosshair · cine |
| ⌫ | Delete measurements on the current slice |
| ⌘E | Export the focused view as PNG |

Headless check: `.build/release/CTViewer --selftest <dicom-folder> <png-output-folder>`

## Sample data

To try the viewer without your own scans, download a public chest CT series (~35 MB):

```bash
./scripts/fetch-sample.sh
```

It fetches patient `LIDC-IDRI-0001` from the LIDC-IDRI collection on The Cancer Imaging Archive
into `sample-data/` (not committed), licensed CC BY 3.0:

> Armato III, S. G., et al. (2015). Data From LIDC-IDRI. The Cancer Imaging Archive.
> https://doi.org/10.7937/K9/TCIA.2015.LO9QL9SX

## Releases

Pushing a tag like `v1.0.0` builds the app on GitHub Actions and attaches `CT-Viewer.zip` to a GitHub
release. The app is ad-hoc signed, not notarized: on first launch right-click it and choose **Open**, or run
`xattr -dr com.apple.quarantine "CT Viewer.app"`.
