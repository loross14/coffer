# Local graph view

The Graph workspace in Planisphere for Mac 0.6.0 visualizes explicit links between the selected vault's Markdown notes. Reading, navigation, layout, pinning and refresh do not edit vault files or require Git, a policy, an account or a network connection. The bundled read adapter uses the installed Python runtime described in [GRAPHEINE.md](GRAPHEINE.md).

## Reading and scope

The graph shares the bounded Markdown discovery inventory with pruning: supported literal Obsidian exclusions apply; hidden/dependency folders, special files, symbolic links and attachments are omitted. Source reads reject changed files and do not follow external targets. The adapter passes admitted text to a pure link parser; note bodies are not included in the graph response.

Node identity is the complete relative note path. Wikilinks use an exact path or unambiguous basename; Markdown destinations resolve relative to their source note. Code, YAML frontmatter and HTML comments do not create links. Reference-style Markdown is supported. Alias inference and arbitrary HTML navigation are not implemented. Unresolved, ambiguous and unsupported counts remain visible in Snapshot & scope rather than being turned into invented edges. Repeated links in one direction become one directed edge; degrees describe returned edges.

Discovery is bounded to 20,000 admitted notes and 256 MiB. The graph returns at most 10,000 nodes and 100,000 directed edges, with omitted totals disclosed. Link-occurrence limits prevent excessively dense inputs from running unbounded. Counts are tied to the admitted snapshot, not a claim to index every file on disk. The floating search card reports visible notes and links when the neighborhood or unlinked-note filter is active.

Refresh takes a new snapshot. Surviving paths retain their positions and pins in the current view; leaving the view or switching vault starts a new view session. Background reads cancel on departure and stale results cannot replace the newly selected vault. Selecting a note reads its current text independently; refresh re-reads a selected preview. The graph is not an automatic filesystem watcher.

## Measurement

The inspector's Measure section and the dock's chart button run the pinned engine's `graph measure` on a private copy of the admitted Markdown (the same discovery scope and limits as the graph). The result is a `grapheine-measure-v1` document bound to the discovery fingerprint: notes and links, degree, density, components, orphans and unresolved links, the Fiedler value, communities and modularity, clustering and triangles, girth, bipartiteness, the most connected notes and balanced bridges. Heavy measurements are skipped above 5,000 notes and the panel says which. The engine's basis line is shown verbatim: these are heuristics about explicit links, not authority or truth. Measuring reads files only.

Links in the graph and in measurements resolve under the engine's single rule (`LINK_RULE`): exact vault-relative path when the destination contains `/`, source-relative for `./` and `../`, otherwise note basename or frontmatter alias, case-insensitive; duplicate basenames resolve to the same folder, then the shortest path, and are counted as ambiguous. Self-links are ignored. The adapter imports the engine's parser, so `grapheine health` on the same folder counts the same edges.

## Layout and interaction

The graph occupies the workspace below a compact vault header. Search and counts float at the top; Fit, Pause/Resume, Refresh, Settings and Snapshot scope sit in a small bottom dock. Settings contains neighborhood, unlinked notes, spacing, pins and Arrange Again. Selecting or searching opens the details panel; closing it preserves the selection and search until an explicit new interaction reopens it. **⌘F** focuses graph search. All controls have accessible labels and native tooltips.

`PlanisphereGraph` is a pure Swift simulation with no filesystem or rendering dependency. It uses deterministic component packing and optional folder groups for initial placement and weak positional attraction. Folder grouping is a visual aid, not evidence of semantic proximity. Springs are generated only from actual links. Unlinked notes share a compact island.

Barnes–Hut repulsion avoids an all-pairs force calculation. Degree-aware springs keep high-degree nodes from pulling everything into a single point. A spatial collision grid, fixed integration step, bounded displacement, damping and cooling keep movement finite and stop it when settled. Dragging holds the selected node exactly under the pointer and reheats nearby nodes. Pins survive a drag and explicit refresh. Arrange Again restores the deterministic starting layout and releases pins.

The AppKit canvas renders edges and notes directly, drawing a bounded set of labels and highlighting the selected neighborhood. Its timer runs only while the graph is visible, unpaused and unsettled; larger graphs use a lower update frequency. Pan, cursor-anchored scroll/pinch zoom and Fit change only the camera. Scroll deltas are bounded to prevent a single large wheel event from collapsing the view. The canvas clips to its own bounds.

Reduce Motion starts paused and enabling it during use pauses the view. Motion can be explicitly resumed. Search results and connected-note buttons expose exact paths to keyboard and accessibility users; the canvas also supports arrow-key panning, plus/minus zoom, zero to fit and Escape to clear selection. Layout and pin choices are temporary UI state, not vault metadata.

## Validation

Run `swift test --disable-sandbox` and `python3 -B scripts/test_graph_adapter.py`. Engine tests cover deterministic replay, finite values, bounds, collisions, dense/star graphs, pins, local drag reheating, component/folder separation and exact sleep. Adapter tests cover path resolution, duplicate stems, exclusions, links in code, malformed input, bounded output and unchanged source bytes. Service tests validate response identity, counts and endpoints and exercise cancellation of read-only subprocesses; signed writes retain their separate completion/recovery rules.

Native acceptance uses an isolated fixture and history root, checks search and exact-path selection, paused and pinned dragging, camera controls, refresh, clipping and the transition to At rest. The [acceptance record](ACCEPTANCE-2026-10-10.md) records the completed checks and candidate identity. Engine microbenchmarks are distinct from end-to-end rendering performance; no comparative performance claim about Obsidian is made.
