# Contributing

Halo welcomes bug reports, measurements and ideas through issues. External code pull requests are not accepted;
code is developed and reviewed by the maintainers, then published here through release-sync pull requests.
The GPL-3.0 license lets you fork and change Halo as you like.

## A good bug report

1. The Halo version (About page) and macOS version, and the Mac model.
2. What you did, what you expected, what happened.
3. The diagnostics summary: on the **Diagnostics** page choose **Copy** next to the summary, or run
   `/Applications/Halo.app/Contents/MacOS/Halo --diagnostics`, and paste `latest.md`. It contains no serial
   numbers, Bluetooth addresses, clipboard contents or key presses; device IDs are keyed hashes. Read it before
   posting and remove anything you would rather not share, such as device or computer names.
4. For scrolling problems, record while reproducing: `halo --diagnostics --record 30` (or the full path above).

Security problems go through private reporting instead: see [SECURITY.md](SECURITY.md).
