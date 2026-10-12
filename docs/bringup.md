# First bring-up of the Module LLM

Do this once, before `./install.sh`.

## 1. Power and console

- Slide the Module LLM's speaker aside and attach the FPC-8P cable to the LLM Mate.
- Ethernet to the LAN. 5 V supply (not a laptop USB port — idle 0.5 W, load 1.5 W).
- Console: Mate Type-C to the PC -> `/dev/ttyUSB0`, 115200 8N1.
  Login: `root` / `123456`.

```sh
picocom -b 115200 /dev/ttyUSB0   # or: python -m serial.tools.miniter /dev/ttyUSB0 115200
```

## 2. Change the password, get the IP

```sh
passwd
ip a      # note the eth0 address, e.g. 192.168.1.X
```

## 3. Verify audio (from the console or SSH)

```sh
arecord -L | grep plughw          # expect plughw:0,0 (MSM421A mic)
aplay -L  | grep plughw           # expect plughw:0,1 (AW8737 speaker)
arecord -D plughw:0,0 -f S32_LE -r 16000 -c 2 -d 3 /tmp/t.raw
```

Two hardware quirks to expect (both confirmed on the shipped image):

- **The mic is on capture channel 1, and channel 0 is dead silence.** Capture is
  fixed stereo S32_LE; `arecord -c 1` fails outright with `Channels count non
  available`. LVA therefore captures mono through PipeWire, which downmixes
  ch0+ch1, so the real signal arrives at roughly half amplitude.
- **`TX LR SWAP` does nothing on this codec.** It stays `off`; use
  `TX RIGHT DIG GAIN` to affect the mic.

## 4. Set the codec mixer state (REQUIRED for the wake word)

**The vendor image applies no mixer state at boot.** Out of the box the hardware
ALC is OFF, and microWakeWord's "okay nabu" never crosses its 0.85 cutoff on
this signal. Measured max probability, same stimulus and same mic:

| `ALC ENABLE` | max `okay nabu` probability |
|---|---|
| off (ship default) | 0.17 - 0.57 |
| on | 0.92 - 0.95 |

So ALC on is the difference between "never wakes" and "wakes reliably".
`setup-module.sh` installs `lva-audio-init.service`, a oneshot unit that applies
the known-good state before LVA starts. Verify it after install, and re-check
after any reboot:

```sh
for c in "INPUT MUX" "ALC ENABLE" "TX LEFT DIG GAIN" "TX RIGHT DIG GAIN"; do
  printf '%-20s ' "$c"; amixer -c 0 sget "$c" | tail -1
done
# expect: FROM AMIC / on / 15 / 15
```

If you ever need to reapply by hand: `/usr/local/sbin/lva-audio-init.sh`.

Note: capture TX digital gain (0-120) moves the level only a few dB across its
whole range and did not change wake-word scores; the hardware ALC is the lever.

### `DAC MUTE` looks wrong at idle - it is not a bug

`amixer -c 0 cget name='DAC MUTE'` reports `values=on` while nothing is playing
and `values=off` while a stream is open. The Axera codec driver toggles it
around PCM start/stop; it is not a persisted mixer state and it does not block
sound. Do not chase it: after a real `systemctl reboot` with the setup below,
the wake chime, the processing sound and a TTS response all come out of the
speaker, and `DAC MUTE` still reads `on` when idle.

What *was* a bug is the thing that restores it. The vendor image has two ALSA
state restorers - `alsa-restore.service` and `/lib/udev/rules.d/90-alsa-restore.rules`
(which runs `alsactl restore` on every `controlC*` add) - and `/var/lib/alsa/asound.state`
held `name 'DAC MUTE' value true`. Either one can run after `lva-audio-init`
and clobber it, at a point in boot where nothing re-applies the good state. So
`setup-module.sh` deletes the saved state, masks the service, and installs an
**empty** `/etc/udev/rules.d/90-alsa-restore.rules` to shadow the vendor rule
(an empty file in `/etc/udev/rules.d` wins over the same name in `/lib`).
`lva-audio-init.sh` then waits for `/dev/snd/controlC0` before touching the
codec, applies the state, reads `ALC ENABLE` and `DAC MUTE` back, and retries up
to 10 times. Success looks like:

```
lva-audio-init[1651]: lva-audio-init: ALC on and DAC unmuted
```

Check after any reboot:

```sh
systemctl is-enabled alsa-restore            # masked
ls /var/lib/alsa/                            # empty
journalctl -u lva-audio-init -b --no-pager   # the line above
```

