// Node — retained widget tree with dirty flags (ADR-0004).
// Zig has no GC: the tree is retained and mutated in place. Dirty flags drive
// the frame loop — a clean tree renders 0 frames (0 wakeups at idle).
const std = @import("std");
const kx = @import("../kx.zig");
const paint_mod = @import("paint.zig");
const sdl = @import("../sdl.zig");
const layout_mod = @import("layout.zig");
const input_mod = @import("input.zig");
const scroll_mod = @import("scroll.zig");
const semantics_mod = @import("semantics.zig");
const state_mod = @import("state.zig");

pub const Paint = paint_mod.Paint;
pub const Constraints = layout_mod.Constraints;
pub const Size = layout_mod.Size;
pub const Axis = layout_mod.Axis;

pub const Rect = struct {
    x: f32 = 0,
    y: f32 = 0,
    w: f32 = 0,
    h: f32 = 0,

    pub fn contains(r: Rect, px: f32, py: f32) bool {
        return px >= r.x and px < r.x + r.w and py >= r.y and py < r.y + r.h;
    }

    pub fn main(r: Rect, axis: Axis) f32 {
        return switch (axis) {
            .horizontal => r.w,
            .vertical => r.h,
        };
    }

    pub fn cross(r: Rect, axis: Axis) f32 {
        return switch (axis) {
            .horizontal => r.h,
            .vertical => r.w,
        };
    }
};

/// Global layout epoch: bumped by process-global layout-affecting changes
/// (the i18n direction flip). `Node.layout()`'s clean-skip requires the
/// current epoch, so a bump re-lays the whole tree once.
pub var layout_epoch: u64 = 1;

pub fn bumpLayoutEpoch() void {
    layout_epoch += 1;
}

/// Dirty-mark dedup epoch — see Node.dirty_mark_gen. Starts at 1 so a
/// fresh node's zero stamps never match. Bumped when the outermost
/// clearing traversal (paint/layout) ENDS: every stamp from before the
/// pass is stale because the pass may have cleared ancestors anywhere.
var mark_epoch: u32 = 1;
/// >0 while a paint()/layout() traversal runs. Marks inside a pass
/// bypass the stamp early-out and always re-walk the ancestor chain —
/// mid-pass the ancestors may have been cleared already.
var in_clearing_pass: u32 = 0;

fn clearingPassEnter() void {
    in_clearing_pass += 1;
}
fn clearingPassExit() void {
    in_clearing_pass -= 1;
    if (in_clearing_pass == 0) mark_epoch += 1;
}

/// Invalidate every dirty-mark stamp — the real invalidator is a clearing
/// pass; tests that reset flags by hand call this to model one.
pub fn bumpMarkEpoch() void {
    mark_epoch += 1;
}

/// Bounding box of two rects (the swept region of a monotonic translation).
pub fn rectUnion(a: Rect, b: Rect) Rect {
    const x0 = @min(a.x, b.x);
    const y0 = @min(a.y, b.y);
    const x1 = @max(a.x + a.w, b.x + b.w);
    const y1 = @max(a.y + a.h, b.y + b.h);
    return .{ .x = x0, .y = y0, .w = x1 - x0, .h = y1 - y0 };
}

/// Intersection of two rects (empty when they don't overlap — w/h clamp to 0).
pub fn rectIntersect(a: Rect, b: Rect) Rect {
    const x0 = @max(a.x, b.x);
    const y0 = @max(a.y, b.y);
    const x1 = @min(a.x + a.w, b.x + b.w);
    const y1 = @min(a.y + a.h, b.y + b.h);
    return .{ .x = x0, .y = y0, .w = @max(0, x1 - x0), .h = @max(0, y1 - y0) };
}

/// Whether two rects share any area (an empty rect overlaps nothing).
pub fn rectOverlaps(a: Rect, b: Rect) bool {
    return a.w > 0 and a.h > 0 and b.w > 0 and b.h > 0 and
        a.x < b.x + b.w and b.x < a.x + a.w and
        a.y < b.y + b.h and b.y < a.y + a.h;
}

/// Normalize a rect to positive extents: a map_paint_rect hook under a
/// negative scale (a mirrored AnimatedScale) flips w/h negative; the
/// callers' overlap/intersect tests require positive extents.
pub fn rectNormalize(r: Rect) Rect {
    return .{
        .x = @min(r.x, r.x + r.w),
        .y = @min(r.y, r.y + r.h),
        .w = @abs(r.w),
        .h = @abs(r.h),
    };
}

/// Pointer cursor shapes (Phase 2d-0.5): the host maps the hovered node to
/// a system cursor on desktop (SDL). A widget overrides via VTable.cursor;
/// otherwise the semantic role decides (.button/.link → hand, .text_field →
/// ibeam — ui/input.zig cursorForNode); the fallback is the default arrow.
pub const PointerCursor = enum { default, hand, ibeam, move, wait };

pub const VTable = struct {
    measure: *const fn (node: *Node, c: Constraints) Size,
    /// measure() is a pure function of (constraints, layout-marked state):
    /// every input it reads — text metrics, immutable opts, child measures —
    /// changes only through markLayoutDirty paths. That lets measure()
    /// cache the last (constraints → size) result and skip a re-measure of
    /// an untouched subtree (Flutter's relayout-boundary idiom). Anything
    /// reading clocks, drives, or externally-mutated buffers must leave this
    /// false — the default — or its silent changes would freeze the size.
    measure_pure: bool = false,
    layout: *const fn (node: *Node, bounds: Rect) void,
    paint: *const fn (node: *Node, ctx: *kx.Ctx) void,
    deinit: ?*const fn (node: *Node) void = null,
    /// Pointer input (Phase 1c, dispatched by ui/input.zig). Returns true if
    /// handled — bubbling to the parent stops.
    on_pointer: ?*const fn (node: *Node, ev: input_mod.PointerEvent) bool = null,
    /// Keyboard input (Phase 1c) — delivered to the focused node's chain.
    on_key: ?*const fn (node: *Node, ev: input_mod.KeyEvent) bool = null,
    /// The node edits text (TextField/SearchBar/SearchView): the host
    /// raises the platform IME while it's focused (SDL_StartTextInput +
    /// SetTextInputArea) — desktop always-on paths ignore this.
    wants_text_input: bool = false,
    /// Scroll (wheel) input (Phase 1f) — bubbles up until a scrollable
    /// reports it handled.
    on_scroll: ?*const fn (node: *Node, ev: input_mod.ScrollEvent) bool = null,
    /// Pointer cursor override (Phase 2d-0.5, desktop): when set, wins over
    /// the semantic-role mapping (ui/input.zig cursorForNode).
    cursor: ?*const fn (node: *Node) PointerCursor = null,
    /// Scrollable interface (Phase 1f): the Scrollbar drives any scrollable
    /// through these hooks — no direct widget-to-widget dependency.
    scroll_info: ?*const fn (node: *Node) scroll_mod.ScrollInfo = null,
    scroll_set_offset: ?*const fn (node: *Node, offset: f32) void = null,
    /// Paint-time wrapper around the children's paint (Phase 1e): called
    /// after this node's own paint, before the children's — e.g. save +
    /// translate for an animated offset. Must be balanced with
    /// post_children_paint (the canvas state is restored right after).
    pre_children_paint: ?*const fn (node: *Node, ctx: *kx.Ctx) void = null,
    post_children_paint: ?*const fn (node: *Node, ctx: *kx.Ctx) void = null,
    /// Popup overlay pass (Phase 2d.3 PR D2): the host paints the open
    /// popup's hook after the whole tree (above later siblings — a popup's
    /// content overflows its anchor), before the focus ring. Children with
    /// defer_paint paint here, not in the normal children pass.
    paint_overlay: ?*const fn (node: *Node, ctx: *kx.Ctx) void = null,
    /// Map a rect from this node's child space into its parent space — the
    /// inverse of the paint transform (pre_children_paint). Dirty marks
    /// under a transformed ancestor land at the child's VISIBLE position.
    /// CONTRACT: the map must be rect-affine (translate / uniform scale —
    /// every current impl is); the paint traversal's childSpaceAffine probes
    /// the composed chain on the unit rect, so a shear/rotation here would
    /// silently mis-cull children.
    map_paint_rect: ?*const fn (node: *Node, rect: Rect) Rect = null,
    /// The rect the children are clipped to (in this node's parent space) —
    /// matching the clipRect pre_children_paint pushes, e.g. a scroll view's
    /// viewport. The paint traversal intersects the visible region with it:
    /// descendants cull against the tighter rect, and an empty intersection
    /// skips the whole children pass. Null = children aren't clipped — their
    /// paint may overflow the bounds (a tooltip's bubble, a menu's panel), so
    /// each child must be visited and culled on its own.
    child_clip: ?*const fn (node: *Node) Rect = null,
    /// The region own-paint can touch, in the node's bounds space (defaults
    /// to bounds + damage_overflow). Set when own paint lands SOMEWHERE ELSE
    /// than an expansion of the bounds — the overlay scrollbar floats over
    /// its parent's edge and takes no layout space (its bounds are ~empty).
    /// Paint culling and markDirty consult it.
    paint_bounds: ?*const fn (node: *Node) Rect = null,
    /// Scroll-copy fast path (backing-store idiom — the same one
    /// QBackingStore/Flutter's viewport layers use): the hook OWNS the
    /// children pass — it may blit the previous frame's composited viewport
    /// shifted by the scroll delta and repaint only the newly-exposed strip.
    /// Return false to fall back to the normal children pass (dirty rows,
    /// window shifts, first paint). `child_region` is the pre-tightened
    /// visible rect — the same one the normal pass would cull against.
    scroll_children_paint: ?*const fn (node: *Node, ctx: *kx.Ctx, child_region: Rect) bool = null,
    /// Effective hit-test rect (defaults to bounds). Transformed widgets
    /// return where their children actually paint.
    hit_bounds: ?*const fn (node: *Node) Rect = null,
    /// Spatial child index for hit-testing (the same idiom as the paint
    /// culler): a container whose children occupy DISJOINT, computable
    /// cells (grid tracks, uniform list rows) answers "which child could
    /// contain this point" with index math instead of a linear scan —
    /// browsers/Qt do the same for regular layouts. Returning a child means
    /// it is the ONLY possible hit (the child still verifies its own
    /// bounds, so gap hits return null naturally); returning null means no
    /// child can contain the point. Contract: only valid while every
    /// child's hit area stays inside its cell (no hit_bounds/overflow).
    hit_child: ?*const fn (node: *Node, x: f32, y: f32) ?*Node = null,
    /// Map a point from this node's space into its children's coordinate
    /// space (matches the paint transform, inverted). Hit-testing through a
    /// transformed subtree lands on the visual position.
    pre_children_hit: ?*const fn (node: *Node, px: f32, py: f32) HitPoint = null,
    /// Automatic retained-subtree eligibility (Phase 4e/dirty-region): when
    /// set, a paint pass that finds this subtree CLEAN may rasterize it into
    /// a cached image once and re-blit while it stays clean — the same
    /// per-item texture idiom as `retained`, driven by the traversal instead
    /// of the app. Only safe for nodes whose whole subtree obeys the
    /// paint-extent contract (everything it draws is reachable through
    /// paintRect + child_clip + map_paint_rect): layout containers, simple
    /// decorative wrappers, and scroll viewports qualify; nodes whose paint
    /// can change without a dirty mark, or whose extent is unbounded, must
    /// not set it. A dirty frame drops the cache and repaints directly —
    /// auto-retention pays only where the subtree changes RARELY relative
    /// to the frame rate.
    auto_retain: bool = false,
    /// This node's paint SAMPLES the pixels behind it (ui.paint.backdropBlur
    /// — a backdrop filter). Inside a retained offscreen pass those pixels
    /// don't exist (the image starts transparent), so a subtree containing
    /// one must never be auto-retained — propagated up the parent chain as
    /// `backdrop_subtree`. Opt-in `retained` is unaffected: an app that
    /// retains a node whose subtree includes its own backdrop content gets
    /// a self-contained image either way.
    reads_backdrop: bool = false,
};

/// A point in a transformed coordinate space (hit-testing, Phase 1e).
pub const HitPoint = struct { x: f32, y: f32 };

/// Auto-retain image cap (auto_retain vtables only — opt-in `retained`
/// nodes are explicitly sized by the app). Above this, the rasterized
/// image costs more memory + blit time than the draw ops it replaces
/// (a 10k-row content column: ~64 MB for a blit slower than re-issuing
/// the cheap op stream). 2 MP ≈ 8 MB RGBA — comfortably covers a
/// 1280×800 viewport; a virtualized content column lands far above.
pub const AUTO_RETAIN_MAX_PX: u64 = 2 * 1024 * 1024;

