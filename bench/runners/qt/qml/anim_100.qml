import QtQuick

// Klaxon bench.zig buildAnim100: grid(10 columns, gap 8, padding 16) of 100
// animated containers. The tick retargets height + color every frame
// (phase = frame*0.06 + i*0.17; height target = 24 + 16*sin(phase); color =
// lerp(#3F51B5, #E91E63, (sin(phase)+1)/2)) and advances the timeline 8
// ms/frame — 100 concurrent springs (ui/anim.zig: stiffness 380, damping 32,
// mass 1, exact closed form). The Qt port evaluates the same closed-form
// spring step per widget per frame.
Item {
    Grid {
        id: grid
        padding: 16
        spacing: 8
        columns: 10
        width: parent.width

        Repeater {
            id: rep
            model: 100
            Rectangle {
                // initial state (the tick applies height/color imperatively
                // from frame 0 on, like Klaxon's signal sets)
                property real curH: 32
                property real curR: 0x3F / 255
                property real curG: 0x51 / 255
                property real curB: 0xB5 / 255
                width: (grid.width - 32 - 9 * 8) / 10
                height: curH
                radius: 8
                color: Qt.rgba(curR, curG, curB, 1)
            }
        }
    }
    Connections {
        target: bench
        // The spring state lives in typed arrays: allocation-free per frame
        // (Klaxon's springs are plain Zig state — no per-frame allocation
        // either). Per widget per frame the tick applies exactly two visual
        // sets (height + color), matching Klaxon's two signal sets.
        property var items: null
        property var st: null
        function onTickFrame(frame) {
            // ui/anim.zig Spring{stiffness 380, damping 32, mass 1}; the
            // timeline advances 8 ms per frame (bench.zig: timeline.tick(frame*8))
            const k = 380.0, c = 32.0, m = 1.0, dt = 0.008
            const omega0 = Math.sqrt(k / m)
            const zeta = c / (2 * Math.sqrt(k * m))
            const omegaD = omega0 * Math.sqrt(1 - zeta * zeta)
            const zwo = zeta * omega0
            const e = Math.exp(-zwo * dt)
            const cosT = Math.cos(omegaD * dt)
            const sinT = Math.sin(omegaD * dt)
            if (!items) {
                items = []
                st = {
                    h: new Float64Array(100), vh: new Float64Array(100),
                    r: new Float64Array(100), vr: new Float64Array(100),
                    g: new Float64Array(100), vg: new Float64Array(100),
                    b: new Float64Array(100), vb: new Float64Array(100)
                }
                for (let i = 0; i < 100; ++i) {
                    const cell = rep.itemAt(i)
                    items.push(cell)
                    st.h[i] = cell.curH
                    st.r[i] = cell.curR
                    st.g[i] = cell.curG
                    st.b[i] = cell.curB
                }
            }
            for (let i = 0; i < 100; ++i) {
                const cell = items[i]
                const phase = frame * 0.06 + i * 0.17
                const s = Math.sin(phase)
                const targetH = 24 + 16 * s
                const t = (s + 1) / 2 // lerp factor #3F51B5 -> #E91E63
                const tR = (0x3F + (0xE9 - 0x3F) * t) / 255
                const tG = (0x51 + (0x1E - 0x51) * t) / 255
                const tB = (0xB5 + (0x63 - 0xB5) * t) / 255
                // height lane (exact closed form, 8 ms step)
                let d0 = st.h[i] - targetH
                let b = (st.vh[i] + zwo * d0) / omegaD
                let disp = e * (d0 * cosT + b * sinT)
                st.vh[i] = e * ((b * omegaD - zwo * d0) * cosT - (d0 * omegaD + zwo * b) * sinT)
                st.h[i] = targetH + disp
                // red lane
                d0 = st.r[i] - tR
                b = (st.vr[i] + zwo * d0) / omegaD
                disp = e * (d0 * cosT + b * sinT)
                st.vr[i] = e * ((b * omegaD - zwo * d0) * cosT - (d0 * omegaD + zwo * b) * sinT)
                st.r[i] = tR + disp
                // green lane
                d0 = st.g[i] - tG
                b = (st.vg[i] + zwo * d0) / omegaD
                disp = e * (d0 * cosT + b * sinT)
                st.vg[i] = e * ((b * omegaD - zwo * d0) * cosT - (d0 * omegaD + zwo * b) * sinT)
                st.g[i] = tG + disp
                // blue lane
                d0 = st.b[i] - tB
                b = (st.vb[i] + zwo * d0) / omegaD
                disp = e * (d0 * cosT + b * sinT)
                st.vb[i] = e * ((b * omegaD - zwo * d0) * cosT - (d0 * omegaD + zwo * b) * sinT)
                st.b[i] = tB + disp
                // apply: height + color (Klaxon: the height and color signals)
                cell.height = st.h[i]
                cell.color = Qt.rgba(st.r[i], st.g[i], st.b[i], 1)
            }
        }
    }
}
