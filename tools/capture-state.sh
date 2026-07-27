#!/bin/zsh
# capture-state.sh <label>
# Dumps every observable audio/Bluetooth fact about Drop-BMR1 into
# captures/<label>-<timestamp>/ so a bad state and a good state can be diffed.
set -uo pipefail
cd "$(dirname "$0")/.."

LABEL="${1:-state}"
STAMP=$(date +%Y%m%d-%H%M%S)
OUT="captures/${LABEL}-${STAMP}"
mkdir -p "$OUT"
BMR1_OUT="42-DA-EC-84-61-F5:output"
BMR1_IN="42-DA-EC-84-61-F5:input"

echo "capturing -> $OUT"

date -u +"%Y-%m-%dT%H:%M:%SZ" > "$OUT/timestamp.txt"
date >> "$OUT/timestamp.txt"

# 1. Full CoreAudio state (devices, streams, formats, rates, alive/running).
./tools/audioprobe > "$OUT/coreaudio.json" 2>"$OUT/coreaudio.err"

# 2. Defaults and rates, plain text for quick eyeballing.
{
  echo "default input : $(./tools/audioctl get-default-input 2>&1)"
  echo "default output: $(./tools/audioctl get-default-output 2>&1)"
  echo "BMR1 out rate : $(./tools/audioctl get-rate "$BMR1_OUT" 2>&1)"
  echo "BMR1 in  rate : $(./tools/audioctl get-rate "$BMR1_IN" 2>&1)"
  echo
  echo "--- device list ---"
  ./tools/audioctl list 2>&1
} > "$OUT/defaults.txt"

# 3. Volume / mute for every output device (element 0,1,2).
/tmp/volprobe > "$OUT/volume-bmr1.txt" 2>&1 || echo "(volprobe unavailable)" > "$OUT/volume-bmr1.txt"

# 4. System volume settings.
osascript -e 'get volume settings' > "$OUT/system-volume.txt" 2>&1

# 5. Bluetooth: profile/service state as macOS reports it.
system_profiler SPBluetoothDataType -json > "$OUT/bluetooth.json" 2>/dev/null
system_profiler SPBluetoothDataType > "$OUT/bluetooth.txt" 2>/dev/null

# 6. Bluetooth daemon's view of the paired device (active profile hints).
defaults read /Library/Preferences/com.apple.Bluetooth > "$OUT/bt-prefs.txt" 2>&1

# 7. IORegistry: live Bluetooth objects, incl. any SCO/eSCO links.
ioreg -l -w0 -r -c IOBluetoothHCIController > "$OUT/ioreg-bt.txt" 2>&1
ioreg -l -w0 | grep -i -E "bluetooth|sco|a2dp|hfp" > "$OUT/ioreg-grep.txt" 2>&1

# 8. Audio HAL plugin / process view.
pgrep -lf "coreaudiod|BMR1Guard" > "$OUT/processes.txt" 2>&1

# 9. Guard's own log.
cp ~/Library/Logs/BMR1Guard.log "$OUT/guard.log" 2>/dev/null || echo "(no guard log)" > "$OUT/guard.log"
defaults read com.youhan.bmr1guard > "$OUT/guard-prefs.txt" 2>&1

# 10. Behaviour under load: does the device consume audio, and what happens to
#     rate / running state while a sound is actually playing?
{
  echo "--- before playback ---"
  ./tools/audioprobe | python3 -c "
import json,sys
d=json.load(sys.stdin)
for dev in d['devices']:
    if '61-F5' in dev['uid']:
        print(dev['uid'], 'rate=',dev.get('nominalSampleRate'), 'running=',dev.get('isRunningSomewhere'), 'alive=',dev.get('isAlive'))
        for s in dev.get('outputStreams',[])+dev.get('inputStreams',[]):
            print('   stream', s.get('direction'), 'active=',s.get('isActive'), 'phys=',s.get('physicalFormat',{}).get('sampleRate'))
"
  afplay /System/Library/Sounds/Ping.aiff &
  AF=$!
  sleep 0.6
  echo "--- during playback ---"
  ./tools/audioprobe | python3 -c "
import json,sys
d=json.load(sys.stdin)
for dev in d['devices']:
    if '61-F5' in dev['uid']:
        print(dev['uid'], 'rate=',dev.get('nominalSampleRate'), 'running=',dev.get('isRunningSomewhere'), 'alive=',dev.get('isAlive'))
        for s in dev.get('outputStreams',[])+dev.get('inputStreams',[]):
            print('   stream', s.get('direction'), 'active=',s.get('isActive'), 'phys=',s.get('physicalFormat',{}).get('sampleRate'))
"
  wait $AF 2>/dev/null
  echo "--- after playback ---"
  ./tools/audioctl get-rate "$BMR1_OUT"
} > "$OUT/playback-behaviour.txt" 2>&1

echo "done: $OUT"
ls "$OUT"
