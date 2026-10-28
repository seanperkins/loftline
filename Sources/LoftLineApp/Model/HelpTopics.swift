import CAMCore
import Foundation

/// Built-in help reference. Each form has a "?" button that opens its topic in the Help window.
/// All wording is LoftLine's own.
enum HelpTopic: String, CaseIterable, Identifiable {
    case gettingStarted, jobSetup, machines, drawing, nodeEditing, layers, transforms
    case toolpathsOverview, profile, pocket, drilling, vcarve, inlay, fluting, texture, relief3D, tabs
    case engrave, chamfer, holeMill, prism, mergeToolpaths, straightInlay, moulding, photoVCarve, facing
    case toolDatabase, preview, checkToolpaths, exportGCode, saveAllToolpaths, airCut
    case preferences, recovery, shortcuts

    var id: String { rawValue }

    var title: String {
        switch self {
        case .gettingStarted: return "Getting Started"
        case .jobSetup: return "Job Setup"
        case .machines: return "Machines and Post Processors"
        case .drawing: return "Drawing Vectors"
        case .nodeEditing: return "Editing Nodes"
        case .layers: return "Layers and Groups"
        case .transforms: return "Arrange, Combine and Offset"
        case .toolpathsOverview: return "Toolpaths Overview"
        case .profile: return "Profile Toolpath"
        case .pocket: return "Pocket Toolpath"
        case .drilling: return "Drilling Toolpath"
        case .vcarve: return "V-Carve Toolpath"
        case .inlay: return "Inlay Toolpaths"
        case .fluting: return "Fluting Toolpath"
        case .texture: return "Texture Toolpath"
        case .relief3D: return "3D Relief Toolpaths"
        case .engrave: return "Quick Engrave Toolpath"
        case .chamfer: return "Chamfer Toolpath"
        case .holeMill: return "Hole Milling Toolpath"
        case .prism: return "Prism Carve Toolpath"
        case .mergeToolpaths: return "Merged Toolpaths"
        case .straightInlay: return "Straight Inlay Toolpaths"
        case .moulding: return "Moulding Toolpath"
        case .photoVCarve: return "Photo V-Carve Toolpath"
        case .facing: return "Facing Toolpath"
        case .tabs: return "Tabs, Ramps and Leads"
        case .toolDatabase: return "Tool Database"
        case .preview: return "2D and 3D Preview"
        case .checkToolpaths: return "Checking Toolpaths"
        case .exportGCode: return "Exporting G-code"
        case .saveAllToolpaths: return "Saving All Toolpaths"
        case .airCut: return "Running a Safe Air Cut"
        case .preferences: return "Preferences"
        case .recovery: return "Autosave and Recovery"
        case .shortcuts: return "Keyboard Shortcuts"
        }
    }

    var systemImage: String {
        switch self {
        case .gettingStarted: return "star"
        case .jobSetup: return "square.dashed"
        case .machines: return "cube"
        case .drawing: return "pencil.and.outline"
        case .nodeEditing: return "point.topleft.down.curvedto.point.bottomright.up"
        case .layers: return "square.3.layers.3d"
        case .transforms: return "square.on.square"
        case .toolpathsOverview: return "list.bullet"
        case .profile: return "square"
        case .pocket: return "square.fill"
        case .drilling: return "circle.circle"
        case .vcarve: return "v.square"
        case .inlay: return "square.on.square.dashed"
        case .fluting: return "line.diagonal"
        case .texture: return "water.waves"
        case .relief3D: return "mountain.2"
        case .engrave: return "pencil.tip"
        case .chamfer: return "triangle"
        case .holeMill: return "circle.dashed"
        case .prism: return "diamond"
        case .mergeToolpaths: return "arrow.triangle.merge"
        case .straightInlay: return "square.inset.filled"
        case .moulding: return "waveform.path"
        case .photoVCarve: return "photo"
        case .facing: return "rectangle.split.3x1"
        case .tabs: return "pin"
        case .toolDatabase: return "wrench.and.screwdriver"
        case .preview: return "cube.transparent"
        case .checkToolpaths: return "checkmark.shield"
        case .exportGCode: return "square.and.arrow.up"
        case .saveAllToolpaths: return "square.and.arrow.down.on.square"
        case .airCut: return "exclamationmark.triangle"
        case .preferences: return "gearshape"
        case .recovery: return "clock.arrow.circlepath"
        case .shortcuts: return "keyboard"
        }
    }

    /// Topic for an operation's inspector form.
    static func forOperation(_ kind: OperationKind) -> HelpTopic {
        switch kind {
        case .profile: return .profile
        case .pocket: return .pocket
        case .drill: return .drilling
        case .vcarve: return .vcarve
        case .inlay: return .inlay
        case .fluting: return .fluting
        case .texture: return .texture
        case .relief3D: return .relief3D
        case .engrave: return .engrave
        case .chamfer: return .chamfer
        case .holeMill: return .holeMill
        case .prism: return .prism
        case .merge: return .mergeToolpaths
        case .straightInlay: return .straightInlay
        case .moulding: return .moulding
        case .photoVCarve: return .photoVCarve
        case .facing: return .facing
        }
    }

