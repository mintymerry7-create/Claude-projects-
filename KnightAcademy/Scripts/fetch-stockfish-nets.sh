#!/bin/sh
# Downloads the Stockfish 17 NNUE networks used by ChessKitEngine into the app
# resources and verifies them (Stockfish names nets after their SHA-256 prefix).
set -eu
cd "$(dirname "$0")/../App/KnightAcademy/Resources/EngineNets"
for net in nn-1111cefa1111 nn-37f18f62d772; do
  file="$net.nnue"
  if [ ! -f "$file" ]; then
    echo "Downloading $file…"
    curl -fL --retry 3 -o "$file.part" "https://tests.stockfishchess.org/api/nn/$file" \
      || curl -fL --retry 3 -o "$file.part" "https://github.com/official-stockfish/networks/raw/master/$file"
    mv "$file.part" "$file"
  fi
  expected=$(echo "$net" | cut -c4-)
  actual=$(shasum -a 256 "$file" | cut -c1-12)
  if [ "$actual" != "$expected" ]; then
    echo "Checksum mismatch for $file (got $actual, expected $expected)" >&2
    rm -f "$file"
    exit 1
  fi
  echo "$file OK"
done
