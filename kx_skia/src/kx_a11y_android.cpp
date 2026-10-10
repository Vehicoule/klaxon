// kx_a11y_android.cpp — Android TalkBack bridge (Phase 3d-a11y).
//
// JNI pont entre le bridge C Zig (src/a11y_bridge.zig) et le delegate Java
// TalkBack (android/.../KxAccessibilityDelegate.java). Same contract as
// kx_a11y_macos.mm (NSAccessibility), kx_a11y.js (ARIA hidden DOM):
//
//   Zig (SDL thread)                    Java (UI thread, via Handler)
//   ─────────────────                   ───────────────────────────
//   kx_a11y_init(root)  ──JNI──►  new KxAccessibilityDelegate(mSurface)
//                                  mSurface.setAccessibilityDelegate(...)
//   bridge events (C cb) ──JNI──►  onTreeDirty / onAnnounce / onFocusChanged
//   kx_a11y_dump_tree ──parsed──►  node cache, pulled by nativeGetNode*
//   nativeActivate / nativeFocus ◄─JNI── performAction (double-tap / focus)
//
// The delegate is attached from native (not from KlaxonActivity): the whole
// bridge is wired by kx_a11y_init, exactly like the macOS one. The SDLSurface
// is reached through the SDLActivity.mSurface static field.
//
// ABI note: the bridge callback receives BridgeEventC BY VALUE (extern
// struct) — the field order below mirrors ui/semantics.zig. Do NOT flatten
// it to scalar parameters: that is the wasm ABI only. Verified against the
// Zig 0.17 arm64 C ABI (a flattened callback reads garbage on native).
//
// v1: swipe navigation, double-tap activation, announcements, focus sync.
// The dump carries each node's rect in window space (x|y|w|h =
// mapRectToRoot(bounds), Phase 3de) — the provider positions the virtual
// nodes from them, so TalkBack's touch exploration and highlight work.
// TalkBack actions call straight into Zig from the UI thread (v1; an
// SDL-thread action queue is the follow-up).
#include <SDL3/SDL.h> // SDL_GetAndroidJNIEnv / SDL_GetAndroidActivity (SDL_system.h)

#include <jni.h>
#include <android/log.h>

#include <cstddef>
#include <cstdint>
#include <mutex>
#include <string>
#include <vector>

#define KX_LOGI(...) __android_log_print(ANDROID_LOG_INFO, "kx_a11y", __VA_ARGS__)
#define KX_LOGE(...) __android_log_print(ANDROID_LOG_ERROR, "kx_a11y", __VA_ARGS__)

// --- Zig bridge ABI (src/a11y_bridge.zig, src/ui/semantics.zig) ---
extern "C" {

// BridgeEventC — extern struct, passed BY VALUE (see the ABI note above).
struct KxBridgeEventC {
    uint32_t kind;    // 0=tree_dirty 1=focus_changed 2=announce 3=control_changed
    uint64_t node_id; // Node pointer (decimal in the dump)
    const char* text; // announce payload (borrowed during the call only)
    size_t text_len;
    uint32_t region;  // LiveRegion: 0=off 1=polite 2=assertive
};

enum {
    KX_A11Y_TREE_DIRTY = 0,
    KX_A11Y_FOCUS_CHANGED = 1,
    KX_A11Y_ANNOUNCE = 2,
    KX_A11Y_CONTROL_CHANGED = 3,
};

void kx_a11y_set_bridge(void (*fn)(void* userdata, KxBridgeEventC event), void* userdata);
char* kx_a11y_dump_tree(void* root_node);
void kx_a11y_free_string(char* s);
// OS bridge -> app (shared with the iOS bridge): focus / activate the node
// whose pointer is `ptr`, resolved from `root` (a real click through the
// input router at the node's visual center).
void kx_a11y_focus_node(void* root, uint64_t ptr);
void kx_a11y_activate_node(void* root, uint64_t ptr);

} // extern "C"

// --- Parsed semantic tree (the node provider's data source) ---
struct KxA11yNode {
    int depth = 0;
    int parent = -1;   // index of the parent node, -1 = top level
    uint64_t ptr = 0;  // Node pointer — the provider's virtual-id key
    int checked = 0;   // 0 = null, 1 = false, 2 = true
    bool focusable = false;
    int x = 0, y = 0, w = 0, h = 0; // rect in window space (mapRectToRoot)
    std::string role;
    std::string label;
    std::string value;
};

