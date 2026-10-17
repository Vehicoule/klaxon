// klaxon-fidelity-compose — the Compose side of the pixel-fidelity harness.
//
// Reads the SAME fidelity/scenes.json the Klaxon runner consumes, builds the
// scene as real Material 3 composables (Button/IconButton/Checkbox/… — not
// the conformance DSL's generic nodes), seeds the interaction state through
// MutableInteractionSource.tryEmit (Press/Hover/Focus; disabled via
// enabled=false), renders headlessly through
// androidx.compose.ui.ImageComposeScene on the CPU raster Skiko surface at
// the scene's synthetic t_ms, and writes fidelity/out/compose/<id>.ppm (P6).
//
// Determinism contract (fidelity/README.md): same scenes file, density 1.0,
// viewport = scene viewport, LayoutDirection from dir, M3 baseline
// lightColorScheme()/darkColorScheme() matching Klaxon's theme.light/dark,
// the widget centered in a surface-colored frame, DejaVu Sans pinned for
// every text style via pinnedTypography() (the vendored TTF lands on the
// classpath through sourceSets -> deps/fonts and loads via ResourceFont).
//
// Flags (same names as the Klaxon runner):
//   --scenes=<path>   scene matrix (default "../../scenes.json")
//   --out=<dir>       image output dir (default "../../out/compose")
//   --scene=<substr>  run only scenes whose id contains the substring
package conf.compose

import androidx.compose.foundation.interaction.FocusInteraction
import androidx.compose.foundation.interaction.HoverInteraction
import androidx.compose.foundation.interaction.Interaction
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.interaction.PressInteraction
import androidx.compose.foundation.layout.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.ExperimentalComposeUiApi
import androidx.compose.ui.ImageComposeScene
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.layout.boundsInWindow
import androidx.compose.ui.layout.onGloballyPositioned
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.platform.ResourceFont
import androidx.compose.ui.unit.Density
import androidx.compose.ui.unit.LayoutDirection
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import kotlinx.coroutines.Dispatchers
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.*
import org.jetbrains.skia.Bitmap
import org.jetbrains.skia.ColorAlphaType
import org.jetbrains.skia.ImageInfo
import java.io.File

// --- scenes.json model -------------------------------------------------------

@Serializable
data class SceneSpec(
    val id: String,
    val widget: String,
    val state: String = "default",
    val theme: String = "light",
    val dir: String = "ltr",
    val viewport: List<Int> = listOf(320, 120),
    val t_ms: Long = 0,
    val options: JsonObject = JsonObject(emptyMap()),
    val children: List<JsonObject> = emptyList(),
)

@Serializable
data class SceneDoc(val scenes: List<SceneSpec>)

private val JsonFormat = Json { ignoreUnknownKeys = true }

fun JsonObject.str(key: String, default: String = ""): String =
    (this[key] as? JsonPrimitive)?.contentOrNull ?: default

fun JsonObject.bool(key: String, default: Boolean = false): Boolean =
    (this[key] as? JsonPrimitive)?.booleanOrNull ?: default

fun JsonObject.num(key: String, default: Double): Double =
    (this[key] as? JsonPrimitive)?.doubleOrNull ?: default

fun JsonObject.items(): List<JsonObject> =
    (this["items"] as? JsonArray)?.filterIsInstance<JsonObject>() ?: emptyList()

// IconName → Unicode codepoint — mirrors src/widgets/icon.zig so both sides
// draw the same glyph in the same (DejaVu) face.
val ICON_CODEPOINTS = mapOf(
    "play" to 0x25B6, "pause" to 0x275A, "stop" to 0x25A0, "circle" to 0x25CF,
    "square" to 0x25A1, "triangle_right" to 0x25B6, "triangle_left" to 0x25C0,
    "triangle_up" to 0x25B2, "triangle_down" to 0x25BC, "arrow_right" to 0x2192,
    "arrow_left" to 0x2190, "arrow_up" to 0x2191, "arrow_down" to 0x2193,
    "chevron_right" to 0x203A, "chevron_left" to 0x2039, "check" to 0x2713,
    "close" to 0x2715, "menu" to 0x2261, "search" to 0x2315, "star" to 0x2605,
    "heart" to 0x2665, "plus" to 0x002B, "minus" to 0x2212, "home" to 0x2302,
    "music_note" to 0x266A, "history" to 0x21BB, "north_west" to 0x2196,
)

