# Stockfish network files

Stockfish 17 needs two NNUE files at runtime. They are too large for git and
are downloaded by `Scripts/fetch-stockfish-nets.sh` into this folder:

- `nn-1111cefa1111.nnue` (EvalFile)
- `nn-37f18f62d772.nnue` (EvalFileSmall)

Everything in this folder is copied into the app bundle. Without the files the
app falls back to its built-in engine automatically.
