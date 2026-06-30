import VideoToolbox
import CoreMedia

/// Hardware decode capabilities of the current device, queried once. Used by routing to decide whether a
/// codec can play on-device (remux/direct) or must be transcoded by Stash.
enum DeviceCapabilities {
    /// True when this device has a hardware AV1 decoder (iPhone 15 Pro / A17 Pro and later, M3-class Macs).
    /// When true, AVPlayer decodes AV1 natively, so AV1 should remux on-device (repackage into `av01` MP4)
    /// instead of asking the server to transcode.
    static let av1HardwareDecode: Bool = VTIsHardwareDecodeSupported(kCMVideoCodecType_AV1)
}