fun glyph(name: String): String =
    String(Character.toChars(ICON_CODEPOINTS[name] ?: 0x2605))

// --- interaction plumbing ---------------------------------------------------

/// The widget's interaction source(s) + press offsets (captured from the
/// first layout — press at the widget's local center on BOTH sides).
class SceneInput(spec: SceneSpec) {
    val source = MutableInteractionSource()
    var pressCenter = Offset.Zero
    var bounds = androidx.compose.ui.geometry.Rect.Zero

    // nav_bar/tabs carry per-item sources: "pressed at the widget center"
    // lands on the middle destination/tab, same as the Klaxon hit test.
    val itemSources = List(spec.options.items().size) { MutableInteractionSource() }
    val itemCenters = MutableList(spec.options.items().size) { Offset.Zero }
}

fun Modifier.captureInto(set: (Offset) -> Unit): Modifier =
    onGloballyPositioned { set(Offset(it.size.width / 2f, it.size.height / 2f)) }

fun Modifier.captureBoundsInto(set: (androidx.compose.ui.geometry.Rect) -> Unit): Modifier =
    onGloballyPositioned { set(it.boundsInWindow()) }

fun seedState(spec: SceneSpec, input: SceneInput) {
    val items = input.itemSources.size
    val mid = if (items > 0) items / 2 else -1
    when (spec.state) {
        "hover" -> {
            val src = if (mid >= 0) input.itemSources[mid] else input.source
            src.emitNow(HoverInteraction.Enter())
        }
        "pressed" -> {
            if (mid >= 0) {
                input.itemSources[mid].emitNow(PressInteraction.Press(input.itemCenters[mid]))
            } else {
                input.source.emitNow(PressInteraction.Press(input.pressCenter))
            }
        }
        "focused" -> input.source.emitNow(FocusInteraction.Focus())
    }
}

fun MutableInteractionSource.emitNow(interaction: Interaction) {
    if (!tryEmit(interaction)) {
        kotlinx.coroutines.runBlocking { emit(interaction) }
    }
}

// --- widget content ----------------------------------------------------------

@Composable
fun SceneContent(spec: SceneSpec, input: SceneInput, dejavu: FontFamily) {
    Surface(modifier = Modifier.fillMaxSize(), color = MaterialTheme.colorScheme.surface) {
        Box(modifier = Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
            WidgetContent(spec, input, dejavu)
        }
    }
}