pub const Node = struct {
    allocator: std.mem.Allocator,
    parent: ?*Node = null,
    children: std.array_list.Managed(*Node),
    bounds: Rect = .{},
    dirty: bool = true,
    layout_dirty: bool = true,
    /// measure() cache (relayout boundary): the last pure measurement and
    /// the constraints it was taken under. Valid only while the subtree is
    /// fully measure-pure — any descendant reading untracked state flips
    /// `impure_descendant` on the whole ancestor chain at add() time.
    m_valid: bool = false,
    m_constraints: Constraints = .{},
    m_size: Size = .{},
    /// Flex only: the last measure ran with an unbounded main axis (scroll
    /// content). flexLayout then measures non-flex children unbounded too —
    /// a fill-seeking child (Center/Align) must not claim the container's
    /// whole content-derived extent. Bounded measures keep the historical
    /// inner_main bound so ListView-style children still fill a tight flex.
    m_main_unbounded: bool = false,
    impure_descendant: bool = false,
    /// Last global layout epoch this node was laid out in. A global
    /// layout-affecting switch (text direction flip) bumps the epoch so a
    /// clean subtree at unchanged bounds still re-runs once.
    layout_gen: u64 = 0,
    visible: bool = true, // invisible subtrees are neither painted nor hit-tested
    /// Flex weight on the parent's main axis (0 = natural size). Set by the
    /// Expanded wrapper (widgets/layout.zig); the flex algorithms distribute
    /// the REMAINING main space to flex children by weight.
    flex: u32 = 0,
    vtable: *const VTable,
    state: ?*anyopaque = null,
    /// Accessibility descriptor (Phase 2c, owned — freed at deinit). Widgets
    /// attach one in their factory; the semantic tree flattens the widget
    /// tree for assistive tech.
    semantics: ?*semantics_mod.Semantics = null,
    /// Hide this subtree from the semantic tree (decorative, Phase 2c).
    exclude_semantics: bool = false,
    /// Internal chrome owned by a widget (a tooltip bubble, a popup): the
    /// node is part of the tree (paint/hit-test) but is NOT document data —
    /// the registry's treeToValue skips it (the widget rebuilds it).
    internal: bool = false,
    /// Signals bound via ui.state.bindNode — auto-unsubscribed in deinitBody
    /// (BEFORE the vtable deinit frees widget-owned signals). Untyped: the
    /// SignalBase lives in state.zig, which already imports this file.
    bound_signals: std.ArrayListUnmanaged(*anyopaque) = .empty,
    /// Defer this node's paint to the popup overlay pass: the parent's
    /// children paint loop skips it, and the host paints the open popup's
    /// paint_overlay hook AFTER the tree — so popup content overflowing its
    /// anchor (a menu panel over later siblings) renders above them. The
    /// node still hit-tests normally (the router's popup barrier hit-tests
    /// popup children outside the ancestor-bounds gate).
    defer_paint: bool = false,
    /// Subtree contains a node with a paint_overlay hook (popup content that
    /// paints above the whole tree). Maintained by create/add so the overlay
    /// pass prunes subtrees that can't contain one — a tree without popups
    /// costs O(1) instead of a full walk every frame.
    overlay_subtree: bool = false,
    /// Subtree contains a reads_backdrop paint hook (a backdrop filter): its
    /// pixels depend on content drawn OUTSIDE the subtree, so the subtree
    /// can never be auto-retained into a transparent-start image. Mirrors
    /// overlay_subtree's upward propagation; sticky like it (removal keeps
    /// the flag — an over-blocked subtree is always safe).
    backdrop_subtree: bool = false,
    /// Dirty-mark dedup stamps: markDirtyUp/markLayoutDirty set them to the
    /// current mark_epoch as they walk, and stop at a node already stamped
    /// this epoch — its ancestor chain is guaranteed still marked, because
    /// dirty/layout_dirty flags only ever clear INSIDE a paint()/layout()
    /// traversal, which bumps the epoch at pass end (invalidating every
    /// stamp) and holds in_clearing_pass > 0 (bypassing the early-out —
    /// mid-pass marks re-walk, preserving the "mark during paint survives
    /// to the next frame" contract).
    /// dirty_mark_gen: "my ancestor FLAG chain is already marked this
    /// epoch" (set on every walked node — ancestors' own paint rects are
    /// NOT implied). dirty_self_gen: "this node's full markDirty —
    /// flag chain AND own paint rect — already ran this epoch".
    dirty_mark_gen: u32 = 0,
    dirty_self_gen: u32 = 0,
    layout_mark_gen: u32 = 0,
    /// The paint rect unioned into root damage by the last markDirty this
    /// epoch — a repeat mark after the rect moved must damage BOTH
    /// positions (the old pixels need erasing).
    damage_src: Rect = .{},
    // Dirty-rect (Phase 1e): the root accumulates the damaged region — the
    // union of every dirty mark's rect — and the host repaints the tree
    // clipped to it (the surface is retained between frames).
    damage: Rect = .{},
    damage_valid: bool = false,
    // Retained-subtree cache (Phase 4e.2): opt-in via `retained`, or managed
    // by the traversal when the vtable declares `auto_retain`. The subtree's
    // paint is rasterized once into a ctx image and re-blit while the
    // subtree stays clean — the per-item texture idiom every retained
    // framework applies (QSG item textures, Compose layers). The image
    // covers the subtree's PAINT EXTENT (paintExtent) snapped out to integer
    // pixels: the blit lands on a pixel boundary, so cached output is a
    // bit-exact copy of a direct paint — no subpixel sampling shift. Any
    // dirty mark in the subtree or a paintRect size change re-rasterizes.
    retained: bool = false,
    retained_image: u64 = 0,
    /// Row-atlas mode (ABI 0.18.0): the subtree rasterized into a slot of
    /// the shared atlas texture instead of its own image — no per-row
    /// texture upload, and blits sprite-batch into one submission.
    retained_atlas: bool = false,
    retained_slot: [4]f32 = .{ 0, 0, 0, 0 },
    /// Owner ctx + its instance serial. A ctx address is recycled on
    /// recreate — frees and "same owner" checks must key on the serial
    /// (ctxSerialAlive), never the pointer (UAF / ABA on a dead ctx).
    retained_ctx: ?*kx.Ctx = null,
    retained_serial: u64 = 0,
    /// Atlas generation at alloc time: kx_atlas_recreate resets the shelf
    /// layout — a stale-gen slot freed into it corrupts the allocator.
    retained_gen: u32 = 0,
    retained_w: i32 = 0, // image extent in logical units (device px inside)
    retained_h: i32 = 0,
    /// Canvas device scale the retained raster was produced at (ABI 0.19.0
    /// passes rasterize at device density): quarter-step quantized. A scale
    /// change (drag to another display, scale animation) invalidates the
    /// cache — re-blitting it would upscale stale-density pixels.
    retained_ds: u16 = 0,
    retained_ix: f32 = 0, // image origin in this node's parent space (integer)
    retained_iy: f32 = 0,
    /// The paintRect at rasterize time: a rigid move (same size) re-blit the
    /// image at the shifted origin; a size change re-rasterizes.
    retained_pr: Rect = .{},
    /// Auto-retain bail-out: the snapped extent exceeded AUTO_RETAIN_MAX_PX
    /// (a giant subtree would rasterize megabytes for a blit pricier than
    /// the draw ops it replaces). Stays set while the subtree is clean —
    /// re-evaluated after the next dirty frame.
    retained_blocked: bool = false,
    /// Optional solid backdrop composited INTO the retained raster before the
    /// subtree paints: the cached image becomes fully opaque, so its blit can
    /// use Src (no destination read) and a full-coverage root blit lets the
    /// frame loop skip its clear. Correct only where the backdrop behind the
    /// node is constant (roots, nodes over a solid frame background).
    retained_bg: ?u32 = null,
    /// Per-instance opt-in to the vtable's `auto_retain` policy (same rules:
    /// rasterize on a clean frame, drop the cache on dirty frames without
    /// wasting a raster). A container type can mark ITS item children this
    /// way without forcing the flag onto every node of the child's vtable —
    /// e.g. list rows re-blit while scrolling, which is the item-texture
    /// idiom, but the same row type used elsewhere need not be cached.
    auto_retain: bool = false,
    /// Paint that extends BEYOND the bounds (a floating label's upper half,
    /// a cutout stroke margin): markDirty damages the bounds EXPANDED by
    /// these insets (negative values would shrink — never set them). Widgets
    /// painting outside their bounds set this so focus/state changes repaint
    /// the overflow too (2d.2 PR C2: the outlined text field's cutout label).
    damage_overflow: layout_mod.EdgeInsets = .{},
    /// Destroyed (deinit called). During a traversal the node keeps its
    /// memory until the outermost traversalEnd sweeps the queue — traversals
    /// skip zombies instead of dereferencing freed memory (the UAF class: a
    /// handler that tears down a node the dispatch loop is still walking).
    zombie: bool = false,
    /// The subtree teardown ran; only the struct free is pending. Guards
    /// against a second teardown when a node is reached both through a
    /// parent's eager recursion and through its own queue slot.
    torn_down: bool = false,

    pub fn create(allocator: std.mem.Allocator, vtable: *const VTable) !*Node {
        const node = try allocator.create(Node);
        node.* = .{
            .allocator = allocator,
            .children = std.array_list.Managed(*Node).init(allocator),
            .vtable = vtable,
            .overlay_subtree = vtable.paint_overlay != null,
            .backdrop_subtree = vtable.reads_backdrop,
        };
        return node;
    }

    /// Append a child. OOM while building the tree is fatal (same as Flutter).
    pub fn add(node: *Node, child: *Node) void {
        // Cycle check: attaching an ancestor (or self) would recurse
        // forever in paint/layout/deinit. Refuse in release too — a
        // corrupted tree is worse than a dropped attach.
        var anc: ?*Node = node;
        while (anc) |a| : (anc = a.parent) {
            std.debug.assert(a != child); // add() cycle: child is an ancestor
            if (a == child) return;
        }
        // Detach from a previous parent — otherwise the child stays in two
        // children lists and both deinit it (double free).
        if (child.parent) |prev| _ = prev.remove(child);
        child.parent = node;
        // The stamps only ever mean "my CURRENT ancestor chain is marked" —
        // reparenting swaps the chain, so they must not early-out here.
        child.dirty_mark_gen = 0;
        child.dirty_self_gen = 0;
        child.layout_mark_gen = 0;
        node.children.append(child) catch @panic("klaxon: out of memory");
        if (child.overlay_subtree) node.markOverlayUp();
        if (child.backdrop_subtree) node.markBackdropUp();
        if (!(child.vtable.measure_pure and !child.impure_descendant))
            node.markImpureUp();
        node.markLayoutDirty();
        // Damage the CHILD's rect, not the parent's — a 640×480 list would
        // otherwise repaint wholesale per row mutation (the krausest-style
        // list ops were floored by this). A not-yet-laid-out child has a
        // zero rect; layout's own bounds-change damage covers it landing.
        child.markDirty();
    }

    /// Propagate "subtree is not fully measure-pure" up the chain (stops at
    /// the first ancestor already flagged). Once set it stays set — a removed
    /// impure child leaves the flag behind rather than recomputing the whole
    /// subtree (conservative: the cost is lost caching, never stale sizes).
    fn markImpureUp(node: *Node) void {
        var n = node;
        while (true) {
            if (n.impure_descendant) return;
            n.impure_descendant = true;
            n.m_valid = false; // a measure cached while pure may now be stale
            const p = n.parent orelse return;
            n = p;
        }
    }

    /// Insert a child at `index` (clamped to the end). Same ownership contract
    /// as add(): the child is parented, not owned. Re-insertion at the original
    /// index restores paint order (hero flight, Phase 2a).
    pub fn insert(node: *Node, index: usize, child: *Node) void {
        var anc: ?*Node = node;
        while (anc) |a| : (anc = a.parent) {
            std.debug.assert(a != child); // insert() cycle: child is an ancestor
            if (a == child) return;
        }
        if (child.parent) |prev| _ = prev.remove(child);
        child.parent = node;
        child.dirty_mark_gen = 0;
        child.dirty_self_gen = 0;
        child.layout_mark_gen = 0;
        const i = @min(index, node.children.items.len);
        node.children.insert(i, child) catch @panic("klaxon: out of memory");
        if (child.overlay_subtree) node.markOverlayUp();
        if (child.backdrop_subtree) node.markBackdropUp();
        if (!(child.vtable.measure_pure and !child.impure_descendant))
            node.markImpureUp();
        node.markLayoutDirty();
        child.markDirty(); // child-scoped damage — see add()
    }

    /// Remove a child. The child is NOT deinited (the caller owns it) and its
    /// parent pointer is cleared. Returns false if it was not a child.
    /// Dynamic UI (conditional children, theme rebuilds) needs this: the tree
    /// is retained, but subtrees come and go.
    pub fn remove(node: *Node, child: *Node) bool {
        for (node.children.items, 0..) |c, i| {
            if (c == child) {
                _ = node.children.orderedRemove(i);
                // Damage the leaving child's rect (its last pixels must
                // repaint) — not the whole parent. The parent chain is
                // still intact for the damage walk.
                child.markDirty();
                // A pointer captured inside the leaving subtree transfers
                // to this node — the gesture keeps bubbling to scrollable
                // ancestors instead of dying at the next event.
                input_mod.captureOnDetach(child, node);
                child.parent = null;
                node.markLayoutDirty();
                return true;
            }
        }
        return false;
    }

    /// Detach `count` children starting at `start` into `out` — the caller
    /// owns them (same contract as remove: NOT deinited). One array shift
    /// for the whole range instead of one per child — the
    /// notifyItemRangeRemoved idiom. Returns how many were detached.
    pub fn removeRange(node: *Node, start: usize, count: usize, out: []*Node) usize {
        const total = node.children.items.len;
        const s = @min(start, total);
        const n = @min(count, @min(out.len, total - s));
        for (node.children.items[s .. s + n], out[0..n]) |c, *slot| {
            // Damage each leaving rect (the parent chain is still intact
            // for the walk); dedup makes the repeated ancestor marks cheap.
            c.markDirty();
            input_mod.captureOnDetach(c, node); // see remove()
            c.parent = null;
            slot.* = c;
        }
        const tail = node.children.items[s + n .. total];
        std.mem.copyForwards(*Node, node.children.items[s .. s + tail.len], tail);
        node.children.items.len -= n;
        if (n > 0) node.markLayoutDirty();
        return n;
    }

    fn markDirtyUp(node: *Node) void {
        var n = node;
        while (true) {
            // Early-out only outside a clearing pass: inside paint()/
            // layout() an ancestor may have been cleared earlier in the
            // pass, so the full re-walk is required (a dirty descendant
            // under a clean ancestor must re-mark the chain or a retained
            // ancestor would blit its stale image).
            if (in_clearing_pass == 0 and n.dirty_mark_gen == mark_epoch) return;
            n.dirty_mark_gen = mark_epoch;
            n.dirty = true;
            const p = n.parent orelse return;
            n = p;
        }
    }

    /// Propagate an overlay-capable subtree up the parent chain (stops at the
    /// first ancestor already flagged — everything above it is too).
    fn markOverlayUp(node: *Node) void {
        var n = node;
        while (true) {
            if (n.overlay_subtree) return;
            n.overlay_subtree = true;
            const p = n.parent orelse return;
            n = p;
        }
    }

    /// Same propagation for backdrop-reading subtrees (auto-retain must not
    /// cache them — their pixels depend on content outside the image).
    fn markBackdropUp(node: *Node) void {
        var n = node;
        while (true) {
            if (n.backdrop_subtree) return;
            n.backdrop_subtree = true;
            const p = n.parent orelse return;
            n = p;
        }
    }

    fn unionDamage(root: *Node, rect: Rect) void {
        if (rect.w <= 0 or rect.h <= 0) return;
        root.damage = if (root.damage_valid) rectUnion(root.damage, rect) else rect;
        root.damage_valid = true;
    }

    /// Map a rect (given in the node's parent space) up to the root, applying
    /// every transformed ancestor's map_paint_rect, and union it into the
    /// root's damage accumulator.
    fn damageRectUp(node: *Node, rect: Rect) void {
        var r = rect;
        var n = node;
        while (n.parent) |p| {
            // Skip the hook on a mid-construction ancestor — its state is
            // not assigned yet and every map_paint_rect impl derefs it. The
            // damage is provisional anyway: first layout+paint sets the
            // real bounds, and a stateless transform is identity here.
            if (p.vtable.map_paint_rect) |m| {
                if (p.state != null) r = m(p, r);
            }
            n = p;
        }
        unionDamage(n, r);
    }

    /// Mark this node (and its ancestors) dirty. The node's paint rect
    /// (paint_bounds, or the bounds expanded by damage_overflow) — mapped
    /// to its visible position through any transformed ancestors — is
    /// unioned into the root's damage region.
    pub fn markDirty(node: *Node) void {
        // A repeat markDirty on the same node within one mark epoch is
        // idempotent ONLY while the paint rect is unchanged — a node moved
        // by layout mid-epoch must union the new rect AND re-damage the
        // old one (its pixels are stale) instead of early-outing.
        const pr = node.paintRect();
        if (in_clearing_pass == 0 and node.dirty_self_gen == mark_epoch) {
            const o = node.damage_src;
            if (o.x == pr.x and o.y == pr.y and o.w == pr.w and o.h == pr.h) return;
            damageRectUp(node, o);
            damageRectUp(node, pr);
            node.damage_src = pr;
            return;
        }
        markDirtyUp(node);
        damageRectUp(node, pr);
        node.damage_src = pr;
        node.dirty_self_gen = mark_epoch;
    }

    /// Mark dirty + record an explicit damaged rect (given in the node's
    /// parent space) — e.g. an animated offset sweeping old → new position:
    /// the union of both regions.
    pub fn markDirtyRect(node: *Node, rect: Rect) void {
        markDirtyUp(node);
        damageRectUp(node, rect);
    }

    /// Clear the root's damage accumulator (called by the host after painting).
    pub fn clearDamage(node: *Node) void {
        node.damage = .{};
        node.damage_valid = false;
    }

    pub fn markLayoutDirty(node: *Node) void {
        // The cache drops on EVERY mark, stamped or not: a measure() could
        // have repopulated it mid-epoch (a test measuring between ticks —
        // in a real tree measure only runs inside clearing passes, where
        // marks never early-out anyway).
        node.m_valid = false;
        // Same stamp rule as markDirtyUp — outside a clearing pass a
        // stamped node's chain is already layout-dirty; inside a pass the
        // walk must run or a pruned subtree's pending relayout strands.
        if (in_clearing_pass == 0 and node.layout_mark_gen == mark_epoch) return;
        node.layout_mark_gen = mark_epoch;
        node.layout_dirty = true;
        if (node.parent) |p| p.markLayoutDirty();
    }

    pub fn measure(node: *Node, c: Constraints) Size {
        if (node.m_valid and std.meta.eql(node.m_constraints, c))
            return node.m_size;
        const s = node.vtable.measure(node, c);
        // Only a fully measure-pure subtree may cache: a cached container
        // would skip measuring an impure descendant entirely, freezing the
        // size it silently changed (the storm rows' frame-driven width is
        // exactly that input — declared impure, they always re-measure).
        if (node.vtable.measure_pure and !node.impure_descendant) {
            node.m_constraints = c;
            node.m_size = s;
            node.m_valid = true;
        }
        return s;
    }

    pub fn layout(node: *Node, bounds: Rect) void {
        clearingPassEnter();
        defer clearingPassExit();
        // Damage-scoped layout: a clean subtree at unchanged bounds produces
        // the same child positions — every layout is a pure function of its
        // bounds + children, and layout_dirty propagates UP, so a dirty leaf
        // re-lays its ancestors but skips clean siblings entirely.
        if (!node.layout_dirty and node.layout_gen == layout_epoch and
            node.bounds.x == bounds.x and node.bounds.y == bounds.y and
            node.bounds.w == bounds.w and node.bounds.h == bounds.h) return;
        node.layout_gen = layout_epoch;
        // A bounds change is a visual mutation: damage old ∪ new paint rect
        // so the next frame repaints the moved/resized region — without
        // this a relayout could shift content with zero damage (a clean
        // retained subtree would even replay stale pixels at the old spot).
        if (node.bounds.x != bounds.x or node.bounds.y != bounds.y or
            node.bounds.w != bounds.w or node.bounds.h != bounds.h)
        {
            const old = node.paintRect();
            node.bounds = bounds;
            node.layout_dirty = false;
            // rectUnion with an empty operand anchors at its (x, y) — a fresh
            // node's (0,0,0,0) would poison the union — so union only when
            // both sides carry area.
            const new = node.paintRect();
            node.markDirtyRect(if (old.w <= 0 or old.h <= 0) new else if (new.w <= 0 or new.h <= 0) old else rectUnion(old, new));
        } else {
            node.bounds = bounds;
            node.layout_dirty = false;
        }
        node.vtable.layout(node, bounds);
    }

    /// The region a node's own paint can touch, in its bounds space: the
    /// vtable's paint_bounds when declared, else the bounds expanded by
    /// damage_overflow — the same rect markDirty damages. Paint outside it
    /// is a contract violation (damage tracking already misses it), so the
    /// cull test below can trust it.
    pub fn paintRect(node: *Node) Rect {
        if (node.vtable.paint_bounds) |pb| return pb(node);
        const o = node.damage_overflow;
        return .{
            .x = node.bounds.x - o.left,
            .y = node.bounds.y - o.top,
            .w = node.bounds.w + o.left + o.right,
            .h = node.bounds.h + o.top + o.bottom,
        };
    }

    /// The region this node's whole subtree can paint into, in the node's
    /// PARENT space — the union of every visible descendant's paintRect,
    /// mapped through the intermediate paint transforms and tightened by
    /// each child's declared clip. It mirrors the cull rules in paint():
    /// a descendant's extent under a scroll viewport is intersected with
    /// child_clip, and a transformed wrapper's children contribute their
    /// mapped rect. Paint outside this box already violates the damage
    /// contract, so the retained raster can cover it exactly.
    /// `include_deferred`: defer_paint children paint in the popup overlay
    /// pass, not inside paintContent — the damage contract still covers
    /// their pixels (a show/hide must repaint where they appeared), but a
    /// retained image never contains them.
    pub fn paintExtent(node: *Node, include_deferred: bool) Rect {
        var ext: Rect = .{};
        var seeded = false;
        unionExtent(&ext, &seeded, node.paintRect());
        node.extendSubtreeExtent(&ext, &seeded, include_deferred);
        return ext;
    }

    /// rectUnion that ignores empty operands: they paint no pixels, and an
    /// empty rect's origin would otherwise anchor (inflate) the union — a
    /// zero-size node at (0,0) must not stretch a distant child's extent.
    fn unionExtent(ext: *Rect, seeded: *bool, r: Rect) void {
        if (r.w <= 0 or r.h <= 0) return;
        ext.* = if (seeded.*) rectUnion(ext.*, r) else r;
        seeded.* = true;
    }

    fn extendSubtreeExtent(node: *Node, ext: *Rect, seeded: *bool, include_deferred: bool) void {
        for (node.children.items) |child| {
            if (!child.visible or child.zombie) continue;
            if (child.defer_paint and !include_deferred) continue;
            // Child's extent lives in this node's child space → map into
            // parent space, then apply this node's clip (it bounds what
            // any descendant can reach — same as paint()'s child_region).
            var r = child.paintExtent(include_deferred);
            if (node.vtable.map_paint_rect) |m| r = rectNormalize(m(node, r));
            if (node.vtable.child_clip) |cc| r = rectIntersect(r, cc(node));
            unionExtent(ext, seeded, r);
        }
    }

    /// Toggle visibility — a visual mutation of the whole subtree. Damage
    /// the subtree's paint extent: hiding must repaint where it WAS drawn,
    /// showing where it WILL be. A hidden descendant contributes nothing
    /// (it painted nothing), matching the traversal's skip.
    pub fn setVisible(node: *Node, v: bool) void {
        if (node.visible == v) return;
        node.visible = v;
        node.markDirtyRect(node.paintExtent(true));
    }

    /// Paint the subtree and clear dirty flags. `visible` is the region the
    /// frame can reach, in ROOT space (the space the root's bounds and the
    /// damage accumulator live in): the damage rect for a clipped repaint,
    /// the surface rect for a full one. Off-region work is culled before any
    /// draw op is issued:
    ///
    /// - own paint is skipped when the node's paintRect — mapped to the root
    ///   through the transformed ancestors' map_paint_rect — misses `visible`;
    /// - the children pass (pre/loop/post hooks) is skipped wholesale when the
    ///   node's child_clip ∩ visible is empty (the canvas clip makes any
    ///   descendant output unreachable);
    /// - otherwise each child is visited and culled on its own mapped rect —
    ///   a child CAN paint outside its parent's bounds (a tooltip bubble).
    ///
    /// Culling changes no visible output: Skia's rasterizer already drops the
    /// same ops after their (expensive) issue. A culled node keeps its dirty
    /// flag — like an invisible one, it repaints when it becomes visible.
    pub fn paint(node: *Node, ctx: *kx.Ctx, visible: Rect) void {
        // Entry points (frame root, popup overlay, one-off paints) probe the
        // ancestor chain once; the recursion then passes the composed affine
        // down instead of re-walking ancestors per node.
        paintInner(node, ctx, visible, node.mapRectToRoot(.{ .x = 0, .y = 0, .w = 1, .h = 1 }));
    }

    /// paint with the strict-ancestors' affine already composed.
    fn paintInner(node: *Node, ctx: *kx.Ctx, visible: Rect, aff: PaintAff) void {
        if (!node.visible or node.zombie) return;
        clearingPassEnter();
        defer clearingPassExit();
        // The region descendants can paint into: `visible`, tightened by the
        // node's children clip (viewport) when it declares one.
        var child_region = visible;
        if (node.vtable.child_clip) |cc| {
            child_region = rectIntersect(visible, affApply(aff, cc(node)));
        }
        const own_hit = rectOverlaps(affApply(aff, node.paintRect()), visible);
        const children_hit = child_region.w > 0 and child_region.h > 0;
        if (!own_hit and !children_hit) return; // the whole subtree is off-region
        // Clear BEFORE painting: a markDirty raised while this subtree paints
        // (paint hook → signal write → subscriber) must survive to schedule
        // the next frame — a tail clear would wipe it.
        const subtree_dirty = node.dirty;
        node.dirty = false;
        // Retained-subtree replay. Opt-in (`retained`) rasterizes on dirty
        // frames and re-blits clean ones; vtable-declared `auto_retain`
        // engages ONLY on a clean frame — a dirty auto subtree drops its
        // cache and paints directly (its content changes too often to
        // re-rasterize every frame). Either way the node must honour the
        // paint-extent contract — the image holds exactly what the subtree
        // draws, so a cached blit is indistinguishable from a repaint.
        if (node.retained) {
            if (node.paintRetained(ctx, subtree_dirty, false, aff)) return;
        } else if ((node.vtable.auto_retain or node.auto_retain) and !node.backdrop_subtree) {
            if (subtree_dirty) {
                node.retained_blocked = false; // re-evaluate on the next clean pass
                node.clearRetained(); // the stale image can never blit again
            } else if (!node.retained_blocked and !autoRetainOffscreenExpensive(ctx) and
                node.paintRetained(ctx, false, true, aff))
            {
                return;
            }
        }
        node.paintContent(ctx, own_hit, child_region, children_hit, aff);
    }

    /// Backend cost model for AUTO-retain (not the explicit `retained` flag —
    /// an app opting in keeps its semantics): on Ganesh-GLES-class renderers
    /// an offscreen pass + texture upload + one blit costs measurably more
    /// than re-emitting a small subtree's few ops (bench emulator: retained
    /// list rows 1.05ms vs 0.25 direct). Skip auto-retain there entirely;
    /// raster/Graphite keep it — their per-op and upload costs are low.
    fn autoRetainOffscreenExpensive(ctx: *kx.Ctx) bool {
        const b = kx.c.kx_backend_of(ctx);
        return b == kx.c.KX_BACKEND_GANESH_GLES or b == kx.c.KX_BACKEND_GANESH_WEBGL2;
    }

    var atlas_off: ?bool = null; // env latch — KX_NO_ATLAS for A/B
    fn atlasEnabled() bool {
        if (atlas_off == null) atlas_off = std.c.getenv("KX_NO_ATLAS") != null;
        return !atlas_off.?;
    }

    // Debug env-gates latched once — getenv walks environ on every call and
    // paintContent/paintRetained run per node per frame.
    var dbg_paint_child: ?bool = null;
    fn dbgPaintChild() bool {
        if (dbg_paint_child == null) dbg_paint_child = std.c.getenv("KLAXON_DBG_PAINT_CHILD") != null;
        return dbg_paint_child.?;
    }
    var dbg_retained: ?bool = null;
    fn dbgRetained() bool {
        if (dbg_retained == null) dbg_retained = std.c.getenv("KLAXON_DBG_RETAINED") != null;
        return dbg_retained.?;
    }

    /// A rect-affine map packed as a Rect (x=dx, y=dy, w=sx, h=sy). Every
    /// map_paint_rect impl is rect-affine — translate or uniform scale — so
    /// the composed map applied to the unit rect IS the affine.
    /// The paint traversal propagates one composed affine down the tree —
    /// replacing the per-node ancestors walk (mapRectToRoot) with an O(1)
    /// rect transform while keeping every visit/hook semantic identical.
    const PaintAff = Rect;

    /// Probe a node's OWN map_paint_rect as an affine (identity when none).
    fn ownAffine(node: *Node) PaintAff {
        const unit = Rect{ .x = 0, .y = 0, .w = 1, .h = 1 };
        return if (node.vtable.map_paint_rect) |m| rectNormalize(m(node, unit)) else unit;
    }

    /// outer ∘ inner — apply `inner` first (child space → parent space).
    fn affCompose(outer: PaintAff, inner: PaintAff) PaintAff {
        return .{
            .x = outer.x + inner.x * outer.w,
            .y = outer.y + inner.y * outer.h,
            .w = inner.w * outer.w,
            .h = inner.h * outer.h,
        };
    }

    /// Apply a probed affine to a rect.
    fn affApply(aff: PaintAff, r: Rect) Rect {
        return rectNormalize(.{
            .x = aff.x + r.x * aff.w,
            .y = aff.y + r.y * aff.h,
            .w = r.w * aff.w,
            .h = r.h * aff.h,
        });
    }

    /// The draw pass: own paint + the children pass (pre/loop/post hooks) —
    /// shared by the direct path and the retained rasterization.
    fn paintContent(node: *Node, ctx: *kx.Ctx, own_hit: bool, child_region: Rect, children_hit: bool, aff: PaintAff) void {
        const dbg = dbgPaintChild();
        if (own_hit) {
            if (dbg) {
                const t0 = sdl.c.SDL_GetTicksNS();
                node.vtable.paint(node, ctx);
                const us = (sdl.c.SDL_GetTicksNS() - t0) / 1000;
                if (us > 5) std.debug.print("    own {*} {d}x{d} = {d}us\n", .{ node, node.bounds.w, node.bounds.h, us });
            } else node.vtable.paint(node, ctx);
        }
        if (children_hit) {
            if (node.vtable.scroll_children_paint) |sc| {
                if (dbg) {
                    const t0 = sdl.c.SDL_GetTicksNS();
                    const consumed = sc(node, ctx, child_region);
                    const us = (sdl.c.SDL_GetTicksNS() - t0) / 1000;
                    if (us > 5) std.debug.print("    scrollcp {*} = {d}us\n", .{ node, us });
                    if (consumed) return;
                } else if (sc(node, ctx, child_region)) return;
            }
            if (node.vtable.pre_children_paint) |pre| pre(node, ctx);
            // Iterate by INDEX, re-reading `items` each step — a paint hook
            // running a subscriber may add/remove children (the traversal
            // freeze only defers deinit); a captured slice would dangle on
            // an append-realloc or skip/double on a remove-shift.
            const kids_aff = affCompose(aff, ownAffine(node));
            var ci: usize = 0;
            while (ci < node.children.items.len) : (ci += 1) {
                const child = node.children.items[ci];
                if (child.defer_paint or child.zombie) continue; // defer_paint → popup overlay; zombie → swept
                if (dbg) {
                    const t0 = sdl.c.SDL_GetTicksNS();
                    paintInner(child, ctx, child_region, kids_aff);
                    const us = (sdl.c.SDL_GetTicksNS() - t0) / 1000;
                    if (us > 5) std.debug.print("    child {*} {d}x{d} = {d}us\n", .{ child, child.bounds.w, child.bounds.h, us });
                } else paintInner(child, ctx, child_region, kids_aff);
            }
            if (node.vtable.post_children_paint) |post| post(node, ctx);
        }
    }

    /// Retained-subtree paint: re-blit the cached raster while the subtree
    /// stays clean; re-rasterize through an offscreen pass when dirty or
    /// resized. `auto` = the vtable-declared auto-retain path (extent-capped;
    /// sets retained_blocked when the image would be too big to be a win).
    /// Returns false when the node must paint directly instead (zero-size
    /// image, over-cap auto extent, or the offscreen pass is unavailable —
    /// e.g. nested inside another retained rasterization).
    fn paintRetained(node: *Node, ctx: *kx.Ctx, subtree_dirty: bool, auto: bool, aff: PaintAff) bool {
        const pr = node.paintRect(); // parent space — the damage-contract rect
        if (node.retained_serial != 0 and node.retained_serial != paint_mod.ctxSerial(ctx) and
            (node.retained_image != 0 or node.retained_atlas))
        {
            node.clearRetained(); // image/slot belongs to another ctx — drop it
        }
        // A clean subtree is rigid: the cached image re-blits at its
        // rasterized origin shifted by the node's move — but only on an
        // exact pixel boundary (a fractional blit would sample-shift the
        // cached content off the direct-paint pixels).
        if (dbgRetained() and !subtree_dirty and node.vtable.auto_retain) {
            std.debug.print("  retainchk {*} img={} atlas={} prw={d:.0}/{d:.0} prh={d:.0}/{d:.0} bx={d} by={d}\n", .{ node, node.retained_image, node.retained_atlas, node.retained_pr.w, pr.w, node.retained_pr.h, pr.h, node.bounds.x, node.bounds.y });
        }
        // Device-scale match: the cached raster is only valid at the
        // density it was rendered for (quarter-step quantized so a scale
        // animation re-rasterizes a bounded number of times).
        const ds_now: u16 = @intFromFloat(@ceil(paint_mod.canvasScale(ctx) * 4));
        if (!subtree_dirty and (node.retained_image != 0 or node.retained_atlas) and
            node.retained_pr.w == pr.w and node.retained_pr.h == pr.h and
            node.retained_ds == ds_now)
        {
            const bx = node.retained_ix + (pr.x - node.retained_pr.x);
            const by = node.retained_iy + (pr.y - node.retained_pr.y);
            if (bx == @floor(bx) and by == @floor(by)) {
                if (node.retained_atlas) {
                    // Inside the ATLAS write pass (this subtree IS being
                    // rasterized into it) the blit would self-sample the
                    // texture being written — paint directly. An offscreen
                    // pass can blit slots freely (different surfaces).
                    if (paint_mod.inAtlasPass(ctx)) return false;
                    // A recreated atlas (gen bump) reset the shelf layout —
                    // this slot's coords point into a dead layout.
                    const img = if (node.retained_gen == paint_mod.atlasGen(ctx))
                        paint_mod.atlasImage(ctx)
                    else
                        0;
                    if (img != 0) {
                        paint_mod.imageDrawRegion(ctx, img, node.retained_slot[0], node.retained_slot[1], node.retained_slot[2], node.retained_slot[3], bx, by, @floatFromInt(node.retained_w), @floatFromInt(node.retained_h));
                        return true;
                    }
                    node.retained_atlas = false; // atlas gone — re-rasterize below
                } else {
                    kx.c.kx_draw_image(ctx, node.retained_image, bx, by, @floatFromInt(node.retained_w), @floatFromInt(node.retained_h));
                    return true;
                }
            }
        }
        // (Re)rasterize. The image covers the subtree's PAINT EXTENT — the
        // union of every descendant's paintRect, transform-mapped and
        // clip-tightened exactly like the paint traversal — snapped OUT to
        // integer pixels so the blit origin sits on a pixel boundary (the
        // cached output is then a bit-exact copy of a direct paint; a
        // fractional origin would shift AA edges ±1). An opaque backdrop
        // (retained_bg) pins the image to the paintRect instead: clearing
        // the whole overflow extent opaque would paint over neighbours.
        const ext = if (node.retained_bg != null) pr else node.paintExtent(false);
        // A NaN/inf extent (widget bounds bug) would trap @intFromFloat in
        // safe builds and UB in release — paint directly instead.
        if (!std.math.isFinite(ext.x) or !std.math.isFinite(ext.y) or
            !std.math.isFinite(ext.w) or !std.math.isFinite(ext.h))
            return false;
        const ix = @floor(ext.x);
        const iy = @floor(ext.y);
        const iw: i32 = @intFromFloat(@ceil(ext.x + ext.w) - ix);
        const ih: i32 = @intFromFloat(@ceil(ext.y + ext.h) - iy);
        if (iw <= 0 or ih <= 0) {
            node.clearRetained(); // don't keep a stale raster for an empty extent
            return true; // nothing reachable — painted
        }
        // u64 product: i32*i32 overflows on big extents (wraps negative →
        // the <= would PASS and attempt a giant atlas alloc).
        const px = @as(u64, @intCast(iw)) * @as(u64, @intCast(ih));
        if (auto and px > AUTO_RETAIN_MAX_PX) {
            node.retained_blocked = true; // too big to be a win — stay direct
            node.clearRetained(); // drop any stale image (smaller extent before)
            return false;
        }
        if (dbgRetained()) std.debug.print("retained miss: {*} dirty={} img={} {d}x{d} ext={d:.0}x{d:.0} y={d:.0}\n", .{ node, subtree_dirty, node.retained_image, iw, ih, ext.w, ext.h, node.bounds.y });
        // Drop the stale image first so a failed pass can't resurrect a
        // stale blit on a later frame.
        node.clearRetained();
        // Retained leaf nodes (list rows etc.) rasterize into a slot of the
        // shared row atlas on GPU backends: the subtree draws straight into
        // the texture — no per-row texture alloc, no upload task, and the
        // blit joins the open sprite batch (one mesh for the whole list).
        // Leaf-scale only: a container-sized subtree keeps the offscreen
        // image path — an offscreen pass may blit ATLAS children inside its
        // regen (different surfaces), so descendants keep their caches;
        // inside an atlas write nothing may sample the atlas (self-sample
        // is illegal on GPU), which would force a full direct repaint.
        const backend = kx.c.kx_backend_of(ctx);
        const use_atlas = backend != kx.c.KX_BACKEND_RASTER and
            px <= 96 * 1024 and
            atlasEnabled() and
            !autoRetainOffscreenExpensive(ctx) and
            paint_mod.atlasBegin(ctx, iw, ih, &node.retained_slot);
        if (!use_atlas and !kx.c.kx_offscreen_begin(ctx, iw, ih)) {
            return false; // nested offscreen pass — paint directly this frame
        }
        if (node.retained_bg) |bg| kx.c.kx_clear(ctx, bg);
        kx.c.kx_translate(ctx, -ix, -iy);
        // The cache must hold EVERYTHING the subtree draws: cull only
        // against the mapped paint extent (the damage-contract bound).
        const mapped = affApply(aff, ext);
        node.paintContent(ctx, true, mapped, true, aff);
        if (use_atlas) {
            paint_mod.atlasEnd(ctx);
            node.retained_atlas = true;
            node.retained_image = 0;
        } else {
            node.retained_image = kx.c.kx_offscreen_end_image(ctx);
            if (node.retained_image == 0) return false; // pass failed — direct paint
        }
        node.retained_ctx = ctx;
        node.retained_serial = paint_mod.ctxSerial(ctx);
        // Captured AFTER the begin/end — an atlas recreate inside bumped
        // the generation (the slot lives in the NEW texture's layout).
        node.retained_gen = if (use_atlas) paint_mod.atlasGen(ctx) else 0;
        node.retained_w = iw;
        node.retained_h = ih;
        node.retained_ds = ds_now;
        node.retained_ix = ix;
        node.retained_iy = iy;
        node.retained_pr = pr;
        if (use_atlas) {
            const img = paint_mod.atlasImage(ctx);
            if (img == 0) {
                node.retained_atlas = false;
                return false;
            }
            paint_mod.imageDrawRegion(ctx, img, node.retained_slot[0], node.retained_slot[1], node.retained_slot[2], node.retained_slot[3], ix, iy, @floatFromInt(iw), @floatFromInt(ih));
        } else {
            kx.c.kx_draw_image(ctx, node.retained_image, ix, iy, @floatFromInt(iw), @floatFromInt(ih));
        }
        return true;
    }

    /// True when this node's next paint is guaranteed to end as a single
    /// opaque blit covering `surface` — so a frame loop can skip its
    /// pre-paint clear (an opaque SrcOver blit overwrites every destination
    /// pixel anyway). Guaranteed either by retained_bg (the raster is built
    /// over a solid backdrop — holds for re-rasterizing dirty frames too) or
    /// by the cached image's scanned content opacity. Only call for
    /// top-level roots (identity CTM, never inside an offscreen pass).
    pub fn retainedBlitCoversSurface(node: *Node, ctx: *kx.Ctx, surface: Rect) bool {
        if (!node.retained) return false;
        const is_opaque = node.retained_bg != null or
            (node.retained_image != 0 and !node.dirty and
                kx.c.kx_image_is_opaque(ctx, node.retained_image) != 0);
        if (!is_opaque) return false;
        const pr = node.paintRect();
        return pr.x <= surface.x and pr.y <= surface.y and
            pr.x + pr.w >= surface.x + surface.w and
            pr.y + pr.h >= surface.y + surface.h;
    }

    /// Drop the cached raster (the image lives in retained_ctx's registry).
    /// retained_blocked is NOT cleared here — it belongs to the auto-retain
    /// policy, which resets it on the next dirty frame.
    fn clearRetained(node: *Node) void {
        if (dbgRetained() and (node.retained_atlas or node.retained_image != 0))
            std.debug.print("  clearRetained {*} atlas={} img={} y={d:.0} h={d:.0}\n", .{ node, node.retained_atlas, node.retained_image, node.bounds.y, node.bounds.h });
        // Free resources only into a LIVE ctx — a destroyed ctx already
        // released them; freeing into a recycled address would be a UAF.
        const live = node.retained_ctx != null and node.retained_serial != 0 and
            paint_mod.ctxSerialAlive(node.retained_serial);
        if (node.retained_image != 0) {
            if (live) kx.c.kx_image_destroy(node.retained_ctx.?, node.retained_image);
            node.retained_image = 0;
        }
        if (node.retained_atlas) {
            // And only while the slot's shelf layout is current — an atlas
            // recreate reset it, so a stale-gen free would corrupt the
            // allocator's free ranges.
            if (live and node.retained_gen == paint_mod.atlasGen(node.retained_ctx.?))
                paint_mod.atlasFree(node.retained_ctx.?, node.retained_slot);
            node.retained_atlas = false;
            node.retained_slot = .{ 0, 0, 0, 0 };
        }
        node.retained_ctx = null;
        node.retained_serial = 0;
        node.retained_gen = 0;
        node.retained_w = 0;
        node.retained_h = 0;
        node.retained_ds = 0;
        node.retained_ix = 0;
        node.retained_iy = 0;
        node.retained_pr = .{};
    }

    /// Deepest visible node containing the point (children are painted last,
    /// on top). Transformed subtrees (animated offset/scale) hit-test at
    /// their VISUAL position: hit_bounds + pre_children_hit mirror the paint
    /// transform.
    pub fn hitTest(node: *Node, px: f32, py: f32) ?*Node {
        if (!node.visible or node.zombie) return null;
        const b = if (node.vtable.hit_bounds) |hb| hb(node) else node.bounds;
        if (!b.contains(px, py)) return null;
        var cx = px;
        var cy = py;
        if (node.vtable.pre_children_hit) |pre| {
            const p = pre(node, px, py);
            cx = p.x;
            cy = p.y;
        }
        var i = node.children.items.len;
        if (node.vtable.hit_child) |hc| {
            if (hc(node, cx, cy)) |child| {
                if (child.hitTest(cx, cy)) |hit| return hit;
            }
            return node;
        }
        while (i > 0) {
            i -= 1;
            const child = node.children.items[i];
            if (child.zombie) continue;
            if (child.hitTest(cx, cy)) |hit| return hit;
        }
        return node;
    }

    /// A hit-test result: the node + the point in the HIT NODE's parent
    /// space (transformed subtrees map viewport coordinates through their
    /// ancestors).
    pub const MappedHit = struct { node: *Node, x: f32, y: f32 };

    /// Hit-test that also returns the point in the hit node's parent space —
    /// the router delivers pointer events with those local coordinates so
    /// scrolled/transformed controls receive events at their visual position.
    pub fn hitTestMapped(node: *Node, px: f32, py: f32) ?MappedHit {
        if (!node.visible or node.zombie) return null;
        const b = if (node.vtable.hit_bounds) |hb| hb(node) else node.bounds;
        if (!b.contains(px, py)) return null;
        var cx = px;
        var cy = py;
        if (node.vtable.pre_children_hit) |pre| {
            const p = pre(node, px, py);
            cx = p.x;
            cy = p.y;
        }
        var i = node.children.items.len;
        if (node.vtable.hit_child) |hc| {
            if (hc(node, cx, cy)) |child| {
                if (child.hitTestMapped(cx, cy)) |hit| return hit;
            }
            return .{ .node = node, .x = px, .y = py };
        }
        while (i > 0) {
            i -= 1;
            const child = node.children.items[i];
            if (child.zombie) continue;
            if (child.hitTestMapped(cx, cy)) |hit| return hit;
        }
        return .{ .node = node, .x = px, .y = py };
    }

    /// Map a window-space point into `node`'s parent space: applies every
    /// strict ancestor's pre_children_hit, root-first. Used to deliver
    /// pointer events with local coordinates to captured nodes (Phase 1f).
    pub fn mapPointToParentSpace(node: *Node, px: f32, py: f32) HitPoint {
        var stack_chain: [64]*Node = undefined;
        var depth: usize = 0;
        var n = node.parent;
        while (n) |p| : (n = p.parent) depth += 1;
        // Deeper than 64: fall back to a heap chain rather than silently
        // dropping ancestors (the transforms then map to the wrong space).
        const chain = if (depth <= stack_chain.len)
            stack_chain[0..depth]
        else
            node.allocator.alloc(*Node, depth) catch {
                // OOM: map without transforms rather than crash — a drag
                // lands offset but the app stays alive.
                return .{ .x = px, .y = py };
            };
        defer if (depth > stack_chain.len) node.allocator.free(chain);
        var i: usize = 0;
        n = node.parent;
        while (n) |p| : (n = p.parent) {
            chain[i] = p;
            i += 1;
        }
        var x = px;
        var y = py;
        while (i > 0) {
            i -= 1;
            const a = chain[i];
            if (a.vtable.pre_children_hit) |pre| {
                const p = pre(a, x, y);
                x = p.x;
                y = p.y;
            }
        }
        return .{ .x = x, .y = y };
    }

    /// Map a rect (in the node's parent space) to window space: applies every
    /// transformed ancestor's map_paint_rect (the visual position). Used by
    /// the focus ring and semantic activation (Phase 2c).
    pub fn mapRectToRoot(node: *Node, rect: Rect) Rect {
        var r = rect;
        var n = node;
        while (n.parent) |p| {
            // A torn-down ancestor's widget state is freed — its hook would
            // dereference dead memory. Treat the zombie chain as the end.
            if (p.torn_down) break;
            if (p.vtable.map_paint_rect) |m| r = rectNormalize(m(p, r));
            n = p;
        }
        return r;
    }

    /// Destroy the subtree. If a traversal is in flight (dispatch, paint,
    /// hit-test, signal notify — anything that might be holding a pointer
    /// to this node) the deinit DEFERS: the node is marked `zombie`, kept in
    /// its parent's child list (memory stays valid, traversals skip it), and
    /// the outermost traversalEnd sweeps the queue. Otherwise the subtree
    /// tears down immediately.
    pub fn deinit(node: *Node) void {
        if (node.zombie) return; // already queued or torn down
        if (traversalActive()) {
            node.zombie = true;
            zombie_list.append(std.heap.c_allocator, node) catch @panic("klaxon: out of memory");
            return;
        }
        // Route through the same sweep: deinit is itself a traversal — a
        // widget deinit that destroys another node defers it.
        traversalBegin();
        node.zombie = true;
        zombie_list.append(std.heap.c_allocator, node) catch @panic("klaxon: out of memory");
        traversalEnd();
    }

    /// Teardown WITHOUT freeing the node struct — callers push the struct
    /// onto pending_free. Children are torn down EAGERLY and recursively
    /// (vtable order: a child's deinit runs while the parent's state is
    /// still alive — e.g. a Hero unregisters from its Navigator's state).
    /// A zombie child is consumed here (its queue slot turns inert) for the
    /// same reason.
    fn deinitBody(node: *Node) void {
        // Drop router references (capture/hover/focus/popup) BEFORE anything
        // is freed — virtualized lists destroy captured items on scroll.
        input_mod.releaseNode(node);
        semantics_mod.focusNodeDestroyed(node); // drop the a11y focus if it was focused (Phase 2c)
        // Drop signal subscriptions BEFORE the vtable deinit frees any
        // widget-owned signals — a dangling .node subscriber would call
        // markDirty on freed memory at the next notify (UAF).
        state_mod.unbindAll(node);
        // Drain with pop(), not a captured slice: a child's vtable deinit
        // can mutate this node's child list (a sibling removing itself)
        // — realloc would dangle the slice, a shift would skip a child.
        while (node.children.pop()) |child| {
            child.parent = null; // detach BEFORE teardown — callbacks walking
            // up from this child must not reach the about-to-be-freed parent
            if (!child.torn_down) {
                // A zombie child is consumed here (its queue slot turns inert):
                // eager recursion keeps the children-before-parent ordering
                // that widget deinits rely on.
                child.torn_down = true;
                child.deinitBody();
                pending_free.append(std.heap.c_allocator, child) catch @panic("klaxon: out of memory");
            }
        }
        node.children.deinit();
        if (node.semantics) |sem| node.allocator.destroy(sem);
        node.clearRetained(); // the ctx image registry outlives this node
        if (node.vtable.deinit) |d| d(node);
    }
};

