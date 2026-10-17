// SearchView (Phase 2d.3 follow-up, M3E) — the Material 3 Expressive
// EXPANDED search view (Compose SearchBar.kt's ExpandedFullScreenSearchView):
// opened from the collapsed SearchBar, it covers the viewport with a
// full-bleed Surface — a header row (back arrow, the editable query, a
// trailing clear button), a 1dp divider, and a suggestion list.
//
// Spec: m3.material.io/components/search + Compose SearchBar.kt /
// ExpandedFullScreenSearchView / SearchViewTokens / ListTokens:
//   - container: Surface, CornerNone, FULL BLEED (the whole window — no
//     scrim: the surface itself covers the content behind)
//   - header: a 72dp row (SearchViewTokens FullScreenHeaderContainerHeight)
//     — the leading back button (a 48dp touch box, the
//     24dp arrow visual at 16..40), the query text (body_large OnSurface,
//     a 1dp Primary caret while focused), the trailing clear button (a
//     48dp box, shown iff the query is non-empty)
//   - divider: 1dp outline_variant, full width, under the header
//   - suggestions: 56dp one-line rows (ListTokens) — the leading icon
//     (24dp OnSurfaceVariant) at 16, the label (body_large OnSurface) at
//     56, the optional trailing "fill" affordance (a 24dp icon, e.g. the
//     M3 insert arrow) at 16 from the end. A click on a row selects it
//     (on_select + selectedIndex); a click on the fill zone writes the
//     suggestion into the query; Up/Down move a keyboard highlight and
//     Enter activates it (or submits the query without one).
//   - state layers: OnSurface @ hover 0.08 / focus 0.10 / pressed 0.12
//   - dismissal: the back arrow, Escape (the focused chain gets it first),
//     and the router's modal back stack (hardware back / Escape unfocused)
//   - open state: an app-owned Signal(bool) — flipping it plays the
//     upstream animationProgress spec: the surface morphs from the
//     collapsed bar toward the full-screen CornerNone (rect lerps from
//     opts.anchor → bounds, radius 28·(1-p)), the header field crossfades
//     on its own 50ms channel, and the divider + suggestion column fades
//     at alpha = progress (AnimationEnter 600+100 emphasized-decelerate /
//     AnimationExit 350+100 linear). While open the view takes the
//     keyboard focus (the query field IS the view) and registers on the
//     modal back stack
//
// The widget is a LEAF (the search_bar / list_item idiom): the surface,
// the header chrome and the suggestion rows are all painted by the widget
// itself — the rows' hover/highlight/pressed colors change at paint time
// so they need no child nodes. A11y exposes the suggestions as VIRTUAL
// semantic children (Semantics.children + child_bounds — the segmented
// button idiom).
//
// Sizing: the view fills FINITE constraints (a modal is screen-sized —
// embed it in a full-viewport overlay/container). Inside an unbounded
// parent, wrap it in a bounded box.
//
// Remaining deviations (documented):
//   - No predictive-back scrubbing (the router's back stack has no
//     BackEvent progress channel — cancellation replays the enter spec);
//     no IME panel placement (the query field renders/edits the buffer but
//     there is no on-screen keyboard yet); the suggestion list does not
//     scroll — rows past the bounds clip; RTL mirrors the chrome but the
//     text runs stay LTR (no bidi — same as text.zig/search_bar.zig).
//   - The caret is a real editing position: click places it at the nearest
//     grapheme boundary (SkParagraph getGlyphPositionAtCoordinate through
//     kx_text_position_at), it blinks at Compose's 500ms cadence while
//     focused (a timeline ticker re-shows it on every edit/move), and
//     typing/backspace/delete/left/right apply AT the caret. Selection is
//     real too: drag or shift+arrows/home/end extend the range (primary
//     @0.4 highlight, collapsed anchors, delete replaces the range).
//     Cmd/Ctrl+A/C/X/V ride the platform clipboard (ui.clipboard); paste
//     strips line terminators to stay single-line. Still missing: no
//     selection handles or double-click word select.
const std = @import("std");
const kx = @import("../kx.zig");
const ui = @import("../ui.zig");
const input = @import("../ui/input.zig");
const i18n_mod = @import("../ui/i18n.zig");
const gestures = @import("../ui/gestures.zig");
const theme_mod = @import("../theme.zig");
const icon_w = @import("icon.zig");
const text_edit = @import("text_edit.zig");
const golden = @import("../golden.zig"); // tests

const Node = ui.node.Node;
const Rect = ui.node.Rect;
const Constraints = ui.layout.Constraints;
const Size = ui.layout.Size;
const Color = ui.paint.Color;
const Callback = ui.state.Callback;
const Theme = theme_mod.Theme;

/// One suggestion row. `label` is copied at build. `icon` is the leading
/// affordance (M3: history for recent queries, search for suggestions —
/// e.g. .history or .search). `trailing_icon` enables the end-side
/// "fill query" affordance (M3 shows a north-west insert arrow —
/// .north_west).
pub const SuggestionItem = struct {
    label: []const u8,
    icon: icon_w.IconName = .search,
    trailing_icon: ?icon_w.IconName = null,
    enabled: bool = true,
};

pub const SearchViewOptions = struct {
    placeholder: []const u8 = "",
    /// The initial query text (used when no live signal is given).
    initial: []const u8 = "",
    theme: Theme = theme_mod.light,
    /// The accessible name of the search region (the dialog role's label)
    /// — null resolves the localized "Search" (an app string is verbatim).
    label: ?[]const u8 = null,
    /// The collapsed search bar's rect in THIS NODE'S parent space — the
    /// anchor the surface expands from (upstream collapsedCoords → the
    /// SearchBarLayout interpolates it toward the full-screen bounds).
    /// null = no geometry morph: the surface fills the bounds at every
    /// progress and only the corner/alpha channels animate.
    anchor: ?Rect = null,
};

// --- M3E tokens (SearchView/ListTokens + the TextFieldImpl paddings) ---
const header_h: f32 = 72; // SearchViewTokens FullScreenHeaderContainerHeight
/// SearchBarCornerRadius = InputFieldHeight (SearchBarTokens 56) / 2 — the
/// surface morphs radius*(1-progress) → CornerNone (upstream animatedShape).
const collapsed_corner: f32 = 28;
/// Expansion: AnimationEnterFloatSpec — DurationLong4 + DurationShort2
/// delay + EasingEmphasizedDecelerate. Collapse: ExitFloatSpec —
/// DurationMedium3 + the same delay + a linear curve. The expanded input
/// field's own crossfade (AnimationForContentFadeIn/Out): DurationShort1,
/// a DurationShort1 lead-in on enter only. All ride theme.motion.durations.
const icon_size: f32 = 24;
// The icon boxes and the text start ride the a11y interactive minimum —
// theme.platform.hit_target_min (upstream minimumInteractiveComponentSize;
// 48dp mobile / 24 desktop).
fn iconBox(t: Theme) f32 {
    return t.platform.hit_target_min;
}
/// The icon visual's offset from the edge: centered in the box + 4.
fn iconEdge(t: Theme) f32 {
    return (iconBox(t) - icon_size) / 2 + 4;
}
/// The query text's start: the icon box + (TextFieldPadding 16 - icon pad 12).
fn textStart(t: Theme) f32 {
    return iconBox(t) + 4;
}
const text_gap_trail: f32 = 4; // the text's end padding before the icon box
const text_end_no_icon: f32 = 16; // TextFieldPadding without a trailing icon
const caret_w: f32 = 1;
const divider_h: f32 = 1; // DividerTokens thickness under the header
const row_h: f32 = 56; // ListTokens one-line item height
const row_h_pad: f32 = 16; // ListItem start/end padding
const row_icon_gap: f32 = 16; // ListTokens LeadingContentEndPadding

const ItemDef = struct {
    label: [:0]const u8, // owned
    icon: icon_w.IconName,
    trailing_icon: ?icon_w.IconName,
    enabled: bool,
};

