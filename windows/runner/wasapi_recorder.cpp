#include "wasapi_recorder.h"

#include <windows.h>
#include <audioclient.h>
#include <mmdeviceapi.h>
#include <mmreg.h>
#include <mfapi.h>
#include <mfidl.h>
#include <mfreadwrite.h>
#include <mferror.h>

#include <cstring>
#include <vector>

namespace {

// Formato común de captura: 48 kHz, 16-bit, mono. El motor de audio remuestrea
// ambas fuentes a este formato gracias a AUDCLNT_STREAMFLAGS_AUTOCONVERTPCM.
constexpr uint32_t kSampleRate = 48000;
constexpr uint16_t kChannels = 1;
constexpr uint16_t kBits = 16;
// Bitrate AAC de salida en bytes/seg. El encoder AAC de Media Foundation admite
// 12000/16000/20000/24000 (= 96/128/160/192 kbps). 12000 (96 kbps) es el mínimo:
// voz nítida y ~43 MB/h. Si AddStream falla, prueba 16000.
constexpr uint32_t kAacBytesPerSec = 12000;
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

// Codifica PCM 48k/16/mono a AAC en un contenedor .m4a vía Media Foundation.
// Sin dependencias externas (MF viene con Windows). Requiere MFStartup previo.
// Nota: las ediciones Windows "N"/"KN" sin Media Feature Pack no traen el codec
// AAC; en esos equipos Init() falla y la grabación no produce fichero.
struct AacWriter {
  IMFSinkWriter* writer = nullptr;
  DWORD stream = 0;
  LONGLONG samples = 0;  // muestras PCM acumuladas, para los timestamps
  bool ok = false;

  bool Init(const std::wstring& path) {
    IMFMediaType* out = nullptr;
    IMFMediaType* in = nullptr;

    HRESULT hr = MFCreateSinkWriterFromURL(path.c_str(), nullptr, nullptr, &writer);
    if (SUCCEEDED(hr)) hr = MFCreateMediaType(&out);
    if (SUCCEEDED(hr)) {
      out->SetGUID(MF_MT_MAJOR_TYPE, MFMediaType_Audio);
      out->SetGUID(MF_MT_SUBTYPE, MFAudioFormat_AAC);
      out->SetUINT32(MF_MT_AUDIO_BITS_PER_SAMPLE, kBits);
      out->SetUINT32(MF_MT_AUDIO_SAMPLES_PER_SECOND, kSampleRate);
      out->SetUINT32(MF_MT_AUDIO_NUM_CHANNELS, kChannels);
      out->SetUINT32(MF_MT_AUDIO_AVG_BYTES_PER_SECOND, kAacBytesPerSec);
      hr = writer->AddStream(out, &stream);
    }
    if (SUCCEEDED(hr)) hr = MFCreateMediaType(&in);
    if (SUCCEEDED(hr)) {
      in->SetGUID(MF_MT_MAJOR_TYPE, MFMediaType_Audio);
      in->SetGUID(MF_MT_SUBTYPE, MFAudioFormat_PCM);
      in->SetUINT32(MF_MT_AUDIO_BITS_PER_SAMPLE, kBits);
      in->SetUINT32(MF_MT_AUDIO_SAMPLES_PER_SECOND, kSampleRate);
      in->SetUINT32(MF_MT_AUDIO_NUM_CHANNELS, kChannels);
      in->SetUINT32(MF_MT_AUDIO_BLOCK_ALIGNMENT, kChannels * kBits / 8);
      in->SetUINT32(MF_MT_AUDIO_AVG_BYTES_PER_SECOND,
                    kSampleRate * kChannels * kBits / 8);
      hr = writer->SetInputMediaType(stream, in, nullptr);
    }
    if (SUCCEEDED(hr)) hr = writer->BeginWriting();

    ok = SUCCEEDED(hr);
    SafeRelease(&out);
    SafeRelease(&in);
    if (!ok) SafeRelease(&writer);
    return ok;
  }

  void Write(const int16_t* pcm, UINT32 frames) {
    if (!ok || frames == 0) return;
    const DWORD bytes = frames * sizeof(int16_t);
    IMFMediaBuffer* buf = nullptr;
    if (FAILED(MFCreateMemoryBuffer(bytes, &buf))) return;

    BYTE* dst = nullptr;
    if (SUCCEEDED(buf->Lock(&dst, nullptr, nullptr))) {
      memcpy(dst, pcm, bytes);
      buf->Unlock();
      buf->SetCurrentLength(bytes);

      IMFSample* sample = nullptr;
      if (SUCCEEDED(MFCreateSample(&sample)) && SUCCEEDED(sample->AddBuffer(buf))) {
        sample->SetSampleTime(samples * 10000000LL / kSampleRate);
        sample->SetSampleDuration(static_cast<LONGLONG>(frames) * 10000000LL / kSampleRate);
        if (SUCCEEDED(writer->WriteSample(stream, sample))) samples += frames;
      }
      SafeRelease(&sample);
    }
    SafeRelease(&buf);
  }

  void Finalize() {
    if (writer) {
      if (ok) writer->Finalize();
      SafeRelease(&writer);
    }
  }
};

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
  bool mf_init = false;
  IMMDeviceEnumerator* enumerator = nullptr;
  IMMDevice* device = nullptr;
  IAudioClient* client = nullptr;
  IAudioCaptureClient* capture = nullptr;
  AacWriter aac;
  WAVEFORMATEX fmt;
  std::vector<int16_t> sys_chunk;
  std::vector<int16_t> mixed_chunk;

  TargetFormat(&fmt);

  hr = CoInitializeEx(nullptr, COINIT_MULTITHREADED);
  com_init = SUCCEEDED(hr);

  hr = MFStartup(MF_VERSION);
  if (FAILED(hr)) goto cleanup;
  mf_init = true;

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

  if (!aac.Init(path)) goto cleanup;

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
        if (mixed_chunk.size() < frames) mixed_chunk.resize(frames);

        int block_peak = 0;
        for (UINT32 i = 0; i < frames; ++i) {
          int m = silent ? 0 : mic[i];
          int s = capture_system_ ? sys_chunk[i] : 0;
          int16_t mixed = ClampToInt16(m + s);
          mixed_chunk[i] = mixed;
          int a = mixed < 0 ? -mixed : mixed;
          if (a > block_peak) block_peak = a;
        }
        aac.Write(mixed_chunk.data(), frames);
        peak_.store(static_cast<float>(block_peak) / 32768.0f);
      }

      if (FAILED(capture->ReleaseBuffer(frames))) break;
      if (FAILED(capture->GetNextPacketSize(&packet))) break;
    }
  }

  client->Stop();

cleanup:
  aac.Finalize();
  SafeRelease(&capture);
  SafeRelease(&client);
  SafeRelease(&device);
  SafeRelease(&enumerator);
  if (mf_init) MFShutdown();
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