static std::mutex g_nodes_mutex; // guards g_nodes (SDL thread writes, UI thread reads)
static std::vector<KxA11yNode> g_nodes;

// --- Java delegate handle ---
static jobject g_delegate = nullptr; // global ref on KxAccessibilityDelegate
static jmethodID g_mid_tree_dirty = nullptr;
static jmethodID g_mid_announce = nullptr;
static jmethodID g_mid_focus_changed = nullptr;

static void* g_zig_root_node = nullptr;

// --- Dump parsing ---

static int parseInt(const char* s, size_t len) {
    int v = 0;
    bool neg = false;
    size_t i = 0;
    if (i < len && s[i] == '-') { neg = true; i++; }
    for (; i < len; i++) v = v * 10 + (s[i] - '0');
    return neg ? -v : v;
}

static unsigned long long parseU64(const char* s, size_t len) {
    unsigned long long v = 0;
    for (size_t i = 0; i < len; i++) v = v * 10 + (unsigned long long)(s[i] - '0');
    return v;
}

// Parse the flat dump — one line per visible semantic node:
//   "depth|role|label|value|focusable|ptr|checked|x|y|w|h\n"
// Parent links are resolved with a depth stack, the same algorithm as the
// wasm mirror (web/kx_a11y.js). The result replaces the node cache.
static void parseDump(const char* dump) {
    std::vector<KxA11yNode> nodes;
    std::vector<int> stack; // stack[d] = index of the node at depth d on the current path
    const char* p = dump;
    while (p && *p) {
        const char* eol = p;
        while (*eol && *eol != '\n') eol++;
        const char* fields[11];
        size_t lens[11];
        int nfields = 0;
        const char* s = p;
        while (s < eol && nfields < 11) {
            const char* bar = s;
            while (bar < eol && *bar != '|') bar++;
            fields[nfields] = s;
            lens[nfields] = (size_t)(bar - s);
            nfields++;
            s = (*bar == '|') ? bar + 1 : bar;
        }
        if (nfields >= 7) {
            KxA11yNode node;
            node.depth = parseInt(fields[0], lens[0]);
            node.role.assign(fields[1], lens[1]);
            node.label.assign(fields[2], lens[2]);
            node.value.assign(fields[3], lens[3]);
            node.focusable = parseInt(fields[4], lens[4]) != 0;
            node.ptr = parseU64(fields[5], lens[5]);
            node.checked = parseInt(fields[6], lens[6]);
            if (nfields >= 11) {
                node.x = parseInt(fields[7], lens[7]);
                node.y = parseInt(fields[8], lens[8]);
                node.w = parseInt(fields[9], lens[9]);
                node.h = parseInt(fields[10], lens[10]);
            }
            while ((int)stack.size() > node.depth) stack.pop_back();
            node.parent = stack.empty() ? -1 : stack.back();
            stack.push_back((int)nodes.size());
            nodes.push_back(std::move(node));
        }
        p = (*eol == '\n') ? eol + 1 : eol;
    }
    std::lock_guard<std::mutex> lock(g_nodes_mutex);
    g_nodes = std::move(nodes);
}

// --- JNI helpers ---

// FindClass from a native-attached thread only sees the boot classpath, so
// app classes (com.klaxon.gallery.*, org.libsdl.app.*) are loaded through
// the activity's ClassLoader.
static jclass findClass(JNIEnv* env, jobject activity, const char* name) {
    jclass activity_class = env->GetObjectClass(activity);
    if (!activity_class) return nullptr;
    jmethodID get_class_loader =
        env->GetMethodID(activity_class, "getClassLoader", "()Ljava/lang/ClassLoader;");
    env->DeleteLocalRef(activity_class);
    if (!get_class_loader) return nullptr;
    jobject loader = env->CallObjectMethod(activity, get_class_loader);
    if (!loader) return nullptr;
    jclass class_class = env->FindClass("java/lang/Class");
    jmethodID load_class = class_class
        ? env->GetMethodID(class_class, "loadClass", "(Ljava/lang/String;)Ljava/lang/Class;")
        : nullptr;
    if (class_class) env->DeleteLocalRef(class_class);
    if (!load_class) { env->DeleteLocalRef(loader); return nullptr; }
    jstring jname = env->NewStringUTF(name);
    jclass result = static_cast<jclass>(env->CallObjectMethod(loader, load_class, jname));
    env->DeleteLocalRef(jname);
    env->DeleteLocalRef(loader);
    return result;
}

