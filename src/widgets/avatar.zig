// M3E Avatar (Phase 4d P2) — a circular avatar with initials, image, or icon.
//
// Spec: docs/specs/m3e-specs-4d-p2-avatar.md
// No official M3/M3E Avatar spec; cross-referenced with Compose Material3
// Avatar (experimental), Flutter CircleAvatar, Material Web avatar, iOS
// circular UIImageView idiom, and the M3E token system (src/theme.zig).
//
// Tokens:
//   - container: PrimaryContainer, shape: CornerFull (size/2)
//   - initials: OnPrimaryContainer, font size = size * 0.4, weight 500
//   - sizes: XS 24, S 32, M 40 (default), L 56, XL 96 (4dp grid)
//
// Variants:
//   - initials: 1-2 uppercase letters centered in the circle
//   - image: RGBA pixels drawn into the square bounds (v1: no circular clip)
//   - icon: a single icon glyph centered
//
// Interaction: non-interactive by default; optional on_tap callback
// (state layers hover 0.08 / pressed 0.12 over OnPrimaryContainer).
//
// v1 deviations: image has no circular clip; no badge/dot overlay;
// no avatar group stack.
const std = @import("std");
const kx = @import("../kx.zig");
const ui = @import("../ui.zig");
const input = @import("../ui/input.zig");
const i18n_mod = @import("../ui/i18n.zig");
const theme_mod = @import("../theme.zig");
const icon_w = @import("icon.zig");
const golden = @import("../golden.zig"); // tests

const Node = ui.node.Node;
const Rect = ui.node.Rect;
const Constraints = ui.layout.Constraints;
const Size = ui.layout.Size;
const Color = ui.paint.Color;
const Callback = ui.state.Callback;
const Theme = theme_mod.Theme;

pub const AvatarSize = enum { xs, s, m, l, xl };

pub const AvatarVariant = enum { initials, image, icon };

pub const AvatarOptions = struct {
    theme: Theme = theme_mod.light,
    size: AvatarSize = .m,
    /// Initials text (1-2 chars, uppercased). Used for the initials variant.
    initials: []const u8 = "",
    /// Image pixels (RGBA memory order) + dimensions. Used for the image variant.
    image_rgba: ?[]const u8 = null,
    image_w: i32 = 0,
    image_h: i32 = 0,
    /// Icon name. Used for the icon variant.
    icon: ?icon_w.IconName = null,
    /// Accessible label (defaults to the initials or "Avatar").
    a11y_label: ?[]const u8 = null,
    /// When true, the avatar is tappable (fires on_tap, shows state layers).
    tappable: bool = false,
};

// --- M3E tokens ---

fn sizeDp(size: AvatarSize) f32 {
    return switch (size) {
        .xs => 24,
        .s => 32,
        .m => 40,
        .l => 56,
        .xl => 96,
    };
}

fn initialsFontSize(size: AvatarSize) f32 {
    return @round(sizeDp(size) * 0.4 * 10) / 10; // 1dp precision
}

// --- State ---

const AvatarState = struct {
    opts: AvatarOptions,
    on_tap: ?Callback = null,
    variant: AvatarVariant = .initials,
    /// Owned initials — uppercased ASCII, at most 2 UTF-8 codepoints (8
    /// bytes; a multibyte glyph is no longer mangled by a byte-wise cap),
    /// null-terminated at initials[len].
    initials: [9]u8 = std.mem.zeroes([9]u8),
    initials_len: usize = 0,
    /// Owned a11y label (null-terminated; "" = fall back to "Avatar").
    label: [:0]const u8,
    pressed: bool = false,
    hovered: bool = false,
    /// Owned image pixels (for deinit).
    image_owned: ?[]u8 = null,
    i18n: ?*i18n_mod.I18n = null,
};

fn stateOf(n: *Node) *AvatarState {
    return @ptrCast(@alignCast(n.state.?));
}

/// An owned null-terminated copy of a string.
fn dupeZ(allocator: std.mem.Allocator, str: []const u8) ![:0]u8 {
    const buf = try allocator.alloc(u8, str.len + 1);
    @memcpy(buf[0..str.len], str);
    buf[str.len] = 0;
    return buf[0..str.len :0];
}

// --- Measure ---

fn avMeasure(n: *Node, c: Constraints) Size {
    const s = stateOf(n);
    const d = sizeDp(s.opts.size);
    return .{
        .w = @max(c.min_w, @min(c.max_w, d)),
        .h = @max(c.min_h, @min(c.max_h, d)),
    };
}

// --- Paint ---