@Composable
fun WidgetContent(spec: SceneSpec, input: SceneInput, dejavu: FontFamily) {
    val o = spec.options
    val enabled = o.bool("enabled", true) && spec.state != "disabled"
    val centerMod = Modifier
        .captureInto { input.pressCenter = it }
        .captureBoundsInto { input.bounds = it }
    when (spec.widget) {
        "button" -> {
            val label = o.str("label").ifEmpty { null }
            val size = o.str("size", "small")
            val h = when (size) {
                "xsmall" -> 32; "medium" -> 56; "large" -> 96; "xlarge" -> 136; else -> 40
            }
            val iconSp = when (size) {
                "xsmall" -> 20; "medium" -> 24; "large" -> 32; "xlarge" -> 40; else -> 20
            }
            val gap = when (size) {
                "xsmall" -> 4; "large" -> 12; "xlarge" -> 16; else -> 8
            }
            val textStyle = when (size) {
                "medium" -> MaterialTheme.typography.titleMedium
                "large" -> MaterialTheme.typography.headlineSmall
                "xlarge" -> MaterialTheme.typography.headlineMedium
                else -> MaterialTheme.typography.labelLarge
            }
            val icon = o.str("icon").ifEmpty { null }
            val mod = Modifier.height(h.dp).then(centerMod)
            val content: @Composable RowScope.() -> Unit = {
                if (icon != null) {
                    Text(glyph(icon), fontFamily = dejavu, fontSize = iconSp.sp)
                    if (label != null) Spacer(Modifier.width(gap.dp))
                }
                if (label != null) Text(label, style = textStyle)
            }
            when (o.str("variant", "filled")) {
                "filled_tonal" -> FilledTonalButton({}, mod, enabled, interactionSource = input.source, content = content)
                "elevated" -> ElevatedButton({}, mod, enabled, interactionSource = input.source, content = content)
                "outlined" -> OutlinedButton({}, mod, enabled, interactionSource = input.source, content = content)
                "text" -> TextButton({}, mod, enabled, interactionSource = input.source, content = content)
                else -> Button({}, mod, enabled, interactionSource = input.source, content = content)
            }
        }

        "icon_button" -> {
            val icon = glyph(o.str("icon", "star"))
            val mod = centerMod
            val content: @Composable () -> Unit = { Text(icon, fontFamily = dejavu, fontSize = 24.sp) }
            when (o.str("variant", "standard")) {
                "filled" -> FilledIconButton({}, mod, enabled, interactionSource = input.source, content = content)
                "filled_tonal" -> FilledTonalIconButton({}, mod, enabled, interactionSource = input.source, content = content)
                "outlined" -> OutlinedIconButton({}, mod, enabled, interactionSource = input.source, content = content)
                else -> IconButton({}, mod, enabled, interactionSource = input.source, content = content)
            }
        }

        "checkbox" -> Checkbox(
            checked = o.bool("checked"), onCheckedChange = null, modifier = centerMod,
            enabled = enabled, interactionSource = input.source,
        )

        "radio" -> RadioButton(
            selected = o.num("index", 0.0).toInt() == o.num("selected", 0.0).toInt(),
            onClick = {}, modifier = centerMod, enabled = enabled, interactionSource = input.source,
        )

        "switch" -> {
            val showIcons = o.bool("show_icons")
            Switch(
                checked = o.bool("checked"), onCheckedChange = {}, modifier = centerMod,
                enabled = enabled, interactionSource = input.source,
                thumbContent = if (showIcons) {
                    { Text(glyph("check"), fontFamily = dejavu, fontSize = 16.sp) }
                } else null,
            )
        }

        "slider" -> Slider(
            value = o.num("value", 0.5).toFloat(), onValueChange = {},
            modifier = Modifier.width(o.num("default_width", 160.0).dp).then(centerMod),
            enabled = enabled, interactionSource = input.source,
        )

        "card" -> {
            val content: @Composable ColumnScope.() -> Unit = {
                for (child in spec.children) {
                    if (child.str("name") == "text") {
                        val copts = (child["options"] as? JsonObject) ?: JsonObject(emptyMap())
                        Text(
                            copts.str("text"),
                            fontSize = copts.num("size", 14.0).sp,
                            color = colorFromInt(copts.num("color", 0.0).toLong()),
                        )
                    }
                }
            }
            val mod = Modifier.then(centerMod)
            when (o.str("variant", "filled")) {
                "elevated" -> ElevatedCard(modifier = mod, content = { Column(Modifier.padding(16.dp), content = content) })
                "outlined" -> OutlinedCard(modifier = mod, content = { Column(Modifier.padding(16.dp), content = content) })
                else -> Card(modifier = mod, content = { Column(Modifier.padding(16.dp), content = content) })
            }
        }

        "divider" -> {
            val color = if (o.num("color", -1.0) >= 0) colorFromInt(o.num("color", 0.0).toLong())
                        else DividerDefaults.color
            if (o.bool("horizontal", true)) {
                HorizontalDivider(centerMod, thickness = o.num("thickness", 1.0).dp, color = color)
            } else {
                VerticalDivider(centerMod, thickness = o.num("thickness", 1.0).dp, color = color)
            }
        }

        "badge" -> {
            val label = o.str("label").ifEmpty { null }
            if (label == null) Badge(centerMod) else Badge(centerMod) { Text(label) }
        }

        "nav_bar" -> {
            val items = o.items()
            val sel = o.num("selected", 0.0).toInt()
            NavigationBar(modifier = Modifier.fillMaxWidth().then(centerMod)) {
                items.forEachIndexed { i, item ->
                    val itemMod = Modifier.captureInto { input.itemCenters[i] = it }
                    NavigationBarItem(
                        selected = i == sel, onClick = {}, modifier = itemMod,
                        icon = { Text(glyph(item.str("icon", "star")), fontFamily = dejavu, fontSize = 24.sp) },
                        label = { Text(item.str("label")) },
                        interactionSource = input.itemSources[i],
                    )
                }
            }
        }

        "tabs" -> {
            val items = o.items()
            val sel = o.num("selected", 0.0).toInt()
            PrimaryTabRow(selectedTabIndex = sel, modifier = Modifier.fillMaxWidth().then(centerMod)) {
                items.forEachIndexed { i, item ->
                    val itemMod = Modifier.captureInto { input.itemCenters[i] = it }
                    Tab(
                        selected = i == sel, onClick = {}, modifier = itemMod,
                        icon = { Text(glyph(item.str("icon", "star")), fontFamily = dejavu, fontSize = 24.sp) },
                        text = { Text(item.str("label"), fontSize = 14.sp) },
                        interactionSource = input.itemSources[i],
                        selectedContentColor = MaterialTheme.colorScheme.primary,
                        unselectedContentColor = MaterialTheme.colorScheme.onSurfaceVariant,
                    )
                }
            }
        }

        "fab" -> {
            val icon = glyph(o.str("icon", "plus"))
            val content: @Composable () -> Unit = { Text(icon, fontFamily = dejavu, fontSize = 24.sp) }
            when (o.str("size", "standard")) {
                "small" -> SmallFloatingActionButton({}, centerMod, interactionSource = input.source, content = content)
                "large" -> LargeFloatingActionButton({}, centerMod, interactionSource = input.source, content = content)
                else -> FloatingActionButton({}, centerMod, interactionSource = input.source, content = content)
            }
        }

        "chip" -> {
            val label: @Composable () -> Unit = { Text(o.str("label")) }
            val leading: (@Composable () -> Unit)? =
                o.str("leading_icon").ifEmpty { null }?.let { ic ->
                    { Text(glyph(ic), fontFamily = dejavu, fontSize = 18.sp) }
                }
            val trailing: (@Composable () -> Unit)? =
                o.str("trailing_icon").ifEmpty { null }?.let { ic ->
                    { Text(glyph(ic), fontFamily = dejavu, fontSize = 18.sp) }
                }
            when (o.str("variant", "assist")) {
                "filter" -> FilterChip(
                    selected = o.bool("selected"), onClick = {}, label = label,
                    modifier = centerMod, enabled = enabled,
                    leadingIcon = leading, interactionSource = input.source,
                )
                "input" -> InputChip(
                    selected = o.bool("selected"), onClick = {}, label = label,
                    modifier = centerMod, enabled = enabled,
                    leadingIcon = leading, trailingIcon = trailing,
                    interactionSource = input.source,
                )
                "elevated" -> ElevatedAssistChip(
                    onClick = {}, label = label, modifier = centerMod,
                    enabled = enabled, leadingIcon = leading, interactionSource = input.source,
                )
                "suggestion" -> SuggestionChip(
                    onClick = {}, label = label, modifier = centerMod,
                    enabled = enabled, icon = leading, interactionSource = input.source,
                )
                else -> AssistChip(
                    onClick = {}, label = label, modifier = centerMod,
                    enabled = enabled, leadingIcon = leading, interactionSource = input.source,
                )
            }
        }

        "text_field" -> {
            val label = o.str("label").ifEmpty { null }
            val placeholder = o.str("placeholder").ifEmpty { null }
            val supporting = o.str("supporting").ifEmpty { null }
            val isError = o.bool("error")
            val value = o.str("value").ifEmpty { o.str("initial") }
            val tfMod = centerMod
            val tfArgs = TextFieldSpec(
                value = value, label = label, placeholder = placeholder,
                supporting = supporting, isError = isError, enabled = enabled,
            )
            if (o.str("variant", "outlined") == "filled") {
                TextField(
                    value = tfArgs.value, onValueChange = {}, modifier = tfMod,
                    enabled = tfArgs.enabled, isError = tfArgs.isError,
                    label = tfArgs.label?.let { l -> { Text(l) } },
                    placeholder = tfArgs.placeholder?.let { p -> { Text(p) } },
                    supportingText = tfArgs.supporting?.let { s -> { Text(s) } },
                    interactionSource = input.source, singleLine = !o.bool("multiline"),
                )
            } else {
                OutlinedTextField(
                    value = tfArgs.value, onValueChange = {}, modifier = tfMod,
                    enabled = tfArgs.enabled, isError = tfArgs.isError,
                    label = tfArgs.label?.let { l -> { Text(l) } },
                    placeholder = tfArgs.placeholder?.let { p -> { Text(p) } },
                    supportingText = tfArgs.supporting?.let { s -> { Text(s) } },
                    interactionSource = input.source, singleLine = !o.bool("multiline"),
                )
            }
        }

        else -> Text("unsupported:${spec.widget}", color = Color.Red)
    }
}

