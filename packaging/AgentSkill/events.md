# Halo's event log

Each line has `t` (local time with offset), `kind`, usually `event`, and fields that depend on the kind. `device` is
the name Halo shows. On `device`, `setting` and `tool` lines, a device `id` identifies the device at the time of
the event. For `--set`, get the current ID from a fresh live export on that Mac. On `battery` lines the ID identifies
the battery's readings.

- `app`: `launched` (`text` is the version), `quit`, `sleep`, `wake`, `reversing`, `paused` (`detail` says why),
  `truncated` (that day's file hit its size cap), `state-unreadable` (a settings file could not be read; `detail` names
  it and whether it was kept aside or left in place; its settings are at their defaults until it is fixed, unless
  `detail` says the ID and pairing were salvaged) and `battery notifications unavailable` (the system's battery
  announcements could not be watched; batteries are then read only at launch, on wake, when a device comes or goes,
  and when the menu opens).
- `device`: `present` (at launch), `connected`, `disconnected`, `lent` and `returned` (a device the other Mac lends
  through Universal Control; it stays lent across many crossings, so these are not crossing times). A departure is
  logged only once the device has been missing for a minute, so a mouse reconnecting after wake is not a disconnect;
  the line is dated when it went missing and written a minute or two later.
- `battery`: `reading` (first this run; for a speaker or headphones also after each reconnect) and `changed` (`from`
  is the previous percent), with `percent`, `charging` and `source` (`registry`, `ble` or `bluetoothd`).
- `setting`: `reverse`, `speed`, `speaker-mic`, `match-settings`, `clipboard`, with `from`, `to` and `by` (`person`,
  `agent`, `other Mac`, `pairing`).
- `tool`: `present`, `started`, `stopped` (another program's scroll tap; `detail` says whether it can modify
  scrolling), `blocked` (`text` names the possible program or programs when a reversed device's direction was
  changed back) and `unblocked`.
- `handoff`: the pointer crossing between the Macs through Universal Control, logged when Halo receives the
  notification macOS posts. How close that time is to the crossing itself has not been measured, and whether the
  other Mac logs a line for the same crossing has not been established, so don't assume a matching one. They say
  nothing about whether the pointer moved smoothly.
  - `left` (this Mac's pointer went to the other Mac) and `arrived` (it came back).
  - `drop-told`: every device the other Mac lends this one left and none came back within 1.5 seconds (this also
    happens each time the pointer goes home); `lent-again`: one came back after that. A pointer bouncing at the screen
    edge logs neither.
  - `stalled`: the other Mac dropped every device this Mac lends it while this Mac's input was over there, and two
    seconds later the input was still routed away: nothing typed or moved here did anything. Then `recovered`
    (`detail` "N s", at least that long) or `cleared` (`detail` says why: the link went away, or no return after 10
    minutes). The other Mac logs `peer-stalled`, then `peer-recovered` or `peer-cleared`, for the same stall.
    `peer-recovered` carries this Mac's seconds when this Mac's word that its input came back arrives first; when the
    other Mac ends it itself (its own pointer crossing, or this Mac's devices lent again) it is timed there from when
    it heard of the stall, about two seconds short of this Mac's count. Halo sees only the
    drop, not its cause, so don't name one. Both Macs show a small notice under Halo's menu-bar icon while it lasts.
- `link`, `clipboard`: what Halo logged about the connection to the other Mac or the clipboard (sizes and types, never
  contents).
- `audio`: a speaker or headphones event, in the app's language.
