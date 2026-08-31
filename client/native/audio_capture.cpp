#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <winsock2.h>
#include <ws2tcpip.h>
#include <mmdeviceapi.h>
#include <audioclient.h>
#include <mmreg.h>
#include <propidl.h>

#if __has_include(<audioclientactivationparams.h>)
#include <audioclientactivationparams.h>
#else
// MinGW does not currently ship audioclientactivationparams.h. These are the
// public Windows SDK ABI declarations used by ActivateAudioInterfaceAsync.
typedef enum AUDIOCLIENT_ACTIVATION_TYPE {
    AUDIOCLIENT_ACTIVATION_TYPE_DEFAULT,
    AUDIOCLIENT_ACTIVATION_TYPE_PROCESS_LOOPBACK,
} AUDIOCLIENT_ACTIVATION_TYPE;

typedef enum PROCESS_LOOPBACK_MODE {
    PROCESS_LOOPBACK_MODE_INCLUDE_TARGET_PROCESS_TREE,
    PROCESS_LOOPBACK_MODE_EXCLUDE_TARGET_PROCESS_TREE,
} PROCESS_LOOPBACK_MODE;

typedef struct AUDIOCLIENT_PROCESS_LOOPBACK_PARAMS {
    DWORD TargetProcessId;
    PROCESS_LOOPBACK_MODE ProcessLoopbackMode;
} AUDIOCLIENT_PROCESS_LOOPBACK_PARAMS;

typedef struct AUDIOCLIENT_ACTIVATION_PARAMS {
    AUDIOCLIENT_ACTIVATION_TYPE ActivationType;
    union {
        AUDIOCLIENT_PROCESS_LOOPBACK_PARAMS ProcessLoopbackParams;
    };
} AUDIOCLIENT_ACTIVATION_PARAMS;

#define VIRTUAL_AUDIO_DEVICE_PROCESS_LOOPBACK L"VAD\\Process_Loopback"
#endif

#include <atomic>
#include <array>
#include <chrono>
#include <condition_variable>
#include <cstdint>
#include <cstring>
#include <deque>
#include <mutex>
#include <memory>
#include <new>
#include <string>
#include <utility>
#include <vector>

#include "wire_protocol.h"
#include "audio_mixer.h"

#ifdef _MSC_VER
#pragma comment(lib, "ws2_32.lib")
#endif

namespace {

constexpr size_t kMaxQueuedChunks = 8;
constexpr size_t kAudioChunkPoolSize = kMaxQueuedChunks + 1;
constexpr uint32_t kSampleRate = 48000;
constexpr uint16_t kChannels = 2;
constexpr uint16_t kBitsPerSample = 16;
constexpr DWORD kActivationTimeoutMilliseconds = 5000;
constexpr DWORD kMixerPeriodMilliseconds = 10;
constexpr size_t kMixerFrames =
    kSampleRate * kMixerPeriodMilliseconds / 1000;
constexpr size_t kMixerSamples = kMixerFrames * kChannels;
constexpr size_t kFrameBytes = kChannels * (kBitsPerSample / 8);
constexpr size_t kMaxHostQueueFrames = kSampleRate * 40 / 1000;
constexpr size_t kMaxEndpointQueueFrames = kSampleRate / 10;
constexpr size_t kEndpointBufferSamples =
    kMaxEndpointQueueFrames * kChannels;
constexpr size_t kMaxMultiEndpointCount = MAXIMUM_WAIT_OBJECTS - 3;
#if defined(CREATE_WAITABLE_TIMER_HIGH_RESOLUTION)
constexpr DWORD kHighResolutionTimerFlag =
    CREATE_WAITABLE_TIMER_HIGH_RESOLUTION;
#else
// Public synchapi.h value, supported by Windows 10 version 1803 and newer.
constexpr DWORD kHighResolutionTimerFlag = 0x00000002;
#endif

enum class CaptureMode : uint32_t {
    kNone = 0,
    kGlobalProcessLoopback = 1,
    kMultiEndpointLoopback = 2,
    kDefaultEndpointLoopback = 3,
};

using ConnectCallback = void (*)(const char* status);
using namespace audioshare::wire;

std::atomic<bool> g_initialized{false};
std::atomic<bool> g_transportRunning{false};
std::atomic<bool> g_captureRunning{false};
std::atomic<bool> g_connected{false};
std::atomic<bool> g_callbackAllowed{false};
std::atomic<uint64_t> g_droppedChunks{0};
std::atomic<uint64_t> g_androidReceivedFrames{0};
std::atomic<uint64_t> g_androidDroppedFrames{0};
std::atomic<uint32_t> g_androidQueueDepth{0};
std::atomic<uint32_t> g_androidBufferFrames{0};
std::atomic<uint32_t> g_androidQueueFrames{0};
std::atomic<uint32_t> g_androidBufferCapacityFrames{0};
std::atomic<uint32_t> g_androidStartThresholdFrames{0};
std::atomic<uint32_t> g_androidUnderrunCount{0};
std::atomic<uint32_t> g_androidRoutedDeviceType{0};
std::atomic<uint32_t> g_androidFocusState{0};
std::atomic<uint32_t> g_androidMediaVolume{0};
std::atomic<uint32_t> g_androidMediaVolumeMax{0};
std::atomic<uint32_t> g_androidQueueHighWaterFrames{0};
std::atomic<uint32_t> g_hostQueueFrames{0};
std::atomic<uint32_t> g_hostQueueHighWaterFrames{0};
std::atomic<uint64_t> g_transportBytesSent{0};
std::atomic<uint32_t> g_heartbeatRttMilliseconds{0};
std::atomic<uint32_t> g_captureMode{static_cast<uint32_t>(CaptureMode::kNone)};
std::atomic<long> g_globalLoopbackHresult{S_OK};
std::atomic<uint32_t> g_activeEndpointCount{0};
std::atomic<uint64_t> g_endpointDroppedFrames{0};
std::atomic<uint64_t> g_endpointUnderrunFrames{0};
std::atomic<uint64_t> g_endpointDiscontinuities{0};
std::atomic<uint32_t> g_endpointRebuildCount{0};
std::atomic<uint64_t> g_endpointCatchUpFrames{0};
std::atomic<uint32_t> g_endpointQueueHighWaterFrames{0};
std::atomic<SOCKET> g_transportSocket{INVALID_SOCKET};

HANDLE g_transportThread = nullptr;
HANDLE g_captureThread = nullptr;
HANDLE g_stopEvent = nullptr;
WSADATA g_wsaData{};

std::mutex g_configMutex;
int g_pendingPort = 0;
uint8_t g_pendingToken[kTokenBytes]{};
ConnectCallback g_connectCallback = nullptr;

std::mutex g_queueMutex;
std::condition_variable g_queueCondition;

template <size_t Capacity>
struct IndexRing {
    std::array<size_t, Capacity> values{};
    size_t head = 0;
    size_t count = 0;

    bool empty() const { return count == 0; }
    bool full() const { return count == Capacity; }

    bool push(size_t value) {
        if (full()) return false;
        values[(head + count) % Capacity] = value;
        ++count;
        return true;
    }

    size_t pop() {
        const size_t value = values[head];
        head = (head + 1) % Capacity;
        --count;
        return value;
    }