fn avPaint(n: *Node, ctx: *kx.Ctx) void {
    const s = stateOf(n);
    const t = s.opts.theme;
    const b = n.bounds;
    const radius = b.w / 2;

    // Circle background.
    ui.paint.fillRRect(ctx, b.x, b.y, b.w, b.h, radius, t.colors.primary_container);

    // State layer when tappable.
    if (s.opts.tappable) {
        var alpha: f32 = 0;
        if (s.pressed) alpha = t.state.pressed else if (s.hovered) alpha = t.state.hover;
        if (alpha > 0) {
            const layer = theme_mod.stateLayer(t.colors.primary_container, t.colors.on_primary_container, alpha);
            ui.paint.fillRRect(ctx, b.x, b.y, b.w, b.h, radius, layer);
        }
    }

    // Content.
    switch (s.variant) {
        .initials => {
            // Centered initials text.
            const font_size = initialsFontSize(s.opts.size);
            if (s.initials_len > 0) {
                const text_z: [:0]const u8 = s.initials[0..s.initials_len :0];
                const metrics = ui.paint.measureText(text_z, font_size, true);
                const tx = b.x + (b.w - metrics.width) / 2;
                const ty = b.y + (b.h - metrics.height) / 2 + metrics.height * 0.8;
                ui.paint.text(ctx, text_z, tx, ty, font_size, true, t.colors.on_primary_container);
            }
        },
        .icon => {
            if (s.opts.icon) |ic| {
                const icon_size = b.w * 0.5;
                icon_w.drawIcon(ctx, ic, b.x + (b.w - icon_size) / 2, b.y + (b.h - icon_size) / 2, icon_size / 24.0, t.colors.on_primary_container);
            }
        },
        .image => {
            // v1: draw the image stretched into the bounds (no circular clip).
            if (s.image_owned) |pixels| {
                if (s.opts.image_w > 0 and s.opts.image_h > 0) {
                    const id = ui.paint.imageCreate(ctx, pixels.ptr, s.opts.image_w, s.opts.image_h);
                    defer ui.paint.imageDestroy(ctx, id);
                    ui.paint.imageDraw(ctx, id, b.x, b.y, b.w, b.h);
                }
            }
        },
    }
}

// --- Input ---

fn avPointer(n: *Node, ev: input.PointerEvent) bool {
    const s = stateOf(n);
    if (!s.opts.tappable) return false;
    switch (ev.phase) {
        .down => {
            s.pressed = true;
            n.markDirty();
            return true;
        },
        .up => {
            if (s.pressed) {
                s.pressed = false;
                n.markDirty();
                // Fire only when released inside — the press model cancels
                // on an outside release like every sibling control.
                if (n.bounds.contains(ev.x, ev.y)) {
                    if (s.on_tap) |cb| cb.fn_ptr(cb.userdata);
                }
            }
            return true;
        },
        // `.move` only reaches a captured node; hover otherwise arrives as
        // enter/leave/hover_move notifications.
        .move, .hover_move, .enter => {
            const inside = n.bounds.contains(ev.x, ev.y);
            if (inside != s.hovered) {
                s.hovered = inside;
                n.markDirty();
            }
            return ev.phase == .move;
        },
        .leave => {
            if (s.hovered) {
                s.hovered = false;
                n.markDirty();
            }
            return false;
        },
        .outside_down => {
            if (s.pressed) {
                s.pressed = false;
                n.markDirty();
            }
            return false;
        },
    }
}

// --- Deinit ---

fn avDeinit(n: *Node) void {
    const s = stateOf(n);
    n.allocator.free(s.label);
    if (s.image_owned) |pixels| n.allocator.free(pixels);
    i18n_mod.unsubscribeLocale(s.i18n, .{ .fn_ptr = avLocaleCb, .userdata = n });
    n.allocator.destroy(s);
}

// --- VTable ---

/// An empty app label resolves the localized "Avatar" — the callback
/// re-attaches in the new locale.
fn avLocaleCb(userdata: ?*anyopaque) void {
    const n: *Node = @ptrCast(@alignCast(userdata.?));
    const s = stateOf(n);
    ui.semantics.attach(n, .{
        .role = .image,
        .label = if (s.label.len > 0) s.label else i18n_mod.tr("Avatar"),
        .focusable = s.opts.tappable,
    });
    n.markDirty();
    ui.semantics.notifyControlChanged(n);
}

const av_vtable = ui.node.VTable{
    .measure = avMeasure,
    .layout = avLayout,
    .paint = avPaint,
    .on_pointer = avPointer,
    .deinit = avDeinit,
};

// No-op layout for a square leaf (bounds are set by the parent).
fn avLayout(_: *Node, _: Rect) void {}

// --- Factory ---

