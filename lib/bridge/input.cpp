#include "input.h"

#include <CoreFoundation/CoreFoundation.h>
#include <SDL3/SDL.h>
#include <pthread.h>

#include <algorithm>
#include <array>
#include <atomic>
#include <chrono>
#include <condition_variable>
#include <cstddef>
#include <cstdint>
#include <cstring>
#include <mutex>
#include <optional>
#include <span>
#include <system_error>
#include <thread>

#include "dualsense.hpp"
#include "input_commands.h"
#include "sdl_ready.hpp"
#include "switch_rumble.hpp"

namespace chiaki_bridge {

class InputThread {
 public:
  struct Traits {
    SDL_GamepadType type{SDL_GAMEPAD_TYPE_UNKNOWN};
    int player{-1};
    bool rumble{};
    bool rgb{};
    bool motion{};
    bool waveform{};
    bool triggers{};
    bool hd_rumble{};
  };

  static auto shared() -> InputThread&;
  static auto make_command(nx_input_command_kind kind, std::uint32_t instance)
      -> nx_input_command;

  InputThread() = default;
  InputThread(const InputThread&) = delete;
  auto operator=(const InputThread&) -> InputThread& = delete;
  ~InputThread();

  auto start() -> bool;
  void stop();
  auto settle(std::chrono::milliseconds timeout) -> bool;
  void listen(nx_input_listener listener, void* context);
  auto devices(std::span<nx_input_device> output) -> int;
  auto events(std::span<nx_input_event> output) -> int;
  auto fingers(std::uint32_t instance, std::span<nx_input_event> output) -> int;
  auto traits(std::uint32_t instance) -> std::optional<Traits>;
  auto enqueue(const nx_input_command& command) -> bool;
  auto waveform(std::uint32_t instance, std::span<const std::uint8_t> pcm,
                float gain) -> bool;

 private:
  enum class Phase { stopped, starting, running, stopping, failed };

  static constexpr std::size_t max_devices = 32;
  static constexpr std::size_t max_fingers = 8;
  static constexpr std::size_t event_capacity = 4096;
  static constexpr std::size_t batch_capacity = 1024;
  static constexpr int events_per_pass = 1024;
  static constexpr std::size_t effect_size = 47;
  static constexpr std::size_t trigger_size = 22;
  static constexpr Sint32 idle_wait_ms = 100;
  static constexpr Sint32 active_poll_ms = 8;
  static constexpr Sint32 trigger_poll_ms = 4;
  static constexpr Sint32 retry_wait_ms = 1;
  static constexpr std::uint64_t silence_flush_ms = 150;
  static constexpr Uint32 silence_step_ms = 5;
  static constexpr std::uint16_t playstation_vendor = 0x054c;
  static constexpr std::uint16_t dualsense_product = 0x0ce6;
  static constexpr std::uint16_t dualsense_edge_product = 0x0df2;
  static constexpr std::uint16_t enhanced_firmware = 0x0224;
  static constexpr const char* trigger_state_property =
      "SDL.joystick.chiaki.trigger_state";

  struct Entry {
    nx_input_device device{};
    Traits traits{};
    int finger_count{};
    std::array<nx_input_event, max_fingers> fingers{};
  };

  struct Outgoing {
    std::array<std::uint8_t, DualSenseReport::wave_bytes> packet{};
    std::uint64_t taken_ms{};
  };

  struct TriggerState {
    std::uint32_t instance{};
    std::int64_t state{};
  };

  using Fingers = std::span<nx_input_event, max_fingers>;

  static void silence(SDL_Gamepad* gamepad);
  static auto open_pad(SDL_JoystickID id) -> SDL_Gamepad*;
  static auto is_dualsense(std::uint16_t vendor, std::uint16_t product) -> bool;
  static auto is_dualsense(SDL_Gamepad* gamepad) -> bool;
  static auto sensor_kind(SDL_SensorType sensor) -> int;
  static auto sensor_event(const SDL_GamepadSensorEvent& event)
      -> nx_input_event;
  static auto touchpad_event(const SDL_GamepadTouchpadEvent& event)
      -> nx_input_event;
  static auto family_of(SDL_GamepadType type) -> int;
  static auto describe(SDL_JoystickID id, SDL_Gamepad* gamepad) -> Entry;
  static auto read_fingers(SDL_JoystickID id, SDL_Gamepad* gamepad,
                           Fingers output) -> int;
  static auto set_sensor(SDL_Gamepad* gamepad, SDL_SensorType sensor,
                         bool enabled) -> bool;
  static void perform_triggers(
      SDL_Gamepad* gamepad, std::span<const std::uint8_t, trigger_size> effects,
      std::uint8_t trigger_intensity, std::uint8_t haptic_intensity);
  static void perform_dualsense_rumble(SDL_Gamepad* gamepad, std::uint8_t left,
                                       std::uint8_t right,
                                       std::uint8_t trigger_intensity,
                                       std::uint8_t haptic_intensity);
  static void perform_light(SDL_Gamepad* gamepad, std::uint32_t rgb);
  static void perform_default_light(SDL_Gamepad* gamepad);
  static void flush_silence();
  static void silence_all();

  void run();
  static void raise_priority();
  void enter(Phase phase);
  void finish_pass();
  auto wait_bound() const -> Sint32;
  void wait_next(Sint32 delay_ms);
  void wake();
  auto pump(const SDL_Event* first) -> bool;
  void handle(const SDL_Event& event);
  void refresh_all();
  void add_pad(SDL_JoystickID id);
  void remove_pad(SDL_JoystickID id);
  void store(const Entry& entry);
  void mark_touched(std::uint32_t instance);
  void refresh_touched();
  void record_player(std::uint32_t instance, int player);
  void recount_dualsense();
  void publish(const nx_input_event& event);
  void deliver_batch();
  void publish_trigger_states();
  void perform_commands();
  void perform(const nx_input_command& command);
  void perform_waveform_mode(std::uint32_t instance, bool enabled);
  void pump_waveform();
  auto take_waveform(std::uint64_t now_ms) -> std::optional<Outgoing>;

