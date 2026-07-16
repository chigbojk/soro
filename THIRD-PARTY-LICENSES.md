# Third-Party Licenses

Soro is built on excellent open-source work. Each dependency below is used under
its own license; Soro itself is MIT-licensed (see [LICENSE](LICENSE)).

## WhisperKit

On-device speech-to-text (Core ML / Metal Whisper inference).

- Author: Argmax, Inc. (`argmaxinc`)
- Repository: https://github.com/argmaxinc/WhisperKit
- License: MIT

## whisper.cpp

Whisper model architecture and the reference C/C++ implementation that the
on-device transcription ecosystem builds on.

- Author: Georgi Gerganov (`ggerganov`) and contributors
- Repository: https://github.com/ggerganov/whisper.cpp
- License: MIT

## Ollama

Local LLM runtime used for optional text cleanup and style matching. Soro talks
to a locally running Ollama server over HTTP (`127.0.0.1:11434`); Ollama is not
bundled or redistributed with Soro.

- Author: Ollama and contributors
- Repository: https://github.com/ollama/ollama
- License: MIT
