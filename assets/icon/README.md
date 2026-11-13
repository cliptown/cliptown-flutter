# App icon

`app_icon.svg` is the source of the ClipTown app icon: the rounded play
triangle (shared with the tray glyph in `../tray/`) around a lit city skyline,
on a deep-purple rounded square sized to the macOS icon grid (824px square on a
1024px canvas). `app_icon_full_bleed.svg` is the same artwork cropped to the
square, for platforms that do not pad icons.

Regenerate every platform icon after editing the SVG:

```sh
# macOS (Finder, Dock, Spotlight, Launchpad)
for s in 16 32 64 128 256 512 1024; do
  rsvg-convert -w $s -h $s app_icon.svg \
    -o ../../macos/Runner/Assets.xcassets/AppIcon.appiconset/app_icon_$s.png
done
# Windows (.exe, taskbar, Start)
for s in 16 24 32 48 64 128 256; do
  rsvg-convert -w $s -h $s app_icon_full_bleed.svg -o /tmp/win-$s.png
done
magick /tmp/win-{16,24,32,48,64,128,256}.png ../../windows/runner/resources/app_icon.ico
# Linux window/taskbar icon (bundled asset, loaded by linux/runner/my_application.cc)
rsvg-convert -w 256 -h 256 app_icon_full_bleed.svg -o app_icon_256.png
```
