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

// The "bench" context property exposed to the scene QML files. The C++
// harness emits tickFrame(frame) once per frame; each scene implements its
// per-frame logic in a Connections handler — the Qt port of bench.zig's
// SceneRunner.tick. The invokables below are the Qt mechanics for the
// input-driven scenes (input_ime, resize).
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
        const QPointF local(x, y);
        const QPointF global = m_view->mapToGlobal(local);
        QMouseEvent press(QEvent::MouseButtonPress, local, global, Qt::LeftButton,
                          Qt::LeftButton, Qt::NoModifier);
        QGuiApplication::sendEvent(m_view, &press);
        QMouseEvent release(QEvent::MouseButtonRelease, local, global, Qt::LeftButton,
                            Qt::NoButton, Qt::NoModifier);
        QGuiApplication::sendEvent(m_view, &release);
        if (!m_view->activeFocusItem()) {
            if (QQuickItem *input =
                    m_view->findChild<QQuickItem *>(QStringLiteral("imeInput")))
                input->forceActiveFocus();
        }
    }

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
    QQuickView *m_view;
};
