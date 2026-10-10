package com.klaxon.gallery;

import android.graphics.Rect;
import android.os.Bundle;
import android.os.Handler;
import android.os.Looper;
import android.view.View;
import android.view.accessibility.AccessibilityEvent;
import android.view.accessibility.AccessibilityNodeInfo;
import android.view.accessibility.AccessibilityNodeProvider;

import java.util.ArrayList;
import java.util.HashMap;
import java.util.List;
import java.util.Map;

/**
 * TalkBack bridge for the Klaxon gallery (Phase 3d-a11y).
 *
 * Attached to SDLActivity.mSurface by kx_a11y_android.cpp (kx_a11y_init), the
 * same way the macOS bridge is wired by kx_a11y_macos.mm. The semantic tree
 * lives in Zig; this class is a thin virtual-node view over it:
 *
 *   Zig (SDL thread)                      this class (UI thread)
 *   ─────────────────                     ─────────────────────
 *   bridge events ──JNI──►  onTreeDirty / onAnnounce / onFocusChanged
 *   kx_a11y_dump_tree ──►   parsed in C++ into a node cache
 *   nativeGetNode*  ◄──JNI── createAccessibilityNodeInfo (pull)
 *   nativeActivate / nativeFocus ◄──JNI── performAction (double-tap / focus)
 *
 * The native entry points hop to the UI thread with a Handler: accessibility
 * calls must run there, the bridge events arrive on SDL's thread.
 *
 * v1: swipe navigation, double-tap activation, announcements, focus sync.
 * The tree dump carries each node's rect in window space (x|y|w|h =
 * mapRectToRoot(bounds), Phase 3de) — the provider positions the virtual
 * nodes from them, so TalkBack's touch exploration and highlight work.
 */
public class KxAccessibilityDelegate extends View.AccessibilityDelegate {

    private final View mHost;
    private final Handler mUi = new Handler(Looper.getMainLooper());
    private final KxNodeProvider mProvider = new KxNodeProvider();

    // Dump index -> Node pointer (decimal), rebuilt on every tree_dirty.
    private final List<Long> mPtrs = new ArrayList<>();
    private final Map<Long, Integer> mIndexByPtr = new HashMap<>();
    private int mFocusedIndex = -1;

    public KxAccessibilityDelegate(View host) {
        mHost = host;
        // TalkBack enters the surface through the host view, then descends
        // into the virtual nodes served by the provider.
        mHost.setFocusable(true);
        mHost.setImportantForAccessibility(View.IMPORTANT_FOR_ACCESSIBILITY_YES);
    }

    // --- Bridge entry points (native -> Java, called on the SDL thread) ---

    /** The semantic tree changed (or one control's value flipped). */
    public void onTreeDirty() {
        mUi.post(() -> {
            rebuildFromNative();
            mHost.invalidate();
            AccessibilityEvent event = AccessibilityEvent.obtain(
                    AccessibilityEvent.TYPE_WINDOW_CONTENT_CHANGED);
            event.setSource(mHost);
            event.setContentChangeTypes(AccessibilityEvent.CONTENT_CHANGE_TYPE_SUBTREE);
            mHost.sendAccessibilityEventUnchecked(event);
        });
    }

    /** A live region announced text (region: 0=off 1=polite 2=assertive). */
    public void onAnnounce(String text, int region) {
        if (text == null || text.isEmpty()) return;
        mUi.post(() -> announce(text));
    }

    /** The keyboard focus moved to the node with this pointer. */
    public void onFocusChanged(long ptr) {
        mUi.post(() -> focusVirtualNode(indexOfPtr(ptr)));
    }

    // --- Node cache, pulled from native (parsed from kx_a11y_dump_tree) ---

    private static native int nativeGetNodeCount();
    private static native int nativeGetNodeParent(int index);
    private static native long nativeGetNodePtr(int index);
    private static native String nativeGetNodeRole(int index);
    private static native String nativeGetNodeLabel(int index);
    private static native String nativeGetNodeValue(int index);
    private static native boolean nativeGetNodeFocusable(int index);
    private static native int nativeGetNodeChecked(int index);
    /** Fills out[0..3] = x, y, w, h (window space). False when out of range. */
    private static native boolean nativeGetNodeBounds(int index, int[] out);
    private static native void nativeActivate(long ptr);
    private static native void nativeFocus(long ptr);

