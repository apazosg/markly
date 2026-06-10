#ifndef RUNNER_WASAPI_RECORDER_H_
#define RUNNER_WASAPI_RECORDER_H_

#include <atomic>
#include <cstdint>
#include <deque>
#include <mutex>
#include <string>
#include <thread>

// Captura unificada de audio en Windows mediante WASAPI:
//   - Micrófono: endpoint de captura por defecto.
//   - Sistema:   endpoint de salida por defecto vía loopback
//                (AUDCLNT_STREAMFLAGS_LOOPBACK), sin Stereo Mix ni cables.
//
// Ambas fuentes se inicializan con AUDCLNT_STREAMFLAGS_AUTOCONVERTPCM, de modo
// que el motor de audio de Windows las entrega ya en 48 kHz / 16-bit / mono.
// El hilo del micrófono actúa de reloj maestro: por cada muestra de micro mezcla
// (suma con saturación) la muestra de sistema disponible o silencio si no la hay,
// y escribe un único WAV mono. Así no hay deriva entre dos relojes ni mezcla en
// el backend.
class WasapiRecorder {
 public:
  WasapiRecorder() = default;
  ~WasapiRecorder();

  // Arranca la captura hacia |path| (UTF-16). |capture_system| añade el audio
  // del sistema a la mezcla. Devuelve false si ya hay una captura en curso.
  bool Start(const std::wstring& path, bool capture_system);
  void Stop();
  void Pause();
  void Resume();

  // Nivel de pico normalizado [0,1] del último bloque mezclado (para el VU).
  double Amplitude() const { return peak_.load(); }

 private:
  void MicLoop(std::wstring path);
  void SystemLoop();
  // Extrae hasta |count| muestras de sistema; rellena con 0 las que falten.
  void PopSystem(int16_t* out, int count);

  std::thread mic_thread_;
  std::thread system_thread_;
  std::mutex system_mutex_;
  std::deque<int16_t> system_buffer_;

  std::atomic<bool> recording_{false};
  std::atomic<bool> paused_{false};
  std::atomic<float> peak_{0.0f};
  bool capture_system_{false};
};

#endif  // RUNNER_WASAPI_RECORDER_H_