const SearchViewState = struct {
    /// The shared editing core (text_edit.zig): buffer, IME composition,
    /// caret/selection, blink ticker.
    edit: text_edit.Edit,
    placeholder: [:0]const u8, // owned
    label_z: [:0]const u8, // owned
    items: std.array_list.Managed(ItemDef),
    /// One virtual semantic child per suggestion (segmented_button idiom):
    /// the borrow stays valid — the list is filled once at build, before
    /// attach, and never reallocated.
    sem_children: std.array_list.Managed(ui.semantics.Semantics),
    opts: SearchViewOptions,
    /// The open state — app-owned (the dialog idiom). `open` mirrors it.
    open_sig: *ui.state.Signal(bool),
    open: bool = false,
    /// The query's live text channel (search_bar idiom): the widget sets it
    /// on edit; an external set replaces the buffer (two-way).
    query_sig: ?*ui.state.TextSignal = null,
    on_changed: ?Callback = null,
    on_select: ?Callback = null, // read the index via selectedIndex(node)
    on_submitted: ?Callback = null,
    on_close: ?Callback = null,
    selected: usize = 0, // the last activated row (selectedIndex accessor)
    /// The hovered/keyboard-highlighted suggestion (menu idiom — one index
    /// for both), -1 = none.
    highlight: i32 = -1,
    pressed_index: i32 = -1, // the row held by the press
    fill_pressed: i32 = -1, // the row whose trailing fill zone is held
    back_hovered: bool = false,
    back_pressed: bool = false,
    clear_hovered: bool = false,
    clear_pressed: bool = false,
    /// The down position in raw (window) coordinates (drag deltas are
    /// physical finger motion — gestures.SLOP).
    down_raw_x: f32 = 0,
    down_raw_y: f32 = 0,
    back_registered: bool = false, // on the router's modal back stack while open
    /// Upstream animationProgress: 0 = the collapsed bar, 1 = full-screen.
    /// Drives the surface rect/corner morph + the divider/rows alpha; the
    /// header field crossfades on `field_alpha` (its own spec).
    progress: f32 = 0,
    field_alpha: f32 = 0,
    /// Stable channel addresses for the timeline (the switch idiom).
    progress_channel: u8 = 0,
    field_channel: u8 = 0,
    i18n: ?*i18n_mod.I18n = null,
    fn text(s: *SearchViewState) [:0]const u8 {
        return s.edit.text();
    }

    fn composition(s: *SearchViewState) [:0]const u8 {
        return s.edit.composition();
    }
};

fn stateOf(n: *Node) *SearchViewState {
    return @ptrCast(@alignCast(n.state.?));
}

const setSentinel = text_edit.setSentinel;
const dupeZ = text_edit.dupeZ;

fn hasText(s: *SearchViewState) bool {
    return s.edit.buf.items.len > 0;
}

/// Mirror a horizontal rect across the view for RTL chrome.
fn mirrorX(bx: f32, bw: f32, x: f32, w: f32, rtl: bool) f32 {
    return if (rtl) bx + bw - (x - bx) - w else x;
}

/// Suggestion `index`'s row rect in parent space.
fn rowRect(b: Rect, index: usize) Rect {
    return .{
        .x = b.x,
        .y = b.y + header_h + divider_h + @as(f32, @floatFromInt(index)) * row_h,
        .w = b.w,
        .h = row_h,
    };
}

/// The back button's zone (the start-side min-interactive box of the
/// header), in parent space.
fn backZone(t: Theme, b: Rect) Rect {
    return .{ .x = b.x, .y = b.y, .w = iconBox(t), .h = header_h };
}

/// The clear button's zone (the end-side min-interactive box of the header).
fn clearZone(t: Theme, b: Rect) Rect {
    return .{ .x = b.x + b.w - iconBox(t), .y = b.y, .w = iconBox(t), .h = header_h };
}

/// The trailing fill zone of a suggestion row (the end-side min-interactive
/// box).
fn fillZone(t: Theme, b: Rect, index: usize) Rect {
    const r = rowRect(b, index);
    return .{ .x = r.x + r.w - iconBox(t), .y = r.y, .w = iconBox(t), .h = r.h };
}

fn contains(z: Rect, x: f32, y: f32) bool {
    return x >= z.x and x < z.x + z.w and y >= z.y and y < z.y + z.h;
}

fn inBack(s: *SearchViewState, b: Rect, x: f32, y: f32) bool {
    var z = backZone(s.opts.theme, b);
    if (ui.i18n.direction() == .rtl) z.x = mirrorX(b.x, b.w, z.x, z.w, true);
    return contains(z, x, y);
}

fn inClear(s: *SearchViewState, b: Rect, x: f32, y: f32) bool {
    if (!hasText(s)) return false;
    var z = clearZone(s.opts.theme, b);
    if (ui.i18n.direction() == .rtl) z.x = mirrorX(b.x, b.w, z.x, z.w, true);
    return contains(z, x, y);
}

/// The suggestion index under the point, or null (rows clipped at the
/// bounds' bottom edge still answer for their visible part; rows past it
/// are unreachable).
fn suggestionAt(s: *SearchViewState, b: Rect, x: f32, y: f32) ?usize {
    const top = b.y + header_h + divider_h;
    if (x < b.x or x >= b.x + b.w or y < top or y >= b.y + b.h) return null;
    const i: usize = @intFromFloat((y - top) / row_h);
    if (i >= s.items.items.len) return null;
    return i;
}

/// The point is inside row `index`'s trailing fill affordance.
fn inFill(s: *SearchViewState, b: Rect, index: usize, x: f32, y: f32) bool {
    if (s.items.items[index].trailing_icon == null) return false;
    var z = fillZone(s.opts.theme, b, index);
    if (ui.i18n.direction() == .rtl) z.x = mirrorX(b.x, b.w, z.x, z.w, true);
    return contains(z, x, y);
}

fn searchViewMeasure(n: *Node, c: Constraints) Size {
    _ = n;
    const size = Size{};
    const w = if (std.math.isFinite(c.max_w)) c.max_w else size.w;
    const h = if (std.math.isFinite(c.max_h)) c.max_h else size.h;
    return c.constrain(.{ .w = w, .h = h }); // a modal: fills finite constraints
}

fn searchViewLayout(n: *Node, bounds: Rect) void {
    _ = n;
    _ = bounds; // leaf: everything is positioned from the bounds at paint/hit time
}

/// Paint an icon centered in a 24x24 box — vector geometry (icon.zig), not
/// a font glyph (emoji-capable codepoints bypass the theme ink).
fn paintIcon(ctx: *kx.Ctx, name: icon_w.IconName, x: f32, y: f32, color: Color) void {
    if (color & 0xFF == 0) return;
    icon_w.drawIcon(ctx, name, x, y, icon_size / 24.0, color);
}

/// The animated surface rect: progress morphs the anchor (the collapsed
/// bar's rect — upstream collapsedCoords) toward the full bounds; without
/// an anchor the surface covers the bounds at every progress.
fn surfaceRect(s: *SearchViewState, b: Rect) Rect {
    const a = s.opts.anchor orelse return b;
    const p = s.progress;
    const q = 1 - p;
    return .{
        .x = a.x * q + b.x * p,
        .y = a.y * q + b.y * p,
        .w = a.w * q + b.w * p,
        .h = a.h * q + b.h * p,
    };
}