    private void rebuildFromNative() {
        int count = nativeGetNodeCount();
        mPtrs.clear();
        mIndexByPtr.clear();
        for (int i = 0; i < count; i++) {
            long ptr = nativeGetNodePtr(i);
            mPtrs.add(ptr);
            mIndexByPtr.put(ptr, i);
        }
        if (mFocusedIndex >= count) mFocusedIndex = -1;
    }

    private int indexOfPtr(long ptr) {
        Integer index = mIndexByPtr.get(ptr);
        return index != null ? index : -1;
    }

    // --- TalkBack plumbing (UI thread) ---

    private void announce(String text) {
        AccessibilityEvent event = AccessibilityEvent.obtain(
                AccessibilityEvent.TYPE_ANNOUNCEMENT);
        event.getText().add(text);
        int index = mFocusedIndex;
        if (index >= 0 && index < mPtrs.size()) {
            // Attribute the announcement to the focused control when there is
            // one, so TalkBack speaks it in context.
            event.setSource(mHost, index);
            mHost.sendAccessibilityEventUnchecked(event);
        } else {
            event.setSource(mHost);
            mHost.sendAccessibilityEventUnchecked(event);
        }
    }

    private void focusVirtualNode(int index) {
        if (index < 0 || index >= mPtrs.size()) return;
        mFocusedIndex = index;
        AccessibilityEvent event = AccessibilityEvent.obtain(
                AccessibilityEvent.TYPE_VIEW_ACCESSIBILITY_FOCUSED);
        event.setSource(mHost, index);
        mHost.sendAccessibilityEventUnchecked(event);
    }

    // --- View.AccessibilityDelegate: the host view itself ---

    @Override
    public void onInitializeAccessibilityNodeInfo(View host, AccessibilityNodeInfo info) {
        super.onInitializeAccessibilityNodeInfo(host, info);
        info.setClassName("android.view.View");
        info.setContentDescription("Klaxon application");
        info.setFocusable(true);
    }

    @Override
    public AccessibilityNodeProvider getAccessibilityNodeProvider(View host) {
        return mProvider;
    }

    // --- The virtual node tree served to TalkBack ---

    private class KxNodeProvider extends AccessibilityNodeProvider {

