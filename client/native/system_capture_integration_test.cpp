#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <winsock2.h>
#include <ws2tcpip.h>

#include <atomic>
#include <chrono>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <vector>

#include "wire_protocol.h"

using namespace audioshare::wire;

namespace {

constexpr char kTokenHex[] =
    "00112233445566778899aabbccddeeff"
    "ffeeddccbbaa99887766554433221100";

using AudioCaptureInitialize = int (*)();
using AudioCaptureConnect = int (*)(int, const char*, void (*)(const char*));
using AudioCaptureStart = int (*)();
using AudioCaptureStop = void (*)();
using AudioCaptureCleanup = void (*)();
using AudioCaptureGetErrorCode = int (*)();
using AudioCaptureGetErrorMessage = const char* (*)();
using AudioCaptureGetCaptureMode = unsigned int (*)();
using AudioCaptureGetGlobalHresult = long (*)();
using AudioCaptureGetUint32 = unsigned int (*)();
using AudioCaptureGetUint64 = unsigned long long (*)();

HANDLE g_transportReady = nullptr;
std::atomic<uint64_t> g_pcmBytes{0};
std::atomic<uint64_t> g_nonZeroPcmBytes{0};
std::atomic<bool> g_serverOk{false};
std::atomic<bool> g_disconnectAfterReady{false};
std::atomic<bool> g_rejectFirstConnection{false};
std::atomic<bool> g_stallHandshake{false};
std::atomic<bool> g_sendHandshakeError{false};
std::atomic<bool> g_callbackReportedError{false};
std::atomic<unsigned int> g_acceptedConnections{0};
std::atomic<unsigned int> g_callbackCalls{0};
SOCKET g_listener = INVALID_SOCKET;
HANDLE g_handshakeStalled = nullptr;

template <typename Function>
Function LoadFunction(HMODULE library, const char* name) {
    const FARPROC raw = GetProcAddress(library, name);
    static_assert(sizeof(raw) == sizeof(Function));
    Function function = nullptr;
    std::memcpy(&function, &raw, sizeof(function));
    return function;
}

bool SendAll(SOCKET socket, const uint8_t* data, size_t length) {
    while (length > 0) {
        const int sent = send(
            socket, reinterpret_cast<const char*>(data),
            static_cast<int>(length), 0);
        if (sent <= 0) return false;
        data += sent;
        length -= static_cast<size_t>(sent);
    }
    return true;
}

bool ReceiveAll(SOCKET socket, uint8_t* data, size_t length) {
    while (length > 0) {
        const int received = recv(
            socket, reinterpret_cast<char*>(data),
            static_cast<int>(length), 0);
        if (received <= 0) return false;
        data += received;
        length -= static_cast<size_t>(received);
    }
    return true;
}

bool SendFrame(SOCKET socket, uint16_t type, uint32_t sequence,
               const uint8_t* payload, size_t payloadLength) {
    const auto header = EncodeHeader(
        type, static_cast<uint32_t>(payloadLength), sequence);
    return SendAll(socket, header.data(), header.size()) &&
        (payloadLength == 0 || SendAll(socket, payload, payloadLength));
}

DWORD WINAPI FakeCompanionThread(LPVOID) {
    SOCKET client = accept(g_listener, nullptr, nullptr);
    if (client == INVALID_SOCKET) return 1;
    g_acceptedConnections.fetch_add(1);
    if (g_rejectFirstConnection.exchange(false)) {
        shutdown(client, SD_BOTH);
        closesocket(client);
        client = accept(g_listener, nullptr, nullptr);
        if (client == INVALID_SOCKET) return 1;
        g_acceptedConnections.fetch_add(1);
    }
    int timeout = 8000;
    setsockopt(client, SOL_SOCKET, SO_RCVTIMEO,
        reinterpret_cast<const char*>(&timeout), sizeof(timeout));

    uint8_t headerBytes[kFrameHeaderBytes]{};
    FrameHeader helloHeader;
    if (!ReceiveAll(client, headerBytes, sizeof(headerBytes)) ||
        !DecodeHeader(headerBytes, sizeof(headerBytes), &helloHeader) ||
        helloHeader.type != kTypeHello || helloHeader.payloadLength != 40) {
        closesocket(client);
        return 1;
    }
    std::vector<uint8_t> hello(helloHeader.payloadLength);
    if (!ReceiveAll(client, hello.data(), hello.size())) {
        closesocket(client);
        return 1;
    }
    uint8_t expectedToken[kTokenBytes]{};
    if (!DecodeToken(kTokenHex, expectedToken) ||
        std::memcmp(hello.data(), expectedToken, sizeof(expectedToken)) != 0 ||
        ReadU32(hello.data() + 32) != 48000 || hello[36] != 2 ||
        hello[37] != 16) {
        closesocket(client);
        return 1;
    }
    if (g_stallHandshake.load()) {
        g_serverOk.store(true);
        SetEvent(g_handshakeStalled);
        uint8_t discarded[64]{};
        while (recv(client, reinterpret_cast<char*>(discarded),
                    sizeof(discarded), 0) > 0) {
        }
        closesocket(client);
        return 0;
    }
    if (g_sendHandshakeError.load()) {
        constexpr char kHandshakeError[] = "built-in speaker unavailable";
        const bool sent = SendFrame(
            client, kTypeError, helloHeader.sequence,
            reinterpret_cast<const uint8_t*>(kHandshakeError),
            sizeof(kHandshakeError) - 1);
        g_serverOk.store(sent);
        shutdown(client, SD_BOTH);
        closesocket(client);
        return sent ? 0 : 1;
    }

    uint8_t ready[16]{};
    WriteU32(ready, 48000);
    WriteU32(ready + 4, 2);
    WriteU32(ready + 8, 16);
    WriteU32(ready + 12, 2880);
    if (!SendFrame(client, kTypeReady, 1, ready, sizeof(ready))) {
        closesocket(client);
        return 1;
    }
    g_serverOk.store(true);
    if (g_disconnectAfterReady.load()) {
        shutdown(client, SD_BOTH);
        closesocket(client);
        return 0;
    }

    while (ReceiveAll(client, headerBytes, sizeof(headerBytes))) {
        FrameHeader frame;
        if (!DecodeHeader(headerBytes, sizeof(headerBytes), &frame)) break;
        std::vector<uint8_t> payload(frame.payloadLength);
        if (frame.payloadLength > 0 &&
            !ReceiveAll(client, payload.data(), payload.size())) {
            break;
        }
        if (frame.type == kTypePcm) {
            g_pcmBytes.fetch_add(frame.payloadLength);
            uint64_t nonZeroBytes = 0;
            for (const uint8_t value : payload) {
                if (value != 0) ++nonZeroBytes;
            }
            g_nonZeroPcmBytes.fetch_add(nonZeroBytes);
        } else if (frame.type == kTypeStats) {
            uint8_t stats[24]{};
            const uint64_t frames = g_pcmBytes.load() / 4;
            WriteU32(stats, static_cast<uint32_t>(frames >> 32));
            WriteU32(stats + 4, static_cast<uint32_t>(frames));
            WriteU32(stats + 16, 0);
            WriteU32(stats + 20, 2880);
            if (!SendFrame(
                    client, kTypeStats, frame.sequence, stats, sizeof(stats))) {
                break;
            }
        } else if (frame.type == kTypePing) {
            if (!SendFrame(client, kTypePong, frame.sequence, nullptr, 0)) break;
        }
    }
    closesocket(client);
    return 0;
}

void OnConnect(const char* status) {
    g_callbackCalls.fetch_add(1);
    if (status != nullptr && std::strcmp(status, "ready") == 0) {
        SetEvent(g_transportReady);
    } else if (status != nullptr && std::strcmp(status, "error") == 0) {
        g_callbackReportedError.store(true);
        SetEvent(g_transportReady);
    }
}

}  // namespace

