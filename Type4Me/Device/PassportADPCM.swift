import Foundation

/// IMA ADPCM 4:1 decoding for the BLE audio path.
///
/// BLE cannot comfortably carry 256 kbps of raw PCM, so the device compresses to
/// 64 kbps there. Each 100 ms block is self-contained — the header carries the
/// predictor and step index — so a lost block costs only its own 100 ms and never
/// desynchronizes what follows.
///
/// Tables and reconstruction match the firmware's `main/adpcm.c` byte for byte, and
/// a shared test vector pins them together. Nibble order is low-nibble-first, as in
/// WAV IMA ADPCM.
enum PassportADPCM {

    /// `[int16 LE predictor][uint8 index][uint8 reserved]`
    static let headerBytes = 4
    /// 100 ms at 16 kHz.
    static let blockSamples = 1600
    /// Header plus one nibble per sample.
    static let blockBytes = headerBytes + blockSamples / 2

    private static let stepTable: [Int] = [
        7, 8, 9, 10, 11, 12, 13, 14, 16, 17,
        19, 21, 23, 25, 28, 31, 34, 37, 41, 45,
        50, 55, 60, 66, 73, 80, 88, 97, 107, 118,
        130, 143, 157, 173, 190, 209, 230, 253, 279, 307,
        337, 371, 408, 449, 494, 544, 598, 658, 724, 796,
        876, 963, 1060, 1166, 1282, 1411, 1552, 1707, 1878, 2066,
        2272, 2499, 2749, 3024, 3327, 3660, 4026, 4428, 4871, 5358,
        5894, 6484, 7132, 7845, 8630, 9493, 10442, 11487, 12635, 13899,
        15289, 16818, 18500, 20350, 22385, 24623, 27086, 29794, 32767,
    ]

    private static let indexDelta: [Int] = [
        -1, -1, -1, -1, 2, 4, 6, 8,
        -1, -1, -1, -1, 2, 4, 6, 8,
    ]

    private static let indexMax = 88

    /// Decode one block into 16 kHz mono Int16 PCM. Returns nil if the block is
    /// too short to carry a header.
    ///
    /// The header's predictor **is** the block's first sample, so `n` samples come
    /// from one header plus `n - 1` nibbles. `sampleCount` defaults to whatever the
    /// payload can supply, so a truncated block (or one zero-padded after a partial
    /// transfer) still decodes what it has.
    static func decodeBlock(_ block: Data, sampleCount: Int? = nil) -> Data? {
        guard block.count >= headerBytes else { return nil }

        return block.withUnsafeBytes { raw -> Data in
            var predictor = Int(Int16(littleEndian: raw.loadUnaligned(as: Int16.self)))
            var index = min(max(Int(raw[2]), 0), indexMax)

            let nibbleBytes = block.count - headerBytes
            // Sample 0 comes from the header; each nibble byte carries two more.
            // A full 804-byte block therefore yields 1600 samples, using 1599 of
            // its 1600 nibbles — the last one is padding.
            let available = min(1 + nibbleBytes * 2, blockSamples)
            let count = min(sampleCount ?? available, available)
            guard count > 0 else { return Data() }

            var samples = [Int16]()
            samples.reserveCapacity(count)
            samples.append(Int16(predictor))

            var byteOffset = headerBytes
            for i in 1..<count {
                // Low nibble first within each byte, matching WAV IMA ADPCM. The
                // phase is keyed to the sample index, which starts at 1 because the
                // header already supplied sample 0.
                let byte = raw[byteOffset]
                let nibble: Int
                if i % 2 == 1 {
                    nibble = Int(byte & 0x0F)
                } else {
                    nibble = Int((byte >> 4) & 0x0F)
                    byteOffset += 1
                }

                let step = stepTable[index]
                var difference = step >> 3
                if nibble & 4 != 0 { difference += step }
                if nibble & 2 != 0 { difference += step >> 1 }
                if nibble & 1 != 0 { difference += step >> 2 }
                predictor += (nibble & 8) != 0 ? -difference : difference
                predictor = min(max(predictor, Int(Int16.min)), Int(Int16.max))

                index = min(max(index + indexDelta[nibble], 0), indexMax)
                samples.append(Int16(predictor))
            }

            return samples.withUnsafeBufferPointer { Data(buffer: $0) }
        }
    }
}
