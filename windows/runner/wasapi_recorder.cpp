#include "wasapi_recorder.h"

#include <windows.h>
#include <audioclient.h>
#include <mmdeviceapi.h>
#include <mmreg.h>

#include <cstdio>
#include <vector>

namespace {

// Formato común de salida: 48 kHz, 16-bit, mono. El motor de audio remuestrea
// ambas fuentes a este formato gracias a AUDCLNT_STREAMFLAGS_AUTOCONVERTPCM.
constexpr uint32_t kSampleRate = 48000;
constexpr uint16_t kChannels = 1;
constexpr uint16_t kBits = 16;
// Buffer WASAPI de 1s; cómodo para sondear cada 10ms.
constexpr REFERENCE_TIME kBufferDuration = 10000000;
// Tope del buffer de sistema (2s) por si el loopback va por delante del micro.
constexpr size_t kSystemBufferCap = kSampleRate * 2;

constexpr DWORD kStreamFlagsCommon =
    AUDCLNT_STREAMFLAGS_AUTOCONVERTPCM | AUDCLNT_STREAMFLAGS_SRC_DEFAULT_QUALITY;

void TargetFormat(WAVEFORMATEX* fmt) {
  fmt->wFormatTag = WAVE_FORMAT_PCM;
  fmt->nChannels = kChannels;
  fmt->nSamplesPerSec = kSampleRate;
  fmt->wBitsPerSample = kBits;
  fmt->nBlockAlign = static_cast<uint16_t>(kChannels * kBits / 8);
  fmt->nAvgBytesPerSec = kSampleRate * fmt->nBlockAlign;
  fmt->cbSize = 0;
}

void WriteWavHeaderPlaceholder(FILE* f) {
  uint8_t header[44] = {0};
  fwrite(header, 1, sizeof(header), f);
}

void PatchWavHeader(FILE* f, uint32_t data_bytes) {
  const uint32_t byte_rate = kSampleRate * kChannels * kBits / 8;
  const uint16_t block_align = static_cast<uint16_t>(kChannels * kBits / 8);
  const uint32_t riff_size = 36 + data_bytes;
  const uint32_t fmt_size = 16;
  const uint16_t pcm_tag = 1;
  const uint32_t rate = kSampleRate;
  const uint16_t channels = kChannels;
  const uint16_t bits = kBits;

  fseek(f, 0, SEEK_SET);
  fwrite("RIFF", 1, 4, f);
  fwrite(&riff_size, 4, 1, f);
  fwrite("WAVE", 1, 4, f);
  fwrite("fmt ", 1, 4, f);
  fwrite(&fmt_size, 4, 1, f);
  fwrite(&pcm_tag, 2, 1, f);
  fwrite(&channels, 2, 1, f);
  fwrite(&rate, 4, 1, f);
  fwrite(&byte_rate, 4, 1, f);
  fwrite(&block_align, 2, 1, f);
  fwrite(&bits, 2, 1, f);
  fwrite("data", 1, 4, f);
  fwrite(&data_bytes, 4, 1, f);
}

template <typename T>
void SafeRelease(T** p) {
  if (*p) {
    (*p)->Release();
    *p = nullptr;
  }
}

int16_t ClampToInt16(int value) {
  if (value > 32767) return 32767;
  if (value < -32768) return -32768;
  return static_cast<int16_t>(value);
}

}  // namespace

WasapiRecorder::~WasapiRecorder() { Stop(); }

bool WasapiRecorder::Start(const std::wstring& path, bool capture_system) {
  if (recording_.load()) return false;
  capture_system_ = capture_system;
  recording_.store(true);
  paused_.store(false);
  peak_.store(0.0f);
  {
    std::lock_guard<std::mutex> lock(system_mutex_);
    system_buffer_.clear();
  }
  if (capture_system_) {
    system_thread_ = std::thread(&WasapiRecorder::SystemLoop, this);
  }
  mic_thread_ = std::thread(&WasapiRecorder::MicLoop, this, path);
  return true;
}

void WasapiRecorder::Stop() {
  recording_.store(false);
  if (mic_thread_.joinable()) mic_thread_.join();
  if (system_thread_.joinable()) system_thread_.join();
}

void WasapiRecorder::Pause() { paused_.store(true); }

void WasapiRecorder::Resume() { paused_.store(false); }

void WasapiRecorder::PopSystem(int16_t* out, int count) {
  std::lock_guard<std::mutex> lock(system_mutex_);
  for (int i = 0; i < count; ++i) {
    if (!system_buffer_.empty()) {
      out[i] = system_buffer_.front();
      system_buffer_.pop_front();
    } else {
      out[i] = 0;
    }
  }
}