int main(int argc, char** argv) {
    bool requirePcm = false;
    bool requireSignal = false;
    bool expectDisconnectError = false;
    bool expectHandshakeRetry = false;
    bool expectHandshakeStop = false;
    bool expectHandshakeError = false;
    unsigned int expectedMode = 0;
    for (int index = 1; index < argc; ++index) {
        if (std::strcmp(argv[index], "--require-pcm") == 0) {
            requirePcm = true;
        } else if (std::strcmp(argv[index], "--require-signal") == 0) {
            requireSignal = true;
        } else if (std::strcmp(argv[index], "--expect-global") == 0) {
            expectedMode = 1;
        } else if (std::strcmp(argv[index], "--expect-multi") == 0) {
            expectedMode = 2;
        } else if (std::strcmp(argv[index], "--expect-default") == 0) {
            expectedMode = 3;
        } else if (std::strcmp(argv[index], "--expect-disconnect-error") == 0) {
            expectDisconnectError = true;
        } else if (std::strcmp(argv[index], "--expect-handshake-retry") == 0) {
            expectHandshakeRetry = true;
        } else if (std::strcmp(argv[index], "--expect-handshake-stop") == 0) {
            expectHandshakeStop = true;
        } else if (std::strcmp(argv[index], "--expect-handshake-error") == 0) {
            expectHandshakeError = true;
        } else {
            std::fprintf(stderr,
                "Usage: system_capture_integration_test "
                "[--require-pcm] [--require-signal] "
                "[--expect-global|--expect-multi|--expect-default] "
                "[--expect-disconnect-error] [--expect-handshake-retry] "
                "[--expect-handshake-stop] [--expect-handshake-error]\n");
            return 2;
        }
    }
    g_disconnectAfterReady.store(expectDisconnectError);
    g_rejectFirstConnection.store(expectHandshakeRetry);
    g_stallHandshake.store(expectHandshakeStop);
    g_sendHandshakeError.store(expectHandshakeError);

    WSADATA wsaData{};
    if (WSAStartup(MAKEWORD(2, 2), &wsaData) != 0) return 1;
    g_listener = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP);
    sockaddr_in address{};
    address.sin_family = AF_INET;
    address.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    address.sin_port = 0;
    if (g_listener == INVALID_SOCKET ||
        bind(g_listener, reinterpret_cast<sockaddr*>(&address), sizeof(address)) != 0 ||
        listen(g_listener, 1) != 0) {
        std::fprintf(stderr, "Could not start the fake loopback companion\n");
        WSACleanup();
        return 1;
    }
    int addressLength = sizeof(address);
    if (getsockname(g_listener, reinterpret_cast<sockaddr*>(&address),
                    &addressLength) != 0) {
        closesocket(g_listener);
        WSACleanup();
        return 1;
    }

    g_transportReady = CreateEvent(nullptr, TRUE, FALSE, nullptr);
    g_handshakeStalled = CreateEvent(nullptr, TRUE, FALSE, nullptr);
    HANDLE serverThread = CreateThread(
        nullptr, 0, FakeCompanionThread, nullptr, 0, nullptr);
    HMODULE library = LoadLibraryA("audio_capture.dll");
    if (serverThread == nullptr || g_transportReady == nullptr ||
        g_handshakeStalled == nullptr || library == nullptr) {
        std::fprintf(stderr, "Could not initialize native integration test\n");
        return 1;
    }

    const auto initialize = LoadFunction<AudioCaptureInitialize>(
        library, "AudioCapture_Initialize");
    const auto connect = LoadFunction<AudioCaptureConnect>(
        library, "AudioCapture_Connect");
    const auto start = LoadFunction<AudioCaptureStart>(library, "AudioCapture_Start");
    const auto stop = LoadFunction<AudioCaptureStop>(library, "AudioCapture_Stop");
    const auto cleanup = LoadFunction<AudioCaptureCleanup>(
        library, "AudioCapture_Cleanup");
    const auto getErrorCode = LoadFunction<AudioCaptureGetErrorCode>(
        library, "AudioCapture_GetLastErrorCode");
    const auto getErrorMessage = LoadFunction<AudioCaptureGetErrorMessage>(
        library, "AudioCapture_GetLastErrorMessage");
    const auto getCaptureMode = LoadFunction<AudioCaptureGetCaptureMode>(
        library, "AudioCapture_GetCaptureMode");
    const auto getDroppedChunks = LoadFunction<AudioCaptureGetUint64>(
        library, "AudioCapture_GetDroppedChunks");
    const auto getGlobalHresult = LoadFunction<AudioCaptureGetGlobalHresult>(
        library, "AudioCapture_GetGlobalLoopbackHresult");
    const auto getActiveEndpointCount = LoadFunction<AudioCaptureGetUint32>(
        library, "AudioCapture_GetActiveEndpointCount");
    const auto getEndpointDroppedFrames = LoadFunction<AudioCaptureGetUint64>(
        library, "AudioCapture_GetEndpointDroppedFrames");
    const auto getEndpointUnderrunFrames = LoadFunction<AudioCaptureGetUint64>(
        library, "AudioCapture_GetEndpointUnderrunFrames");
    const auto getEndpointDiscontinuities = LoadFunction<AudioCaptureGetUint64>(
        library, "AudioCapture_GetEndpointDiscontinuities");
    const auto getCaptureDiscontinuities = LoadFunction<AudioCaptureGetUint64>(
        library, "AudioCapture_GetCaptureDiscontinuities");
    const auto getEndpointRebuildCount = LoadFunction<AudioCaptureGetUint32>(
        library, "AudioCapture_GetEndpointRebuildCount");
    if (initialize == nullptr || connect == nullptr || start == nullptr ||
        stop == nullptr || cleanup == nullptr || getErrorCode == nullptr ||
        getErrorMessage == nullptr || getCaptureMode == nullptr ||
        getGlobalHresult == nullptr || getDroppedChunks == nullptr ||
        getActiveEndpointCount == nullptr ||
        getEndpointDroppedFrames == nullptr ||
        getEndpointUnderrunFrames == nullptr ||
        getEndpointDiscontinuities == nullptr ||
        getCaptureDiscontinuities == nullptr ||
        getEndpointRebuildCount == nullptr) {
        std::fprintf(stderr, "The DLL does not expose the expected Windows API\n");
        return 1;
    }

    int result = 1;
    bool cleanupCalled = false;
    if (initialize() == 0 ||
        connect(ntohs(address.sin_port), kTokenHex, OnConnect) == 0) {
        std::fprintf(stderr, "Setup failed: %d %s\n",
            getErrorCode(), getErrorMessage());
    } else if (expectHandshakeError) {
        if (WaitForSingleObject(g_transportReady, 3000) == WAIT_OBJECT_0 &&
            g_serverOk.load() && g_callbackCalls.load() == 1 &&
            g_callbackReportedError.load() && getErrorCode() == 2107 &&
            std::strstr(getErrorMessage(), "built-in speaker unavailable") !=
                nullptr) {
            result = 0;
        } else {
            std::fprintf(stderr,
                "Fatal handshake error was not surfaced immediately: %d %s\n",
                getErrorCode(), getErrorMessage());
        }
    } else if (expectHandshakeStop) {
        if (WaitForSingleObject(g_handshakeStalled, 3000) != WAIT_OBJECT_0 ||
            !g_serverOk.load()) {
            std::fprintf(stderr, "The fake companion did not stall the handshake\n");
        } else {
            const auto stopStarted = std::chrono::steady_clock::now();
            stop();
            cleanup();
            cleanupCalled = true;
            const auto stopMilliseconds =
                std::chrono::duration_cast<std::chrono::milliseconds>(
                    std::chrono::steady_clock::now() - stopStarted).count();
            std::printf("handshake_stop_milliseconds=%lld\n",
                static_cast<long long>(stopMilliseconds));
            if (stopMilliseconds < 2000 && getErrorCode() != 2007 &&
                g_callbackCalls.load() == 0) {
                result = 0;
            } else {
                std::fprintf(stderr,
                    "Stalled handshake did not stop promptly: %d %s\n",
                    getErrorCode(), getErrorMessage());
            }
        }
    } else if (WaitForSingleObject(g_transportReady, 10000) != WAIT_OBJECT_0 ||
               !g_serverOk.load() || g_callbackCalls.load() != 1) {
        std::fprintf(stderr, "Setup failed: %d %s\n",
            getErrorCode(), getErrorMessage());
    } else if (expectDisconnectError) {
        int errorCode = 0;
        for (int attempt = 0; attempt < 100 && errorCode == 0; ++attempt) {
            Sleep(50);
            errorCode = getErrorCode();
        }
        if (errorCode == 2112) {
            result = 0;
        } else {
            std::fprintf(stderr,
                "Clean peer EOF was not reported: %d %s\n",
                errorCode, getErrorMessage());
        }
    } else if (start() == 0) {
        std::fprintf(stderr, "Capture start failed: %d %s\n",
            getErrorCode(), getErrorMessage());
    } else {
        unsigned int mode = 0;
        for (int attempt = 0; attempt < 100 && mode == 0; ++attempt) {
            Sleep(100);
            mode = getCaptureMode();
            if (getErrorCode() != 0) break;
        }
        if (mode == 0) {
            std::fprintf(stderr, "Capture activation failed: %d %s\n",
                getErrorCode(), getErrorMessage());
        } else {
            std::printf("capture_mode=%u global_hresult=0x%08lX\n",
                mode, static_cast<unsigned long>(getGlobalHresult()));
            Sleep(4000);
            const uint64_t pcmBytes = g_pcmBytes.load();
            const uint64_t nonZeroPcmBytes = g_nonZeroPcmBytes.load();
            const uint64_t endpointDroppedFrames =
                getEndpointDroppedFrames();
            const uint64_t droppedChunks = getDroppedChunks();
            std::printf("pcm_bytes=%llu nonzero_pcm_bytes=%llu\n",
                static_cast<unsigned long long>(pcmBytes),
                static_cast<unsigned long long>(nonZeroPcmBytes));
            std::printf(
                "host_dropped_chunks=%llu active_endpoint_count=%u "
                "endpoint_dropped_frames=%llu "
                "endpoint_underrun_frames=%llu endpoint_discontinuities=%llu "
                "capture_discontinuities=%llu endpoint_rebuilds=%u\n",
                static_cast<unsigned long long>(droppedChunks),
                getActiveEndpointCount(),
                endpointDroppedFrames,
                getEndpointUnderrunFrames(),
                getEndpointDiscontinuities(),
                getCaptureDiscontinuities(),
                getEndpointRebuildCount());
            if ((expectedMode == 0 || mode == expectedMode) &&
                (!requirePcm || pcmBytes > 0) &&
                (!requireSignal || nonZeroPcmBytes > 0) &&
                droppedChunks == 0 &&
                (expectedMode != 2 || endpointDroppedFrames == 0) &&
                (!expectHandshakeRetry || g_acceptedConnections.load() >= 2)) {
                result = 0;
            }
        }
    }

    if (!cleanupCalled) {
        stop();
        cleanup();
    }
    shutdown(g_listener, SD_BOTH);
    closesocket(g_listener);
    WaitForSingleObject(serverThread, 3000);
    CloseHandle(serverThread);
    CloseHandle(g_transportReady);
    CloseHandle(g_handshakeStalled);
    FreeLibrary(library);
    WSACleanup();
    return result;
}
