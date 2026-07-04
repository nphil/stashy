import Libavformat
import Libavcodec
import Libavutil
import Libswresample

/// M-A Stage 1b: re-encode a non-MP4-native audio track (Opus/Vorbis/…) to **AAC** so it can be muxed
/// into the fragmented MP4 alongside the on-device-transcoded H.264 video, instead of being dropped.
///
/// Pipeline: decode → libswresample convert to the AAC encoder's format (FLTP, source rate/layout) →
/// buffer PCM in an `AVAudioFifo` → pull fixed 1024-sample frames for the encoder → mux. The FIFO is
/// needed because the AAC encoder wants a constant frame size while decoders emit variable-size frames.
/// The resampler is created lazily from the first decoded frame, since a decoder's real sample format
/// isn't known until it produces output.
///
/// Timestamps come from a monotonic sample counter (starts at 0), so audio and the zero-based video line
/// up for start-from-0 playback; on a mid-stream seek the alignment is approximate (good enough — the
/// primary path starts at 0).
final class FFmpegAudioReencoder {
    private let decCtx: UnsafeMutablePointer<AVCodecContext>
    private let encCtx: UnsafeMutablePointer<AVCodecContext>
    let outStream: UnsafeMutablePointer<AVStream>
    private let outFmt: UnsafeMutablePointer<AVFormatContext>
    private var swr: OpaquePointer?
    private let fifo: OpaquePointer
    private let decFrame: UnsafeMutablePointer<AVFrame>
    private let swrFrame: UnsafeMutablePointer<AVFrame>
    private let encPkt: UnsafeMutablePointer<AVPacket>
    private let channels: Int32
    private let frameSize: Int32
    private var nextPts: Int64 = 0

    /// Human summary, e.g. "opus → aac", for the diagnostic log.
    let label: String

    private let averrorEAGAIN: Int32 = -35
    private let averrorEOF: Int32 = -541478725
    private let codecFlagGlobalHeader: Int32 = 1 << 22

    init?(inStream: UnsafeMutablePointer<AVStream>,
          outFmt: UnsafeMutablePointer<AVFormatContext>,
          globalHeader: Bool) {
        guard let apar = inStream.pointee.codecpar,
              let dec = avcodec_find_decoder(apar.pointee.codec_id),
              let dctx = avcodec_alloc_context3(dec) else { return nil }
        if avcodec_parameters_to_context(dctx, apar) < 0 || avcodec_open2(dctx, dec, nil) < 0 {
            var d: UnsafeMutablePointer<AVCodecContext>? = dctx; avcodec_free_context(&d); return nil
        }
        guard let enc = avcodec_find_encoder_by_name("aac"),
              let ectx = avcodec_alloc_context3(enc) else {
            var d: UnsafeMutablePointer<AVCodecContext>? = dctx; avcodec_free_context(&d); return nil
        }
        ectx.pointee.sample_rate = apar.pointee.sample_rate > 0 ? apar.pointee.sample_rate : 48_000
        ectx.pointee.sample_fmt = AV_SAMPLE_FMT_FLTP          // the native FFmpeg AAC encoder's input format
        av_channel_layout_copy(&ectx.pointee.ch_layout, &dctx.pointee.ch_layout)
        if ectx.pointee.ch_layout.nb_channels <= 0 {
            av_channel_layout_default(&ectx.pointee.ch_layout, 2)
        }
        ectx.pointee.bit_rate = 128_000
        ectx.pointee.time_base = AVRational(num: 1, den: ectx.pointee.sample_rate)
        // Fragmented MP4 (empty_moov) puts the AudioSpecificConfig in the init segment, so the encoder must
        // emit a global header rather than in-band config — else AVPlayer can't decode the AAC track.
        if globalHeader { ectx.pointee.flags |= codecFlagGlobalHeader }
        if avcodec_open2(ectx, enc, nil) < 0 {
            var d: UnsafeMutablePointer<AVCodecContext>? = dctx; avcodec_free_context(&d)
            var e: UnsafeMutablePointer<AVCodecContext>? = ectx; avcodec_free_context(&e); return nil
        }
        guard let os = avformat_new_stream(outFmt, nil),
              avcodec_parameters_from_context(os.pointee.codecpar, ectx) >= 0 else {
            var d: UnsafeMutablePointer<AVCodecContext>? = dctx; avcodec_free_context(&d)
            var e: UnsafeMutablePointer<AVCodecContext>? = ectx; avcodec_free_context(&e); return nil
        }
        os.pointee.codecpar.pointee.codec_tag = 0
        os.pointee.time_base = ectx.pointee.time_base
        let ch = ectx.pointee.ch_layout.nb_channels
        guard let fifo = av_audio_fifo_alloc(ectx.pointee.sample_fmt, ch, 1),
              let df = av_frame_alloc(), let sf = av_frame_alloc(), let ep = av_packet_alloc() else {
            var d: UnsafeMutablePointer<AVCodecContext>? = dctx; avcodec_free_context(&d)
            var e: UnsafeMutablePointer<AVCodecContext>? = ectx; avcodec_free_context(&e); return nil
        }
        self.decCtx = dctx
        self.encCtx = ectx
        self.outStream = os
        self.outFmt = outFmt
        self.fifo = fifo
        self.decFrame = df
        self.swrFrame = sf
        self.encPkt = ep
        self.channels = ch
        self.frameSize = ectx.pointee.frame_size > 0 ? ectx.pointee.frame_size : 1024
        self.label = "\(String(cString: avcodec_get_name(apar.pointee.codec_id))) → aac"
    }