    void clear() {
        head = 0;
        count = 0;
    }
};

struct AudioChunk {
    std::array<uint8_t, kMaxPcmPayload> bytes{};
    size_t length = 0;
    size_t frames = 0;
};

std::array<AudioChunk, kAudioChunkPoolSize> g_audioChunkPool{};
IndexRing<kAudioChunkPoolSize> g_freeAudioChunks;
IndexRing<kAudioChunkPoolSize> g_readyAudioChunks;
bool g_audioPoolInitialized = false;

std::mutex g_errorMutex;
int g_lastErrorCode = 0;
char g_lastErrorMessage[1024]{};

void SetError(int code, const std::string& message) {
    std::lock_guard<std::mutex> lock(g_errorMutex);
    g_lastErrorCode = code;
    const size_t copyLength = message.size() < sizeof(g_lastErrorMessage) - 1
        ? message.size()
        : sizeof(g_lastErrorMessage) - 1;
    memcpy(g_lastErrorMessage, message.data(), copyLength);
    g_lastErrorMessage[copyLength] = '\0';
}

void SetErrorIfNone(int code, const std::string& message) {
    std::lock_guard<std::mutex> lock(g_errorMutex);
    if (g_lastErrorCode != 0) return;
    g_lastErrorCode = code;
    const size_t copyLength = message.size() < sizeof(g_lastErrorMessage) - 1
        ? message.size()
        : sizeof(g_lastErrorMessage) - 1;
    memcpy(g_lastErrorMessage, message.data(), copyLength);
    g_lastErrorMessage[copyLength] = '\0';
}

void ClearError() {
    std::lock_guard<std::mutex> lock(g_errorMutex);
    g_lastErrorCode = 0;
    g_lastErrorMessage[0] = '\0';
}

template <typename Value>
void UpdateAtomicMaximum(std::atomic<Value>* target, Value candidate) {
    Value current = target->load();
    while (candidate > current &&
           !target->compare_exchange_weak(current, candidate)) {
    }
}

std::string HresultMessage(const char* operation, HRESULT result) {
    char buffer[160]{};
    _snprintf_s(buffer, sizeof(buffer), _TRUNCATE, "%s failed (HRESULT 0x%08lX)",
        operation, static_cast<unsigned long>(result));
    return std::string(buffer);
}

bool SendAll(SOCKET socket, const uint8_t* data, size_t length) {
    while (length > 0 && g_transportRunning.load()) {
        const int batch = length > static_cast<size_t>(INT_MAX) ? INT_MAX : static_cast<int>(length);
        const int sent = send(socket, reinterpret_cast<const char*>(data), batch, 0);
        if (sent <= 0) return false;
        g_transportBytesSent.fetch_add(static_cast<uint64_t>(sent));
        data += sent;
        length -= static_cast<size_t>(sent);
    }
    return length == 0;
}

bool ReceiveAll(SOCKET socket, uint8_t* data, size_t length) {
    while (length > 0 && g_transportRunning.load()) {
        const int batch = length > static_cast<size_t>(INT_MAX) ? INT_MAX : static_cast<int>(length);
        const int received = recv(socket, reinterpret_cast<char*>(data), batch, 0);
        if (received <= 0) return false;
        data += received;
        length -= static_cast<size_t>(received);
    }
    return length == 0;
}

bool SendFrame(SOCKET socket, uint16_t type, uint32_t sequence,
               const uint8_t* payload, size_t payloadLength) {
    if (!IsPayloadLengthAllowed(type, payloadLength)) return false;
    const auto header = EncodeHeader(
        type, static_cast<uint32_t>(payloadLength), sequence);
    if (!SendAll(socket, header.data(), header.size())) return false;
    return payloadLength == 0 || SendAll(socket, payload, payloadLength);
}

struct ReceivedFrame {
    uint16_t type = 0;
    uint32_t sequence = 0;
    std::vector<uint8_t> payload;
};

bool ReceiveFrame(SOCKET socket, ReceivedFrame* frame) {
    uint8_t header[kFrameHeaderBytes]{};
    if (!ReceiveAll(socket, header, sizeof(header))) return false;
    FrameHeader decoded;
    if (!DecodeHeader(header, sizeof(header), &decoded)) {
        SetError(2104, "Android returned an invalid protocol header");
        return false;
    }
    frame->type = decoded.type;
    frame->sequence = decoded.sequence;
    frame->payload.resize(decoded.payloadLength);
    return decoded.payloadLength == 0 ||
        ReceiveAll(socket, frame->payload.data(), decoded.payloadLength);
}

std::string SanitizeAndroidError(const std::vector<uint8_t>& payload) {
    std::string detail;
    const size_t detailLength = payload.size() < 512 ? payload.size() : 512;
    detail.reserve(detailLength);
    for (size_t index = 0; index < detailLength; ++index) {
        const uint8_t value = payload[index];
        detail.push_back(value == 0 || value < 0x20
            ? ' '
            : static_cast<char>(value));
    }
    return detail;
}

void CloseTransportSocket() {
    const SOCKET socket = g_transportSocket.exchange(INVALID_SOCKET);
    if (socket != INVALID_SOCKET) {
        shutdown(socket, SD_BOTH);
        closesocket(socket);
    }
}

void ResetAudioQueueLocked() {
    g_freeAudioChunks.clear();
    g_readyAudioChunks.clear();
    for (size_t index = 0; index < g_audioChunkPool.size(); ++index) {
        g_audioChunkPool[index].length = 0;
        g_audioChunkPool[index].frames = 0;
        g_freeAudioChunks.push(index);
    }
    g_audioPoolInitialized = true;
    g_hostQueueFrames.store(0);
}

void ClearQueue() {
    std::lock_guard<std::mutex> lock(g_queueMutex);
    ResetAudioQueueLocked();
}

void DiscardQueuedAudio() {
    std::lock_guard<std::mutex> lock(g_queueMutex);
    while (!g_readyAudioChunks.empty()) {
        const size_t index = g_readyAudioChunks.pop();
        g_audioChunkPool[index].length = 0;
        g_audioChunkPool[index].frames = 0;
        g_freeAudioChunks.push(index);
        g_droppedChunks.fetch_add(1);
    }
    // A chunk already popped by the transport thread remains in-flight and is
    // intentionally not touched. It will return to the free ring when its
    // send completes, so a capture restart cannot reuse memory concurrently.
    g_hostQueueFrames.store(0);
}

void EnqueuePcm(const uint8_t* data, size_t length) {
    if (data == nullptr && length != 0) return;
    size_t offset = 0;
    while (offset < length && g_captureRunning.load()) {
        size_t chunkLength = length - offset;
        if (chunkLength > kMaxPcmPayload) chunkLength = kMaxPcmPayload;
        chunkLength -= chunkLength % kFrameBytes;
        if (chunkLength == 0) return;
        const size_t chunkFrames = chunkLength / kFrameBytes;
        {
            std::lock_guard<std::mutex> lock(g_queueMutex);
            if (!g_audioPoolInitialized) ResetAudioQueueLocked();
            while (!g_readyAudioChunks.empty() &&
                   (g_readyAudioChunks.count >= kMaxQueuedChunks ||
                    g_hostQueueFrames.load() + chunkFrames >
                        kMaxHostQueueFrames)) {
                const size_t discardedIndex = g_readyAudioChunks.pop();
                const size_t discardedFrames =
                    g_audioChunkPool[discardedIndex].frames;
                g_hostQueueFrames.fetch_sub(
                    static_cast<uint32_t>(discardedFrames));
                g_audioChunkPool[discardedIndex].length = 0;
                g_audioChunkPool[discardedIndex].frames = 0;
                g_freeAudioChunks.push(discardedIndex);
                g_droppedChunks.fetch_add(1);
            }
            if (g_freeAudioChunks.empty()) {
                // One buffer may be owned by the transport thread. Reuse the
                // oldest queued buffer instead of allocating on the capture
                // thread or blocking system-audio capture.
                if (g_readyAudioChunks.empty()) {
                    g_droppedChunks.fetch_add(1);
                    offset += chunkLength;
                    continue;
                }
                const size_t discardedIndex = g_readyAudioChunks.pop();
                g_hostQueueFrames.fetch_sub(
                    static_cast<uint32_t>(g_audioChunkPool[discardedIndex].frames));
                g_freeAudioChunks.push(discardedIndex);
                g_droppedChunks.fetch_add(1);
            }
            const size_t chunkIndex = g_freeAudioChunks.pop();
            AudioChunk& chunk = g_audioChunkPool[chunkIndex];
            memcpy(chunk.bytes.data(), data + offset, chunkLength);
            chunk.length = chunkLength;
            chunk.frames = chunkFrames;
            g_readyAudioChunks.push(chunkIndex);
            const uint32_t queuedFrames = g_hostQueueFrames.fetch_add(
                static_cast<uint32_t>(chunkFrames)) +
                static_cast<uint32_t>(chunkFrames);
            UpdateAtomicMaximum(&g_hostQueueHighWaterFrames, queuedFrames);
        }
        g_queueCondition.notify_one();
        offset += chunkLength;
    }
}

void EnqueueSilence(size_t byteCount) {
    static const std::array<uint8_t, kMaxPcmPayload> silence{};
    while (byteCount > 0 && g_captureRunning.load()) {
        size_t length = byteCount < silence.size() ? byteCount : silence.size();
        length -= length % kFrameBytes;
        if (length == 0) return;
        EnqueuePcm(silence.data(), length);
        byteCount -= length;
    }
}

bool ReapThread(HANDLE* thread, DWORD timeoutMilliseconds) {
    if (*thread == nullptr) return true;
    if (WaitForSingleObject(*thread, timeoutMilliseconds) != WAIT_OBJECT_0) return false;
    CloseHandle(*thread);
    *thread = nullptr;
    return true;
}

#if !defined(AUDIOSHARE_FORCE_DEFAULT_ENDPOINT) && \
    !defined(AUDIOSHARE_FORCE_MULTI_ENDPOINT)
class ActivationCompletionHandler final
    : public IActivateAudioInterfaceCompletionHandler {
public:
    ActivationCompletionHandler()
        : completedEvent_(CreateEvent(nullptr, TRUE, FALSE, nullptr)) {}

    bool IsValid() const { return completedEvent_ != nullptr; }

    HRESULT WaitForClient(IAudioClient** audioClient) {
        if (audioClient == nullptr) return E_POINTER;
        *audioClient = nullptr;
        if (completedEvent_ == nullptr) return HRESULT_FROM_WIN32(GetLastError());

        HANDLE waitHandles[2] = {g_stopEvent, completedEvent_};
        const DWORD waitResult = WaitForMultipleObjects(
            2, waitHandles, FALSE, kActivationTimeoutMilliseconds);
        if (waitResult == WAIT_OBJECT_0) {
            return HRESULT_FROM_WIN32(ERROR_CANCELLED);
        }
        if (waitResult == WAIT_TIMEOUT) {
            return HRESULT_FROM_WIN32(ERROR_TIMEOUT);
        }
        if (waitResult != WAIT_OBJECT_0 + 1) {
            return HRESULT_FROM_WIN32(GetLastError());
        }
        std::lock_guard<std::mutex> lock(resultMutex_);
        if (FAILED(activationResult_)) return activationResult_;
        if (audioClient_ == nullptr) return E_NOINTERFACE;
        *audioClient = audioClient_;
        audioClient_ = nullptr;
        return S_OK;
    }

    HRESULT STDMETHODCALLTYPE QueryInterface(REFIID iid, void** object) override {
        if (object == nullptr) return E_POINTER;
        *object = nullptr;
        if (IsEqualIID(iid, IID_IUnknown) ||
            IsEqualIID(iid, __uuidof(IActivateAudioInterfaceCompletionHandler)) ||
            IsEqualIID(iid, IID_IAgileObject)) {
            *object = static_cast<IActivateAudioInterfaceCompletionHandler*>(this);
            AddRef();
            return S_OK;
        }
        return E_NOINTERFACE;
    }

    ULONG STDMETHODCALLTYPE AddRef() override {
        return references_.fetch_add(1) + 1;
    }

    ULONG STDMETHODCALLTYPE Release() override {
        const ULONG remaining = references_.fetch_sub(1) - 1;
        if (remaining == 0) delete this;
        return remaining;
    }

    HRESULT STDMETHODCALLTYPE ActivateCompleted(
        IActivateAudioInterfaceAsyncOperation* operation) override {
        HRESULT activationResult = E_UNEXPECTED;
        IUnknown* activatedInterface = nullptr;
        HRESULT result = operation == nullptr
            ? E_POINTER
            : operation->GetActivateResult(&activationResult, &activatedInterface);
        if (SUCCEEDED(result)) result = activationResult;
        if (SUCCEEDED(result) && activatedInterface != nullptr) {
            IAudioClient* audioClient = nullptr;
            result = activatedInterface->QueryInterface(
                __uuidof(IAudioClient), reinterpret_cast<void**>(&audioClient));
            if (SUCCEEDED(result)) {
                std::lock_guard<std::mutex> lock(resultMutex_);
                audioClient_ = audioClient;
            }
        }
        if (activatedInterface != nullptr) activatedInterface->Release();
        {
            std::lock_guard<std::mutex> lock(resultMutex_);
            activationResult_ = result;
        }
        SetEvent(completedEvent_);
        // Balance the callback-lifetime reference taken before activation.
        Release();
        return S_OK;
    }

private:
    ~ActivationCompletionHandler() {
        if (audioClient_ != nullptr) audioClient_->Release();
        if (completedEvent_ != nullptr) CloseHandle(completedEvent_);
    }

    std::atomic<ULONG> references_{1};
    HANDLE completedEvent_ = nullptr;
    std::mutex resultMutex_;
    HRESULT activationResult_ = E_PENDING;
    IAudioClient* audioClient_ = nullptr;
};

HRESULT ActivateGlobalProcessLoopback(IAudioClient** audioClient) {
    if (audioClient == nullptr) return E_POINTER;
    *audioClient = nullptr;

    AUDIOCLIENT_ACTIVATION_PARAMS audioParams{};
    audioParams.ActivationType = AUDIOCLIENT_ACTIVATION_TYPE_PROCESS_LOOPBACK;
    audioParams.ProcessLoopbackParams.TargetProcessId = GetCurrentProcessId();
    audioParams.ProcessLoopbackParams.ProcessLoopbackMode =
        PROCESS_LOOPBACK_MODE_EXCLUDE_TARGET_PROCESS_TREE;

    PROPVARIANT activationParams{};
    activationParams.vt = VT_BLOB;
    activationParams.blob.cbSize = sizeof(audioParams);
    activationParams.blob.pBlobData = reinterpret_cast<BYTE*>(&audioParams);

    auto* handler = new (std::nothrow) ActivationCompletionHandler();
    if (handler == nullptr) return E_OUTOFMEMORY;
    if (!handler->IsValid()) {
        handler->Release();
        return HRESULT_FROM_WIN32(ERROR_NOT_ENOUGH_MEMORY);
    }

    IActivateAudioInterfaceAsyncOperation* operation = nullptr;
    // Keep the handler alive even if stop/timeout releases the operation before
    // Windows invokes the asynchronous completion callback.
    handler->AddRef();
    HRESULT result = ActivateAudioInterfaceAsync(
        VIRTUAL_AUDIO_DEVICE_PROCESS_LOOPBACK,
        __uuidof(IAudioClient),
        &activationParams,
        handler,
        &operation);
    if (FAILED(result)) handler->Release();
    if (SUCCEEDED(result)) result = handler->WaitForClient(audioClient);
    if (operation != nullptr) operation->Release();
    handler->Release();
    return result;
}
#endif

void FillCanonicalFormat(WAVEFORMATEX* format) {
    *format = {};
    format->wFormatTag = WAVE_FORMAT_PCM;
    format->nChannels = kChannels;
    format->nSamplesPerSec = kSampleRate;
    format->wBitsPerSample = kBitsPerSample;
    format->nBlockAlign = kChannels * (kBitsPerSample / 8);
    format->nAvgBytesPerSec = kSampleRate * format->nBlockAlign;
}

HRESULT InitializeCanonicalLoopback(IAudioClient* audioClient,
                                    const WAVEFORMATEX* format) {
    const DWORD streamFlags = AUDCLNT_STREAMFLAGS_LOOPBACK |
        AUDCLNT_STREAMFLAGS_EVENTCALLBACK |
        AUDCLNT_STREAMFLAGS_AUTOCONVERTPCM |
        AUDCLNT_STREAMFLAGS_SRC_DEFAULT_QUALITY;
    return audioClient->Initialize(
        AUDCLNT_SHAREMODE_SHARED, streamFlags, 0, 0, format, nullptr);
}

#if !defined(AUDIOSHARE_FORCE_DEFAULT_ENDPOINT)
struct EndpointCapture {
    IAudioClient* audioClient = nullptr;
    IAudioCaptureClient* captureClient = nullptr;
    HANDLE captureEvent = nullptr;
    bool audioStarted = false;
    bool hasSeenNonSilentPacket = false;
    uint64_t lastNonSilentPacketMillis = 0;
    // A fixed-capacity ring keeps packet ingestion allocation-free after
    // endpoint setup. The capture thread is the sole owner of these fields.
    std::unique_ptr<int16_t[]> sampleBuffer;
    size_t readSample = 0;
    size_t sampleCount = 0;
};

void CloseEndpoint(EndpointCapture* endpoint) {
    if (endpoint == nullptr) return;
    if (endpoint->audioStarted && endpoint->audioClient != nullptr) {
        endpoint->audioClient->Stop();
    }
    if (endpoint->captureClient != nullptr) {
        endpoint->captureClient->Release();
        endpoint->captureClient = nullptr;
    }
    if (endpoint->audioClient != nullptr) {
        endpoint->audioClient->Release();
        endpoint->audioClient = nullptr;
    }
    if (endpoint->captureEvent != nullptr) {
        CloseHandle(endpoint->captureEvent);
        endpoint->captureEvent = nullptr;
    }
    endpoint->audioStarted = false;
    endpoint->hasSeenNonSilentPacket = false;
    endpoint->lastNonSilentPacketMillis = 0;
    endpoint->sampleBuffer.reset();
    endpoint->readSample = 0;
    endpoint->sampleCount = 0;
}

void CloseEndpoints(std::vector<EndpointCapture>* endpoints) {
    if (endpoints == nullptr) return;
    for (auto& endpoint : *endpoints) CloseEndpoint(&endpoint);
    endpoints->clear();
    g_activeEndpointCount.store(0);
}

HRESULT InitializeEndpoint(IMMDevice* device, const WAVEFORMATEX* format,
                           EndpointCapture* endpoint) {
    if (device == nullptr || format == nullptr || endpoint == nullptr) {
        return E_POINTER;
    }

    endpoint->sampleBuffer.reset(
        new (std::nothrow) int16_t[kEndpointBufferSamples]);
    if (endpoint->sampleBuffer == nullptr) return E_OUTOFMEMORY;

    HRESULT result = device->Activate(
        __uuidof(IAudioClient), CLSCTX_ALL, nullptr,
        reinterpret_cast<void**>(&endpoint->audioClient));
    if (SUCCEEDED(result)) {
        result = InitializeCanonicalLoopback(endpoint->audioClient, format);
    }
    if (SUCCEEDED(result)) {
        endpoint->captureEvent = CreateEvent(nullptr, FALSE, FALSE, nullptr);
        if (endpoint->captureEvent == nullptr) {
            result = HRESULT_FROM_WIN32(GetLastError());
        }
    }
    if (SUCCEEDED(result)) {
        result = endpoint->audioClient->SetEventHandle(endpoint->captureEvent);
    }
    if (SUCCEEDED(result)) {
        result = endpoint->audioClient->GetService(
            __uuidof(IAudioCaptureClient),
            reinterpret_cast<void**>(&endpoint->captureClient));
    }
    if (SUCCEEDED(result)) return S_OK;

    CloseEndpoint(endpoint);
    return result;
}

HRESULT EnumerateActiveEndpoints(IMMDeviceEnumerator* enumerator,
                                 const WAVEFORMATEX* format,
                                 std::vector<EndpointCapture>* endpoints) {
    if (enumerator == nullptr || format == nullptr || endpoints == nullptr) {
        return E_POINTER;
    }
    if (!endpoints->empty()) CloseEndpoints(endpoints);

    IMMDeviceCollection* collection = nullptr;
    HRESULT result = enumerator->EnumAudioEndpoints(
        eRender, DEVICE_STATE_ACTIVE, &collection);
    if (FAILED(result)) return result;

    UINT count = 0;
    result = collection->GetCount(&count);
    HRESULT lastEndpointResult = HRESULT_FROM_WIN32(ERROR_NOT_FOUND);
    if (FAILED(result)) {
        collection->Release();
        return result;
    }

    endpoints->reserve(
        count < kMaxMultiEndpointCount ? count : kMaxMultiEndpointCount);
    const UINT usableCount = count < kMaxMultiEndpointCount
        ? count
        : static_cast<UINT>(kMaxMultiEndpointCount);
    for (UINT index = 0; index < usableCount; ++index) {
        IMMDevice* device = nullptr;
        const HRESULT itemResult = collection->Item(index, &device);
        if (SUCCEEDED(itemResult)) {
            EndpointCapture endpoint;
            lastEndpointResult = InitializeEndpoint(
                device, format, &endpoint);
            if (SUCCEEDED(lastEndpointResult)) {
                endpoints->push_back(std::move(endpoint));
            }
        } else {
            lastEndpointResult = itemResult;
        }
        if (device != nullptr) device->Release();
    }
    collection->Release();

    // Do not start an endpoint while the collection is still being built.
    // Enumeration/activation can take longer than the low-latency ring, and a
    // running early endpoint would accumulate audio before the mixer can drain
    // it. Start the fully initialized set together immediately before return.
    for (auto endpoint = endpoints->begin(); endpoint != endpoints->end();) {
        const HRESULT startResult = endpoint->audioClient->Start();
        if (SUCCEEDED(startResult)) {
            endpoint->audioStarted = true;
            ++endpoint;
        } else {
            lastEndpointResult = startResult;
            CloseEndpoint(&*endpoint);
            endpoint = endpoints->erase(endpoint);
        }
    }

    if (endpoints->empty()) return lastEndpointResult;
    g_activeEndpointCount.store(static_cast<uint32_t>(endpoints->size()));
    return S_OK;
}

HRESULT EnumerateActiveEndpointsWithRetry(
    IMMDeviceEnumerator* enumerator, const WAVEFORMATEX* format,
    std::vector<EndpointCapture>* endpoints) {
    HRESULT result = E_FAIL;
    constexpr int kAttempts = 4;
    for (int attempt = 0; attempt < kAttempts && g_captureRunning.load(); ++attempt) {
        result = EnumerateActiveEndpoints(enumerator, format, endpoints);
        if (SUCCEEDED(result)) return S_OK;
        if (attempt + 1 < kAttempts && g_stopEvent != nullptr) {
            // USB/Bluetooth/default-device transitions can briefly expose no
            // active endpoint. Give the audio service a bounded recovery window
            // before abandoning this mode for the default-output fallback.
            WaitForSingleObject(g_stopEvent, 250);
        }
    }
    return result;
}

class EndpointNotificationClient final : public IMMNotificationClient {
public:
    explicit EndpointNotificationClient(HANDLE changeEvent)
        : changeEvent_(changeEvent) {}

