// kx_a11y_win.cpp — Windows UI Automation (UIA) bridge (Phase 3c.2).
//
// Maps Klaxon's semantic tree (ui/semantics.zig) to Microsoft UI Automation
// so Narrator/NVDA/Inspect.exe see the SDL window's content. Same contract
// as kx_a11y_macos.mm / kx_a11y_android.cpp / web/kx_a11y.js:
//
//   Zig (SDL thread)                        UIA core (provider threads)
//   ─────────────────                       ─────────────────────────
//   kx_a11y_init(root)  ──►  find the SDL HWND, subclass its WNDPROC,
//                            build the provider tree, install the C bridge
//   bridge events (C cb) ──► rebuild node snapshot on tree_dirty /
//                            control_changed, raise UiaRaise* events
//   WM_GETOBJECT       ◄──   UiaReturnRawElementProvider(root provider)
//   KX_WM_A11Y_ACTION  ◄──   Invoke/Select/SetFocus marshaled back onto
//                            the SDL thread (PostMessage → kx_a11y_*_node)
//
// Provider model (raw HWND providers, plain COM — no ATL/WRL):
//   - KxUiaRootProvider: IRawElementProviderSimple +
//     IRawElementProviderFragment + IRawElementProviderFragmentRoot — the
//     window-level fragment root returned by WM_GETOBJECT.
//   - KxUiaNodeProvider per semantic node: IRawElementProviderSimple +
//     IRawElementProviderFragment, plus role-gated patterns (IInvokeProvider
//     buttons/links/menu items, IToggleProvider toggles/checkboxes/radios,
//     IValueProvider text fields/sliders/progress/scrollbars,
//     ISelectionItemProvider radios/tabs/list items, ITextProvider text).
//   - KxUiaTextRange: ITextRangeProvider over a node's document text.
//
// Node data flows through a dump-parsed snapshot (same flat format:
// "depth|role|label|value|focusable|ptr|checked|x|y|w|h"). Providers key
// nodes by the Zig Node pointer and resolve fields live from the snapshot
// under g_mutex, so a tree swap refreshes every provider in place; providers
// for vanished nodes are UiaDisconnectProvider'd. UIA may call provider
// methods on its own threads — every snapshot access takes the mutex, and
// app-bound actions are posted back to the window thread (KX_WM_A11Y_ACTION)
// instead of calling into Zig directly (Zig's tree/router are not
// thread-safe).
//
// WM_GETOBJECT never reaches SDL's message hook (SDL_SetWindowsMessageHook
// taps the queue before TranslateMessage — WM_GETOBJECT is SendMessage'd
// straight at the WNDPROC), so the HWND is subclassed with
// SetWindowLongPtrW(GWLP_WNDPROC). Build note: this file is compiled WITHOUT
// WIN32_LEAN_AND_MEAN (build.zig compileMsvcShims lean=false) —
// UIAutomation.h needs the ole2 types.
#include "kx_skia.h"

#include <SDL3/SDL.h>

#include <windows.h>
#include <ole2.h>
#include <oleauto.h>
#include <UIAutomation.h>

// mingw-w64 headers declare no IRawElementProviderUnknown — its Uia* entry
// points take IRawElementProviderSimple and there is no separate marker IID.
// The MSVC SDK (the shipping target) does have it. KX_UIA_PROVIDER_BASE
// appends the extra base class only where it exists; KX_UIA_PROVIDER_ARG is
// the parameter type UiaReturnRawElementProvider/UiaDisconnectProvider take.
#if defined(__MINGW32__) || defined(__MINGW64__)
#define KX_UIA_PROVIDER_BASE
#define KX_UIA_PROVIDER_ARG IRawElementProviderSimple
#define KX_UIA_HAS_UNKNOWN 0
#else
#define KX_UIA_PROVIDER_BASE , public IRawElementProviderUnknown
#define KX_UIA_PROVIDER_ARG IRawElementProviderUnknown
#define KX_UIA_HAS_UNKNOWN 1
#endif

#include <cmath>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <cwctype>
#include <mutex>
#include <new>
#include <string>
#include <unordered_map>
#include <vector>

// Older WinSDKs may not declare every constant used below — provide the
// documented fallbacks so the translation unit compiles regardless.
#ifndef UiaRootObjectId
#define UiaRootObjectId ((LONG)-25)
#endif
#ifndef UiaAppendRuntimeId
#define UiaAppendRuntimeId 3
#endif
#ifndef UIA_E_ELEMENTNOTAVAILABLE
#define UIA_E_ELEMENTNOTAVAILABLE ((HRESULT)0x80040201L)
#endif
#ifndef UIA_E_INVALIDOPERATION
#define UIA_E_INVALIDOPERATION ((HRESULT)0x80131509L)
#endif
#ifndef UIA_HeadingLevelPropertyId
#define UIA_HeadingLevelPropertyId 30173
#endif
#ifndef UIA_LiveRegionChangedEventId
#define UIA_LiveRegionChangedEventId 20024
#endif
#ifndef UIA_SelectionItem_ElementSelectedEventId
#define UIA_SelectionItem_ElementSelectedEventId 20011
#endif

// --- Zig bridge ABI (src/a11y_bridge.zig, src/ui/semantics.zig) ---
extern "C" {

// BridgeEventC — extern struct, passed BY VALUE (mirrors BridgeEventC in
// ui/semantics.zig field for field). Do NOT flatten it to scalar
// parameters: on arm64 a struct passed by value rides in registers
// differently than flattened scalars, and a flattened callback reads
// garbage. (Same ABI note as kx_a11y_android.cpp.)
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
// OS bridge -> app: focus / activate the node whose pointer is `ptr`,
// resolved from `root` (activation = a real click through the input router
// at the node's visual center). Shared with the iOS/Android bridges.
void kx_a11y_focus_node(void* root, uint64_t ptr);
void kx_a11y_activate_node(void* root, uint64_t ptr);

} // extern "C"

// --- Parsed semantic tree (the providers' data source) ---
struct KxA11yNode {
    int depth = 0;
    int parent = -1;                // index into g_nodes; -1 = top level
    std::vector<int> children;      // indices into g_nodes
    uint64_t ptr = 0;               // Node pointer — the provider's key
    int checked = 0;                // 0 = null, 1 = false, 2 = true
    bool focusable = false;
    int x = 0, y = 0, w = 0, h = 0; // rect in window space (mapRectToRoot)
    std::string role;
    std::string label;
    std::string value;
};

static std::mutex g_mutex;                         // guards snapshot + providers
static std::vector<KxA11yNode> g_nodes;            // current snapshot
static std::unordered_map<uint64_t, int> g_index;  // ptr -> index in g_nodes
static uint64_t g_focused_ptr = 0;                 // last focus_changed node

static void* g_zig_root_node = nullptr;            // Klaxon root Node*
static HWND g_hwnd = nullptr;                      // SDL window's HWND
static WNDPROC g_old_wndproc = nullptr;            // pre-subclass proc

// Private message ID for app-bound actions (posted from provider methods
// running on UIA threads back to the SDL thread — see the file header).
// wParam is the action kind, lParam the node pointer.
static const UINT KX_WM_A11Y_ACTION = WM_APP + 0x0A17;
static const WPARAM KX_A11Y_DO_FOCUS = 1;
static const WPARAM KX_A11Y_DO_ACTIVATE = 2;

// --- Dump parsing (same algorithm as kx_a11y_android.cpp / web/kx_a11y.js) ---

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

// Bounds may be fractional (mapRectToRoot emits "10.5"): parse as float and
// round — a digit-only parse would read '.' as a digit.
static int parseCoord(const char* s, size_t len) {
    char buf[32];
    size_t n = len < sizeof(buf) - 1 ? len : sizeof(buf) - 1;
    memcpy(buf, s, n);
    buf[n] = '\0';
    return (int)lroundf(strtof(buf, nullptr));
}

// Parse the flat dump into a fresh snapshot (not yet installed). One line
// per visible semantic node; parent links resolve with a depth stack, and
// each parent records its children for navigation.
static std::vector<KxA11yNode> parseDump(const char* dump) {
    std::vector<KxA11yNode> nodes;
    std::vector<int> stack; // stack[d] = index of the node at depth d on the path
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
                node.x = parseCoord(fields[7], lens[7]);
                node.y = parseCoord(fields[8], lens[8]);
                node.w = parseCoord(fields[9], lens[9]);
                node.h = parseCoord(fields[10], lens[10]);
            }
            while ((int)stack.size() > node.depth) stack.pop_back();
            node.parent = stack.empty() ? -1 : stack.back();
            stack.push_back((int)nodes.size()); // the index the node will occupy
            nodes.push_back(std::move(node));
            const int idx = (int)nodes.size() - 1;
            const int parent = nodes[(size_t)idx].parent;
            if (parent >= 0) nodes[(size_t)parent].children.push_back(idx);
        }
        p = (*eol == '\n') ? eol + 1 : eol;
    }
    return nodes;
}

// Rebuild g_index to match g_nodes (caller holds g_mutex).
static void reindex() {
    g_index.clear();
    for (size_t i = 0; i < g_nodes.size(); i++) g_index[g_nodes[i].ptr] = (int)i;
}

// --- String helpers ---