private data class TextFieldSpec(
    val value: String, val label: String?, val placeholder: String?,
    val supporting: String?, val isError: Boolean, val enabled: Boolean,
)

// Klaxon Colors are 0xRRGGBBAA; Compose Color wants ARGB.
fun colorFromInt(rrggbbaa: Long): Color {
    val v = rrggbbaa.toInt()
    val r = (v ushr 24) and 0xFF; val g = (v ushr 16) and 0xFF
    val b = (v ushr 8) and 0xFF; val a = v and 0xFF
    return Color(r, g, b, a)
}

// --- frame -------------------------------------------------------------

// Default M3 type scale with every style rebound to `font`. Typography's
// fontFamily ctor is still behind the expressive opt-in in this artifact and
// the 30-style primary is internal, so go through the public 15-style copy.
private fun pinnedTypography(font: FontFamily): Typography {
    fun TextStyle.f(): TextStyle = copy(fontFamily = font)
    val base = Typography()
    return base.copy(
        displayLarge = base.displayLarge.f(),
        displayMedium = base.displayMedium.f(),
        displaySmall = base.displaySmall.f(),
        headlineLarge = base.headlineLarge.f(),
        headlineMedium = base.headlineMedium.f(),
        headlineSmall = base.headlineSmall.f(),
        titleLarge = base.titleLarge.f(),
        titleMedium = base.titleMedium.f(),
        titleSmall = base.titleSmall.f(),
        bodyLarge = base.bodyLarge.f(),
        bodyMedium = base.bodyMedium.f(),
        bodySmall = base.bodySmall.f(),
        labelLarge = base.labelLarge.f(),
        labelMedium = base.labelMedium.f(),
        labelSmall = base.labelSmall.f(),
    )
}

