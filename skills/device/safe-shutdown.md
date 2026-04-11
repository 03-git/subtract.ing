---
aliases: shut down, turn off, power off, restart, reboot
tags: power, shutdown, restart
---

SAFE SHUTDOWN

Shut down:
1. Save your work.
2. Run: sudo shutdown now

Restart:
1. Run: sudo reboot

Scheduled shutdown:
1. In 10 minutes: sudo shutdown +10
2. Cancel scheduled: sudo shutdown -c

Notes:
- Never unplug without shutting down. Filesystem corruption is real.
- If the system is frozen: hold power button 5 seconds (hardware override).
