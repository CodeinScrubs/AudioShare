#include "wire_protocol.h"

#include <array>
#include <cassert>
#include <cstdint>
#include <cstring>
#include <iostream>

using namespace audioshare::wire;

int main() {
    const auto encoded = EncodeHeader(kTypePcm, 4096, 0x10203040);
    FrameHeader decoded;
    assert(DecodeHeader(encoded.data(), encoded.size(), &decoded));
    assert(decoded.type == kTypePcm);
    assert(decoded.payloadLength == 4096);
    assert(decoded.sequence == 0x10203040);

    auto invalidMagic = encoded;
    invalidMagic[0] ^= 0xff;
    assert(!DecodeHeader(invalidMagic.data(), invalidMagic.size(), &decoded));
    auto invalidVersion = encoded;
    invalidVersion[5] = 2;
    assert(!DecodeHeader(invalidVersion.data(), invalidVersion.size(), &decoded));
    assert(!DecodeHeader(encoded.data(), encoded.size() - 1, &decoded));
    assert(IsStrictlyIncreasingSequence(7, 8));
    assert(!IsStrictlyIncreasingSequence(7, 7));
    assert(!IsStrictlyIncreasingSequence(7, 6));

    const auto oversizedPcm = EncodeHeader(
        kTypePcm, static_cast<uint32_t>(kMaxPcmPayload + 1), 1);
    assert(!DecodeHeader(oversizedPcm.data(), oversizedPcm.size(), &decoded));
    const auto maximumPcm = EncodeHeader(
        kTypePcm, static_cast<uint32_t>(kMaxPcmPayload), 1);
    assert(DecodeHeader(maximumPcm.data(), maximumPcm.size(), &decoded));

    constexpr char tokenHex[] =
        "00112233445566778899aabbccddeeff"
        "ffeeddccbbaa99887766554433221100";
    std::array<uint8_t, kTokenBytes> token{};
    assert(DecodeToken(tokenHex, token.data()));
    assert(token.front() == 0x00);
    assert(token[15] == 0xff);
    assert(token[16] == 0xff);
    assert(token.back() == 0x00);
    assert(!DecodeToken("0011", token.data()));
    char invalidToken[sizeof(tokenHex)]{};
    std::memcpy(invalidToken, tokenHex, sizeof(tokenHex));
    invalidToken[10] = 'z';
    assert(!DecodeToken(invalidToken, token.data()));

    assert(DecodeToken(tokenHex, token.data()));
    const auto hello = EncodeHello(token.data(), 48000, 2, 16);
    assert(std::memcmp(hello.data(), token.data(), kTokenBytes) == 0);
    assert(ReadU32(hello.data() + 32) == 48000);
    assert(hello[36] == 2);
    assert(hello[37] == 16);
    assert(hello[38] == 0 && hello[39] == 0);

    std::array<uint8_t, 16> readyBytes{};
    WriteU32(readyBytes.data(), 48000);
    WriteU32(readyBytes.data() + 4, 2);
    WriteU32(readyBytes.data() + 8, 16);
    WriteU32(readyBytes.data() + 12, 2880);
    ReadyPayload ready;
    assert(DecodeReady(readyBytes.data(), readyBytes.size(), &ready));
    assert(ready.sampleRate == 48000 && ready.channels == 2);
    assert(ready.bitsPerSample == 16 && ready.bufferFrames == 2880);
    assert(!DecodeReady(readyBytes.data(), readyBytes.size() - 1, &ready));

    std::array<uint8_t, kLegacyPlaybackStatsBytes> statsBytes{};
    WriteU32(statsBytes.data(), 1);
    WriteU32(statsBytes.data() + 4, 2);
    WriteU32(statsBytes.data() + 8, 3);
    WriteU32(statsBytes.data() + 12, 4);
    WriteU32(statsBytes.data() + 16, 5);
    WriteU32(statsBytes.data() + 20, 6);
    PlaybackStats stats;
    assert(DecodePlaybackStats(statsBytes.data(), statsBytes.size(), &stats));
    assert(stats.receivedFrames == 0x0000000100000002ULL);
    assert(stats.droppedFrames == 0x0000000300000004ULL);
    assert(stats.queueDepth == 5 && stats.bufferFrames == 6);
    assert(stats.queueFrames == 0 && stats.startThresholdFrames == 0);
    assert(!DecodePlaybackStats(
        statsBytes.data(), statsBytes.size() - 1, &stats));

    std::array<uint8_t, kEnhancedPlaybackStatsBytes> enhancedStatsBytes{};
    for (size_t index = 0; index < enhancedStatsBytes.size() / 4; ++index) {
        WriteU32(
            enhancedStatsBytes.data() + index * 4,
            static_cast<uint32_t>(index + 1));
    }
    assert(DecodePlaybackStats(
        enhancedStatsBytes.data(), enhancedStatsBytes.size(), &stats));
    assert(stats.receivedFrames == 0x0000000100000002ULL);
    assert(stats.droppedFrames == 0x0000000300000004ULL);
    assert(stats.queueDepth == 5 && stats.bufferFrames == 6);
    assert(stats.queueFrames == 7 && stats.bufferCapacityFrames == 8);
    assert(stats.startThresholdFrames == 9 && stats.underrunCount == 10);
    assert(stats.routedDeviceType == 11 && stats.focusState == 12);
    assert(stats.mediaVolume == 13 && stats.mediaVolumeMax == 14);
    assert(stats.queueHighWaterFrames == 15);
    assert(!DecodePlaybackStats(
        enhancedStatsBytes.data(), enhancedStatsBytes.size() - 1, &stats));

    std::cout << "Wire protocol tests passed\n";
    return 0;
}