// --- Deferred destruction -------------------------------------------------
//
// Widget callbacks run during tree traversals (dispatch bubble, paint,
// hit-test, signal notify). A callback that deinits a node being walked
// used to leave the loop dereferencing freed memory. Instead, deinit()
// during a traversal marks the node `zombie` — the memory stays valid, the
// flag tells every traversal to skip it, and the outermost traversalEnd
// sweeps: teardown runs at depth 0 where list mutation is safe.
//
// Two lists: `zombie_list` queues nodes awaiting teardown; `pending_free`
// collects structs whose teardown ran — frees happen in a batch at the end
// so a parent's removal/teardown never leaves a queued sibling pointing at
// freed memory.

var traversal_depth: u32 = 0;
var zombie_list: std.ArrayListUnmanaged(*Node) = .empty;
var pending_free: std.ArrayListUnmanaged(*Node) = .empty;

/// Open a mutation-freeze window: deinit() inside defers to the sweep.
pub fn traversalBegin() void {
    traversal_depth += 1;
}

/// Close the window; at depth 0 the queued zombies are torn down and freed.
/// Balanced — every traversalBegin must reach its traversalEnd (defer).
pub fn traversalEnd() void {
    std.debug.assert(traversal_depth > 0); // unbalanced — every Begin must pair its End
    traversal_depth -|= 1;
    if (traversal_depth != 0) return;
    // Sweeping runs callbacks (vtable deinits can touch the tree): hold a
    // freeze so nested deinits queue onto the list we drain below.
    traversal_depth = 1;
    while (zombie_list.items.len > 0 or pending_free.items.len > 0) {
        var batch = zombie_list;
        zombie_list = .empty;
        for (batch.items) |z| {
            if (z.torn_down) continue; // consumed eagerly by a parent's teardown
            z.torn_down = true;
            // Detach from the parent first — the node stayed listed so far
            // (detaching mid-dispatch would shift the array under an active
            // iteration). remove() at sweep depth is safe.
            if (z.parent) |p| {
                z.parent = null;
                _ = p.remove(z);
            }
            z.deinitBody();
            pending_free.append(std.heap.c_allocator, z) catch @panic("klaxon: out of memory");
        }
        batch.deinit(std.heap.c_allocator);
        for (pending_free.items) |z| z.allocator.destroy(z);
        pending_free.clearRetainingCapacity();
    }
    traversal_depth = 0;
}

