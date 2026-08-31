#include "audio_mixer.h"

#include <cassert>
#include <cstdint>
#include <iostream>
#include <limits>

using namespace audioshare::mixer;

int main() {
    assert(AverageMixedSample(25000, 1) == 25000);
    assert(AverageMixedSample(50000, 2) == 25000);
    assert(AverageMixedSample(-50000, 2) == -25000);
    assert(AverageMixedSample(0, 0) == 0);
    assert(AverageMixedSample(
        static_cast<int32_t>(std::numeric_limits<int16_t>::max()) * 60, 60) ==
        std::numeric_limits<int16_t>::max());

    assert(ShouldCountUnderrun(true, 1000, 1050, 240, 480));
    assert(!ShouldCountUnderrun(true, 1000, 1200, 240, 480));
    assert(!ShouldCountUnderrun(false, 0, 50, 0, 480));
    assert(!ShouldCountUnderrun(true, 1000, 1050, 480, 480));
    assert(!ShouldCountUnderrun(true, 1050, 1000, 0, 480));

    std::cout << "Audio mixer tests passed\n";
    return 0;
}
