---
name: halo
description: Diagnose Mac peripheral problems with Halo, a macOS menu-bar app. Use when the person asks about Halo or wants to check or investigate per-device scrolling (a mouse that scrolls the wrong way, reversing scroll direction for one device, wheel speed), a mouse, trackpad or keyboard, peripheral battery levels or drain, Bluetooth speakers or headphones (sound, microphone, disconnects), Universal Control handoffs, or the link between their two paired Macs. Read live diagnostics or past events, run on-demand checks, and change an explicitly requested Halo setting.
---

# Halo

## The command

`halo` when Halo was installed with Homebrew; otherwise `/Applications/Halo.app/Contents/MacOS/Halo`. Both are the
same program; below it is `halo`. `halo --help` lists every command. A flag it does not know prints the usage instead
of starting Halo, and while Halo runs no command starts a second copy.

Start Halo with `open -a Halo`, outside your sandbox (a sandbox can hide Launch Services), or ask the person to open
it. Never start it with a bare `halo`: when Halo is not running, that runs the whole app in the foreground of your
shell, so the command does not return, the app quits when the shell ends, and macOS checks the Accessibility
permission of whatever started it, not Halo's. (While Halo runs, a bare `halo` only says so and exits.)

`--diagnostics` (with or without a check below) and `--set` reach the running app through a macOS distributed
notification, which agent sandboxes block: run them outside the sandbox, asking the person to allow it if you need
to. `--events` and `--watch` only read files and work anywhere.

If Halo is not installed and the person wants it, follow "Set up with your coding agent" under Get started in the
README of https://github.com/bayesianhunter/halo. Only the person can allow Halo under Accessibility; never try to
change privacy settings for them.

## What Halo knows now

```bash
halo --diagnostics
```

It asks the running Halo to export and prints the paths, age and a one-screen summary. It writes diagnostics files
and leaves settings alone. The exit status does not tell you whether the data is current; the output does. If it
says `Not current`, `cached live` or `cold`, or stderr reports that the request failed, the files are old or limited:
say so, and do what the output says (open Halo, run outside the sandbox, or ask the person for **Copy**). When the
app could not be asked and no export exists yet, the command writes a `cold` one: only devices, batteries and saved
settings.

- `~/Library/Application Support/Halo/diagnostics/latest.md`: the summary. Its first section says what is missing and
  what would fill it; follow it rather than guessing why something is empty.
- `~/Library/Application Support/Halo/diagnostics/latest.json`: everything (`schemaVersion` 1). Times are local with
  their offset. Field guide: [export.md](export.md).

When the command cannot run outside the sandbox, or Halo runs but does not answer, ask the person to click **Copy**
beside **Diagnostics Summary** on Halo's Diagnostics page and paste it.

## Measure first, then export

Each runs only when asked, stops by itself, and returns when the export is written. One at a time; "Halo did not do
it: …" says why.

- `--diagnostics --link-check`: one connection check to the paired Mac (ping, TCP to its Halo port, TCP to the
  router). Needs nobody.
- `--diagnostics --audio-check`: a 30-second check of the music link to a Bluetooth speaker or headphones. **First**
  ask the person to play music to it; with nothing playing Halo refuses at once.
- `--diagnostics --record [seconds]`: records scrolls for 5 to 120 s (default 30). **First** tell the person to scroll
  the device in question during that time; the output only arrives at the end. Recording turns off afterwards.

## Change a setting

Change only what the person asked for or agreed to. Take the ID from a fresh live export on the Mac where you will
run the command (`devices[].id` or `audioDevices[].id`). If the name is ambiguous, confirm which device or Mac they
mean. IDs for devices without a serial can change on reconnect. When **Sync Scrolling Settings** is on, reverse and
speed changes can also apply on the paired Mac. Halo shows a notification naming the change and prints
`Changed: <before> → <after>`; a value already in place prints `Unchanged: … (already so)`, changes nothing and shows
no notification. This confirms the rule was applied. A scroll test can verify its effect.

- `--set reverse <device id> on|off`: reverse scrolling for one pointing device, relative to macOS natural scrolling.
- `--set speed <device id> 0.5|1|1.5|2|3|4`: a mouse's wheel speed; trackpads have none.
- `--set speaker-mic <audio device id> on|off`: keep the system microphone off a Bluetooth speaker (on) or allow it
  (off).

## What happened earlier

```bash
halo --events --since 15:00
```

Reads Halo's event log (30 days, one JSON Lines file per day in `~/Library/Application Support/Halo/events/`). It
works whether or not Halo runs, needs no sandbox exception and changes nothing. The default window is the last 24
hours, up to `--until` or now. `--since` / `--until` take `15:00` (the last such time, so possibly yesterday), `90m`,
`2h`, `3d`, `today`, `yesterday`, `2026-11-04`, `"2026-11-04 15:00"` or ISO 8601; a bare day starts `--since` and ends
`--until`. `--kind battery,link` narrows it; `--json` prints the stored lines. Use it when the person asks about
something that already happened (a disconnect, a battery that drained, a setting that changed by itself) instead of
asking them to reproduce it.

To follow events while the person reproduces a problem: `halo --watch --for 120` (always pass `--for`, 1 to 86400
seconds; `--kind` and `--json` work here too; `--since 10m` first prints what was already logged). It waits on
file-system notifications and does not poll.

What each line means: [events.md](events.md).

## Removing Halo

`halo --uninstall` prints everything Halo has put on this Mac and removes nothing; it works without the app running.
To remove Halo, show the person that list and point them to **Settings → General → Uninstall Halo…**: it confirms
with them, unpairs (telling the other Mac if it is connected), then moves the files and the app to the Trash. Never delete Halo's files
or keychain items yourself. If Halo came from Homebrew, `brew uninstall --cask halo` afterwards removes the app.

## Rules

- Report what Halo measured. When something was not measured, say so instead of inferring it; a gap between `sleep`
  and `wake`, or `quit` and `launched`, means Halo saw nothing then.
- Talk about devices by `displayName`, the name the person sees in Halo.
- Before calling a reversed device faulty, check `state` (`listening`, `reversing`) and `directionCheck`: another
  program may be changing the direction back.
- The export and the log hold no keystrokes, screen content, sound, clipboard contents, pairing digits, serial numbers
  or Bluetooth addresses; Bluetooth devices appear by name and a short hash.