/// True while a traversal window is open (dispatch/paint/notify/deinit).
pub fn traversalActive() bool {
    return traversal_depth > 0;
}

// --- tests (stub leaf widget) ---

const TestState = struct { w: f32, h: f32 };

fn testMeasure(n: *Node, c: Constraints) Size {
    const s: *TestState = @ptrCast(@alignCast(n.state.?));
    return c.constrain(.{ .w = s.w, .h = s.h });
}
fn testLayout(n: *Node, bounds: Rect) void {
    _ = n;
    _ = bounds;
}
fn testPaint(n: *Node, ctx: *kx.Ctx) void {
    _ = n;
    _ = ctx;
}
fn testDeinit(n: *Node) void {
    std.testing.allocator.destroy(@as(*TestState, @ptrCast(@alignCast(n.state.?))));
}
const test_vtable = VTable{ .measure = testMeasure, .layout = testLayout, .paint = testPaint, .deinit = testDeinit };

fn testNode(w: f32, h: f32) !*Node {
    const node = try Node.create(std.testing.allocator, &test_vtable);
    const s = try std.testing.allocator.create(TestState);
    s.* = .{ .w = w, .h = h };
    node.state = s;
    return node;
}

test "remove detaches a child without deiniting it" {
    const root = try testNode(100, 100);
    defer root.deinit();
    const a = try testNode(10, 10);
    const b = try testNode(10, 10);
    root.add(a);
    root.add(b);
    try std.testing.expectEqual(@as(usize, 2), root.children.items.len);
    try std.testing.expect(root.remove(a));
    try std.testing.expectEqual(@as(usize, 1), root.children.items.len);
    try std.testing.expectEqual(b, root.children.items[0]);
    try std.testing.expect(a.parent == null);
    try std.testing.expect(!root.remove(a)); // already detached
    a.deinit(); // caller owns the detached child
    // the remaining subtree still deinits cleanly
}

