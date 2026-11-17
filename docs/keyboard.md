# Keyboard and pointer map

Shortcuts are registered in two places and both must agree: `ViewerController.keyDown`
for the bare keys, and `MenuBuilder` for anything with a modifier — on macOS the
menu bar is where modified shortcuts are *registered*, not merely advertised.

## Navigation

| Key | Action |
|---|---|
| `←` `→` | Previous / next image |
| `⌥` + arrow | Jump 10 |
| `Page Up` / `Page Down` | Jump 10 |
| `Home` / `End` | First / last image |
| `Space` | Next image |
| `⌘[` / `⌘]` | Previous / next file, always — the way past a long PDF |
| `S` | Start or stop a slideshow (3.5 s per photo; stops at the end, or when you zoom) |

Navigation clamps at both ends rather than wrapping. Wrapping makes it
impossible to tell you have reached the end of a folder.

## Zoom

| Input | Action |
|---|---|
| `0` or `⌘0` | Fit to window |
| `1` | Actual size (1 image pixel per *screen* pixel), or back to fit if already there |
| `⌘1` | Actual size |
| `↑` / `↓` | Zoom in / out about the center, as Picasa did |
| `+` / `-` | Zoom about the center |
| Mouse wheel | Zoom about the pointer, smoothly. The percentage appears beside the cursor |
| `⌃` + wheel | Previous / next image |
| Trackpad two-finger | Pan |
| Trackpad pinch | Zoom about the pointer |
| Double-click | Toggle fit ⇄ 1:1, anchored where you clicked |
| Drag | Pan |
| Click the surround, or `Return` | Switch between full-screen and a window hugging the photo |

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

## Files

| Key | Action |
|---|---|
| `⌘O` | Open… |
| `⌘N` | New from Clipboard |
| `⌘S` | Save edits. A photo's original goes to the Trash first |
| `⇧⌘S` | Duplicate |
| `⇧⌘E` | Export… (any writable format; PDF password and size options) |
| `⌘P` | Print… |
| `⌘⌫` | Move to Trash and show the next file. `⌘Z` puts it back |
| `⌘I` | Inspector |
| `⌘Z` / `⇧⌘Z` | Undo / redo: edits, markup, trash, rename |

## Editing photos

| Key | Action |
|---|---|
| `⌘K` | Crop. `Return` applies, `Esc` cancels, double-click applies |
| `⌥⌘A` | Adjust Color |
| `⇧⌘A` | Markup tools. `Return` or `Esc` finishes and keeps the marks |
| `⇧⌘K` | Remove Background |
| `Shift` while drawing | Constrain a line to 45°, a box to a square |
| `Delete` | Remove the selected mark |
| `⌘A`, then `⌘C` | Select and copy the text in a photo |

## PDFs

| Key | Action |
|---|---|
| `←` `→` | Previous / next page. Floating over the desktop, the ends fall through to the neighbouring file |
| `Return` | Switch between floating and the reading window |
| `⌘F`, `⌘G`, `⇧⌘G` | Find, next, previous |
| `⌥⌘G` | Go to Page… |
| `⌥⌘S` | Sidebar |
| `⌃⌘H` / `⌃⌘U` / `⌃⌘S` | Highlight / underline / strike through the selection |
| `⇧⌘[` / `⇧⌘]` | Rotate the page |

## Window

| Key | Action |
|---|---|
| `Esc` or `⌘W` | Close |
| The X, top right | Close |
| `⇧⌘[` / `⇧⌘]` | Rotate left / right. Written to the file when you move on, losslessly where the format has an orientation tag |
| `⌘Q` | Quit |