    HRESULT STDMETHODCALLTYPE QueryInterface(REFIID iid, void** object) override {
        if (object == nullptr) return E_POINTER;
        *object = nullptr;
        if (IsEqualIID(iid, IID_IUnknown) ||
            IsEqualIID(iid, __uuidof(IMMNotificationClient))) {
            *object = static_cast<IMMNotificationClient*>(this);
            AddRef();
            return S_OK;
        }
        return E_NOINTERFACE;
    }

    ULONG STDMETHODCALLTYPE AddRef() override {
        return references_.fetch_add(1) + 1;
    }

    ULONG STDMETHODCALLTYPE Release() override {
        const ULONG remaining = references_.fetch_sub(1) - 1;
        if (remaining == 0) delete this;
        return remaining;
    }

    HRESULT STDMETHODCALLTYPE OnDeviceStateChanged(LPCWSTR, DWORD) override {
        SignalChange();
        return S_OK;
    }

    HRESULT STDMETHODCALLTYPE OnDeviceAdded(LPCWSTR) override {
        SignalChange();
        return S_OK;
    }

    HRESULT STDMETHODCALLTYPE OnDeviceRemoved(LPCWSTR) override {
        SignalChange();
        return S_OK;
    }

    HRESULT STDMETHODCALLTYPE OnDefaultDeviceChanged(
        EDataFlow flow, ERole, LPCWSTR) override {
        if (flow == eRender) SignalChange();
        return S_OK;
    }

