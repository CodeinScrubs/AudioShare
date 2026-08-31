#ifndef AUDIOSHARE_WIRE_PROTOCOL_H_
#define AUDIOSHARE_WIRE_PROTOCOL_H_

#include <array>
#include <cstddef>
#include <cstdint>
#include <cstring>

namespace audioshare::wire {

constexpr uint32_t kProtocolMagic = 0x41535542;  // ASUB
constexpr uint16_t kProtocolVersion = 1;
constexpr uint16_t kTypeHello = 1;
constexpr uint16_t kTypeReady = 2;
constexpr uint16_t kTypePcm = 4;
constexpr uint16_t kTypeStats = 5;
constexpr uint16_t kTypePing = 6;
constexpr uint16_t kTypePong = 7;
constexpr uint16_t kTypeError = 8;
constexpr size_t kFrameHeaderBytes = 16;
constexpr size_t kTokenBytes = 32;
constexpr size_t kHelloBytes = 40;
constexpr size_t kLegacyPlaybackStatsBytes = 24;
constexpr size_t kEnhancedPlaybackStatsBytes = 60;
constexpr size_t kMaxControlPayload = 64 * 1024;
constexpr size_t kMaxPcmPayload = 8 * 1024;

struct FrameHeader {
    uint16_t type = 0;
    uint32_t payloadLength = 0;
    uint32_t sequence = 0;
};

inline void WriteU16(uint8_t* destination, uint16_t value) {
    destination[0] = static_cast<uint8_t>((value >> 8) & 0xff);
    destination[1] = static_cast<uint8_t>(value & 0xff);
}

inline void WriteU32(uint8_t* destination, uint32_t value) {
    destination[0] = static_cast<uint8_t>((value >> 24) & 0xff);
    destination[1] = static_cast<uint8_t>((value >> 16) & 0xff);
    destination[2] = static_cast<uint8_t>((value >> 8) & 0xff);
    destination[3] = static_cast<uint8_t>(value & 0xff);
}

inline uint16_t ReadU16(const uint8_t* source) {
    return static_cast<uint16_t>(
        (static_cast<uint16_t>(source[0]) << 8) | source[1]);
}

inline uint32_t ReadU32(const uint8_t* source) {
    return (static_cast<uint32_t>(source[0]) << 24) |
        (static_cast<uint32_t>(source[1]) << 16) |
        (static_cast<uint32_t>(source[2]) << 8) |
        source[3];
}

inline uint64_t ReadU64(const uint8_t* source) {
    return (static_cast<uint64_t>(ReadU32(source)) << 32) |
        ReadU32(source + 4);
}

struct ReadyPayload {
    uint32_t sampleRate = 0;
    uint32_t channels = 0;
    uint32_t bitsPerSample = 0;
    uint32_t bufferFrames = 0;
};

inline bool DecodeReady(
        const uint8_t* payload, size_t length, ReadyPayload* ready) {
    if (payload == nullptr || ready == nullptr || length != 16) return false;
    ready->sampleRate = ReadU32(payload);
    ready->channels = ReadU32(payload + 4);
    ready->bitsPerSample = ReadU32(payload + 8);
    ready->bufferFrames = ReadU32(payload + 12);
    return true;
}

struct PlaybackStats {
    uint64_t receivedFrames = 0;
    uint64_t droppedFrames = 0;
    uint32_t queueDepth = 0;
    uint32_t bufferFrames = 0;
    uint32_t queueFrames = 0;
    uint32_t bufferCapacityFrames = 0;
    uint32_t startThresholdFrames = 0;
    uint32_t underrunCount = 0;
    uint32_t routedDeviceType = 0;
    uint32_t focusState = 0;
    uint32_t mediaVolume = 0;
    uint32_t mediaVolumeMax = 0;
    uint32_t queueHighWaterFrames = 0;
};

inline bool DecodePlaybackStats(
        const uint8_t* payload, size_t length, PlaybackStats* stats) {
    if (payload == nullptr || stats == nullptr ||
        (length != kLegacyPlaybackStatsBytes &&
         length != kEnhancedPlaybackStatsBytes)) {
        return false;
    }
    *stats = {};
    stats->receivedFrames = ReadU64(payload);
    stats->droppedFrames = ReadU64(payload + 8);
    stats->queueDepth = ReadU32(payload + 16);
    stats->bufferFrames = ReadU32(payload + 20);
    if (length == kEnhancedPlaybackStatsBytes) {
        stats->queueFrames = ReadU32(payload + 24);
        stats->bufferCapacityFrames = ReadU32(payload + 28);
        stats->startThresholdFrames = ReadU32(payload + 32);
        stats->underrunCount = ReadU32(payload + 36);
        stats->routedDeviceType = ReadU32(payload + 40);
        stats->focusState = ReadU32(payload + 44);
        stats->mediaVolume = ReadU32(payload + 48);
        stats->mediaVolumeMax = ReadU32(payload + 52);
        stats->queueHighWaterFrames = ReadU32(payload + 56);
    }
    return true;
}

inline bool IsPayloadLengthAllowed(uint16_t type, size_t payloadLength) {
    const size_t maximum =
        type == kTypePcm ? kMaxPcmPayload : kMaxControlPayload;
    return payloadLength <= maximum && payloadLength <= UINT32_MAX;
}

inline bool IsStrictlyIncreasingSequence(uint32_t previous, uint32_t next) {
    return next > previous;
}

inline std::array<uint8_t, kFrameHeaderBytes> EncodeHeader(
        uint16_t type, uint32_t payloadLength, uint32_t sequence) {
    std::array<uint8_t, kFrameHeaderBytes> header{};
    WriteU32(header.data(), kProtocolMagic);
    WriteU16(header.data() + 4, kProtocolVersion);
    WriteU16(header.data() + 6, type);
    WriteU32(header.data() + 8, payloadLength);
    WriteU32(header.data() + 12, sequence);
    return header;
}

inline bool DecodeHeader(
        const uint8_t* encoded, size_t length, FrameHeader* header) {
    if (encoded == nullptr || header == nullptr ||
        length < kFrameHeaderBytes ||
        ReadU32(encoded) != kProtocolMagic ||
        ReadU16(encoded + 4) != kProtocolVersion) {
        return false;
    }
    const uint16_t type = ReadU16(encoded + 6);
    const uint32_t payloadLength = ReadU32(encoded + 8);
    if (!IsPayloadLengthAllowed(type, payloadLength)) return false;
    header->type = type;
    header->payloadLength = payloadLength;
    header->sequence = ReadU32(encoded + 12);
    return true;
}

inline bool DecodeToken(const char* hex, uint8_t* output) {
    if (hex == nullptr || output == nullptr ||
        std::strlen(hex) != kTokenBytes * 2) {
        return false;
    }
    const auto nibble = [](char value) -> int {
        if (value >= '0' && value <= '9') return value - '0';
        if (value >= 'a' && value <= 'f') return value - 'a' + 10;
        if (value >= 'A' && value <= 'F') return value - 'A' + 10;
        return -1;
    };
    for (size_t index = 0; index < kTokenBytes; ++index) {
        const int high = nibble(hex[index * 2]);
        const int low = nibble(hex[index * 2 + 1]);
        if (high < 0 || low < 0) return false;
        output[index] = static_cast<uint8_t>((high << 4) | low);
    }
    return true;
}

inline std::array<uint8_t, kHelloBytes> EncodeHello(
        const uint8_t* token, uint32_t sampleRate,
        uint8_t channels, uint8_t bitsPerSample) {
    std::array<uint8_t, kHelloBytes> hello{};
    std::memcpy(hello.data(), token, kTokenBytes);
    WriteU32(hello.data() + 32, sampleRate);
    hello[36] = channels;
    hello[37] = bitsPerSample;
    return hello;
}

}  // namespace audioshare::wire

#endif  // AUDIOSHARE_WIRE_PROTOCOL_H_
