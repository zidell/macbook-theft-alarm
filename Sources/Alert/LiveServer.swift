import Foundation
import Network

final class LiveServer: @unchecked Sendable {
    private let camera: CameraSnapper
    private let alarm: AlarmPlayer
    private let token: String
    private let snapshotFPS: Double
    private let listener: NWListener
    private let queue = DispatchQueue(label: "alert.live.server")
    private let started = DispatchSemaphore(value: 0)
    private var startError: Error?

    init(port: Int, token: String, snapshotFPS: Double, camera: CameraSnapper, alarm: AlarmPlayer) throws {
        self.camera = camera
        self.alarm = alarm
        self.token = token
        self.snapshotFPS = snapshotFPS
        self.listener = try NWListener(using: .tcp, on: NWEndpoint.Port(rawValue: UInt16(port))!)
    }

    func start() throws {
        listener.stateUpdateHandler = { state in
            switch state {
            case .ready:
                self.started.signal()
            case .failed(let error):
                self.startError = error
                self.started.signal()
            default:
                break
            }
        }

        listener.newConnectionHandler = { connection in
            self.handle(connection)
        }

        listener.start(queue: queue)
        started.wait()

        if let startError {
            throw startError
        }
    }

    func stop() {
        listener.cancel()
    }

    private func handle(_ connection: NWConnection) {
        connection.start(queue: queue)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 32_768) { data, _, _, _ in
            guard let data, let request = String(data: data, encoding: .utf8) else {
                connection.cancel()
                return
            }

            let response = self.response(for: request)
            connection.send(content: response, isComplete: true, completion: .idempotent)
        }
    }

    private func response(for request: String) -> Data {
        let firstLine = request.split(separator: "\r\n").first ?? ""
        let parts = firstLine.split(separator: " ")

        guard parts.count >= 2 else {
            return textResponse("bad request", status: "400 Bad Request")
        }

        let target = String(parts[1])
        guard let url = URL(string: "http://local\(target)") else {
            return textResponse("bad request", status: "400 Bad Request")
        }

        guard queryValue("token", in: url) == token else {
            return textResponse("unauthorized", status: "401 Unauthorized")
        }

        switch url.path {
        case "/", "/watch":
            return htmlResponse(watchHTML(token: token, fps: snapshotFPS))
        case "/snapshot.jpg":
            do {
                let jpeg = try camera.snapshotJPEG(timeout: 0.2)
                return binaryResponse(jpeg, contentType: "image/jpeg", cache: false)
            } catch {
                return textResponse("camera unavailable: \(error)", status: "503 Service Unavailable")
            }
        case "/alarm":
            alarm.start()
            return alarmStatusResponse()
        case "/alarm/stop":
            alarm.stop()
            return alarmStatusResponse()
        case "/alarm/toggle":
            if alarm.isRunning {
                alarm.stop()
            } else {
                alarm.start()
            }
            return alarmStatusResponse()
        case "/status":
            return alarmStatusResponse()
        default:
            return textResponse("not found", status: "404 Not Found")
        }
    }

    private func alarmStatusResponse() -> Data {
        let body = #"{"ok":true,"alarm":\#(alarm.isRunning ? "true" : "false")}"#
        return textResponse(body, contentType: "application/json")
    }

    private func queryValue(_ name: String, in url: URL) -> String? {
        URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?
            .first { $0.name == name }?
            .value
    }

    private func textResponse(
        _ body: String,
        status: String = "200 OK",
        contentType: String = "text/plain; charset=utf-8"
    ) -> Data {
        let bodyData = Data(body.utf8)
        return responseHeader(status: status, contentType: contentType, length: bodyData.count, cache: false) + bodyData
    }

    private func htmlResponse(_ body: String) -> Data {
        let bodyData = Data(body.utf8)
        return responseHeader(status: "200 OK", contentType: "text/html; charset=utf-8", length: bodyData.count, cache: false) + bodyData
    }

    private func binaryResponse(_ body: Data, contentType: String, cache: Bool) -> Data {
        responseHeader(status: "200 OK", contentType: contentType, length: body.count, cache: cache) + body
    }

    private func responseHeader(status: String, contentType: String, length: Int, cache: Bool) -> Data {
        let cacheHeader = cache ? "Cache-Control: public, max-age=1" : "Cache-Control: no-store"
        let header = [
            "HTTP/1.1 \(status)",
            "Content-Type: \(contentType)",
            "Content-Length: \(length)",
            cacheHeader,
            "Connection: close",
            "",
            ""
        ].joined(separator: "\r\n")
        return Data(header.utf8)
    }
}