    HRESULT STDMETHODCALLTYPE OnPropertyValueChanged(
        LPCWSTR, const PROPERTYKEY) override {
        // Volume/mute/name property churn does not require tearing down every
        // loopback client. Device add/remove/state/default notifications and a
        // failed packet read cover the changes that affect endpoint ownership.
        return S_OK;
    }

private:
    ~EndpointNotificationClient() = default;

    void SignalChange() const {
        if (changeEvent_ != nullptr) SetEvent(changeEvent_);
    }

    std::atomic<ULONG> references_{1};
    HANDLE changeEvent_ = nullptr;
};

void AppendEndpointPacket(EndpointCapture* endpoint, const BYTE* data,
                          UINT32 frames, bool silent) {
    if (endpoint == nullptr || endpoint->sampleBuffer == nullptr ||
        frames == 0) return;
    if (!silent && data != nullptr) {
        endpoint->hasSeenNonSilentPacket = true;
        endpoint->lastNonSilentPacketMillis = GetTickCount64();
    }

    size_t firstFrame = 0;
    if (frames > kMaxEndpointQueueFrames) {
        firstFrame = frames - kMaxEndpointQueueFrames;
        g_endpointDroppedFrames.fetch_add(firstFrame);
    }
    const size_t retainedFrames = static_cast<size_t>(frames) - firstFrame;
    const size_t queuedFrames = endpoint->sampleCount / kChannels;
    if (queuedFrames + retainedFrames > kMaxEndpointQueueFrames) {
        const size_t framesToDrop =
            queuedFrames + retainedFrames - kMaxEndpointQueueFrames;
        endpoint->readSample =
            (endpoint->readSample + framesToDrop * kChannels) %
            kEndpointBufferSamples;
        endpoint->sampleCount -= framesToDrop * kChannels;
        g_endpointDroppedFrames.fetch_add(framesToDrop);
    }

    const auto* input = reinterpret_cast<const int16_t*>(data);
    for (size_t frame = firstFrame; frame < frames; ++frame) {
        for (size_t channel = 0; channel < kChannels; ++channel) {
            const size_t writeSample =
                (endpoint->readSample + endpoint->sampleCount) %
                kEndpointBufferSamples;
            endpoint->sampleBuffer[writeSample] =
                silent || input == nullptr
                    ? 0
                    : input[frame * kChannels + channel];
            ++endpoint->sampleCount;
        }
    }
    UpdateAtomicMaximum(
        &g_endpointQueueHighWaterFrames,
        static_cast<uint32_t>(endpoint->sampleCount / kChannels));
}

HRESULT DrainEndpoint(EndpointCapture* endpoint) {
    if (endpoint == nullptr || endpoint->captureClient == nullptr) {
        return E_POINTER;
    }

    UINT32 packetFrames = 0;
    HRESULT result = endpoint->captureClient->GetNextPacketSize(&packetFrames);
    while (SUCCEEDED(result) && packetFrames > 0 && g_captureRunning.load()) {
        BYTE* data = nullptr;
        UINT32 frames = 0;
        DWORD flags = 0;
        result = endpoint->captureClient->GetBuffer(
            &data, &frames, &flags, nullptr, nullptr);
        if (FAILED(result)) break;
        if ((flags & AUDCLNT_BUFFERFLAGS_DATA_DISCONTINUITY) != 0) {
            g_endpointDiscontinuities.fetch_add(1);
        }
        AppendEndpointPacket(
            endpoint, data, frames,
            (flags & AUDCLNT_BUFFERFLAGS_SILENT) != 0);
        const HRESULT releaseResult = endpoint->captureClient->ReleaseBuffer(frames);
        if (FAILED(releaseResult)) return releaseResult;
        result = endpoint->captureClient->GetNextPacketSize(&packetFrames);
    }
    return result;
}

void MixEndpointPeriod(
        std::vector<EndpointCapture>* endpoints, bool catchUpOnly = false) {
    std::array<int32_t, kMixerSamples> accumulator{};
    std::array<int16_t, kMixerSamples> mixed{};
    std::array<uint16_t, kMixerFrames> contributors{};
    const uint64_t nowMillis = GetTickCount64();

    for (auto& endpoint : *endpoints) {
        if (endpoint.sampleBuffer == nullptr) continue;
        const size_t availableFrames = endpoint.sampleCount / kChannels;
        if (catchUpOnly && availableFrames < kMixerFrames * 2) continue;
        const size_t framesToMix = availableFrames < kMixerFrames
            ? availableFrames
            : kMixerFrames;
        if (!catchUpOnly && audioshare::mixer::ShouldCountUnderrun(
                endpoint.hasSeenNonSilentPacket,
                endpoint.lastNonSilentPacketMillis,
                nowMillis,
                framesToMix,
                kMixerFrames)) {
            g_endpointUnderrunFrames.fetch_add(kMixerFrames - framesToMix);
        }
        for (size_t frame = 0; frame < framesToMix; ++frame) {
            ++contributors[frame];
            for (size_t channel = 0; channel < kChannels; ++channel) {
                accumulator[frame * kChannels + channel] +=
                    endpoint.sampleBuffer[endpoint.readSample];
                endpoint.readSample =
                    (endpoint.readSample + 1) % kEndpointBufferSamples;
                --endpoint.sampleCount;
            }
        }
        if (catchUpOnly) g_endpointCatchUpFrames.fetch_add(framesToMix);
    }

    for (size_t frame = 0; frame < kMixerFrames; ++frame) {
        for (size_t channel = 0; channel < kChannels; ++channel) {
            const size_t sample = frame * kChannels + channel;
            mixed[sample] = audioshare::mixer::AverageMixedSample(
                accumulator[sample], contributors[frame]);
        }
    }
    EnqueuePcm(
        reinterpret_cast<const uint8_t*>(mixed.data()),
        mixed.size() * sizeof(mixed[0]));
}

size_t MaximumQueuedEndpointFrames(
    const std::vector<EndpointCapture>& endpoints) {
    size_t maximum = 0;
    for (const auto& endpoint : endpoints) {
        const size_t frames = endpoint.sampleCount / kChannels;
        if (frames > maximum) maximum = frames;
    }
    return maximum;
}

void DrainAllEndpoints(std::vector<EndpointCapture>* endpoints,
                       HANDLE changeEvent) {
    for (auto& endpoint : *endpoints) {
        if (FAILED(DrainEndpoint(&endpoint))) {
            // Device invalidation can race the periodic tick even before the
            // notification callback arrives. Defer teardown/rebuild to the
            // capture thread's normal change-event branch.
            if (changeEvent != nullptr) SetEvent(changeEvent);
            return;
        }
    }
}

HRESULT RunMultiEndpointCapture(const WAVEFORMATEX* format) {
    IMMDeviceEnumerator* enumerator = nullptr;
    EndpointNotificationClient* notification = nullptr;
    HANDLE changeEvent = nullptr;
    HANDLE mixerTimer = nullptr;
    bool notificationRegistered = false;
    std::vector<EndpointCapture> endpoints;

    HRESULT result = CoCreateInstance(
        __uuidof(MMDeviceEnumerator), nullptr, CLSCTX_ALL,
        __uuidof(IMMDeviceEnumerator),
        reinterpret_cast<void**>(&enumerator));
    if (FAILED(result)) return result;

    changeEvent = CreateEvent(nullptr, FALSE, FALSE, nullptr);
    // A default-resolution 10 ms periodic timer can be rounded to the legacy
    // 15.6 ms scheduler tick. Input then arrives faster than the mixer drains
    // it, eventually overflowing the bounded ring. The process targets modern
    // Windows, where this per-timer high-resolution flag is available; failure
    // cleanly abandons this mode and lets the caller try default-endpoint
    // loopback instead of knowingly streaming damaged audio.
    mixerTimer = CreateWaitableTimerExW(
        nullptr, nullptr, kHighResolutionTimerFlag, TIMER_ALL_ACCESS);
    if (changeEvent == nullptr || mixerTimer == nullptr) {
        result = HRESULT_FROM_WIN32(GetLastError());
    }
    if (SUCCEEDED(result)) {
        notification = new (std::nothrow) EndpointNotificationClient(changeEvent);
        if (notification == nullptr) result = E_OUTOFMEMORY;
    }
    if (SUCCEEDED(result)) {
        result = enumerator->RegisterEndpointNotificationCallback(notification);
        notificationRegistered = SUCCEEDED(result);
    }
    if (SUCCEEDED(result)) {
        result = EnumerateActiveEndpointsWithRetry(
            enumerator, format, &endpoints);
    }
    if (SUCCEEDED(result)) {
        LARGE_INTEGER firstTick{};
        firstTick.QuadPart =
            -static_cast<LONGLONG>(kMixerPeriodMilliseconds) * 10000;
        if (!SetWaitableTimer(
                mixerTimer, &firstTick,
                static_cast<LONG>(kMixerPeriodMilliseconds),
                nullptr, nullptr, FALSE)) {
            result = HRESULT_FROM_WIN32(GetLastError());
        }
    }
    if (SUCCEEDED(result)) {
        g_captureMode.store(
            static_cast<uint32_t>(CaptureMode::kMultiEndpointLoopback));
    }

    std::vector<HANDLE> waitHandles;
    waitHandles.reserve(kMaxMultiEndpointCount + 3);
    while (SUCCEEDED(result) && g_captureRunning.load()) {
        waitHandles.clear();
        waitHandles.push_back(g_stopEvent);
        waitHandles.push_back(changeEvent);
        // WaitForMultipleObjects returns the lowest-index signaled handle.
        // Keep the periodic mixer ahead of endpoint notifications so a
        // continuously active render endpoint cannot starve mixing and fill
        // the bounded per-endpoint ring. The timer branch drains every
        // endpoint before it mixes the next period.
        const size_t timerIndex = waitHandles.size();
        waitHandles.push_back(mixerTimer);
        const size_t endpointStartIndex = waitHandles.size();
        for (const auto& endpoint : endpoints) {
            waitHandles.push_back(endpoint.captureEvent);
        }

        const DWORD waitResult = WaitForMultipleObjects(
            static_cast<DWORD>(waitHandles.size()), waitHandles.data(),
            FALSE, 2000);
        if (waitResult == WAIT_OBJECT_0) {
            result = S_OK;
            break;
        }
        if (waitResult == WAIT_TIMEOUT) continue;
        if (waitResult == WAIT_FAILED) {
            result = HRESULT_FROM_WIN32(GetLastError());
            break;
        }

        const size_t signaledIndex = waitResult - WAIT_OBJECT_0;
        if (signaledIndex == 1) {
            CloseEndpoints(&endpoints);
            g_endpointRebuildCount.fetch_add(1);
            result = EnumerateActiveEndpointsWithRetry(
                enumerator, format, &endpoints);
        } else if (signaledIndex == timerIndex) {
            // Event handles are the normal wake-up mechanism. Polling once per
            // mixer period is intentional as a compatibility guard for older
            // loopback implementations that initialize successfully but do not
            // signal an event until a render client advances the stream.
            DrainAllEndpoints(&endpoints, changeEvent);
            MixEndpointPeriod(&endpoints);
            // A scheduler wake can span more than one 10 ms audio period.
            // Drain a bounded number of additional complete periods while
            // retaining one period as jitter cushion. This follows the audio
            // clock over time without allowing a slow timer wake to grow into
            // ring loss or unbounded transport bursts.
            constexpr size_t kMaximumCatchUpPeriods = 4;
            for (size_t period = 0;
                 period < kMaximumCatchUpPeriods &&
                 MaximumQueuedEndpointFrames(endpoints) >=
                     kMixerFrames * 2;
                 ++period) {
                // Catch up only endpoints that individually accumulated at
                // least two periods. A faster device must not drain a slower
                // device and fabricate underruns merely because their hardware
                // clocks differ.
                MixEndpointPeriod(&endpoints, true);
            }
        } else if (signaledIndex >= endpointStartIndex &&
                   signaledIndex < waitHandles.size()) {
            result = DrainEndpoint(
                &endpoints[signaledIndex - endpointStartIndex]);
            if (FAILED(result)) {
                SetEvent(changeEvent);
                result = S_OK;
            }
        } else {
            result = E_UNEXPECTED;
        }
    }

    CloseEndpoints(&endpoints);
    if (notificationRegistered) {
        enumerator->UnregisterEndpointNotificationCallback(notification);
    }
    if (notification != nullptr) notification->Release();
    if (mixerTimer != nullptr) {
        CancelWaitableTimer(mixerTimer);
        CloseHandle(mixerTimer);
    }
    if (changeEvent != nullptr) CloseHandle(changeEvent);
    enumerator->Release();
    return result;
}
#endif

SOCKET ConnectLoopbackOnce(int port) {
    SOCKET socket = ::socket(AF_INET, SOCK_STREAM, IPPROTO_TCP);
    if (socket == INVALID_SOCKET) return INVALID_SOCKET;
    int one = 1;
    int timeout = 5000;
    setsockopt(socket, IPPROTO_TCP, TCP_NODELAY,
        reinterpret_cast<const char*>(&one), sizeof(one));
    setsockopt(socket, SOL_SOCKET, SO_SNDTIMEO,
        reinterpret_cast<const char*>(&timeout), sizeof(timeout));
    setsockopt(socket, SOL_SOCKET, SO_RCVTIMEO,
        reinterpret_cast<const char*>(&timeout), sizeof(timeout));
    sockaddr_in address{};
    address.sin_family = AF_INET;
    address.sin_port = htons(static_cast<u_short>(port));
    address.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    if (connect(socket, reinterpret_cast<sockaddr*>(&address),
                sizeof(address)) == 0) {
        return socket;
    }
    closesocket(socket);
    return INVALID_SOCKET;
}

DWORD WINAPI TransportThread(LPVOID) {
    int port = 0;
    uint8_t token[kTokenBytes]{};
    ConnectCallback callback = nullptr;
    {
        std::lock_guard<std::mutex> lock(g_configMutex);
        port = g_pendingPort;
        memcpy(token, g_pendingToken, sizeof(token));
        callback = g_connectCallback;
    }

    const auto hello = EncodeHello(
        token, kSampleRate, static_cast<uint8_t>(kChannels),
        static_cast<uint8_t>(kBitsPerSample));
    SOCKET socket = INVALID_SOCKET;
    ReceivedFrame ready;
    ReadyPayload accepted;
    bool handshakeComplete = false;
    bool fatalHandshakeError = false;
    const auto handshakeDeadline =
        std::chrono::steady_clock::now() + std::chrono::seconds(8);

    // An ADB forward's localhost listener can accept before Android has
    // created the target LocalServerSocket. In that window TCP connect
    // succeeds and adbd immediately closes the stream. Retry the complete
    // connect + HELLO + READY transaction, not just the TCP connect call.
    while (g_transportRunning.load() &&
           std::chrono::steady_clock::now() < handshakeDeadline) {
        socket = ConnectLoopbackOnce(port);
        if (socket != INVALID_SOCKET) {
            g_transportSocket.store(socket);
            // Stop can race between the loop condition, connect(), and the
            // atomic publication above. Recheck after publication so Stop can
            // never miss a newly created socket and leave this worker blocked
            // in a handshake receive timeout.
            if (!g_transportRunning.load()) {
                CloseTransportSocket();
                socket = INVALID_SOCKET;
                break;
            }
            if (SendFrame(socket, kTypeHello, 1, hello.data(), hello.size()) &&
                ReceiveFrame(socket, &ready)) {
                if (ready.type == kTypeError) {
                    const std::string detail = SanitizeAndroidError(ready.payload);
                    SetError(2107, detail.empty()
                        ? "Android rejected the protocol handshake"
                        : "Android handshake error: " + detail);
                    fatalHandshakeError = true;
                } else if (ready.type != kTypeReady) {
                    SetError(2102, "Android returned an unexpected handshake message");
                    fatalHandshakeError = true;
                } else if (!DecodeReady(
                               ready.payload.data(), ready.payload.size(),
                               &accepted) ||
                           ready.sequence != 1 ||
                           accepted.sampleRate != kSampleRate ||
                           accepted.channels != kChannels ||
                           accepted.bitsPerSample != kBitsPerSample ||
                           accepted.bufferFrames == 0 ||
                           accepted.bufferFrames > kSampleRate * 5) {
                    SetError(2109,
                        "Android accepted an invalid or incompatible audio format");
                    fatalHandshakeError = true;
                } else {
                    handshakeComplete = true;
                }
            }
            if (handshakeComplete) break;
            CloseTransportSocket();
            socket = INVALID_SOCKET;
            if (fatalHandshakeError) break;
        }
        Sleep(100);
    }

    if (!handshakeComplete) {
        if (g_transportRunning.load()) {
            SetErrorIfNone(
                2102,
                "Android receiver did not complete the ADB-forward handshake");
        }
        CloseTransportSocket();
        g_transportRunning.store(false);
        if (callback != nullptr && g_callbackAllowed.exchange(false)) {
            callback("error");
        }
        return 1;
    }
    g_androidBufferFrames.store(accepted.bufferFrames);

    g_connected.store(true);
    if (callback != nullptr && g_callbackAllowed.exchange(false)) {
        callback("ready");
    }
    uint32_t sequence = 2;
    uint32_t lastInboundSequence = ready.sequence;
    auto nextPing = std::chrono::steady_clock::now() + std::chrono::seconds(3);
    auto lastAndroidResponse = std::chrono::steady_clock::now();
    uint32_t pendingStatsSequence = 0;
    auto pendingStatsSent = std::chrono::steady_clock::time_point{};
    while (g_transportRunning.load()) {
        size_t chunkIndex = g_audioChunkPool.size();
        {
            std::unique_lock<std::mutex> lock(g_queueMutex);
            g_queueCondition.wait_for(lock, std::chrono::milliseconds(100), [] {
                return !g_readyAudioChunks.empty() || !g_transportRunning.load();
            });
            if (!g_readyAudioChunks.empty()) {
                chunkIndex = g_readyAudioChunks.pop();
                g_hostQueueFrames.fetch_sub(static_cast<uint32_t>(
                    g_audioChunkPool[chunkIndex].frames));
            }
        }
        if (chunkIndex < g_audioChunkPool.size()) {
            AudioChunk& chunk = g_audioChunkPool[chunkIndex];
            const bool sent = SendFrame(
                socket, kTypePcm, sequence++, chunk.bytes.data(), chunk.length);
            {
                std::lock_guard<std::mutex> lock(g_queueMutex);
                chunk.length = 0;
                chunk.frames = 0;
                g_freeAudioChunks.push(chunkIndex);
            }
            if (!sent) {
                if (g_transportRunning.load()) {
                    SetError(2103, "Audio transport write failed");
                }
                break;
            }
        }
        const auto now = std::chrono::steady_clock::now();
        if (now >= nextPing && pendingStatsSequence == 0) {
            pendingStatsSequence = sequence++;
            pendingStatsSent = now;
            if (!SendFrame(socket, kTypeStats, pendingStatsSequence, nullptr, 0)) {
                if (g_transportRunning.load()) SetError(2106, "Android heartbeat write failed");
                break;
            }
            nextPing = now + std::chrono::seconds(3);
        }
        fd_set readSet;
        FD_ZERO(&readSet);
        FD_SET(socket, &readSet);
        timeval noWait{};
        const int selected = select(0, &readSet, nullptr, nullptr, &noWait);
        if (selected == SOCKET_ERROR) {
            if (g_transportRunning.load()) {
                SetError(2111, "Android transport readiness check failed");
            }
            break;
        }
        if (selected > 0 && FD_ISSET(socket, &readSet)) {
            ReceivedFrame inbound;
            if (!ReceiveFrame(socket, &inbound)) break;
            lastAndroidResponse = std::chrono::steady_clock::now();
            // ERROR is terminal and may use the reserved sequence 0 so a
            // playback failure can be reported even when it occurred outside
            // the normal request/response sequence. Handle it before the
            // monotonic check rather than masking the useful diagnostic.
            if (inbound.type == kTypeError) {
                const std::string detail = SanitizeAndroidError(inbound.payload);
                SetError(2107, detail.empty()
                    ? "Android reported a playback error"
                    : "Android playback error: " + detail);
                break;
            }
            if (!IsStrictlyIncreasingSequence(
                    lastInboundSequence, inbound.sequence)) {
                SetError(2115, "Android returned a non-increasing sequence");
                break;
            }
            lastInboundSequence = inbound.sequence;
            if (inbound.type == kTypeStats) {
                if (pendingStatsSequence == 0 ||
                    inbound.sequence != pendingStatsSequence) {
                    SetError(2114, "Android returned an unexpected STATS sequence");
                    break;
                }
                PlaybackStats stats;
                if (!DecodePlaybackStats(
                        inbound.payload.data(), inbound.payload.size(), &stats)) {
                    SetError(2110, "Android returned invalid playback statistics");
                    break;
                }
                g_androidReceivedFrames.store(stats.receivedFrames);
                g_androidDroppedFrames.store(stats.droppedFrames);
                g_androidQueueDepth.store(stats.queueDepth);
                g_androidBufferFrames.store(stats.bufferFrames);
                g_androidQueueFrames.store(stats.queueFrames);
                g_androidBufferCapacityFrames.store(
                    stats.bufferCapacityFrames);
                g_androidStartThresholdFrames.store(
                    stats.startThresholdFrames);
                g_androidUnderrunCount.store(stats.underrunCount);
                g_androidRoutedDeviceType.store(stats.routedDeviceType);
                g_androidFocusState.store(stats.focusState);
                g_androidMediaVolume.store(stats.mediaVolume);
                g_androidMediaVolumeMax.store(stats.mediaVolumeMax);
                g_androidQueueHighWaterFrames.store(
                    stats.queueHighWaterFrames);
                const auto rtt = std::chrono::duration_cast<
                    std::chrono::milliseconds>(
                        lastAndroidResponse - pendingStatsSent).count();
                g_heartbeatRttMilliseconds.store(static_cast<uint32_t>(
                    rtt < 0 ? 0 : (rtt > UINT32_MAX ? UINT32_MAX : rtt)));
                pendingStatsSequence = 0;
            } else if (inbound.type != kTypePong) {
                SetError(2108, "Android sent an unexpected protocol message");
                break;
            }
        }
        if (now - lastAndroidResponse >= std::chrono::seconds(10)) {
            SetError(2113, "Android playback heartbeat timed out");
            break;
        }
    }

    if (g_transportRunning.load()) {
        SetErrorIfNone(2112, "Android USB audio transport closed unexpectedly");
    }
    g_connected.store(false);
    g_transportRunning.store(false);
    g_captureRunning.store(false);
    if (g_stopEvent != nullptr) SetEvent(g_stopEvent);
    CloseTransportSocket();
    g_queueCondition.notify_all();
    return 0;
}

DWORD WINAPI CaptureThread(LPVOID) {
    HRESULT result = CoInitializeEx(nullptr, COINIT_MULTITHREADED);
    const bool comInitialized = SUCCEEDED(result);
    if (FAILED(result) && result != RPC_E_CHANGED_MODE) {
        SetError(2200, HresultMessage("CoInitializeEx", result));
        g_captureRunning.store(false);
        return 1;
    }

    IMMDeviceEnumerator* enumerator = nullptr;
    IMMDevice* device = nullptr;
    IAudioClient* audioClient = nullptr;
    IAudioCaptureClient* captureClient = nullptr;
    HANDLE captureEvent = nullptr;
    bool audioStarted = false;
    DWORD exitCode = 1;
    HRESULT globalResult = E_NOTIMPL;
    HRESULT multiEndpointResult = E_NOTIMPL;
    CaptureMode selectedMode = CaptureMode::kNone;

    do {
        WAVEFORMATEX format{};
        FillCanonicalFormat(&format);

        // Preferred mode: Windows' endpoint-independent process loopback,
        // excluding this host process tree. Activation is the feature probe;
        // version strings are intentionally not used as a gate.
#if defined(AUDIOSHARE_FORCE_DEFAULT_ENDPOINT) || \
    defined(AUDIOSHARE_FORCE_MULTI_ENDPOINT)
        globalResult = E_NOTIMPL;
#else
        globalResult = ActivateGlobalProcessLoopback(&audioClient);
#endif
        if (SUCCEEDED(globalResult)) {
            globalResult = InitializeCanonicalLoopback(audioClient, &format);
        }
        g_globalLoopbackHresult.store(globalResult);
        if (SUCCEEDED(globalResult)) {
            selectedMode = CaptureMode::kGlobalProcessLoopback;
        } else {
            if (!g_captureRunning.load()) {
                exitCode = 0;
                break;
            }
            if (audioClient != nullptr) {
                audioClient->Release();
                audioClient = nullptr;
            }

#if !defined(AUDIOSHARE_FORCE_DEFAULT_ENDPOINT)
            // Compatibility mode for Windows versions without global process
            // loopback: capture each active render endpoint and mix them on a
            // bounded 10 ms host clock. The routine owns device-change rebuilds
            // and returns only on stop or if the whole mode becomes unusable.
            multiEndpointResult = RunMultiEndpointCapture(&format);
            if (SUCCEEDED(multiEndpointResult)) {
                exitCode = 0;
                break;
            }
            g_captureMode.store(static_cast<uint32_t>(CaptureMode::kNone));
#endif

            // Last-resort compatibility mode: this captures every normal stream
            // routed through the current default render endpoint.
            result = CoCreateInstance(
                __uuidof(MMDeviceEnumerator), nullptr, CLSCTX_ALL,
                __uuidof(IMMDeviceEnumerator),
                reinterpret_cast<void**>(&enumerator));
            if (FAILED(result)) {
                SetError(2201, HresultMessage(
                    "Create default audio device enumerator", result));
                break;
            }
            result = enumerator->GetDefaultAudioEndpoint(eRender, eConsole, &device);
            if (FAILED(result)) {
                SetError(2202, HresultMessage(
                    "Get default Windows render endpoint", result));
                break;
            }
            result = device->Activate(
                __uuidof(IAudioClient), CLSCTX_ALL, nullptr,
                reinterpret_cast<void**>(&audioClient));
            if (FAILED(result)) {
                SetError(2203, HresultMessage(
                    "Activate default-endpoint WASAPI client", result));
                break;
            }
            result = InitializeCanonicalLoopback(audioClient, &format);
            if (FAILED(result)) {
                std::string message = HresultMessage(
                    "Initialize 48 kHz default-endpoint loopback", result);
                message += "; global process loopback was unavailable (HRESULT 0x";
                char globalCode[16]{};
                _snprintf_s(globalCode, sizeof(globalCode), _TRUNCATE, "%08lX",
                    static_cast<unsigned long>(globalResult));
                message += globalCode;
                message += "); multi-endpoint loopback was unavailable (HRESULT 0x";
                char multiEndpointCode[16]{};
                _snprintf_s(
                    multiEndpointCode, sizeof(multiEndpointCode), _TRUNCATE,
                    "%08lX", static_cast<unsigned long>(multiEndpointResult));
                message += multiEndpointCode;
                message += ")";
                SetError(2204, message);
                break;
            }
            selectedMode = CaptureMode::kDefaultEndpointLoopback;
        }

        captureEvent = CreateEvent(nullptr, FALSE, FALSE, nullptr);
        if (captureEvent == nullptr) { SetError(2205, "Could not create the WASAPI capture event"); break; }
        result = audioClient->SetEventHandle(captureEvent);
        if (FAILED(result)) { SetError(2206, HresultMessage("Set WASAPI event handle", result)); break; }
        result = audioClient->GetService(__uuidof(IAudioCaptureClient),
            reinterpret_cast<void**>(&captureClient));
        if (FAILED(result)) { SetError(2207, HresultMessage("Get WASAPI capture service", result)); break; }
        result = audioClient->Start();
        if (FAILED(result)) { SetError(2208, HresultMessage("Start system audio capture", result)); break; }
        audioStarted = true;
        // Publish readiness only after WASAPI is actually running. The Dart
        // supervisor treats a non-zero mode as the streaming-ready signal.
        g_captureMode.store(static_cast<uint32_t>(selectedMode));
        exitCode = 0;

        HANDLE waitHandles[2] = {g_stopEvent, captureEvent};
        while (g_captureRunning.load()) {
            const DWORD waitResult = WaitForMultipleObjects(2, waitHandles, FALSE, 2000);
            if (waitResult == WAIT_OBJECT_0) break;
            if (waitResult == WAIT_TIMEOUT) continue;
            if (waitResult != WAIT_OBJECT_0 + 1) { SetError(2209, "WASAPI capture wait failed"); exitCode = 1; break; }

            UINT32 packetFrames = 0;
            result = captureClient->GetNextPacketSize(&packetFrames);
            while (SUCCEEDED(result) && packetFrames > 0 && g_captureRunning.load()) {
                BYTE* data = nullptr;
                UINT32 frames = 0;
                DWORD flags = 0;
                result = captureClient->GetBuffer(&data, &frames, &flags, nullptr, nullptr);
                if (FAILED(result)) break;
                const size_t byteCount = static_cast<size_t>(frames) * format.nBlockAlign;
                if ((flags & AUDCLNT_BUFFERFLAGS_SILENT) != 0 || data == nullptr) {
                    EnqueueSilence(byteCount);
                } else {
                    EnqueuePcm(data, byteCount);
                }
                const HRESULT releaseResult = captureClient->ReleaseBuffer(frames);
                if (FAILED(releaseResult)) { result = releaseResult; break; }
                result = captureClient->GetNextPacketSize(&packetFrames);
            }
            if (FAILED(result)) { SetError(2210, HresultMessage("Read WASAPI packet", result)); exitCode = 1; break; }
        }
    } while (false);

    if (audioStarted) audioClient->Stop();
    if (captureClient != nullptr) captureClient->Release();
    if (audioClient != nullptr) audioClient->Release();
    if (device != nullptr) device->Release();
    if (enumerator != nullptr) enumerator->Release();
    if (captureEvent != nullptr) CloseHandle(captureEvent);
    if (comInitialized) CoUninitialize();
    g_captureRunning.store(false);
    g_captureMode.store(static_cast<uint32_t>(CaptureMode::kNone));
    g_activeEndpointCount.store(0);
    return exitCode;
}

}  // namespace