  std::mutex state_mutex_;
  std::condition_variable changed_;
  std::atomic<Phase> phase_{Phase::stopped};
  std::atomic<std::uint64_t> completed_passes_{};
  std::atomic<int> settle_waiters_{};
  std::thread thread_;

  std::mutex wake_mutex_;
  std::condition_variable wake_cv_;
  bool woken_{};

  std::mutex queue_mutex_;
  nx_input_commands commands_{};
  std::array<nx_input_event, event_capacity> ring_{};
  std::size_t ring_head_{};
  std::size_t ring_count_{};

  std::mutex snapshot_mutex_;
  std::array<Entry, max_devices> snapshot_{};
  std::size_t snapshot_count_{};

  std::mutex listener_mutex_;
  nx_input_listener listener_{};
  void* listener_context_{};

  std::mutex wave_mutex_;
  WaveStream wave_stream_;
  std::uint32_t wave_instance_{};

  std::array<nx_input_event, batch_capacity> batch_{};
  std::size_t batch_count_{};
  std::array<std::uint32_t, max_devices> touched_{};
  std::size_t touched_count_{};
  std::array<TriggerState, max_devices> trigger_states_{};
  std::size_t trigger_state_count_{};
  bool dualsense_present_{};
  std::optional<Outgoing> outgoing_;
};

auto InputThread::shared() -> InputThread& {
  static InputThread thread;
  return thread;
}

auto InputThread::make_command(nx_input_command_kind kind,
                               std::uint32_t instance) -> nx_input_command {
  nx_input_command command{};
  command.kind = kind;
  command.instance = instance;
  return command;
}

InputThread::~InputThread() {
  stop();
  if (thread_.joinable()) {
    thread_.join();
  }
}

void InputThread::silence(SDL_Gamepad* gamepad) {
  SDL_RumbleGamepad(gamepad, 1, 1, 0);
  SDL_RumbleGamepadTriggers(gamepad, 1, 1, 0);
  SDL_RumbleGamepad(gamepad, 0, 0, 0);
  SDL_RumbleGamepadTriggers(gamepad, 0, 0, 0);
}

auto InputThread::open_pad(SDL_JoystickID id) -> SDL_Gamepad* {
  if (auto* existing = SDL_GetGamepadFromID(id)) {
    return existing;
  }
  auto* opened = SDL_OpenGamepad(id);
  if (opened != nullptr) {
    silence(opened);
  }
  return opened;
}

auto InputThread::is_dualsense(std::uint16_t vendor, std::uint16_t product)
    -> bool {
  return vendor == playstation_vendor &&
         (product == dualsense_product || product == dualsense_edge_product);
}

auto InputThread::is_dualsense(SDL_Gamepad* gamepad) -> bool {
  return gamepad != nullptr && is_dualsense(SDL_GetGamepadVendor(gamepad),
                                            SDL_GetGamepadProduct(gamepad));
}

auto InputThread::sensor_kind(SDL_SensorType sensor) -> int {
  switch (sensor) {
    case SDL_SENSOR_ACCEL:
      return NX_INPUT_SENSOR_ACCEL;
    case SDL_SENSOR_GYRO:
      return NX_INPUT_SENSOR_GYRO;
    default:
      return 0;
  }
}

auto InputThread::sensor_event(const SDL_GamepadSensorEvent& event)
    -> nx_input_event {
  nx_input_event output{};
  const int sensor = sensor_kind(static_cast<SDL_SensorType>(event.sensor));
  if (sensor == 0) {
    return output;
  }
  const float scale =
      sensor == NX_INPUT_SENSOR_ACCEL ? 1.0F / SDL_STANDARD_GRAVITY : 1.0F;
  output.instance = event.which;
  output.kind = NX_INPUT_EVENT_SENSOR;
  output.control = sensor;
  std::ranges::transform(event.data, output.data,
                         [scale](float value) { return value * scale; });
  const std::uint64_t nanoseconds =
      event.sensor_timestamp != 0 ? event.sensor_timestamp : event.timestamp;
  output.timestamp_us = nanoseconds / 1000;
  return output;
}

auto InputThread::touchpad_event(const SDL_GamepadTouchpadEvent& event)
    -> nx_input_event {
  nx_input_event output{};
  switch (event.type) {
    case SDL_EVENT_GAMEPAD_TOUCHPAD_DOWN:
      output.kind = NX_INPUT_EVENT_TOUCH_DOWN;
      break;
    case SDL_EVENT_GAMEPAD_TOUCHPAD_MOTION:
      output.kind = NX_INPUT_EVENT_TOUCH_MOTION;
      break;
    case SDL_EVENT_GAMEPAD_TOUCHPAD_UP:
      output.kind = NX_INPUT_EVENT_TOUCH_UP;
      break;
    default:
      return output;
  }
  output.instance = event.which;
  output.control = event.finger;
  output.value = event.touchpad;
  output.data[0] = event.x;
  output.data[1] = event.y;
  output.data[2] = event.pressure;
  output.timestamp_us = event.timestamp / 1000;
  return output;
}

auto InputThread::family_of(SDL_GamepadType type) -> int {
  switch (type) {
    case SDL_GAMEPAD_TYPE_PS3:
    case SDL_GAMEPAD_TYPE_PS4:
    case SDL_GAMEPAD_TYPE_PS5:
      return NX_INPUT_FAMILY_PLAYSTATION;
    case SDL_GAMEPAD_TYPE_XBOX360:
    case SDL_GAMEPAD_TYPE_XBOXONE:
      return NX_INPUT_FAMILY_XBOX;
    case SDL_GAMEPAD_TYPE_NINTENDO_SWITCH_PRO:
    case SDL_GAMEPAD_TYPE_NINTENDO_SWITCH_JOYCON_LEFT:
    case SDL_GAMEPAD_TYPE_NINTENDO_SWITCH_JOYCON_RIGHT:
    case SDL_GAMEPAD_TYPE_NINTENDO_SWITCH_JOYCON_PAIR:
      return NX_INPUT_FAMILY_NINTENDO;
    default:
      return NX_INPUT_FAMILY_GENERIC;
  }
}

auto InputThread::describe(SDL_JoystickID id, SDL_Gamepad* gamepad) -> Entry {
  static constexpr std::array<std::uint8_t, 8> probe{'C', 'N', 'H', '1',
                                                     0,   0,   0,   0};
  Entry entry;
  auto& device = entry.device;
  device.instance = id;
  device.vendor = SDL_GetGamepadVendor(gamepad);
  device.product = SDL_GetGamepadProduct(gamepad);
  device.connection = SDL_GetGamepadConnectionState(gamepad);
  const SDL_GamepadType type = SDL_GetGamepadType(gamepad);
  device.family = family_of(type);
  device.triggers = is_dualsense(device.vendor, device.product);
  device.waveform = device.triggers &&
                    device.connection == SDL_JOYSTICK_CONNECTION_WIRELESS &&
                    SDL_SendGamepadEffect(gamepad, probe.data(), probe.size());
  const SDL_PropertiesID properties = SDL_GetGamepadProperties(gamepad);
  device.rumble = SDL_GetBooleanProperty(
      properties, SDL_PROP_GAMEPAD_CAP_RUMBLE_BOOLEAN, false);
  device.hd_rumble =
      device.rumble && type == SDL_GAMEPAD_TYPE_NINTENDO_SWITCH_PRO;
  device.rgb = SDL_GetBooleanProperty(
      properties, SDL_PROP_GAMEPAD_CAP_RGB_LED_BOOLEAN, false);
  device.gyro = SDL_GamepadHasSensor(gamepad, SDL_SENSOR_GYRO);
  device.accel = SDL_GamepadHasSensor(gamepad, SDL_SENSOR_ACCEL);
  device.touchpad = SDL_GetNumGamepadTouchpads(gamepad) > 0;
  const char* name = SDL_GetGamepadName(gamepad);
  const char* serial = SDL_GetGamepadSerial(gamepad);
  SDL_strlcpy(device.name, name != nullptr ? name : "Controller",
              sizeof(device.name));
  SDL_strlcpy(device.serial, serial != nullptr ? serial : "",
              sizeof(device.serial));
  SDL_GUIDToString(SDL_GetGamepadGUIDForID(id), device.guid,
                   sizeof(device.guid));
  entry.traits = Traits{.type = type,
                        .player = SDL_GetGamepadPlayerIndex(gamepad),
                        .rumble = device.rumble,
                        .rgb = device.rgb,
                        .motion = device.gyro || device.accel,
                        .waveform = device.waveform,
                        .triggers = device.triggers,
                        .hd_rumble = device.hd_rumble};
  if (device.touchpad) {
    entry.finger_count = read_fingers(id, gamepad, entry.fingers);
  }
  return entry;
}

auto InputThread::read_fingers(SDL_JoystickID id, SDL_Gamepad* gamepad,
                               Fingers output) -> int {
  std::size_t count = 0;
  const int touchpads = SDL_GetNumGamepadTouchpads(gamepad);
  for (int touchpad = 0; touchpad < touchpads; ++touchpad) {
    const int fingers = SDL_GetNumGamepadTouchpadFingers(gamepad, touchpad);
    for (int finger = 0; finger < fingers && count < output.size(); ++finger) {
      bool down = false;
      float x = 0;
      float y = 0;
      float pressure = 0;
      if (!SDL_GetGamepadTouchpadFinger(gamepad, touchpad, finger, &down, &x,
                                        &y, &pressure) ||
          !down) {
        continue;
      }
      output[count] = nx_input_event{.instance = id,
                                     .kind = NX_INPUT_EVENT_TOUCH_DOWN,
                                     .control = finger,
                                     .value = touchpad,
                                     .data = {x, y, pressure},
                                     .timestamp_us = 0};
      ++count;
    }
  }
  return static_cast<int>(count);
}

auto InputThread::set_sensor(SDL_Gamepad* gamepad, SDL_SensorType sensor,
                             bool enabled) -> bool {
  if (!SDL_GamepadHasSensor(gamepad, sensor)) {
    return false;
  }
  if (SDL_GamepadSensorEnabled(gamepad, sensor) == enabled) {
    return true;
  }
  return SDL_SetGamepadSensorEnabled(gamepad, sensor, enabled);
}

void InputThread::perform_triggers(
    SDL_Gamepad* gamepad, std::span<const std::uint8_t, trigger_size> effects,
    std::uint8_t trigger_intensity, std::uint8_t haptic_intensity) {
  std::array<std::uint8_t, effect_size> packet{};
  DualSenseReport::triggers(effects, packet);
  packet[1] = 0x40;
  packet[36] =
      DualSenseReport::power_reduction(trigger_intensity, haptic_intensity);
  SDL_SendGamepadEffect(gamepad, packet.data(), packet.size());
}

void InputThread::perform_dualsense_rumble(SDL_Gamepad* gamepad,
                                           std::uint8_t left,
                                           std::uint8_t right,
                                           std::uint8_t trigger_intensity,
                                           std::uint8_t haptic_intensity) {
  const Uint16 firmware = SDL_GetGamepadFirmwareVersion(gamepad);
  const bool enhanced =
      SDL_GetGamepadProduct(gamepad) == dualsense_edge_product ||
      firmware == 0 || firmware >= enhanced_firmware;
  std::array<std::uint8_t, effect_size> packet{};
  DualSenseReport::rumble(
      left, right, enhanced,
      DualSenseReport::power_reduction(trigger_intensity, haptic_intensity),
      packet);
  SDL_SendGamepadEffect(gamepad, packet.data(), packet.size());
}

void InputThread::perform_light(SDL_Gamepad* gamepad, std::uint32_t rgb) {
  SDL_SetGamepadLED(gamepad, static_cast<Uint8>(rgb >> 16),
                    static_cast<Uint8>(rgb >> 8), static_cast<Uint8>(rgb));
}

void InputThread::perform_default_light(SDL_Gamepad* gamepad) {
  static constexpr std::array<std::uint32_t, 7> ps5{
      0x000040, 0x400000, 0x004000, 0x200020, 0x201000, 0x001010, 0x101010};
  static constexpr std::array<std::uint32_t, 7> ps4{
      0x000040, 0x400000, 0x004000, 0x200020, 0x020100, 0x000101, 0x010101};
  const SDL_GamepadType type = SDL_GetGamepadType(gamepad);
  const int player = SDL_GetGamepadPlayerIndex(gamepad);
  const std::size_t slot =
      player >= 0 ? static_cast<std::size_t>(player) % ps5.size() : 0;
  perform_light(gamepad, type == SDL_GAMEPAD_TYPE_PS5 ? ps5[slot] : ps4[slot]);
}

void InputThread::flush_silence() {
  const std::uint64_t deadline = SDL_GetTicks() + silence_flush_ms;
  while (SDL_GetTicks() < deadline) {
    SDL_UpdateGamepads();
    SDL_Delay(silence_step_ms);
  }
}

void InputThread::silence_all() {
  int total = 0;
  SDL_JoystickID* ids = SDL_GetGamepads(&total);
  if (ids == nullptr) {
    return;
  }
  for (const SDL_JoystickID id :
       std::span{ids, static_cast<std::size_t>(std::max(total, 0))}) {
    if (auto* gamepad = SDL_GetGamepadFromID(id)) {
      silence(gamepad);
    }
  }
  SDL_free(ids);
  if (total > 0) {
    flush_silence();
  }
}

auto InputThread::start() -> bool {
  std::unique_lock lock(state_mutex_);
  if (phase_.load() == Phase::stopped) {
    phase_.store(Phase::starting);
    {
      const std::lock_guard queue(queue_mutex_);
      nx_input_commands_reset(&commands_);
      ring_head_ = 0;
      ring_count_ = 0;
    }
    try {
      thread_ = std::thread([this] { run(); });
    } catch (const std::system_error&) {
      phase_.store(Phase::failed);
    }
  }
  changed_.wait(lock, [this] { return phase_.load() != Phase::stopping; });
  const Phase phase = phase_.load();
  return phase == Phase::starting || phase == Phase::running;
}

void InputThread::stop() {
  std::unique_lock lock(state_mutex_);
  changed_.wait(lock, [this] { return phase_.load() != Phase::starting; });
  if (phase_.load() != Phase::running) {
    return;
  }
  phase_.store(Phase::stopping);
  std::thread joining = std::move(thread_);
  lock.unlock();
  wake();
  joining.join();
  {
    const std::lock_guard snapshot(snapshot_mutex_);
    snapshot_count_ = 0;
  }
  lock.lock();
  phase_.store(Phase::stopped);
  changed_.notify_all();
}

auto InputThread::settle(std::chrono::milliseconds timeout) -> bool {
  std::unique_lock lock(state_mutex_);
  const std::uint64_t target = completed_passes_.load() + 2;
  settle_waiters_.fetch_add(1);
  wake();
  static_cast<void>(changed_.wait_for(lock, timeout, [this, target] {
    const Phase phase = phase_.load();
    return (phase != Phase::starting && phase != Phase::running) ||
           completed_passes_.load() >= target;
  }));
  settle_waiters_.fetch_sub(1);
  return phase_.load() == Phase::running && completed_passes_.load() >= target;
}

void InputThread::listen(nx_input_listener listener, void* context) {
  const std::lock_guard lock(listener_mutex_);
  listener_ = listener;
  listener_context_ = context;
}

auto InputThread::devices(std::span<nx_input_device> output) -> int {
  const std::lock_guard lock(snapshot_mutex_);
  const std::size_t count = std::min(snapshot_count_, output.size());
  for (std::size_t index = 0; index < count; ++index) {
    output[index] = snapshot_[index].device;
  }
  return static_cast<int>(count);
}

auto InputThread::events(std::span<nx_input_event> output) -> int {
  const std::lock_guard lock(queue_mutex_);
  std::size_t count = 0;
  while (count < output.size() && ring_count_ > 0) {
    output[count] = ring_[ring_head_];
    ++count;
    ring_head_ = (ring_head_ + 1) % event_capacity;
    --ring_count_;
  }
  return static_cast<int>(count);
}

auto InputThread::fingers(std::uint32_t instance,
                          std::span<nx_input_event> output) -> int {
  const std::lock_guard lock(snapshot_mutex_);
  const auto entries = std::span{snapshot_}.first(snapshot_count_);
  const auto found = std::ranges::find(
      entries, instance, [](const Entry& e) { return e.device.instance; });
  if (found == entries.end()) {
    return 0;
  }
  const std::size_t count =
      std::min(static_cast<std::size_t>(found->finger_count), output.size());
  std::copy_n(found->fingers.begin(), count, output.begin());
  return static_cast<int>(count);
}

auto InputThread::traits(std::uint32_t instance) -> std::optional<Traits> {
  const std::lock_guard lock(snapshot_mutex_);
  const auto entries = std::span{snapshot_}.first(snapshot_count_);
  const auto found = std::ranges::find(
      entries, instance, [](const Entry& e) { return e.device.instance; });
  if (found == entries.end()) {
    return std::nullopt;
  }
  return found->traits;
}

auto InputThread::enqueue(const nx_input_command& command) -> bool {
  bool queued = false;
  {
    const std::lock_guard lock(queue_mutex_);
    queued = nx_input_commands_push(&commands_, &command);
  }
  if (queued) {
    wake();
  }
  return queued;
}

auto InputThread::waveform(std::uint32_t instance,
                           std::span<const std::uint8_t> pcm, float gain)
    -> bool {
  const std::uint64_t now = SDL_GetTicks();
  bool ready = false;
  {
    const std::lock_guard lock(wave_mutex_);
    if (wave_instance_ != instance || !wave_stream_.push(pcm, gain, now)) {
      return false;
    }
    ready = wave_stream_.frames() >= DualSenseReport::wave_frames;
  }
  if (ready) {
    wake();
  }
  return true;
}

void InputThread::wake() {
  {
    const std::lock_guard lock(wake_mutex_);
    woken_ = true;
  }
  wake_cv_.notify_one();
}

void InputThread::wait_next(Sint32 delay_ms) {
  std::unique_lock lock(wake_mutex_);
  if (!woken_ && delay_ms > 0 && phase_.load() == Phase::running &&
      settle_waiters_.load() == 0) {
    wake_cv_.wait_for(lock, std::chrono::milliseconds(delay_ms), [this] {
      return woken_ || phase_.load() != Phase::running ||
             settle_waiters_.load() > 0;
    });
  }
  woken_ = false;
}

void InputThread::raise_priority() {
  pthread_setname_np("ChiakiInput");
  pthread_set_qos_class_self_np(QOS_CLASS_USER_INTERACTIVE, 0);
}

void InputThread::enter(Phase phase) {
  const std::lock_guard lock(state_mutex_);
  phase_.store(phase);
  changed_.notify_all();
}

void InputThread::finish_pass() {
  completed_passes_.fetch_add(1);
  if (settle_waiters_.load() > 0) {
    const std::lock_guard lock(state_mutex_);
    changed_.notify_all();
  }
}

auto InputThread::wait_bound() const -> Sint32 {
  if (settle_waiters_.load() > 0) {
    return 0;
  }
  if (outgoing_) {
    return retry_wait_ms;
  }
  if (dualsense_present_) {
    return trigger_poll_ms;
  }
  return snapshot_count_ > 0 ? active_poll_ms : idle_wait_ms;
}

void InputThread::run() {
  raise_priority();
#if TARGET_OS_OSX
  SDL_SetHint(SDL_HINT_JOYSTICK_MFI, "0");
#endif
  SDL_SetHint(SDL_HINT_JOYSTICK_ALLOW_BACKGROUND_EVENTS, "1");
  SdlReady::mark();
  const bool ready = SDL_InitSubSystem(SDL_INIT_GAMEPAD);
  enter(ready ? Phase::running : Phase::failed);
  if (!ready) {
    return;
  }
  refresh_all();
  while (phase_.load() == Phase::running) {
    CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0, true);
    SDL_PumpEvents();
    SDL_Event first;
    const bool has_event = SDL_PollEvent(&first);
    const bool more_events = pump(has_event ? &first : nullptr);
    deliver_batch();
    perform_commands();
    pump_waveform();
    finish_pass();
    if (!more_events) {
      wait_next(wait_bound());
    }
  }
  perform_commands();
  silence_all();
  SDL_QuitSubSystem(SDL_INIT_GAMEPAD);
}

