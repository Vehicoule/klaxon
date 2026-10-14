// Node — retained widget tree with dirty flags (ADR-0004).
// Zig has no GC: the tree is retained and mutated in place. Dirty flags drive
// the frame loop — a clean tree renders 0 frames (0 wakeups at idle).
const std = @import("std");
const kx = @import("../kx.zig");
const paint_mod = @import("paint.zig");
const layout_mod = @import("layout.zig");
const input_mod = @import("input.zig");
const scroll_mod = @import("scroll.zig");
const semantics_mod = @import("semantics.zig");

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
    layout: *const fn (node: *Node, bounds: Rect) void,
    paint: *const fn (node: *Node, ctx: *kx.Ctx) void,
    deinit: ?*const fn (node: *Node) void = null,
    /// Pointer input (Phase 1c, dispatched by ui/input.zig). Returns true if
    /// handled — bubbling to the parent stops.
    on_pointer: ?*const fn (node: *Node, ev: input_mod.PointerEvent) bool = null,
    /// Keyboard input (Phase 1c) — delivered to the focused node's chain.
    on_key: ?*const fn (node: *Node, ev: input_mod.KeyEvent) bool = null,
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
    /// Effective hit-test rect (defaults to bounds). Transformed widgets
    /// return where their children actually paint.
    hit_bounds: ?*const fn (node: *Node) Rect = null,
    /// Map a point from this node's space into its children's coordinate
    /// space (matches the paint transform, inverted). Hit-testing through a
    /// transformed subtree lands on the visual position.
    pre_children_hit: ?*const fn (node: *Node, px: f32, py: f32) HitPoint = null,
};

/// A point in a transformed coordinate space (hit-testing, Phase 1e).
pub const HitPoint = struct { x: f32, y: f32 };

