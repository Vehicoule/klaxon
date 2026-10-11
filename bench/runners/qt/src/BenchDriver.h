#pragma once

#include <QGuiApplication>
#include <QInputMethodEvent>
#include <QKeyEvent>
#include <QMouseEvent>
#include <QObject>
#include <QPointF>
#include <QQuickItem>
#include <QQuickView>
#include <QString>
#include <QVector>

// The "bench" context property exposed to the scene QML files. The C++
// harness emits tickFrame(frame) once per frame; each scene implements its
// per-frame logic in a Connections handler — the Qt port of bench.zig's
// SceneRunner.tick. The invokables below are the Qt mechanics for the
// input-driven scenes (input_ime, resize) and the catalogue-v2 system
// scenes (input_latency, pointer_storm, semantics_build).
class BenchDriver : public QObject {
    Q_OBJECT

public:
    explicit BenchDriver(QQuickView *view, QObject *parent = nullptr)
        : QObject(parent), m_view(view) {}

    // Klaxon's input_ime tick focuses the field with a pointer down+up at
    // its center (frame 0). Synthesize the same mouse events at window
    // coordinates; fall back to forceActiveFocus if the click path did not
    // focus anything (offscreen windows have no window manager activation).
    Q_INVOKABLE void clickAt(qreal x, qreal y) {
        pressAt(x, y);
        if (!m_view->activeFocusItem()) {
            if (QQuickItem *input =
                    m_view->findChild<QQuickItem *>(QStringLiteral("imeInput")))
                input->forceActiveFocus();
        }
    }

    // A synthetic pointer event (down+up) at window coordinates — the
    // input_latency scene's injected event and input_ime's click-to-focus
    // (bench.zig: router.dispatchPointer / kx pointer events).
    Q_INVOKABLE void pressAt(qreal x, qreal y) {
        const QPointF local(x, y);
        const QPointF global = m_view->mapToGlobal(local);
        QMouseEvent press(QEvent::MouseButtonPress, local, global, Qt::LeftButton,
                          Qt::LeftButton, Qt::NoModifier);
        QGuiApplication::sendEvent(m_view, &press);
        QMouseEvent release(QEvent::MouseButtonRelease, local, global, Qt::LeftButton,
                            Qt::NoButton, Qt::NoModifier);
        QGuiApplication::sendEvent(m_view, &release);
    }

    // One hit-test query over the scene's item tree (pointer_storm: 1000 of
    // these per frame over a 500-node tree, "pure hit-test cost"). Walks the
    // tree exactly like Qt's event delivery does — topmost-first, contains()
    // then descend — and returns the depth of the deepest hit item (0 =
    // miss), so the query's work cannot be elided.
    Q_INVOKABLE int hitTest(qreal x, qreal y) {
        QQuickItem *root = m_view->rootObject();
        if (!root)
            return 0;
        int depth = 0;
        hitTestRec(root, QPointF(x, y), &depth);
        return depth;
    }

    // semantics_build's per-frame work: walk the item tree and (re)build a
    // flat semantics record per node — class, objectName, text and mapped
    // bounds, the fields a real a11y tree carries — then a cheap diff
    // against the previous frame's build (record hash). Qt has no public
    // "build the a11y tree" entry point; this is the closest idiom for
    // Klaxon's semantics-tree build+diff (see README.md). Returns the number
    // of nodes walked (extra.nodes_per_frame).
    Q_INVOKABLE int collectSemantics() {
        m_semanticsNodes = 0;
        m_semanticsChanged = 0;
        m_semanticsScratch.clear();
        if (QQuickItem *root = m_view->rootObject())
            collectRec(root);
        // The diff: compare this frame's record hash with the previous
        // frame's; node-count changes also count as a change.
        if (m_semanticsScratch != m_semanticsPrev) {
            m_semanticsChanged = qAbs(m_semanticsScratch.size() - m_semanticsPrev.size());
            const int n = qMin(m_semanticsScratch.size(), m_semanticsPrev.size());
            for (int i = 0; i < n; ++i)
                if (m_semanticsScratch[i] != m_semanticsPrev[i])
                    ++m_semanticsChanged;
        }
        m_semanticsPrev = m_semanticsScratch;
        return m_semanticsNodes;
    }

    int semanticsNodes() const { return m_semanticsNodes; }
    int semanticsChanged() const { return m_semanticsChanged; }

    // An IME text commit: a QInputMethodEvent with a commit string is exactly
    // what an input method delivers; the focused TextInput inserts it at the
    // caret (bench.zig: router.dispatchKey(.text_input, ...)).
    Q_INVOKABLE void sendText(const QString &text) {
        QInputMethodEvent ev;
        ev.setCommitString(text);
        QGuiApplication::sendEvent(m_view, &ev);
    }

    // A backspace key press (input_ime: every 12th frame keeps the buffer
    // bounded).
    Q_INVOKABLE void sendBackspace() {
        QKeyEvent ev(QEvent::KeyPress, Qt::Key_Backspace, Qt::NoModifier);
        QGuiApplication::sendEvent(m_view, &ev);
    }

    // Resize the view (resize scene: the viewport cycles through
    // RESIZE_SIZES every frame — Klaxon's kx_resize + relayout).
    Q_INVOKABLE void setViewSize(int w, int h) { m_view->resize(w, h); }

signals:
    void tickFrame(int frame);

private:
    // Topmost-first recursive hit test (the same walk Qt performs to
    // dispatch a pointer event: contains() in local coords, then descend).
    static void hitTestRec(QQuickItem *item, const QPointF &pos, int *depth) {
        const QList<QQuickItem *> kids = item->childItems();
        // childItems() is bottom-to-top stacking order; hit-testing starts
        // at the topmost child.
        for (int i = kids.size() - 1; i >= 0; --i) {
            QQuickItem *c = kids.at(i);
            if (!c->isVisible())
                continue;
            const QPointF lp = item->mapToItem(c, pos);
            if (lp.x() >= 0 && lp.y() >= 0 && lp.x() < c->width() && lp.y() < c->height()) {
                ++(*depth);
                hitTestRec(c, lp, depth);
                return; // topmost hit wins
            }
        }
    }

    // One semantics record: class + name + text + mapped bounds, hashed into
    // a compact key (records are built fresh every frame — the build cost is
    // the point of the scene).
    void collectRec(QQuickItem *item) {
        if (!item || !item->isVisible())
            return;
        ++m_semanticsNodes;
        const QVariant text = item->property("text");
        const QRectF r = item->mapRectToScene(QRectF(0, 0, item->width(), item->height()));
        quint64 h = quint64(item->metaObject()->className()[0]);
        h = (h * 131) ^ quint64(item->objectName().size());
        h = (h * 131) ^ quint64(text.isValid() ? text.toString().size() : 0);
        h = (h * 131) ^ quint64(qint64(r.x()) ^ (qint64(r.y()) << 20)
                              ^ (qint64(r.width()) << 40));
        m_semanticsScratch.append(h);
        const QList<QQuickItem *> kids = item->childItems();
        for (QQuickItem *c : kids)
            collectRec(c);
    }

    QQuickView *m_view;
    int m_semanticsNodes = 0;
    int m_semanticsChanged = 0;
    QVector<quint64> m_semanticsScratch;
    QVector<quint64> m_semanticsPrev;
};
