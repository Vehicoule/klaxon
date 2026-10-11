import QtQuick
import klaxonbench

// Klaxon bench.zig buildVideoPlayback: column(padding 16, gap 12) [ title,
// videoWidget(320x180) ]. The widget regenerates its pixels every paint (a
// moving gradient + a sliding bar, deterministic in the frame counter) and
// uploads a fresh texture per frame. Qt: VideoItem (a C++ QQuickPaintedItem)
// does the same per-pixel loop + re-upload inside paint().
Item {
    Column {
        padding: 16
        spacing: 12
        width: parent.width

        Text {
            text: "video_playback — simulated 320×180 stream (texture re-upload every frame)"
            color: "#CCCCCC"
            font.pixelSize: 14
        }
        VideoItem {
            id: video
            width: 320
            height: 180
        }
    }
    Connections {
        target: bench
        function onTickFrame(frame) {
            video.frame = frame
        }
    }
}