static std::wstring wstrFromUtf8(const char* s, size_t len) {
    if (!s || len == 0) return std::wstring();
    int wlen = MultiByteToWideChar(CP_UTF8, 0, s, (int)len, nullptr, 0);
    if (wlen <= 0) return std::wstring();
    std::wstring out((size_t)wlen, L'\0');
    MultiByteToWideChar(CP_UTF8, 0, s, (int)len, out.data(), wlen);
    return out;
}

static BSTR bstrFromUtf8(const std::string& s) {
    std::wstring w = wstrFromUtf8(s.data(), s.size());
    return SysAllocStringLen(w.data(), (UINT)w.size());
}

// --- Role mapping (mirrors the macOS/Android tables) ---

static LONG controlTypeOf(const std::string& role) {
    if (role == "text") return UIA_TextControlTypeId;
    if (role == "heading") return UIA_TextControlTypeId; // + HeadingLevel property
    if (role == "button") return UIA_ButtonControlTypeId;
    if (role == "link") return UIA_HyperlinkControlTypeId;
    if (role == "image") return UIA_ImageControlTypeId;
    if (role == "text_field") return UIA_EditControlTypeId;
    if (role == "toggle") return UIA_CheckBoxControlTypeId;
    if (role == "checkbox") return UIA_CheckBoxControlTypeId;
    if (role == "radio") return UIA_RadioButtonControlTypeId;
    if (role == "slider") return UIA_SliderControlTypeId;
    if (role == "progress") return UIA_ProgressBarControlTypeId;
    if (role == "scrollbar") return UIA_ScrollBarControlTypeId;
    if (role == "list") return UIA_ListControlTypeId;
    if (role == "list_item") return UIA_ListItemControlTypeId;
    if (role == "dialog") return UIA_PaneControlTypeId;
    if (role == "alert") return UIA_GroupControlTypeId;
    if (role == "menu") return UIA_MenuControlTypeId;
    if (role == "menu_item") return UIA_MenuItemControlTypeId;
    if (role == "tab") return UIA_TabItemControlTypeId;
    if (role == "tab_panel") return UIA_PaneControlTypeId;
    if (role == "separator") return UIA_SeparatorControlTypeId;
    return UIA_GroupControlTypeId; // "none", "group", unknown
}

// Pattern capability sets (QueryInterface/GetPatternProvider filter on these).
static bool isInvokeRole(const std::string& r) {
    return r == "button" || r == "link" || r == "menu_item";
}
static bool isToggleRole(const std::string& r) {
    return r == "toggle" || r == "checkbox" || r == "radio";
}
static bool isValueRole(const std::string& r) {
    return r == "text_field" || r == "slider" || r == "progress" || r == "scrollbar";
}
static bool isSelectionItemRole(const std::string& r) {
    return r == "radio" || r == "tab" || r == "list_item";
}
static bool isTextRole(const std::string& r) {
    return r == "text" || r == "heading" || r == "text_field";
}

// checked (0=null 1=false 2=true) → ToggleState.
static LONG kxToggleState(int checked) {
    if (checked == 2) return ToggleState_On;
    if (checked == 1) return ToggleState_Off;
    return ToggleState_Indeterminate;
}

// The document text the Text pattern exposes: for editable-ish roles the
// value is the document, for static text it's the label.
static std::string docTextOf(const KxA11yNode& n) {
    if (n.role == "text_field") return n.value;
    return n.label.empty() ? n.value : n.label;
}

// --- Snapshot access (all under g_mutex) ---

// Copy a node's data out of the snapshot. Returns false when the ptr is
// stale (the node vanished in the last rebuild — the caller's provider is
// being disconnected and should report "element gone").
static bool snapshotCopy(uint64_t ptr, KxA11yNode* out) {
    std::lock_guard<std::mutex> lock(g_mutex);
    auto it = g_index.find(ptr);
    if (it == g_index.end()) return false;
    *out = g_nodes[(size_t)it->second];
    return true;
}

// Node rect (window space) → UiaRect (screen coordinates, per the UIA
// BoundingRectangle contract).
static UiaRect screenRect(const KxA11yNode& n) {
    UiaRect r{ (double)n.x, (double)n.y, (double)n.w, (double)n.h };
    if (g_hwnd) {
        POINT pt{ n.x, n.y };
        if (ClientToScreen(g_hwnd, &pt)) {
            r.left = (double)pt.x;
            r.top = (double)pt.y;
        }
    }
    return r;
}

// --- Providers ---
class KxUiaNodeProvider;
class KxUiaRootProvider;

static KxUiaRootProvider* g_root_provider = nullptr;
static std::unordered_map<uint64_t, KxUiaNodeProvider*> g_providers; // 1 ref each

// Caller takes one reference; the map keeps its own.
static KxUiaNodeProvider* providerFor(uint64_t ptr);

// AddRef'd root as its simple interface (caller Releases).
static IRawElementProviderSimple* rootSimpleRef();

// Map snapshot index → AddRef'd fragment interface. Caller holds g_mutex.
static HRESULT providerFragmentForLocked(int index, IRawElementProviderFragment** pRetVal);

// Post an app-bound action to the window thread (providers run on UIA's
// threads; Zig state may only be touched from the SDL thread).
static void postAction(WPARAM action, uint64_t ptr) {
    if (g_hwnd) PostMessageW(g_hwnd, KX_WM_A11Y_ACTION, action, (LPARAM)ptr);
}

// --- KxUiaTextRange: ITextRangeProvider over a node's document text ---
// A string range in [0, len). v1 supports the units the document text
// actually has (character/word/line/paragraph/document); no embedded
// children or attributes.
class KxUiaTextRange final : public ITextRangeProvider {
public:
    KxUiaTextRange(uint64_t node, int start, int end)
        : m_ref(1), m_node(node), m_start(start), m_end(end) {}

    // --- IUnknown ---
    HRESULT STDMETHODCALLTYPE QueryInterface(REFIID riid, void** ppv) override {
        if (!ppv) return E_POINTER;
        *ppv = nullptr;
        if (riid == __uuidof(IUnknown) || riid == __uuidof(ITextRangeProvider)) {
            *ppv = static_cast<ITextRangeProvider*>(this);
        }
        if (!*ppv) return E_NOINTERFACE;
        AddRef();
        return S_OK;
    }
    ULONG STDMETHODCALLTYPE AddRef() override { return (ULONG)InterlockedIncrement(&m_ref); }
    ULONG STDMETHODCALLTYPE Release() override {
        ULONG r = (ULONG)InterlockedDecrement(&m_ref);
        if (r == 0) delete this;
        return r;
    }

    // --- ITextRangeProvider ---
    HRESULT STDMETHODCALLTYPE Clone(ITextRangeProvider** pRetVal) override {
        if (!pRetVal) return E_POINTER;
        *pRetVal = new (std::nothrow) KxUiaTextRange(m_node, m_start, m_end);
        return *pRetVal ? S_OK : E_OUTOFMEMORY;
    }

    HRESULT STDMETHODCALLTYPE Compare(ITextRangeProvider* range, BOOL* pRetVal) override {
        if (!pRetVal) return E_POINTER;
        *pRetVal = FALSE;
        auto* other = dynamic_cast<KxUiaTextRange*>(range);
        if (!other) return E_INVALIDARG;
        *pRetVal = (other->m_node == m_node && other->m_start == m_start &&
                    other->m_end == m_end)
                       ? TRUE
                       : FALSE;
        return S_OK;
    }

    HRESULT STDMETHODCALLTYPE CompareEndpoints(TextPatternRangeEndpoint endpoint,
                                               ITextRangeProvider* targetRange,
                                               TextPatternRangeEndpoint targetEndpoint,
                                               int* pRetVal) override {
        if (!pRetVal) return E_POINTER;
        auto* other = dynamic_cast<KxUiaTextRange*>(targetRange);
        if (!other || other->m_node != m_node) return E_INVALIDARG;
        const int mine = (endpoint == TextPatternRangeEndpoint_Start) ? m_start : m_end;
        const int theirs =
            (targetEndpoint == TextPatternRangeEndpoint_Start) ? other->m_start : other->m_end;
        *pRetVal = mine - theirs;
        return S_OK;
    }

    HRESULT STDMETHODCALLTYPE ExpandToEnclosingUnit(TextUnit unit) override {
        const std::wstring text = docText();
        const int len = (int)text.size();
        clampEnds(len);
        switch (unit) {
            case TextUnit_Character:
                if (m_start == m_end && m_start < len) m_end = m_start + 1;
                break;
            case TextUnit_Word:
                m_start = scanBack(text, m_start, true);
                m_end = scanFwd(text, m_end, true);
                break;
            case TextUnit_Line:
            case TextUnit_Paragraph:
                m_start = scanBack(text, m_start, false);
                m_end = scanFwd(text, m_end, false);
                break;
            default: // Format, Page, Document → the whole text
                m_start = 0;
                m_end = len;
                break;
        }
        return S_OK;
    }

    HRESULT STDMETHODCALLTYPE FindAttribute(int attributeId, VARIANT val, BOOL backward,
                                            ITextRangeProvider** pRetVal) override {
        (void)attributeId;
        (void)val;
        (void)backward;
        if (!pRetVal) return E_POINTER;
        // No attributes supported — per contract a degenerate range answers
        // "not found".
        return cloneAt(m_start, m_start, pRetVal);
    }

