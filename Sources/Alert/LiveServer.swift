import Foundation
import Network

final class LiveServer: @unchecked Sendable {
    private let camera: CameraSnapper
    private let alarm: AlarmPlayer
    private let location: LocationProvider
    private let noise: NoiseMeter
    private let startedAt = Date()
    private let token: String
    private let snapshotFPS: Double
    private let recordingRetentionSeconds: Double
    private let liveMaxSeconds: Double
    private let listener: NWListener
    private let queue = DispatchQueue(label: "alert.live.server")
    private let started = DispatchSemaphore(value: 0)
    private var startError: Error?

    init(
        port: Int,
        token: String,
        snapshotFPS: Double,
        recordingRetentionSeconds: Double,
        liveMaxSeconds: Double,
        camera: CameraSnapper,
        alarm: AlarmPlayer,
        location: LocationProvider,
        noise: NoiseMeter
    ) throws {
        self.camera = camera
        self.alarm = alarm
        self.location = location
        self.noise = noise
        self.token = token
        self.snapshotFPS = snapshotFPS
        self.recordingRetentionSeconds = recordingRetentionSeconds
        self.liveMaxSeconds = liveMaxSeconds
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
            return htmlResponse(watchHTML(token: token, fps: snapshotFPS, retentionSeconds: recordingRetentionSeconds, maxDurationLabel: formatDurationLabel(seconds: liveMaxSeconds)))
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
        case "/location.json":
            return textResponse(location.latestJSON(), contentType: "application/json")
        case "/telemetry.json":
            return textResponse(telemetryJSON(), contentType: "application/json")
        default:
            return textResponse("not found", status: "404 Not Found")
        }
    }

    private func telemetryJSON() -> String {
        let now = Date()
        let frames = camera.frameStats()
        let frameAgeMs = frames.lastFrameAt.map { Int(now.timeIntervalSince($0) * 1000) } ?? -1
        let mic = noise.latest()
        let fields = [
            #""time":\#(Int(now.timeIntervalSince1970 * 1000))"#,
            #""uptime":\#(Int(now.timeIntervalSince(startedAt)))"#,
            #""cameraFrames":\#(frames.count)"#,
            #""cameraFrameAgeMs":\#(frameAgeMs)"#,
            #""mic":"\#(mic.status)""#,
            #""db":\#(String(format: "%.1f", max(mic.db, -160)))"#
        ]
        return "{" + fields.joined(separator: ",") + "}"
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

private func formatDurationLabel(seconds: Double) -> String {
    let total = Int(seconds.rounded())
    let hours = total / 3600
    let minutes = (total % 3600) / 60

    if hours > 0 && minutes > 0 {
        return "\(hours)시간 \(minutes)분"
    } else if hours > 0 {
        return "\(hours)시간"
    } else if minutes > 0 {
        return "\(minutes)분"
    } else {
        return "\(total)초"
    }
}

private func watchHTML(token: String, fps: Double, retentionSeconds: Double, maxDurationLabel: String) -> String {
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
        #max-duration{position:absolute;left:8px;bottom:8px;font-size:10px;color:rgba(255,255,255,0.4);pointer-events:none}
        #locationBar{background:#111;border-bottom:1px solid #333;padding:8px 12px;font-size:13px;color:#ccc}
        #locationBar a{color:#5ab0ff;text-decoration:none}
        #mapFrame{width:100%;height:140px;border:0;display:block;background:#1b1b1b}
        #monitor{background:#0b0b0b;border-top:1px solid #333;padding:6px 10px;font-size:12px}
        #meterRow{display:flex;align-items:center;gap:8px}
        #meter{flex:1;height:10px;background:#222;border-radius:5px;overflow:hidden;position:relative}
        #meterFill{height:100%;width:0;background:#46e27b;transition:width .2s linear}
        #meterPeak{position:absolute;top:0;width:2px;height:100%;background:#fff;left:0}
        #meterText{min-width:110px;text-align:right;font-variant-numeric:tabular-nums;color:#ccc}
        #log{margin-top:6px;height:96px;overflow-y:auto;font-family:ui-monospace,Menlo,monospace;font-size:11px;line-height:1.45;color:#9a9a9a;white-space:pre}
        #log .warn{color:#ff8a5b}
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
      <div id="locationBar">
        <div id="locationText">위치 확인 중</div>
        <iframe id="mapFrame" loading="lazy"></iframe>
      </div>
      <main>
        <canvas id="view" width="960" height="540"></canvas>
        <span id="max-duration">최대 \(maxDurationLabel) 연동 가능</span>
      </main>
      <section id="monitor">
        <div id="meterRow">
          <span>소음</span>
          <div id="meter"><div id="meterFill"></div><div id="meterPeak"></div></div>
          <span id="meterText">-- dB</span>
        </div>
        <div id="log"></div>
      </section>
      <footer>
        <button id="alarm">경보</button>
        <button id="save">Save Recording</button>
      </footer>
      <script>
        const token = "\(token)";
        const fps = \(String(format: "%.2f", fps));
        const retentionSeconds = \(String(format: "%.0f", retentionSeconds));
        const canvas = document.getElementById('view');
        const ctx = canvas.getContext('2d');
        const statusEl = document.getElementById('status');
        const alarmBtn = document.getElementById('alarm');
        const saveBtn = document.getElementById('save');
        const footer = document.querySelector('footer');
        let chunks = [];
        let recorder;
        let mediaStream;
        let rotateTimer;
        let frameCount = 0;
        let lastFrameBytes = 0;

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
              const blob = await res.blob();
              await drawBlob(blob);
              lastFrameBytes = blob.size;
              frameCount += 1;
              setStatus(`live ${frameCount}`, 'live');
            } catch (err) {
              setStatus('disconnected', 'bad');
            }
            await sleep(1000 / fps);
          }
        }

        function beginRecording() {
          chunks = [];
          recorder = new MediaRecorder(mediaStream);
          recorder.ondataavailable = event => {
            if (event.data && event.data.size > 0) chunks.push(event.data);
          };
          recorder.start(1000);
          clearTimeout(rotateTimer);
          rotateTimer = setTimeout(rotateRecording, retentionSeconds * 1000);
        }

        function rotateRecording() {
          if (recorder && recorder.state === 'recording') {
            recorder.onstop = beginRecording;
            recorder.stop();
          } else {
            beginRecording();
          }
        }

        function startRecording() {
          if (!canvas.captureStream || !window.MediaRecorder) {
            setStatus('live, recording unsupported', 'live');
            return;
          }

          mediaStream = canvas.captureStream(fps);
          beginRecording();
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
          if (!recorder) return;
          clearTimeout(rotateTimer);

          const downloadAndResume = () => {
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

            beginRecording();
          };

          if (recorder.state === 'recording') {
            recorder.onstop = downloadAndResume;
            recorder.stop();
          } else {
            downloadAndResume();
          }
        };

        const locationText = document.getElementById('locationText');
        const mapFrame = document.getElementById('mapFrame');
        let lastMappedKey = '';
        const locationReasons = {
          starting: '위치 확인 중',
          not_determined: '위치 권한 대기 중 (맥북의 권한 창에서 허용 필요)',
          authorized: '위치 확인 중',
          denied: '위치 권한 꺼짐 (시스템 설정 > 개인정보 보호 및 보안 > 위치 서비스에서 MacBook Theft Alarm Location 허용)',
          restricted: '위치 권한이 이 Mac에서 제한됨',
          services_off: '맥북의 위치 서비스가 꺼져 있음',
          helper_missing: '위치 앱 없음 (sudo ./watch.sh로 실행 필요)'
        };

        function updateMap(lat, lon) {
          const key = `${lat.toFixed(4)},${lon.toFixed(4)}`;
          if (key === lastMappedKey) return;
          lastMappedKey = key;
          const delta = 0.006;
          const bbox = [lon - delta, lat - delta, lon + delta, lat + delta].join(',');
          mapFrame.src = `https://www.openstreetmap.org/export/embed.html?bbox=${bbox}&marker=${lat},${lon}&layers=M`;
        }

        async function locationLoop() {
          while (true) {
            try {
              const res = await fetch(`/location.json?token=${token}&t=${Date.now()}`, { cache: 'no-store' });
              if (!res.ok) throw new Error(String(res.status));
              const data = await res.json();
              if (data.available) {
                const lat = data.lat.toFixed(5);
                const lon = data.lon.toFixed(5);
                locationText.innerHTML =
                  `위치: ${lat}, ${lon} (오차 ±${data.accuracy}m, ${data.age}초 전) ` +
                  `<a href="https://www.openstreetmap.org/?mlat=${data.lat}&mlon=${data.lon}#map=17/${data.lat}/${data.lon}" target="_blank">크게 보기</a>`;
                updateMap(data.lat, data.lon);
              } else {
                locationText.textContent = locationReasons[data.reason] || '위치 정보 없음';
              }
            } catch (err) {
              locationText.textContent = '위치 정보 가져오기 실패';
            }
            await sleep(5000);
          }
        }

        const logEl = document.getElementById('log');
        const meterFill = document.getElementById('meterFill');
        const meterPeak = document.getElementById('meterPeak');
        const meterText = document.getElementById('meterText');
        const micReasons = {
          starting: '마이크 준비 중',
          denied: '마이크 권한 없음',
          unavailable: '마이크 없음'
        };

        function clock(ms) {
          return new Date(ms).toLocaleTimeString('ko-KR', { hour12: false });
        }

        function addLog(text, warn) {
          const line = document.createElement('div');
          line.textContent = text;
          if (warn) line.className = 'warn';
          logEl.prepend(line);
          while (logEl.childElementCount > 120) logEl.lastChild.remove();
        }

        // 화면이 정지해 보여도 카메라·전송·마이크가 살아 있는지 1초마다 기록합니다.
        async function telemetryLoop() {
          let tick = 0;
          let peakDb = -160;
          let lastCameraFrames = null;
          let lastViewFrames = frameCount;
          let failures = 0;
          while (true) {
            try {
              const res = await fetch(`/telemetry.json?token=${token}&t=${Date.now()}`, { cache: 'no-store' });
              if (!res.ok) throw new Error(String(res.status));
              const data = await res.json();
              failures = 0;

              if (data.mic === 'ok') {
                const pct = Math.max(0, Math.min(100, (data.db + 80) / 80 * 100));
                peakDb = Math.max(peakDb, data.db);
                meterFill.style.width = `${pct}%`;
                meterFill.style.background = pct > 75 ? '#ff5b5b' : pct > 50 ? '#ffd23f' : '#46e27b';
                meterText.textContent = `${data.db.toFixed(0)} dB`;
              } else {
                meterFill.style.width = '0';
                meterText.textContent = micReasons[data.mic] || data.mic;
              }

              tick += 1;
              if (tick % 4 === 0) {
                const peakPct = Math.max(0, Math.min(100, (peakDb + 80) / 80 * 100));
                meterPeak.style.left = `${peakPct}%`;
                const cameraRate = lastCameraFrames === null ? '-' : data.cameraFrames - lastCameraFrames;
                const viewRate = frameCount - lastViewFrames;
                const stale = data.cameraFrameAgeMs < 0 || data.cameraFrameAgeMs > 2000;
                const noise = data.mic === 'ok' ? `소음 최대 ${peakDb.toFixed(0)}dB` : (micReasons[data.mic] || data.mic);
                addLog(
                  `${clock(data.time)} 카메라 ${cameraRate}f/s · 전송 ${viewRate}장 ${(lastFrameBytes / 1024).toFixed(0)}KB · ${noise}`,
                  stale || viewRate === 0
                );
                lastCameraFrames = data.cameraFrames;
                lastViewFrames = frameCount;
                peakDb = -160;
              }
            } catch (err) {
              failures += 1;
              if (failures % 4 === 1) addLog(`${clock(Date.now())} 맥북 응답 없음`, true);
            }
            await sleep(250);
          }
        }

        startRecording();
        setAlarmButton(false);
        refreshAlarmStatus();
        frameLoop();
        locationLoop();
        telemetryLoop();
      </script>
    </body>
    </html>
    """
}
