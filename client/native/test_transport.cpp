#include <windows.h>

#include <cstdio>
#include <cstdlib>
#include <cstring>

using AudioCaptureInitialize = int (*)();
using AudioCaptureConnect = int (*)(int, const char*, void (*)(const char*));
using AudioCaptureStart = int (*)();
using AudioCaptureStop = void (*)();
using AudioCaptureCleanup = void (*)();
using AudioCaptureGetErrorCode = int (*)();
using AudioCaptureGetErrorMessage = const char* (*)();

HANDLE g_readyEvent = nullptr;

template <typename Function>
Function LoadFunction(HMODULE library, const char* name) {
    const FARPROC raw = GetProcAddress(library, name);
    static_assert(sizeof(raw) == sizeof(Function));
    Function function = nullptr;
    std::memcpy(&function, &raw, sizeof(function));
    return function;
}

void OnConnect(const char* status) {
    std::printf("Transport callback: %s\n", status == nullptr ? "" : status);
    SetEvent(g_readyEvent);
}

int main(int argc, char** argv) {
    if (argc != 3) {
        std::fprintf(stderr, "Usage: test_transport <forward-port> <64-hex-token>\n");
        return 2;
    }
    const int port = std::atoi(argv[1]);
    HMODULE library = LoadLibraryA("audio_capture.dll");
    if (library == nullptr) {
        std::fprintf(stderr, "Could not load audio_capture.dll\n");
        return 1;
    }
    const auto initialize = LoadFunction<AudioCaptureInitialize>(
        library, "AudioCapture_Initialize");
    const auto connect = LoadFunction<AudioCaptureConnect>(
        library, "AudioCapture_Connect");
    const auto start = LoadFunction<AudioCaptureStart>(
        library, "AudioCapture_Start");
    const auto stop = LoadFunction<AudioCaptureStop>(
        library, "AudioCapture_Stop");
    const auto cleanup = LoadFunction<AudioCaptureCleanup>(
        library, "AudioCapture_Cleanup");
    const auto getErrorCode = LoadFunction<AudioCaptureGetErrorCode>(
        library, "AudioCapture_GetLastErrorCode");
    const auto getErrorMessage = LoadFunction<AudioCaptureGetErrorMessage>(
        library, "AudioCapture_GetLastErrorMessage");
    if (initialize == nullptr || connect == nullptr || start == nullptr ||
        stop == nullptr || cleanup == nullptr || getErrorCode == nullptr ||
        getErrorMessage == nullptr) {
        std::fprintf(stderr, "The DLL does not expose the expected API\n");
        FreeLibrary(library);
        return 1;
    }

    g_readyEvent = CreateEvent(nullptr, TRUE, FALSE, nullptr);
    int result = 1;
    if (g_readyEvent == nullptr || initialize() == 0 ||
        connect(port, argv[2], OnConnect) == 0) {
        std::fprintf(stderr, "Setup failed: %d %s\n",
            getErrorCode(), getErrorMessage());
    } else if (WaitForSingleObject(g_readyEvent, 15000) != WAIT_OBJECT_0) {
        std::fprintf(stderr, "Handshake timed out: %d %s\n",
            getErrorCode(), getErrorMessage());
    } else if (start() == 0) {
        std::fprintf(stderr, "Capture start failed: %d %s\n",
            getErrorCode(), getErrorMessage());
    } else {
        std::puts("Streaming all system audio. Press Enter to stop.");
        std::getchar();
        result = 0;
    }

    stop();
    cleanup();
    if (g_readyEvent != nullptr) CloseHandle(g_readyEvent);
    FreeLibrary(library);
    return result;
}
