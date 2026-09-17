from functools import partial
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
import os
import sys
import threading
import webbrowser


ROOT = Path(__file__).resolve().parent.parent
WEB_ROOT = ROOT / "zig-out" / "web"


def wait_for_stop() -> None:
    if os.name == "nt" and sys.stdin.isatty():
        import msvcrt

        while msvcrt.getwch() != "\x04":
            pass
        return

    while True:
        ch = sys.stdin.read(1)
        if ch == "" or ch == "\x04":
            return


def main() -> None:
    if not WEB_ROOT.is_dir():
        raise SystemExit("zig-out/web/ does not exist; run `zig build publish` first")

    handler = partial(SimpleHTTPRequestHandler, directory=str(WEB_ROOT))
    with ThreadingHTTPServer(("127.0.0.1", 0), handler) as server:
        port = server.server_address[1]
        url = f"http://127.0.0.1:{port}/"
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        try:
            print(f"Serving {WEB_ROOT} at {url}")
            print("Press Ctrl-D to stop.")
            webbrowser.open(url)
            wait_for_stop()
        except KeyboardInterrupt:
            pass
        finally:
            server.shutdown()
            thread.join()


if __name__ == "__main__":
    main()
