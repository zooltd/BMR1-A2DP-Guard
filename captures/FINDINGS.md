# SoundSource "Output Only" — observable CoreAudio state study

Date: 2026-07-25 · macOS 26.5.2 (25F84) · SoundSource 6.1.0 · Drop-BMR1 connected (HFP + A2DP + AVRCP)

## Method

`tools/audioprobe` (this repo) dumps every publicly readable CoreAudio property:
device IDs/UIDs/names, device-list membership, transport type, input/output
stream configuration, per-stream physical/virtual/available formats, nominal and
available sample rates, default input/output/system-output devices, alive /
running-somewhere state, hog mode, data sources.

Captures (in this directory):

| File | Condition |
|---|---|
| `01-soundsource-ON-outputonly.json` | SoundSource running, Output Only enabled for Drop-BMR1 |
| `02-soundsource-OFF.json` | SoundSource completely quit |
| `03-soundsource-ON-again.json` | SoundSource relaunched |

SoundSource itself was not touched, inspected, or modified beyond quitting and
relaunching it; only public system state was read.

## Results

### Static state: zero difference

A full structural diff of ON vs OFF found **no difference in any public
CoreAudio property**:

- Device-list membership identical — the Drop-BMR1 **input** endpoint
  (`42-DA-EC-84-61-F5:input`, 1 ch, 16 kHz) remains in the HAL device list and
  `alive=1` even with Output Only enabled. It is *not* removed from the system.
- No virtual device or route is created (device set identical, all transports
  unchanged: `blue` stays `blue`).
- Stream configurations, physical/virtual formats, available formats identical.
- Nominal rates identical (input 16000; output 44100 with available rates
  {16000, 44100}).
- Default input/output identical (input: built-in mic; output: BMR1).
- Only ephemeral diff ever observed: `isRunningSomewhere=1` on the BMR1 output
  right after SoundSource relaunch (its own engine touching the device).

### Dynamic behavior: default-input enforcement

Behavioral probe (`audioctl set-default-input 42-DA-EC-84-61-F5:input`, then
poll):

- **SoundSource ON**: the set call returns `noErr`, but the default input never
  reads back as BMR1 — not even on the first poll ~30 ms later. Either
  SoundSource reverts faster than that or the change is suppressed inside
  coreaudiod (Rogue Amoeba's engine runs there; not investigated further).
- **SoundSource OFF**: the same call sticks — BMR1 stays default input
  indefinitely until manually restored.

## Conclusion

SoundSource's Output Only mode, as observed from public system state, does
**not** change a public CoreAudio property, does **not** remove the input
endpoint, and does **not** create a virtual route. Its observable effect is
purely **dynamic enforcement**: Drop-BMR1 is never allowed to remain the
system-default input, so no default-input client ever opens the HFP/SCO link,
and the output never leaves A2DP.

That behavior is replicable by a normal, unprivileged CoreAudio app using
property listeners plus immediate restore — which is what BMR1Guard does. The
one thing a normal app cannot replicate is suppressing the changeover with
zero-length visibility window (if that is what SoundSource does); BMR1Guard's
window was measured at <82 ms, which no real recording app can race (apps take
far longer between the default-input change and starting IO).
