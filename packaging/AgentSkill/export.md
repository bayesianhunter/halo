# Halo's export (`latest.json`)

- `source`: `live` means the running app produced the file, possibly for an earlier request. `cold` means a limited
  export from the CLI. Use the command output and `app.exportedAt` to check freshness.
- `notes`: what is missing or empty, and what would fill it. Read it first.
- `request`: what produced this export (`export`, `button`, `record`, `link`, `audio`, `set`), when it started and
  ended, and its result. The summary's **This export:** line says the same.
- `state`: whether Halo has the Accessibility permission (`accessibility`), is `listening` and `reversing`, macOS's
  own `naturalScrolling` (every reverse rule is relative to it), and the two sharing switches (`matchSettings`,
  `clipboard`).
- `devices`: pointing devices by `displayName` (what the person sees) and system `name`, with the reverse rule for
  wheel and for continuous (trackpad-style) scrolling, wheel speed, and scrolls seen this run. `universalControl`
  marks a device Universal Control lends from another Mac.
- `scrolls`: recent scroll events at Halo's tap. `input` and `output` are the vertical point delta before and after
  Halo's processing. Other taps can still change the event downstream. `reversed` means Halo flipped it. The summary
  counts events per device. A scroll counted as "passed" can still have been scaled by the wheel-speed setting.
- `scrollTools` lists programs with enabled scroll event taps. `directionCheck` measures the direction at the two ends
  of the tap chain. `blockedDevice` identifies a reversed device whose direction was changed back. When `blockedBy`
  has several programs, they are candidates.
- `batteries` and `batteryForecasts`: charge per device, and how long each lasts at its rate since its last charge
  (`daysLeft`, `percentPerDay`, `since`, `readAt`). A forecast appears only after a day of readings and a drop of 3
  points since that charge, so say "not estimated yet" rather than guessing. A device that reports in coarse steps
  (every drop 10 points or more) never gets one.
- `page` (live only): the Devices page in the words and order it shows, so you can answer "what does it show?"
  without a screenshot. `rows` is this Mac's own devices (title, `facts`, battery, reverse switch `on`, `speed`) with
  `notes`; `universalControlRows` the devices Universal Control lends here that are not the paired Mac's; `pairCard`
  the "Another Mac Connected" card while Universal Control connects an unpaired Mac; then the paired Mac's
  `peerTitle`, `peerRows` and `peerNote`. A row with `lent` is a device lent here, carrying this Mac's switch, in its
  place in the lending Mac's list. Also `windowOpen`, `firstLaunch` and `pairing` (`idle`, `searching`, `comparing`,
  `confirmed`).
- `link`: the paired Mac, whether it is `online`, how the connection runs (`path`), the last check from each side
  (`verdict`; `noForwardSecrecy` means connections made with the pairing key settled for plain PSK and were refused,
  `handshake` means pair again) and recent link events.
- `audioDevices`, `audioEvents`, `audioCheck`: connected speakers and headphones, what happened to them (call mode,
  weak links with Wi‑Fi band and channel, microphone changes, connects), and the last audio check's per-second
  retransmission and drops. Drops are what is heard; retransmission alone is not.
- `events`: the newest 300 events of the last 24 hours, the same as `halo --events` (see [events.md](events.md)).
- Text Halo wrote for people (`statusText`, audio event `text`) is in the app's language.