// The SDLSurface the app draws on (SDLActivity.mSurface, a static field).
// Returns a local ref, or null when the surface is not created yet.
static jobject getSurface(JNIEnv* env, jobject activity) {
    jclass activity_class = env->GetObjectClass(activity);
    if (!activity_class) return nullptr;
    jfieldID field =
        env->GetFieldID(activity_class, "mSurface", "Lorg/libsdl/app/SDLSurface;");
    jobject surface = field ? env->GetStaticObjectField(activity_class, field) : nullptr;
    env->DeleteLocalRef(activity_class);
    return surface;
}

static void clearException(JNIEnv* env, const char* what) {
    if (env->ExceptionCheck()) {
        KX_LOGE("kx_a11y: JNI exception in %s", what);
        env->ExceptionDescribe();
        env->ExceptionClear();
    }
}

// --- Bridge event callback (called from Zig on the SDL thread) ---
static void a11yBridgeCallback(void* userdata, KxBridgeEventC ev) {
    (void)userdata;
    JNIEnv* env = static_cast<JNIEnv*>(SDL_GetAndroidJNIEnv());
    if (!env || !g_delegate) return;
    switch (ev.kind) {
        case KX_A11Y_TREE_DIRTY:
        case KX_A11Y_CONTROL_CHANGED: {
            // Re-dump the semantic tree into the node cache; the delegate
            // re-reads it through the nativeGetNode* pull API. control_changed
            // re-dumps too (same as the wasm mirror): one control's value or
            // checked state flipped.
            if (g_zig_root_node) {
                char* dump = kx_a11y_dump_tree(g_zig_root_node);
                if (dump) {
                    parseDump(dump);
                    kx_a11y_free_string(dump);
                }
            }
            if (g_mid_tree_dirty) env->CallVoidMethod(g_delegate, g_mid_tree_dirty);
            break;
        }
        case KX_A11Y_FOCUS_CHANGED:
            if (g_mid_focus_changed) {
                env->CallVoidMethod(g_delegate, g_mid_focus_changed, (jlong)ev.node_id);
            }
            break;
        case KX_A11Y_ANNOUNCE:
            if (g_mid_announce && ev.text && ev.text_len > 0) {
                // NewStringUTF takes modified UTF-8 (null-terminated) — the
                // payload is borrowed, so copy it first.
                std::string msg(ev.text, ev.text_len);
                jstring text = env->NewStringUTF(msg.c_str());
                if (text) {
                    env->CallVoidMethod(g_delegate, g_mid_announce, text, (jint)ev.region);
                    env->DeleteLocalRef(text);
                }
            }
            break;
        default:
            break;
    }
    clearException(env, "bridge callback");
}

