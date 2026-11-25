# KeyframeSequence Importer (Studio plugin)

This local plugin imports this project's generated XML `KeyframeSequence` files
through Roblox Studio's `StudioService:PromptImportFilesAsync`, rather than the
3D asset importer. It reconstructs only the whitelisted `KeyframeSequence`,
`Keyframe`, and `Pose` XML elements. It never evaluates file text, overwrites an
existing Workspace object, or changes the source file. The selected sequence
gets an `ImportedForRig` attribute naming `Workspace.Rig`.

## Install in Studio

1. Open a temporary place in Studio so the production place is not changed.
2. Use **File > Import Roblox Model** and select
   `tools/KeyframeSequenceImporterPlugin.rbxmx`. The package contains one root
   `Script` named `KeyframeSequenceImporterPlugin`.
3. In Explorer, move that Script into `ServerStorage` and select it.
4. Use **Plugins > Save as Local Plugin**, then click **Save** in Studio's
   confirmation window. This installs the selected Script in Studio's local
   Plugins folder and starts the local plugin. The source Script is still in
   the temporary place; remove that staging copy after confirming installation.
5. Confirm that the **R6 Animations** toolbar section and its
   **ImportKeyframeSequence** button appear. Studio's plugin documentation says
   the saved plugin is also available through `PluginDebugService`.
6. In the Monster Eater place, confirm `Workspace.Rig` is an R6 Model with an
   R6 Humanoid.
7. Click **ImportKeyframeSequence** and choose one or more animation `.rbxmx`
   files. The plugin validates the selected sequences before inserting any of
   them, then reports each name, keyframe count, and duration in Output. If a
   sequence name already exists in `Workspace`, the batch is rejected rather
   than creating a duplicate.
8. In Explorer, right-click the imported `KeyframeSequence` and use Studio's
   **Save to Roblox** action to publish it. Select the experience owner in the
   asset dialog. The plugin itself does not publish or manufacture an asset ID.

## Boundaries

`KeyframeSequenceProvider:RegisterKeyframeSequence` creates a temporary ID for
local preview and is not an upload API. The documented publishing path is the
Animation Editor's **Publish to Roblox** action. This importer does not claim
that an externally reconstructed sequence is accepted as an editable
Animation Editor track; verify that in Studio before publishing. If Studio only
offers **Save to Roblox** from Explorer, that is the native sequence upload
flow and its result must be confirmed in Studio.

The XML reader is intentionally strict and intended for the converter's
generated schema, not arbitrary Roblox XML files.
