import Foundation

/// Reassembles BLE audio notifications back into 100 ms PCM frames.
///
/// The device sends one ADPCM block per 100 ms, split into fragments that fit the
/// ATT MTU, each carrying a two-byte header:
///
/// ```
/// byte 0: block sequence, ++ per block, wrapping at 256
/// byte 1: fragment index (0...127) | 0x80 on the last fragment
/// ```
///
/// The header exists so a lost fragment costs only its own block rather than
/// desynchronizing the byte stream forever.
///
/// There is a second problem, specific to macOS: **CoreBluetooth coalesces several
/// ATT notifications into one delegate callback.** A single fragment is at most
/// ~253 bytes, yet real sessions deliver payloads of 364, 546 and 728 bytes. Parsing
/// the header at offset zero then reads the middle of a fragment as a header,
/// corrupting that block and every one after it. So each payload is split before
/// reassembly, using rules derived from the firmware's fragmentation:
///
/// - within one connection, non-final fragments are all the same length
/// - the final fragment holds whatever the block still needs, plus its header
/// - coalescing only concatenates whole fragments; it never cuts one
///
/// Ported from the reference client's `companion/relay.py`, whose comments record
/// this as observed on hardware rather than theorized.
struct PassportADPCMReassembler {

    /// Two-byte fragment header.
    static let fragmentHeader = 2
    /// Marks the last fragment of a block.
    static let lastFragmentFlag: UInt8 = 0x80
    static let fragmentIndexMask: UInt8 = 0x7F

    /// Current block being assembled.
    private var sequence: UInt8?
    private var buffer = Data()
    private var lastIndex = -1
    /// Sequence of the block we most recently finalized, so a late fragment from it
    /// is dropped rather than starting a bogus new block.
    private var lastFinalizedSequence: UInt8?
    /// Learned full-fragment length, used to split coalesced payloads.
    private var unit: Int?

    /// Blocks lost or discarded. Reconciled against the device's own `drop` count.
    private(set) var missedBlocks = 0

    init() {}

    /// Feed one notification payload; get back every complete 100 ms PCM frame.
    mutating func accept(_ payload: Data) -> [Data] {
        let pieces = splitCoalesced(payload)
        guard pieces.count > 1 else { return acceptFragment(payload) }

        var frames: [Data] = []
        for piece in pieces {
            frames += acceptFragment(piece)
        }
        return frames
    }

    /// Reset for a new session; adaptive state does not carry across recordings.
    mutating func reset() {
        sequence = nil
        buffer = Data()
        lastIndex = -1
        lastFinalizedSequence = nil
        unit = nil
        missedBlocks = 0
    }

    // MARK: - Single fragment

    private mutating func acceptFragment(_ fragment: Data) -> [Data] {
        guard fragment.count >= Self.fragmentHeader else {
            missedBlocks += 1
            return []
        }

        let base = fragment.startIndex
        let seq = fragment[base]
        let index = Int(fragment[base + 1] & Self.fragmentIndexMask)
        let isLast = fragment[base + 1] & Self.lastFragmentFlag != 0
        let data = fragment[(base + Self.fragmentHeader)...]

        var frames: [Data] = []

        if seq == sequence {
            // Duplicate or reordered fragment: the radio can deliver both.
            guard index > lastIndex else { return [] }
            buffer.append(data)
            lastIndex = index
        } else if seq == lastFinalizedSequence {
            // Straggler from a block we already emitted.
            return []
        } else {
            // A new block while the previous one never saw its last fragment. Pad
            // and emit it rather than dropping it, so the 100 ms cadence — which the
            // ASR stream depends on — survives a lost fragment.
            if sequence != nil, !buffer.isEmpty {
                frames += finalizeBlock(padding: true)
            }
            sequence = seq
            buffer = Data(data)
            lastIndex = index
        }

        if isLast {
            frames += finalizeBlock(padding: false)
        }
        return frames
    }