void WasapiRecorder::MicLoop(std::wstring path) {
  HRESULT hr = S_OK;
  bool com_init = false;
  IMMDeviceEnumerator* enumerator = nullptr;
  IMMDevice* device = nullptr;
  IAudioClient* client = nullptr;
  IAudioCaptureClient* capture = nullptr;
  FILE* file = nullptr;
  uint32_t data_bytes = 0;
  WAVEFORMATEX fmt;
  std::vector<int16_t> sys_chunk;

  TargetFormat(&fmt);

  hr = CoInitializeEx(nullptr, COINIT_MULTITHREADED);
  com_init = SUCCEEDED(hr);

  hr = CoCreateInstance(__uuidof(MMDeviceEnumerator), nullptr, CLSCTX_ALL,
                        __uuidof(IMMDeviceEnumerator),
                        reinterpret_cast<void**>(&enumerator));
  if (FAILED(hr)) goto cleanup;

  hr = enumerator->GetDefaultAudioEndpoint(eCapture, eConsole, &device);
  if (FAILED(hr)) goto cleanup;

  hr = device->Activate(__uuidof(IAudioClient), CLSCTX_ALL, nullptr,
                        reinterpret_cast<void**>(&client));
  if (FAILED(hr)) goto cleanup;

  hr = client->Initialize(AUDCLNT_SHAREMODE_SHARED, kStreamFlagsCommon,
                          kBufferDuration, 0, &fmt, nullptr);
  if (FAILED(hr)) goto cleanup;

  hr = client->GetService(__uuidof(IAudioCaptureClient),
                          reinterpret_cast<void**>(&capture));
  if (FAILED(hr)) goto cleanup;

  file = _wfopen(path.c_str(), L"wb");
  if (!file) goto cleanup;
  WriteWavHeaderPlaceholder(file);

  hr = client->Start();
  if (FAILED(hr)) goto cleanup;

  while (recording_.load()) {
    Sleep(10);
    UINT32 packet = 0;
    if (FAILED(capture->GetNextPacketSize(&packet))) break;
    while (packet != 0) {
      BYTE* data = nullptr;
      UINT32 frames = 0;
      DWORD flags = 0;
      if (FAILED(capture->GetBuffer(&data, &frames, &flags, nullptr, nullptr)))
        break;

      if (paused_.load()) {
        // En pausa no se escribe; se vacía el buffer de sistema para no
        // arrastrar audio viejo al reanudar.
        std::lock_guard<std::mutex> lock(system_mutex_);
        system_buffer_.clear();
      } else {
        const bool silent = (flags & AUDCLNT_BUFFERFLAGS_SILENT) != 0;
        const int16_t* mic = reinterpret_cast<const int16_t*>(data);

        if (capture_system_) {
          if (sys_chunk.size() < frames) sys_chunk.resize(frames);
          PopSystem(sys_chunk.data(), static_cast<int>(frames));
        }

        int block_peak = 0;
        for (UINT32 i = 0; i < frames; ++i) {
          int m = silent ? 0 : mic[i];
          int s = capture_system_ ? sys_chunk[i] : 0;
          int16_t mixed = ClampToInt16(m + s);
          fwrite(&mixed, sizeof(int16_t), 1, file);
          data_bytes += sizeof(int16_t);
          int a = mixed < 0 ? -mixed : mixed;
          if (a > block_peak) block_peak = a;
        }
        peak_.store(static_cast<float>(block_peak) / 32768.0f);
      }

      if (FAILED(capture->ReleaseBuffer(frames))) break;
      if (FAILED(capture->GetNextPacketSize(&packet))) break;
    }
  }

  client->Stop();

cleanup:
  if (file) {
    PatchWavHeader(file, data_bytes);
    fclose(file);
  }
  SafeRelease(&capture);
  SafeRelease(&client);
  SafeRelease(&device);
  SafeRelease(&enumerator);
  if (com_init) CoUninitialize();
  recording_.store(false);
}

void WasapiRecorder::SystemLoop() {
  HRESULT hr = S_OK;
  bool com_init = false;
  IMMDeviceEnumerator* enumerator = nullptr;
  IMMDevice* device = nullptr;
  IAudioClient* client = nullptr;
  IAudioCaptureClient* capture = nullptr;
  WAVEFORMATEX fmt;

  TargetFormat(&fmt);

  hr = CoInitializeEx(nullptr, COINIT_MULTITHREADED);
  com_init = SUCCEEDED(hr);

  hr = CoCreateInstance(__uuidof(MMDeviceEnumerator), nullptr, CLSCTX_ALL,
                        __uuidof(IMMDeviceEnumerator),
                        reinterpret_cast<void**>(&enumerator));
  if (FAILED(hr)) goto cleanup;

  hr = enumerator->GetDefaultAudioEndpoint(eRender, eConsole, &device);
  if (FAILED(hr)) goto cleanup;

  hr = device->Activate(__uuidof(IAudioClient), CLSCTX_ALL, nullptr,
                        reinterpret_cast<void**>(&client));
  if (FAILED(hr)) goto cleanup;

  hr = client->Initialize(AUDCLNT_SHAREMODE_SHARED,
                          AUDCLNT_STREAMFLAGS_LOOPBACK | kStreamFlagsCommon,
                          kBufferDuration, 0, &fmt, nullptr);
  if (FAILED(hr)) goto cleanup;

  hr = client->GetService(__uuidof(IAudioCaptureClient),
                          reinterpret_cast<void**>(&capture));
  if (FAILED(hr)) goto cleanup;

  hr = client->Start();
  if (FAILED(hr)) goto cleanup;

  while (recording_.load()) {
    Sleep(10);
    UINT32 packet = 0;
    if (FAILED(capture->GetNextPacketSize(&packet))) break;
    while (packet != 0) {
      BYTE* data = nullptr;
      UINT32 frames = 0;
      DWORD flags = 0;
      if (FAILED(capture->GetBuffer(&data, &frames, &flags, nullptr, nullptr)))
        break;

      if (!paused_.load()) {
        const bool silent = (flags & AUDCLNT_BUFFERFLAGS_SILENT) != 0;
        const int16_t* sys = reinterpret_cast<const int16_t*>(data);
        std::lock_guard<std::mutex> lock(system_mutex_);
        for (UINT32 i = 0; i < frames; ++i) {
          system_buffer_.push_back(silent ? 0 : sys[i]);
        }
        while (system_buffer_.size() > kSystemBufferCap) {
          system_buffer_.pop_front();
        }
      }

      if (FAILED(capture->ReleaseBuffer(frames))) break;
      if (FAILED(capture->GetNextPacketSize(&packet))) break;
    }
  }

  client->Stop();

cleanup:
  SafeRelease(&capture);
  SafeRelease(&client);
  SafeRelease(&device);
  SafeRelease(&enumerator);
  if (com_init) CoUninitialize();
}