    var related: [HelpTopic] {
        switch self {
        case .gettingStarted: return [.jobSetup, .drawing, .toolpathsOverview, .airCut]
        case .jobSetup: return [.machines, .airCut]
        case .machines: return [.exportGCode, .preferences]
        case .drawing: return [.nodeEditing, .transforms, .layers]
        case .nodeEditing, .layers, .transforms: return [.drawing]
        case .toolpathsOverview: return [.profile, .pocket, .vcarve, .toolDatabase]
        case .profile: return [.tabs, .toolDatabase]
        case .pocket, .drilling, .fluting, .texture: return [.toolDatabase, .preview]
        case .vcarve: return [.inlay, .toolDatabase]
        case .inlay: return [.vcarve]
        case .relief3D: return [.preview, .toolDatabase]
        case .engrave, .chamfer, .prism: return [.vcarve, .toolDatabase]
        case .holeMill: return [.drilling, .toolDatabase]
        case .mergeToolpaths: return [.toolpathsOverview]
        case .straightInlay: return [.inlay, .pocket]
        case .moulding: return [.fluting, .preview]
        case .photoVCarve: return [.vcarve, .preview]
        case .facing: return [.pocket, .jobSetup]
        case .tabs: return [.profile]
        case .toolDatabase: return [.toolpathsOverview]
        case .preview: return [.checkToolpaths]
        case .checkToolpaths: return [.exportGCode, .airCut]
        case .exportGCode: return [.saveAllToolpaths, .checkToolpaths, .airCut]
        case .saveAllToolpaths: return [.exportGCode]
        case .airCut: return [.jobSetup, .exportGCode]
        case .preferences: return [.machines, .recovery]
        case .recovery: return [.preferences]
        case .shortcuts: return [.drawing]
        }
    }