extern "C" __declspec(dllexport) int AudioCapture_Initialize() {
    if (g_initialized.load()) return 1;
    ClearError();
    if (WSAStartup(MAKEWORD(2, 2), &g_wsaData) != 0) { SetError(2000, "Could not initialize Winsock"); return 0; }
    g_stopEvent = CreateEvent(nullptr, TRUE, FALSE, nullptr);
    if (g_stopEvent == nullptr) { WSACleanup(); SetError(2001, "Could not create the native stop event"); return 0; }
    g_initialized.store(true);
    return 1;
}

extern "C" __declspec(dllexport) int AudioCapture_Connect(int port, const char* tokenHex,
                                                           ConnectCallback callback) {
    if (!g_initialized.load()) { SetError(2008, "Native audio transport is not initialized"); return 0; }
    if (port < 1 || port > 65535) { SetError(2009, "Invalid ADB forwarded port"); return 0; }
    if (callback == nullptr) { SetError(2010, "Native connection callback is missing"); return 0; }
    ClearError();
    uint8_t token[kTokenBytes]{};
    if (!DecodeToken(tokenHex, token)) { SetError(2002, "Invalid native session token"); return 0; }

    g_captureRunning.store(false);
    g_transportRunning.store(false);
    g_callbackAllowed.store(false);
    if (g_stopEvent != nullptr) SetEvent(g_stopEvent);
    CloseTransportSocket();
    g_queueCondition.notify_all();
    if (!ReapThread(&g_captureThread, 2000) || !ReapThread(&g_transportThread, 2000)) {
        SetError(2003, "Previous native session did not stop in time");
        return 0;
    }
    ClearQueue();
    g_droppedChunks.store(0);
    g_androidReceivedFrames.store(0);
    g_androidDroppedFrames.store(0);
    g_androidQueueDepth.store(0);
    g_androidBufferFrames.store(0);
    g_androidQueueFrames.store(0);
    g_androidBufferCapacityFrames.store(0);
    g_androidStartThresholdFrames.store(0);
    g_androidUnderrunCount.store(0);
    g_androidRoutedDeviceType.store(0);
    g_androidFocusState.store(0);
    g_androidMediaVolume.store(0);
    g_androidMediaVolumeMax.store(0);
    g_androidQueueHighWaterFrames.store(0);
    g_hostQueueHighWaterFrames.store(0);
    g_transportBytesSent.store(0);
    g_heartbeatRttMilliseconds.store(0);
    g_captureMode.store(static_cast<uint32_t>(CaptureMode::kNone));
    g_globalLoopbackHresult.store(S_OK);
    g_activeEndpointCount.store(0);
    g_endpointDroppedFrames.store(0);
    g_endpointUnderrunFrames.store(0);
    g_endpointDiscontinuities.store(0);
    g_endpointRebuildCount.store(0);
    g_endpointCatchUpFrames.store(0);
    g_endpointQueueHighWaterFrames.store(0);
    g_connected.store(false);
    if (g_stopEvent != nullptr) ResetEvent(g_stopEvent);
    {
        std::lock_guard<std::mutex> lock(g_configMutex);
        g_pendingPort = port;
        memcpy(g_pendingToken, token, sizeof(token));
        g_connectCallback = callback;
    }
    g_transportRunning.store(true);
    g_callbackAllowed.store(true);
    g_transportThread = CreateThread(nullptr, 0, TransportThread, nullptr, 0, nullptr);
    if (g_transportThread == nullptr) {
        g_callbackAllowed.store(false);
        g_transportRunning.store(false);
        SetError(2004, "Could not create the native transport thread");
        return 0;
    }
    return 1;
}

