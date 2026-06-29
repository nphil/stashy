import Libavcodec
import Libavutil

/// A tiny smoke test that the self-built FFmpeg XCFrameworks (from the `stashy-videoengine` package)
/// actually link and are callable from Swift. Surfaced in the debug Stats overlay so it can be
/// verified on-device before the full remux/transcode pipeline is built on top.
enum FFmpegProbe {
    /// FFmpeg's configured version string, e.g. "7.1".
    static var versionInfo: String {
        guard let info = av_version_info() else { return "unavailable" }
        return String(cString: info)
    }

    /// Whether the VideoToolbox hardware H.264 encoder is present — the encoder the on-device
    /// transcode path relies on (and the reason for a custom, encoder-enabled build).
    static var hasVideoToolboxH264: Bool {
        avcodec_find_encoder_by_name("h264_videotoolbox") != nil
    }
}