@OptIn(ExperimentalComposeUiApi::class)
fun renderScene(spec: SceneSpec, outDir: File) {
    val w = spec.viewport[0]
    val h = spec.viewport[1]
    // The vendored DejaVu Sans — same file Klaxon serves via KLAXON_FONT_DIR.
    // ResourceFont loads the classpath copy (sourceSets -> deps/fonts).
    val dejavu = FontFamily(ResourceFont("DejaVuSans.ttf"))
    val scheme = if (spec.theme == "dark") darkColorScheme() else lightColorScheme()
    val dir = if (spec.dir == "rtl") LayoutDirection.Rtl else LayoutDirection.Ltr
    val input = SceneInput(spec)

    val scene = ImageComposeScene(w, h, Density(1f, 1f), dir, Dispatchers.Unconfined) {
        // m3-1.13.0-alpha02 keeps Typography's font-family ctor experimental,
        // so pull the default Typography instance and copy each style with
        // the pinned family instead of constructing one directly.
        MaterialTheme(colorScheme = scheme, typography = pinnedTypography(dejavu)) {
            SceneContent(spec, input, dejavu)
        }
    }
    try {
        // Frame 1 (t=1ns): layout — captures widget/item bounds centers.
        scene.render(1L).close()
        // Interactions are seeded at ~t0: tryEmit lands on the next frame's
        // collect pass, the ripple/press anim starts on the frame after —
        // the two settle frames mirror Klaxon's lazy arm at tick(0).
        seedState(spec, input)
        scene.render(2L).close()
        val t0 = 3L
        scene.render(t0).close()
        val img = scene.render(t0 + spec.t_ms * 1_000_000L)
        writePpm(img, w, h, File(outDir, "${spec.id}.ppm"))
        img.close()
        writeMeta(spec, input, scheme, File(outDir, "${spec.id}.json"))
    } finally {
        scene.close()
    }
}