    /// Decode one input packet and push whatever audio it yields through resample → FIFO → encoder → mux.
    func process(_ pkt: UnsafeMutablePointer<AVPacket>?) {
        guard avcodec_send_packet(decCtx, pkt) >= 0 else { return }
        while true {
            let r = avcodec_receive_frame(decCtx, decFrame)
            if r == averrorEAGAIN || r == averrorEOF { break }
            guard r >= 0 else { break }
            resampleIntoFifo(decFrame)
            av_frame_unref(decFrame)
        }
        drainFifo(flush: false)
    }

    /// Flush at EOF: drain the resampler's tail, emit the final short frame, then flush the AAC encoder.
    func flush() {
        if swr != nil {
            while true {
                av_frame_unref(swrFrame)
                swrFrame.pointee.format = Int32(encCtx.pointee.sample_fmt.rawValue)
                av_channel_layout_copy(&swrFrame.pointee.ch_layout, &encCtx.pointee.ch_layout)
                swrFrame.pointee.sample_rate = encCtx.pointee.sample_rate
                swrFrame.pointee.nb_samples = frameSize
                guard av_frame_get_buffer(swrFrame, 0) >= 0 else { break }
                guard swr_convert_frame(swr, swrFrame, nil) == 0, swrFrame.pointee.nb_samples > 0 else { break }
                writeFrameToFifo(swrFrame)
            }
        }
        drainFifo(flush: true)
        encodeAndMux(nil)   // flush the encoder
    }

    func free() {
        var d: UnsafeMutablePointer<AVCodecContext>? = decCtx; avcodec_free_context(&d)
        var e: UnsafeMutablePointer<AVCodecContext>? = encCtx; avcodec_free_context(&e)
        if swr != nil { swr_free(&swr) }
        av_audio_fifo_free(fifo)
        var df: UnsafeMutablePointer<AVFrame>? = decFrame; av_frame_free(&df)
        var sf: UnsafeMutablePointer<AVFrame>? = swrFrame; av_frame_free(&sf)
        var ep: UnsafeMutablePointer<AVPacket>? = encPkt; av_packet_free(&ep)
    }

    // MARK: - Internals