    HRESULT STDMETHODCALLTYPE FindText(BSTR text, BOOL backward, BOOL ignoreCase,
                                       ITextRangeProvider** pRetVal) override {
        if (!pRetVal) return E_POINTER;
        *pRetVal = nullptr;
        const std::wstring doc = docText();
        const std::wstring needle =
            text ? std::wstring(text, SysStringLen(text)) : std::wstring();
        const int found = findTextIn(doc, needle, backward == TRUE, ignoreCase == TRUE);
        if (found < 0) return cloneAt(m_start, m_start, pRetVal); // degenerate = not found
        return cloneAt(found, found + (int)needle.size(), pRetVal);
    }

    HRESULT STDMETHODCALLTYPE GetAttributeValue(int attributeId, VARIANT* pRetVal) override {
        (void)attributeId;
        if (!pRetVal) return E_POINTER;
        VariantInit(pRetVal);
        // Documented sentinel for "attribute not supported".
        IUnknown* unk = nullptr;
        if (SUCCEEDED(UiaGetReservedNotSupportedValue(&unk)) && unk) {
            pRetVal->vt = VT_UNKNOWN;
            pRetVal->punkVal = unk;
        }
        return S_OK;
    }

    HRESULT STDMETHODCALLTYPE GetBoundingRectangles(SAFEARRAY** pRetVal) override {
        if (!pRetVal) return E_POINTER;
        *pRetVal = nullptr;
        UiaRect r{ 0, 0, 0, 0 };
        KxA11yNode n;
        if (snapshotCopy(m_node, &n)) r = screenRect(n);
        SAFEARRAY* sa = SafeArrayCreateVector(VT_R8, 0, 4);
        if (!sa) return E_OUTOFMEMORY;
        const double vals[4] = { r.left, r.top, r.width, r.height };
        for (LONG i = 0; i < 4; i++) SafeArrayPutElement(sa, &i, (void*)&vals[i]);
        *pRetVal = sa;
        return S_OK;
    }

    HRESULT STDMETHODCALLTYPE GetEnclosingElement(IRawElementProviderSimple** pRetVal) override;
    // (defined below, needs KxUiaNodeProvider)

    HRESULT STDMETHODCALLTYPE GetText(int maxLength, BSTR* pRetVal) override {
        if (!pRetVal) return E_POINTER;
        *pRetVal = nullptr;
        const std::wstring text = docText();
        const int len = (int)text.size();
        clampEnds(len);
        int want = m_end - m_start;
        if (maxLength >= 0 && maxLength < want) want = maxLength;
        if (want < 0) want = 0;
        *pRetVal = SysAllocStringLen(text.data() + m_start, (UINT)want);
        return S_OK;
    }

    HRESULT STDMETHODCALLTYPE Move(TextUnit unit, int count, int* pRetVal) override {
        if (!pRetVal) return E_POINTER;
        const std::wstring text = docText();
        clampEnds((int)text.size());
        if (count == 0) {
            *pRetVal = 0;
            return S_OK;
        }
        // Collapse to the leading edge, then walk it by whole units
        // (caret-style Move; the result is a degenerate range).
        int pos = (count < 0) ? m_start : m_end;
        int moved = 0;
        while (moved != count) {
            const int next = stepUnit(text, pos, unit, count > 0 ? 1 : -1);
            if (next == pos) break;
            pos = next;
            moved += (count > 0 ? 1 : -1);
        }
        m_start = m_end = pos;
        *pRetVal = moved;
        return S_OK;
    }

    HRESULT STDMETHODCALLTYPE MoveEndpointByUnit(TextPatternRangeEndpoint endpoint, TextUnit unit,
                                                 int count, int* pRetVal) override {
        if (!pRetVal) return E_POINTER;
        const std::wstring text = docText();
        clampEnds((int)text.size());
        int pos = (endpoint == TextPatternRangeEndpoint_Start) ? m_start : m_end;
        int moved = 0;
        while (moved != count) {
            const int next = stepUnit(text, pos, unit, count > 0 ? 1 : -1);
            if (next == pos) break;
            pos = next;
            moved += (count > 0 ? 1 : -1);
        }
        if (endpoint == TextPatternRangeEndpoint_Start)
            m_start = pos;
        else
            m_end = pos;
        if (m_start > m_end) { // endpoints may not cross
            if (endpoint == TextPatternRangeEndpoint_Start)
                m_start = m_end;
            else
                m_end = m_start;
        }
        *pRetVal = moved;
        return S_OK;
    }

    HRESULT STDMETHODCALLTYPE MoveEndpointByRange(TextPatternRangeEndpoint endpoint,
                                                  ITextRangeProvider* targetRange,
                                                  TextPatternRangeEndpoint targetEndpoint) override {
        auto* other = dynamic_cast<KxUiaTextRange*>(targetRange);
        if (!other || other->m_node != m_node) return E_INVALIDARG;
        const int theirs =
            (targetEndpoint == TextPatternRangeEndpoint_Start) ? other->m_start : other->m_end;
        if (endpoint == TextPatternRangeEndpoint_Start)
            m_start = theirs;
        else
            m_end = theirs;
        if (m_start > m_end) { // endpoints may not cross
            if (endpoint == TextPatternRangeEndpoint_Start)
                m_start = m_end;
            else
                m_end = m_start;
        }
        return S_OK;
    }

    HRESULT STDMETHODCALLTYPE Select() override {
        postAction(KX_A11Y_DO_FOCUS, m_node);
        return S_OK;
    }
    HRESULT STDMETHODCALLTYPE AddToSelection() override {
        postAction(KX_A11Y_DO_FOCUS, m_node); // single-selection documents
        return S_OK;
    }
    HRESULT STDMETHODCALLTYPE RemoveFromSelection() override {
        return UIA_E_INVALIDOPERATION;
    }
    HRESULT STDMETHODCALLTYPE ScrollIntoView(BOOL alignToTop) override {
        (void)alignToTop; // everything renders in the window already
        return S_OK;
    }
    HRESULT STDMETHODCALLTYPE GetChildren(SAFEARRAY** pRetVal) override {
        if (!pRetVal) return E_POINTER;
        *pRetVal = SafeArrayCreateVector(VT_UNKNOWN, 0, 0); // no embedded elements
        return *pRetVal ? S_OK : E_OUTOFMEMORY;
    }

private:
    LONG m_ref;
    uint64_t m_node;
    int m_start, m_end;

    std::wstring docText() const {
        KxA11yNode n;
        if (!snapshotCopy(m_node, &n)) return std::wstring();
        const std::string utf8 = docTextOf(n);
        return wstrFromUtf8(utf8.data(), utf8.size());
    }
    void clampEnds(int len) {
        if (m_start < 0) m_start = 0;
        if (m_end < 0) m_end = 0;
        if (m_start > len) m_start = len;
        if (m_end > len) m_end = len;
        if (m_start > m_end) m_start = m_end;
    }
    static bool isWordBreak(wchar_t c) { return iswspace(c) != 0; }
    // Expand helpers: scan to a word boundary (whitespace) or a hard break
    // ('\n' for line/paragraph).
    static int scanBack(const std::wstring& t, int pos, bool word) {
        while (pos > 0 && !(word ? isWordBreak(t[pos - 1]) : t[pos - 1] == L'\n')) pos--;
        return pos;
    }
    static int scanFwd(const std::wstring& t, int pos, bool word) {
        const int len = (int)t.size();
        while (pos < len && !(word ? isWordBreak(t[pos]) : t[pos] == L'\n')) pos++;
        return pos;
    }
    // One step of `unit` in `dir` from `pos`.
    static int stepUnit(const std::wstring& t, int pos, TextUnit unit, int dir) {
        const int len = (int)t.size();
        switch (unit) {
            case TextUnit_Character: {
                const int next = pos + dir;
                return next < 0 ? 0 : (next > len ? len : next);
            }
            case TextUnit_Word: {
                int p = pos;
                if (dir > 0) {
                    while (p < len && !isWordBreak(t[p])) p++;
                    while (p < len && isWordBreak(t[p])) p++;
                } else {
                    while (p > 0 && isWordBreak(t[p - 1])) p--;
                    while (p > 0 && !isWordBreak(t[p - 1])) p--;
                }
                return p;
            }
            case TextUnit_Line:
            case TextUnit_Paragraph: {
                int p = pos;
                if (dir > 0) {
                    while (p < len && t[p] != L'\n') p++;
                    if (p < len) p++; // consume the break
                } else {
                    if (p > 0 && t[p - 1] == L'\n') p--; // step over the break first
                    while (p > 0 && t[p - 1] != L'\n') p--;
                }
                return p;
            }
            default: // Format/Page/Document behave like Document
                return dir > 0 ? len : 0;
        }
    }
    static int findTextIn(const std::wstring& doc, const std::wstring& needle, bool backward,
                          bool ignoreCase) {
        if (needle.empty()) return 0;
        const int dlen = (int)doc.size(), nlen = (int)needle.size();
        if (nlen > dlen) return -1;
        const int first = backward ? dlen - nlen : 0;
        const int last = backward ? -1 : dlen - nlen + 1;
        const int step = backward ? -1 : 1;
        for (int i = first; i != last; i += step) {
            bool ok = true;
            for (int j = 0; j < nlen; j++) {
                const wchar_t a = doc[i + j], b = needle[j];
                if (ignoreCase ? (towlower(a) != towlower(b)) : (a != b)) {
                    ok = false;
                    break;
                }
            }
            if (ok) return i;
        }
        return -1;
    }
    HRESULT cloneAt(int start, int end, ITextRangeProvider** pRetVal) {
        *pRetVal = new (std::nothrow) KxUiaTextRange(m_node, start, end);
        return *pRetVal ? S_OK : E_OUTOFMEMORY;
    }
};

