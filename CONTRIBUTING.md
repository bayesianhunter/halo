# Contributing

Halo takes **issues, not pull requests**. Bug reports, measurements from your Mac and ideas are welcome; code is
written and reviewed in the maintainers' own repository and released from there, so pull requests here are closed
without review. The license (GPL-3.0) lets you fork and change Halo as you like.

## A good bug report

1. The Halo version (About page) and macOS version, and the Mac model.
2. What you did, what you expected, what happened.
3. The diagnostics summary: on the **Diagnostics** page choose **Copy** next to the summary, or run
   `/Applications/Halo.app/Contents/MacOS/Halo --diagnostics`, and paste `latest.md`. It contains no serial
   numbers, Bluetooth addresses, clipboard contents or key presses; device IDs are keyed hashes. Read it before
   posting and remove anything you would rather not share, such as device or computer names.
4. For scrolling problems, record while reproducing: `halo --diagnostics --record 30` (or the full path above).

Security problems go through private reporting instead: see [SECURITY.md](SECURITY.md).