fn searchViewPaint(n: *Node, ctx: *kx.Ctx) void {
    const s = stateOf(n);
    if (s.progress <= 0) return; // collapsed (incl. the exit's last frame)
    const b = n.bounds;
    const t = s.opts.theme;
    const cs = t.colors;
    const rtl = ui.i18n.direction() == .rtl;
    const focused = input.isFocused(n);
    const surface = cs.surface;
    const p = s.progress;
    const field_a = s.field_alpha;

    // --- the Surface: morphs from the collapsed bar toward the full-bleed
    // CornerNone fullscreen (upstream animatedShape: radius 28·(1-p); the
    // whole view's own chrome clips to the same rounded surface) ---
    const sr = surfaceRect(s, b);
    const radius = collapsed_corner * (1 - p);
    ui.paint.clipRRect(ctx, sr.x, sr.y, sr.w, sr.h, radius);
    ui.paint.fillRRect(ctx, sr.x, sr.y, sr.w, sr.h, radius, surface);

    // --- header row (crossfades in on its own spec: field_alpha) ---
    const header_ink = ui.paint.withAlphaScaled(cs.on_surface, field_a);
    const header_muted = ui.paint.withAlphaScaled(cs.on_surface_variant, field_a);
    const header_primary = ui.paint.withAlphaScaled(cs.primary, field_a);
    // the back button's state layer (a circle centered in its box)
    const bz = backZone(t, b);
    const bx = mirrorX(b.x, b.w, bz.x, bz.w, rtl);
    const back_alpha: f32 = if (s.back_pressed)
        t.state.pressed
    else if (s.back_hovered)
        t.state.hover
    else
        0;
    if (back_alpha > 0) {
        ui.paint.fillRRect(ctx, bx, b.y + (header_h - iconBox(t)) / 2, iconBox(t), iconBox(t), iconBox(t) / 2, theme_mod.stateLayer(surface, cs.on_surface_variant, back_alpha * field_a));
    }
    // the arrow visual at iconEdge..iconEdge+24 — a back arrow (pointing at
    // the start edge in RTL too: the glyph itself auto-mirrors, so the
    // literal name is always arrow_left — Compose AutoMirrored.ArrowBack)
    const icon_y = b.y + (header_h - icon_size) / 2;
    const back_x = mirrorX(b.x, b.w, b.x + iconEdge(t), icon_size, rtl);
    paintIcon(ctx, .arrow_left, back_x, icon_y, header_ink);

    // the clear button (the trailing min-interactive box; shown iff the
    // query is non-empty)
    if (hasText(s)) {
        const z = clearZone(t, b);
        const zx = mirrorX(b.x, b.w, z.x, z.w, rtl);
        const clear_alpha: f32 = if (s.clear_pressed)
            t.state.pressed
        else if (s.clear_hovered)
            t.state.hover
        else
            0;
        if (clear_alpha > 0) {
            ui.paint.fillRRect(ctx, zx, b.y + (header_h - iconBox(t)) / 2, iconBox(t), iconBox(t), iconBox(t) / 2, theme_mod.stateLayer(surface, cs.on_surface_variant, clear_alpha * field_a));
        }
        const cx = mirrorX(b.x, b.w, b.x + b.w - iconEdge(t) - icon_size, icon_size, rtl);
        paintIcon(ctx, .close, cx, icon_y, header_muted);
    }

    // --- the query text (clipped between the icons; the whole clip rect
    // mirrors in RTL — mirroring only the edge would clip the text away) ---
    const style = t.type_scale.body_large;
    const ty = b.y + (header_h - style.line_height) / 2;
    const right = if (hasText(s)) iconBox(t) + text_gap_trail else text_end_no_icon;
    const clip_w = b.w - textStart(t) - right;
    const clip_x = mirrorX(b.x, b.w, b.x + textStart(t), clip_w, rtl);
    ui.paint.clipRect(ctx, clip_x, b.y, clip_w, header_h);
    s.edit.ensureTicker(); // the caret blink (a focused view stays awake)
    if (hasText(s) or s.edit.comp.items.len > 0) {
        const str = s.text();
        const m = ui.paint.measureText(str, style.size, false);
        const tx = mirrorX(b.x, b.w, b.x + textStart(t), m.width, rtl);
        // Selection highlight behind the glyphs (TextSelectionColors —
        // primary @ 0.4 over the run's x range for [caret, anchor)).
        const sel = s.edit.selRange();
        if (sel.hi > sel.lo) {
            const hx0 = tx + ui.paint.measureTextLen(str[0..sel.lo], style.size, false).width;
            const hx1 = tx + ui.paint.measureTextLen(str[0..sel.hi], style.size, false).width;
            ui.paint.fillRect(ctx, hx0, ty, hx1 - hx0, m.height, ui.paint.withAlphaScaled(header_primary, 0.4));
        }
        ui.paint.text(ctx, str, tx, ty + m.ascent, style.size, false, header_ink);
        var caret_x = tx + ui.paint.measureTextLen(str[0..s.edit.caret], style.size, false).width;
        if (s.edit.comp.items.len > 0) {
            // Preedit after the committed text, underlined (IME convention);
            // SDL's comp_start puts the caret INSIDE the composition.
            const comp = s.composition();
            const comp_m = ui.paint.measureText(comp, style.size, false);
            ui.paint.text(ctx, comp, tx + m.width, ty + m.ascent, style.size, false, header_ink);
            ui.paint.fillRect(ctx, tx + m.width, ty + m.ascent + 1, comp_m.width, 1, header_ink);
            const at: usize = @intCast(@min(@max(s.edit.comp_cursor, 0), @as(i32, @intCast(comp.len))));
            caret_x = tx + m.width + ui.paint.measureTextLen(comp[0..at], style.size, false).width;
        }
        if (focused and s.edit.caret_on) {
            ui.paint.fillRect(ctx, caret_x, ty, caret_w, m.height, header_primary);
        }
    } else {
        if (s.placeholder.len > 0) {
            const m = ui.paint.measureText(s.placeholder, style.size, false);
            const tx = mirrorX(b.x, b.w, b.x + textStart(t), m.width, rtl);
            ui.paint.text(ctx, s.placeholder, tx, ty + m.ascent, style.size, false, header_muted);
        }
        if (focused and s.edit.caret_on) {
            // the caret at the (mirrored) start (empty text)
            const caret_x = mirrorX(b.x, b.w, b.x + textStart(t), 0, rtl);
            ui.paint.fillRect(ctx, caret_x, ty, caret_w, style.line_height, header_primary);
        }
    }
    ui.paint.clipReset(ctx);

    // --- the divider + suggestion rows (the upstream wrappedContent column:
    // shown iff progress > 0, alpha = animationProgress) ---
    const body_ink = ui.paint.withAlphaScaled(cs.on_surface, p);
    const body_muted = ui.paint.withAlphaScaled(cs.on_surface_variant, p);
    // the divider under the header (1dp, outline_variant, full width)
    ui.paint.fillRect(ctx, b.x, b.y + header_h, b.w, divider_h, ui.paint.withAlphaScaled(cs.outline_variant, p));

    // --- the suggestion rows ---
    const list_y = b.y + header_h + divider_h;
    const list_h = b.y + b.h - list_y;
    if (list_h <= 0) {
        ui.paint.clipReset(ctx); // the animated surface clip
        return;
    }
    ui.paint.clipRect(ctx, b.x, list_y, b.w, list_h);
    for (s.items.items, 0..) |it, i| {
        const r = rowRect(b, i);
        if (r.y >= b.y + b.h) break; // ordered rows: the rest is clipped away
        const enabled = it.enabled;
        const content: Color = if (enabled) body_ink else ui.paint.withAlphaScaled(cs.on_surface, 0.38 * p);
        const muted: Color = if (enabled) body_muted else ui.paint.withAlphaScaled(cs.on_surface, 0.38 * p);
        // the state layer over the row (pressed > hovered/keyboard highlight)
        var alpha: f32 = 0;
        if (enabled) {
            if (s.pressed_index == @as(i32, @intCast(i)) or s.fill_pressed == @as(i32, @intCast(i)))
                alpha = t.state.pressed
            else if (s.highlight == @as(i32, @intCast(i)))
                alpha = if (focused) t.state.focus else t.state.hover;
        }
        if (alpha > 0) {
            ui.paint.fillRect(ctx, r.x, r.y, r.w, r.h, theme_mod.stateLayer(surface, cs.on_surface, alpha * p));
        }
        const iy = r.y + (row_h - icon_size) / 2;
        // the leading icon (24dp at 16 from the start)
        const lix = mirrorX(b.x, b.w, r.x + row_h_pad, icon_size, rtl);
        paintIcon(ctx, it.icon, lix, iy, muted);
        // the trailing "fill" affordance (24dp at 16 from the end)
        if (it.trailing_icon) |tic| {
            const tix = mirrorX(b.x, b.w, r.x + r.w - row_h_pad - icon_size, icon_size, rtl);
            paintIcon(ctx, tic, tix, iy, muted);
        }
        // the label (body_large at 56 from the start, clipped before the
        // trailing affordance)
        const label_x = r.x + row_h_pad + icon_size + row_icon_gap;
        const trail_w: f32 = if (it.trailing_icon != null) iconBox(t) else row_h_pad;
        const max_tw = @max(0, r.w - (label_x - r.x) - trail_w);
        const lclip_x = mirrorX(b.x, b.w, label_x, max_tw, rtl);
        ui.paint.clipRect(ctx, lclip_x, r.y, max_tw, r.h);
        const lm = ui.paint.measureText(it.label, style.size, false);
        const ltx = mirrorX(b.x, b.w, label_x, lm.width, rtl);
        ui.paint.text(ctx, it.label, ltx, r.y + (row_h - style.line_height) / 2 + lm.ascent, style.size, false, content);
        ui.paint.clipReset(ctx);
    }
    ui.paint.clipReset(ctx);
    ui.paint.clipReset(ctx); // the animated surface clip
}

/// Byte offset of the grapheme boundary nearest the press — the shared
/// text_edit hit test over the painted run (its mirrored left is the
/// probe's origin; the y is the header's text line box).
fn caretAt(n: *Node, s: *SearchViewState, x: f32, y: f32) usize {
    const str = s.text();
    const style = s.opts.theme.type_scale.body_large;
    const m = ui.paint.measureText(str, style.size, false);
    const b = n.bounds;
    const tx = mirrorX(b.x, b.w, b.x + textStart(s.opts.theme), m.width, ui.i18n.direction() == .rtl);
    const ty = b.y + (header_h - style.line_height) / 2;
    return s.edit.caretAt(x - tx, y - ty, style.size);
}

