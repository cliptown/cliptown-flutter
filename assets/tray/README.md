# Tray icons

`tray_template.svg` (macOS template, tinted by the system), `tray_color.svg`
(Windows/Linux resting icon) and `tray_highlight.svg` (the flash shown when
⌥C/Alt+C summons ClipTown) are the sources; the PNG/ICO files are rendered
from them and must be regenerated together:

```sh
for n in tray_template tray_color tray_highlight; do
  rsvg-convert -w 36 -h 36 $n.svg -o $n.png        # 18pt @2x
done
for n in tray_color tray_highlight; do
  for s in 16 24 32 48 64; do rsvg-convert -w $s -h $s $n.svg -o /tmp/$n-$s.png; done
  magick /tmp/$n-{16,24,32,48,64}.png $n.ico
done
```

`lib/desktop/tray_icon.dart` maps each platform to its file and
`test/desktop_shell_test.dart` checks every mapped file exists and is listed in
`pubspec.yaml`.
