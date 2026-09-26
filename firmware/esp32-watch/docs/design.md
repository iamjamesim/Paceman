# Watch-face design

> Upstream device reference from Omarchy Watch v0.6.1. Desktop behavior described
> here belongs to the standalone project; see the root architecture and validation
> docs for what Paceman currently forwards.

## Product boundary

The watch inherits context from Omarchy without mirroring the desktop UI.
The desktop companion resolves settings and sends the watch an effective,
versioned profile. The watch stores the latest profile and remains useful when
the desktop is unavailable.

Settings that can be derived from the desktop follow it by default. A future
desktop settings surface can override each one independently. This includes the
theme, timezone, weather location, units, hour cycle, and locale. Hardware- and
face-specific settings are still configured from the desktop, even though they
belong semantically to the watch.

The watch firmware does not need to evaluate preference rules. It receives
resolved values, caches them, and renders them.

## Plain 01

The first face is deliberately one state and one layout. Pairing, invalid-time,
and fatal-error screens are system states rather than face variants.

- 410 x 502 portrait canvas
- resolved Omarchy bar background and foreground, plus its theme accent
- JetBrains Mono throughout
- compact date and battery rail
- time is the dominant element
- two horizontal rules divide time, weather, and the footer
- weather uses a two-column composition: icon/temperature and condition/range
- v4 and later profiles show Codex remaining allowance and reset time in the footer;
  older profiles show the forecast location
- battery level, charging state, weather, and allowance are live on hardware
- the clock is the dominant accent focal point; the battery uses accent while
  charging or at 20% or less; the agent robot in the top rail uses the face
  accent for routine states and alert colors when attention is needed
- tapping the battery temporarily replaces its glyph with the exact percentage
- weather and reset text use foreground; allowance text uses accent at 20% or less
- the allowance rim shows remaining capacity in accent over a 40% opacity track
- no controls, cards, vertical dividers, or decorative chrome
- no image background; the face model may gain an optional background later

The deterministic preview fixture is `Tue 8 Sep`, `05:59 PM`, a charging
battery, and partly cloudy at `68°` with `H 72°`, `L 61°`, and `SAN FRANCISCO`.
Fixed fixture data makes pixel comparisons useful.

Layout coordinates and font sizes are native display pixels; LVGL does not
apply CSS points, DPI scaling, or a physical-millimeter conversion. Nominal
font size selects the font's em square, while the visible glyph bounds are
usually smaller. Positions are therefore tuned from rendered glyph bounds and
the physical AMOLED, with a 28 px safe inline gutter.

## Content-fit contract

Layout safety comes from bounded content and measured fallback tiers, not from
making the default typography unnecessarily small.

- The clock uses tabular, monospaced digits. Its primary form is `HH:MM`. A
  fixed-width suffix slot is always reserved at the right: 12-hour mode shows
  `AM` or `PM`, while 24-hour mode makes it invisible without collapsing it.
  The main clock therefore never moves when the preference changes.
- The date formatter currently emits the bounded English form `Tue 8 Sep`.
  Locale-aware fallback tiers are future work.
- Weather shows one fixed-size glyph and a rounded integer temperature. The
  accepted display range is `-99°` through `199°`; invalid or unavailable data
  becomes `--°`.
- Battery state uses ten discrete fill glyphs. Charging adds a separate bolt so
  the battery body continues to communicate level.
- The location label has a fixed width and truncates rather than entering the
  rounded display corners.
- Future locale and weather support will use approved font-size tiers. Firmware
  will measure rendered text and select the largest tier that fits rather than
  scaling continuously.
- Before those inputs become live, design fixtures must cover the widest
  digits, negative and three-digit weather, both hour cycles, and the longest
  supported localized date tokens.

The LVGL face uses the preferred English tier. Its input is deliberately
bounded until the fallback tiers are implemented.

## Preview contract

