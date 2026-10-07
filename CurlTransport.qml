import QtQuick
import Quickshell.Io
import "CurlConfig.js" as CurlConfig

Item {
  id: root

  signal completed(int requestId, int exitCode, int httpStatus, string contentType,
                   string body, string errorKind, string errorMessage)

  property var activeProcess: null

  function start(requestId, spec) {
    if (activeProcess !== null) return false;
    const marker = "OMAHP_" + requestId + "_" + Math.floor(Math.random() * 0x7fffffff);
    const built = CurlConfig.buildRequest(spec, marker);
    if (!built.ok) {
      Qt.callLater(function() { root.completed(requestId, -1, 0, "", "", "config", built.error); });
      return true;
    }
    const process = processComponent.createObject(root, {
      requestId,
      marker,
      inputConfig: built.text,
      running: true
    });
    if (!process) {
      Qt.callLater(function() { root.completed(requestId, -2, 0, "", "", "missing-curl", "Could not start curl."); });
      return true;
    }
    activeProcess = process;
    return true;
  }

  function cancel(requestId) {
    const process = activeProcess;
    if (!process || (requestId !== undefined && process.requestId !== requestId)) return;
    activeProcess = null;
    process.cancelled = true;
    process.running = false;
    process.inputConfig = "";
  }

  function finish(process, exitCode) {
    if (process.reported) return;
    process.reported = true;
    if (activeProcess === process) activeProcess = null;
    if (process.cancelled) { process.destroy(); return; }
    const requestId = process.requestId;
    const stderr = process.stderrText;
    const stdout = process.stdoutText;
    const metadata = CurlConfig.parseOutput(stdout, stderr, process.marker);
    process.inputConfig = "";
    process.destroy();
    if (exitCode !== 0) {
      const kind = CurlConfig.errorKind(exitCode);
      const message = kind === "network" ? "Could not reach Homepage."
        : kind === "tls" ? "Homepage TLS verification failed."
        : kind === "missing-curl" ? "curl is required by OmaHomepage."
        : "Homepage request failed.";
      root.completed(requestId, exitCode, 0, "", "", kind, message);
      return;
    }
    if (!metadata.ok) {
      root.completed(requestId, exitCode, 0, "", "", "protocol", metadata.error);
      return;
    }
    root.completed(requestId, exitCode, metadata.status, metadata.contentType,
                    metadata.body, "", "");
  }

  Component {
    id: processComponent
    Process {
      id: processJob
      property int requestId: 0
      property string marker: ""
      property string inputConfig: ""
      property string stdoutText: ""
      property string stderrText: ""
      property bool didStart: false
      property bool cancelled: false
      property bool reported: false

      command: ["curl", "-q", "--config", "-"]
      clearEnvironment: true
      environment: ({ PATH: "/usr/bin:/bin", LANG: "C.UTF-8", LC_ALL: "C" })
      stdinEnabled: true
      stdout: StdioCollector { waitForEnd: true; onStreamFinished: processJob.stdoutText = text }
      stderr: StdioCollector { waitForEnd: true; onStreamFinished: processJob.stderrText = text }

      onStarted: {
        didStart = true;
        write(inputConfig);
        inputConfig = "";
        stdinEnabled = false;
      }
      onRunningChanged: {
        if (!running && !didStart && !cancelled) Qt.callLater(function() { root.finish(processJob, -2); });
        else if (!running && !didStart && cancelled) processJob.destroy();
      }
      onExited: function(exitCode) { root.finish(processJob, exitCode); }
    }
  }
}