    /// Turn the assembled block into a PCM frame, or count it as missed.
    private mutating func finalizeBlock(padding: Bool) -> [Data] {
        var payload = buffer
        let finished = sequence
        sequence = nil
        lastFinalizedSequence = finished
        buffer = Data()
        lastIndex = -1

        if payload.count == PassportADPCM.blockBytes {
            if let pcm = PassportADPCM.decodeBlock(payload, sampleCount: PassportADPCM.blockSamples),
               pcm.count == AudioCaptureEngine.chunkByteSize {
                return [pcm]
            }
            missedBlocks += 1
            return []
        }

        missedBlocks += 1

        if payload.count > PassportADPCM.blockBytes {
            // Longer than any legal block means we are out of step; forget the
            // finalized sequence so the next fragment can realign freely.
            lastFinalizedSequence = nil
            return []
        }

        // A partial block still decodes to something: zero-pad it and emit near
        // silence, which keeps the cadence instead of stalling the ASR stream.
        if padding, payload.count >= PassportADPCM.headerBytes {
            payload.append(Data(repeating: 0, count: PassportADPCM.blockBytes - payload.count))
            if let pcm = PassportADPCM.decodeBlock(payload, sampleCount: PassportADPCM.blockSamples),
               pcm.count == AudioCaptureEngine.chunkByteSize {
                return [pcm]
            }
        }
        return []
    }

    // MARK: - Coalesced payload splitting

    /// Split one delegate callback into the fragments CoreBluetooth merged into it.
    ///
    /// `unit` is learned as the minimum non-final fragment length: a full fragment
    /// never carries the LAST flag, and a coalesced payload is always at least
    /// `unit + header` long, so the minimum converges on the true value. Until it is
    /// known, the hard ceiling (one fragment large enough for a whole block) is used,
    /// which covers an MTU big enough to send a block in one notification.
    private mutating func splitCoalesced(_ payload: Data) -> [Data] {
        let n = payload.count
        guard n >= Self.fragmentHeader else { return [payload] }

        let base = payload.startIndex
        if payload[base + 1] & Self.lastFragmentFlag == 0 {
            if unit == nil || n < unit! {
                unit = n
            }
        }
        let fragmentLength = unit ?? (Self.fragmentHeader + PassportADPCM.blockBytes)
        guard n > fragmentLength else { return [payload] }

        var pieces: [Data] = []
        var offset = 0
        var currentSequence = sequence
        // How much of the current block we already hold, needed to size a last
        // fragment from the ledger.
        var accumulated = currentSequence != nil ? buffer.count : 0

        while offset + Self.fragmentHeader <= n {
            let seq = payload[base + offset]
            if seq != currentSequence {
                currentSequence = seq
                accumulated = 0
            }

            if payload[base + offset + 1] & Self.lastFragmentFlag != 0 {
                let length = lastFragmentLength(
                    payload, offset: offset, sequence: seq, accumulated: accumulated)
                pieces.append(payload[(base + offset)..<(base + offset + length)])
                offset += length
                currentSequence = nil
                accumulated = 0
            } else {
                pieces.append(payload[(base + offset)..<(base + offset + fragmentLength)])
                offset += fragmentLength
                accumulated += fragmentLength - Self.fragmentHeader
            }
        }

        if offset < n {
            // Trailing bytes too short to be a header; hand them on to be counted.
            pieces.append(payload[(base + offset)...])
        }
        return pieces
    }

    /// Length of a last fragment starting at `offset` inside a coalesced payload.
    ///
    /// The ledger value — what the block still needs, plus a header — is right when
    /// no fragment was lost. When one was, the ledger over-counts, so the cut is
    /// validated against what must follow a last fragment: the first fragment of the
    /// next block, `[seq+1][0]` or `[seq+1][0x80]`. If the ledger fails, scan forward
    /// for the first cut that does hold; if none does, take the rest as one piece and
    /// let the zero-padding path absorb it. Never split at a position that would
    /// produce a misaligned fragment.
    private func lastFragmentLength(
        _ payload: Data, offset: Int, sequence seq: UInt8, accumulated: Int
    ) -> Int {
        let n = payload.count
        let base = payload.startIndex
        let next = seq &+ 1

        func isValidCut(_ cut: Int) -> Bool {
            if cut == n { return true }
            if cut + Self.fragmentHeader > n { return false }
            return payload[base + cut] == next
                && payload[base + cut + 1] & Self.fragmentIndexMask == 0
        }

        let ledger = PassportADPCM.blockBytes - accumulated + Self.fragmentHeader
        if ledger > Self.fragmentHeader, offset + ledger <= n, isValidCut(offset + ledger) {
            return ledger
        }

        var cut = offset + Self.fragmentHeader
        while cut <= n {
            if isValidCut(cut) { return cut - offset }
            cut += 1
        }
        return n - offset
    }
}