`firmware/main/watch_face_layout.c` and `watch_allowance_layout.c` are shared by
the firmware and `simulator/render_watchface.c`, with the same generated fonts and
LVGL 9.5 dependency. The simulator renders a deterministic 410 x 502 RGB565
frame, then the preview tool exports square and rounded PNGs.

This removes browser font metrics and CSS layout from firmware review. The
simulator is exact at the framebuffer level; the physical AMOLED remains the
authority for perceived weight, contrast, corner safety, and on-wrist scale.
The browser prototype is retained only as early design history.

## Theme mapping

The prototype uses the resolved Solitude palette as its initial fixture:

| Face role | Omarchy token | Value |
| --- | --- | --- |
| Canvas | `bar.background` (fallback: `background`) | `#101315` |
| Supporting content | `bar.text` (fallback: `foreground`) | `#cacccc` |
| Clock and routine agent status | `accent` | `#798186` |

These values remain the deterministic preview fixture. On hardware, the
desktop companion reads `background`, `foreground`, and `accent` from
Omarchy's resolved current theme and sends them in one coherent profile
update. `background` and `foreground` intentionally match the desktop bar;
Plain 01 does not substitute a darker watch-only surface. If accent does not
meet a 3:1 contrast ratio against the background, the desktop falls back to
foreground for legibility. An explicit watch-theme override remains future
work.

## Agent attention

Agent activity distinguishes working, needs input, failed, finished, and absent.
The face prioritizes input requests, then failed turns, then work and completed turns.
The Paceman face has open eyes while working, chevron eyes for input, and
rounded happy eyes when finished. Failed turns show an open-X face. Working
uses the theme accent, Finished uses that accent at 70% opacity, Needs input
uses amber, and Failed uses red. Alert shades deepen on light backgrounds.
The clock and Codex allowance stay in the theme accent. The robot pulses in opacity
while working, bounces for input, and sways when finished. Failed is still and
idle is hidden.
The timing and cross-surface rules are in the
[shared motion spec](../../../docs/agent-state-motion.md).
Animations run only while the screen is awake, and repeated snapshots do not
restart them. Input requests and failures use two equal notes; completion uses
a descending pair. The panel's shared Sound toggle controls these alerts. Fresh alerts wake the face
for five seconds, except on battery at 15% or less; that cutoff suppresses the
wake, not the sound or optional GPIO18 haptic pulse.
An alert still fires when an earlier completion remains unacknowledged;
retransmission and reconnect do not repeat it.
The normal display timeout remains independent of semantic attention.

Tapping the robot acknowledges every input/failure/completion revision currently represented
by the aggregate glyph. A new prompt implicitly acknowledges the previous
result in that session, and interruption or session end removes it. The design
does not infer acknowledgement from desktop window focus.

The phone sends the distinct Failed wire state only when the watch advertises
failure support. Earlier firmware receives its existing Finished presentation.
The simulator was checked in Working, Needs input, Failed, Finished, and idle,
including a connected face and light profile. The calmer routine-state palette
was reviewed on full Miasma and Ayu Light face previews, then flashed; boot and
phone reconnection were observed. On-wrist acceptance of this palette and alert
delivery remain to be checked.

## Data freshness

Weather and allowance preserve useful last-known readings. A neutral history
glyph marks cached values without moving the numbers. Tapping either section
shows the observation age for three seconds. See
[data-freshness.md](data-freshness.md) for exact cutoffs and recovery behavior.

## Evolution constraints

- The bridge must send a packet layout supported by the watch; older watches
  reject unknown layouts rather than ignoring appended fields.
- A profile update is a full, versioned snapshot rather than a chain of patches.
- Pending synchronization is derived from desired and acknowledged snapshot
  fingerprints, so restarts and overlapping changes cannot lose work.
- Missing optional content must degrade to a valid face, not an error screen.
- Background artwork is optional and must never be required for legibility.
- The shared LVGL preview catches framebuffer regressions; physical hardware is
  still the final authority for optical adjustments.
