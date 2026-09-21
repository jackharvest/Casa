# Keyboard and pointer map

Shortcuts are registered in two places and both must agree: `ViewerController.keyDown`
for the bare keys, and `MenuBuilder` for anything with a modifier — on macOS the
menu bar is where modified shortcuts are *registered*, not merely advertised.

## Navigation

| Key | Action |
|---|---|
| `←` `→` `↑` `↓` | Previous / next image |
| `⌥` + arrow | Jump 10 |
| `Page Up` / `Page Down` | Jump 10 |
| `Home` / `End` | First / last image |
| `Space` | Next image |
| `⌘[` / `⌘]` | Previous / next image |

Navigation clamps at both ends rather than wrapping. Wrapping makes it
impossible to tell you have reached the end of a folder.

## Zoom

| Input | Action |
|---|---|
| `0` or `⌘0` | Fit to window |
| `1` or `⌘1` | Actual size (1 image pixel per *screen* pixel) |
| `+` / `-` | Zoom about the center |
| Mouse wheel | Zoom about the pointer, smoothly. The percentage appears beside the cursor |
| `⌃` + wheel | Previous / next image |
| Trackpad two-finger | Pan |
| Trackpad pinch | Zoom about the pointer |
| Double-click | Toggle fit ⇄ 1:1, anchored where you clicked |
| Drag | Pan |
| Click the surround | Switch between full-screen and a window hugging the photo |

Dragging a photo that already fits moves it and leaves it there, rather than
snapping back to the middle. Picasa did this because you are usually lining up
a zoom.

A mouse wheel and a trackpad are different instruments and are deliberately not
mapped to the same gesture — `NSEvent.hasPreciseScrollingDeltas` tells them
apart. Two-finger scroll means pan everywhere else on macOS; a wheel means zoom
to anyone who used Picasa.

## Clipboard and Finder

| Key | Action |
|---|---|
| `⌘C` | Copy the image *and* its file URL — paste does the obvious thing either way |
| `⌥⌘C` | Copy the POSIX path as text |
| `⌘R` | Reveal in Finder |

## Window

| Key | Action |
|---|---|
| `Esc` or `⌘W` | Close |
| The X, top right | Close |
| `⇧⌘[` / `⇧⌘]` | Rotate left / right. Written to the file when you move on, losslessly where the format has an orientation tag |
| `⌘Q` | Quit |