/// Create an M3E avatar.
///
/// `on_tap` — fired when the avatar is tapped (only when `opts.tappable`).
/// `opts` — size, variant content (initials/image/icon), theme.
pub fn avatar(
    allocator: std.mem.Allocator,
    on_tap: ?Callback,
    opts: AvatarOptions,
) !*Node {
    const node = try Node.create(allocator, &av_vtable);
    errdefer allocator.destroy(node);
    const s = try allocator.create(AvatarState);
    errdefer allocator.destroy(s);

    // Determine the variant.
    var variant: AvatarVariant = .initials;
    if (opts.image_rgba != null and opts.image_w > 0 and opts.image_h > 0) {
        variant = .image;
    } else if (opts.icon != null) {
        variant = .icon;
    }

    // A11y label — owned, any length ("" = the "Avatar" default).
    const label = try dupeZ(allocator, opts.a11y_label orelse opts.initials);
    errdefer allocator.free(label);

    s.* = .{
        .opts = opts,
        .on_tap = on_tap,
        .variant = variant,
        .label = label,
    };

    // Uppercase the initials (max 2 UTF-8 codepoints — a multibyte glyph
    // keeps its bytes; only ASCII letters are upcased).
    var idx: usize = 0;
    var count: usize = 0;
    while (idx < opts.initials.len and count < 2) {
        const cp_len = std.unicode.utf8ByteSequenceLength(opts.initials[idx]) catch 1;
        const end = @min(idx + cp_len, opts.initials.len);
        for (opts.initials[idx..end]) |ch| {
            s.initials[s.initials_len] = switch (ch) {
                'a'...'z' => ch - 'a' + 'A',
                else => ch,
            };
            s.initials_len += 1;
        }
        idx += cp_len; // a truncated tail codepoint exits the loop anyway
        count += 1;
    }
    s.initials[s.initials_len] = 0;

    // Copy image pixels (owned).
    if (opts.image_rgba) |pixels| {
        const copy = try allocator.alloc(u8, pixels.len);
        @memcpy(copy, pixels);
        s.image_owned = copy;
    }

    node.state = @ptrCast(s);

    avLocaleCb(node); // the same path resolves the label in the active locale
    s.i18n = i18n_mod.subscribeLocale(.{ .fn_ptr = avLocaleCb, .userdata = node });

    return node;
}

// --- Accessors (for tests) ---

pub fn avatarSize(n: *Node) f32 {
    return sizeDp(stateOf(n).opts.size);
}

// --- Tests ---

test "avatar: measure returns the size square" {
    const a = std.testing.allocator;
    const n = try avatar(a, null, .{ .size = .m, .initials = "AB" });
    defer n.deinit();
    const sz = n.measure(.{ .max_w = 200, .max_h = 200 });
    try std.testing.expectApproxEqAbs(@as(f32, 40), sz.w, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 40), sz.h, 0.001);

    const n2 = try avatar(a, null, .{ .size = .xl, .initials = "Z" });
    defer n2.deinit();
    const sz2 = n2.measure(.{ .max_w = 200, .max_h = 200 });
    try std.testing.expectApproxEqAbs(@as(f32, 96), sz2.w, 0.001);
}

test "avatar: initials are uppercased (max 2 chars)" {
    const a = std.testing.allocator;
    const n = try avatar(a, null, .{ .initials = "john" });
    defer n.deinit();
    const s = stateOf(n);
    try std.testing.expectEqual(@as(u8, 'J'), s.initials[0]);
    try std.testing.expectEqual(@as(u8, 'O'), s.initials[1]);
    try std.testing.expectEqual(@as(u8, 0), s.initials[2]);
}

test "avatar: initials cap at 2 UTF-8 codepoints, not 2 bytes" {
    const a = std.testing.allocator;
    // "世" is 3 bytes: the old [3]u8 buffer held exactly one byte-capped char
    // (a 2-codepoint CJK string would have split the second glyph's bytes)
    const n = try avatar(a, null, .{ .initials = "世界" });
    defer n.deinit();
    const s = stateOf(n);
    try std.testing.expectEqual(@as(usize, 6), s.initials_len);
    try std.testing.expectEqualStrings("世界", s.initials[0..s.initials_len]);
    // a long a11y label is owned — no 63-byte cap anymore
    const long_label = "A very long avatar accessibility label that exceeds the old 63 byte fixed buffer easily";
    const n2 = try avatar(a, null, .{ .a11y_label = long_label });
    defer n2.deinit();
    try std.testing.expectEqualStrings(long_label, n2.semantics.?.label);
}

