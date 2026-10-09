"use strict";
const { spawn } = require("node:child_process");

// Do not use spawnSync here: blocking the Node event loop prevents the in-process fixture server from answering curl.
function runCurl(args, options = {}) {
  const env = { PATH: "/usr/bin:/bin", LANG: "C", LC_ALL: "C", ...(options.env || {}) };
  return new Promise((resolve, reject) => {
    const child = spawn("curl", args, {
      shell: false,
      env,
      stdio: ["pipe", "pipe", "pipe"]
    });
    let stdout = "";
    let stderr = "";
    child.stdout.setEncoding("utf8");
    child.stderr.setEncoding("utf8");
    child.stdout.on("data", chunk => { stdout += chunk; });
    child.stderr.on("data", chunk => { stderr += chunk; });
    child.once("error", reject);
    child.once("close", status => resolve({
      status,
      exitCode: status,
      stdout,
      stderr,
      spawnargs: child.spawnargs || [],
      argv: child.spawnargs || [],
      env
    }));
    child.stdin.end(options.input || "");
  });
}

module.exports = { runCurl };
