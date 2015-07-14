In this example WAV files are converted to MP3 using Lame. The script takes two arguments that are supplied by the PPSS -c option.

PPSS is run like this:

```
ppss -d /source/directory/with/wav/files -c './wav2mp3.sh "$ITEM" "$OUTPUT_DIR"' -o /dest/dir/where/mp3/files/must/be/put
```

This is the code.

```
#!/usr/bin/env bash

SRC="$1"
DEST="$2"

BASENAME=`basename "$SRC"`
MP3FILE="`echo ${BASENAME%wav}mp3`"
lame --quiet --preset insane "$SRC" "$DEST/$MP3FILE"
exit "$?"

```