extern "C" __declspec(dllexport) int AudioCapture_Start() {
    if (!g_initialized.load()) { SetError(2011, "Native audio capture is not initialized"); return 0; }
    if (!g_connected.load() || !g_transportRunning.load()) {
        SetError(2012, "Android transport is not ready for audio capture");
        return 0;
    }
    if (g_captureRunning.load()) {
        ClearError();
        return 1;
    }
    ClearError();
    if (g_captureThread != nullptr && !ReapThread(&g_captureThread, 1000)) {
        SetError(2005, "Previous capture thread did not stop in time");
        return 0;
    }
    // Discard stale queued audio without resetting the pool: the transport
    // thread is still alive and may own one in-flight chunk.
    DiscardQueuedAudio();
    if (g_stopEvent != nullptr) ResetEvent(g_stopEvent);
    // Closing the transport and starting capture can race on different
    // threads. Recheck after ResetEvent so an already-signaled transport stop
    // cannot be accidentally consumed by a new capture worker.
    if (!g_connected.load() || !g_transportRunning.load()) {
        if (g_stopEvent != nullptr) SetEvent(g_stopEvent);
        SetError(
            2012,
            "Android transport stopped before audio capture could start");
        return 0;
    }
    g_captureRunning.store(true);
    g_captureThread = CreateThread(nullptr, 0, CaptureThread, nullptr, 0, nullptr);
    if (g_captureThread == nullptr) {
        g_captureRunning.store(false);
        SetError(2006, "Could not create the WASAPI capture thread");
        return 0;
    }
    return 1;
}