## 5. Verify the LEDs

```sh
ls /sys/class/leds/
# for each entry with a brightness file:
echo 100 > /sys/class/leds/<name>/brightness
```

Record the exact channel names. `led/led_status.py` auto-detects them, but the
first run must be checked by eye. The shipped unit runs it with `--debug`, which
is what makes it log every event, so the state machine is visible without
watching a lamp:

```sh
journalctl -u lva-led-bridge -f
# event=snapshot data={'muted': False, ..., 'ha_connected': False}
# event=disconnected data={}
```

Without `--debug` the bridge is silent and indistinguishable from a broken one -
it can be connected and driving the LEDs correctly while logging nothing at all.

## 6. Install from the PC

```sh
cd ~/AX630C-ha-voice-satellite
MODULE_IP=192.168.1.X ./install.sh

# this module's root login rejects the default key ("Operation not permitted"):
MODULE_IP=192.168.1.X SSH_OPTS="-i ~/.ssh/id_ed25519_m5llm" ./install.sh
```

The LVA build compiles on-device (2x Cortex-A53). Expect 10-20 minutes.

`ALIAS_IP` (default `192.168.1.230`) is the address the satellite binds and the
one you give Home Assistant - see section 10. `MODULE_IP` is only how you reach
the box the first time.

## 7. Wire into Home Assistant

1. Settings -> Devices & services -> Add Integration -> **ESPHome**.
2. "Set up another instance" -> `192.168.1.230:6053` (the alias `setup-module.sh`
   pins to the module - see section 10).
3. Settings -> Voice assistants -> your assistant -> wake word "okay nabu" ->
   assign the new satellite.

**Do not type the DHCP address.** The lease moves across power cycles (observed
.230 -> .100), and HA's ESPHome entry stores the address it was given, so a
changed IP silently disconnects the satellite. `setup-module.sh` gives the module
a second, static address that survives DHCP and advertises *that* one in mDNS and
in `/etc/default/lva`. A router DHCP reservation is still the right thing to do
for the primary address; the alias is what makes the satellite reachable even when
you have not made one.

## 8. Measure before tuning

- Wake-word false positives: 10 minutes of normal room conversation, count
  triggers via `journalctl -u linux-voice-assistant -f`.
- Wake-to-chime latency and end-of-speech-to-answer latency: time two runs,
  compare against the Voice PE in the same room.

Wake-word detection only runs while Home Assistant is connected: LVA sets
`state.satellite` on connect and skips the whole wake-word block when it is
`None`. If `journalctl` shows `Opening audio input device` with no detections at
all, check the HA side first. `journalctl -u linux-voice-assistant | grep
'Connected to Home Assistant'` confirms the handshake.

Tuning notes, in order of usefulness:

1. `ALC ENABLE` on/off (`amixer -c 0 sset 'ALC ENABLE' on`) - by far the
   biggest lever.
2. `ALC TARGET LEVEL` / `ALC GAIN MAX` - small effect, tune by measurement.
3. `TX RIGHT DIG GAIN` - a few dB, mostly not worth it.
4. `MIC_AUTO_GAIN` / `MIC_NOISE_SUPPRESSION` in `/etc/default/lva` - the WebRTC
   extras sat within noise of each other (0.948 vs 0.942) and did not help.

## 9. Playback clicks (Axera I2S period stall)

Symptom: a continuous clicking/ticking from the speaker as soon as any sound is
played (most obvious right after the wake chime, because that is the first time
LVA opens the output stream). It keeps going while a stream is open and only
stops when the sink suspends.

Cause: the playback PCM is `hw:0,1`, exposed by PipeWire as
`alsa_output.platform-sound.playback.1.0`, and its ALSA period size defaults to
exactly PipeWire's quantum (1024 frames @ 16 kHz = 64 ms). The `dw_i2s` driver
then stops and restarts the DMA on every period, logging one `dw_i2s_trigger`
START/STOP pair per 64 ms. Each restart is audible, so an idle-but-open sink
stream is a permanent click train. Confirm with:

```sh
dmesg -C; sleep 3; dmesg | grep -c dw_i2s_trigger   # ~25/s while clicking
```

Fix: give the hardware a smaller period so a 1024-frame quantum spans four of
them, and the PCM is started once and left running. This lives in the same
WirePlumber rule as the ACP bypass (`/etc/wireplumber/main.lua.d/51-lva-codec.lua`):

