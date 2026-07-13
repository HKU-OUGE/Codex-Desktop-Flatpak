#!/usr/bin/env node
const assert = require("node:assert/strict");
const {
  patchAsarBuffer,
  patchMainBundleSource,
  readAsarBufferStatus,
} = require("./patch-codex-linux-titlebar.cjs");

const original =
  "case`primary`:return n===`darwin`?t?{titleBarStyle:`hiddenInset`,trafficLightPosition:p9(r)}:{vibrancy:`menu`,titleBarStyle:`hiddenInset`,trafficLightPosition:p9(r)}:n===`win32`||n===`linux`?{titleBarStyle:`hidden`,titleBarOverlay:m9(r)}:{titleBarStyle:`default`};case`secondary`:";

const patched = patchMainBundleSource(original);

assert.equal(
  patched,
  "case`primary`:return n===`darwin`?t?{titleBarStyle:`hiddenInset`,trafficLightPosition:p9(r)}:{vibrancy:`menu`,titleBarStyle:`hiddenInset`,trafficLightPosition:p9(r)}:n===`win32`&&n===`linux`?{titleBarStyle:`hidden`,titleBarOverlay:m9(r)}:{titleBarStyle:`default`};case`secondary`:",
);
assert.equal(patched.length, original.length);
assert.equal(patched.includes("n===`win32`&&n===`linux`"), true);
assert.equal(patched.includes("titleBarStyle:`default`"), true);
assert.equal(patchMainBundleSource(patched), patched);

const overlayOriginal =
  "(process.platform===`win32`||process.platform===`linux`)&&(this.windowZooms.set(n.id,t),n.setTitleBarOverlay(m9(t)))installApplicationMenuTitleBarOverlaySync(e,t){if(process.platform!==`win32`&&process.platform!==`linux`||t!==`primary`)return;";
const overlayPatched = patchMainBundleSource(overlayOriginal);

assert.equal(
  overlayPatched,
  "(process.platform===`win32`&&process.platform===`linux`)&&(this.windowZooms.set(n.id,t),n.setTitleBarOverlay(m9(t)))installApplicationMenuTitleBarOverlaySync(e,t){if(process.platform!==`win32`||process.platform!==`linux`||t!==`primary`)return;",
);
assert.equal(overlayPatched.length, overlayOriginal.length);
assert.equal(patchMainBundleSource(overlayPatched), overlayPatched);

const currentTitlebarOriginal =
  "case`quickChat`:case`primary`:return n===`darwin`?{titleBarStyle:`hiddenInset`,trafficLightPosition:A9(r),...e===`quickChat`?{hasShadow:!0,resizable:!0,transparent:!0}:{},...t?{}:{vibrancy:`menu`}}:n===`win32`||n===`linux`?{titleBarStyle:`hidden`,titleBarOverlay:j9(r),...e===`quickChat`?{resizable:!0}:{}}:{titleBarStyle:`default`,...e===`quickChat`?{resizable:!0}:{}};case`secondary`:";
const currentTitlebarPatched = patchMainBundleSource(currentTitlebarOriginal);

assert.equal(
  currentTitlebarPatched,
  "case`quickChat`:case`primary`:return n===`darwin`?{titleBarStyle:`hiddenInset`,trafficLightPosition:A9(r),...e===`quickChat`?{hasShadow:!0,resizable:!0,transparent:!0}:{},...t?{}:{vibrancy:`menu`}}:n===`win32`&&n===`linux`?{titleBarStyle:`hidden`,titleBarOverlay:j9(r),...e===`quickChat`?{resizable:!0}:{}}:{titleBarStyle:`default`,...e===`quickChat`?{resizable:!0}:{}};case`secondary`:",
);
assert.equal(currentTitlebarPatched.length, currentTitlebarOriginal.length);
assert.equal(patchMainBundleSource(currentTitlebarPatched), currentTitlebarPatched);