auto InputThread::pump(const SDL_Event* first) -> bool {
  batch_count_ = 0;
  touched_count_ = 0;
  bool more_events = false;
  if (first != nullptr) {
    handle(*first);
    SDL_Event event;
    int processed = 1;
    while (processed < events_per_pass && SDL_PollEvent(&event)) {
      handle(event);
      ++processed;
    }
    more_events = processed >= events_per_pass;
  }
  refresh_touched();
  publish_trigger_states();
  return more_events;
}

void InputThread::handle(const SDL_Event& event) {
  nx_input_event output{};
  switch (event.type) {
    case SDL_EVENT_GAMEPAD_ADDED:
      add_pad(event.gdevice.which);
      output.instance = event.gdevice.which;
      output.kind = NX_INPUT_EVENT_ADDED;
      break;
    case SDL_EVENT_GAMEPAD_REMOVED: {
      output.instance = event.gdevice.which;
      output.kind = NX_INPUT_EVENT_REMOVED;
      if (auto* gamepad = SDL_GetGamepadFromID(output.instance)) {
        SDL_CloseGamepad(gamepad);
      }
      {
        const std::lock_guard lock(queue_mutex_);
        nx_input_commands_forget(&commands_, output.instance);
      }
      remove_pad(event.gdevice.which);
      break;
    }
    case SDL_EVENT_GAMEPAD_REMAPPED:
      add_pad(event.gdevice.which);
      break;
    case SDL_EVENT_GAMEPAD_BUTTON_DOWN:
    case SDL_EVENT_GAMEPAD_BUTTON_UP:
      output.instance = event.gbutton.which;
      output.kind = NX_INPUT_EVENT_BUTTON;
      output.control = event.gbutton.button;
      output.value = event.gbutton.down;
      output.timestamp_us = event.gbutton.timestamp / 1000;
      break;
    case SDL_EVENT_GAMEPAD_AXIS_MOTION:
      output.instance = event.gaxis.which;
      output.kind = NX_INPUT_EVENT_AXIS;
      output.control = event.gaxis.axis;
      output.value = event.gaxis.value;
      output.timestamp_us = event.gaxis.timestamp / 1000;
      break;
    case SDL_EVENT_GAMEPAD_SENSOR_UPDATE:
      output = sensor_event(event.gsensor);
      break;
    case SDL_EVENT_GAMEPAD_TOUCHPAD_DOWN:
    case SDL_EVENT_GAMEPAD_TOUCHPAD_MOTION:
    case SDL_EVENT_GAMEPAD_TOUCHPAD_UP:
      output = touchpad_event(event.gtouchpad);
      mark_touched(event.gtouchpad.which);
      break;
    default:
      break;
  }
  if (output.kind != 0) {
    publish(output);
  }
}