        @Override
        public AccessibilityNodeInfo createAccessibilityNodeInfo(int virtualDescendantId) {
            if (virtualDescendantId == AccessibilityNodeProvider.HOST_VIEW_ID) {
                // Host node: the surface itself. Populate it through the
                // delegate's onInitializeAccessibilityNodeInfo and advertise
                // every virtual node as a child — without the addChild calls
                // TalkBack swipes on the surface but finds nothing to descend
                // into.
                AccessibilityNodeInfo info = AccessibilityNodeInfo.obtain(mHost);
                KxAccessibilityDelegate.this.onInitializeAccessibilityNodeInfo(mHost, info);
                int childCount = nativeGetNodeCount();
                for (int i = 0; i < childCount; i++) {
                    info.addChild(mHost, i);
                }
                return info;
            }
            if (virtualDescendantId < 0 || virtualDescendantId >= mPtrs.size()) {
                return null;
            }
            String role = nativeGetNodeRole(virtualDescendantId);
            String label = nativeGetNodeLabel(virtualDescendantId);
            String value = nativeGetNodeValue(virtualDescendantId);
            boolean focusable = nativeGetNodeFocusable(virtualDescendantId);
            int checked = nativeGetNodeChecked(virtualDescendantId);
            int parent = nativeGetNodeParent(virtualDescendantId);

            AccessibilityNodeInfo info = AccessibilityNodeInfo.obtain(mHost);
            info.setSource(mHost, virtualDescendantId);
            info.setPackageName(mHost.getContext().getPackageName());
            info.setClassName(classNameForRole(role));
            if (parent >= 0) {
                info.setParent(mHost, parent);
            } else {
                info.setParent(mHost);
            }
            // The dump carries window-space rects (mapRectToRoot): absolute
            // for boundsInScreen, relative to the parent's rect for
            // boundsInParent — TalkBack positions the highlight from these.
            int[] rect = new int[4];
            if (nativeGetNodeBounds(virtualDescendantId, rect)) {
                info.setBoundsInScreen(new Rect(rect[0], rect[1],
                        rect[0] + rect[2], rect[1] + rect[3]));
                int[] parentRect = new int[4];
                boolean hasParentRect = parent >= 0 && nativeGetNodeBounds(parent, parentRect);
                int ox = hasParentRect ? parentRect[0] : 0;
                int oy = hasParentRect ? parentRect[1] : 0;
                info.setBoundsInParent(new Rect(rect[0] - ox, rect[1] - oy,
                        rect[0] - ox + rect[2], rect[1] - oy + rect[3]));
            } else {
                // No geometry (older dump): every node reports the host rect.
                int width = mHost.getWidth();
                int height = mHost.getHeight();
                info.setBoundsInParent(new Rect(0, 0, width, height));
                int[] location = new int[2];
                mHost.getLocationOnScreen(location);
                info.setBoundsInScreen(new Rect(location[0], location[1],
                        location[0] + width, location[1] + height));
            }
            info.setVisibleToUser(true);
            if (label != null && !label.isEmpty()) {
                info.setText(label);
            }
            if ("slider".equals(role) || "progress".equals(role) || "scrollbar".equals(role)) {
                float now = parseFloat(value);
                if (!Float.isNaN(now)) {
                    info.setRangeInfo(AccessibilityNodeInfo.RangeInfo.obtain(
                            AccessibilityNodeInfo.RangeInfo.RANGE_TYPE_FLOAT, 0f, 100f, now));
                }
            } else if ("toggle".equals(role) || "checkbox".equals(role) || "radio".equals(role)) {
                info.setCheckable(true);
                info.setChecked(checked == 2); // dump: 0=null 1=false 2=true
            }
            if (focusable) {
                info.setFocusable(true);
                info.setFocused(virtualDescendantId == mFocusedIndex);
            }
            if (isActionable(role)) {
                info.setClickable(true);
                info.addAction(AccessibilityNodeInfo.ACTION_CLICK);
            }
            return info;
        }

        @Override
        public boolean performAction(int virtualDescendantId, int action, Bundle arguments) {
            if (virtualDescendantId < 0 || virtualDescendantId >= mPtrs.size()) {
                return false;
            }
            long ptr = mPtrs.get(virtualDescendantId);
            switch (action) {
                case AccessibilityNodeInfo.ACTION_CLICK:
                    // TalkBack double-tap -> activate the node in Zig.
                    nativeActivate(ptr);
                    return true;
                case AccessibilityNodeInfo.ACTION_ACCESSIBILITY_FOCUS:
                case AccessibilityNodeInfo.ACTION_FOCUS:
                    // TalkBack moved its focus -> sync the Zig focus ring.
                    nativeFocus(ptr);
                    focusVirtualNode(virtualDescendantId);
                    return true;
                default:
                    return false;
            }
        }
    }

    // --- Role mapping (Klaxon semantics role -> android widget class) ---

    private static String classNameForRole(String role) {
        if (role == null) return "android.view.View";
        switch (role) {
            case "button": return "android.widget.Button";
            case "text":
            case "heading":
            case "link": return "android.widget.TextView";
            case "text_field": return "android.widget.EditText";
            case "toggle": return "android.widget.Switch";
            case "checkbox": return "android.widget.CheckBox";
            case "radio": return "android.widget.RadioButton";
            case "slider": return "android.widget.SeekBar";
            case "progress": return "android.widget.ProgressBar";
            case "scrollbar": return "android.widget.ScrollBar";
            case "image": return "android.widget.ImageView";
            case "list": return "android.widget.ListView";
            default: return "android.view.View";
        }
    }

    private static boolean isActionable(String role) {
        if (role == null) return false;
        switch (role) {
            case "button":
            case "link":
            case "toggle":
            case "checkbox":
            case "radio":
            case "tab":
            case "menu_item":
            case "list_item":
                return true;
            default:
                return false;
        }
    }

    private static float parseFloat(String value) {
        if (value == null || value.isEmpty()) return Float.NaN;
        try {
            return Float.parseFloat(value);
        } catch (NumberFormatException e) {
            return Float.NaN;
        }
    }
}
