# Security

## Reporting a vulnerability

Please report security problems privately through GitHub: on this repository's **Security** tab, choose **Report a
vulnerability**. Do not open a public issue for them. Include the Halo version (About page), the macOS version, and
what an attacker needs (same network, local account, physical access).

Only the latest release is supported. Fixes ship as a new release through the in-app updater and Homebrew.

## What Halo can do on your Mac

- **Accessibility.** Halo needs Accessibility permission to install an event tap on scroll events, which is how it
  reverses scrolling per device. The tap sees scroll events only, never key presses. While an agent records
  (`--diagnostics --record`), the last 512 scroll events are kept in memory for the diagnostics export.
- **Bluetooth.** Halo reads battery levels through the standard Battery Service of devices that are already
  connected. It does not pair or connect to anything new.
- **Local network.** Only after you pair with another Mac (see below).
- **System log.** Halo runs `/usr/bin/log`, filtered to Universal Control and Bluetooth (`bluetoothd`) messages, to
  notice Universal Control handoffs and to read speaker batteries and call-mode switches while audio plays. Only the
  facts it parses are kept; see "What is written to disk".
- **Updates.** Sparkle checks `https://halo.liuzhekan.com/appcast.xml` once a day if you agreed when asked (it asks
  on the second launch), otherwise only when you choose **Check for Updates…**. An update is installed only if it is
  signed with Halo's own update key (`SUPublicEDKey` in `Info.plist`); Gatekeeper's Developer ID check is not relied
  on for that, since anyone can notarize a replacement under their own Developer ID.
- **Agents.** `halo --diagnostics` and `halo --set …` reach the running app through a macOS distributed
  notification, so any process running as your user can ask for a diagnostics export or change a device's reverse
  setting, scroll speed or a speaker's microphone rule. That is the same trust as anything else running as you; Halo
  shows a notification for each change (if notifications are allowed) and records it in the event log with
  `by: agent`.

Nothing is sent anywhere except to the Mac you paired with and to the update feed.

## Pairing two Macs

Pairing uses numeric comparison, as Bluetooth does. Both Macs commit to a one-time X25519 public key before seeing
the other's, then show the same six digits derived from both halves; you confirm on both. Each Mac reveals its half
once per attempt, so someone in the middle cannot try many keys to find a matching code: the chance that the digits
match by accident is one in a million per attempt. Pairing is only as good as that comparison: if the digits differ,
choose **Don't Match**. The 32-byte long-term key is derived from the one-time keys, bound to both Macs' IDs, stored
in the login keychain (service `Halo`) and never sent over the network.

## The link between paired Macs

- **Encryption.** TLS 1.2 keyed with the pairing key, using `TLS_ECDHE_PSK_WITH_CHACHA20_POLY1305_SHA256`: every
  connection also runs an ephemeral key exchange, so traffic recorded today stays unreadable even if the pairing key
  leaks later (forward secrecy). macOS still accepts plain PSK when the other end offers only that, so
  Halo checks the negotiated suite once connected and drops any connection without forward secrecy.
- **What travels.** The computer name, whether Halo is reversing, the menu's devices (name, kind, battery level),
  each device's settings (name, reverse, speed; applied by the other Mac only while **Sync Scrolling Settings** is
  on), link-check results, and, with **Share Clipboard** on, clipboard contents (below). Serial numbers and
  Bluetooth addresses are not sent.
- **The two switches are shared.** **Sync Scrolling Settings** and **Share Clipboard** are ticked when you pair, and
  whichever Mac changed one last wins: turning one on or off on either Mac turns it on or off on both.
- **What the other Mac can do.** Show your devices; with **Sync Scrolling Settings** on, change this Mac's reverse
  and speed settings; with **Share Clipboard** on, read this Mac's current clipboard whenever it asks (below) and
  replace it. Pair only with a Mac you control.
- **Discovery is not authenticated.** Halo advertises a Bonjour service (`_halo._tcp`) whose TXT record carries a
  random Halo ID, the host name and the port. Anyone on the same network can see it, and can advertise a fake one
  with your other Mac's ID. Halo would try to connect there, fail the TLS handshake (no key), and the link would not
  come up: a way to disrupt it, not to read or change anything. Link checks may then probe the wrong address (a ping
  and two TCP connects, no data). Halo does not advertise or browse until you pair.

## Clipboard sharing

On unless you untick it when pairing, and shared between the two Macs (above). When the pointer moves to the other
Mac through Universal Control, Halo sends what you copied during this visit: plain text, RTF, HTML and images, up to
16 MB. The other Mac can also ask for this Mac's current clipboard at any time (its menu has a button for it),
whatever was copied and when, concealed passwords included; Halo answers unless this Mac's screen is locked. Items
that apps mark as transient, auto-generated or relayed from another device (the nspasteboard.org markers) are never
sent. Items a password manager marks as concealed **are** sent, because you may mean to paste that password on the
other Mac; the other Mac keeps the concealed marker, shows only "Password · Hidden" in its menu, and clears its
clipboard after 90 seconds (or at sleep or lock) if nothing replaced it. A password copied from an ordinary app
carries no marker and is treated as text. Received contents stay in memory only and are written to the clipboard as
current-host-only (so Universal Clipboard does not pass them on). At sleep, lock, when sharing is turned off or when
you unpair, Halo drops everything it holds from the other Mac (received, waiting or half-arrived contents), and
clears a concealed password it wrote if the clipboard still holds it. Text or an image it already wrote to the
clipboard stays there, like anything else you copied, until something replaces it. Logs record only types and sizes.

## What is written to disk

`~/Library/Application Support/Halo/`: settings and per-device rules, the event log (one file a day, kept 30 days;
no scroll events, clipboard contents, key presses, pairing digits, serial numbers or Bluetooth addresses; devices
appear under the same keyed IDs as in the export), and the latest diagnostics export. Device IDs in the export are
an HMAC of the device identity with a random key kept on this Mac, so exports from different Macs cannot be linked
by device. The pairing key is in the keychain.

## Known limits

- Halo uses private HID event functions to read which device sent a scroll; they are looked up at launch and Halo
  does not process events if they are missing. A macOS update can change them.
- The clipboard trigger uses an undocumented Universal Control notification.
- The first release supports macOS 26 or later on Apple silicon. Automated tests run on macOS 26. Two-Mac
  Universal Control has been tested on macOS 27.2.
