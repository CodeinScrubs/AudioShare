#ifndef AUDIOSHARE_AUDIO_MIXER_H_
#define AUDIOSHARE_AUDIO_MIXER_H_

#include <cstddef>
#include <cstdint>
#include <limits>

namespace audioshare::mixer {

// Averaging gives each concurrently available endpoint deterministic headroom:
// mirrored full-scale streams remain full-scale instead of hard-clipping, and
// a lone endpoint retains unity gain.
inline int16_t AverageMixedSample(int32_t sum, uint32_t contributors) {
    if (contributors == 0) return 0;
    const int32_t half = static_cast<int32_t>(contributors / 2);
    int32_t value = sum >= 0
        ? (sum + half) / static_cast<int32_t>(contributors)
        : (sum - half) / static_cast<int32_t>(contributors);
    if (value > std::numeric_limits<int16_t>::max()) {
        value = std::numeric_limits<int16_t>::max();
    }
    if (value < std::numeric_limits<int16_t>::min()) {
        value = std::numeric_limits<int16_t>::min();
    }
    return static_cast<int16_t>(value);
}

// Loopback capture may stop producing packets during normal silence. Count a
// short read only while a recently non-silent stream was expected to advance.
inline bool ShouldCountUnderrun(
        bool hasSeenNonSilentPacket, uint64_t lastNonSilentPacketMillis,
        uint64_t nowMillis, size_t availableFrames, size_t requiredFrames,
        uint64_t activeWindowMillis = 100) {
    if (!hasSeenNonSilentPacket || availableFrames >= requiredFrames) return false;
    if (nowMillis < lastNonSilentPacketMillis) return false;
    return nowMillis - lastNonSilentPacketMillis <= activeWindowMillis;
}

}  // namespace audioshare::mixer

#endif  // AUDIOSHARE_AUDIO_MIXER_H_