test "insert places a child at the index and keeps paint order" {
    const root = try testNode(100, 100);
    defer root.deinit();
    const a = try testNode(10, 10);
    const b = try testNode(10, 10);
    const c = try testNode(10, 10);
    root.add(a);
    root.add(c);
    root.insert(1, b);
    try std.testing.expectEqual(@as(usize, 3), root.children.items.len);
    try std.testing.expectEqual(a, root.children.items[0]);
    try std.testing.expectEqual(b, root.children.items[1]);
    try std.testing.expectEqual(c, root.children.items[2]);
    try std.testing.expectEqual(root, b.parent.?);
    // clamped past the end
    const d = try testNode(10, 10);
    root.insert(99, d);
    try std.testing.expectEqual(d, root.children.items[3]);
}

test "markDirty propagates up to the root" {
    const root = try testNode(100, 100);
    defer root.deinit();
    const child = try testNode(10, 10);
    root.add(child);
    root.dirty = false;
    bumpMarkEpoch(); // manual flag clear models a completed paint pass
    child.markDirty();
    try std.testing.expect(root.dirty);
    try std.testing.expect(child.dirty);
}

test "hitTest returns the deepest node containing the point" {
    const root = try testNode(100, 100);
    defer root.deinit();
    root.layout(.{ .x = 0, .y = 0, .w = 100, .h = 100 });
    const child = try testNode(50, 50);
    root.add(child);
    child.layout(.{ .x = 10, .y = 10, .w = 50, .h = 50 });
    try std.testing.expectEqual(child, root.hitTest(20, 20).?);
    try std.testing.expectEqual(root, root.hitTest(80, 80).?);
    try std.testing.expect(root.hitTest(200, 200) == null);
}