```lua
table.insert(alsa_monitor.rules, {
  matches = { { { 'api.alsa.path', 'matches', 'hw:0,1' } } },
  apply_properties = { ['api.alsa.period-size'] = 256 },
})
```

Then `XDG_RUNTIME_DIR=/run/user/0 systemctl --user restart wireplumber`.

Verify: `grep period_size /proc/asound/card0/pcm1p/sub0/hw_params` reports 256
while playing, and a 10 s tone produces ~1 DMA trigger instead of ~227.
`api.alsa.disable-batch` does **not** help on this driver.

## 10. The address Home Assistant connects to

HA's ESPHome entry stores a host:port. The module's DHCP lease is not stable
(observed .230 -> .100 across a power cycle), so `setup-module.sh` pins a second,
static address to `eth0` and points everything at it:

| file | role |
|---|---|
| `/etc/default/lva-net-alias` | `NET_DEV=eth0`, `LVA_ALIAS_IP=192.168.1.230` |
| `/usr/local/sbin/lva-net-alias.sh` | idempotently ensures the alias exists (`--nowait` for hooks) |
| `lva-net-alias.service` | runs at boot, `Before=linux-voice-assistant.service` |
| `lva-net-alias.timer` | re-asserts every 5 min for anything else that flushes the link |
| `/etc/dhcp/dhclient-exit-hooks.d/lva-net-alias` | re-asserts on PREINIT/BOUND/REBOOT/REBIND/RENEW/FAIL |

Why the naive approach fails. A `post-up ip addr add ...` in
`/etc/network/interfaces` looked right and was not. In the journal you can watch
it happen: the alias is added at boot, then ~80 s later *every* IPv4 address on
`eth0` is withdrawn and dhclient rebinds to .100 without re-running `ifup`.
`dhclient-script` flushes the interface in the PREINIT/BOUND paths
(`ip -4 addr flush dev eth0 label eth0`), and an unlabelled `ip addr add` gets
exactly that label - so the secondary address disappears on a rebind even when the
lease itself never changed. `ifplugd` re-running `ifup` does not reliably re-run
`post-up` either. Hence: hook dhclient's state machine, and keep a slow timer as
a backstop.

`HOST=192.168.1.230` in `/etc/default/lva` is the **bind** address, not just an
advertised one. That is deliberate - `HOST=0.0.0.0` makes LVA advertise
`address = [0.0.0.0]` over mDNS and HA can never connect - but it also means the
satellite is unreachable if the alias is ever missing. LVA retries the bind 15
times at 1 s, then exits and systemd restarts it, so it self-heals within ~20 s
once the alias returns. If HA reports "Can't connect to ...", check the alias
before anything else:

```sh
ip -4 addr show eth0                              # .230 must be there
journalctl -u lva-net-alias -b --no-pager
journalctl -u linux-voice-assistant -b --no-pager | grep -i "failed to bind"
ss -tlnp | grep 6053                              # listening on .230:6053
```

From another machine, `nc -z  <ALIAS_IP>6053` should succeed. mDNS should
advertise the same address (avahi is running on the module, so this works there
and on any other machine on the LAN):

```sh
avahi-browse -art | grep esphomelib
# = lva-0ed3e0025a35._esphomelib._tcp.local. ... lva-0ed3e0025a35.local.  <ALIAS_IP>6053
```

Still ask the router for a DHCP reservation on the module's MAC. The alias keeps
HA working without one; the reservation keeps the *primary* address sane too.

## 11. Proving the whole pipeline without Home Assistant

Wake-word detection is gated on a client being connected: `process_audio()` does
`if state.satellite is None ...: continue`, and `state.satellite` is only set when
a `VoiceSatelliteProtocol` connection is created. So with nothing connected, the
mic opens, the model loads, and *nothing is ever detected* - which looks exactly
like a broken microphone. `tools/ha-test-client.py` is a real `aioesphomeapi`
client: it connects, arms detection, prints the wake event, streams the mic audio
back, and can drive the rest of the pipeline with synthetic HA events so the LED
state machine and the TTS path are exercised end to end.