extern "C" __declspec(dllexport) void AudioCapture_Stop() {
    g_callbackAllowed.store(false);
    g_captureRunning.store(false);
    g_captureMode.store(static_cast<uint32_t>(CaptureMode::kNone));
    g_activeEndpointCount.store(0);
    g_transportRunning.store(false);
    g_connected.store(false);
    if (g_stopEvent != nullptr) SetEvent(g_stopEvent);
    CloseTransportSocket();
    g_queueCondition.notify_all();
    const bool captureStopped = ReapThread(&g_captureThread, 250);
    const bool transportStopped = ReapThread(&g_transportThread, 250);
    if (captureStopped && transportStopped) ClearQueue();
}

extern "C" __declspec(dllexport) void AudioCapture_Cleanup() {
    AudioCapture_Stop();
    const bool captureStopped = ReapThread(&g_captureThread, 3000);
    const bool transportStopped = ReapThread(&g_transportThread, 3000);
    if (!captureStopped || !transportStopped) {
        SetError(2007, "Native worker did not stop; shared resources were retained safely");
        return;
    }
    ClearQueue();
    if (g_stopEvent != nullptr) { CloseHandle(g_stopEvent); g_stopEvent = nullptr; }
    if (g_initialized.exchange(false)) WSACleanup();
    std::lock_guard<std::mutex> lock(g_configMutex);
    g_connectCallback = nullptr;
    memset(g_pendingToken, 0, sizeof(g_pendingToken));
}