const currentOverlayOriginal =
  "(process.platform===`win32`||process.platform===`linux`)&&(this.windowZooms.set(n.id,t),n.setTitleBarOverlay(j9(t)))";
const currentOverlayPatched = patchMainBundleSource(currentOverlayOriginal);

assert.equal(
  currentOverlayPatched,
  "(process.platform===`win32`&&process.platform===`linux`)&&(this.windowZooms.set(n.id,t),n.setTitleBarOverlay(j9(t)))",
);
assert.equal(currentOverlayPatched.length, currentOverlayOriginal.length);
assert.equal(patchMainBundleSource(currentOverlayPatched), currentOverlayPatched);

const currentInstallOverlayOriginal =
  "installApplicationMenuTitleBarOverlaySync(e,t){if(process.platform!==`win32`&&process.platform!==`linux`||t!==`primary`&&t!==`quickChat`)return;";
const currentInstallOverlayPatched = patchMainBundleSource(currentInstallOverlayOriginal);

assert.equal(
  currentInstallOverlayPatched,
  "installApplicationMenuTitleBarOverlaySync(e,t){if(process.platform!==`win32`||process.platform!==`linux`||t!==`primary`&&t!==`quickChat`)return;",
);
assert.equal(currentInstallOverlayPatched.length, currentInstallOverlayOriginal.length);
assert.equal(patchMainBundleSource(currentInstallOverlayPatched), currentInstallOverlayPatched);

const focusableOriginal =
  "backgroundColor:A,show:l,parent:p,focusable:m,...process.platform===`win32`||process.platform===`linux`?{autoHideMenuBar:!0}:{}";
const focusablePatched = patchMainBundleSource(focusableOriginal);

assert.equal(
  focusablePatched,
  "backgroundColor:A,show:l,parent:p,...{},      ...process.platform===`win32`||process.platform===`linux`?{autoHideMenuBar:!0}:{}",
);
assert.equal(focusablePatched.length, focusableOriginal.length);
assert.equal(focusablePatched.includes("focusable:m"), false);
assert.equal(patchMainBundleSource(focusablePatched), focusablePatched);

function align4(value) {
  return value + ((4 - (value % 4)) % 4);
}

function pickleUInt32(value) {
  const buffer = Buffer.alloc(8);
  buffer.writeUInt32LE(4, 0);
  buffer.writeUInt32LE(value, 4);
  return buffer;
}

function pickleString(value) {
  const valueBuffer = Buffer.from(value);
  const payloadSize = align4(4 + valueBuffer.length);
  const buffer = Buffer.alloc(4 + payloadSize);
  buffer.writeUInt32LE(payloadSize, 0);
  buffer.writeInt32LE(valueBuffer.length, 4);
  valueBuffer.copy(buffer, 8);
  return buffer;
}

function fakeAsarWithMainBundle(source) {
  const content = Buffer.from(source);
  const fakeHash = "0".repeat(64);
  const header = {
    files: {
      ".vite": {
        files: {
          build: {
            files: {
              "main-test.js": {
                size: content.length,
                offset: "0",
                integrity: {
                  algorithm: "SHA256",
                  hash: fakeHash,
                  blockSize: 4194304,
                  blocks: [fakeHash],
                },
              },
            },
          },
        },
      },
    },
  };
  const headerPickle = pickleString(JSON.stringify(header));
  return Buffer.concat([pickleUInt32(headerPickle.length), headerPickle, content]);
}

const fakeAsar = fakeAsarWithMainBundle(original);
const patchedAsar = patchAsarBuffer(fakeAsar);
const asarStatus = readAsarBufferStatus(patchedAsar);
assert.equal(patchedAsar.length, fakeAsar.length);
assert.equal(asarStatus.state, "patched");
assert.equal(asarStatus.integrityOk, true);
assert.equal(asarStatus.targetPath, "/.vite/build/main-test.js");

console.log("patch-codex-linux-titlebar tests passed");