void InputThread::refresh_all() {
  int total = 0;
  SDL_JoystickID* ids = SDL_GetGamepads(&total);
  if (ids == nullptr) {
    return;
  }
  for (const SDL_JoystickID id :
       std::span{ids, static_cast<std::size_t>(std::max(total, 0))}) {
    add_pad(id);
  }
  SDL_free(ids);
}

void InputThread::add_pad(SDL_JoystickID id) {
  SDL_Gamepad* gamepad = open_pad(id);
  if (gamepad == nullptr) {
    return;
  }
  store(describe(id, gamepad));
  recount_dualsense();
}

void InputThread::store(const Entry& entry) {
  const std::lock_guard lock(snapshot_mutex_);
  const auto entries = std::span{snapshot_}.first(snapshot_count_);
  const auto found = std::ranges::find(
      entries, entry.device.instance,
      [](const Entry& existing) { return existing.device.instance; });
  if (found != entries.end()) {
    *found = entry;
    return;
  }
  if (snapshot_count_ < snapshot_.size()) {
    snapshot_[snapshot_count_] = entry;
    ++snapshot_count_;
  }
}

void InputThread::remove_pad(SDL_JoystickID id) {
  {
    const std::lock_guard lock(snapshot_mutex_);
    const auto entries = std::span{snapshot_}.first(snapshot_count_);
    const auto removed = std::ranges::remove(
        entries, id, [](const Entry& entry) { return entry.device.instance; });
    snapshot_count_ -= removed.size();
  }
  recount_dualsense();
}

