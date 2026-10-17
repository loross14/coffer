# Planisphere for Mac workspace

## Purpose and grounding

Logan's October 10, 2026 request is to upscale the Mac app using the best of Obsidian and Wispr. The audience is a person working with ordinary local Markdown vaults: get to a vault or note quickly, inspect saved versions clearly, and review pruning without losing context.

The founder's `notes/design/I'm bringing Figma back.md` calls for growth through subtraction, progressive disclosure and spatial consistency. The August brand work order and September console studies are historical context, not a settled Mac specification. This native implementation is the Mac design study; it does not change the website, console or shared Figma library.

Reference principles were checked against [Obsidian's workspace](https://obsidian.md/help/workspace), [collapsible sidebars](https://obsidian.md/help/User%2Binterface/Sidebar), [Wispr's interaction design](https://wisprflow.ai/post/designing-a-natural-and-useful-voice-interface), and [Flow's small contextual bar](https://docs.wisprflow.ai/articles/1790396454-move-and-dock-the-flow-bar-on-desktop). The implementation takes fast access and spatial control from the former and quiet contextual controls from the latter. It does not add dictation, copy branding, or claim measured superiority.

## Structure

- A 216-point vault sidebar holds the three workspaces, vault selection and a small local-storage disclosure. It collapses using its button or ⌘\\.
- A 54-point breadcrumb header carries vault/view selection and a small actions menu. Checkpoint creation is prominent in History; scope and naming remain in a review sheet.
- The graph has floating search and controls. Details open for a selected note or search and can genuinely close without losing that context. Advanced physics controls are disclosed in a popover.
- History separates saved moments, changed-file search and a wrapped Before/After reader. Capture mode and exclusion meaning remain visible so absence from a saved snapshot is not confused with deletion of working files.
- Pruning presents a brief first-use explanation, then candidate discovery, keeper selection and exact review. Existing preservation holds and local/signed policy distinctions remain intact.
- ⌘K opens an in-window launcher. Search, arrows, Return and Escape work from the keyboard. Actions reuse the existing workflows; it never directly executes pruning. Vault paths disambiguate identical names. The underlying workspace leaves the focus/accessibility tree while the launcher is open.

## Visual system and review

`PlanisphereStyle.swift` defines adaptive graphite, warm white, cobalt, borders and shared controls. Native system typography, consistent spacing, quiet selected states and restrained rounded surfaces serve reading. Color is not the only selection/status cue. Buttons have accessible labels; reduced motion suppresses inspector transitions and retains the graph's existing pause behavior.

The primary rejection risk was making the app prettier while hiding consequences or breaking keyboard state. Independent source review restored visible capture scope, checked modal navigation guards and disambiguated vault paths. Native checks caught and repaired launcher focus timing. Simulation, local history format, Grapheine protocols and managed boundary remain unchanged. The native renderer adopts the shared palette and respects modal focus. Layout and sidebar visibility are session state, not synced preferences.

See [the acceptance record](ACCEPTANCE-2026-10-10.md) for actual test coverage and packaging limits.