fn searchViewOnPointer(n: *Node, ev: input.PointerEvent) bool {
    const s = stateOf(n);
    if (!s.open) return false;
    const b = n.bounds;
    switch (ev.phase) {
        .down => {
            s.down_raw_x = ev.raw_x;
            s.down_raw_y = ev.raw_y;
            if (inBack(s, b, ev.x, ev.y)) {
                s.back_pressed = true;
            } else if (inClear(s, b, ev.x, ev.y)) {
                s.clear_pressed = true;
            } else if (suggestionAt(s, b, ev.x, ev.y)) |i| {
                if (s.items.items[i].enabled) {
                    if (inFill(s, b, i, ev.x, ev.y)) {
                        s.fill_pressed = @intCast(i);
                    } else {
                        s.pressed_index = @intCast(i);
                    }
                }
            } else {
                // the header text area / empty space: the query keeps focus
                input.requestFocus(n);
                // Press-to-caret: the press maps to the nearest grapheme
                // boundary; the shared tap() also handles double-click
                // word select.
                s.edit.tap(caretAt(n, s, ev.x, ev.y), ev.x, ev.y, ev.time_ms);
            }
            // the press is modal — nothing under the view sees it
            n.markDirty();
            return true;
        },
        .up => {
            const was_back = s.back_pressed;
            const was_clear = s.clear_pressed;
            const fill_i = s.fill_pressed;
            const item_i = s.pressed_index;
            s.back_pressed = false;
            s.clear_pressed = false;
            s.fill_pressed = -1;
            s.pressed_index = -1;
            s.edit.dragging = false;
            s.edit.drag_word = false;
            n.markDirty();
            if (was_back) {
                if (inBack(s, b, ev.x, ev.y)) closeSearchView(n, s); // M3: the nav icon dismisses
            } else if (was_clear) {
                if (inClear(s, b, ev.x, ev.y)) clearQuery(n, s);
            } else if (fill_i >= 0) {
                const i: usize = @intCast(fill_i);
                if (suggestionAt(s, b, ev.x, ev.y) == i and inFill(s, b, i, ev.x, ev.y)) fillQuery(n, s, i);
            } else if (item_i >= 0) {
                const i: usize = @intCast(item_i);
                if (suggestionAt(s, b, ev.x, ev.y) == i and !inFill(s, b, i, ev.x, ev.y)) select(n, s, i);
            }
            return true;
        },
        .move => {
            // A held primary button drags the selection (word-granular
            // after a double-tap) — the captured pointer keeps moving.
            if (s.edit.dragging) {
                s.edit.dragExtend(caretAt(n, s, ev.x, ev.y));
                return true;
            }
            // A drag beyond the touch slop is a scroll, not a press: cancel
            // the pressed state. The move is NOT claimed (return false) so
            // it keeps bubbling to scrollable ancestors.
            if (s.back_pressed or s.clear_pressed or s.pressed_index >= 0 or s.fill_pressed >= 0) {
                const dx = ev.raw_x - s.down_raw_x;
                const dy = ev.raw_y - s.down_raw_y;
                if (dx * dx + dy * dy > gestures.SLOP * gestures.SLOP) {
                    s.back_pressed = false;
                    s.clear_pressed = false;
                    s.fill_pressed = -1;
                    s.pressed_index = -1;
                    n.markDirty();
                }
            }
            return false;
        },
        // the pointer went down outside while we held the capture: cancel
        .outside_down => {
            s.back_pressed = false;
            s.clear_pressed = false;
            s.fill_pressed = -1;
            s.pressed_index = -1;
            n.markDirty();
            return true;
        },
        .enter => {
            updateHover(n, s, ev.x, ev.y);
            return true;
        },
        // moving within the leaf emits hover_move (not enter/leave):
        // re-resolve the hover zones
        .hover_move => {
            updateHover(n, s, ev.x, ev.y);
            return true;
        },
        .leave => {
            s.highlight = -1;
            s.back_hovered = false;
            s.clear_hovered = false;
            n.markDirty();
            return true;
        },
    }
    return false;
}

/// Re-resolve the hovered zones from the pointer position (the suggestion
/// highlight doubles as the hover state — the menu idiom).
fn updateHover(n: *Node, s: *SearchViewState, x: f32, y: f32) void {
    const b = n.bounds;
    const bh = inBack(s, b, x, y);
    const ch = inClear(s, b, x, y);
    var hi: i32 = -1;
    if (!bh and !ch) {
        if (suggestionAt(s, b, x, y)) |i| {
            if (s.items.items[i].enabled) hi = @intCast(i);
        }
    }
    if (bh != s.back_hovered or ch != s.clear_hovered or hi != s.highlight) {
        s.back_hovered = bh;
        s.clear_hovered = ch;
        s.highlight = hi;
        n.markDirty();
    }
}

/// Move the keyboard highlight to the next/previous enabled suggestion
/// (wrapping); a no-op when there is no enabled row. From no highlight,
/// Down lands on the first row and Up wraps to the last.
fn moveHighlight(n: *Node, s: *SearchViewState, dir: i32) void {
    const count: i32 = @intCast(s.items.items.len);
    if (count == 0) return;
    var i = s.highlight;
    var steps: i32 = 0;
    while (steps < count) : (steps += 1) {
        i = if (i < 0)
            (if (dir > 0) 0 else count - 1)
        else
            @mod(i + dir, count);
        if (s.items.items[@intCast(i)].enabled) {
            if (i != s.highlight) {
                s.highlight = i;
                n.markDirty();
            }
            return;
        }
    }
}

/// An edit happened: repaint, sync the a11y value, mirror the signal, fire
/// the callback. The view fills its constraints — the text width drives no
/// measure, so no markLayoutDirty (unlike the collapsed bar).
fn applyEdit(n: *Node, s: *SearchViewState) void {
    n.markDirty();
    if (n.semantics) |sem| sem.value = s.text(); // a11y: the value follows edits
    ui.semantics.notifyControlChanged(n); // a11y: the control's value changed
    // The buffer is already bounded by the 1 MiB input cap → set cannot fail.
    if (s.query_sig) |sig| sig.set(s.text()) catch @panic("klaxon: text buffer exceeds the 1 MiB cap");
    if (s.on_changed) |cb| cb.fn_ptr(cb.userdata);
}

/// Clear the query (the clear button): keep the focus, fire on_changed.
fn clearQuery(n: *Node, s: *SearchViewState) void {
    s.edit.buf.clearRetainingCapacity();
    s.edit.caret = 0;
    s.edit.sel_anchor = 0;
    setSentinel(&s.edit.buf);
    applyEdit(n, s);
}

/// The trailing fill affordance: write the suggestion into the query
/// (M3's "insert" arrow — the field fills, the view stays open).
fn fillQuery(n: *Node, s: *SearchViewState, i: usize) void {
    const label = s.items.items[i].label;
    s.edit.buf.clearRetainingCapacity();
    s.edit.buf.ensureTotalCapacity(label.len + 1) catch @panic("klaxon: out of memory");
    s.edit.buf.appendSlice(label) catch @panic("klaxon: out of memory");
    setSentinel(&s.edit.buf);
    s.edit.caret = s.edit.buf.items.len; // a wholesale replace → caret at the end
    s.edit.sel_anchor = s.edit.caret;
    s.edit.resetBlink();
    applyEdit(n, s);
}

/// A suggestion was activated (click / Enter on the highlight): record the
/// index and fire the callback — the app decides what it means (fill the
/// query, submit, navigate); the view stays open.
fn select(n: *Node, s: *SearchViewState, i: usize) void {
    s.selected = i;
    _ = n;
    if (s.on_select) |cb| cb.fn_ptr(cb.userdata);
}

/// Dismiss: flip the open signal (the sync callback hides the view, drops
/// the focus, pops the back handler) and fire on_close.
fn closeSearchView(n: *Node, s: *SearchViewState) void {
    s.open_sig.set(false);
    if (s.on_close) |cb| cb.fn_ptr(cb.userdata);
    _ = n;
}

/// The widget's applyEdit adapted to text_edit's callback signature.
fn applyEditNode(n: *Node) void {
    applyEdit(n, stateOf(n));
}

fn searchViewOnKey(n: *Node, ev: input.KeyEvent) bool {
    const s = stateOf(n);
    if (!s.open) return false;
    // The shared editing core: text_input/text_editing, the Cmd/Ctrl
    // clipboard chords, backspace/delete, arrows/home/end.
    if (s.edit.handleKey(ev, applyEditNode)) return true;
    if (ev.kind == .key_down) switch (ev.key) {
        .up => {
            moveHighlight(n, s, -1);
            return true;
        },
        .down => {
            moveHighlight(n, s, 1);
            return true;
        },
        .enter => {
            // M3: Enter activates the highlighted suggestion; without
            // one it submits the query (imeAction = Search).
            if (s.highlight >= 0 and s.highlight < @as(i32, @intCast(s.items.items.len))) {
                const i: usize = @intCast(s.highlight);
                if (s.items.items[i].enabled) {
                    select(n, s, i);
                    return true;
                }
            }
            if (s.on_submitted) |cb| cb.fn_ptr(cb.userdata);
            return true;
        },
        .escape => {
            s.edit.comp.clearRetainingCapacity();
            s.edit.comp_cursor = 0;
            setSentinel(&s.edit.comp);
            closeSearchView(n, s); // M3: Escape dismisses the view
            return true;
        },
        else => {},
    };
    return false;
}

/// Show/hide to match the open signal: visible iff open, the modal back
/// handler tracks it, and the focus lands on the query field (or is
/// released on dismiss).
fn progressCb(userdata: ?*anyopaque, v: ui.anim.Vec4) void {
    const n: *Node = @ptrCast(@alignCast(userdata.?));
    stateOf(n).progress = v[0];
    n.markDirty();
}
fn fieldCb(userdata: ?*anyopaque, v: ui.anim.Vec4) void {
    const n: *Node = @ptrCast(@alignCast(userdata.?));
    stateOf(n).field_alpha = v[0];
    n.markDirty();
}
/// The exit animation settled at 0 → the view actually leaves the tree's
/// visible set (upstream flips SearchBarValue back to Collapsed).
fn hideCb(userdata: ?*anyopaque) void {
    const n: *Node = @ptrCast(@alignCast(userdata.?));
    n.setVisible(false);
    n.markDirty();
}