// --- KxUiaNodeProvider: one semantic node ---
// Implements every pattern the bridge supports; QueryInterface and
// GetPatternProvider filter by role so clients only see applicable
// interfaces. Node state is resolved live from the snapshot — a tree
// rebuild refreshes this provider's data in place.
class KxUiaNodeProvider final : public IRawElementProviderSimple,
                                public IRawElementProviderFragment
                                KX_UIA_PROVIDER_BASE,
                                public IInvokeProvider,
                                public IToggleProvider,
                                public IValueProvider,
                                public ISelectionItemProvider,
                                public ITextProvider {
public:
    explicit KxUiaNodeProvider(uint64_t ptr) : m_ref(1), m_ptr(ptr) {}

    uint64_t nodePtr() const { return m_ptr; }

    // --- IUnknown ---
    HRESULT STDMETHODCALLTYPE QueryInterface(REFIID riid, void** ppv) override {
        if (!ppv) return E_POINTER;
        *ppv = nullptr;
        if (riid == __uuidof(IUnknown) || riid == __uuidof(IRawElementProviderSimple)) {
            *ppv = static_cast<IRawElementProviderSimple*>(this); // canonical IUnknown
#if KX_UIA_HAS_UNKNOWN
        } else if (riid == __uuidof(IRawElementProviderUnknown)) {
            *ppv = static_cast<KX_UIA_PROVIDER_ARG*>(this);
#endif
        } else if (riid == __uuidof(IRawElementProviderFragment)) {
            *ppv = static_cast<IRawElementProviderFragment*>(this);
        } else if (riid == __uuidof(IInvokeProvider) && hasRole(isInvokeRole)) {
            *ppv = static_cast<IInvokeProvider*>(this);
        } else if (riid == __uuidof(IToggleProvider) && hasRole(isToggleRole)) {
            *ppv = static_cast<IToggleProvider*>(this);
        } else if (riid == __uuidof(IValueProvider) && hasRole(isValueRole)) {
            *ppv = static_cast<IValueProvider*>(this);
        } else if (riid == __uuidof(ISelectionItemProvider) && hasRole(isSelectionItemRole)) {
            *ppv = static_cast<ISelectionItemProvider*>(this);
        } else if (riid == __uuidof(ITextProvider) && hasRole(isTextRole)) {
            *ppv = static_cast<ITextProvider*>(this);
        }
        if (!*ppv) return E_NOINTERFACE;
        AddRef();
        return S_OK;
    }
    ULONG STDMETHODCALLTYPE AddRef() override { return (ULONG)InterlockedIncrement(&m_ref); }
    ULONG STDMETHODCALLTYPE Release() override {
        ULONG r = (ULONG)InterlockedDecrement(&m_ref);
        if (r == 0) delete this;
        return r;
    }

    // --- IRawElementProviderSimple ---
    HRESULT STDMETHODCALLTYPE get_ProviderOptions(ProviderOptions* pRetVal) override {
        if (!pRetVal) return E_POINTER;
        *pRetVal = (ProviderOptions)(ProviderOptions_ServerSideProvider |
                                     ProviderOptions_UseComThreading |
                                     ProviderOptions_ProviderOwnsSetFocus);
        return S_OK;
    }

    HRESULT STDMETHODCALLTYPE GetPatternProvider(PATTERNID patternId, IUnknown** pRetVal) override {
        if (!pRetVal) return E_POINTER;
        *pRetVal = nullptr;
        bool match = false;
        if (patternId == UIA_InvokePatternId && hasRole(isInvokeRole))
            match = true;
        else if (patternId == UIA_TogglePatternId && hasRole(isToggleRole))
            match = true;
        else if (patternId == UIA_ValuePatternId && hasRole(isValueRole))
            match = true;
        else if (patternId == UIA_SelectionItemPatternId && hasRole(isSelectionItemRole))
            match = true;
        else if (patternId == UIA_TextPatternId && hasRole(isTextRole))
            match = true;
        if (!match) return S_OK;
        AddRef(); // patterns are implemented on this same object
        *pRetVal = static_cast<IUnknown*>(static_cast<IRawElementProviderSimple*>(this));
        return S_OK;
    }

    HRESULT STDMETHODCALLTYPE GetPropertyValue(PROPERTYID propertyId, VARIANT* pRetVal) override {
        if (!pRetVal) return E_POINTER;
        VariantInit(pRetVal); // VT_EMPTY = "not supported"
        KxA11yNode n;
        if (!snapshotCopy(m_ptr, &n)) return UIA_E_ELEMENTNOTAVAILABLE;
        switch (propertyId) {
            case UIA_ControlTypePropertyId:
                pRetVal->vt = VT_I4;
                pRetVal->lVal = controlTypeOf(n.role);
                break;
            case UIA_NamePropertyId:
                pRetVal->vt = VT_BSTR;
                pRetVal->bstrVal = bstrFromUtf8(n.label.empty() ? n.value : n.label);
                break;
            case UIA_AutomationIdPropertyId: {
                char buf[24];
                const int blen = snprintf(buf, sizeof(buf), "kx-%llu", (unsigned long long)n.ptr);
                const int wlen =
                    MultiByteToWideChar(CP_UTF8, 0, buf, blen > 0 ? blen : 0, nullptr, 0);
                BSTR b = SysAllocStringLen(nullptr, wlen > 0 ? (UINT)wlen : 0);
                if (b && wlen > 0) MultiByteToWideChar(CP_UTF8, 0, buf, blen, b, wlen);
                pRetVal->vt = VT_BSTR;
                pRetVal->bstrVal = b;
                break;
            }
            case UIA_ClassNamePropertyId:
                pRetVal->vt = VT_BSTR;
                pRetVal->bstrVal = bstrFromUtf8(n.role);
                break;
            case UIA_IsKeyboardFocusablePropertyId:
                pRetVal->vt = VT_BOOL;
                pRetVal->boolVal = n.focusable ? VARIANT_TRUE : VARIANT_FALSE;
                break;
            case UIA_HasKeyboardFocusPropertyId:
                pRetVal->vt = VT_BOOL;
                pRetVal->boolVal = isFocused() ? VARIANT_TRUE : VARIANT_FALSE;
                break;
            case UIA_IsEnabledPropertyId:
            case UIA_IsContentElementPropertyId:
            case UIA_IsControlElementPropertyId:
                pRetVal->vt = VT_BOOL;
                pRetVal->boolVal = VARIANT_TRUE;
                break;
            case UIA_IsOffscreenPropertyId:
                pRetVal->vt = VT_BOOL;
                pRetVal->boolVal = VARIANT_FALSE;
                break;
            case UIA_BoundingRectanglePropertyId: {
                const UiaRect r = screenRect(n);
                SAFEARRAY* sa = SafeArrayCreateVector(VT_R8, 0, 4);
                if (!sa) return E_OUTOFMEMORY;
                const double vals[4] = { r.left, r.top, r.width, r.height };
                for (LONG i = 0; i < 4; i++) SafeArrayPutElement(sa, &i, (void*)&vals[i]);
                pRetVal->vt = VT_ARRAY | VT_R8;
                pRetVal->parray = sa;
                break;
            }
            case UIA_ToggleToggleStatePropertyId:
                if (isToggleRole(n.role) && n.checked != 0) {
                    pRetVal->vt = VT_I4;
                    pRetVal->lVal = kxToggleState(n.checked);
                }
                break;
            case UIA_ValueValuePropertyId:
                if (isValueRole(n.role)) {
                    pRetVal->vt = VT_BSTR;
                    pRetVal->bstrVal = bstrFromUtf8(n.value);
                }
                break;
            case UIA_PositionInSetPropertyId:
            case UIA_SizeOfSetPropertyId: {
                int pos = 0, total = 0;
                if (setInfo(n, &pos, &total)) {
                    const int v = (propertyId == UIA_PositionInSetPropertyId) ? pos : total;
                    if (v > 0) {
                        pRetVal->vt = VT_I4;
                        pRetVal->lVal = v;
                    }
                }
                break;
            }
            case UIA_HeadingLevelPropertyId:
                if (n.role == "heading") {
                    pRetVal->vt = VT_I4;
                    pRetVal->lVal = 1;
                }
                break;
            default:
                break;
        }
        return S_OK;
    }

    HRESULT STDMETHODCALLTYPE get_HostRawElementProvider(
        IRawElementProviderSimple** pRetVal) override {
        if (!pRetVal) return E_POINTER;
        *pRetVal = nullptr; // only the fragment root reports a host provider
        return S_OK;
    }

    // --- IRawElementProviderFragment ---
    // (Navigate / get_FragmentRoot defined below — they need KxUiaRootProvider
    // and the provider map.)
    HRESULT STDMETHODCALLTYPE Navigate(NavigateDirection direction,
                                       IRawElementProviderFragment** pRetVal) override;

    HRESULT STDMETHODCALLTYPE GetRuntimeId(SAFEARRAY** pRetVal) override {
        if (!pRetVal) return E_POINTER;
        *pRetVal = nullptr;
        SAFEARRAY* sa = SafeArrayCreateVector(VT_I4, 0, 3);
        if (!sa) return E_OUTOFMEMORY;
        // UiaAppendRuntimeId scopes this id under the HWND provider's own
        // runtime id; the two trailing ints make it unique per node.
        const int rid[3] = { UiaAppendRuntimeId, (int)(m_ptr & 0xFFFFFFFFu), (int)(m_ptr >> 32) };
        for (LONG i = 0; i < 3; i++) SafeArrayPutElement(sa, &i, (void*)&rid[i]);
        *pRetVal = sa;
        return S_OK;
    }

    HRESULT STDMETHODCALLTYPE get_BoundingRectangle(UiaRect* pRetVal) override {
        if (!pRetVal) return E_POINTER;
        KxA11yNode n;
        if (!snapshotCopy(m_ptr, &n)) return UIA_E_ELEMENTNOTAVAILABLE;
        *pRetVal = screenRect(n);
        return S_OK;
    }

    HRESULT STDMETHODCALLTYPE GetEmbeddedFragmentRoots(SAFEARRAY** pRetVal) override {
        if (!pRetVal) return E_POINTER;
        *pRetVal = nullptr;
        return S_OK;
    }

    HRESULT STDMETHODCALLTYPE SetFocus() override {
        postAction(KX_A11Y_DO_FOCUS, m_ptr);
        return S_OK;
    }

    HRESULT STDMETHODCALLTYPE get_FragmentRoot(IRawElementProviderFragmentRoot** pRetVal) override;

    // --- IInvokeProvider ---
    HRESULT STDMETHODCALLTYPE Invoke() override {
        if (!alive()) return UIA_E_ELEMENTNOTAVAILABLE;
        postAction(KX_A11Y_DO_ACTIVATE, m_ptr); // a real click through the input router
        return S_OK;
    }

    // --- IToggleProvider ---
    HRESULT STDMETHODCALLTYPE Toggle() override {
        if (!alive()) return UIA_E_ELEMENTNOTAVAILABLE;
        postAction(KX_A11Y_DO_ACTIVATE, m_ptr); // activating the control toggles it
        return S_OK;
    }

    HRESULT STDMETHODCALLTYPE get_ToggleState(ToggleState* pRetVal) override {
        if (!pRetVal) return E_POINTER;
        KxA11yNode n;
        if (!snapshotCopy(m_ptr, &n)) return UIA_E_ELEMENTNOTAVAILABLE;
        *pRetVal = (ToggleState)kxToggleState(n.checked);
        return S_OK;
    }

    // --- IValueProvider ---
    // v1 is read-only: no ABI exists yet for writing a value back into the
    // Zig widget (SetValue fails and IsReadOnly reports TRUE).
    HRESULT STDMETHODCALLTYPE SetValue(LPCWSTR val) override {
        (void)val;
        return E_FAIL;
    }
    HRESULT STDMETHODCALLTYPE get_Value(BSTR* pRetVal) override {
        if (!pRetVal) return E_POINTER;
        *pRetVal = nullptr;
        KxA11yNode n;
        if (!snapshotCopy(m_ptr, &n)) return UIA_E_ELEMENTNOTAVAILABLE;
        *pRetVal = bstrFromUtf8(n.value);
        return S_OK;
    }
    HRESULT STDMETHODCALLTYPE get_IsReadOnly(BOOL* pRetVal) override {
        if (!pRetVal) return E_POINTER;
        *pRetVal = TRUE;
        return S_OK;
    }

    // --- ISelectionItemProvider ---
    HRESULT STDMETHODCALLTYPE Select() override {
        if (!alive()) return UIA_E_ELEMENTNOTAVAILABLE;
        // A synthesized click both focuses and selects (radio/tab/list item).
        postAction(KX_A11Y_DO_ACTIVATE, m_ptr);
        return S_OK;
    }
    HRESULT STDMETHODCALLTYPE AddToSelection() override {
        // Klaxon's containers are single-select — additive selection is not
        // meaningful here.
        return UIA_E_INVALIDOPERATION;
    }
    HRESULT STDMETHODCALLTYPE RemoveFromSelection() override { return UIA_E_INVALIDOPERATION; }
    HRESULT STDMETHODCALLTYPE get_IsSelected(BOOL* pRetVal) override {
        if (!pRetVal) return E_POINTER;
        *pRetVal = FALSE;
        KxA11yNode n;
        if (!snapshotCopy(m_ptr, &n)) return UIA_E_ELEMENTNOTAVAILABLE;
        *pRetVal = (n.checked == 2 || isFocused()) ? TRUE : FALSE;
        return S_OK;
    }
    HRESULT STDMETHODCALLTYPE get_SelectionContainer(IRawElementProviderSimple** pRetVal) override;

    // --- ITextProvider ---
    HRESULT STDMETHODCALLTYPE GetSelection(SAFEARRAY** pRetVal) override {
        if (!pRetVal) return E_POINTER;
        *pRetVal = nullptr;
        // Single-selection documents: report a degenerate caret range.
        KxUiaTextRange* r = new (std::nothrow) KxUiaTextRange(m_ptr, 0, 0);
        if (!r) return E_OUTOFMEMORY;
        return putRangesInArray(r, pRetVal);
    }
    HRESULT STDMETHODCALLTYPE GetVisibleRanges(SAFEARRAY** pRetVal) override {
        if (!pRetVal) return E_POINTER;
        *pRetVal = nullptr;
        // Everything is on-screen: one range spanning the document.
        KxUiaTextRange* r = docRange();
        if (!r) return E_OUTOFMEMORY;
        return putRangesInArray(r, pRetVal);
    }
    HRESULT STDMETHODCALLTYPE RangeFromChild(IRawElementProviderSimple* childElement,
                                             ITextRangeProvider** pRetVal) override {
        if (!pRetVal) return E_POINTER;
        *pRetVal = nullptr;
        // Our text nodes have no embedded children.
        if (childElement != static_cast<IRawElementProviderSimple*>(this)) return S_OK;
        *pRetVal = docRange();
        return *pRetVal ? S_OK : E_OUTOFMEMORY;
    }
    HRESULT STDMETHODCALLTYPE RangeFromPoint(UiaPoint point, ITextRangeProvider** pRetVal) override {
        (void)point;
        if (!pRetVal) return E_POINTER;
        // Single-rect document: the doc range answers any point inside.
        *pRetVal = docRange();
        return *pRetVal ? S_OK : E_OUTOFMEMORY;
    }
    HRESULT STDMETHODCALLTYPE get_DocumentRange(ITextRangeProvider** pRetVal) override {
        if (!pRetVal) return E_POINTER;
        *pRetVal = docRange();
        return *pRetVal ? S_OK : E_OUTOFMEMORY;
    }
    HRESULT STDMETHODCALLTYPE get_SupportedTextSelection(SupportedTextSelection* pRetVal) override {
        if (!pRetVal) return E_POINTER;
        *pRetVal = SupportedTextSelection_Single;
        return S_OK;
    }

private:
    LONG m_ref;
    uint64_t m_ptr;

    bool alive() const {
        std::lock_guard<std::mutex> lock(g_mutex);
        return g_index.find(m_ptr) != g_index.end();
    }
    bool isFocused() const {
        std::lock_guard<std::mutex> lock(g_mutex);
        return g_focused_ptr == m_ptr;
    }
    bool hasRole(bool (*pred)(const std::string&)) const {
        std::lock_guard<std::mutex> lock(g_mutex);
        auto it = g_index.find(m_ptr);
        if (it == g_index.end()) return false;
        return pred(g_nodes[(size_t)it->second].role);
    }
    // PositionInSet/SizeOfSet: this node's 1-based index among its siblings.
    bool setInfo(const KxA11yNode& n, int* pos, int* total) {
        *pos = 0;
        *total = 0;
        if (n.parent < 0) return false;
        std::lock_guard<std::mutex> lock(g_mutex);
        if ((size_t)n.parent >= g_nodes.size()) return false;
        auto it = g_index.find(m_ptr);
        if (it == g_index.end()) return false;
        const int me = it->second;
        const auto& siblings = g_nodes[(size_t)n.parent].children;
        *total = (int)siblings.size();
        for (size_t i = 0; i < siblings.size(); i++) {
            if (siblings[i] == me) {
                *pos = (int)i + 1;
                break;
            }
        }
        return *pos > 0;
    }
    KxUiaTextRange* docRange() {
        KxA11yNode n;
        int len = 0;
        if (snapshotCopy(m_ptr, &n)) {
            const std::string utf8 = docTextOf(n);
            len = (int)wstrFromUtf8(utf8.data(), utf8.size()).size();
        }
        return new (std::nothrow) KxUiaTextRange(m_ptr, 0, len);
    }
    // Wrap a single range in a SAFEARRAY(VT_UNKNOWN). Takes ownership of r.
    static HRESULT putRangesInArray(KxUiaTextRange* r, SAFEARRAY** pRetVal) {
        SAFEARRAY* sa = SafeArrayCreateVector(VT_UNKNOWN, 0, 1);
        if (!sa) {
            r->Release();
            return E_OUTOFMEMORY;
        }
        LONG ix = 0;
        ITextRangeProvider* elem = r;
        const HRESULT hr = SafeArrayPutElement(sa, &ix, &elem); // AddRefs elem
        r->Release();
        if (FAILED(hr)) {
            SafeArrayDestroy(sa);
            return hr;
        }
        *pRetVal = sa;
        return S_OK;
    }
};