test "markDirty accumulates the damage region at the root" {
    const root = try testNode(100, 100);
    defer root.deinit();
    root.layout(.{ .x = 0, .y = 0, .w = 100, .h = 100 });
    const child = try testNode(10, 10);
    root.add(child);
    child.layout(.{ .x = 20, .y = 30, .w = 10, .h = 10 });
    root.dirty = false;
    root.clearDamage();
    child.markDirty();
    try std.testing.expect(root.dirty);
    try std.testing.expect(root.damage_valid);
    try std.testing.expectEqual(@as(f32, 20), root.damage.x);
    try std.testing.expectEqual(@as(f32, 30), root.damage.y);
    try std.testing.expectEqual(@as(f32, 10), root.damage.w);
    try std.testing.expectEqual(@as(f32, 10), root.damage.h);
    // a second mark unions into the region (0,0,30,40)
    child.markDirtyRect(.{ .x = 0, .y = 0, .w = 5, .h = 5 });
    try std.testing.expectEqual(@as(f32, 0), root.damage.x);
    try std.testing.expectEqual(@as(f32, 0), root.damage.y);
    try std.testing.expectEqual(@as(f32, 30), root.damage.w);
    try std.testing.expectEqual(@as(f32, 40), root.damage.h);
    // empty rects (pre-layout) never corrupt the region
    root.clearDamage();
    child.markDirtyRect(.{});
    try std.testing.expect(!root.damage_valid);
}

test "rect: contains is half-open; main/cross pick the axis; rectUnion sweeps both" {
    const r = Rect{ .x = 10, .y = 20, .w = 30, .h = 40 };
    try std.testing.expect(r.contains(10, 20)); // the top-left corner is inside
    try std.testing.expect(r.contains(39.9, 59.9));
    try std.testing.expect(!r.contains(40, 30)); // the right edge is exclusive
    try std.testing.expect(!r.contains(20, 60)); // the bottom edge is exclusive
    try std.testing.expect(!r.contains(9.9, 20));
    try std.testing.expectEqual(@as(f32, 30), r.main(.horizontal));
    try std.testing.expectEqual(@as(f32, 40), r.main(.vertical));
    try std.testing.expectEqual(@as(f32, 40), r.cross(.horizontal));
    try std.testing.expectEqual(@as(f32, 30), r.cross(.vertical));
    const u = rectUnion(.{ .x = 0, .y = 0, .w = 10, .h = 10 }, .{ .x = 5, .y = 20, .w = 10, .h = 5 });
    try std.testing.expectEqual(@as(f32, 0), u.x);
    try std.testing.expectEqual(@as(f32, 0), u.y);
    try std.testing.expectEqual(@as(f32, 15), u.w); // spans 0..15
    try std.testing.expectEqual(@as(f32, 25), u.h); // spans 0..25
    // a rect unioned with itself is itself
    try std.testing.expectEqual(r, rectUnion(r, r));
}

test "add parents the child and marks the tree dirty + layout-dirty" {
    const root = try testNode(100, 100);
    defer root.deinit();
    root.dirty = false;
    root.layout_dirty = false;
    const child = try testNode(10, 10);
    root.add(child);
    try std.testing.expectEqual(root, child.parent.?);
    try std.testing.expect(root.dirty);
    try std.testing.expect(root.layout_dirty);
}

test "markLayoutDirty propagates up to the root" {
    const root = try testNode(100, 100);
    defer root.deinit();
    const mid = try testNode(50, 50);
    const leaf = try testNode(10, 10);
    root.add(mid);
    mid.add(leaf);
    root.layout_dirty = false;
    mid.layout_dirty = false;
    bumpMarkEpoch(); // manual flag clear models a completed layout pass
    leaf.markLayoutDirty();
    try std.testing.expect(leaf.layout_dirty);
    try std.testing.expect(mid.layout_dirty);
    try std.testing.expect(root.layout_dirty);
}

// --- paint-pass recording stub (order + visibility assertions) ---

const PaintRec = struct {
    log: *std.array_list.Managed([]const u8),
    name: []const u8, // static literal — safe to store in the log
    pre_name: []u8, // owned ("pre:" ++ name) — the log stores slice pointers
    post_name: []u8, // owned ("post:" ++ name)
    clip: Rect = .{}, // read by rec_clip_vtable's child_clip
};

fn recPaintMeasure(_: *Node, c: Constraints) Size {
    return c.constrain(.{ .w = 10, .h = 10 });
}
fn recPaintPaint(n: *Node, ctx: *kx.Ctx) void {
    _ = ctx;
    const s: *PaintRec = @ptrCast(@alignCast(n.state.?));
    s.log.append(s.name) catch @panic("klaxon: out of memory");
}
fn recPaintPre(n: *Node, ctx: *kx.Ctx) void {
    _ = ctx;
    const s: *PaintRec = @ptrCast(@alignCast(n.state.?));
    s.log.append(s.pre_name) catch @panic("klaxon: out of memory");
}
fn recPaintPost(n: *Node, ctx: *kx.Ctx) void {
    _ = ctx;
    const s: *PaintRec = @ptrCast(@alignCast(n.state.?));
    s.log.append(s.post_name) catch @panic("klaxon: out of memory");
}
fn recPaintDeinit(n: *Node) void {
    const s: *PaintRec = @ptrCast(@alignCast(n.state.?));
    n.allocator.free(s.pre_name);
    n.allocator.free(s.post_name);
    n.allocator.destroy(s);
}
const paint_rec_vtable = VTable{
    .measure = recPaintMeasure,
    .layout = testLayout,
    .paint = recPaintPaint,
    .deinit = recPaintDeinit,
    .pre_children_paint = recPaintPre,
    .post_children_paint = recPaintPost,
};

/// Recording vtable + a child clip (scroll-view-style: the children pass
/// paints inside a canvas clip the hook pushes).
const paint_rec_clip_vtable = blk: {
    var vt = paint_rec_vtable;
    vt.child_clip = struct {
        fn cc(n: *Node) Rect {
            const s: *PaintRec = @ptrCast(@alignCast(n.state.?));
            return s.clip;
        }
    }.cc;
    break :blk vt;
};

/// Recording vtable + a paint transform: children paint translated by
/// (+100, +50) — map_paint_rect mirrors it (like scroll_view's offset).
const paint_rec_shift_vtable = blk: {
    var vt = paint_rec_vtable;
    vt.map_paint_rect = struct {
        fn m(_: *Node, rect: Rect) Rect {
            return .{ .x = rect.x + 100, .y = rect.y + 50, .w = rect.w, .h = rect.h };
        }
    }.m;
    break :blk vt;
};

fn recPaintNodeVtable(log: *std.array_list.Managed([]const u8), name: []const u8, vt: *const VTable) !*Node {
    const node = try Node.create(std.testing.allocator, vt);
    errdefer node.allocator.destroy(node);
    const s = try std.testing.allocator.create(PaintRec);
    errdefer std.testing.allocator.destroy(s);
    s.* = .{
        .log = log,
        .name = name,
        .pre_name = try std.fmt.allocPrint(std.testing.allocator, "pre:{s}", .{name}),
        .post_name = try std.fmt.allocPrint(std.testing.allocator, "post:{s}", .{name}),
    };
    node.state = s;
    return node;
}

fn recPaintNode(log: *std.array_list.Managed([]const u8), name: []const u8) !*Node {
    return recPaintNodeVtable(log, name, &paint_rec_vtable);
}

test "paint: hooks wrap the children pass; invisible + defer_paint subtrees are skipped" {
    const ctx = kx.create(null, 64, 64, kx.c.KX_BACKEND_RASTER) orelse return error.TestUnexpectedResult;
    defer kx.c.kx_destroy(ctx);
    var log = std.array_list.Managed([]const u8).init(std.testing.allocator);
    defer log.deinit();
    const root = try recPaintNode(&log, "root");
    defer root.deinit();
    const child = try recPaintNode(&log, "child");
    const hidden = try recPaintNode(&log, "hidden");
    const deferred = try recPaintNode(&log, "deferred");
    root.add(child);
    root.add(hidden);
    root.add(deferred);
    // Paint culling needs real bounds: an empty rect misses every region.
    root.bounds = .{ .x = 0, .y = 0, .w = 64, .h = 64 };
    child.bounds = .{ .x = 0, .y = 0, .w = 10, .h = 10 };
    hidden.bounds = .{ .x = 0, .y = 0, .w = 10, .h = 10 };
    deferred.bounds = .{ .x = 0, .y = 0, .w = 10, .h = 10 };
    hidden.visible = false;
    deferred.defer_paint = true;
    kx.c.kx_begin_frame(ctx);
    root.paint(ctx, .{ .x = 0, .y = 0, .w = 64, .h = 64 });
    kx.c.kx_end_frame(ctx);
    // own paint → pre → children (defer_paint skipped) → post
    const expected = [_][]const u8{ "root", "pre:root", "child", "pre:child", "post:child", "post:root" };
    try std.testing.expectEqual(expected.len, log.items.len);
    for (expected, log.items) |exp, act| {
        try std.testing.expectEqualStrings(exp, act);
    }
    // the painted nodes clear their dirty flag; the skipped ones keep it
    try std.testing.expect(!root.dirty);
    try std.testing.expect(!child.dirty);
    try std.testing.expect(hidden.dirty);
    try std.testing.expect(deferred.dirty);
}

fn expectLog(log: *std.array_list.Managed([]const u8), expected: []const []const u8) !void {
    try std.testing.expectEqual(expected.len, log.items.len);
    for (expected, log.items) |exp, act| {
        try std.testing.expectEqualStrings(exp, act);
    }
}

test "paint culling: off-region own paint is skipped but children are still visited" {
    const ctx = kx.create(null, 64, 64, kx.c.KX_BACKEND_RASTER) orelse return error.TestUnexpectedResult;
    defer kx.c.kx_destroy(ctx);
    var log = std.array_list.Managed([]const u8).init(std.testing.allocator);
    defer log.deinit();
    const root = try recPaintNode(&log, "root");
    defer root.deinit();
    root.bounds = .{ .x = 0, .y = 0, .w = 10, .h = 10 };
    // "wrapper" is entirely off-region: its own paint is culled — but the
    // traversal still visits its children (a child can paint outside the
    // parent's bounds — the tooltip bubble does).
    const wrapper = try recPaintNode(&log, "wrapper");
    wrapper.bounds = .{ .x = 200, .y = 200, .w = 10, .h = 10 };
    const bubble = try recPaintNode(&log, "bubble");
    bubble.bounds = .{ .x = 0, .y = 0, .w = 10, .h = 10 }; // back inside the region
    wrapper.add(bubble);
    root.add(wrapper);
    const inside = try recPaintNode(&log, "inside");
    inside.bounds = .{ .x = 0, .y = 0, .w = 5, .h = 5 };
    root.add(inside);
    kx.c.kx_begin_frame(ctx);
    root.paint(ctx, .{ .x = 0, .y = 0, .w = 64, .h = 64 });
    kx.c.kx_end_frame(ctx);
    try expectLog(&log, &.{ "root", "pre:root", "pre:wrapper", "bubble", "pre:bubble", "post:bubble", "post:wrapper", "inside", "pre:inside", "post:inside", "post:root" });
}

test "paint culling: child_clip tightens the region and can skip the whole pass" {
    const ctx = kx.create(null, 64, 64, kx.c.KX_BACKEND_RASTER) orelse return error.TestUnexpectedResult;
    defer kx.c.kx_destroy(ctx);
    var log = std.array_list.Managed([]const u8).init(std.testing.allocator);
    defer log.deinit();
    const root = try recPaintNode(&log, "root");
    defer root.deinit();
    root.bounds = .{ .x = 0, .y = 0, .w = 64, .h = 64 };
    // A clipper whose clip rect misses the visible region entirely: the
    // children pass (pre/children/post) is skipped wholesale.
    const away = try recPaintNodeVtable(&log, "away", &paint_rec_clip_vtable);
    away.bounds = .{ .x = 0, .y = 0, .w = 64, .h = 64 };
    (@as(*PaintRec, @ptrCast(@alignCast(away.state.?)))).clip = .{ .x = 200, .y = 200, .w = 10, .h = 10 };
    const hidden_child = try recPaintNode(&log, "hidden_child");
    hidden_child.bounds = .{ .x = 0, .y = 0, .w = 5, .h = 5 };
    away.add(hidden_child);
    root.add(away);
    // A clipper whose clip keeps only the top-left corner: a child outside it
    // is culled against the TIGHTER region even though it hits the surface.
    const corner = try recPaintNodeVtable(&log, "corner", &paint_rec_clip_vtable);
    corner.bounds = .{ .x = 0, .y = 0, .w = 64, .h = 64 };
    (@as(*PaintRec, @ptrCast(@alignCast(corner.state.?)))).clip = .{ .x = 0, .y = 0, .w = 10, .h = 10 };
    const clipped_child = try recPaintNode(&log, "clipped_child");
    clipped_child.bounds = .{ .x = 50, .y = 50, .w = 5, .h = 5 }; // on-surface, off-clip
    corner.add(clipped_child);
    root.add(corner);
    kx.c.kx_begin_frame(ctx);
    root.paint(ctx, .{ .x = 0, .y = 0, .w = 64, .h = 64 });
    kx.c.kx_end_frame(ctx);
    try expectLog(&log, &.{ "root", "pre:root", "away", "corner", "pre:corner", "pre:clipped_child", "post:clipped_child", "post:corner", "post:root" });
}