void InputThread::recount_dualsense() {
  const auto entries = std::span{snapshot_}.first(snapshot_count_);
  dualsense_present_ = std::ranges::any_of(
      entries, [](const Entry& entry) { return entry.device.triggers; });
}

void InputThread::mark_touched(std::uint32_t instance) {
  const auto touched = std::span{touched_}.first(touched_count_);
  if (std::ranges::find(touched, instance) != touched.end() ||
      touched_count_ == touched_.size()) {
    return;
  }
  touched_[touched_count_] = instance;
  ++touched_count_;
}

void InputThread::refresh_touched() {
  for (const std::uint32_t instance :
       std::span{touched_}.first(touched_count_)) {
    std::array<nx_input_event, max_fingers> fresh{};
    SDL_Gamepad* gamepad = SDL_GetGamepadFromID(instance);
    const int count =
        gamepad != nullptr ? read_fingers(instance, gamepad, fresh) : 0;
    const std::lock_guard lock(snapshot_mutex_);
    const auto entries = std::span{snapshot_}.first(snapshot_count_);
    const auto found = std::ranges::find(
        entries, instance,
        [](const Entry& entry) { return entry.device.instance; });
    if (found != entries.end()) {
      found->finger_count = count;
      found->fingers = fresh;
    }
  }
}