// --- KxUiaRootProvider: the window's fragment root ---
// Returned by WM_GETOBJECT (UiaReturnRawElementProvider). Owns the top-level
// semantic nodes as its children and bridges to the HWND host provider.
class KxUiaRootProvider final : public IRawElementProviderSimple,
                                public IRawElementProviderFragment,
                                public IRawElementProviderFragmentRoot
                                KX_UIA_PROVIDER_BASE {
public:
    KxUiaRootProvider() : m_ref(1) {}

    // --- IUnknown ---
    HRESULT STDMETHODCALLTYPE QueryInterface(REFIID riid, void** ppv) override {
        if (!ppv) return E_POINTER;
        *ppv = nullptr;
        if (riid == __uuidof(IUnknown) || riid == __uuidof(IRawElementProviderSimple)) {
            *ppv = static_cast<IRawElementProviderSimple*>(this); // canonical IUnknown
#if KX_UIA_HAS_UNKNOWN
        } else if (riid == __uuidof(IRawElementProviderUnknown)) {
            *ppv = static_cast<KX_UIA_PROVIDER_ARG*>(this);
#endif
        } else if (riid == __uuidof(IRawElementProviderFragment)) {
            *ppv = static_cast<IRawElementProviderFragment*>(this);
        } else if (riid == __uuidof(IRawElementProviderFragmentRoot)) {
            *ppv = static_cast<IRawElementProviderFragmentRoot*>(this);
        }
        if (!*ppv) return E_NOINTERFACE;
        AddRef();
        return S_OK;
    }
    ULONG STDMETHODCALLTYPE AddRef() override { return (ULONG)InterlockedIncrement(&m_ref); }
    ULONG STDMETHODCALLTYPE Release() override {
        ULONG r = (ULONG)InterlockedDecrement(&m_ref);
        if (r == 0) delete this;
        return r;
    }

    // --- IRawElementProviderSimple ---
    HRESULT STDMETHODCALLTYPE get_ProviderOptions(ProviderOptions* pRetVal) override {
        if (!pRetVal) return E_POINTER;
        *pRetVal = (ProviderOptions)(ProviderOptions_ServerSideProvider |
                                     ProviderOptions_UseComThreading);
        return S_OK;
    }
    HRESULT STDMETHODCALLTYPE GetPatternProvider(PATTERNID patternId, IUnknown** pRetVal) override {
        (void)patternId;
        if (!pRetVal) return E_POINTER;
        *pRetVal = nullptr;
        return S_OK;
    }
    HRESULT STDMETHODCALLTYPE GetPropertyValue(PROPERTYID propertyId, VARIANT* pRetVal) override {
        if (!pRetVal) return E_POINTER;
        VariantInit(pRetVal);
        switch (propertyId) {
            case UIA_ControlTypePropertyId:
                pRetVal->vt = VT_I4;
                pRetVal->lVal = UIA_PaneControlTypeId; // the app content pane
                break;
            case UIA_NamePropertyId:
                pRetVal->vt = VT_BSTR;
                pRetVal->bstrVal = windowTitle();
                break;
            case UIA_AutomationIdPropertyId:
                pRetVal->vt = VT_BSTR;
                pRetVal->bstrVal = SysAllocString(L"klaxon.root");
                break;
            case UIA_ClassNamePropertyId:
                pRetVal->vt = VT_BSTR;
                pRetVal->bstrVal = SysAllocString(L"Klaxon");
                break;
            case UIA_IsKeyboardFocusablePropertyId:
            case UIA_IsEnabledPropertyId:
            case UIA_IsContentElementPropertyId:
            case UIA_IsControlElementPropertyId:
                pRetVal->vt = VT_BOOL;
                pRetVal->boolVal = VARIANT_TRUE;
                break;
            case UIA_HasKeyboardFocusPropertyId:
            case UIA_IsOffscreenPropertyId:
                pRetVal->vt = VT_BOOL;
                pRetVal->boolVal = VARIANT_FALSE;
                break;
            case UIA_BoundingRectanglePropertyId: {
                const UiaRect r = windowRect();
                SAFEARRAY* sa = SafeArrayCreateVector(VT_R8, 0, 4);
                if (!sa) return E_OUTOFMEMORY;
                const double vals[4] = { r.left, r.top, r.width, r.height };
                for (LONG i = 0; i < 4; i++) SafeArrayPutElement(sa, &i, (void*)&vals[i]);
                pRetVal->vt = VT_ARRAY | VT_R8;
                pRetVal->parray = sa;
                break;
            }
            default:
                break;
        }
        return S_OK;
    }
    HRESULT STDMETHODCALLTYPE get_HostRawElementProvider(
        IRawElementProviderSimple** pRetVal) override {
        if (!pRetVal) return E_POINTER;
        *pRetVal = nullptr;
        if (!g_hwnd) return S_OK;
        // Links our fragment root under the HWND's default provider so
        // clients can navigate window chrome → content.
        return UiaHostProviderFromHwnd(g_hwnd, pRetVal);
    }

    // --- IRawElementProviderFragment ---
    HRESULT STDMETHODCALLTYPE Navigate(NavigateDirection direction,
                                       IRawElementProviderFragment** pRetVal) override {
        if (!pRetVal) return E_POINTER;
        *pRetVal = nullptr;
        // Parent/NextSibling/PreviousSibling on the fragment root: NULL (the
        // host provider reachable via get_HostRawElementProvider covers it).
        if (direction != NavigateDirection_FirstChild && direction != NavigateDirection_LastChild)
            return S_OK;
        std::lock_guard<std::mutex> lock(g_mutex);
        int idx = -1;
        if (direction == NavigateDirection_FirstChild) {
            for (size_t i = 0; i < g_nodes.size(); i++)
                if (g_nodes[i].parent < 0) {
                    idx = (int)i;
                    break;
                }
        } else {
            for (size_t i = g_nodes.size(); i-- > 0;)
                if (g_nodes[i].parent < 0) {
                    idx = (int)i;
                    break;
                }
        }
        return idx >= 0 ? providerFragmentForLocked(idx, pRetVal) : S_OK;
    }
    HRESULT STDMETHODCALLTYPE GetRuntimeId(SAFEARRAY** pRetVal) override {
        if (!pRetVal) return E_POINTER;
        *pRetVal = nullptr; // inherit the HWND provider's runtime id
        return S_OK;
    }
    HRESULT STDMETHODCALLTYPE get_BoundingRectangle(UiaRect* pRetVal) override {
        if (!pRetVal) return E_POINTER;
        *pRetVal = windowRect();
        return S_OK;
    }
    HRESULT STDMETHODCALLTYPE GetEmbeddedFragmentRoots(SAFEARRAY** pRetVal) override {
        if (!pRetVal) return E_POINTER;
        *pRetVal = nullptr;
        return S_OK;
    }
    HRESULT STDMETHODCALLTYPE SetFocus() override {
        return S_OK; // the window itself; node focus goes through fragments
    }
    HRESULT STDMETHODCALLTYPE get_FragmentRoot(IRawElementProviderFragmentRoot** pRetVal) override {
        if (!pRetVal) return E_POINTER;
        *pRetVal = this;
        AddRef();
        return S_OK;
    }

    // --- IRawElementProviderFragmentRoot ---
    HRESULT STDMETHODCALLTYPE ElementProviderFromPoint(
        double x, double y, IRawElementProviderFragment** pRetVal) override {
        if (!pRetVal) return E_POINTER;
        *pRetVal = nullptr;
        // Screen → client coordinates, then deepest hit wins (front-most in
        // DFS order: later siblings paint over earlier ones).
        POINT pt{ (LONG)x, (LONG)y };
        if (g_hwnd) ScreenToClient(g_hwnd, &pt);
        {
            std::lock_guard<std::mutex> lock(g_mutex);
            int best = -1, best_depth = -1;
            for (size_t i = 0; i < g_nodes.size(); i++) {
                const KxA11yNode& n = g_nodes[i];
                if (n.w <= 0 || n.h <= 0) continue;
                if (pt.x >= n.x && pt.x < n.x + n.w && pt.y >= n.y && pt.y < n.y + n.h &&
                    n.depth >= best_depth) {
                    best_depth = n.depth;
                    best = (int)i;
                }
            }
            if (best >= 0) return providerFragmentForLocked(best, pRetVal);
        }
        // Nothing hit: return the root itself while inside the window.
        const UiaRect r = windowRect();
        if (x >= r.left && x < r.left + r.width && y >= r.top && y < r.top + r.height) {
            *pRetVal = static_cast<IRawElementProviderFragment*>(this);
            AddRef();
        }
        return S_OK;
    }
    HRESULT STDMETHODCALLTYPE GetFocus(IRawElementProviderFragment** pRetVal) override {
        if (!pRetVal) return E_POINTER;
        *pRetVal = nullptr;
        std::lock_guard<std::mutex> lock(g_mutex);
        if (g_focused_ptr) {
            auto it = g_index.find(g_focused_ptr);
            if (it != g_index.end()) return providerFragmentForLocked(it->second, pRetVal);
        }
        return S_OK;
    }

private:
    LONG m_ref;

    static UiaRect windowRect() {
        UiaRect r{ 0, 0, 0, 0 };
        if (!g_hwnd) return r;
        RECT rc{};
        if (!GetClientRect(g_hwnd, &rc)) return r;
        POINT pt{ 0, 0 };
        ClientToScreen(g_hwnd, &pt);
        r.left = (double)pt.x;
        r.top = (double)pt.y;
        r.width = (double)(rc.right - rc.left);
        r.height = (double)(rc.bottom - rc.top);
        return r;
    }
    static BSTR windowTitle() {
        wchar_t buf[256];
        buf[0] = L'\0';
        if (g_hwnd) GetWindowTextW(g_hwnd, buf, (int)(sizeof(buf) / sizeof(buf[0])));
        if (!buf[0]) return SysAllocString(L"Klaxon");
        return SysAllocString(buf);
    }
};