// Compose Color → Klaxon's "rrggbbaa" hex.
private fun hexRgba(c: Color): String = buildString(8) {
    for (v in listOf(c.red, c.green, c.blue, c.alpha)) {
        append("%02x".format((v.coerceIn(0f, 1f) * 255f + 0.5f).toInt()))
    }
}

// Same schema as the Klaxon runner's <id>.json sidecar.
fun writeMeta(spec: SceneSpec, input: SceneInput, scheme: ColorScheme, path: File) {
    val b = input.bounds
    val meta = buildJsonObject {
        put("id", spec.id)
        put("widget", spec.widget)
        put("state", spec.state)
        put("theme", spec.theme)
        put("dir", spec.dir)
        putJsonArray("viewport") {
            add(JsonPrimitive(spec.viewport.getOrElse(0) { 0 }))
            add(JsonPrimitive(spec.viewport.getOrElse(1) { 0 }))
        }
        put("t_ms", spec.t_ms)
        putJsonArray("widget_bounds") {
            add(JsonPrimitive("%.2f".format(b.left).toDouble()))
            add(JsonPrimitive("%.2f".format(b.top).toDouble()))
            add(JsonPrimitive("%.2f".format(b.width).toDouble()))
            add(JsonPrimitive("%.2f".format(b.height).toDouble()))
        }
        putJsonObject("colors") {
            put("surface", hexRgba(scheme.surface))
            put("primary", hexRgba(scheme.primary))
            put("on_surface", hexRgba(scheme.onSurface))
            put("on_surface_variant", hexRgba(scheme.onSurfaceVariant))
        }
    }
    path.writeText(Json { prettyPrint = true }.encodeToString(JsonObject.serializer(), meta) + "\n")
}

fun writePpm(img: org.jetbrains.skia.Image, w: Int, h: Int, path: File) {
    val bmp = Bitmap()
    bmp.allocPixels(ImageInfo.makeN32(w, h, ColorAlphaType.PREMUL))
    check(img.readPixels(bmp)) { "readPixels failed for ${path.name}" }
    val bytes = bmp.readPixels() ?: error("bitmap readback failed")
    File(path.parent!!).mkdirs()
    path.outputStream().use { f ->
        f.write("P6\n$w $h\n255\n".toByteArray())
        // N32 = BGRA byte order on little-endian → emit R,G,B.
        var i = 0
        while (i + 3 < bytes.size) {
            f.write(byteArrayOf(bytes[i + 2], bytes[i + 1], bytes[i]))
            i += 4
        }
    }
}

// --- main --------------------------------------------------------------

fun main(args: Array<String>) {
    var scenesPath = "../../scenes.json"
    var outDir = "../../out/compose"
    var filter: String? = null
    for (arg in args) {
        when {
            arg.startsWith("--scenes=") -> scenesPath = arg.substringAfter('=')
            arg.startsWith("--out=") -> outDir = arg.substringAfter('=')
            arg.startsWith("--scene=") -> filter = arg.substringAfter('=')
        }
    }
    val doc = JsonFormat.decodeFromString<SceneDoc>(File(scenesPath).readText())
    val out = File(outDir).apply { mkdirs() }
    var ran = 0
    var failed = 0
    for (scene in doc.scenes) {
        if (filter != null && !scene.id.contains(filter)) continue
        try {
            renderScene(scene, out)
            ran += 1
            println("ok   ${scene.id}")
        } catch (e: Throwable) {
            failed += 1
            println("FAIL ${scene.id} — ${e.message ?: e::class.simpleName}")
        }
    }
    println("compose fidelity: $ran rendered, $failed failed -> $outDir")
    if (failed > 0) kotlin.system.exitProcess(1)
    if (ran == 0) kotlin.system.exitProcess(2)
}
