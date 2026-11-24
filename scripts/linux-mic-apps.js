// Reports which apps hold a PipeWire microphone stream, in the same messages
// Granola's macOS helper sends for CoreAudio input processes. Granola has no
// Linux source for this list, so it never noticed a meeting app using the mic.
"use strict";

const { execFile } = require("node:child_process");

// PipeWire's application.process.binary mapped to the macOS bundle IDs Granola
// knows; Granola ignores bundle IDs that are not meeting apps.
const BUNDLE_IDS = {
  chrome: "com.google.Chrome",
  "google-chrome": "com.google.Chrome",
  chromium: "org.chromium.Chromium",
  brave: "com.brave.Browser",
  msedge: "com.microsoft.edgemac",
  vivaldi: "com.vivaldi.Vivaldi",
  "vivaldi-bin": "com.vivaldi.Vivaldi",
  opera: "com.operasoftware.Opera",
  firefox: "org.mozilla.firefox",
  "firefox-bin": "org.mozilla.firefox",
  "firefox-esr": "org.mozilla.firefox",
  zoom: "us.zoom.xos",
  slack: "com.tinyspeck.slackmacgap",
  discord: "com.hnc.Discord",
  "teams-for-linux": "com.microsoft.teams2",
};
const POLL_MS = 1000;

let previous = new Map();
let reported = false;
let failing = false;

function activeInputProcesses(objects) {
  // Native PipeWire clients put the process details on the client, not the stream.
  const clients = new Map();
  for (const object of objects) {
    if (object?.type === "PipeWire:Interface:Client") clients.set(object.id, object.info?.props);
  }
  const processes = [];
  for (const object of objects) {
    const nodeProps = object?.info?.props;
    if (object?.type !== "PipeWire:Interface:Node" || !nodeProps) continue;
    const props = { ...clients.get(nodeProps["client.id"]), ...nodeProps };
    if (props["media.class"] !== "Stream/Input/Audio") continue;
    // Recording an output (Granola's own loopback, tab audio) is not a mic.
    if (String(props["stream.capture.sink"]) === "true") continue;
    const binary = String(props["application.process.binary"] ?? "").toLowerCase();
    const bundleId = BUNDLE_IDS[binary];
    if (bundleId === undefined) continue;
    processes.push({
      bundleId,
      pid: Number(props["application.process.id"]) || undefined,
      deviceUID: undefined,
    });
  }
  return processes;
}

function poll() {
  execFile("pw-dump", [], { maxBuffer: 64 * 1024 * 1024 }, (error, stdout) => {
    try {
      if (error) throw error;
      const processes = activeInputProcesses(JSON.parse(stdout));
      const current = new Map(processes.map((p) => [`${p.bundleId}:${p.pid}`, p]));
      const added = [...current].filter(([key]) => !previous.has(key)).map(([, p]) => p);
      const removed = [...previous].filter(([key]) => !current.has(key)).map(([, p]) => p);
      if (!reported || added.length > 0 || removed.length > 0) {
        process.parentPort.postMessage({
          event: "macos-mic-apps-with-devices-update",
          processes,
          added,
          removed,
          defaultInputDeviceUID: undefined,
        });
      }
      previous = current;
      reported = true;
      failing = false;
    } catch (failure) {
      if (!failing) console.error("Cannot read PipeWire streams with pw-dump:", failure.message);
      failing = true;
    } finally {
      setTimeout(poll, POLL_MS);
    }
  });
}

if (require.main === module) {
  poll();
}

module.exports = { activeInputProcesses };