```sh
# One shot from the PC. Note the path: /tmp is wiped on reboot, the repo copy at
# /opt/ax630c-ha-voice-satellite is not, and install.sh already put it there.
K=~/.ssh/id_ed25519_m5llm; R=/opt/ax630c-ha-voice-satellite
ssh -i $K root@ <ALIAS_IP>"export XDG_RUNTIME_DIR=/run/user/0; dmesg -C
  nohup /opt/linux-voice-assistant/.venv/bin/python $R/tools/ha-test-client.py \
    --timeout 90 --drive --tts-url /opt/linux-voice-assistant/sounds/timer_finished.flac \
    > /tmp/haclient.log 2>&1 &
  for i in \$(seq 1 30); do grep -q subscribed /tmp/haclient.log && break; sleep 1; done
  sleep 3
  paplay --device=alsa_output.platform-sound.playback.1.0 $R/tools/okay-nabu.wav
  sleep 4
  paplay --device=alsa_output.platform-sound.playback.1.0 $R/tools/okay-nabu.wav
  sleep 16
  cat /tmp/haclient.log
  echo i2s: \$(dmesg | grep -c dw_i2s_trigger)"
```

Two traps here, both of which produced a false negative at least once:

- **Wait for `subscribed` before making the sound.** Detection is armed by the
  subscription, and the first connection after a boot takes ~10 s (cold caches).
  Play the stimulus too early and you get silence plus a confusing "no wake word
  within 60s".
- **`tools/okay-nabu.wav` is committed on purpose** - espeak-ng "okay nabu",
  16 kHz mono, the same sample rate and format the mic pipeline uses. A fixed
  stimulus is what makes "it woke this time" mean something.

Playing the wake word out of the speaker and re-capturing it with the mic is a
legitimate test: it exercises capture, model, network, and playback in one loop.
A known-good run looks like this:

```
connected: name='lva-0ed3e0025a35' model='Linux Voice Assistant' version='45.3.1'
voice_assistant_feature_flags=61
entities advertised: 9            # Media Player, Mute, Thinking Sound, sensitivities, mic controls
VoiceAssistantRequest(start) conversation= flags=0 wake_word='Okay Nabu'
```

and in the journal:

```
pymicro_wakeword: Wake word 'Okay Nabu' activated (probability 0.892 exceeded threshold 0.850)
MpvMediaPlayer: Playing 1 URL(s): .../sounds/wake_word_triggered.flac
lva-led-bridge: event=wake_word_detected -> listening -> stt_text -> thinking
                -> tts_text -> tts_speaking -> tts_finished -> idle
```

The LED lines are the cheapest way to watch the state machine; `lva-led-bridge`
runs with `--debug` so every transition is logged. `event=disconnected` at the end
of the run is correct - the test client hung up, so `ha_connected` is false and
the LED goes red.

While that runs, `dmesg | grep -c dw_i2s_trigger` should print **2** for a whole
interaction (one START, one STOP), not one pair per 64 ms. That is the click
regression check from section 9.

This exact sequence was last run minutes after a plain `systemctl reboot` with no
manual commands in between, and the boot left behind:

```sh
ip -4 addr show eth0            #  <ALIAS_IP>present, DHCP lease (.100) as secondary
systemctl is-active linux-voice-assistant lva-led-bridge lva-net-alias.timer   # active active active
journalctl -u lva-audio-init -b | grep lva-audio-init.sh   # "ALC on and DAC unmuted"
ss -tlnp | grep 6053            # LISTEN 192.168.1.230:6053
systemctl is-enabled alsa-restore                           # masked
amixer -c 0 cget name='ALC ENABLE' | tail -1               # values=on
```

Wake word then fired at probability 0.905 (threshold 0.850) with the full LED
sequence and 2 I2S trigger lines. If a boot does *not* look like this, the alias
and the codec state are the two things that have ever broken, in that order.

## 12. Still open, and one gotcha

- **Home Assistant has never connected to this module.** `journalctl -u
  linux-voice-assistant -b | grep -c 'Connected to Home Assistant'` is 0, and the
  LED bridge's first event is `ha_connected: False`. Everything on the module side
  is verified working with the test client above, so the remaining step is in the
  HA UI: add/reload the ESPHome entry pointing at `192.168.1.230:6053`. If it
  refuses, note that LVA reports `api_encryption_supported: false` - choose the
  legacy plaintext connection, not a NoNoise key.
- **The RTC is wrong at boot and NTP fixes it mid-boot.** One boot's journal
  contains both `Jul 29 21:41` (RTC) and `Oct 13 05:50` (NTP) timestamps for the
  same events. `journalctl -b` still groups them correctly, but reading timestamps
  across the jump will mislead you about "did this survive the reboot". Use
  `uptime -s` and `journalctl -u <unit> -b` instead of wall-clock guesses.