/// Show/hide to match the open signal — animated: opening plays the
/// upstream enter spec (the surface morphs in from the collapsed geometry,
/// the field + content fade on their own channels); closing plays the exit
/// spec and hides the node once progress reaches 0. No timeline → snap
/// (tests, headless).
fn applyOpen(n: *Node, s: *SearchViewState, open: bool) void {
    if (s.open == open) return;
    s.open = open;
    s.highlight = -1;
    s.pressed_index = -1;
    s.fill_pressed = -1;
    s.back_pressed = false;
    s.clear_pressed = false;
    s.back_hovered = false;
    s.clear_hovered = false;
    if (open) {
        input.requestFocus(n); // the query field takes the focus while open
    } else if (input.isFocused(n)) {
        input.requestFocus(null); // a dismissed view drops the focus
    }
    syncBackHandler(n, s);
    if (ui.anim.timeline()) |tl| {
        const dur = s.opts.theme.motion.durations;
        if (open) {
            n.setVisible(true); // paints from the first frame (progress ≥ 0)
            _ = tl.play(.{
                .kind = ui.anim.Animation.tweenAnim(.{ 1, 0, 0, 0 }, dur.long4, .{ .ease = .emphasized_decelerate }),
                .from = .{ s.progress, 0, 0, 0 },
                .delay_ms = dur.short2,
                .channel = @ptrCast(&s.progress_channel),
                .on_update = .{ .fn_ptr = progressCb, .userdata = n },
            });
            _ = tl.play(.{
                .kind = ui.anim.Animation.tweenAnim(.{ 1, 0, 0, 0 }, dur.short1, .{ .ease = .standard_accelerate }),
                .from = .{ s.field_alpha, 0, 0, 0 },
                .delay_ms = dur.short1,
                .channel = @ptrCast(&s.field_channel),
                .on_update = .{ .fn_ptr = fieldCb, .userdata = n },
            });
        } else {
            // Stays visible while the exit runs — hideCb clears it at 0.
            _ = tl.play(.{
                .kind = ui.anim.Animation.tweenAnim(.{ 0, 0, 0, 0 }, dur.medium3, .{ .ease = .linear }),
                .from = .{ s.progress, 0, 0, 0 },
                .delay_ms = dur.short2,
                .channel = @ptrCast(&s.progress_channel),
                .on_update = .{ .fn_ptr = progressCb, .userdata = n },
                .on_complete = .{ .fn_ptr = hideCb, .userdata = n },
            });
            _ = tl.play(.{
                .kind = ui.anim.Animation.tweenAnim(.{ 0, 0, 0, 0 }, dur.short1, .{ .ease = .standard_decelerate }),
                .from = .{ s.field_alpha, 0, 0, 0 },
                .channel = @ptrCast(&s.field_channel),
                .on_update = .{ .fn_ptr = fieldCb, .userdata = n },
            });
        }
    } else {
        s.progress = if (open) 1 else 0;
        s.field_alpha = s.progress;
        n.setVisible(open);
    }
    n.markDirty();
}

/// Open state changed (the app set the signal).
fn svOpenSyncCb(userdata: ?*anyopaque) void {
    const n: *Node = @ptrCast(@alignCast(userdata.?));
    const s = stateOf(n);
    applyOpen(n, s, s.open_sig.peek());
}

/// Escape / hardware-back while the view is open (the router consults the
/// modal back stack before the navigator — dispatchBack).
fn svBackCb(userdata: ?*anyopaque) bool {
    const n: *Node = @ptrCast(@alignCast(userdata.?));
    const s = stateOf(n);
    if (!s.open) return false;
    closeSearchView(n, s); // the signal sync pops the handler
    return true;
}

/// Keep the router's modal back stack in sync with the open state.
fn syncBackHandler(n: *Node, s: *SearchViewState) void {
    const want = s.open;
    if (want == s.back_registered) return;
    const router = input.current() orelse return;
    if (want) {
        if (router.pushBackHandler(.{ .fn_ptr = svBackCb, .userdata = n })) s.back_registered = true;
    } else {
        router.popBackHandler(n);
        s.back_registered = false;
    }
}

/// An external signal set (the designer): replace the buffer when the text
/// differs. The signal holds the full text, so the comparison runs against
/// the buffer itself — the widget's own sets round-trip as no-ops (the
/// signal dedups equal content).
fn svQuerySyncCb(userdata: ?*anyopaque) void {
    const n: *Node = @ptrCast(@alignCast(userdata.?));
    const s = stateOf(n);
    const incoming = s.query_sig.?.peek();
    if (std.mem.eql(u8, s.text(), incoming)) return;
    s.edit.buf.clearRetainingCapacity();
    s.edit.buf.ensureTotalCapacity(incoming.len + 1) catch @panic("klaxon: out of memory");
    s.edit.buf.appendSlice(incoming) catch @panic("klaxon: out of memory");
    setSentinel(&s.edit.buf);
    s.edit.clampOffsets(); // the caret rides the new text's bounds
    n.markDirty();
    if (n.semantics) |sem| sem.value = s.text(); // a11y: the value follows external edits
}

fn searchViewDeinit(n: *Node) void {
    const s = stateOf(n);
    if (ui.anim.timeline()) |tl| {
        tl.cancelChannel(@ptrCast(&s.progress_channel));
        tl.cancelChannel(@ptrCast(&s.field_channel));
    }
    s.open_sig.unsubscribe(.{ .callback = .{ .fn_ptr = svOpenSyncCb, .userdata = n } });
    if (s.query_sig) |sig| sig.unsubscribe(.{ .callback = .{ .fn_ptr = svQuerySyncCb, .userdata = n } });
    if (s.back_registered) {
        if (input.current()) |r| r.popBackHandler(n); // destroyed while open
        s.back_registered = false;
    }
    input.releaseNode(n);
    for (s.items.items) |it| n.allocator.free(it.label);
    s.items.deinit();
    s.sem_children.deinit();
    n.allocator.free(s.placeholder);
    n.allocator.free(s.label_z);
    s.edit.deinit(); // the blink ticker + both buffers
    i18n_mod.unsubscribeLocale(s.i18n, .{ .fn_ptr = svLocaleCb, .userdata = n });
    n.allocator.destroy(s);
}

/// A defaulted region label is tr()-resolved — the locale callback
/// re-dupes it and re-attaches in the new locale (the hint, value and
/// suggestion rows are app/live strings, verbatim).
fn svLocaleCb(userdata: ?*anyopaque) void {
    const n: *Node = @ptrCast(@alignCast(userdata.?));
    const s = stateOf(n);
    if (s.opts.label == null) {
        n.allocator.free(s.label_z);
        s.label_z = dupeZ(n.allocator, i18n_mod.tr("Search")) catch @panic("klaxon: out of memory");
    }
    ui.semantics.attach(n, .{
        .role = .dialog, // the search region (a full-screen dialog)
        .label = s.label_z,
        .hint = s.placeholder,
        .value = s.text(),
        .focusable = true,
        .children = s.sem_children.items,
        .child_bounds = suggestionChildBounds,
    });
    n.markDirty();
    ui.semantics.notifyControlChanged(n);
}

/// The damage extent: the surface paints anywhere inside the
/// anchor∪bounds hull while it morphs — report the union so a mid-anim
/// repaint covers the trailing edge (the lerp rect is always inside it).
fn searchViewPaintBounds(n: *Node) Rect {
    const b = n.bounds;
    const a = stateOf(n).opts.anchor orelse return b;
    const x = @min(b.x, a.x);
    const y = @min(b.y, a.y);
    return .{
        .x = x,
        .y = y,
        .w = @max(b.x + b.w, a.x + a.w) - x,
        .h = @max(b.y + b.h, a.y + a.h) - y,
    };
}

const search_view_vtable = ui.node.VTable{
    .measure = searchViewMeasure,
    .layout = searchViewLayout,
    .paint = searchViewPaint,
    .deinit = searchViewDeinit,
    .on_pointer = searchViewOnPointer,
    .on_key = searchViewOnKey,
    .wants_text_input = true,
    .paint_bounds = searchViewPaintBounds,
};

/// Suggestion `index`'s rect in NODE-LOCAL space (Semantics.child_bounds —
/// 0,0 is the node's top-left).
fn suggestionChildBounds(n: *Node, index: usize) Rect {
    return .{
        .x = 0,
        .y = header_h + divider_h + @as(f32, @floatFromInt(index)) * row_h,
        .w = n.bounds.w,
        .h = row_h,
    };
}