// --- Provider map management (definitions of the earlier decls) ---

static KxUiaNodeProvider* providerFor(uint64_t ptr) {
    std::lock_guard<std::mutex> lock(g_mutex);
    auto it = g_providers.find(ptr);
    if (it != g_providers.end()) {
        it->second->AddRef();
        return it->second;
    }
    if (g_index.find(ptr) == g_index.end()) return nullptr; // stale node id
    KxUiaNodeProvider* p = new (std::nothrow) KxUiaNodeProvider(ptr);
    if (!p) return nullptr;
    g_providers[ptr] = p; // map holds one ref
    p->AddRef();          // one for the caller
    return p;
}

static IRawElementProviderSimple* rootSimpleRef() {
    // Read + AddRef under the mutex: shutdown nulls the pointer under the
    // same lock, so a racing provider call can never grab a dying root.
    std::lock_guard<std::mutex> lock(g_mutex);
    if (!g_root_provider) return nullptr;
    g_root_provider->AddRef();
    return static_cast<IRawElementProviderSimple*>(g_root_provider);
}

static HRESULT providerFragmentForLocked(int index, IRawElementProviderFragment** pRetVal) {
    *pRetVal = nullptr;
    if (index < 0 || (size_t)index >= g_nodes.size()) return S_OK;
    const uint64_t ptr = g_nodes[(size_t)index].ptr;
    auto it = g_providers.find(ptr);
    KxUiaNodeProvider* p = it != g_providers.end() ? it->second : nullptr;
    if (!p) {
        p = new (std::nothrow) KxUiaNodeProvider(ptr);
        if (!p) return E_OUTOFMEMORY;
        g_providers[ptr] = p; // map keeps one ref
    }
    p->AddRef(); // caller's ref
    *pRetVal = static_cast<IRawElementProviderFragment*>(p);
    return S_OK;
}