void InputThread::record_player(std::uint32_t instance, int player) {
  const std::lock_guard lock(snapshot_mutex_);
  for (auto& entry : std::span{snapshot_}.first(snapshot_count_)) {
    if (entry.device.instance == instance) {
      entry.traits.player = player;
    }
  }
}

void InputThread::publish(const nx_input_event& event) {
  if (batch_count_ < batch_.size()) {
    batch_[batch_count_] = event;
    ++batch_count_;
  }
  const std::lock_guard lock(queue_mutex_);
  if (ring_count_ == event_capacity) {
    ring_head_ = (ring_head_ + 1) % event_capacity;
    --ring_count_;
  }
  ring_[(ring_head_ + ring_count_) % event_capacity] = event;
  ++ring_count_;
}

void InputThread::deliver_batch() {
  nx_input_listener current = nullptr;
  void* context = nullptr;
  {
    const std::lock_guard lock(listener_mutex_);
    current = listener_;
    context = listener_context_;
  }
  if (current != nullptr && batch_count_ > 0) {
    current(batch_.data(), static_cast<int>(batch_count_), context);
  }
  batch_count_ = 0;
}

void InputThread::publish_trigger_states() {
  if (!dualsense_present_ && trigger_state_count_ == 0) {
    return;
  }
  std::array<TriggerState, max_devices> current{};
  std::size_t count = 0;
  for (const auto& entry : std::span{snapshot_}.first(snapshot_count_)) {
    const std::uint32_t instance = entry.device.instance;
    SDL_Gamepad* gamepad = SDL_GetGamepadFromID(instance);
    const std::int64_t state =
        is_dualsense(gamepad)
            ? SDL_GetNumberProperty(SDL_GetGamepadProperties(gamepad),
                                    trigger_state_property, 0)
            : 0;
    const auto known = std::span{trigger_states_}.first(trigger_state_count_);
    const auto previous =
        std::ranges::find(known, instance, &TriggerState::instance);
    const std::int64_t before = previous != known.end() ? previous->state : 0;
    if (state != before) {
      nx_input_event output{};
      output.instance = instance;
      output.kind = NX_INPUT_EVENT_TRIGGER_STATE;
      output.value = static_cast<int>(state);
      publish(output);
    }
    if (state != 0) {
      current[count] = TriggerState{.instance = instance, .state = state};
      ++count;
    }
  }
  trigger_states_ = current;
  trigger_state_count_ = count;
}

void InputThread::perform_commands() {
  for (;;) {
    nx_input_command command{};
    bool next = false;
    {
      const std::lock_guard lock(queue_mutex_);
      next = nx_input_commands_pop(&commands_, &command);
    }
    if (!next) {
      return;
    }
    perform(command);
  }
}

void InputThread::perform_waveform_mode(std::uint32_t instance, bool enabled) {
  SDL_Gamepad* gamepad = SDL_GetGamepadFromID(instance);
  const std::array<std::uint8_t, 8> command{
      'C', 'N', 'H', '1', static_cast<std::uint8_t>(enabled ? 1 : 2), 0, 0, 0};
  const bool applied =
      gamepad != nullptr &&
      SDL_GetGamepadType(gamepad) == SDL_GAMEPAD_TYPE_PS5 &&
      SDL_SendGamepadEffect(gamepad, command.data(), command.size());
  bool cleared = false;
  {
    const std::lock_guard lock(wave_mutex_);
    if (enabled && applied) {
      wave_stream_.reset();
      wave_instance_ = instance;
      cleared = true;
    } else if (wave_instance_ == instance) {
      wave_stream_.reset();
      wave_instance_ = 0;
      cleared = true;
    }
  }
  if (cleared) {
    outgoing_.reset();
  }
}