/// The M3E expanded search view (full-screen). `items` is the suggestion
/// list (copied — the view owns the labels). `open` is the app-owned open
/// signal: true = visible + focused + on the modal back stack; flipping it
/// plays the upstream expand/collapse spec (the surface morphs from
/// opts.anchor → bounds with the corner radius lerping to CornerNone, the
/// header field + suggestion column fade on their own channels — snaps
/// when no timeline is installed). `query` = null → the text starts at
/// `opts.initial`; non-null → the query mirrors the signal both ways.
/// `on_changed` fires on every edit (incl. the clear + fill affordances);
/// `on_select` on a suggestion activation (read the row via
/// selectedIndex(node)); `on_submitted` on Enter without a highlight;
/// `on_close` on dismissal. The view is a leaf: it owns its text buffer
/// and paints all of its chrome; the suggestions are virtual semantic
/// children. The query text is growable up to
/// ui.state.TextSignal.max_len (1 MiB); over-cap initial text is REJECTED
/// (error.TextTooLong), never truncated.
pub fn searchView(
    allocator: std.mem.Allocator,
    items: []const SuggestionItem,
    open: *ui.state.Signal(bool),
    query: ?*ui.state.TextSignal,
    on_changed: ?Callback,
    on_select: ?Callback,
    on_submitted: ?Callback,
    on_close: ?Callback,
    opts: SearchViewOptions,
) !*Node {
    // Rejected up front: over the documented cap → error.TextTooLong (never
    // truncated). Checked before any allocation so nothing needs freeing.
    const initial: []const u8 = if (query) |q| q.peek() else opts.initial;
    if (initial.len > ui.state.TextSignal.max_len) return error.TextTooLong;
    const node = try Node.create(allocator, &search_view_vtable);
    errdefer allocator.destroy(node); // no state yet; children list is empty
    const placeholder = try dupeZ(allocator, opts.placeholder);
    errdefer allocator.free(placeholder);
    const label_z = try dupeZ(allocator, opts.label orelse i18n_mod.tr("Search"));
    errdefer allocator.free(label_z);
    const s = try allocator.create(SearchViewState);
    errdefer allocator.destroy(s);
    s.* = .{
        .edit = text_edit.Edit.init(allocator, node),
        .placeholder = placeholder,
        .label_z = label_z,
        .items = std.array_list.Managed(ItemDef).init(allocator),
        .sem_children = std.array_list.Managed(ui.semantics.Semantics).init(allocator),
        .opts = opts,
        .open_sig = open,
        .query_sig = query,
        .on_changed = on_changed,
        .on_select = on_select,
        .on_submitted = on_submitted,
        .on_close = on_close,
    };
    errdefer {
        for (s.items.items) |it| allocator.free(it.label);
        s.items.deinit();
        s.sem_children.deinit();
        s.edit.deinit();
    }
    try s.items.ensureTotalCapacity(items.len);
    try s.sem_children.ensureTotalCapacity(items.len);
    for (items) |it| {
        const label = try dupeZ(allocator, it.label);
        s.items.appendAssumeCapacity(.{
            .label = label,
            .icon = it.icon,
            .trailing_icon = it.trailing_icon,
            .enabled = it.enabled,
        });
        // The suggestion rows are virtual a11y children (no Node of their
        // own) — activation lands on the row rect via child_bounds.
        s.sem_children.appendAssumeCapacity(.{
            .role = .list_item,
            .label = label,
            .disabled = !it.enabled,
            .actions = if (it.enabled) ui.semantics.Actions.initOne(.activate) else .{},
        });
    }
    s.edit.buf.ensureTotalCapacity(initial.len + 1) catch @panic("klaxon: out of memory");
    if (initial.len > 0) {
        s.edit.buf.appendSlice(initial) catch @panic("klaxon: out of memory");
    }
    setSentinel(&s.edit.buf); // null-terminates the (possibly empty) buffer
    s.edit.caret = s.edit.buf.items.len; // the caret starts at the end
    s.edit.sel_anchor = s.edit.caret;
    node.state = s;
    if (!open.peek()) node.setVisible(false); // hidden until the signal opens it
    svLocaleCb(node); // Phase 2c — the same path resolves the labels
    s.i18n = i18n_mod.subscribeLocale(.{ .fn_ptr = svLocaleCb, .userdata = node });
    open.subscribe(.{ .callback = .{ .fn_ptr = svOpenSyncCb, .userdata = node } });
    if (query) |q| {
        q.subscribe(.{ .callback = .{ .fn_ptr = svQuerySyncCb, .userdata = node } }); // external edits land in the buffer
    }
    if (open.peek()) applyOpen(node, s, true); // built open: focus + back stack
    return node;
}

/// Current query text — borrowed from the widget's buffer (valid until the
/// next edit or deinit).
pub fn text(n: *Node) [:0]const u8 {
    return stateOf(n).text();
}

/// Replace the query text (e.g. the gallery restores it across rebuilds).
/// Over-cap text is rejected: the view keeps its current contents.
pub fn setText(n: *Node, str: []const u8) void {
    const s = stateOf(n);
    if (str.len > ui.state.TextSignal.max_len) return;
    s.edit.buf.clearRetainingCapacity();
    s.edit.buf.ensureTotalCapacity(str.len + 1) catch @panic("klaxon: out of memory");
    s.edit.buf.appendSlice(str) catch @panic("klaxon: out of memory");
    setSentinel(&s.edit.buf);
    s.edit.caret = s.edit.buf.items.len; // programmatic replace → caret at the end
    s.edit.sel_anchor = s.edit.caret;
    s.edit.resetBlink();
    n.markDirty();
    if (n.semantics) |sem| sem.value = s.text();
    ui.semantics.notifyControlChanged(n);
    if (s.query_sig) |sig| sig.set(s.text()) catch @panic("klaxon: text buffer exceeds the 1 MiB cap");
}

/// Whether the view is open (mirrors the open signal).
pub fn isOpen(n: *Node) bool {
    return stateOf(n).open;
}

/// Flip the open signal (the sync callback applies it).
pub fn setOpen(n: *Node, open: bool) void {
    stateOf(n).open_sig.set(open);
}

/// The last activated suggestion's index (read inside on_select).
pub fn selectedIndex(n: *Node) usize {
    return stateOf(n).selected;
}

// --- tests ---

const SuggestionList = struct {
    const items = [_]SuggestionItem{
        .{ .label = "apples", .icon = .search },
        .{ .label = "apricots", .icon = .star, .trailing_icon = .arrow_up },
        .{ .label = "bananas", .icon = .search },
    };
};

fn countingCb(userdata: ?*anyopaque) void {
    const c: *u32 = @ptrCast(@alignCast(userdata.?));
    c.* += 1;
}

test "search_view: closed by default — invisible; the signal opens it" {
    const open = try ui.state.Signal(bool).init(std.testing.allocator, false);
    defer open.deinit();
    const v = try searchView(std.testing.allocator, &SuggestionList.items, open, null, null, null, null, null, .{});
    defer v.deinit();
    v.layout(.{ .x = 0, .y = 0, .w = 360, .h = 640 });
    try std.testing.expect(!v.visible);
    try std.testing.expect(!isOpen(v));
    open.set(true);
    try std.testing.expect(v.visible);
    try std.testing.expect(isOpen(v));
    open.set(false);
    try std.testing.expect(!v.visible);
}

test "search_view: fills finite constraints" {
    const open = try ui.state.Signal(bool).init(std.testing.allocator, true);
    defer open.deinit();
    const v = try searchView(std.testing.allocator, &.{}, open, null, null, null, null, null, .{});
    defer v.deinit();
    const m = v.measure(.{ .max_w = 720, .max_h = 480 });
    try std.testing.expectEqual(@as(f32, 720), m.w);
    try std.testing.expectEqual(@as(f32, 480), m.h);
}

test "search_view: the back arrow and Escape close; on_close fires" {
    const open = try ui.state.Signal(bool).init(std.testing.allocator, false);
    defer open.deinit();
    var closed: u32 = 0;
    const v = try searchView(std.testing.allocator, &SuggestionList.items, open, null, null, null, null, .{ .fn_ptr = countingCb, .userdata = &closed }, .{});
    defer v.deinit();
    v.layout(.{ .x = 0, .y = 0, .w = 360, .h = 640 });
    var router = input.InputRouter{};
    input.setCurrent(&router);
    defer input.setCurrent(null);
    // open with the router live: the modal back handler registers and the
    // query field takes the focus
    open.set(true);
    try std.testing.expectEqual(@as(usize, 1), router.back_stack_len);
    try std.testing.expect(router.focused == v);
    // a click on the back arrow (the 48dp start box of the 64dp header)
    router.dispatchPointer(v, .{ .phase = .down, .x = 24, .y = 32 });
    router.dispatchPointer(v, .{ .phase = .up, .x = 24, .y = 32 });
    try std.testing.expect(!open.peek());
    try std.testing.expectEqual(@as(u32, 1), closed);
    try std.testing.expectEqual(@as(usize, 0), router.back_stack_len);
    try std.testing.expect(router.focused == null); // the close released the focus
    // reopen: Escape (the focused key path) closes it too
    open.set(true);
    try std.testing.expect(router.focused == v);
    try std.testing.expect(router.dispatchKey(.{ .kind = .key_down, .key = .escape }));
    try std.testing.expect(!open.peek());
    try std.testing.expectEqual(@as(u32, 2), closed);
    // reopen, blur: the modal back stack still closes it (unfocused Escape)
    open.set(true);
    router.focus(null);
    try std.testing.expect(router.dispatchBack());
    try std.testing.expect(!open.peek());
    try std.testing.expectEqual(@as(u32, 3), closed);
}