// --- Deferred out-of-class method bodies (need providerFor/root access) ---

HRESULT STDMETHODCALLTYPE KxUiaTextRange::GetEnclosingElement(IRawElementProviderSimple** pRetVal) {
    if (!pRetVal) return E_POINTER;
    *pRetVal = providerFor(m_node);
    return *pRetVal ? S_OK : UIA_E_ELEMENTNOTAVAILABLE;
}

HRESULT STDMETHODCALLTYPE KxUiaNodeProvider::Navigate(NavigateDirection direction,
                                                      IRawElementProviderFragment** pRetVal) {
    if (!pRetVal) return E_POINTER;
    *pRetVal = nullptr;
    std::lock_guard<std::mutex> lock(g_mutex);
    auto it = g_index.find(m_ptr);
    if (it == g_index.end()) return UIA_E_ELEMENTNOTAVAILABLE;
    const int me = it->second;
    const KxA11yNode& n = g_nodes[(size_t)me];
    if (direction == NavigateDirection_Parent && n.parent < 0) {
        // Top-level node's parent is the fragment root.
        if (g_root_provider) {
            g_root_provider->AddRef();
            *pRetVal = static_cast<IRawElementProviderFragment*>(g_root_provider);
        }
        return S_OK;
    }
    int target = -1;
    switch (direction) {
        case NavigateDirection_Parent:
            target = n.parent;
            break;
        case NavigateDirection_FirstChild:
            target = n.children.empty() ? -1 : n.children.front();
            break;
        case NavigateDirection_LastChild:
            target = n.children.empty() ? -1 : n.children.back();
            break;
        case NavigateDirection_NextSibling:
        case NavigateDirection_PreviousSibling:
            if (n.parent >= 0 && (size_t)n.parent < g_nodes.size()) {
                const auto& siblings = g_nodes[(size_t)n.parent].children;
                for (size_t i = 0; i < siblings.size(); i++) {
                    if (siblings[i] != me) continue;
                    const int j = (int)i + (direction == NavigateDirection_NextSibling ? 1 : -1);
                    if (j >= 0 && (size_t)j < siblings.size()) target = siblings[(size_t)j];
                    break;
                }
            }
            break;
        default:
            break;
    }
    if (target < 0) return S_OK;
    return providerFragmentForLocked(target, pRetVal);
}

HRESULT STDMETHODCALLTYPE KxUiaNodeProvider::get_FragmentRoot(
    IRawElementProviderFragmentRoot** pRetVal) {
    if (!pRetVal) return E_POINTER;
    *pRetVal = nullptr;
    std::lock_guard<std::mutex> lock(g_mutex);
    if (!g_root_provider) return S_OK;
    g_root_provider->AddRef();
    *pRetVal = static_cast<IRawElementProviderFragmentRoot*>(g_root_provider);
    return S_OK;
}

HRESULT STDMETHODCALLTYPE KxUiaNodeProvider::get_SelectionContainer(
    IRawElementProviderSimple** pRetVal) {
    if (!pRetVal) return E_POINTER;
    *pRetVal = nullptr;
    uint64_t parent_ptr = 0;
    {
        std::lock_guard<std::mutex> lock(g_mutex);
        auto it = g_index.find(m_ptr);
        if (it == g_index.end()) return UIA_E_ELEMENTNOTAVAILABLE;
        const int parent = g_nodes[(size_t)it->second].parent;
        if (parent >= 0) parent_ptr = g_nodes[(size_t)parent].ptr;
    }
    if (parent_ptr)
        *pRetVal = providerFor(parent_ptr);
    else
        *pRetVal = rootSimpleRef();
    return S_OK;
}

// --- Event helpers ---

// Snapshot swap on tree_dirty / control_changed: parse the dump, install it,
// then disconnect providers whose nodes vanished (UIA releases their remote
// references; our map ref drops here).
static void rebuildTree(std::vector<KxUiaNodeProvider*>* stale) {
    stale->clear();
    if (!g_zig_root_node) return;
    char* dump = kx_a11y_dump_tree(g_zig_root_node);
    if (!dump) return;
    std::vector<KxA11yNode> fresh = parseDump(dump);
    kx_a11y_free_string(dump);
    {
        std::lock_guard<std::mutex> lock(g_mutex);
        g_nodes = std::move(fresh);
        reindex();
        for (auto it = g_providers.begin(); it != g_providers.end();) {
            if (g_index.find(it->first) == g_index.end()) {
                stale->push_back(it->second); // carries the map's ref out
                it = g_providers.erase(it);
            } else {
                ++it;
            }
        }
    }
    for (KxUiaNodeProvider* p : *stale) {
        UiaDisconnectProvider(static_cast<KX_UIA_PROVIDER_ARG*>(p));
        p->Release(); // the map's ref; client refs die with the disconnect
    }
}

// UiaRaiseNotificationEvent exists only on Windows 10 RS3+ — resolve it at
// runtime so the binary still loads on older builds (uiautomationcore.lib is
// already on the link line for the other Uia* calls).
typedef HRESULT(WINAPI* UiaRaiseNotificationEventFn)(IRawElementProviderSimple*, NotificationKind,
                                                     NotificationProcessing, BSTR, BSTR);
static UiaRaiseNotificationEventFn raiseNotificationFn() {
    static UiaRaiseNotificationEventFn fn = [] {
        HMODULE m = GetModuleHandleW(L"uiautomationcore.dll");
        if (!m) m = LoadLibraryW(L"uiautomationcore.dll");
        return m ? (UiaRaiseNotificationEventFn)GetProcAddress(m, "UiaRaiseNotificationEvent")
                 : nullptr;
    }();
    return fn;
}

static VARIANT bstrVariant(const std::string& utf8) {
    VARIANT v;
    VariantInit(&v);
    v.vt = VT_BSTR;
    v.bstrVal = bstrFromUtf8(utf8);
    return v;
}

// Raise a property-changed event for owned VARIANTs (UIA marshals its own
// copies synchronously — callers VariantClear theirs).
static void raisePropertyChanged(IRawElementProviderSimple* target, PROPERTYID id,
                                 const VARIANT& oldV, const VARIANT& newV) {
    if (!target || !UiaClientsAreListening()) return;
    UiaRaiseAutomationPropertyChangedEvent(target, id, oldV, newV);
}

