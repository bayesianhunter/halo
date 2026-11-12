# Changelog

## 0.8.0 (2026-11-12)

First public release.

- Scrolling per device: reverse a mouse and keep the trackpad natural (or the other way round), decided by which device
  sent each scroll; devices Universal Control lends from another Mac get their own switch; wheel speed 0.5× to 4×.
- Correct wheel direction in iPhone Mirroring, also over Universal Control; trackpad scrolling remains natural.
- Batteries of mice, keyboards, trackpads, Bluetooth speakers and headphones, with an estimate of how long each lasts.
- Bluetooth speakers kept off the microphone, so music stays at full quality.
- Two paired Macs: each shows the other's devices, scrolling settings can stay in step, and the clipboard can follow
  the pointer through Universal Control; Halo notices when Universal Control leaves input stuck on the other Mac.
- Uninstall Halo… in Settings removes everything Halo put on the Mac: it unpairs (telling the other Mac if it is
  connected), deletes the pairing key, turns off Open at Login, removes its Agent Skill links and moves its files and
  the app to the Trash (an app installed with Homebrew is left to `brew uninstall --cask halo`). `halo --uninstall`
  lists the same without removing anything.
- Feedback: Settings → About → Send Feedback… opens a GitHub issue or an email with the Halo and macOS versions
  written in; clicking the version at the top of the menu copies them.
- For coding agents: `halo --diagnostics`, on-demand checks, a 30-day event log, `--set` for reverse, wheel speed and the speaker microphone rule, and a
  bundled Agent Skill.