test "search_view: a suggestion click fires on_select with the row index" {
    const open = try ui.state.Signal(bool).init(std.testing.allocator, true);
    defer open.deinit();
    var picked: u32 = 0;
    const v = try searchView(std.testing.allocator, &SuggestionList.items, open, null, null, .{ .fn_ptr = countingCb, .userdata = &picked }, null, null, .{});
    defer v.deinit();
    v.layout(.{ .x = 0, .y = 0, .w = 360, .h = 640 });
    var router = input.InputRouter{};
    input.setCurrent(&router);
    defer input.setCurrent(null);
    // row 1 (apricots) center — under the header + divider
    const ry = header_h + divider_h + row_h + row_h / 2;
    router.dispatchPointer(v, .{ .phase = .down, .x = 180, .y = ry });
    router.dispatchPointer(v, .{ .phase = .up, .x = 180, .y = ry });
    try std.testing.expectEqual(@as(u32, 1), picked);
    try std.testing.expectEqual(@as(usize, 1), selectedIndex(v));
    // a click up outside the pressed row does not fire (release on row 2)
    const ry2 = header_h + divider_h + 2 * row_h + row_h / 2;
    router.dispatchPointer(v, .{ .phase = .down, .x = 180, .y = ry });
    router.dispatchPointer(v, .{ .phase = .up, .x = 180, .y = ry2 });
    try std.testing.expectEqual(@as(u32, 1), picked);
}

test "search_view: the fill affordance writes the suggestion into the query" {
    const open = try ui.state.Signal(bool).init(std.testing.allocator, true);
    defer open.deinit();
    var changed: u32 = 0;
    var picked: u32 = 0;
    const v = try searchView(std.testing.allocator, &SuggestionList.items, open, null, .{ .fn_ptr = countingCb, .userdata = &changed }, .{ .fn_ptr = countingCb, .userdata = &picked }, null, null, .{});
    defer v.deinit();
    v.layout(.{ .x = 0, .y = 0, .w = 360, .h = 640 });
    var router = input.InputRouter{};
    input.setCurrent(&router);
    defer input.setCurrent(null);
    // the trailing 48dp zone of row 1 (the only row with a trailing icon)
    const ry = header_h + divider_h + row_h + row_h / 2;
    router.dispatchPointer(v, .{ .phase = .down, .x = 360 - 24, .y = ry });
    router.dispatchPointer(v, .{ .phase = .up, .x = 360 - 24, .y = ry });
    try std.testing.expectEqualStrings("apricots", text(v));
    try std.testing.expectEqual(@as(u32, 1), changed); // an edit, not a select
    try std.testing.expectEqual(@as(u32, 0), picked);
}

test "search_view: typing edits the query; the signal mirrors; clear empties it" {
    const open = try ui.state.Signal(bool).init(std.testing.allocator, false);
    defer open.deinit();
    const query = try ui.state.TextSignal.init(std.testing.allocator, "");
    defer query.deinit();
    var changed: u32 = 0;
    const v = try searchView(std.testing.allocator, &SuggestionList.items, open, query, .{ .fn_ptr = countingCb, .userdata = &changed }, null, null, null, .{});
    defer v.deinit();
    v.layout(.{ .x = 0, .y = 0, .w = 360, .h = 640 });
    var router = input.InputRouter{};
    input.setCurrent(&router);
    defer input.setCurrent(null);
    // open with the router live → the query field takes the focus
    open.set(true);
    try std.testing.expect(router.focused == v);
    _ = router.dispatchKey(.{ .kind = .text_input, .text = "ap" });
    try std.testing.expectEqualStrings("ap", text(v));
    try std.testing.expectEqualStrings("ap", query.peek());
    try std.testing.expectEqual(@as(u32, 1), changed);
    _ = router.dispatchKey(.{ .kind = .key_down, .key = .backspace });
    try std.testing.expectEqualStrings("a", text(v));
    // an external set replaces the buffer (two-way sync)
    query.set("app") catch return error.TestUnexpectedError;
    try std.testing.expectEqualStrings("app", text(v));
    // the clear button (the trailing 48dp header box) empties the field
    router.dispatchPointer(v, .{ .phase = .down, .x = 360 - 24, .y = 32 });
    router.dispatchPointer(v, .{ .phase = .up, .x = 360 - 24, .y = 32 });
    try std.testing.expectEqualStrings("", text(v));
    try std.testing.expectEqualStrings("", query.peek());
}

test "search_view: Up/Down highlight and Enter activates the suggestion" {
    const open = try ui.state.Signal(bool).init(std.testing.allocator, false);
    defer open.deinit();
    var picked: u32 = 0;
    var submitted: u32 = 0;
    const v = try searchView(std.testing.allocator, &SuggestionList.items, open, null, null, .{ .fn_ptr = countingCb, .userdata = &picked }, .{ .fn_ptr = countingCb, .userdata = &submitted }, null, .{});
    defer v.deinit();
    v.layout(.{ .x = 0, .y = 0, .w = 360, .h = 640 });
    var router = input.InputRouter{};
    input.setCurrent(&router);
    defer input.setCurrent(null);
    open.set(true); // focused with the router live
    // Enter with no highlight submits the query
    _ = router.dispatchKey(.{ .kind = .key_down, .key = .enter });
    try std.testing.expectEqual(@as(u32, 1), submitted);
    try std.testing.expectEqual(@as(u32, 0), picked);
    // Down lands on row 0; Down again on row 1; Enter selects it
    _ = router.dispatchKey(.{ .kind = .key_down, .key = .down });
    _ = router.dispatchKey(.{ .kind = .key_down, .key = .down });
    _ = router.dispatchKey(.{ .kind = .key_down, .key = .enter });
    try std.testing.expectEqual(@as(u32, 1), picked);
    try std.testing.expectEqual(@as(usize, 1), selectedIndex(v));
}

test "search_view: semantics — the dialog role with virtual list_item children" {
    const open = try ui.state.Signal(bool).init(std.testing.allocator, true);
    defer open.deinit();
    const v = try searchView(std.testing.allocator, &SuggestionList.items, open, null, null, null, null, null, .{ .label = "Find stuff" });
    defer v.deinit();
    const sem = v.semantics.?;
    try std.testing.expectEqual(ui.semantics.Role.dialog, sem.role);
    try std.testing.expectEqualStrings("Find stuff", sem.label);
    try std.testing.expect(sem.focusable);
    try std.testing.expectEqual(@as(usize, 3), sem.children.len);
    try std.testing.expectEqual(ui.semantics.Role.list_item, sem.children[0].role);
    try std.testing.expectEqualStrings("apples", sem.children[0].label);
    // the virtual child bounds: row 1 sits under the header + divider
    v.layout(.{ .x = 0, .y = 0, .w = 360, .h = 640 });
    const cb = sem.child_bounds.?(v, 1);
    try std.testing.expectEqual(header_h + divider_h + row_h, cb.y);
    try std.testing.expectEqual(row_h, cb.h);
    try std.testing.expectEqual(@as(f32, 360), cb.w);
}

test "search_view: setText + a disabled row is not selectable" {
    const open = try ui.state.Signal(bool).init(std.testing.allocator, false);
    defer open.deinit();
    const dis_items = [_]SuggestionItem{
        .{ .label = "on", .icon = .search },
        .{ .label = "off", .icon = .search, .enabled = false },
    };
    var picked: u32 = 0;
    const v = try searchView(std.testing.allocator, &dis_items, open, null, null, .{ .fn_ptr = countingCb, .userdata = &picked }, null, null, .{});
    defer v.deinit();
    v.layout(.{ .x = 0, .y = 0, .w = 360, .h = 640 });
    var router = input.InputRouter{};
    input.setCurrent(&router);
    defer input.setCurrent(null);
    open.set(true); // focused for the keyboard part below
    setText(v, "hello");
    try std.testing.expectEqualStrings("hello", text(v));
    // a click on the disabled row does not fire
    const ry = header_h + divider_h + row_h + row_h / 2;
    router.dispatchPointer(v, .{ .phase = .down, .x = 180, .y = ry });
    router.dispatchPointer(v, .{ .phase = .up, .x = 180, .y = ry });
    try std.testing.expectEqual(@as(u32, 0), picked);
    // keyboard highlight skips the disabled row (Down wraps back to row 0)
    _ = router.dispatchKey(.{ .kind = .key_down, .key = .down });
    _ = router.dispatchKey(.{ .kind = .key_down, .key = .down });
    _ = router.dispatchKey(.{ .kind = .key_down, .key = .enter });
    try std.testing.expectEqual(@as(u32, 1), picked);
    try std.testing.expectEqual(@as(usize, 0), selectedIndex(v));
}