void InputThread::perform(const nx_input_command& command) {
  if (command.kind == NX_INPUT_COMMAND_WAVEFORM_MODE) {
    perform_waveform_mode(command.instance, command.value.enabled);
    return;
  }
  SDL_Gamepad* gamepad = SDL_GetGamepadFromID(command.instance);
  if (gamepad == nullptr) {
    return;
  }
  switch (command.kind) {
    case NX_INPUT_COMMAND_RUMBLE:
      SDL_RumbleGamepad(gamepad, command.value.rumble.low,
                        command.value.rumble.high,
                        command.value.rumble.duration);
      break;
    case NX_INPUT_COMMAND_DUALSENSE_RUMBLE:
      perform_dualsense_rumble(gamepad, command.value.dualsense.left,
                               command.value.dualsense.right,
                               command.value.dualsense.trigger_intensity,
                               command.value.dualsense.haptic_intensity);
      break;
    case NX_INPUT_COMMAND_SWITCH_RUMBLE: {
      std::array<std::uint8_t, SwitchRumble::packet_size> packet{};
      SwitchRumble::packet(
          {command.value.amplitude[0], command.value.amplitude[1]}, packet);
      SDL_SendGamepadEffect(gamepad, packet.data(), packet.size());
      break;
    }
    case NX_INPUT_COMMAND_TRIGGERS:
      perform_triggers(gamepad,
                       std::span<const std::uint8_t, trigger_size>{
                           command.value.triggers.effects},
                       command.value.triggers.trigger_intensity,
                       command.value.triggers.haptic_intensity);
      break;
    case NX_INPUT_COMMAND_MIC_LIGHT: {
      std::array<std::uint8_t, effect_size> packet{};
      DualSenseReport::mic_light(command.value.enabled, packet);
      SDL_SendGamepadEffect(gamepad, packet.data(), packet.size());
      break;
    }
    case NX_INPUT_COMMAND_SPEAKER: {
      std::array<std::uint8_t, effect_size> packet{};
      DualSenseReport::speaker(command.value.enabled, packet);
      SDL_SendGamepadEffect(gamepad, packet.data(), packet.size());
      break;
    }
    case NX_INPUT_COMMAND_LIGHT:
      perform_light(gamepad, command.value.rgb);
      break;
    case NX_INPUT_COMMAND_DEFAULT_LIGHT:
      perform_default_light(gamepad);
      break;
    case NX_INPUT_COMMAND_PLAYER:
      if (SDL_SetGamepadPlayerIndex(gamepad, command.value.player)) {
        record_player(command.instance, command.value.player);
      }
      break;
    case NX_INPUT_COMMAND_MOTION:
      set_sensor(gamepad, SDL_SENSOR_GYRO, command.value.enabled);
      set_sensor(gamepad, SDL_SENSOR_ACCEL, command.value.enabled);
      break;
    case NX_INPUT_COMMAND_RESET_FEEDBACK: {
      perform_waveform_mode(command.instance, false);
      if (is_dualsense(gamepad)) {
        std::array<std::uint8_t, trigger_size> triggers{};
        triggers[0] = 5;
        triggers[11] = 5;
        perform_triggers(gamepad, triggers, 0, 1);
        perform_dualsense_rumble(gamepad, 0, 0, 0, 1);
      }
      SDL_RumbleGamepad(gamepad, 0, 0, 0);
      break;
    }
    case NX_INPUT_COMMAND_WAVEFORM_MODE:
      break;
  }
}

auto InputThread::take_waveform(std::uint64_t now_ms)
    -> std::optional<Outgoing> {
  Outgoing taken{.packet = {}, .taken_ms = now_ms};
  const std::lock_guard lock(wave_mutex_);
  if (wave_instance_ == 0) {
    return std::nullopt;
  }
  wave_stream_.expire(now_ms);
  if (!wave_stream_.peek(taken.packet)) {
    return std::nullopt;
  }
  wave_stream_.consume();
  return taken;
}

void InputThread::pump_waveform() {
  const std::uint32_t instance = wave_instance_;
  if (instance == 0) {
    outgoing_.reset();
    return;
  }
  SDL_Gamepad* gamepad = SDL_GetGamepadFromID(instance);
  const std::uint64_t now = SDL_GetTicks();
  if (gamepad == nullptr) {
    outgoing_.reset();
    return;
  }
  for (;;) {
    if (outgoing_ && now - outgoing_->taken_ms > WaveStream::stale_ms) {
      outgoing_.reset();
    }
    if (!outgoing_) {
      outgoing_ = take_waveform(now);
    }
    if (!outgoing_ || !SDL_SendGamepadEffect(gamepad, outgoing_->packet.data(),
                                             outgoing_->packet.size())) {
      return;
    }
    outgoing_.reset();
  }
}

}  // namespace chiaki_bridge

bool nx_input_init(void) {
  return chiaki_bridge::InputThread::shared().start();
}

void nx_input_quit(void) { chiaki_bridge::InputThread::shared().stop(); }

bool nx_input_settle(uint32_t timeout_ms) {
  return chiaki_bridge::InputThread::shared().settle(
      std::chrono::milliseconds{timeout_ms});
}

int nx_input_devices(nx_input_device* devices, int capacity) {
  if (!nx_input_init() || devices == nullptr || capacity < 1) {
    return -1;
  }
  return chiaki_bridge::InputThread::shared().devices(
      std::span{devices, static_cast<std::size_t>(capacity)});
}

int nx_input_touch_fingers(uint32_t instance, nx_input_event* events,
                           int capacity) {
  if (events == nullptr || capacity < 1) {
    return 0;
  }
  return chiaki_bridge::InputThread::shared().fingers(
      instance, std::span{events, static_cast<std::size_t>(capacity)});
}

int nx_input_events(nx_input_event* events, int capacity) {
  if (events == nullptr || capacity < 1) {
    return 0;
  }
  return chiaki_bridge::InputThread::shared().events(
      std::span{events, static_cast<std::size_t>(capacity)});
}

bool nx_input_motion(uint32_t instance, bool enabled) {
  const auto traits = chiaki_bridge::InputThread::shared().traits(instance);
  if (!traits || !traits->motion) {
    return false;
  }
  auto command = chiaki_bridge::InputThread::make_command(
      NX_INPUT_COMMAND_MOTION, instance);
  command.value.enabled = enabled;
  return chiaki_bridge::InputThread::shared().enqueue(command);
}

bool nx_input_rumble(uint32_t instance, uint16_t low, uint16_t high,
                     uint32_t duration) {
  const auto traits = chiaki_bridge::InputThread::shared().traits(instance);
  if (!traits || !traits->rumble) {
    return false;
  }
  auto command = chiaki_bridge::InputThread::make_command(
      NX_INPUT_COMMAND_RUMBLE, instance);
  command.value.rumble.low = low;
  command.value.rumble.high = high;
  command.value.rumble.duration = duration;
  return chiaki_bridge::InputThread::shared().enqueue(command);
}