// --- Bridge event callback (called from Zig on the SDL thread) ---
static void a11yBridgeCallback(void* userdata, KxBridgeEventC ev) {
    (void)userdata;
    switch (ev.kind) {
        case KX_A11Y_TREE_DIRTY: {
            std::vector<KxUiaNodeProvider*> stale;
            rebuildTree(&stale);
            if (IRawElementProviderSimple* root = rootSimpleRef()) {
                if (UiaClientsAreListening())
                    UiaRaiseStructureChangedEvent(root, StructureChangeType_ChildrenInvalidated,
                                                  nullptr, 0);
                root->Release();
            }
            break;
        }
        case KX_A11Y_CONTROL_CHANGED: {
            // Same re-dump as the wasm mirror: one control's value/checked
            // flipped. Diff the node and raise property-change events for
            // what moved; the rebuild sweep keeps the provider set honest if
            // the structure also shifted.
            KxA11yNode before;
            const bool had_before = snapshotCopy(ev.node_id, &before);
            std::vector<KxUiaNodeProvider*> stale;
            rebuildTree(&stale);
            KxA11yNode after;
            if (!snapshotCopy(ev.node_id, &after)) break; // node vanished
            KxUiaNodeProvider* p = providerFor(ev.node_id);
            if (!p) break;
            IRawElementProviderSimple* simple = static_cast<IRawElementProviderSimple*>(p);
            if (!had_before || before.label != after.label) {
                VARIANT ov = bstrVariant(had_before ? before.label : std::string());
                VARIANT nv = bstrVariant(after.label);
                raisePropertyChanged(simple, UIA_NamePropertyId, ov, nv);
                VariantClear(&ov);
                VariantClear(&nv);
            }
            if (isValueRole(after.role) && (!had_before || before.value != after.value)) {
                VARIANT ov = bstrVariant(had_before ? before.value : std::string());
                VARIANT nv = bstrVariant(after.value);
                raisePropertyChanged(simple, UIA_ValueValuePropertyId, ov, nv);
                VariantClear(&ov);
                VariantClear(&nv);
            }
            if (isToggleRole(after.role) && (!had_before || before.checked != after.checked)) {
                VARIANT ov, nv;
                VariantInit(&ov);
                VariantInit(&nv);
                ov.vt = nv.vt = VT_I4;
                ov.lVal = had_before ? kxToggleState(before.checked) : ToggleState_Indeterminate;
                nv.lVal = kxToggleState(after.checked);
                raisePropertyChanged(simple, UIA_ToggleToggleStatePropertyId, ov, nv);
            }
            if (isSelectionItemRole(after.role) &&
                (!had_before || before.checked != after.checked) && after.checked == 2 &&
                UiaClientsAreListening()) {
                UiaRaiseAutomationEvent(simple, UIA_SelectionItem_ElementSelectedEventId);
            }
            p->Release();
            break;
        }
        case KX_A11Y_FOCUS_CHANGED: {
            {
                std::lock_guard<std::mutex> lock(g_mutex);
                g_focused_ptr = ev.node_id;
            }
            if (KxUiaNodeProvider* p = providerFor(ev.node_id)) {
                if (UiaClientsAreListening()) {
                    UiaRaiseAutomationEvent(static_cast<IRawElementProviderSimple*>(p),
                                            UIA_AutomationFocusChangedEventId);
                }
                p->Release();
            }
            break;
        }
        case KX_A11Y_ANNOUNCE: {
            // Live regions: LiveRegionChanged on the announcing node (or the
            // root when the event carries no node) +, on RS3+, a
            // notification that speaks the announcement text itself.
            IRawElementProviderSimple* target =
                ev.node_id ? static_cast<IRawElementProviderSimple*>(providerFor(ev.node_id))
                           : rootSimpleRef();
            if (target) {
                if (UiaClientsAreListening())
                    UiaRaiseAutomationEvent(target, UIA_LiveRegionChangedEventId);
                target->Release();
            }
            if (UiaRaiseNotificationEventFn notify = raiseNotificationFn()) {
                if (ev.text && ev.text_len > 0) {
                    std::wstring w = wstrFromUtf8(ev.text, ev.text_len);
                    BSTR msg = SysAllocStringLen(w.data(), (UINT)w.size());
                    BSTR activity = SysAllocString(L"");
                    const NotificationProcessing how =
                        ev.region == 2 ? NotificationProcessing_ImportantMostRecent
                                       : NotificationProcessing_MostRecent;
                    if (IRawElementProviderSimple* root = rootSimpleRef()) {
                        notify(root, NotificationKind_Other, how, msg, activity);
                        root->Release();
                    }
                    SysFreeString(msg);
                    SysFreeString(activity);
                }
            }
            break;
        }
        default:
            break;
    }
}

// --- HWND plumbing ---

// The SDL window's HWND (single-window app: first SDL window wins).
static HWND findHwnd() {
    int count = 0;
    SDL_Window** wins = SDL_GetWindows(&count);
    HWND hwnd = nullptr;
    if (wins) {
        for (int i = 0; i < count && !hwnd; i++) {
            if (!wins[i]) continue;
            hwnd = (HWND)SDL_GetPointerProperty(SDL_GetWindowProperties(wins[i]),
                                                SDL_PROP_WINDOW_WIN32_HWND_POINTER, nullptr);
        }
        SDL_free(wins);
    }
    return hwnd;
}

// Subclassed WNDPROC: serves WM_GETOBJECT for UIA and the posted action
// messages that call back into Zig on the SDL thread. Everything else falls
// through to SDL's proc.
static LRESULT CALLBACK KxUiaWndProc(HWND hwnd, UINT msg, WPARAM wParam, LPARAM lParam) {
    if (msg == WM_GETOBJECT && (LONG)lParam == UiaRootObjectId) {
        // UiaReturnRawElementProvider marshals our root to the client; it
        // returns 0 for requests it doesn't own (e.g. MSAA OBJID_CLIENT),
        // which we then pass on to the default handling.
        if (IRawElementProviderSimple* root = rootSimpleRef()) {
            const LRESULT res = UiaReturnRawElementProvider(hwnd, wParam, lParam, root);
            root->Release();
            if (res) return res;
        }
    } else if (msg == KX_WM_A11Y_ACTION) {
        if (g_zig_root_node && lParam) {
            if (wParam == KX_A11Y_DO_FOCUS)
                kx_a11y_focus_node(g_zig_root_node, (uint64_t)lParam);
            else if (wParam == KX_A11Y_DO_ACTIVATE)
                kx_a11y_activate_node(g_zig_root_node, (uint64_t)lParam);
        }
        return 0;
    }
    return CallWindowProcW(g_old_wndproc ? g_old_wndproc : DefWindowProcW, hwnd, msg, wParam,
                           lParam);
}

// --- Public C API (called from Zig host.zig, like the macOS bridge) ---
extern "C" {

/// Initialize the UIA bridge. `root_node` is the Klaxon root Node (used to
/// dump the semantic tree on tree_dirty). Finds the SDL window's HWND,
/// subclasses it for WM_GETOBJECT, installs the C bridge callback, and
/// builds the initial provider tree.
void kx_a11y_init(void* root_node) {
    g_zig_root_node = root_node;
    // Register the C bridge callback with the Zig semantics module.
    kx_a11y_set_bridge(a11yBridgeCallback, nullptr);
    if (g_root_provider) return; // already initialized

    g_hwnd = findHwnd();
    g_root_provider = new (std::nothrow) KxUiaRootProvider(); // ref 1, ours
    if (g_hwnd) {
        // Subclass for WM_GETOBJECT (a SendMessage — never reaches SDL's
        // message hook) and for KX_WM_A11Y_ACTION dispatches. Only remember
        // the prior proc when the subclass actually took — otherwise
        // shutdown's "restore" would stomp SDL's WNDPROC with ours gone.
        g_old_wndproc = (WNDPROC)SetWindowLongPtrW(g_hwnd, GWLP_WNDPROC, (LONG_PTR)&KxUiaWndProc);
    }
    // Populate the snapshot now so providers exist before the first
    // tree_dirty event arrives.
    std::vector<KxUiaNodeProvider*> stale;
    rebuildTree(&stale);
}

/// Shut down the bridge: restore the WNDPROC, disconnect and release all
/// providers, unregister the C bridge callback.
void kx_a11y_shutdown(void) {
    kx_a11y_set_bridge(nullptr, nullptr);
    if (g_hwnd && g_old_wndproc) {
        SetWindowLongPtrW(g_hwnd, GWLP_WNDPROC, (LONG_PTR)g_old_wndproc);
    }
    g_old_wndproc = nullptr;
    std::vector<KxUiaNodeProvider*> dying;
    {
        std::lock_guard<std::mutex> lock(g_mutex);
        dying.reserve(g_providers.size());
        for (auto& kv : g_providers) dying.push_back(kv.second);
        g_providers.clear();
        g_nodes.clear();
        g_index.clear();
        g_focused_ptr = 0;
    }
    for (KxUiaNodeProvider* p : dying) {
        UiaDisconnectProvider(static_cast<KX_UIA_PROVIDER_ARG*>(p));
        p->Release();
    }
    if (g_root_provider) {
        UiaDisconnectProvider(static_cast<KX_UIA_PROVIDER_ARG*>(g_root_provider));
        // Null the global under the lock first so in-flight provider calls
        // (read+AddRef inside g_mutex) can't observe a dying root.
        KxUiaRootProvider* root;
        {
            std::lock_guard<std::mutex> lock(g_mutex);
            root = g_root_provider;
            g_root_provider = nullptr;
        }
        root->Release();
    }
    g_hwnd = nullptr;
    g_zig_root_node = nullptr;
}

/// Opaque handle on the UIA root provider (IRawElementProviderSimple* —
/// non-owning; API parity with the macOS/Android bridges).
void* kx_a11y_root_element(void) {
    return static_cast<IRawElementProviderSimple*>(g_root_provider);
}

} // extern "C"