    /// Markdown body (rendered with `AttributedString(markdown:)`).
    var body: String {
        switch self {
        case .gettingStarted:
            return """
            LoftLine turns vector drawings into G-code for a CNC router. A typical job:

            1. **Job Setup** (⇧⌘J): material width, height and thickness, where X0 Y0 is, and whether Z zero is the material top or the spoilboard.
            2. **Pick the machine and post processor**, also in Job Setup. The machine sets the bed size and the posts you can use.
            3. **Draw or import** vectors (File ▸ Import… for SVG, DXF, EPS or STL).
            4. **Select vectors and add a toolpath** (Toolpaths ▸ New Toolpath). Choose the tool and depths in the inspector.
            5. **Calculate** (⌘R) and look at the 2D overlay and the 3D preview.
            6. **Check** (⇧⌘K), then **Export G-code** (⇧⌘E).
            7. **Air cut first** on a new job: see "Running a Safe Air Cut".

            Help ▸ Welcome to LoftLine opens a sample sign that already has toolpaths.
            """
        case .jobSetup:
            return """
            Job Setup describes the stock you clamp to the bed.

            - **Units**: changing them converts the design and every toolpath length.
            - **Machine and post processor**: the router and the G-code dialect it understands (see Machines).
            - **Material**: width (X), height (Y) and thickness (Z). The design area is the material rectangle, with (0, 0) at its lower-left corner.
            - **Z zero**: *Material surface* means you touch off on top of the stock and cuts have negative Z. *Machine bed* means you touch off on the spoilboard and the stock top is Z = thickness.
            - **XY origin**: which corner (or the center) of the material is machine X0 Y0. Moving the origin never moves the design; it only changes the G-code numbers.
            - **Safe Z / Home**: rapid moves happen at Safe Z above the material. The program ends by going to the home position.

            LoftLine warns when the material is bigger than the selected machine's bed.

            **Touch-off spot**: when the machine re-zeroes Z on a touch plate at each tool change (see Machines), Job Setup asks where the plate goes on the material. Every tool is probed there, the first one too. The plate must lie on solid stock: inside the material by at least the plate's size (so stock narrower than twice the plate's size cannot be probed), off clamps and keep-out zones, and clear of every toolpath on the sheet, switched on or off. Otherwise the export is refused. The check knows the current design only, not cuts from an earlier version of it or another project. Two-sided and tiled jobs cannot be posted with probing yet; switch it off in Preferences ▸ Machines to post them.
            """
        case .machines:
            return """
            A **machine** is the physical router: bed size, Z travel, how far a cut may go into the spoilboard, rapid speed and spindle range. A **post processor** is the G-code dialect the controller understands.

            Pick both in Job Setup (⇧⌘J). The status bar shows them, and clicking it opens Job Setup. Choosing a machine switches to one of its posts if the current one does not drive it. Validation and time estimates use the machine's limits.

            A project **carries its own copy** of its post, machine and tools, so it posts the same G-code on any Mac, even one that does not have them. Job Setup says "Using this project's copy" and, when the one installed here differs, shows a warning and an **Update This Project** button (⌘Z undoes it). Nothing changes until you use it.

            **Park and probe.** A machine can park the gantry for a manual tool swap and re-zero Z on a touch plate lying on the material, at every tool change (Preferences ▸ Machines). The program: lifts to the traverse height, parks, stops for the swap, moves to the job's touch-off spot, stops so you clip the lead on the bit, check that the probe light comes on, put the plate under the bit and jog **Z only** down to about half the probe travel above it, then probes, sets Z, lifts clear and stops for you to remove the plate. Park and traverse positions are machine coordinates (G53, on a homed machine): machine Z 0 is the top of travel and Z is negative downward. The probe travel can be no more than the plate's thickness, so a probe that misses still stops above the material. **GRBL** probes with G38.2 (it alarms without contact) and sets Z with G10 L20; set the traverse height at least 1 mm below machine Z 0, which is the limit switch. **Mach4** probes with G31, which does not stop without contact, so it calls **your zero macro** as `M<n> P<plate Z>`: the macro must stop the program when the probe did not touch, otherwise set the active work offset so the current Z reads P (in the program's units), and do nothing else. A reference macro is in the manual (TESTING.md). Probing works with a built-in post, unchanged, or a custom post that declares its controller (Toolpaths ▸ Post Processors); the probe settings always come from the machine installed on this Mac, and turning probing on reaches every project at once. Run the air-probe check in the manual before cutting. Material-top Z zero is recommended with probing.

            **Built-in posts**: Avid Mach4 (inch, mm), GRBL (inch, mm), LinuxCNC (inch, mm), Othermill (inch, mm), Onefinity Buildbotics (inch, mm), Carbide Motion (inch, mm), MASSO G3 (inch, mm), UCCNC (inch, mm) and Centroid CNC12 (inch, mm), with built-in machines for the Avid, a generic GRBL router, the Othermill Pro and original, the Genmitsu 3018-PROVer V2, the Sienci LongMill MK2 30x30, the Onefinity Woodworker and the Shapeoko 5 Pro 2x2. Only the Avid Mach4 posts have run on a machine: air-cut before the first job with any other (see the manual). For a post with no machine of your own model, make a machine for your controller (bed, feeds, spindle range) and list the post in it; until then LoftLine checks the job against the machine you picked. The GRBL, LinuxCNC, Onefinity Buildbotics and UCCNC posts stop for a tool change with M0, and the MASSO and Centroid posts change tools with M6 without applying the new tool's length and cannot re-zero Z there (LinuxCNC cannot touch off while a program is paused). Unless the machine probes on a touch plate, post a job with more than one tool with Save All Toolpaths ▸ one file per tool, and load and touch off each tool **before** starting its file: the stop at the top of the file only confirms the tool. Export warns when a program changes tools with a post like this. **Othermill** (Pro or original, through the Bantam Tools software): choose the Othermill machine and set Material Size and Home Z first in Job Setup, since the defaults (24 x 18 in, Home Z 0.8 in) do not fit its 5.5 x 4.5 x 1.35 in travel. The software puts the file's X0 Y0 Z0 at the front-left top corner of the stock, so use Z zero at the material top, the lower-left XY origin and no datum offset (export reports anything else as an error), and enter the same Material Size X, Y and Z in the Bantam software. A tool change writes `T M6`: the software asks for the swap and touches the new tool off, so one file can hold several tools. An optional stop always stops there. **Carbide Motion** (Shapeoko): comments are written with `;` and no parentheses, a tool change is `T M6`, which Carbide Motion answers with its tool-change prompt and, with a BitSetter, a measurement; the post assumes a BitSetter. **GRBL machines**: duplicate the machine, set its Max RPM to your spindle's top speed and choose the copy in Job Setup, and set GRBL's $30 to the same value. A post duplicated from a built-in (`<id>-custom-<n>`) keeps its controller's rules; one renamed to another id does not. **MASSO**: the dwell is written in milliseconds (`G4 P3000`), tools must be numbered T1–T100 (T0 is the laser), and MASSO has no G43. **UCCNC**: the dwell is in milliseconds, arcs are written as short lines, a tool change stops with M0, and UCCNC takes units from its profile, so set the profile to the post's units before the first cut (export reminds you). **Centroid CNC12**: the dwell is in seconds, the documented default; if Parameter 2 bit 2 is set (milliseconds) a 3 s spin-up becomes 3 ms, so check it before the first cut; arcs are written as short lines; dwells must be 0.01–327.67 s.

            Add your own machines in Preferences ▸ Machines: duplicate a built-in machine and edit it. Custom machines are JSON files in Application Support/LoftLine/machines; custom posts go in Application Support/LoftLine/posts.

            **Toolpaths ▸ Post Processors…** edits posts. Built-in posts are read-only: **Duplicate** one to make an editable copy (written only when you **Save**). The form holds every field of the post, and the right side shows the G-code it writes for a small sample job, with problems listed above it. Save stays disabled while there is a problem: the motion and spindle codes are fixed (G0, G1, G2, G3, M3 S{S}, M5, and the dwell G4 P{SECONDS} or, for a controller that reads P in milliseconds such as MASSO, NcStudio or UCCNC, G4 P{MILLISECONDS}; a post that dwells in milliseconds may not use {SECONDS} anywhere else, and a dwell is at most an hour), each template may use only its own placeholders, a tool or job name may appear only inside a comment, and every tool change must stop (M0) or select the new tool (T then M6). **Controller** declares Mach4 or GRBL, which a custom post needs for touch-plate tool changes. **Delete** moves the post's file to the Trash. Files in the posts folder that did not load are listed under Did not load with the reason; a post file must be named after its id (`<id>.json`).

            **Sharing a post.** **Export…** saves the selected custom post as a `.loftlinepost` file (a built-in is on every Mac already: Duplicate it first to share a changed copy). **Import…** opens such a file (or a `.json` post) as a draft: it is checked like any edit and added only when you Save, under a new id if one here already has its id. When the open project carries a post this Mac does not have, **Add This Project's Post** adds it with its own id, so the project then finds it installed.
            """
        case .drawing:
            return """
            The tool palette on the left of the canvas holds the drawing tools. Single-key shortcuts: **V** select, **N** node edit, **R** rectangle, **C** circle, **E** ellipse, **L** polyline, **P** Bézier pen, **T** text.

            - Drag to draw shapes; type exact sizes in the inspector afterwards.
            - Polylines and curves: click points, double-click or press Return to finish, Esc to cancel.
            - Text uses any installed font; the size is the height of capital letters.
            - To kern, select one text object and choose **Kern on Canvas** in the inspector (or Vectors ▸ Kern Text on Canvas): drag letters, Shift-drag to move a letter and the rest of its line, arrows nudge the clicked letter. The text stays editable.
            - Snapping to the grid (⌘') and to object points (⇧⌘') can be paused by holding ⌘ while dragging.
            - Drag a box left→right to select shapes fully inside it, right→left to select anything it touches.
            """
        case .nodeEditing:
            return """
            Press **N** (or Arrange ▸ Edit Nodes) to edit the points of a vector. Drag nodes or curve handles; Shift-click to select several. The inspector can make nodes smooth or corners, convert segments between lines and curves, insert nodes and break a path.

            The first node edit turns arcs into curves and the shape becomes a plain drawn vector (it loses its rectangle/circle settings).

            **Mirror** in the inspector edits symmetrically: moving a node or handle also moves its partner on the other side of the vector's center line (Left – Right, Top – Bottom or Both). Nodes on a center line only slide along it, so a symmetric shape stays symmetric.
            """
        case .layers:
            return """
            Layers live in the Design sidebar. Hide a layer to keep its vectors out of the way, lock it to stop accidental edits, and give it a color. New shapes go to the layer of the current selection.

            **Group** (⌘G) keeps shapes together when selecting; **Ungroup** (⇧⌘G) splits them again. **Combine Vectors** merges shapes into one; **Break Apart** splits a multi-path shape.

            **Edit ▸ Select** picks vectors by property: open vectors, duplicate copies lying on top of another vector, vectors similar in size and outline to the selection, everything on a layer, or the inverse of the selection. Locked and hidden layers are skipped.
            """
        case .transforms:
            return """
            The Arrange menu aligns and distributes the selection, mirrors, rotates by 90°, joins open vectors (**Join Open Vectors…** shows how far ends will move and lets you raise the tolerance), closes them, and runs boolean operations (union, subtract, intersect). **Offset…** grows or shrinks closed vectors.

            Drag the selection box handles to scale (Shift keeps proportions, Option scales about the center). The round handle above the box rotates (Shift snaps to 15°).

            **Vectors ▸ Distort Envelope on Canvas** puts four corner handles on the selection's box: drag them and the vectors are previewed bending to follow; Return or **Apply** makes the change, Esc cancels. Typed corner offsets are under **Values…** or in Vectors ▸ Shear / Distort….
            """
        case .toolpathsOverview:
            return """
            Select vectors, then Toolpaths ▸ New Toolpath. The toolpath appears in the Toolpaths sidebar and its settings in the inspector. Edits apply straight away; **Revert** undoes them.

            A toolpath shows as stale (faded) after its settings or the design change. Press **Calculate** or ⌘R to recalculate. Toolpaths are cut in sidebar order unless "Group by tool" is on in the export sheet. Untick "Include in export" to leave a toolpath out.

            **Pause** (at the bottom of the inspector) stops the machine after a toolpath, to flip the part, add clamps or clear chips: the program lifts to safe Z, stops the spindle, shows your message on the controller and waits for Cycle Start; the next toolpath restarts the spindle. "Optional stop" writes M1, which stops only when Optional Stop is switched on at the controller; on a controller with no usable switch (every built-in post but Mach4 and LinuxCNC) the post writes M0 and the machine always stops. Nothing is added after the last toolpath, and "Group by tool" never moves a toolpath across a pause.
            **Coolant** (each toolpath's form): Off, Mist (M7) or Air (M8). It comes on after the spindle starts and goes off (M9) before a tool change, a pause and the program's end. A stock GRBL controller has no M7: use Air there. The Othermill and Carbide Motion have no coolant (Carbide Motion ignores M7 and lacks M8): export reports coolant on their posts as an error.
            """
        case .profile:
            return """
            A profile cuts along vectors: **Outside** to cut a part free, **Inside** to cut a hole, **On** to follow the line.

            - **Cut depth** is below the material top; use the full thickness to cut through. Passes are split by the tool's stepdown, or by **Pass depth** when set.
            - **Allowance** leaves extra material for a finishing pass (negative removes more).
            - **Climb/Conventional** sets which way the tool travels around the part.
            - Add **tabs** so through-cut parts stay attached, and **ramps** so the tool does not plunge straight down.
            """
        case .pocket:
            return """
            A pocket clears all material inside closed vectors to a depth. Vectors inside other vectors become islands that are left standing.

            - **Offset** clearing follows the outline inward; **Raster** cuts back-and-forth lines at an angle, optionally with a final profile pass.
            - A larger **clearance tool** can remove the bulk first; the finish tool then cleans the walls and corners it could not reach.
            - LoftLine warns when a region is too narrow for the tool.
            """
        case .drilling:
            return """
            Drilling plunges once at the center of each selected closed vector (or each point). Turn on **Peck drilling** to drill in steps and retract between them to clear chips; **Dwell at bottom** pauses before retracting.
            """
        case .vcarve:
            return """
            V-carving follows the center line of shapes with a V-bit, going deeper where the shape is wider, so letters get crisp corners.

            - **Flat depth** limits the depth; wider areas are then cleared flat, optionally with a separate **flat area tool** (an end mill).
            - **Max pass depth** splits deep carves into several passes.
            - Only closed vectors are carved; text counters (the holes in letters) are respected.
            """
        case .inlay:
            return """
            An inlay is a V-carved **pocket** in one board and a matching **plug** cut from another board, glued in and planed flush.

            New Toolpath ▸ Inlay opens a wizard that creates both toolpaths. The plug is created disabled because it must be cut from its own board: export it as a separate file. **Glue gap** sets the space left at the bottom for glue.
            """
        case .engrave:
            return """
            Quick Engrave runs the tool straight along the selected vectors at one depth, with no offset to either side. Use it for single-line text, score lines and layout marks.

            Set the **depth** and the cut direction. Deep engraves are split into passes by the tool's stepdown.
            """
        case .chamfer:
            return """
            Chamfer runs a V-bit along the edges of a part so the side of the cone cuts a bevel.

            - **Side** says which side of a closed vector is the part; the bevel is cut into the part edge.
            - Give the **width** of the bevel on the top face, or a **depth**; the other follows from the bit angle.
            - With a **start depth** both are measured from the surface at that depth (the material above it is taken as already removed).
            - **Tip clearance** keeps the bit's point off the wall by running it slightly into the waste.
            """
        case .facing:
            return """
            Facing takes a thin layer off the top of a rectangle with a wide tool: the whole material, or the box round the selected vectors. Use it to flatten a warped board, or to surface the spoilboard.

            - **Pattern**: passes along X or along Y (each the reverse of the one before), or a spiral of rectangular rings from the outside in.
            - **Stepover** is the distance between passes as a percentage of the tool diameter; 70% is usual for a surfacing bit.
            - **Overhang** is how far the cutter's edge reaches past the edge of the area. By default the tool's center rides the edge, so the edge is cleaned. Passes are led in from outside the area, so the first pass does not plunge into the surface.
            - **Cut depth** is how far below the original top the new surface ends up. Later toolpaths still measure depth from the original top (or from the spoilboard), so touch off Z0 once and do not re-zero after facing.
            """
        case .holeMill:
            return """
            Hole Milling cuts round holes with an end mill smaller than the hole, centered on each selected circle.

            - **Helical bore** spirals down at the hole radius, then makes one flat lap at the bottom. **Helix pitch** is the depth per turn.
            - **Thread milling** cuts an internal thread with a thread mill in a pilot hole. Set the thread pitch and hand.
            - Leave the diameter empty to use each circle's own size.
            """
        case .prism:
            return """
            Prism Carve runs a V-bit round each shape deep enough that the two sloping walls meet in a sharp ridge down the middle, so letters and shapes stand out as beveled prisms.

            Set a **max depth** to stop wide shapes going too deep; they then keep a flat top.
            """
        case .mergeToolpaths:
            return """
            Merging combines several toolpaths into one entry that is cut in the listed order. It keeps the sidebar short and keeps related cuts together in the G-code.

            Choose **Split Into Separate Toolpaths** in the inspector to get the original toolpaths back.
            """
        case .straightInlay:
            return """
            A straight inlay cuts a pocket in one board and a matching plug in another, both with an end mill. Corners are rounded to what the tool can cut, so the plug fits the pocket.

            - **Clearance** is the gap all round between plug and pocket wall.
            - Make the **plug depth** a little more than the pocket depth.
            - Turn on **Mirror plug** when the plug is glued in face down.
            """
        case .moulding:
            return """
            Moulding sweeps a cross-section shape along one or more rail vectors to carve a profile, such as a picture-frame edge.

            Select the rails, then the cross-section last. The section's left edge sits on the rail and its top is the material surface. **Rough in levels first** removes material in flat levels before the finishing passes. Curved rails are carved approximately.
            """
        case .photoVCarve:
            return """
            Photo V-Carve engraves a picture as rows of parallel V-grooves. Darker parts of the image get wider, deeper grooves; black areas are carved as wide as the line spacing.

            Choose the image, set its width and position (or **Fit to Material**), the groove **angle** and **line spacing**. **Invert** carves the light areas instead, for a light fill in dark wood.
            """
        case .fluting:
            return """
            Fluting runs a ball-nose or V-bit along open or closed vectors and ramps the depth at the start, the end or both, giving tapered decorative grooves. **Ramp length** is a percentage of each vector's length.
            """
        case .texture:
            return """
            Texture covers the selected area with short random scoops, like a hand-tooled surface. Spacing, stroke length, angle and variation shape the pattern; the **seed** makes it repeatable.
            """
        case .relief3D:
            return """
            Import an STL model (File ▸ Import…) to place it on the job and create **Roughing** and **Finishing** toolpaths.

            - Roughing removes most material in flat layers with an end mill, leaving an **allowance**.
            - Finishing follows the surface with a ball-nose in raster lines; a smaller **stepover** gives a smoother finish but takes longer.
            - **Resolution** is the size of the height grid used for calculation.
            """
        case .tabs:
            return """
            **Tabs** are small bridges left at the bottom of a through cut so the part does not move. Set their length and **tab height**, which is measured up from the bottom of the cut, not from the material bottom: if the cut goes a little below the material (to clear the spoilboard) the tab holds less, and the note under the field says how much. Choose automatic spacing or Placement: Manual and **Edit on Canvas** to click where they go (drag to slide, Option-click to delete).

            **Ramps** enter the material gradually (smooth, zigzag or spiral) instead of plunging. **Leads** start and finish the cut just outside the part to avoid marks; **Overcut** goes past the start point to clean the seam.
            """
        case .toolDatabase:
            return """
            Toolpaths ▸ Tool Database (⇧⌘T) lists your cutters. Each tool has a type, diameter, angle (V-bits), stepdown, stepover, spindle speed, feed and plunge rates. Tools are shared by all jobs and saved in Application Support/LoftLine/tools.json; jobs also keep a copy of the tools they use. Numbers and choices save as you make them; a name, group, note or material name saves when you leave the field or press Return. Renaming a tool or changing its notes or group does not make toolpaths stale; changing anything that reaches the program does. Revert Changes discards the edits that are not saved yet.

            End mills and ball noses have a **Shape**: Bull Nose (an end mill with a corner radius), Tapered (a ball tip of the given radius on a cone that widens at the taper angle per side, up to the diameter) or Form (any turned outline such as a roundover, entered as radius at each height above the tip). The 3D preview, 3D finishing, Moulding and Quick Engrave widths use the real outline; 2D Profile and Pocket offsets still use the diameter. Undercuts on a form tool are treated as seen from below.

            To move tools to another Mac, use **Share ▸ Export All Tools…** (or Export Selected Tool…) and save a `.loftlinetools` file, then **Share ▸ Import Tools…** on the other machine. Import also reads another Mac's `tools.json` and CSV files (columns name, type, diameter, plus optional units, number, flutes, angle, stepdown, stepover, rpm, feed, plunge, group, notes). If an imported tool already exists with different settings, choose Replace Existing, Keep Both or Keep Existing. Clashing tool numbers are changed to a free number.
            """
        case .preview:
            return """
            The **2D** view draws calculated toolpaths over the design: solid lines are cuts, dashed red lines are rapid moves. Toolpaths ▸ Show Toolpaths (⌥⌘P) hides them.

            The **3D** view simulates cutting the material. Press Play, scrub the timeline or change the speed. **2D | 3D** shows both side by side.

            The **view** button (cube) resets the camera; its arrow picks a standard view (top, front, back, left, right, bottom, isometric) and switches **Orthographic** projection on or off. Drag to orbit, scroll to zoom.

            The **Show** menu next to the Tool checkbox draws **toolpath lines** (cuts colored by depth, rapid moves in orange) and the design **vectors** in the 3D view, on top of the simulated stock.

            **Toolpaths ▸ Preview G-code File…** simulates a saved program (.tap, .nc, …) from another job on this job's material, in its own window. It assumes the program uses this job's XY origin and Z zero. Tools named in a LoftLine header are recognized; otherwise set each tool's type and diameter in the window. Nothing is added to the job. To reuse toolpath settings across jobs, use a toolpath template instead.
            """
        case .checkToolpaths:
            return """
            Toolpaths ▸ Check Toolpaths… (⇧⌘K) checks every enabled toolpath and the combined program against the machine: travel limits, cuts into the spoilboard, rapids below the material, spindle speed range, and missing feeds. **Errors** must be fixed or explicitly accepted; **warnings** are worth a look.
            """
        case .exportGCode:
            return """
            File ▸ Export G-code… (⇧⌘E) writes one program. Choose all enabled toolpaths or a single one, and the post processor. **Group by tool** reorders toolpaths to reduce tool changes when that is safe (profiles that cut parts free stay last).

            The sheet reads the **deepest cut** back out of the program itself, in machine Z and against the material bottom, so you can check it against your Z zero before you run anything. The validator runs on the output; if it reports errors you must confirm before saving.
            """
        case .saveAllToolpaths:
            return """
            Toolpaths ▸ Save All Toolpaths… (⌥⌘S) writes several programs at once: one file grouped by tool, one file in list order, one file per toolpath, or one file per tool. Multi-file modes ask for a folder; names get a run-order prefix.
            """
        case .airCut:
            return """
            Before cutting a new job for real:

            1. Zero X and Y as set in Job Setup.
            2. Zero Z **1–2 inches above** the material (or spoilboard), so every move happens in the air.
            3. Leave the spindle off and run the program at reduced feed, watching tool changes, rapids and the final home move.
            4. Re-zero Z properly and run the real cut.

            Always wear eye and hearing protection and keep a hand near the E-stop.
            """
        case .preferences:
            return """
            LoftLine ▸ Settings… (⌘,) sets the defaults for **new** documents (units, grid spacing, machine, post, snapping), the canvas colors, how often recovery copies are saved, and whether the Welcome window opens at launch. Open documents keep their own settings.

            **Updates and privacy.** Release builds of LoftLine look for a newer version when they start and then once a day. The only request goes to github.com, with the user agent `LoftLine/<version>`: no identifiers, no usage data, nothing else. A download is checked against its SHA-256 and a signature made with LoftLine's own key before anything is installed, and an update installs only when LoftLine quits. Turn the daily check off with **Check for updates automatically** in Settings ▸ General. LoftLine ▸ Check for Updates… looks once, on request.
            """
        case .recovery:
            return """
            LoftLine saves documents through macOS (File ▸ Save, Revert To, and Browse All Versions). In addition, every open document with unsaved changes is copied to a recovery folder on a timer (Preferences ▸ General).

            If LoftLine quits unexpectedly, the next launch offers to recover those documents; they open as new, untitled windows that you then save. File ▸ Recover Unsaved Work… shows them again. Recovered and discarded copies are kept in Recovery/Archive.
            """
        case .shortcuts:
            return """
            - **File**: ⇧⌘I import · ⌘P print
            - **Canvas tools**: V select · N nodes · R rectangle · C circle · E ellipse · L polyline · P pen · T text
            - **View**: ⌘0 zoom to material · ⌘2 zoom to selection · ⌘= / ⌘- zoom · ⌥⌘1 2D · ⌥⌘2 2D and 3D · ⌥⌘3 3D · ⌥⌘P toolpaths
            - **Design**: ⇧⌘J Job Setup · ⇧⌘B top / bottom side (two-sided jobs) · ⌘' snap to grid · ⇧⌘' snap to objects
            - **Selection** (Edit and Arrange menus): ⌘D duplicate · ⌘G / ⇧⌘G group / ungroup · ⌥⌘[ / ⌥⌘] rotate 90°
            - **Canvas keyboard**: Tab / ⇧Tab select the next / previous shape (⌃Tab leaves the canvas) · arrow keys nudge (⇧ for ×10) · Delete removes · Esc clears
            - **Toolpaths**: ⌘R calculate all · ⇧⌘K check · ⇧⌘E export · ⌥⌘S save all · ⇧⌘T tool database
            - **Help**: ⌘? LoftLine Help
            """
        }
    }