    /// Lazily build the resampler from the first decoded frame (a decoder's true sample format is only
    /// known once it emits output). Converts to the encoder's format/rate/layout.
    private func ensureSwr(from frame: UnsafeMutablePointer<AVFrame>) -> Bool {
        if swr != nil { return true }
        var s: OpaquePointer?
        let inFmt = AVSampleFormat(rawValue: frame.pointee.format)
        let ok = swr_alloc_set_opts2(&s,
            &encCtx.pointee.ch_layout, encCtx.pointee.sample_fmt, encCtx.pointee.sample_rate,
            &frame.pointee.ch_layout, inFmt, frame.pointee.sample_rate, 0, nil) >= 0
        guard ok, let created = s, swr_init(created) >= 0 else { if s != nil { swr_free(&s) }; return false }
        swr = created
        return true
    }

    private func resampleIntoFifo(_ input: UnsafeMutablePointer<AVFrame>) {
        guard ensureSwr(from: input) else { return }
        av_frame_unref(swrFrame)
        swrFrame.pointee.format = Int32(encCtx.pointee.sample_fmt.rawValue)
        av_channel_layout_copy(&swrFrame.pointee.ch_layout, &encCtx.pointee.ch_layout)
        swrFrame.pointee.sample_rate = encCtx.pointee.sample_rate
        // Sample rate is unchanged (encoder rate == source rate), so out ≈ in; +frameSize covers any
        // resampler delay comfortably.
        swrFrame.pointee.nb_samples = input.pointee.nb_samples + frameSize
        guard av_frame_get_buffer(swrFrame, 0) >= 0 else { return }
        guard swr_convert_frame(swr, swrFrame, input) == 0 else { return }
        writeFrameToFifo(swrFrame)
    }

    private func writeFrameToFifo(_ frame: UnsafeMutablePointer<AVFrame>) {
        let n = frame.pointee.nb_samples
        guard n > 0, let planes = frame.pointee.extended_data else { return }
        planes.withMemoryRebound(to: UnsafeMutableRawPointer?.self, capacity: Int(channels)) { data in
            _ = av_audio_fifo_write(fifo, data, n)
        }
    }

    /// Pull fixed-size frames from the FIFO into the encoder. On `flush`, also emit the final short frame.
    private func drainFifo(flush: Bool) {
        while av_audio_fifo_size(fifo) >= frameSize || (flush && av_audio_fifo_size(fifo) > 0) {
            let n = min(frameSize, av_audio_fifo_size(fifo))
            guard let frame = av_frame_alloc() else { return }
            frame.pointee.nb_samples = n
            av_channel_layout_copy(&frame.pointee.ch_layout, &encCtx.pointee.ch_layout)
            frame.pointee.format = Int32(encCtx.pointee.sample_fmt.rawValue)
            frame.pointee.sample_rate = encCtx.pointee.sample_rate
            if av_frame_get_buffer(frame, 0) >= 0, let planes = frame.pointee.extended_data {
                planes.withMemoryRebound(to: UnsafeMutableRawPointer?.self, capacity: Int(channels)) { data in
                    _ = av_audio_fifo_read(fifo, data, n)
                }
                frame.pointee.pts = nextPts
                nextPts += Int64(n)
                encodeAndMux(frame)
            }
            var f: UnsafeMutablePointer<AVFrame>? = frame; av_frame_free(&f)
        }
    }

    private func encodeAndMux(_ frame: UnsafeMutablePointer<AVFrame>?) {
        guard avcodec_send_frame(encCtx, frame) >= 0 else { return }
        while true {
            let r = avcodec_receive_packet(encCtx, encPkt)
            if r == averrorEAGAIN || r == averrorEOF { break }
            guard r >= 0 else { break }
            encPkt.pointee.stream_index = outStream.pointee.index
            av_packet_rescale_ts(encPkt, encCtx.pointee.time_base, outStream.pointee.time_base)
            encPkt.pointee.pos = -1
            _ = av_interleaved_write_frame(outFmt, encPkt)
            av_packet_unref(encPkt)
        }
    }
}
