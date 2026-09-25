# Paceman themes: design study and build map

Status: six-family dark-only picker implemented in the iPhone app. The selected theme
belongs to the phone. The user has confirmed that theme changes appear on the
physical custom watch and a visible Live Activity. A full per-family pass and
the suspended remote-start path remain separate acceptance checks.

## What the references teach

Xcode and VS Code make theme choice a persistent user preference, with light,
dark, and higher-contrast treatments. Omarchy projects a palette across many
programs. Developer themes build an identity from several colors with distinct
roles: Sakura Mochi combines hot pink and cool green; Retro 82 combines navy,
amber, and teal; Osaka Jade uses several greens with warm highlights; Miasma
combines moss, rust, and gold; Batman is a focused yellow-on-graphite scheme.

- [Xcode themes](https://developer.apple.com/tutorials/develop-in-swift/hello-swiftui),
  [VS Code themes](https://code.visualstudio.com/docs/configure/themes), and
  [Omarchy's palette system](https://learn.omacom.io/books/2/pages/92)
- [Sakura Mochi](https://github.com/OldJobobo/omarchy-sakura-mochi-theme),
  [Retro 82](https://github.com/OldJobobo/omarchy-retro-82-theme),
  [Osaka Jade](https://github.com/Justikun/omarchy-osaka-jade-theme),
  [Miasma](https://github.com/OldJobobo/omarchy-miasma-theme), and
  [Batman](https://github.com/OldJobobo/omarchy-batman-theme)

The named palettes are adapted to Paceman's phone, watch, and Live Activity
roles. Paceman ownership means the **phone owns selection and mapping**; it
does not require Paceman to invent every palette. An info button beside the
picker title links to each source, and the app bundle includes their license
notices. Wallpapers, icons,
and desktop configuration files are not part of the iPhone themes.

| Reference | Provenance and use for Paceman |
| --- | --- |
| [Miasma](https://github.com/OldJobobo/omarchy-miasma-theme) | A port of [xero's original Neovim palette](https://github.com/xero/miasma.nvim), released CC0. Strong candidate for a named, attributed palette port. Its dark character can remain dark in the app. Map canonical colors to Paceman roles and check contrast; do not transplant terminal ANSI roles directly into UI. |
| [Sakura Mochi](https://github.com/OldJobobo/omarchy-sakura-mochi-theme) | OldJobobo's pink/green Omarchy scheme, with an MIT license. A distinct expressive option worth testing as an attributed dark phone/watch theme. Review the license notice before incorporating exact values. |
| [Osaka Jade](https://github.com/Justikun/omarchy-osaka-jade-theme) | Justikun's green Omarchy theme, with an MIT license. Attractive, but compare full surfaces with Paceman and Miasma to ensure it earns a separate row. |
| [Retro 82](https://github.com/OldJobobo/omarchy-retro-82-theme) | OldJobobo's navy/amber/teal theme; its README credits @niraletter for palette inspiration and feedback. No license was visible in the repository review. Ayu now fills the blue/amber slot with its own established palette and clear reuse terms. |
| [Batman](https://github.com/OldJobobo/omarchy-batman-theme) | An Omarchy adaptation of FredHappyface's Tinted Theming Base24 Batman scheme. Its strong yellow/graphite pairing is useful reference, but the Batman name and scheme provenance make it a weak choice for a Paceman launch row. |
| [Catppuccin](https://github.com/catppuccin/catppuccin) | A mature, MIT-licensed palette with Latte for light and several dark flavors. A named port can use its own light/dark system instead of inventing a counterpart. Follow its [role guidance](https://github.com/catppuccin/catppuccin/blob/main/docs/style-guide.md) when adapting it. |
| [Rosé Pine](https://github.com/rose-pine/rose-pine-palette) | Another MIT-licensed established palette with Dawn light and Main/Moon dark variants. A strong alternate to Catppuccin if it feels more distinct beside Sakura Mochi. |
| [Ayu](https://github.com/ayu-theme/ayu-colors) | An MIT-licensed developer palette with Light, Mirage, and Dark variants. Light/Mirage pair a near-white UI with a deep blue-gray and amber accent, covering the warm-on-cool direction without making an uncredited lookalike of Retro 82. |

## Dark themes on the phone

Theme selection chooses a **family**. Every offered phone appearance uses its
dark palette, including when iPhone system appearance is light. The picker order
is Paceman, Ayu, Catppuccin, Miasma, Sakura Mochi, then Monochrome. The phone
choice is global across paired computers. Existing light palette tokens remain
in the catalog but have no user-facing picker option.

The custom AMOLED watch and Lock Screen Live Activity use the selected family's
dark glance palette in both iOS appearances. The Dynamic Island remains system
black and uses that family's light-on-black colors. This follows
[Apple's Live Activity guidance](https://developer.apple.com/design/human-interface-guidelines/live-activities)
on its opaque Island background and reduced-luminance legibility. The family
identity travels through its background, foreground, and primary accent on
the watch. The current watch face gives weather details the foreground color;
it does not have an independent weather color. The app and Live Activity may
use additional palette colors for their existing roles, but should not add
accents solely to decorate an element. SF remains the app/Live Activity
typeface; the watch keeps its JetBrains Mono face and established layout.

## Catalog and order

The picker offers **six families** in the order above. Paceman uses the app's
existing brand colors; Monochrome is a deliberate grayscale utility.
Neither claims a novel color scheme. The other
four use established palettes with visible credit and license notices. Ayu
replaces the Signal sketch, which followed Retro 82's navy/amber/teal idea too
closely to justify a separate invented identity. Pulse likewise yields to
Sakura Mochi. This gives the picker familiar green, pure neutral, blue/amber,
vivid pink, earthy olive, and pastel violet identities.

The phone uses Ayu Dark, Catppuccin Mocha, and the dark variants of Paceman and
Monochrome. Sakura Mochi and Miasma remain dark. The watch and Live Activity
always use the dark glance treatment. For named ports, preserve canonical base, text, and accent
colors where they remain legible. When a source accent fails contrast as small
Apple UI text, choose another source color or adjust its luminance and label
that role as adapted.

Rosé Pine and Osaka Jade are the strongest candidates for a seventh or eighth
row if full-surface comparison shows they are meaningfully different from
Sakura Mochi/Catppuccin and Paceman/Miasma respectively. There is no technical
four- or six-theme limit.

Each row needs a palette specification for phone, custom watch, Lock Screen,
and Dynamic Island; a provenance/license record; accessible dark roles;
and connected, empty, needs-input, stale, and multiple-computer
previews. Eight is reasonable if the additional two survive that same review.
The picker itself stays simple: one name and three signature colors per family.
The themed Appearance screen is the live phone preview.

The initial visual comparison was a palette study. These are the core colors
implemented from that review. Each watch tuple is
background / foreground / accent. Extra phone and Live Activity role colors
remain within each family; the watch has no fourth color.

| Family | Phone light: background / surface / ink / accent | Phone dark: background / surface / ink / accent | Watch: background / ink / accent |
| --- | --- | --- | --- |
| **Paceman** | `#F5F4F0` / `#EAEDE7` / `#242823` / `#456554` | `#151C18` / `#202A23` / `#E9EDE7` / `#A8D2B6` | `#0A100C` / `#E9EDE7` / `#A8D2B6` |
| **Ayu** | `#F8F9FA` / `#EBEEF0` / `#5C6166` / `#8A5700` | `#1F2430` / `#282E3B` / `#CCCAC2` / `#FFCC66` | `#181C26` / `#CCCAC2` / `#FFCC66` |
| **Catppuccin** | `#EFF1F5` / `#E6E9EF` / `#4C4F69` / `#8839EF` | `#1E1E2E` / `#313244` / `#CDD6F4` / `#CBA6F7` | `#11111B` / `#CDD6F4` / `#CBA6F7` |
| **Miasma** | Dark only | `#222222` / `#242D1D` / `#C2C2B0` / `#D7C483` | `#222222` / `#C2C2B0` / `#D7C483` |
| **Sakura Mochi** | Dark only | `#0B0D11` / `#201620` / `#F0B7CA` / `#FC0594` | `#0B0D11` / `#F0B7CA` / `#FC0594` |
| **Monochrome** | `#F4F4F4` / `#E6E6E6` / `#191919` / `#191919` | `#111111` / `#222222` / `#F1F1F1` / `#F1F1F1` | `#050505` / `#F1F1F1` / `#F1F1F1` |

The app icon uses Paceman's dark background and mint accent across platforms.

Ayu's light accent is darkened from its canonical orange for legible small
controls on near-white; it remains an explicitly adapted Ayu port. Miasma uses
its canonical gold as the watch accent because the darker olive accent is less
legible at glance size. Sakura Mochi's phone surface and vivid pink accent are
adapted. This is not a byte-for-byte port. Bundled notices are in
`ios/Resources/ThemeLicenses.txt`.

Color roles across surfaces:

| Role | Phone | Live Activity | Custom watch |
| --- | --- | --- | --- |
| Canvas and surface | Family background and panel | Dark glance background; system black in the Island | Dark glance background |
| Primary ink | Brand wordmark, names, titles, finished/idle headlines, and ordinary content | Computer name, finished/idle headline, and ordinary content | Date, weather, allowance text, and supporting status |
| Secondary ink | Receipt times, supporting labels, and historical rows | Session counts, elapsed time, and supporting labels | Rules and supporting information |
| Family accent | Brand mark, selected controls, fresh agent robots, and working/needs-input headlines | Fresh working/needs-input robot and headline | Clock, active agent robot, and allowance rim |
| State colors | State is spelled out; needs-input label receives accent emphasis | Small per-state session lights and input count in the compact Island | State is carried by robot form and words; no separate state hues |
| Inactive or stale | Neutral connection cues and muted last-known activity | Muted stale content; softer finished robot; neutral finished headline and idle robot | Ordinary battery remains ink; low/charging battery receives accent |

The accent identifies the active focal point, not a universal success or error
signal. A full accent headline is legible against every launch family's dark
glance background and the Island's black; finished content recedes. Long text
and metadata stay in ink. Phone small labels use the palette's computed
secondary ink rather than a fixed ink opacity, so they remain legible on both
the canvas and card surface. Small session lights retain their separate state
colors and accompany written counts. Monochrome carries state through words,
robot forms, weight, and position, with grayscale intensity only. The phone
and Live Activity must never require hue recognition. Actual display,
reduced-luminance, increased-contrast, and color-vision checks remain necessary.
[WCAG text contrast](https://www.w3.org/WAI/WCAG21/Understanding/contrast-minimum)
is a numeric starting point.

## Interaction

Appearance in iPhone Settings has one row per **family** with its name and
three signature color swatches. The first is the dark phone accent;
the other two show distinct colors from the watch and Live Activity
palette. The screen itself renders in the selected phone theme. The selected
row has a checkmark. Source links
sit behind one info button in the navigation bar. Selecting a family persists
its stable ID. The phone owns the choice even
when a computer is disconnected, removed, or added. Following an Omarchy
computer remains a later explicit mode.

## Build map

1. Define an immutable family catalog and per-appearance role tokens in
   `ios/Shared/`, separate from the source `appearance` DTO. Persist the family
   ID in phone preferences. Resolve the dark phone palette at rendering time
   and prefer the dark system appearance in `AgentCompanionApp.swift`.
   Unknown IDs fall back to Paceman.
2. Add the Settings picker and adapt the app's existing components without
   changing its screen hierarchy. Audit current uses of `theme.tint` and
   opacity-based secondary text, especially status displays, card surfaces,
   long names, and accessibility sizes. Review connected, empty, stale, and
   multiple-computer states in the dark phone appearance.
3. Make `CompanionModel` and `WatchLink` forward the selected glance palette
   independently of source activity. The current v2–v5 watch profile already
   carries background, foreground, and one accent. Map each selected family
   to those three values; no watch protocol change is needed for launch.
   Weather remains foreground, and clock/agent use accent according to the
   current watch face. Confirm the colored watch face on physical hardware;
   BLE acceptance is a separate check.
4. Share the family ID with the WidgetKit extension through an App Group. The
   extension renders local and remotely started Live Activities with the dark
   glance palette. Keep source activity state and `service/push.py` payloads
   independent of theme. Test how already visible activities repaint after a
   selection change, and preserve the latest activity state if a local
   ActivityKit update is needed. Verify remote start and update while the app
   is suspended. [Apple's shared data guidance](https://developer.apple.com/documentation/widgetkit/developing-a-widgetkit-strategy)
   and [ActivityKit push contract](https://developer.apple.com/documentation/ActivityKit/starting-and-updating-live-activities-with-activitykit-push-notifications)
   support this split.
5. Revise the four source-owned docs named above. Test dark resolution under both iPhone system appearances,
   preference fallback, multi-computer independence, BLE color packets, and
   widget rendering. Review full affected phone screens plus the custom watch,
   Lock Screen, and Island for every family and activity state. Use simulator
   comparisons for iteration, then the physical watch and remotely started
   iPhone Live Activity for acceptance.

## Implementation review (24 September 2026)

The phone persists one family ID in App Group preferences. Both the app and
WidgetKit extension resolve that ID through the same catalog. The watch profile
receives the selected dark glance colors even when no source snapshot is
available; watch v2 carries background and foreground, and v3+ adds accent.
Source appearance remains decodable but does not drive any surface. Selecting a
new family refreshes active Live Activities with their current state preserved.

Initial simulator review covered the picker in light Ayu and dark Sakura Mochi,
including Sakura Mochi while the system appearance remained light, then
connected grouped activity in dark Paceman, no active sessions in dark
Monochrome, stale/disconnected activity in dark Miasma, two computers with long
text in dark Catppuccin, and two computers with long text in light Ayu. The
picker was also checked at Accessibility Large text size. The Ayu watch-detail
illustration and Sakura Mochi Live Activities detail were reviewed. The app and widget
build for a signed iPhone target, and the signed simulator test suite passes.

The picker was then simplified to names, three signature colors, a selection
checkmark, and an info button for
source links. The revised screen was reviewed in light Ayu, dark Ayu,
Sakura Mochi with light system appearance, and Accessibility Large. The
credits sheet was reviewed in dark Sakura Mochi. The
connected, empty, stale, and multiple-computer screens listed above were
unchanged by this picker refinement. The revised app was
installed and launched on the paired iPhone.

After comparing the full set of physical phone screenshots, the picker now
offers only dark appearances in this order: Paceman, Ayu, Catppuccin, Miasma,
Sakura Mochi, Monochrome. A simulator set to system Light showed the dark picker
and grouped Ayu activity; the signed iPhone build passed and was installed.

The user confirmed on 24 September that selected themes adapt on the physical
custom watch and visible Live Activity. This confirms the normal propagation
path. Still to check separately: all six families on watch hardware, and a
remotely started Live Activity repainting after a selection change while the
app is suspended.
