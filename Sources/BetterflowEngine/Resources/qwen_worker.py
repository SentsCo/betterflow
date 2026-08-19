import argparse
import json
import sys
import time

import numpy as np
from mlx_audio.stt import load


def reply(request_id, *, text="", inference_ms=0.0, error=None):
    print(
        json.dumps(
            {
                "id": request_id,
                "text": text,
                "inference_ms": inference_ms,
                "error": error,
            }
        ),
        flush=True,
    )


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--model", required=True)
    args = parser.parse_args()
    model = load(args.model)

    for line in sys.stdin:
        try:
            request = json.loads(line)
            request_id = request["id"]
            if request["command"] == "ping":
                reply(request_id)
                continue
            samples = np.fromfile(request["audio_path"], dtype=np.float32)
            started = time.perf_counter()
            result = model.generate(
                samples,
                language="English",
                system_prompt=request.get("context"),
                verbose=False,
            )
            elapsed = (time.perf_counter() - started) * 1000
            reply(request_id, text=getattr(result, "text", str(result)), inference_ms=elapsed)
        except Exception as error:
            reply(request.get("id", "unknown"), error=f"{type(error).__name__}: {error}")


if __name__ == "__main__":
    main()