test "avatar: tappable fires on_tap" {
    var count: u32 = 0;
    const cb = Callback{ .fn_ptr = tapCounterCb, .userdata = &count };
    const a = std.testing.allocator;
    const n = try avatar(a, cb, .{ .tappable = true, .initials = "T" });
    defer n.deinit();
    n.layout(.{ .x = 0, .y = 0, .w = 40, .h = 40 });
    // Tap.
    _ = n.vtable.on_pointer.?(n, .{ .phase = .down, .x = 20, .y = 20, .raw_x = 20, .raw_y = 20 });
    _ = n.vtable.on_pointer.?(n, .{ .phase = .up, .x = 20, .y = 20, .raw_x = 20, .raw_y = 20 });
    try std.testing.expectEqual(@as(u32, 1), count);
}

test "avatar: semantics — role image, label = initials" {
    const a = std.testing.allocator;
    const n = try avatar(a, null, .{ .initials = "AB" });
    defer n.deinit();
    try std.testing.expectEqual(ui.semantics.Role.image, n.semantics.?.role);
    try std.testing.expectEqualStrings("AB", n.semantics.?.label);
}

test "golden: the avatar paints PrimaryContainer circle + OnPrimaryContainer initials" {
    const t = theme_mod.light;
    const a = std.testing.allocator;
    const n = try avatar(a, null, .{ .size = .l, .initials = "AB", .theme = t });
    defer n.deinit();
    var r = try golden.Renderer.init(std.testing.allocator, 80, 80);
    defer r.deinit();
    n.layout(.{ .x = 12, .y = 12, .w = 56, .h = 56 });
    r.paint(n, 0xFFFFFFFF);
    var f = try r.readback(std.testing.allocator);
    defer f.deinit();
    // Inside the circle, clear of the centered text ink: the fill.
    // The text "AB" at size 22.4 is ~30px wide centered at (40,40), so
    // x=18 (22px left of center) is inside the circle (r=28) but outside
    // the text box.
    const cx = 12 + 28;
    const cy = 12 + 28;
    try std.testing.expectEqual(t.colors.primary_container, f.pixelAt(cx - 22, cy));
    // The corner (outside the circle): background.
    try std.testing.expectEqual(@as(Color, 0xFFFFFFFF), f.pixelAt(12, 12));
    // The initials ink (OnPrimaryContainer) somewhere in the center row.
    try std.testing.expect(f.countColorIn(.{ .x = 12, .y = 30, .w = 56, .h = 20 }, t.colors.on_primary_container) > 0);
}

test "golden: the image avatar draws the exact pixels stretched into the bounds" {
    const a = std.testing.allocator;
    // 2x2 source: red green / blue white, drawn into 4x4 → each source pixel
    // is a 2x2 block (nearest sampling — the same draw path as the image widget).
    const src = [_]u8{
        0xFF, 0x00, 0x00, 0xFF, 0x00, 0xFF, 0x00, 0xFF, // red, green
        0x00, 0x00, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, // blue, white
    };
    const n = try avatar(a, null, .{ .size = .xs, .image_rgba = &src, .image_w = 2, .image_h = 2 });
    var frame = try golden.render(a, n, 4, 4, 0x101010FF);
    defer frame.deinit();
    // the image covers the whole bounds (v1: stretched, no circular clip)
    try std.testing.expectEqual(@as(u64, 4), frame.countColor(0xFF0000FF));
    try std.testing.expectEqual(@as(u64, 4), frame.countColor(0x00FF00FF));
    try std.testing.expectEqual(@as(u64, 4), frame.countColor(0x0000FFFF));
    try std.testing.expectEqual(@as(u64, 4), frame.countColor(0xFFFFFFFF));
    try std.testing.expectEqual(@as(u64, 0), frame.countColor(0x101010FF)); // no bg shows
}

// --- Test helpers ---

fn tapCounterCb(userdata: ?*anyopaque) void {
    const count: *u32 = @ptrCast(@alignCast(userdata.?));
    count.* += 1;
}

test "avatar: i18n — the default label localizes; an app label is verbatim" {
    const a = std.testing.allocator;
    const i18n = try i18n_mod.I18n.init(a, "en");
    defer i18n.deinit();
    try i18n.addArb("en", "{}", .ltr);
    try i18n.addArb("es", "{\"@@locale\": \"es\", \"Avatar\": \"Imagen de perfil\"}", .ltr);
    try i18n.setLocale("es");
    i18n_mod.setCurrent(i18n);
    defer i18n_mod.setCurrent(null);
    // no a11y_label + no initials → the localized fallback
    const n = try avatar(a, null, .{});
    defer n.deinit();
    try std.testing.expectEqualStrings("Imagen de perfil", n.semantics.?.label);
    try i18n.setLocale("en");
    try std.testing.expectEqualStrings("Avatar", n.semantics.?.label);
    const n2 = try avatar(a, null, .{ .a11y_label = "Jane's photo" });
    defer n2.deinit();
    try i18n.setLocale("es");
    try std.testing.expectEqualStrings("Jane's photo", n2.semantics.?.label);
}