test "paint culling follows map_paint_rect transforms (visual position, not layout)" {
    const ctx = kx.create(null, 200, 200, kx.c.KX_BACKEND_RASTER) orelse return error.TestUnexpectedResult;
    defer kx.c.kx_destroy(ctx);
    var log = std.array_list.Managed([]const u8).init(std.testing.allocator);
    defer log.deinit();
    const root = try recPaintNode(&log, "root");
    defer root.deinit();
    root.bounds = .{ .x = 0, .y = 0, .w = 200, .h = 200 };
    const shifted = try recPaintNodeVtable(&log, "shifted", &paint_rec_shift_vtable);
    shifted.bounds = .{ .x = 0, .y = 0, .w = 200, .h = 200 };
    root.add(shifted);
    // Layout-space (0,0,10,10) paints at (100,50,10,10) — inside the region.
    const on = try recPaintNode(&log, "on");
    on.bounds = .{ .x = 0, .y = 0, .w = 10, .h = 10 };
    shifted.add(on);
    // Layout-space (-300,-200,10,10) paints at (-200,-150,10,10) — off-region.
    const off = try recPaintNode(&log, "off");
    off.bounds = .{ .x = -300, .y = -200, .w = 10, .h = 10 };
    shifted.add(off);
    kx.c.kx_begin_frame(ctx);
    root.paint(ctx, .{ .x = 0, .y = 0, .w = 200, .h = 200 });
    kx.c.kx_end_frame(ctx);
    try expectLog(&log, &.{ "root", "pre:root", "shifted", "pre:shifted", "on", "pre:on", "post:on", "pre:off", "post:off", "post:shifted", "post:root" });
}

test "paint culling honors damage_overflow (paint legitimately outside bounds)" {
    const ctx = kx.create(null, 64, 64, kx.c.KX_BACKEND_RASTER) orelse return error.TestUnexpectedResult;
    defer kx.c.kx_destroy(ctx);
    var log = std.array_list.Managed([]const u8).init(std.testing.allocator);
    defer log.deinit();
    const root = try recPaintNode(&log, "root");
    defer root.deinit();
    root.bounds = .{ .x = 0, .y = 0, .w = 64, .h = 64 };
    // Same off-region bounds; only the overflow-expanded rect reaches back in.
    const shadow = try recPaintNode(&log, "shadow");
    shadow.bounds = .{ .x = 70, .y = 0, .w = 10, .h = 10 };
    shadow.damage_overflow.left = 10; // paints from x=60 → inside the region
    root.add(shadow);
    const plain = try recPaintNode(&log, "plain");
    plain.bounds = .{ .x = 70, .y = 0, .w = 10, .h = 10 };
    root.add(plain);
    kx.c.kx_begin_frame(ctx);
    root.paint(ctx, .{ .x = 0, .y = 0, .w = 64, .h = 64 });
    kx.c.kx_end_frame(ctx);
    try expectLog(&log, &.{ "root", "pre:root", "shadow", "pre:shadow", "post:shadow", "pre:plain", "post:plain", "post:root" });
}

const hit_bounds_vtable = blk: {
    var vt = test_vtable;
    vt.hit_bounds = struct {
        fn hb(_: *Node) Rect {
            return .{ .x = 50, .y = 50, .w = 20, .h = 20 };
        }
    }.hb;
    break :blk vt;
};

test "hitTest honors the hit_bounds hook over the raw bounds" {
    const root = try testNode(100, 100);
    defer root.deinit();
    root.layout(.{ .x = 0, .y = 0, .w = 100, .h = 100 });
    const shifted = try testNode(10, 10);
    shifted.vtable = &hit_bounds_vtable; // bounds at (0,0,10,10), hit rect at (50,50,20,20)
    root.add(shifted);
    shifted.layout(.{ .x = 0, .y = 0, .w = 10, .h = 10 });
    try std.testing.expectEqual(shifted, root.hitTest(55, 55).?); // inside the hit rect
    try std.testing.expectEqual(root, root.hitTest(5, 5).?); // bounds say child, hit rect says no
}

const pre_hit_shift_vtable = blk: {
    var vt = test_vtable;
    vt.pre_children_hit = struct {
        fn pre(_: *Node, px: f32, py: f32) HitPoint {
            return .{ .x = px - 100, .y = py - 50 }; // content translated by (+100, +50)
        }
    }.pre;
    break :blk vt;
};

const pre_hit_shift2_vtable = blk: {
    var vt = test_vtable;
    vt.pre_children_hit = struct {
        fn pre(_: *Node, px: f32, py: f32) HitPoint {
            return .{ .x = px - 10, .y = py }; // content translated by (+10, 0)
        }
    }.pre;
    break :blk vt;
};

test "hitTestMapped maps through pre_children_hit and reports parent-space coords" {
    const root = try testNode(200, 200);
    defer root.deinit();
    root.vtable = &pre_hit_shift_vtable;
    root.layout(.{ .x = 0, .y = 0, .w = 200, .h = 200 });
    const child = try testNode(50, 50);
    root.add(child);
    child.layout(.{ .x = 10, .y = 10, .w = 50, .h = 50 }); // content space
    // window (120, 70) → child space (20, 20): inside the child
    const hit = root.hitTestMapped(120, 70).?;
    try std.testing.expectEqual(child, hit.node);
    try std.testing.expectEqual(@as(f32, 20), hit.x); // the hit node's parent space
    try std.testing.expectEqual(@as(f32, 20), hit.y);
    // a point outside the mapped child hits the root
    try std.testing.expectEqual(root, root.hitTestMapped(50, 20).?.node);
}

test "mapPointToParentSpace applies every ancestor's pre_children_hit, root-first" {
    const root = try testNode(300, 300);
    defer root.deinit();
    root.vtable = &pre_hit_shift_vtable; // window → root's child space: (-100, -50)
    const mid = try testNode(100, 100);
    mid.vtable = &pre_hit_shift2_vtable; // root's child space → mid's child space: (-10, 0)
    root.add(mid);
    const leaf = try testNode(10, 10);
    mid.add(leaf);
    // window (115, 55) → mid space (15, 5) → leaf's parent space (5, 5)
    const p = Node.mapPointToParentSpace(leaf, 115, 55);
    try std.testing.expectEqual(@as(f32, 5), p.x);
    try std.testing.expectEqual(@as(f32, 5), p.y);
    // a node without a parent maps 1:1 (identity)
    const free_leaf = try testNode(10, 10);
    defer free_leaf.deinit();
    const p2 = Node.mapPointToParentSpace(free_leaf, 115, 55);
    try std.testing.expectEqual(@as(f32, 115), p2.x);
    try std.testing.expectEqual(@as(f32, 55), p2.y);
}

const map_paint_vtable = blk: {
    var vt = test_vtable;
    vt.map_paint_rect = struct {
        fn m(_: *Node, rect: Rect) Rect {
            return .{ .x = rect.x + 100, .y = rect.y + 50, .w = rect.w, .h = rect.h };
        }
    }.m;
    break :blk vt;
};

test "mapRectToRoot applies every transformed ancestor's map_paint_rect" {
    const root = try testNode(300, 300);
    defer root.deinit();
    root.vtable = &map_paint_vtable; // translates child rects by (+100, +50)
    const leaf = try testNode(10, 10);
    root.add(leaf);
    const r = leaf.mapRectToRoot(.{ .x = 0, .y = 0, .w = 10, .h = 10 });
    try std.testing.expectEqual(@as(f32, 100), r.x);
    try std.testing.expectEqual(@as(f32, 50), r.y);
    try std.testing.expectEqual(@as(f32, 10), r.w);
    try std.testing.expectEqual(@as(f32, 10), r.h);
    // without a transform hook the rect passes through unchanged
    const free_leaf = try testNode(10, 10);
    defer free_leaf.deinit();
    const r2 = free_leaf.mapRectToRoot(.{ .x = 1, .y = 2, .w = 3, .h = 4 });
    try std.testing.expectEqual(Rect{ .x = 1, .y = 2, .w = 3, .h = 4 }, r2);
}

const mirror_paint_vtable = blk: {
    var vt = test_vtable;
    vt.map_paint_rect = struct {
        fn m(_: *Node, rect: Rect) Rect {
            // mirror around x=50 (an AnimatedScale with factor -1)
            return .{ .x = 50 + (rect.x - 50) * -1, .y = rect.y, .w = rect.w * -1, .h = rect.h };
        }
    }.m;
    break :blk vt;
};

test "mapRectToRoot normalizes mirrored (negative-scale) rects" {
    const root = try testNode(300, 300);
    defer root.deinit();
    root.vtable = &mirror_paint_vtable;
    const leaf = try testNode(10, 10);
    root.add(leaf);
    // rect 60..80 mirrors to 20..40 (negative extent pre-normalization)
    const r = leaf.mapRectToRoot(.{ .x = 60, .y = 5, .w = 20, .h = 10 });
    try std.testing.expectEqual(Rect{ .x = 20, .y = 5, .w = 20, .h = 10 }, r);
}

test "deinit releases the node's router references (capture/hover/focus/popup)" {
    var router = input_mod.InputRouter{};
    input_mod.setCurrent(&router);
    defer input_mod.setCurrent(null);
    const root = try testNode(100, 100);
    defer root.deinit();
    const child = try testNode(50, 50);
    root.add(child);
    root.layout(.{ .x = 0, .y = 0, .w = 100, .h = 100 });
    child.layout(.{ .x = 0, .y = 0, .w = 50, .h = 50 });
    router.dispatchPointer(root, .{ .phase = .move, .x = 10, .y = 10 }); // hover the child
    router.dispatchPointer(root, .{ .phase = .down, .x = 10, .y = 10 }); // capture it
    router.focus(child);
    router.open_popup = child;
    try std.testing.expect(router.capturedNode(0) == child);
    try std.testing.expect(root.remove(child)); // detach first: the root must not double-free
    // A captured subtree hands its capture to the surviving parent on
    // detach — the gesture continues bubbling instead of dying mid-drag.
    try std.testing.expect(router.capturedNode(0) == root);
    child.deinit();
    try std.testing.expect(router.capturedNode(0) == root); // no dangling ref to the dead child
    try std.testing.expect(router.hovered == null);
    try std.testing.expect(router.focused == null);
    try std.testing.expect(router.open_popup == null);
}

// --- deferred destruction (deinit during traversal) ------------------------

const KillState = struct {
    victim: ?*Node = null, // deinit'd on .down
    self_destruct: bool = false, // deinit self on .down
};
fn killMeasure(_: *Node, c: Constraints) Size {
    return c.constrain(.{ .w = 10, .h = 10 });
}
fn killLayout(_: *Node, _: Rect) void {}
fn killPaint(_: *Node, _: *kx.Ctx) void {}
fn killPointer(n: *Node, ev: input_mod.PointerEvent) bool {
    const s: *KillState = @ptrCast(@alignCast(n.state.?));
    if (ev.phase != .down) return true;
    if (s.victim) |v| v.deinit();
    if (s.self_destruct) n.deinit();
    return true;
}
fn killDeinit(n: *Node) void {
    n.allocator.destroy(@as(*KillState, @ptrCast(@alignCast(n.state.?))));
}
const kill_vtable = blk: {
    var vt = test_vtable;
    vt.measure = killMeasure;
    vt.layout = killLayout;
    vt.paint = killPaint;
    vt.on_pointer = killPointer;
    vt.deinit = killDeinit;
    break :blk vt;
};
fn killNode(victim: ?*Node, self_destruct: bool) !*Node {
    const node = try Node.create(std.testing.allocator, &kill_vtable);
    errdefer node.allocator.destroy(node);
    const s = try std.testing.allocator.create(KillState);
    s.* = .{ .victim = victim, .self_destruct = self_destruct };
    node.state = s;
    return node;
}

test "deinit during a traversal marks the node zombie; the sweep frees it" {
    const root = try testNode(100, 100);
    defer root.deinit();
    const child = try testNode(50, 50);
    root.add(child);
    traversalBegin();
    child.deinit(); // defers — zombie, still listed: a captured slice stays valid
    try std.testing.expect(child.zombie);
    try std.testing.expectEqual(@as(usize, 1), root.children.items.len);
    traversalEnd(); // sweep: teardown + detach + free (testing alloc reports a missed free)
    try std.testing.expectEqual(@as(usize, 0), root.children.items.len);
}

test "a zombie child is skipped by hitTest — the sibling behind it answers" {
    const root = try testNode(100, 100);
    defer root.deinit();
    root.bounds = .{ .x = 0, .y = 0, .w = 100, .h = 100 };
    const back = try testNode(50, 50);
    back.bounds = .{ .x = 0, .y = 0, .w = 50, .h = 50 };
    root.add(back);
    const front = try testNode(50, 50);
    front.bounds = .{ .x = 0, .y = 0, .w = 50, .h = 50 };
    root.add(front);
    front.zombie = true; // destroyed mid-traversal: still listed, memory valid
    const hit = root.hitTest(10, 10);
    try std.testing.expect(hit != null);
    try std.testing.expect(hit.? == back); // front skipped — stays listed for the sweep
}

test "dispatch: a .down handler that destroys a sibling does not UAF" {
    var router = input_mod.InputRouter{};
    input_mod.setCurrent(&router);
    defer input_mod.setCurrent(null);
    const root = try testNode(100, 100);
    defer root.deinit();
    root.bounds = .{ .x = 0, .y = 0, .w = 100, .h = 100 };
    const victim = try testNode(50, 50);
    victim.bounds = .{ .x = 50, .y = 0, .w = 50, .h = 50 };
    root.add(victim);
    const btn = try killNode(victim, false);
    btn.bounds = .{ .x = 0, .y = 0, .w = 50, .h = 50 };
    root.add(btn);
    // .down hits btn → kills victim mid-traversal: deferral keeps the memory
    // valid until the sweep, which detaches + frees it (a pre-fix run read
    // 0xAA-poisoned memory and crashed).
    router.dispatchPointer(root, .{ .phase = .down, .x = 10, .y = 10 });
    try std.testing.expectEqual(@as(usize, 1), root.children.items.len);
}