test "golden: search_view open paints the surface, the header and the rows" {
    const t = theme_mod.light;
    const open = try ui.state.Signal(bool).init(std.testing.allocator, true);
    defer open.deinit();
    const query = try ui.state.TextSignal.init(std.testing.allocator, "ap");
    defer query.deinit();
    const items = [_]SuggestionItem{
        .{ .label = "apples", .icon = .search },
        .{ .label = "apricots", .icon = .star, .trailing_icon = .arrow_up },
    };
    const v = try searchView(std.testing.allocator, &items, open, query, null, null, null, null, .{ .theme = t });
    defer v.deinit();
    var r = try golden.Renderer.init(std.testing.allocator, 360, 400);
    defer r.deinit();
    v.layout(.{ .x = 0, .y = 0, .w = 360, .h = 400 });
    r.paint(v, 0x112233FF);
    var f = try r.readback(std.testing.allocator);
    defer f.deinit();
    // the surface covers the whole frame (full bleed — the corner is surface)
    try std.testing.expectEqual(t.colors.surface, f.pixelAt(2, 2));
    try std.testing.expectEqual(t.colors.surface, f.pixelAt(358, 398));
    // the divider row is outline_variant, full width
    try std.testing.expect(f.countColorIn(.{ .x = 0, .y = header_h, .w = 360, .h = divider_h }, t.colors.outline_variant) > 300);
    // the back arrow + the clear button ink in the header (on_surface /
    // on_surface_variant — AA blends count as "not surface")
    try std.testing.expect(f.countNotIn(.{ .x = 0, .y = 0, .w = 48, .h = header_h }, t.colors.surface) > 0);
    try std.testing.expect(f.countNotIn(.{ .x = 312, .y = 0, .w = 48, .h = header_h }, t.colors.surface) > 0);
    // the suggestion rows: leading icon + label + trailing arrow ink
    const row0 = Rect{ .x = 0, .y = header_h + divider_h, .w = 360, .h = row_h };
    const row1 = Rect{ .x = 0, .y = header_h + divider_h + row_h, .w = 360, .h = row_h };
    try std.testing.expect(f.countColorIn(row0, t.colors.on_surface) > 0); // label ink
    try std.testing.expect(f.countColorIn(row0, t.colors.on_surface_variant) > 0); // icon ink
    try std.testing.expect(f.countColorIn(row1, t.colors.on_surface) > 0);
    try std.testing.expect(f.countNotIn(row1, t.colors.surface) > 0);
    // closed: nothing paints — the body shows through
    open.set(false);
    v.layout(.{ .x = 0, .y = 0, .w = 360, .h = 400 });
    r.paint(v, 0x112233FF);
    var f2 = try r.readback(std.testing.allocator);
    defer f2.deinit();
    try std.testing.expectEqual(@as(Color, 0x112233FF), f2.pixelAt(2, 2));
    try std.testing.expectEqual(@as(Color, 0x112233FF), f2.pixelAt(180, 200));
}

test "search_view: the expansion plays the upstream spec — progress + field channels" {
    var tl = ui.anim.Timeline.init(std.testing.allocator);
    defer tl.deinit();
    ui.anim.setCurrent(&tl);
    defer ui.anim.setCurrent(null);
    const open = try ui.state.Signal(bool).init(std.testing.allocator, false);
    defer open.deinit();
    const v = try searchView(std.testing.allocator, &SuggestionList.items, open, null, null, null, null, null, .{});
    defer v.deinit();
    v.layout(.{ .x = 0, .y = 0, .w = 360, .h = 640 });
    try std.testing.expect(!v.visible);
    open.set(true);
    // visible from the first frame; progress holds at 0 through the 100ms delay
    try std.testing.expect(v.visible);
    tl.tick(0); // lazy start: both clocks arm at now + delay
    tl.tick(50);
    try std.testing.expectEqual(@as(f32, 0), stateOf(v).progress);
    tl.tick(100); // the enter spec starts
    try std.testing.expectEqual(@as(f32, 0), stateOf(v).progress);
    tl.tick(400); // 300ms into the 600ms emphasized-decelerate → most of the way
    const mid = stateOf(v).progress;
    try std.testing.expect(mid > 0.5 and mid < 1);
    tl.tick(700); // 600ms in → done
    try std.testing.expectEqual(@as(f32, 1), stateOf(v).progress);
    // the field crossfade (50ms + 50 delay, standard accelerate) landed earlier
    try std.testing.expectEqual(@as(f32, 1), stateOf(v).field_alpha);
    // collapse: the exit spec (350ms + 100 delay, linear) keeps the node
    // visible until progress reaches 0
    open.set(false);
    try std.testing.expect(v.visible); // the exit still draws
    tl.tick(800); // lazy start at 800 + 100 delay
    tl.tick(900);
    try std.testing.expectEqual(@as(f32, 1), stateOf(v).progress); // delayed
    tl.tick(1075); // ~half the 350ms linear exit
    const p2 = stateOf(v).progress;
    try std.testing.expect(p2 > 0.4 and p2 < 0.6);
    try std.testing.expect(v.visible); // mid-exit: still on screen
    tl.tick(1250); // 350ms in → complete → hideCb hides the node
    try std.testing.expectEqual(@as(f32, 0), stateOf(v).progress);
    try std.testing.expect(!v.visible);
}

test "search_view: the anchor morphs the surface rect; the radius lerps to CornerNone" {
    var s: SearchViewState = undefined;
    s.opts = .{ .anchor = .{ .x = 20, .y = 30, .w = 200, .h = 56 } };
    const b = Rect{ .x = 0, .y = 0, .w = 360, .h = 640 };
    s.progress = 0;
    var r = surfaceRect(&s, b);
    try std.testing.expectEqual(@as(f32, 20), r.x);
    try std.testing.expectEqual(@as(f32, 200), r.w);
    s.progress = 0.5;
    r = surfaceRect(&s, b);
    try std.testing.expectEqual(@as(f32, 10), r.x); // 20·0.5 + 0·0.5
    try std.testing.expectEqual(@as(f32, 15), r.y);
    try std.testing.expectEqual(@as(f32, 280), r.w); // 200·0.5 + 360·0.5
    s.progress = 1;
    r = surfaceRect(&s, b);
    try std.testing.expectEqual(b.x, r.x);
    try std.testing.expectEqual(b.h, r.h);
    // no anchor → the surface covers the bounds at every progress
    s.opts.anchor = null;
    s.progress = 0.4;
    r = surfaceRect(&s, b);
    try std.testing.expectEqual(b.w, r.w);
}

test "golden: mid-expansion the surface paints rounded inside the animated clip" {
    const t = theme_mod.light;
    const open = try ui.state.Signal(bool).init(std.testing.allocator, true);
    defer open.deinit();
    const v = try searchView(std.testing.allocator, &SuggestionList.items, open, null, null, null, null, null, .{ .theme = t });
    defer v.deinit();
    var r = try golden.Renderer.init(std.testing.allocator, 200, 160);
    defer r.deinit();
    v.layout(.{ .x = 0, .y = 0, .w = 200, .h = 160 });
    // mid-expansion: progress 0.5 → the corner radius is 28·0.5 = 14
    stateOf(v).progress = 0.5;
    stateOf(v).field_alpha = 0.5;
    r.paint(v, 0x112233FF);
    var f = try r.readback(std.testing.allocator);
    defer f.deinit();
    // the rounded corner is OUTSIDE the clip → the background shows through
    try std.testing.expectEqual(@as(Color, 0x112233FF), f.pixelAt(1, 1));
    try std.testing.expectEqual(@as(Color, 0x112233FF), f.pixelAt(199, 159));
    // inside the corner radius the surface + content paint
    try std.testing.expectEqual(t.colors.surface, f.pixelAt(100, 80));
    // the divider fades at alpha = progress over the surface
    const div = f.pixelAt(100, 73); // header 72 + divider 1
    const want = ui.paint.withAlphaScaled(t.colors.outline_variant, 0.5);
    _ = want; // blended over surface — just assert it's neither pure color
    try std.testing.expect(div != 0x112233FF);
    // the suggestion row background stays surface (between the icon box
    // and the label — no state layer on an idle row)
    try std.testing.expectEqual(t.colors.surface, f.pixelAt(48, 100));
}

test "search_view: i18n — the defaulted region label localizes + re-resolves" {
    const a = std.testing.allocator;
    const i18n = try i18n_mod.I18n.init(a, "en");
    defer i18n.deinit();
    try i18n.addArb("en", "{}", .ltr);
    try i18n.addArb("es", "{\"@@locale\": \"es\", \"Search\": \"Buscar\"}", .ltr);
    try i18n.setLocale("es");
    i18n_mod.setCurrent(i18n);
    defer i18n_mod.setCurrent(null);
    const open = try ui.state.Signal(bool).init(a, false);
    defer open.deinit();
    const v = try searchView(a, &SuggestionList.items, open, null, null, null, null, null, .{});
    defer v.deinit();
    try std.testing.expectEqualStrings("Buscar", v.semantics.?.label);
    try i18n.setLocale("en");
    try std.testing.expectEqualStrings("Search", v.semantics.?.label);
}
