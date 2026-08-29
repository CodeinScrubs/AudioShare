#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <winsock2.h>
#include <ws2tcpip.h>
#include <mmdeviceapi.h>
#include <audioclient.h>
#include <mmreg.h>

#include <atomic>
#include <chrono>
#include <condition_variable>
#include <cstdint>
#include <cstring>
#include <deque>
#include <mutex>
#include <string>
#include <vector>

#include "wire_protocol.h"

#ifdef _MSC_VER
#pragma comment(lib, "ws2_32.lib")
#endif

namespace {

constexpr size_t kMaxQueuedChunks = 8;
constexpr uint32_t kSampleRate = 48000;
constexpr uint16_t kChannels = 2;
constexpr uint16_t kBitsPerSample = 16;

using ConnectCallback = void (*)(const char* status);
using namespace audioshare::wire;

std::atomic<bool> g_initialized{false};
std::atomic<bool> g_transportRunning{false};
std::atomic<bool> g_captureRunning{false};
std::atomic<bool> g_connected{false};
std::atomic<uint64_t> g_droppedChunks{0};
std::atomic<uint64_t> g_androidReceivedFrames{0};
std::atomic<uint64_t> g_androidDroppedFrames{0};
std::atomic<uint32_t> g_androidQueueDepth{0};
std::atomic<uint32_t> g_androidBufferFrames{0};
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
std::deque<std::vector<uint8_t>> g_audioQueue;

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

void CloseTransportSocket() {
    const SOCKET socket = g_transportSocket.exchange(INVALID_SOCKET);
    if (socket != INVALID_SOCKET) {
        shutdown(socket, SD_BOTH);
        closesocket(socket);
    }
}

void ClearQueue() {
    std::lock_guard<std::mutex> lock(g_queueMutex);
    g_audioQueue.clear();
}

void EnqueuePcm(const uint8_t* data, size_t length) {
    size_t offset = 0;
    while (offset < length && g_captureRunning.load()) {
        size_t chunkLength = length - offset;
        if (chunkLength > kMaxPcmPayload) chunkLength = kMaxPcmPayload;
        chunkLength -= chunkLength % (kChannels * (kBitsPerSample / 8));
        if (chunkLength == 0) return;
        std::vector<uint8_t> chunk(data + offset, data + offset + chunkLength);
        {
            std::lock_guard<std::mutex> lock(g_queueMutex);
            if (g_audioQueue.size() >= kMaxQueuedChunks) {
                g_audioQueue.pop_front();
                g_droppedChunks.fetch_add(1);
            }
            g_audioQueue.push_back(std::move(chunk));
        }
        g_queueCondition.notify_one();
        offset += chunkLength;
    }
}

bool ReapThread(HANDLE* thread, DWORD timeoutMilliseconds) {
    if (*thread == nullptr) return true;
    if (WaitForSingleObject(*thread, timeoutMilliseconds) != WAIT_OBJECT_0) return false;
    CloseHandle(*thread);
    *thread = nullptr;
    return true;
}

SOCKET ConnectLoopback(int port) {
    const auto deadline = std::chrono::steady_clock::now() + std::chrono::seconds(8);
    while (g_transportRunning.load() && std::chrono::steady_clock::now() < deadline) {
        SOCKET socket = ::socket(AF_INET, SOCK_STREAM, IPPROTO_TCP);
        if (socket == INVALID_SOCKET) return INVALID_SOCKET;
        int one = 1;
        int timeout = 5000;
        setsockopt(socket, IPPROTO_TCP, TCP_NODELAY, reinterpret_cast<const char*>(&one), sizeof(one));
        setsockopt(socket, SOL_SOCKET, SO_SNDTIMEO, reinterpret_cast<const char*>(&timeout), sizeof(timeout));
        setsockopt(socket, SOL_SOCKET, SO_RCVTIMEO, reinterpret_cast<const char*>(&timeout), sizeof(timeout));
        sockaddr_in address{};
        address.sin_family = AF_INET;
        address.sin_port = htons(static_cast<u_short>(port));
        address.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
        if (connect(socket, reinterpret_cast<sockaddr*>(&address), sizeof(address)) == 0) return socket;
        closesocket(socket);
        Sleep(100);
    }
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

    SOCKET socket = ConnectLoopback(port);
    if (socket == INVALID_SOCKET) {
        if (g_transportRunning.load()) SetError(2100, "Could not connect to the ADB loopback forward");
        g_transportRunning.store(false);
        return 1;
    }
    g_transportSocket.store(socket);

    const auto hello = EncodeHello(
        token, kSampleRate, static_cast<uint8_t>(kChannels),
        static_cast<uint8_t>(kBitsPerSample));
    if (!SendFrame(socket, kTypeHello, 1, hello.data(), hello.size())) {
        SetError(2101, "Could not send protocol HELLO to Android");
        CloseTransportSocket();
        g_transportRunning.store(false);
        return 1;
    }

    ReceivedFrame ready;
    if (!ReceiveFrame(socket, &ready) || ready.type != kTypeReady) {
        SetErrorIfNone(2102, "Android rejected or did not complete the protocol handshake");
        CloseTransportSocket();
        g_transportRunning.store(false);
        return 1;
    }
    ReadyPayload accepted;
    if (!DecodeReady(ready.payload.data(), ready.payload.size(), &accepted) ||
        accepted.sampleRate != kSampleRate ||
        accepted.channels != kChannels ||
        accepted.bitsPerSample != kBitsPerSample ||
        accepted.bufferFrames == 0 ||
        accepted.bufferFrames > kSampleRate * 5) {
        SetError(2109, "Android accepted an invalid or incompatible audio format");
        CloseTransportSocket();
        g_transportRunning.store(false);
        return 1;
    }
    g_androidBufferFrames.store(accepted.bufferFrames);

    g_connected.store(true);
    if (callback != nullptr) callback("ready");
    uint32_t sequence = 2;
    auto nextPing = std::chrono::steady_clock::now() + std::chrono::seconds(3);
    while (g_transportRunning.load()) {
        std::vector<uint8_t> chunk;
        {
            std::unique_lock<std::mutex> lock(g_queueMutex);
            g_queueCondition.wait_for(lock, std::chrono::milliseconds(100), [] {
                return !g_audioQueue.empty() || !g_transportRunning.load();
            });
            if (!g_audioQueue.empty()) {
                chunk = std::move(g_audioQueue.front());
                g_audioQueue.pop_front();
            }
        }
        if (!chunk.empty() && !SendFrame(socket, kTypePcm, sequence++, chunk.data(), chunk.size())) {
            if (g_transportRunning.load()) SetError(2103, "Audio transport write failed");
            break;
        }
        const auto now = std::chrono::steady_clock::now();
        if (now >= nextPing) {
            if (!SendFrame(socket, kTypeStats, sequence++, nullptr, 0)) {
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
        if (selected > 0 && FD_ISSET(socket, &readSet)) {
            ReceivedFrame inbound;
            if (!ReceiveFrame(socket, &inbound)) break;
            if (inbound.type == kTypeError) {
                SetError(2107, "Android reported a playback error");
                break;
            }
            if (inbound.type == kTypeStats) {
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
            } else if (inbound.type != kTypePong) {
                SetError(2108, "Android sent an unexpected protocol message");
                break;
            }
        }
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

    do {
        result = CoCreateInstance(__uuidof(MMDeviceEnumerator), nullptr, CLSCTX_ALL,
            __uuidof(IMMDeviceEnumerator), reinterpret_cast<void**>(&enumerator));
        if (FAILED(result)) { SetError(2201, HresultMessage("Create audio device enumerator", result)); break; }
        result = enumerator->GetDefaultAudioEndpoint(eRender, eConsole, &device);
        if (FAILED(result)) { SetError(2202, HresultMessage("Get default render endpoint", result)); break; }
        result = device->Activate(__uuidof(IAudioClient), CLSCTX_ALL, nullptr,
            reinterpret_cast<void**>(&audioClient));
        if (FAILED(result)) { SetError(2203, HresultMessage("Activate WASAPI client", result)); break; }

        WAVEFORMATEX format{};
        format.wFormatTag = WAVE_FORMAT_PCM;
        format.nChannels = kChannels;
        format.nSamplesPerSec = kSampleRate;
        format.wBitsPerSample = kBitsPerSample;
        format.nBlockAlign = kChannels * (kBitsPerSample / 8);
        format.nAvgBytesPerSec = kSampleRate * format.nBlockAlign;
        format.cbSize = 0;

        const DWORD streamFlags = AUDCLNT_STREAMFLAGS_LOOPBACK |
            AUDCLNT_STREAMFLAGS_EVENTCALLBACK |
            AUDCLNT_STREAMFLAGS_AUTOCONVERTPCM |
            AUDCLNT_STREAMFLAGS_SRC_DEFAULT_QUALITY;
        result = audioClient->Initialize(AUDCLNT_SHAREMODE_SHARED, streamFlags, 0, 0,
            &format, nullptr);
        if (FAILED(result)) { SetError(2204, HresultMessage("Initialize 48 kHz system loopback", result)); break; }

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
                    std::vector<uint8_t> silence(byteCount, 0);
                    EnqueuePcm(silence.data(), silence.size());
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
    g_connected.store(false);
    if (g_stopEvent != nullptr) ResetEvent(g_stopEvent);
    {
        std::lock_guard<std::mutex> lock(g_configMutex);
        g_pendingPort = port;
        memcpy(g_pendingToken, token, sizeof(token));
        g_connectCallback = callback;
    }
    g_transportRunning.store(true);
    g_transportThread = CreateThread(nullptr, 0, TransportThread, nullptr, 0, nullptr);
    if (g_transportThread == nullptr) {
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
    if (g_captureRunning.load()) return 1;
    ClearError();
    if (g_captureThread != nullptr && !ReapThread(&g_captureThread, 1000)) {
        SetError(2005, "Previous capture thread did not stop in time");
        return 0;
    }
    ClearQueue();
    if (g_stopEvent != nullptr) ResetEvent(g_stopEvent);
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
    g_captureRunning.store(false);
    g_transportRunning.store(false);
    g_connected.store(false);
    if (g_stopEvent != nullptr) SetEvent(g_stopEvent);
    CloseTransportSocket();
    g_queueCondition.notify_all();
    ReapThread(&g_captureThread, 250);
    ReapThread(&g_transportThread, 250);
    ClearQueue();
}

extern "C" __declspec(dllexport) void AudioCapture_Cleanup() {
    AudioCapture_Stop();
    const bool captureStopped = ReapThread(&g_captureThread, 3000);
    const bool transportStopped = ReapThread(&g_transportThread, 3000);
    if (!captureStopped || !transportStopped) {
        SetError(2007, "Native worker did not stop; shared resources were retained safely");
        return;
    }
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