// --- Public C API (called from Zig host.zig, like the macOS bridge) ---
extern "C" {

/// Initialize the TalkBack bridge. `root_node` is the Klaxon root Node (used
/// to dump the semantic tree on tree_dirty). Attaches a
/// KxAccessibilityDelegate to SDLActivity.mSurface over JNI.
void kx_a11y_init(void* root_node) {
    g_zig_root_node = root_node;
    // Register the C bridge callback with the Zig semantics module.
    kx_a11y_set_bridge(a11yBridgeCallback, nullptr);
    if (g_delegate) return; // already initialized

    JNIEnv* env = static_cast<JNIEnv*>(SDL_GetAndroidJNIEnv());
    if (!env) { KX_LOGE("kx_a11y_init: no JNIEnv"); return; }
    jobject activity = static_cast<jobject>(SDL_GetAndroidActivity()); // local ref
    if (!activity) { KX_LOGE("kx_a11y_init: no activity"); return; }

    jobject surface = getSurface(env, activity);
    if (!surface) {
        KX_LOGE("kx_a11y_init: SDLActivity.mSurface is null (surface not created yet?)");
        clearException(env, "getSurface");
        env->DeleteLocalRef(activity);
        return;
    }

    // Construct the delegate and attach it to the surface view.
    jclass delegate_class = findClass(env, activity, "com.klaxon.gallery.KxAccessibilityDelegate");
    if (!delegate_class) {
        KX_LOGE("kx_a11y_init: KxAccessibilityDelegate class not found");
        clearException(env, "findClass");
        env->DeleteLocalRef(surface);
        env->DeleteLocalRef(activity);
        return;
    }
    jmethodID ctor = env->GetMethodID(delegate_class, "<init>", "(Landroid/view/View;)V");
    jobject delegate = ctor ? env->NewObject(delegate_class, ctor, surface) : nullptr;
    if (!delegate) {
        KX_LOGE("kx_a11y_init: delegate construction failed");
        clearException(env, "NewObject");
        env->DeleteLocalRef(delegate_class);
        env->DeleteLocalRef(surface);
        env->DeleteLocalRef(activity);
        return;
    }
    jclass view_class = env->GetObjectClass(surface);
    jmethodID set_delegate = view_class ? env->GetMethodID(
        view_class, "setAccessibilityDelegate", "(Landroid/view/View$AccessibilityDelegate;)V")
                                       : nullptr;
    if (view_class) env->DeleteLocalRef(view_class);
    if (set_delegate) env->CallVoidMethod(surface, set_delegate, delegate);
    clearException(env, "setAccessibilityDelegate");
    env->DeleteLocalRef(surface);

    // Cache the global ref + the bridge entry-point method ids.
    g_delegate = env->NewGlobalRef(delegate);
    g_mid_tree_dirty = env->GetMethodID(delegate_class, "onTreeDirty", "()V");
    g_mid_announce = env->GetMethodID(delegate_class, "onAnnounce", "(Ljava/lang/String;I)V");
    g_mid_focus_changed = env->GetMethodID(delegate_class, "onFocusChanged", "(J)V");
    env->DeleteLocalRef(delegate);
    env->DeleteLocalRef(delegate_class);
    env->DeleteLocalRef(activity);
    clearException(env, "init");
    KX_LOGI("kx_a11y_init: TalkBack delegate attached");
}

/// Shut down the bridge: detach the delegate from the surface, drop the
/// global ref, unregister the C bridge callback.
void kx_a11y_shutdown(void) {
    kx_a11y_set_bridge(nullptr, nullptr);
    JNIEnv* env = static_cast<JNIEnv*>(SDL_GetAndroidJNIEnv());
    if (env && g_delegate) {
        jobject activity = static_cast<jobject>(SDL_GetAndroidActivity()); // local ref
        if (activity) {
            jobject surface = getSurface(env, activity);
            if (surface) {
                jclass view_class = env->GetObjectClass(surface);
                jmethodID set_delegate = view_class ? env->GetMethodID(
                    view_class, "setAccessibilityDelegate",
                    "(Landroid/view/View$AccessibilityDelegate;)V")
                                                   : nullptr;
                if (view_class) env->DeleteLocalRef(view_class);
                if (set_delegate) env->CallVoidMethod(surface, set_delegate, nullptr);
                clearException(env, "detach");
                env->DeleteLocalRef(surface);
            }
            env->DeleteLocalRef(activity);
        }
        env->DeleteGlobalRef(g_delegate);
    }
    g_delegate = nullptr;
    g_mid_tree_dirty = nullptr;
    g_mid_announce = nullptr;
    g_mid_focus_changed = nullptr;
    g_zig_root_node = nullptr;
    std::lock_guard<std::mutex> lock(g_nodes_mutex);
    g_nodes.clear();
}

/// Opaque handle on the Java delegate (API parity with the macOS bridge).
void* kx_a11y_root_element(void) {
    return g_delegate;
}

} // extern "C"

// --- Node cache pull API (Java -> native, called by KxAccessibilityDelegate
// on the UI thread; virtualDescendantId = the dump index) ---
#define KX_JNI(name) Java_com_klaxon_gallery_KxAccessibilityDelegate_##name

static jstring nodeStringField(JNIEnv* env, jint index, const std::string KxA11yNode::*field) {
    std::string value;
    {
        std::lock_guard<std::mutex> lock(g_nodes_mutex);
        if (index < 0 || (size_t)index >= g_nodes.size()) return nullptr;
        value = g_nodes[(size_t)index].*field;
    }
    return env->NewStringUTF(value.c_str());
}