test "dispatch: a handler that destroys its OWN node survives the next phase" {
    var router = input_mod.InputRouter{};
    input_mod.setCurrent(&router);
    defer input_mod.setCurrent(null);
    const root = try testNode(100, 100);
    defer root.deinit();
    root.bounds = .{ .x = 0, .y = 0, .w = 100, .h = 100 };
    const btn = try killNode(null, true);
    btn.bounds = .{ .x = 0, .y = 0, .w = 50, .h = 50 };
    root.add(btn);
    router.dispatchPointer(root, .{ .phase = .down, .x = 10, .y = 10 }); // captures + self-destructs
    router.dispatchPointer(root, .{ .phase = .up, .x = 10, .y = 10 }); // captured zombie → skipped
    try std.testing.expectEqual(@as(usize, 0), root.children.items.len);
}

const TwinKillState = struct { other: ?*Node = null };
fn twinKillMeasure(_: *Node, c: Constraints) Size {
    return c.constrain(.{ .w = 10, .h = 10 });
}
fn twinKillDeinit(n: *Node) void {
    const s: *TwinKillState = @ptrCast(@alignCast(n.state.?));
    if (s.other) |o| o.deinit(); // destroys a DETACHED sibling during teardown
    n.allocator.destroy(s);
}
const twin_kill_vtable = blk: {
    var vt = test_vtable;
    vt.measure = twinKillMeasure;
    vt.deinit = twinKillDeinit;
    break :blk vt;
};
fn twinKillNode(other: ?*Node) !*Node {
    const node = try Node.create(std.testing.allocator, &twin_kill_vtable);
    errdefer node.allocator.destroy(node);
    const s = try std.testing.allocator.create(TwinKillState);
    s.* = .{ .other = other };
    node.state = s;
    return node;
}

test "deinit: a vtable deinit that destroys another node defers it to the sweep" {
    const detached = try testNode(10, 10); // not parented — destroyed by the sibling's deinit
    const killer = try twinKillNode(detached);
    killer.deinit(); // depth-0 deinit runs the sweep; the nested deinit queues onto it
    // both freed — the testing allocator fails the test on a leak
}

test "paint: a markDirty raised during paint survives to the next frame" {
    const ctx = kx.create(null, 64, 64, kx.c.KX_BACKEND_RASTER) orelse return error.TestUnexpectedResult;
    defer kx.c.kx_destroy(ctx);
    const mark_paint_vtable = blk: {
        var vt = test_vtable;
        vt.deinit = null; // no TestState on this node
        vt.paint = struct {
            fn p(n: *Node, _: *kx.Ctx) void {
                n.markDirty(); // a paint hook that mutates must re-dirty the node
            }
        }.p;
        break :blk vt;
    };
    const root = try Node.create(std.testing.allocator, &mark_paint_vtable);
    defer root.deinit();
    root.bounds = .{ .x = 0, .y = 0, .w = 10, .h = 10 };
    kx.c.kx_begin_frame(ctx);
    root.paint(ctx, .{ .x = 0, .y = 0, .w = 64, .h = 64 });
    kx.c.kx_end_frame(ctx);
    try std.testing.expect(root.dirty); // cleared BEFORE paint — the in-paint mark survives
}

// --- dirty-region / auto-retain coverage ---

test "layout() damages old∪new paint rect on a bounds change; a no-op layout stays clean" {
    const root = try testNode(100, 100);
    defer root.deinit();
    const child = try testNode(10, 10);
    root.add(child);
    root.bounds = .{ .x = 0, .y = 0, .w = 100, .h = 100 };
    child.bounds = .{ .x = 0, .y = 0, .w = 10, .h = 10 };
    // A clean tree (as if a frame just painted).
    root.clearDamage();
    root.dirty = false;
    child.dirty = false;
    // Moving the child marks it + damages old ∪ new.
    child.layout(.{ .x = 20, .y = 5, .w = 10, .h = 10 });
    try std.testing.expect(child.dirty);
    try std.testing.expect(root.dirty);
    try std.testing.expect(root.damage_valid);
    const want = rectUnion(
        .{ .x = 0, .y = 0, .w = 10, .h = 10 },
        .{ .x = 20, .y = 5, .w = 10, .h = 10 },
    );
    try std.testing.expectEqual(want.x, root.damage.x);
    try std.testing.expectEqual(want.y, root.damage.y);
    try std.testing.expectEqual(want.w, root.damage.w);
    try std.testing.expectEqual(want.h, root.damage.h);
    // Re-laying out at the same bounds is a visual no-op: zero new damage.
    root.clearDamage();
    root.dirty = false;
    child.dirty = false;
    child.layout(.{ .x = 20, .y = 5, .w = 10, .h = 10 });
    try std.testing.expect(!child.dirty);
    try std.testing.expect(!root.dirty);
    try std.testing.expect(!root.damage_valid);
}

test "paintExtent unions descendants through child_clip and map_paint_rect" {
    const root = try testNode(64, 64);
    defer root.deinit();
    var log = std.array_list.Managed([]const u8).init(std.testing.allocator);
    defer log.deinit();
    // A clipper (5,5,20,20) whose clip is (5,5,10,10); a huge child clipped
    // to it contributes only the clipped region.
    const clipper = try recPaintNodeVtable(&log, "clipper", &paint_rec_clip_vtable);
    clipper.bounds = .{ .x = 5, .y = 5, .w = 20, .h = 20 };
    (@as(*PaintRec, @ptrCast(@alignCast(clipper.state.?)))).clip = .{ .x = 5, .y = 5, .w = 10, .h = 10 };
    const big = try recPaintNode(&log, "big");
    big.bounds = .{ .x = 0, .y = 0, .w = 100, .h = 100 };
    clipper.add(big);
    root.add(clipper);
    const ext = clipper.paintExtent(false);
    try std.testing.expectEqual(@as(f32, 5), ext.x);
    try std.testing.expectEqual(@as(f32, 5), ext.y);
    try std.testing.expectEqual(@as(f32, 20), ext.w); // own pr wins over the clipped child
    try std.testing.expectEqual(@as(f32, 20), ext.h);
    // A transform maps the child's extent to its visual position.
    const shifted = try recPaintNodeVtable(&log, "shifted", &paint_rec_shift_vtable);
    shifted.bounds = .{ .x = 0, .y = 0, .w = 50, .h = 50 };
    const child = try recPaintNode(&log, "child");
    child.bounds = .{ .x = 0, .y = 0, .w = 10, .h = 10 };
    shifted.add(child);
    root.add(shifted);
    const ext2 = shifted.paintExtent(false);
    // own (0,0,50,50) ∪ child mapped to (100,50,10,10) → (0,0,110,60)
    try std.testing.expectEqual(@as(f32, 0), ext2.x);
    try std.testing.expectEqual(@as(f32, 0), ext2.y);
    try std.testing.expectEqual(@as(f32, 110), ext2.w);
    try std.testing.expectEqual(@as(f32, 60), ext2.h);
}

test "setVisible damages the subtree extent — hide covers overflow, show covers the new region" {
    const root = try testNode(64, 64);
    defer root.deinit();
    var log = std.array_list.Managed([]const u8).init(std.testing.allocator);
    defer log.deinit();
    const wrapper = try recPaintNode(&log, "wrapper");
    wrapper.bounds = .{ .x = 0, .y = 0, .w = 10, .h = 10 };
    const overflow = try recPaintNode(&log, "overflow");
    overflow.bounds = .{ .x = 0, .y = 0, .w = 40, .h = 40 }; // paints past the wrapper
    wrapper.add(overflow);
    root.add(wrapper);
    root.clearDamage();
    root.dirty = false;
    wrapper.dirty = false;
    overflow.dirty = false;
    // Hide: damage covers the wrapper AND the overflowing child.
    wrapper.setVisible(false);
    try std.testing.expect(root.damage_valid);
    try std.testing.expectEqual(@as(f32, 0), root.damage.x);
    try std.testing.expectEqual(@as(f32, 0), root.damage.y);
    try std.testing.expectEqual(@as(f32, 40), root.damage.w);
    try std.testing.expectEqual(@as(f32, 40), root.damage.h);
    // A repeated hide is a no-op.
    root.clearDamage();
    root.dirty = false;
    wrapper.setVisible(false);
    try std.testing.expect(!root.damage_valid);
    // Show: the reappearing subtree's extent is damaged again.
    wrapper.setVisible(true);
    try std.testing.expect(root.damage_valid);
    try std.testing.expectEqual(@as(f32, 40), root.damage.w);
}

const paint_rec_retain_vtable = blk: {
    var vt = paint_rec_vtable;
    vt.auto_retain = true;
    break :blk vt;
};

test "auto-retained subtree rasterizes once, re-blits while clean, drops on dirty" {
    const ctx = kx.create(null, 64, 64, kx.c.KX_BACKEND_RASTER) orelse return error.TestUnexpectedResult;
    defer kx.c.kx_destroy(ctx);
    var log = std.array_list.Managed([]const u8).init(std.testing.allocator);
    defer log.deinit();
    const root = try recPaintNode(&log, "root");
    defer root.deinit();
    const box = try recPaintNodeVtable(&log, "box", &paint_rec_retain_vtable);
    const leaf = try recPaintNode(&log, "leaf");
    box.add(leaf);
    root.add(box);
    root.bounds = .{ .x = 0, .y = 0, .w = 64, .h = 64 };
    box.bounds = .{ .x = 10, .y = 10, .w = 30, .h = 30 };
    leaf.bounds = .{ .x = 10, .y = 10, .w = 10, .h = 10 };
    const whole = Rect{ .x = 0, .y = 0, .w = 64, .h = 64 };
    // Frame 1 (dirty): direct paint — every hook runs.
    kx.c.kx_begin_frame(ctx);
    root.paint(ctx, whole);
    kx.c.kx_end_frame(ctx);
    const f1 = log.items.len;
    try std.testing.expectEqual(@as(usize, 9), f1);
    try std.testing.expect(box.retained_image == 0);
    // Frame 2 (clean): the auto subtree rasterizes into its image — hooks
    // run once more (into the offscreen), then a single blit lands.
    kx.c.kx_begin_frame(ctx);
    root.paint(ctx, whole);
    kx.c.kx_end_frame(ctx);
    try std.testing.expectEqual(f1 + 9, log.items.len);
    try std.testing.expect(box.retained_image != 0);
    // Frame 3 (clean): pure blit — neither the box's nor the leaf's hooks run.
    kx.c.kx_begin_frame(ctx);
    root.paint(ctx, whole);
    kx.c.kx_end_frame(ctx);
    try std.testing.expectEqual(f1 + 12, log.items.len); // root + pre:root + post:root only
    // A dirty leaf drops the cache: the next paint repaints the box directly.
    leaf.markDirty();
    kx.c.kx_begin_frame(ctx);
    root.paint(ctx, whole);
    kx.c.kx_end_frame(ctx);
    try std.testing.expectEqual(f1 + 12 + 9, log.items.len);
    try std.testing.expect(box.retained_image == 0);
    // Frame 5 (clean): the subtree is clean again — re-rasterized and blitted.
    kx.c.kx_begin_frame(ctx);
    root.paint(ctx, whole);
    kx.c.kx_end_frame(ctx);
    try std.testing.expectEqual(f1 + 12 + 9 + 9, log.items.len);
    try std.testing.expect(box.retained_image != 0);
}

const paint_rec_backdrop_vtable = blk: {
    var vt = paint_rec_vtable;
    vt.reads_backdrop = true;
    break :blk vt;
};

test "backdrop_subtree propagates up and blocks auto-retain" {
    const ctx = kx.create(null, 64, 64, kx.c.KX_BACKEND_RASTER) orelse return error.TestUnexpectedResult;
    defer kx.c.kx_destroy(ctx);
    var log = std.array_list.Managed([]const u8).init(std.testing.allocator);
    defer log.deinit();
    const root = try recPaintNode(&log, "root");
    defer root.deinit();
    const box = try recPaintNodeVtable(&log, "box", &paint_rec_retain_vtable);
    const blur = try recPaintNodeVtable(&log, "blur", &paint_rec_backdrop_vtable);
    box.add(blur);
    root.add(box);
    // The flag walked up at add() time — every ancestor knows.
    try std.testing.expect(blur.backdrop_subtree);
    try std.testing.expect(box.backdrop_subtree);
    try std.testing.expect(root.backdrop_subtree);
    root.bounds = .{ .x = 0, .y = 0, .w = 64, .h = 64 };
    box.bounds = .{ .x = 10, .y = 10, .w = 30, .h = 30 };
    blur.bounds = .{ .x = 10, .y = 10, .w = 10, .h = 10 };
    const whole = Rect{ .x = 0, .y = 0, .w = 64, .h = 64 };
    for (0..3) |_| {
        kx.c.kx_begin_frame(ctx);
        root.paint(ctx, whole);
        kx.c.kx_end_frame(ctx);
    }
    // Three clean frames in, the auto-eligible box must STILL paint
    // directly: its blur child reads the backdrop and a cached image would
    // bake a transparent-beneath sample.
    try std.testing.expect(box.retained_image == 0);
    // Every frame ran the hooks (9 entries/frame: root+box+blur chain).
    try std.testing.expectEqual(@as(usize, 27), log.items.len);
}

// Note: add()/insert() assert on cycles in debug builds (a tree cycle is a
// programmer bug, not runtime data) and refuse silently in release — the
// crash path itself isn't unit-testable in-process.
test "add reparents a node from its previous parent" {
    const root = try testNode(100, 100);
    defer root.deinit();
    const mid = try testNode(50, 50);
    const leaf = try testNode(10, 10);
    root.add(mid);
    mid.add(leaf);
    root.add(leaf); // reparent: leaf leaves mid, joins root
    try std.testing.expectEqual(root, leaf.parent.?);
    try std.testing.expectEqual(@as(usize, 0), mid.children.items.len);
    try std.testing.expectEqual(@as(usize, 2), root.children.items.len);
}