private func watchHTML(token: String, fps: Double) -> String {
    """
    <!doctype html>
    <html>
    <head>
      <meta charset="utf-8">
      <meta name="viewport" content="width=device-width,initial-scale=1,viewport-fit=cover">
      <title>MacBook Live</title>
      <style>
        html,body{margin:0;height:100%;background:#050505;color:#f5f5f5;font-family:-apple-system,BlinkMacSystemFont,sans-serif}
        body{display:flex;flex-direction:column}
        header{height:44px;display:flex;align-items:center;justify-content:space-between;padding:0 12px;background:#111;border-bottom:1px solid #333}
        #status{font-size:13px}
        #status.live{color:#46e27b}
        #status.bad{color:#ff5b5b}
        main{position:relative;flex:1;overflow:hidden}
        canvas{width:100%;height:100%;object-fit:contain;background:#000}
        footer{display:grid;grid-template-columns:1.2fr 1fr;gap:8px;padding:10px;background:#111;border-top:1px solid #333}
        button,a{flex:1;padding:12px;border:1px solid #555;border-radius:6px;background:#1b1b1b;color:#fff;text-align:center;text-decoration:none;font-size:15px}
        #alarm{background:#d80000;border-color:#ff3b30;font-weight:800;font-size:18px}
        #alarm.off{background:#252525;border-color:#555}
        #alarm.on{background:#d80000;border-color:#ff3b30}
        #alarm:active{filter:brightness(1.2)}
      </style>
    </head>
    <body>
      <header><strong>MacBook Live</strong><span id="status">starting</span></header>
      <main><canvas id="view" width="960" height="540"></canvas></main>
      <footer>
        <button id="alarm">경보</button>
        <button id="save">Save Recording</button>
      </footer>
      <script>
        const token = "\(token)";
        const fps = \(String(format: "%.2f", fps));
        const canvas = document.getElementById('view');
        const ctx = canvas.getContext('2d');
        const statusEl = document.getElementById('status');
        const alarmBtn = document.getElementById('alarm');
        const saveBtn = document.getElementById('save');
        const footer = document.querySelector('footer');
        const chunks = [];
        let recorder;
        let frameCount = 0;

        function setStatus(text, cls) {
          statusEl.textContent = text;
          statusEl.className = cls;
        }

        function sleep(ms) {
          return new Promise(resolve => setTimeout(resolve, ms));
        }

        function drawBlob(blob) {
          return new Promise((resolve, reject) => {
            const img = new Image();
            img.onload = () => {
              if (canvas.width !== img.naturalWidth || canvas.height !== img.naturalHeight) {
                canvas.width = img.naturalWidth;
                canvas.height = img.naturalHeight;
              }
              ctx.drawImage(img, 0, 0, canvas.width, canvas.height);
              URL.revokeObjectURL(img.src);
              resolve();
            };
            img.onerror = reject;
            img.src = URL.createObjectURL(blob);
          });
        }

        async function frameLoop() {
          while (true) {
            try {
              const res = await fetch(`/snapshot.jpg?token=${token}&t=${Date.now()}`, { cache: 'no-store' });
              if (!res.ok) throw new Error(String(res.status));
              await drawBlob(await res.blob());
              frameCount += 1;
              setStatus(`live ${frameCount}`, 'live');
            } catch (err) {
              setStatus('disconnected', 'bad');
            }
            await sleep(1000 / fps);
          }
        }

        function startRecording() {
          if (!canvas.captureStream || !window.MediaRecorder) {
            setStatus('live, recording unsupported', 'live');
            return;
          }

          const stream = canvas.captureStream(fps);
          recorder = new MediaRecorder(stream);
          recorder.ondataavailable = event => {
            if (event.data && event.data.size > 0) chunks.push(event.data);
          };
          recorder.start(1000);
        }

        function setAlarmButton(on) {
          alarmBtn.disabled = false;
          alarmBtn.className = on ? 'on' : 'off';
          alarmBtn.textContent = on ? '경보 끄기' : '경보 울림';
        }

        async function refreshAlarmStatus() {
          try {
            const res = await fetch(`/status?token=${token}&t=${Date.now()}`, { cache: 'no-store' });
            if (!res.ok) throw new Error(String(res.status));
            const data = await res.json();
            setAlarmButton(Boolean(data.alarm));
          } catch (err) {
          }
        }

        alarmBtn.onclick = async () => {
          alarmBtn.disabled = true;
          try {
            const res = await fetch(`/alarm/toggle?token=${token}&t=${Date.now()}`, {
              method: 'POST',
              cache: 'no-store'
            });
            if (!res.ok) throw new Error(String(res.status));
            const data = await res.json();
            setAlarmButton(Boolean(data.alarm));
            setStatus(data.alarm ? 'alarm on' : 'alarm off', data.alarm ? 'bad' : 'live');
          } catch (err) {
            alarmBtn.textContent = '전송 실패';
            setStatus('alarm failed', 'bad');
            setTimeout(() => {
              alarmBtn.disabled = false;
              refreshAlarmStatus();
            }, 1200);
          }
        };

        saveBtn.onclick = () => {
          if (recorder && recorder.state === 'recording') recorder.stop();
          setTimeout(() => {
            const blob = new Blob(chunks, { type: 'video/webm' });
            const previousDownload = document.getElementById('download');
            if (previousDownload) previousDownload.remove();

            const download = document.createElement('a');
            download.id = 'download';
            download.download = 'macbook-live.webm';
            download.href = URL.createObjectURL(blob);
            download.textContent = 'WebM 다운로드';
            footer.appendChild(download);
            download.click();
          }, 300);
        };

        startRecording();
        setAlarmButton(false);
        refreshAlarmStatus();
        frameLoop();
      </script>
    </body>
    </html>
    """
}
