# Design guidelines

How VMPane's windows look and behave. A native Mac app first: system controls, system fonts, the materials macOS gives
us. Read this before adding a view; `Packages/VMPaneKit/Sources/VMPaneUI/Components.swift` holds the shared pieces.

## Tokens

| Token | Values | Use |
|---|---|---|
| Spacing | 4, 8, 12, 16, 24 pt | 4 inside a control, 8 between related items, 12-16 between groups, 24 between sections |
| Corner radius | 6 (badges, small controls), 12 (floating surfaces), 16 (cards, thumbnails) | always `.continuous` |
| Thumbnail | 16:10, 64 pt wide in lists, full width in the detail | scaled to fit, never cropped |

## Type

Semantic fonts only (`.body`, `.callout`, `.caption`, `.headline`, `.title2`...), so Dynamic Type and the user's text
size settings apply. Numbers that change (sizes, percentages, times) use `.monospacedDigit()`.

## Colour

State colours always come with text (VoiceOver and colour blindness):

| State | Colour | Text |
|---|---|---|
| Running | green | Running |
| Starting, stopping, paused, suspending | orange | the state's name |
| Suspended | blue | Suspended |
| Stopped | grey | Stopped |
| Error | red | Error, with the problem below |
| Agent acting | the accent tint | "<client> · acting" (`AgentBadge`) |

Warnings use `.orange` with an `exclamationmark` symbol; errors `.red` with the fix next to them (`ErrorExplainer`).

## Words

- Agent levels everywhere (app, CLI help, docs, site): **Off · Look only · Use the screen and keyboard · Run commands ·
  Full control** (`PolicyLevel.title`). Never Observe/Control/Administer in front of people.
- Say what happens, then the fix: "This Mac's disk is nearly full. Free some space, then try again." Not error codes.
- Buttons are verbs: Start, Shut Down, Take Over, Restore.

## Surfaces

- Windows and sheets: the system's backgrounds.
- Controls floating over a VM's screen or the library (the agent HUD, overlays): `vmGlass()` — Liquid Glass on macOS 26,
  `.regularMaterial` on macOS 15, an opaque window background with a separator stroke when Reduce Transparency or
  Increase Contrast is on.
- No custom chrome on top of the guest's picture beyond the HUD.

## Components

`OSBadge` (the guest OS as a symbol, labelled), `StateDot` (colour + word), `ByteSizeText`, `AgentBadge`,
`vmGlass()`. A new shared piece goes into `Components.swift` with a doc comment.

## Motion

Short, purposeful: state changes cross-fade (0.2 s); the agent edge tint pulses only while an agent acts. With Reduce
Motion, no pulses or slides: static tint, instant changes.

## Accessibility checklist

- Every row is one VoiceOver element that reads like a sentence ("Debian 13, running, Claude acting").
- Icon-only buttons have a label and `.help()`.
- Every action is in a menu with a keyboard shortcut; the library works with arrows, Return (Start / Show Window),
  ⌘I (inspector), ⌘⌫ (delete, confirmed).
- Check light and dark, Increase Contrast, Reduce Transparency, Reduce Motion, and the largest text size.
- macOS 15 (materials) and macOS 26 (glass): review both. This Mac runs macOS 15; review 26 in a macOS 26 VM in VMPane.