extern "C" {

JNIEXPORT jint JNICALL KX_JNI(nativeGetNodeCount)(JNIEnv*, jclass) {
    std::lock_guard<std::mutex> lock(g_nodes_mutex);
    return (jint)g_nodes.size();
}

JNIEXPORT jint JNICALL KX_JNI(nativeGetNodeParent)(JNIEnv*, jclass, jint index) {
    std::lock_guard<std::mutex> lock(g_nodes_mutex);
    if (index < 0 || (size_t)index >= g_nodes.size()) return -1;
    return g_nodes[(size_t)index].parent;
}

JNIEXPORT jlong JNICALL KX_JNI(nativeGetNodePtr)(JNIEnv*, jclass, jint index) {
    std::lock_guard<std::mutex> lock(g_nodes_mutex);
    if (index < 0 || (size_t)index >= g_nodes.size()) return 0;
    return (jlong)g_nodes[(size_t)index].ptr;
}

JNIEXPORT jstring JNICALL KX_JNI(nativeGetNodeRole)(JNIEnv* env, jclass, jint index) {
    return nodeStringField(env, index, &KxA11yNode::role);
}

JNIEXPORT jstring JNICALL KX_JNI(nativeGetNodeLabel)(JNIEnv* env, jclass, jint index) {
    return nodeStringField(env, index, &KxA11yNode::label);
}

JNIEXPORT jstring JNICALL KX_JNI(nativeGetNodeValue)(JNIEnv* env, jclass, jint index) {
    return nodeStringField(env, index, &KxA11yNode::value);
}

JNIEXPORT jboolean JNICALL KX_JNI(nativeGetNodeFocusable)(JNIEnv*, jclass, jint index) {
    std::lock_guard<std::mutex> lock(g_nodes_mutex);
    if (index < 0 || (size_t)index >= g_nodes.size()) return JNI_FALSE;
    return g_nodes[(size_t)index].focusable ? JNI_TRUE : JNI_FALSE;
}

JNIEXPORT jint JNICALL KX_JNI(nativeGetNodeChecked)(JNIEnv*, jclass, jint index) {
    std::lock_guard<std::mutex> lock(g_nodes_mutex);
    if (index < 0 || (size_t)index >= g_nodes.size()) return 0;
    return g_nodes[(size_t)index].checked;
}

// The node's rect in window space: out[0..3] = x, y, w, h.
JNIEXPORT jboolean JNICALL KX_JNI(nativeGetNodeBounds)(JNIEnv* env, jclass, jint index, jintArray out) {
    if (!out) return JNI_FALSE;
    if (env->GetArrayLength(out) < 4) return JNI_FALSE;
    jint rect[4] = { 0, 0, 0, 0 };
    {
        std::lock_guard<std::mutex> lock(g_nodes_mutex);
        if (index < 0 || (size_t)index >= g_nodes.size()) return JNI_FALSE;
        const KxA11yNode& node = g_nodes[(size_t)index];
        rect[0] = node.x;
        rect[1] = node.y;
        rect[2] = node.w;
        rect[3] = node.h;
    }
    env->SetIntArrayRegion(out, 0, 4, rect);
    return JNI_TRUE;
}

// TalkBack double-tap: activate the node in Zig — a real click through the
// input router at the node's visual center (kx_a11y_activate_node, shared
// with the iOS bridge). v1 calls straight into Zig from the UI thread —
// see the file header.
JNIEXPORT void JNICALL KX_JNI(nativeActivate)(JNIEnv*, jclass, jlong ptr) {
    if (ptr && g_zig_root_node) kx_a11y_activate_node(g_zig_root_node, (uint64_t)ptr);
}

// TalkBack focus action: move the Zig keyboard focus to the node
// (kx_a11y_focus_node, shared with the iOS bridge).
JNIEXPORT void JNICALL KX_JNI(nativeFocus)(JNIEnv*, jclass, jlong ptr) {
    if (ptr && g_zig_root_node) kx_a11y_focus_node(g_zig_root_node, (uint64_t)ptr);
}

} // extern "C"