    /// Topics whose title or body contain every word of `query` (case-insensitive).
    static func search(_ query: String) -> [HelpTopic] {
        let words = query.lowercased().split(whereSeparator: \.isWhitespace).map(String.init)
        guard !words.isEmpty else { return allCases }
        return allCases.filter { t in
            let text = (t.title + " " + t.body).lowercased()
            return words.allSatisfy { text.contains($0) }
        }
    }
}

/// Tooltips for form fields, keyed by the field label (used when a field has no explicit help).
enum FieldHelp {
    static let texts: [String: String] = [
        "Start depth": "Depth below the material top where cutting starts",
        "Spot X": "Where the touch plate goes on the material, from its lower-left corner",
        "Spot Y": "Where the touch plate goes on the material, from its lower-left corner",
        "Coolant": "Mist (M7) or air (M8) while this toolpath cuts; off (M9) before a tool change or pause",
        "Cut depth": "Final depth below the material top",
        "Pass depth": "Maximum depth of each pass (off = the tool's stepdown)",
        "Max pass depth": "Split the carve into passes no deeper than this (off = one pass)",
        "Final pass": "Thin last pass for a cleaner floor (0 = none)",
        "Ramp length": "Distance over which the tool descends into the material",
        "Max angle": "Steepest allowed ramp angle",
        "Raster angle": "Direction of raster lines (0° = along X)",
        "Overhang": "How far the cutter's edge reaches past the area's edge (off = a tool radius)",
        "Area": "Face the whole material, or the box round the selected vectors",
        "Facing pattern": "Parallel passes along X or Y, or rectangular rings from the outside in",
        "Allowance": "Material left on the part for a later finishing pass (negative removes more)",
        "Length": "Length of each tab along the cut",
        "Tab height": "Height of each tab, measured up from the bottom of the cut",
        "Follow the material thickness": "Keep the cut depth the same distance past the material bottom when Job Setup's thickness changes",
        "Spacing": "Distance between tabs or strokes",
        "Lead radius": "Radius of the arc that leads into and out of the cut",
        "Lead length": "Length of the straight lead into and out of the cut",
        "Overcut": "Distance cut past the start point to clean the seam",
        "Peck depth": "Depth added by each peck",
        "Retract height": "Height above the material the drill lifts to between pecks",
        "Dwell at bottom": "Pause at the bottom of each hole before retracting",
        "Flat depth": "Deepest the V-bit goes; wider areas are cleared flat at this depth",
        "Pocket depth": "Depth of the inlay pocket in the receiving board",
        "Plug start depth": "How far below the plug board's top the plug's carve starts",
        "Glue gap": "Space left between the plug and the pocket floor for glue",
        "Plug boundary margin": "Extra material cleared around the plug outline",
        "Max depth": "Deepest point of each texture stroke",
        "Min stroke": "Shortest texture stroke",
        "Max stroke": "Longest texture stroke",
        "Angle": "Direction of the strokes (0° = along X)",
        "Variation": "How much stroke length and depth vary randomly",
        "Resolution": "Size of the height grid cell used to calculate 3D toolpaths",
        "Stepover": "Distance between neighboring passes",
        "Width (X)": "Material size along the machine's X axis",
        "Height (Y)": "Material size along the machine's Y axis",
        "Thickness (Z)": "Material thickness",
        "Safe Z": "Height above the material for rapid moves",
        "Home Z": "Height above the material at the end of the program",
        "Grid spacing": "Distance between grid lines used for snapping",
        "Rapid rate": "Rapid traverse speed, used for time estimates",
        // Toolpath forms: toggles and pickers (through `fieldHelp`) and the remaining fields.
        "Ramp plunges": "Enter the material on a slope instead of plunging straight down",
        "Ramp type": "Smooth follows the cut on a slope, zig-zag goes back and forth, spiral circles down",
        "Direction": "Climb cuts with the spindle's rotation for a cleaner edge; conventional cuts against it",
        "Clearing": "Offset follows the outline inwards; raster sweeps back and forth",
        "Profile pass": "A pass along the wall to clean up what the raster leaves, before or after it",
        "Final profile pass": "Finish with a pass along the wall to clean up the raster edges",
        "Side": "Outside cuts a part free, Inside cuts a hole, On runs the tool's center along the line",
        "Open vectors": "Where the tool runs on an open vector: on the line, or to its left or right",
        "Start point": "Where each closed loop starts cutting",
        "Cut order": "The order the parts are cut in; holes always come before the part around them",
        "Output arcs (G2/G3)": "Write curves as arc moves; off writes them as short straight lines",
        "Sharp external corners": "Run straight out to a square corner instead of rolling round it",
        "Add tabs": "Leave small bridges that hold the part until the cut is done",
        "Triangular (3D) tabs": "Ramp over each tab instead of stepping, for a smaller bump to clean up",
        "Placement": "Automatic spaces the tabs evenly; Manual lets you put each one on the canvas",
        "Tabs per vector": "Tabs on each closed vector",
        "Lead in/out": "Enter and leave the cut along a line or an arc, so the tool does not mark the part",
        "Peck drilling": "Drill in steps, lifting between them to clear the chips",
        "Taper ends": "Share of each line's length over which its ends rise to the surface",
        "Use vector start points": "Start outlines and engraved lines at each vector's start point",
        "Use vector selection order": "Carve the vectors in the order they were selected, not the shortest route",
        "Plug boundary": "How much waste is cleared around the plug: its outline, a box around it, or the whole board",
        "Part": "Which half to cut: the pocket board, the plug board, or both",
        "Mirror plug": "Flip the plug so it is cut face down and fits when turned over",
        "Ramp": "Which end of each flute slopes: the start, the end or both",
        "Smooth ramp": "Ease the flute's slope with a curve instead of a straight ramp",
        "Model": "The 3D model this toolpath machines",
        "Machine from both sides": "Cut the top of the model, then flip the board and cut the bottom",
        "This toolpath cuts": "Which face of the board this toolpath is for",
        "Flip board": "The axis the board turns over on between the two sides",
        "Split depth": "Depth of the plane where the two sides meet (off = half the thickness)",
        "Web": "Material left at the split plane so the part stays in the board",
        "Rough first": "Clear most of the material in flat levels before the finishing passes",
        "Finish": "Trace the model's surface with closely spaced passes",
        "Pattern": "Raster sweeps back and forth, Offset follows the outline inwards, Spiral winds in from the edge",
        "Separate last pass": "Rough close to the line, then one last lap cuts the wall to size",
        "Reverse direction": "Cut the last pass the other way round for a cleaner wall",
        "Last pass at full depth": "Cut the last pass in one go instead of pass by pass",
        "Last pass allowance": "Material the roughing passes leave on the wall for the last pass",
        "Corner sharpen": "Lift this tapered tool into corners it cannot reach at the flat depth",
        "Engrave at depth": "Carve open vectors as lines at this depth (off = ignore them)",
        "Surface clearance": "Gap kept between the plug board and the pocket board when the plug is seated",
        "Size by": "Set the chamfer by its width on the surface or by how deep the tip goes",
        "Depth": "Depth of the bit tip below the start depth's surface",
        "Width": "Chamfer width on the surface at the start depth (the material top when it is 0)",
        "Tip clearance": "How far the tip runs into the waste past the edge",
        "Passes": "Even divides the depth evenly; Exact step cuts full passes and the remainder last; Custom lists each pass",
        "Last pass thickness": "Material left for a thin last pass (0 = none)",
        "Mode": "Helical bore spirals down a hole; thread mill cuts a thread one turn per pitch",
        "Hole diameter": "Size to bore (off = each circle's own size)",
        "Major diameter": "The thread's outside diameter (off = each circle's own size)",
        "Depth per turn": "How far the helix descends each turn",
        "Thread pitch": "Distance the thread advances per turn",
        "Right-hand thread": "A thread that tightens clockwise (off = left-hand)",
        "Repeat on a grid": "Cut this toolpath several times, on a grid of copies",
        "Columns": "Copies across",
        "Rows": "Copies up",
        "X spacing": "Distance between columns",
        "Y spacing": "Distance between rows",
        "Plug depth": "Depth of the cut round the plug",
        "Clearance": "Gap all round between the plug and the pocket",
        "Section side (open rails)": "Which side of an open rail the cross-section extends to",
        "Rough in levels first": "Clear the bulk in flat levels before following the section",
        "Pause the machine after this toolpath": "Lift to safe Z, stop the spindle and wait for Cycle Start: flip the part, add clamps, clear chips",
        "Optional stop (M1)": "Stops only when Optional Stop is switched on at the controller",
        "Include in export": "Write this toolpath into the exported program",
        "Project onto 3D": "Cut this toolpath's depths below the 3D model's surface instead of the material top",
        "Invert (carve light areas)": "Carve the light areas deep and the dark ones shallow",
        "Line angle": "Direction of the grooves (0° = horizontal)",
        "Line spacing": "Distance between groove centers; black areas are carved this wide",
        "Min depth": "Shallower grooves are skipped (light areas)",
        "Left (X)": "Left edge, in material coordinates",
        "Bottom (Y)": "Bottom edge, in material coordinates",
        // Job Setup.
        "Units": "Inches or millimeters for every length",
        "Machine": "Bed size, travel limits and the post processors that drive it",
        "Z zero": "Where Z 0 is touched off: the material top or the spoilboard",
        "Offset the datum": "Put machine X0 Y0 somewhere other than the chosen corner or center",
        "Offset X": "Distance from the chosen corner or center to machine X0 (right is positive)",
        "Offset Y": "Distance from the chosen corner or center to machine Y0 (up is positive)",
        "Plunge Z (rapid down to)": "Height the tool rapids down to before feeding into the cut (off = feed from safe Z)",
        "Home X": "Where the program parks at the end, in machine coordinates",
        "Home Y": "Where the program parks at the end, in machine coordinates",
        "Two-sided job": "Machine the top, flip the board, machine the bottom",
        "Flip the material": "Which way the board turns over between the two sides",
        "Bottom side Z zero": "Where Z is touched off for the second side",
        // Tool Database.
        "Type": "What the cutter is; decides which toolpaths offer it",
        "Tool number": "The T number the post writes; the operator loads this tool at the change",
        "Diameter": "Cutting diameter; the toolpath offsets use it",
        "Flutes": "Cutting edges; feed = RPM × flutes × chip load",
        "Included angle": "Full angle between a V-bit's two flanks",
        "Tip diameter": "Flat at the point of a V-bit or engraver (0 = sharp)",
        "Flute length": "Length of the cutting edges; a deeper cut rubs the shank",
        "Pass depth (stepdown)": "Deepest cut per pass",
        "Spindle speed": "Spindle RPM",
        "Feed rate": "Speed along the cut",
        "Plunge rate": "Speed straight down into the material",
        "Target chip load": "Advance per cutting edge; the material presets are starting points",
        "Material": "A common material's starting chip load for a cutter of this diameter",
    ]

    static func text(for label: String) -> String? { texts[label] }
}
