---
aliases: change brightness, screen brightness, dim screen, display settings, adjust brightness
tags: display, screen, accessibility
---

ADJUSTING DISPLAY

Brightness:
1. Find your backlight: ls /sys/class/backlight/
2. Read current: cat /sys/class/backlight/*/brightness
3. Read max: cat /sys/class/backlight/*/max_brightness
4. Set (requires root): echo 100 | sudo tee /sys/class/backlight/*/brightness

Resolution:
1. List outputs: xrandr (X11) or wlr-randr (Wayland)
2. Change: xrandr --output HDMI-1 --mode 1920x1080

Notes:
- On laptops, function keys (Fn+F5/F6) often work without commands.
- Cog renderer: display is managed by the compositor, not these commands.
