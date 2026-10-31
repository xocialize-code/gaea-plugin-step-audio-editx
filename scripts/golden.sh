#!/bin/zsh
# The plugin against in-process MLXServeEngine: seeded edits called on the signed bundle the way Gaea calls them
# (gaea-plugin-check: launch under the launch requirement, configure, prepare, run) and through editx-inproc with the
# lane configuration and requests the worker uses. Each pair must be byte for byte the same WAV.
#
#   scripts/golden.sh <out-dir>     (after scripts/build-plugin.sh)
#
# Cases (int8, Kokoro-spoken takes in Tests/Fixtures): angry, afraid (upstream's fear), whisper, narration (upstream's
# story), a laugh added at the end, a breath added inline, a sigh at the start, denoise on a noisy take, and
# trim_silence on a take padded with 1.5 s of silence each side. The add_cue runs must also return the new transcript.
set -uo pipefail
ROOT=${0:A:h:h}
cd $ROOT
OUT=${1:?out dir}; mkdir -p $OUT
B=$ROOT/dist/step-audio-editx.gaeaplugin
F=$ROOT/Tests/Fixtures
MODELS=${CHECK_MODELS_ROOT:-$HOME/Library/Application Support/MLXEngine/Models}
SWIFTPM=(-c release --build-system swiftbuild)
xcrun swift build $SWIFTPM --product editx-inproc > /dev/null && xcrun swift build -c release --product gaea-plugin-check > /dev/null
INPROC=$(xcrun swift build $SWIFTPM --show-bin-path)/editx-inproc; CHECK=$(xcrun swift build -c release --show-bin-path)/gaea-plugin-check
LOG=$OUT/golden.log; : > $LOG
pass=0; fail=0
say() { print -r -- "$*" | tee -a $LOG }
say "# Step-Audio-EditX golden check $(date -u +%FT%TZ): $(python3 -c "import json; m=json.load(open('$B/Contents/Resources/manifest.json')); print(m['id'], m['version'])")"
same() { # name, gpp wav, inproc wav
  local a=$(shasum -a 256 $2 2>/dev/null | cut -c1-16) b=$(shasum -a 256 $3 2>/dev/null | cut -c1-16)
  if [[ -n $a && $a == $b ]]; then pass=$((pass+1)); say "PASS  $1: byte-identical, sha256 $a…"
  else fail=$((fail+1)); say "FAIL  $1: differs ($a… / $b…)"; fi
}
outputs() { grep -o '"path":"[^"]*"' $1 | sed 's/"path":"//; s/"$//; s/\\\//\//g' }

TAKE="We don't have much time, so listen carefully to what I say."
TAKE2="The weather is lovely today, and I think we should go outside."

# edit <name> <seed> <take wav> <transcript> <edit json> [expected transcript output]
edit() {
  local name=$1 seed=$2 wav=$3 text=$4 e=$5 expect=${6:-}
  $CHECK $B --operation audio.edit_speech --model step-audio-editx --lane int8 --params "{\"edit\":$e}" --seed $seed \
    --input "audio=$wav" --text "transcript=$text" \
    --models-root "$MODELS" --budget 64000000000 --timeout 900 --session $OUT/$name.gpp > $OUT/$name-gpp.log 2>&1
  local file=$(outputs $OUT/$name-gpp.log | tail -1); [[ -f $file ]] && cp $file $OUT/$name-gpp.wav
  $INPROC --take $wav --transcript "$text" --edit "$e" --seed $seed --models-root "$MODELS" --out $OUT/$name-inproc.wav 2>> $LOG | tail -1 > $OUT/$name-inproc.json
  say "      $name: over GPP $(grep -o 'ran in [0-9.]* s' $OUT/$name-gpp.log | head -1); in-process $(cat $OUT/$name-inproc.json)"
  same $name $OUT/$name-gpp.wav $OUT/$name-inproc.wav
  if [[ -n $expect ]]; then
    local got=$(python3 -c '
import json, sys
for line in open(sys.argv[1]):
    if line.startswith("W ") and "\"type\":\"result\"" in line:
        r = json.loads(line[2:])
        print(next((o["value"]["text"] for o in r["outputs"] if o["name"] == "transcript"), ""))' $OUT/$name.gpp 2>/dev/null)
    if [[ $got == $expect ]]; then pass=$((pass+1)); say "PASS  $name returns the transcript \"$got\""
    else fail=$((fail+1)); say "FAIL  $name's transcript is \"$got\", not \"$expect\""; fi
  fi
}

edit angry 42 $F/take.wav $TAKE '{"kind":"emotion","emotion":"angry"}'
edit afraid 7 $F/take.wav $TAKE '{"kind":"emotion","emotion":"afraid"}'
edit whisper 42 $F/take.wav $TAKE '{"kind":"style","style":"whisper"}'
edit narration 3 $F/take2.wav $TAKE2 '{"kind":"style","style":"narration"}'
edit laugh 42 $F/take2.wav $TAKE2 '{"kind":"add_cue","cue":"laugh","at":"end"}' "$TAKE2 [laugh]"
edit breath 5 $F/take.wav $TAKE '{"kind":"add_cue","cue":"breath","text":"We don'"'"'t have much time, [breath] so listen carefully to what I say."}' \
  "We don't have much time, [breath] so listen carefully to what I say."
edit sigh 9 $F/take.wav $TAKE '{"kind":"add_cue","cue":"sigh","at":"start"}' "[sigh] $TAKE"
edit denoise 42 $F/noisy.wav $TAKE2 '{"kind":"denoise"}'
edit trim 42 $F/padded.wav $TAKE2 '{"kind":"trim_silence"}'

for s in $OUT/*.gpp; do
  if python3 ${GAEA_SPEC_ROOT:-$ROOT/../gaea-mes-media-server}/tools/validate.py --transcript $s >> $LOG 2>&1; then pass=$((pass+1)); say "PASS  ${s:t} passes validate.py"
  else fail=$((fail+1)); say "FAIL  ${s:t} fails validate.py"; fi
done
say "== $pass passed, $fail failed"
exit $(( fail > 0 ))