pub const Node = struct {
    allocator: std.mem.Allocator,
    parent: ?*Node = null,
    children: std.array_list.Managed(*Node),
    bounds: Rect = .{},
    dirty: bool = true,
    layout_dirty: bool = true,
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
    // Dirty-rect (Phase 1e): the root accumulates the damaged region — the
    // union of every dirty mark's rect — and the host repaints the tree
    // clipped to it (the surface is retained between frames).
    damage: Rect = .{},
    damage_valid: bool = false,
    // Retained-subtree cache (Phase 4e.2): opt-in per node. When set, the
    // subtree's paint is rasterized once into a ctx image and re-blit while
    // the subtree stays clean — the per-item texture idiom every retained
    // framework applies (QSG item textures, Compose layers). Any dirty mark
    // in the subtree or a paintRect size change re-rasterizes on next paint.
    // Paint outside paintRect is already a damage-contract violation, so the
    // image covers paintRect exactly.
    retained: bool = false,
    retained_image: u64 = 0,
    retained_ctx: ?*kx.Ctx = null,
    retained_w: i32 = 0,
    retained_h: i32 = 0,
    /// Optional solid backdrop composited INTO the retained raster before the
    /// subtree paints: the cached image becomes fully opaque, so its blit can
    /// use Src (no destination read) and a full-coverage root blit lets the
    /// frame loop skip its clear. Correct only where the backdrop behind the
    /// node is constant (roots, nodes over a solid frame background).
    retained_bg: ?u32 = null,
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
        };
        return node;
    }

    /// Append a child. OOM while building the tree is fatal (same as Flutter).
    pub fn add(node: *Node, child: *Node) void {
        // Detach from a previous parent — otherwise the child stays in two
        // children lists and both deinit it (double free).
        if (child.parent) |prev| _ = prev.remove(child);
        child.parent = node;
        node.children.append(child) catch @panic("klaxon: out of memory");
        if (child.overlay_subtree) node.markOverlayUp();
        node.markLayoutDirty();
        node.markDirty();
    }

    /// Insert a child at `index` (clamped to the end). Same ownership contract
    /// as add(): the child is parented, not owned. Re-insertion at the original
    /// index restores paint order (hero flight, Phase 2a).
    pub fn insert(node: *Node, index: usize, child: *Node) void {
        if (child.parent) |prev| _ = prev.remove(child);
        child.parent = node;
        const i = @min(index, node.children.items.len);
        node.children.insert(i, child) catch @panic("klaxon: out of memory");
        if (child.overlay_subtree) node.markOverlayUp();
        node.markLayoutDirty();
        node.markDirty();
    }

    /// Remove a child. The child is NOT deinited (the caller owns it) and its
    /// parent pointer is cleared. Returns false if it was not a child.
    /// Dynamic UI (conditional children, theme rebuilds) needs this: the tree
    /// is retained, but subtrees come and go.
    pub fn remove(node: *Node, child: *Node) bool {
        for (node.children.items, 0..) |c, i| {
            if (c == child) {
                _ = node.children.orderedRemove(i);
                child.parent = null;
                node.markLayoutDirty();
                node.markDirty();
                return true;
            }
        }
        return false;
    }

    fn markDirtyUp(node: *Node) void {
        var n = node;
        while (true) {
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
            if (p.vtable.map_paint_rect) |m| r = m(p, r);
            n = p;
        }
        unionDamage(n, r);
    }

    /// Mark this node (and its ancestors) dirty. The node's paint rect
    /// (paint_bounds, or the bounds expanded by damage_overflow) — mapped
    /// to its visible position through any transformed ancestors — is
    /// unioned into the root's damage region.
    pub fn markDirty(node: *Node) void {
        markDirtyUp(node);
        damageRectUp(node, node.paintRect());
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
        node.layout_dirty = true;
        if (node.parent) |p| p.markLayoutDirty();
    }

    pub fn measure(node: *Node, c: Constraints) Size {
        return node.vtable.measure(node, c);
    }

    pub fn layout(node: *Node, bounds: Rect) void {
        node.bounds = bounds;
        node.layout_dirty = false;
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
        if (!node.visible or node.zombie) return;
        // The region descendants can paint into: `visible`, tightened by the
        // node's children clip (viewport) when it declares one.
        var child_region = visible;
        if (node.vtable.child_clip) |cc| {
            child_region = rectIntersect(visible, node.mapRectToRoot(cc(node)));
        }
        const own_hit = rectOverlaps(node.mapRectToRoot(node.paintRect()), visible);
        const children_hit = child_region.w > 0 and child_region.h > 0;
        if (!own_hit and !children_hit) return; // the whole subtree is off-region
        // Clear BEFORE painting: a markDirty raised while this subtree paints
        // (paint hook → signal write → subscriber) must survive to schedule
        // the next frame — a tail clear would wipe it.
        const subtree_dirty = node.dirty;
        node.dirty = false;
        if (node.retained and node.paintRetained(ctx, subtree_dirty)) return;
        node.paintContent(ctx, own_hit, child_region, children_hit);
    }

    /// The draw pass: own paint + the children pass (pre/loop/post hooks) —
    /// shared by the direct path and the retained rasterization.
    fn paintContent(node: *Node, ctx: *kx.Ctx, own_hit: bool, child_region: Rect, children_hit: bool) void {
        if (own_hit) node.vtable.paint(node, ctx);
        if (children_hit) {
            if (node.vtable.pre_children_paint) |pre| pre(node, ctx);
            for (node.children.items) |child| {
                if (child.defer_paint or child.zombie) continue; // defer_paint → popup overlay; zombie → swept
                child.paint(ctx, child_region);
            }
            if (node.vtable.post_children_paint) |post| post(node, ctx);
        }
    }

    /// Retained-subtree paint: re-blit the cached raster while the subtree
    /// stays clean; re-rasterize through an offscreen pass when dirty or
    /// resized. Returns false when the node must paint directly instead
    /// (zero-size image, or the offscreen pass is unavailable — e.g. nested
    /// inside another retained rasterization).
    fn paintRetained(node: *Node, ctx: *kx.Ctx, subtree_dirty: bool) bool {
        const pr = node.paintRect(); // parent space — the damage-contract rect
        const iw: i32 = @intFromFloat(@ceil(@max(0, pr.w)));
        const ih: i32 = @intFromFloat(@ceil(@max(0, pr.h)));
        if (iw <= 0 or ih <= 0) return true; // nothing reachable — painted
        if (node.retained_ctx != ctx and node.retained_image != 0) {
            node.clearRetained(); // image belongs to another ctx — drop it
        }
        if (!subtree_dirty and node.retained_image != 0 and
            node.retained_w == iw and node.retained_h == ih)
        {
            kx.c.kx_draw_image(ctx, node.retained_image, pr.x, pr.y,
                @floatFromInt(iw), @floatFromInt(ih));
            return true;
        }
        if (std.c.getenv("KLAXON_DBG_RETAINED") != null) std.debug.print("retained miss: dirty={} img={} {d}x{d} vs {d}x{d}\n", .{ subtree_dirty, node.retained_image, node.retained_w, node.retained_h, iw, ih });
        // (Re)rasterize: drop the stale image first so a failed pass can't
        // resurrect a stale blit on a later frame.
        node.clearRetained();
        if (!kx.c.kx_offscreen_begin(ctx, iw, ih)) {
            return false; // nested offscreen pass — paint directly this frame
        }
        if (node.retained_bg) |bg| kx.c.kx_clear(ctx, bg);
        kx.c.kx_translate(ctx, -pr.x, -pr.y);
        // The cache must hold EVERYTHING the subtree draws: cull only
        // against the mapped paintRect (the damage-contract bound).
        const mapped = node.mapRectToRoot(pr);
        node.paintContent(ctx, true, mapped, true);
        node.retained_image = kx.c.kx_offscreen_end_image(ctx);
        if (node.retained_image == 0) return false; // pass failed — direct paint
        node.retained_ctx = ctx;
        node.retained_w = iw;
        node.retained_h = ih;
        kx.c.kx_draw_image(ctx, node.retained_image, pr.x, pr.y,
            @floatFromInt(iw), @floatFromInt(ih));
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
    fn clearRetained(node: *Node) void {
        if (node.retained_image != 0) {
            if (node.retained_ctx) |ctx| kx.c.kx_image_destroy(ctx, node.retained_image);
            node.retained_image = 0;
        }
        node.retained_ctx = null;
        node.retained_w = 0;
        node.retained_h = 0;
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
        var chain: [64]*Node = undefined;
        var depth: usize = 0;
        var n = node.parent;
        while (n) |p| : (n = p.parent) {
            if (depth < chain.len) {
                chain[depth] = p;
                depth += 1;
            }
        }
        var x = px;
        var y = py;
        while (depth > 0) {
            depth -= 1;
            const a = chain[depth];
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
        for (node.children.items) |child| {
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
    traversal_depth -= 1;
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
    child.deinit();
    try std.testing.expect(router.capturedNode(0) == null);
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