bool nx_input_waveform_mode(uint32_t instance, bool enabled) {
  const auto traits = chiaki_bridge::InputThread::shared().traits(instance);
  if (!traits || traits->type != SDL_GAMEPAD_TYPE_PS5 ||
      (enabled && !traits->waveform)) {
    return false;
  }
  auto command = chiaki_bridge::InputThread::make_command(
      NX_INPUT_COMMAND_WAVEFORM_MODE, instance);
  command.value.enabled = enabled;
  return chiaki_bridge::InputThread::shared().enqueue(command);
}

bool nx_input_waveform(uint32_t instance, const uint8_t* pcm, int size,
                       float gain) {
  if (pcm == nullptr || size <= 0) {
    return false;
  }
  return chiaki_bridge::InputThread::shared().waveform(
      instance, std::span{pcm, static_cast<std::size_t>(size)}, gain);
}

bool nx_input_triggers(uint32_t instance, const uint8_t effects[22],
                       uint8_t trigger_intensity, uint8_t haptic_intensity) {
  if (effects == nullptr) {
    return false;
  }
  const auto traits = chiaki_bridge::InputThread::shared().traits(instance);
  if (!traits || !traits->triggers) {
    return false;
  }
  auto command = chiaki_bridge::InputThread::make_command(
      NX_INPUT_COMMAND_TRIGGERS, instance);
  std::memcpy(command.value.triggers.effects, effects,
              sizeof(command.value.triggers.effects));
  command.value.triggers.trigger_intensity = trigger_intensity;
  command.value.triggers.haptic_intensity = haptic_intensity;
  return chiaki_bridge::InputThread::shared().enqueue(command);
}

bool nx_input_dualsense_rumble(uint32_t instance, uint8_t left, uint8_t right,
                               uint8_t trigger_intensity,
                               uint8_t haptic_intensity) {
  const auto traits = chiaki_bridge::InputThread::shared().traits(instance);
  if (!traits || !traits->triggers) {
    return false;
  }
  auto command = chiaki_bridge::InputThread::make_command(
      NX_INPUT_COMMAND_DUALSENSE_RUMBLE, instance);
  command.value.dualsense.left = left;
  command.value.dualsense.right = right;
  command.value.dualsense.trigger_intensity = trigger_intensity;
  command.value.dualsense.haptic_intensity = haptic_intensity;
  return chiaki_bridge::InputThread::shared().enqueue(command);
}

bool nx_input_switch_rumble(uint32_t instance, const float amplitude[2]) {
  if (amplitude == nullptr) {
    return false;
  }
  const auto traits = chiaki_bridge::InputThread::shared().traits(instance);
  if (!traits || !traits->hd_rumble) {
    return false;
  }
  auto command = chiaki_bridge::InputThread::make_command(
      NX_INPUT_COMMAND_SWITCH_RUMBLE, instance);
  command.value.amplitude[0] = amplitude[0];
  command.value.amplitude[1] = amplitude[1];
  return chiaki_bridge::InputThread::shared().enqueue(command);
}

bool nx_input_mic_light(uint32_t instance, bool lit) {
  const auto traits = chiaki_bridge::InputThread::shared().traits(instance);
  if (!traits || !traits->triggers) {
    return false;
  }
  auto command = chiaki_bridge::InputThread::make_command(
      NX_INPUT_COMMAND_MIC_LIGHT, instance);
  command.value.enabled = lit;
  return chiaki_bridge::InputThread::shared().enqueue(command);
}

bool nx_input_dualsense_speaker(uint32_t instance, bool enabled) {
  const auto traits = chiaki_bridge::InputThread::shared().traits(instance);
  if (!traits || !traits->triggers) {
    return false;
  }
  auto command = chiaki_bridge::InputThread::make_command(
      NX_INPUT_COMMAND_SPEAKER, instance);
  command.value.enabled = enabled;
  return chiaki_bridge::InputThread::shared().enqueue(command);
}

void nx_input_reset_feedback(uint32_t instance) {
  if (chiaki_bridge::InputThread::shared().traits(instance)) {
    chiaki_bridge::InputThread::shared().enqueue(
        chiaki_bridge::InputThread::make_command(
            NX_INPUT_COMMAND_RESET_FEEDBACK, instance));
  }
}

bool nx_input_light(uint32_t instance, uint32_t rgb) {
  if (rgb > 0xffffff) {
    return false;
  }
  const auto traits = chiaki_bridge::InputThread::shared().traits(instance);
  if (!traits || !traits->rgb) {
    return false;
  }
  auto command = chiaki_bridge::InputThread::make_command(
      NX_INPUT_COMMAND_LIGHT, instance);
  command.value.rgb = rgb;
  return chiaki_bridge::InputThread::shared().enqueue(command);
}

bool nx_input_player(uint32_t instance, int player) {
  if (player < -1 || player >= 8 ||
      !chiaki_bridge::InputThread::shared().traits(instance)) {
    return false;
  }
  auto command = chiaki_bridge::InputThread::make_command(
      NX_INPUT_COMMAND_PLAYER, instance);
  command.value.player = player;
  return chiaki_bridge::InputThread::shared().enqueue(command);
}

void nx_input_set_listener(nx_input_listener next, void* context) {
  chiaki_bridge::InputThread::shared().listen(next, context);
}

uint64_t nx_input_now_us(void) { return SDL_GetTicksNS() / 1000; }

int nx_input_player_index(uint32_t instance) {
  const auto traits = chiaki_bridge::InputThread::shared().traits(instance);
  return traits ? traits->player : -1;
}

bool nx_input_default_light(uint32_t instance) {
  const auto traits = chiaki_bridge::InputThread::shared().traits(instance);
  if (!traits ||
      (traits->type != SDL_GAMEPAD_TYPE_PS5 &&
       traits->type != SDL_GAMEPAD_TYPE_PS4) ||
      !traits->rgb) {
    return false;
  }
  return chiaki_bridge::InputThread::shared().enqueue(
      chiaki_bridge::InputThread::make_command(NX_INPUT_COMMAND_DEFAULT_LIGHT,
                                               instance));
}