extern "C" __declspec(dllexport) int AudioCapture_GetLastErrorCode() {
    std::lock_guard<std::mutex> lock(g_errorMutex);
    return g_lastErrorCode;
}

extern "C" __declspec(dllexport) const char* AudioCapture_GetLastErrorMessage() {
    static thread_local char snapshot[sizeof(g_lastErrorMessage)]{};
    std::lock_guard<std::mutex> lock(g_errorMutex);
    memcpy(snapshot, g_lastErrorMessage, sizeof(snapshot));
    snapshot[sizeof(snapshot) - 1] = '\0';
    return snapshot;
}

extern "C" __declspec(dllexport) void AudioCapture_ClearLastError() {
    ClearError();
}

extern "C" __declspec(dllexport) unsigned long long AudioCapture_GetDroppedChunks() {
    return static_cast<unsigned long long>(g_droppedChunks.load());
}

extern "C" __declspec(dllexport) unsigned long long AudioCapture_GetAndroidReceivedFrames() {
    return static_cast<unsigned long long>(g_androidReceivedFrames.load());
}

extern "C" __declspec(dllexport) unsigned long long AudioCapture_GetAndroidDroppedFrames() {
    return static_cast<unsigned long long>(g_androidDroppedFrames.load());
}

extern "C" __declspec(dllexport) unsigned int AudioCapture_GetAndroidQueueDepth() {
    return static_cast<unsigned int>(g_androidQueueDepth.load());
}

extern "C" __declspec(dllexport) unsigned int AudioCapture_GetAndroidBufferFrames() {
    return static_cast<unsigned int>(g_androidBufferFrames.load());
}

extern "C" __declspec(dllexport) unsigned int AudioCapture_GetAndroidQueueFrames() {
    return static_cast<unsigned int>(g_androidQueueFrames.load());
}

extern "C" __declspec(dllexport) unsigned int AudioCapture_GetAndroidBufferCapacityFrames() {
    return static_cast<unsigned int>(g_androidBufferCapacityFrames.load());
}

extern "C" __declspec(dllexport) unsigned int AudioCapture_GetAndroidStartThresholdFrames() {
    return static_cast<unsigned int>(g_androidStartThresholdFrames.load());
}

extern "C" __declspec(dllexport) unsigned int AudioCapture_GetAndroidUnderrunCount() {
    return static_cast<unsigned int>(g_androidUnderrunCount.load());
}

extern "C" __declspec(dllexport) unsigned int AudioCapture_GetAndroidRoutedDeviceType() {
    return static_cast<unsigned int>(g_androidRoutedDeviceType.load());
}

extern "C" __declspec(dllexport) unsigned int AudioCapture_GetAndroidFocusState() {
    return static_cast<unsigned int>(g_androidFocusState.load());
}

extern "C" __declspec(dllexport) unsigned int AudioCapture_GetAndroidMediaVolume() {
    return static_cast<unsigned int>(g_androidMediaVolume.load());
}

extern "C" __declspec(dllexport) unsigned int AudioCapture_GetAndroidMediaVolumeMax() {
    return static_cast<unsigned int>(g_androidMediaVolumeMax.load());
}

extern "C" __declspec(dllexport) unsigned int AudioCapture_GetAndroidQueueHighWaterFrames() {
    return static_cast<unsigned int>(g_androidQueueHighWaterFrames.load());
}

extern "C" __declspec(dllexport) unsigned int AudioCapture_GetHostQueueFrames() {
    return static_cast<unsigned int>(g_hostQueueFrames.load());
}

extern "C" __declspec(dllexport) unsigned int AudioCapture_GetHostQueueHighWaterFrames() {
    return static_cast<unsigned int>(g_hostQueueHighWaterFrames.load());
}

extern "C" __declspec(dllexport) unsigned long long AudioCapture_GetTransportBytesSent() {
    return static_cast<unsigned long long>(g_transportBytesSent.load());
}

extern "C" __declspec(dllexport) unsigned int AudioCapture_GetHeartbeatRttMilliseconds() {
    return static_cast<unsigned int>(g_heartbeatRttMilliseconds.load());
}

extern "C" __declspec(dllexport) unsigned int AudioCapture_GetCaptureMode() {
    return static_cast<unsigned int>(g_captureMode.load());
}

extern "C" __declspec(dllexport) long AudioCapture_GetGlobalLoopbackHresult() {
    return g_globalLoopbackHresult.load();
}

extern "C" __declspec(dllexport) unsigned int AudioCapture_GetActiveEndpointCount() {
    return static_cast<unsigned int>(g_activeEndpointCount.load());
}

extern "C" __declspec(dllexport) unsigned long long AudioCapture_GetEndpointDroppedFrames() {
    return static_cast<unsigned long long>(g_endpointDroppedFrames.load());
}

extern "C" __declspec(dllexport) unsigned long long AudioCapture_GetEndpointUnderrunFrames() {
    return static_cast<unsigned long long>(g_endpointUnderrunFrames.load());
}

extern "C" __declspec(dllexport) unsigned long long AudioCapture_GetEndpointDiscontinuities() {
    return static_cast<unsigned long long>(g_endpointDiscontinuities.load());
}

extern "C" __declspec(dllexport) unsigned int AudioCapture_GetEndpointRebuildCount() {
    return static_cast<unsigned int>(g_endpointRebuildCount.load());
}

extern "C" __declspec(dllexport) unsigned long long AudioCapture_GetEndpointCatchUpFrames() {
    return static_cast<unsigned long long>(g_endpointCatchUpFrames.load());
}

extern "C" __declspec(dllexport) unsigned int AudioCapture_GetEndpointQueueHighWaterFrames() {
    return static_cast<unsigned int>(g_endpointQueueHighWaterFrames.load());
}
