#!/usr/bin/env node
"use strict";

const childProcess = require("node:child_process");
const crypto = require("node:crypto");
const fs = require("node:fs");
const path = require("node:path");

const APP_ID = "com.openai.CodexLinuxX64";
const RESOURCE_RELATIVE_PATH = path.join("files", "lib", "codex", "resources", "app.asar");
const BACKUP_SUFFIX = ".codex-linux-titlebar-hidden.bak";
const INTEGRITY_BLOCK_SIZE = 4 * 1024 * 1024;

const ORIGINAL =
  "n===`win32`||n===`linux`?{titleBarStyle:`hidden`,titleBarOverlay:m9(r)}:{titleBarStyle:`default`}";
const PATCHED =
  "n===`win32`&&n===`linux`?{titleBarStyle:`hidden`,titleBarOverlay:m9(r)}:{titleBarStyle:`default`}";
const ZOOM_OVERLAY_ORIGINAL =
  "(process.platform===`win32`||process.platform===`linux`)&&(this.windowZooms.set(n.id,t),n.setTitleBarOverlay(m9(t)))";
const ZOOM_OVERLAY_PATCHED =
  "(process.platform===`win32`&&process.platform===`linux`)&&(this.windowZooms.set(n.id,t),n.setTitleBarOverlay(m9(t)))";
const CURRENT_TITLEBAR_ORIGINAL =
  "n===`win32`||n===`linux`?{titleBarStyle:`hidden`,titleBarOverlay:j9(r),...e===`quickChat`?{resizable:!0}:{}}";
const CURRENT_TITLEBAR_PATCHED =
  "n===`win32`&&n===`linux`?{titleBarStyle:`hidden`,titleBarOverlay:j9(r),...e===`quickChat`?{resizable:!0}:{}}";
const CURRENT_ZOOM_OVERLAY_ORIGINAL =
  "(process.platform===`win32`||process.platform===`linux`)&&(this.windowZooms.set(n.id,t),n.setTitleBarOverlay(j9(t)))";
const CURRENT_ZOOM_OVERLAY_PATCHED =
  "(process.platform===`win32`&&process.platform===`linux`)&&(this.windowZooms.set(n.id,t),n.setTitleBarOverlay(j9(t)))";
const INSTALL_OVERLAY_ORIGINAL =
  "if(process.platform!==`win32`&&process.platform!==`linux`||t!==`primary`)return;";
const INSTALL_OVERLAY_PATCHED =
  "if(process.platform!==`win32`||process.platform!==`linux`||t!==`primary`)return;";
const CURRENT_INSTALL_OVERLAY_ORIGINAL =
  "installApplicationMenuTitleBarOverlaySync(e,t){if(process.platform!==`win32`&&process.platform!==`linux`||t!==`primary`&&t!==`quickChat`)return;";
const CURRENT_INSTALL_OVERLAY_PATCHED =
  "installApplicationMenuTitleBarOverlaySync(e,t){if(process.platform!==`win32`||process.platform!==`linux`||t!==`primary`&&t!==`quickChat`)return;";
const FOCUSABLE_UNDEFINED_ORIGINAL = "show:l,parent:p,focusable:m,...process.platform";
const FOCUSABLE_UNDEFINED_PATCHED = "show:l,parent:p,...{},      ...process.platform";

const PATCHES = [
  { name: "linux-titlebar-default", original: ORIGINAL, patched: PATCHED },
  { name: "disable-titlebar-overlay-on-zoom", original: ZOOM_OVERLAY_ORIGINAL, patched: ZOOM_OVERLAY_PATCHED },
  { name: "linux-titlebar-default-current", original: CURRENT_TITLEBAR_ORIGINAL, patched: CURRENT_TITLEBAR_PATCHED },
  {
    name: "disable-titlebar-overlay-on-zoom-current",
    original: CURRENT_ZOOM_OVERLAY_ORIGINAL,
    patched: CURRENT_ZOOM_OVERLAY_PATCHED,
  },
  {
    name: "disable-titlebar-overlay-install",
    original: INSTALL_OVERLAY_ORIGINAL,
    patched: INSTALL_OVERLAY_PATCHED,
  },
  {
    name: "disable-titlebar-overlay-install-current",
    original: CURRENT_INSTALL_OVERLAY_ORIGINAL,
    patched: CURRENT_INSTALL_OVERLAY_PATCHED,
  },
  {
    name: "drop-undefined-focusable-option",
    original: FOCUSABLE_UNDEFINED_ORIGINAL,
    patched: FOCUSABLE_UNDEFINED_PATCHED,
  },
];

for (const patch of PATCHES) {
  if (Buffer.byteLength(patch.original) !== Buffer.byteLength(patch.patched)) {
    throw new Error(`ASAR patch ${patch.name} must be byte-for-byte length preserving.`);
  }
}

function countOccurrences(source, needle) {
  let count = 0;
  let index = 0;
  while (true) {
    index = source.indexOf(needle, index);
    if (index === -1) return count;
    count += 1;
    index += needle.length;
  }
}

function patchMainBundleSource(source) {
  return replacePatchSetInString(source, "patch");
}

function restoreMainBundleSource(source) {
  return replacePatchSetInString(source, "restore");
}

function replacePatchSetInString(source, direction) {
  let output = source;
  let matchedAny = false;
  for (const patch of PATCHES) {
    const from = direction === "patch" ? patch.original : patch.patched;
    const to = direction === "patch" ? patch.patched : patch.original;
    const fromCount = countOccurrences(output, from);
    const toCount = countOccurrences(output, to);
    if (fromCount === 0 && toCount === 0) continue;
    matchedAny = true;
    if (toCount === 1 && fromCount === 0) continue;
    if (fromCount !== 1) {
      throw new Error(`Expected exactly one source match for ${patch.name}, found ${fromCount}.`);
    }
    if (toCount !== 0) {
      throw new Error(`Found both source and destination matches for ${patch.name}.`);
    }
    output = output.replace(from, to);
  }
  if (!matchedAny) {
    throw new Error("No known Linux titlebar patch targets found.");
  }
  return output;
}

function getAppAsarPath() {
  if (process.env.CODEX_FLATPAK_APP_ASAR) {
    return process.env.CODEX_FLATPAK_APP_ASAR;
  }
  const location = childProcess
    .execFileSync("flatpak", ["info", "--user", "--show-location", APP_ID], {
      encoding: "utf8",
    })
    .trim();
  return path.join(location, RESOURCE_RELATIVE_PATH);
}

function countBufferOccurrences(buffer, needle) {
  let count = 0;
  let index = 0;
  const needleBuffer = Buffer.from(needle);
  while (true) {
    index = buffer.indexOf(needleBuffer, index);
    if (index === -1) return count;
    count += 1;
    index += needleBuffer.length;
  }
}

function parseAsar(buffer) {
  if (buffer.length < 16) {
    throw new Error("ASAR is too small to contain a header.");
  }
  const headerSize = buffer.readUInt32LE(4);
  const headerOffset = 8;
  const headerEnd = headerOffset + headerSize;
  if (headerEnd > buffer.length) {
    throw new Error(`ASAR header exceeds file size: ${headerSize}.`);
  }
  const headerBuffer = buffer.subarray(headerOffset, headerEnd);
  const payloadSize = headerBuffer.readUInt32LE(0);
  const headerStringLength = headerBuffer.readInt32LE(4);
  const headerStringOffset = headerOffset + 8;
  const headerStringEnd = headerStringOffset + headerStringLength;
  if (headerStringEnd > headerEnd) {
    throw new Error("ASAR header string exceeds pickle payload.");
  }
  return {
    buffer,
    header: JSON.parse(buffer.subarray(headerStringOffset, headerStringEnd).toString()),
    headerOffset,
    headerSize,
    headerStringLength,
    headerStringOffset,
    payloadSize,
    dataOffset: headerEnd,
  };
}

function writeAsarHeader(parsed, targetBuffer) {
  const headerString = JSON.stringify(parsed.header);
  if (Buffer.byteLength(headerString) !== parsed.headerStringLength) {
    throw new Error(
      `ASAR header length changed from ${parsed.headerStringLength} to ${Buffer.byteLength(
        headerString,
      )}.`,
    );
  }
  targetBuffer.write(headerString, parsed.headerStringOffset, parsed.headerStringLength, "utf8");
}

function walkFiles(node, basePath, visitor) {
  if (!node.files) return;
  for (const [name, child] of Object.entries(node.files)) {
    const childPath = `${basePath}/${name}`;
    if (child.files) {
      walkFiles(child, childPath, visitor);
    } else {
      visitor(childPath, child);
    }
  }
}

function getFileContent(parsed, node) {
  if (node.unpacked) {
    throw new Error("Target file is unpacked; this script only patches packed ASAR files.");
  }
  const start = parsed.dataOffset + Number.parseInt(node.offset, 10);
  const end = start + node.size;
  if (start < parsed.dataOffset || end > parsed.buffer.length) {
    throw new Error("ASAR file node points outside archive data.");
  }
  return Buffer.from(parsed.buffer.subarray(start, end));
}

function putFileContent(parsed, targetBuffer, node, content) {
  if (content.length !== node.size) {
    throw new Error(`Patched content changed size from ${node.size} to ${content.length}.`);
  }
  const start = parsed.dataOffset + Number.parseInt(node.offset, 10);
  content.copy(targetBuffer, start);
}

function hashBuffer(buffer) {
  return crypto.createHash("SHA256").update(buffer).digest("hex");
}

function calculateIntegrity(content) {
  const blocks = [];
  for (let offset = 0; offset < content.length; offset += INTEGRITY_BLOCK_SIZE) {
    blocks.push(hashBuffer(content.subarray(offset, offset + INTEGRITY_BLOCK_SIZE)));
  }
  if (content.length % INTEGRITY_BLOCK_SIZE === 0) {
    blocks.push(hashBuffer(Buffer.alloc(0)));
  }
  return {
    algorithm: "SHA256",
    hash: hashBuffer(content),
    blockSize: INTEGRITY_BLOCK_SIZE,
    blocks,
  };
}

function integrityMatches(node, content) {
  return JSON.stringify(node.integrity) === JSON.stringify(calculateIntegrity(content));
}

function findTargetFile(parsed) {
  const matches = [];
  walkFiles(parsed.header, "", (filePath, node) => {
    if (node.unpacked || !filePath.endsWith(".js") || typeof node.offset !== "string") return;
    const content = getFileContent(parsed, node);
    const originalCount = PATCHES.reduce(
      (count, patch) => count + countBufferOccurrences(content, patch.original),
      0,
    );
    const patchedCount = PATCHES.reduce(
      (count, patch) => count + countBufferOccurrences(content, patch.patched),
      0,
    );
    if (originalCount > 0 || patchedCount > 0) {
      matches.push({ filePath, node, originalCount, patchedCount, content });
    }
  });
  if (matches.length !== 1) {
    throw new Error(`Expected exactly one ASAR JS file match, found ${matches.length}.`);
  }
  return matches[0];
}

function readAsarBufferStatus(buffer) {
  const parsed = parseAsar(buffer);
  const target = findTargetFile(parsed);
  const patchStates = PATCHES.map((patch) => {
    const originalCount = countBufferOccurrences(target.content, patch.original);
    const patchedCount = countBufferOccurrences(target.content, patch.patched);
    const present = originalCount + patchedCount > 0;
    const state = !present
      ? "absent"
      : patchedCount === 1 && originalCount === 0
        ? "patched"
        : originalCount === 1 && patchedCount === 0
          ? "original"
          : "unexpected";
    return { name: patch.name, originalCount, patchedCount, state };
  });
  const presentStates = patchStates.filter((patch) => patch.state !== "absent");
  const state =
    presentStates.length === 0
      ? "unexpected"
      : presentStates.every((patch) => patch.state === "patched")
        ? "patched"
        : presentStates.every((patch) => patch.state === "original")
          ? "original"
          : "partial";
  return {
    method: "in-place equal-length ASAR content and integrity patch",
    state,
    targetPath: target.filePath,
    originalCount: target.originalCount,
    patchedCount: target.patchedCount,
    patchStates,
    integrityOk: integrityMatches(target.node, target.content),
    sizeBytes: buffer.length,
  };
}

function replacePatchSetInBuffer(content, direction) {
  let output = Buffer.from(content);
  let matchedAny = false;
  for (const patch of PATCHES) {
    const from = direction === "patch" ? patch.original : patch.patched;
    const to = direction === "patch" ? patch.patched : patch.original;
    const fromBuffer = Buffer.from(from);
    const toBuffer = Buffer.from(to);
    const fromCount = countBufferOccurrences(output, from);
    const toCount = countBufferOccurrences(output, to);
    if (fromCount === 0 && toCount === 0) continue;
    matchedAny = true;
    if (toCount === 1 && fromCount === 0) continue;
    if (fromCount !== 1) {
      throw new Error(`Expected exactly one source byte match for ${patch.name}, found ${fromCount}.`);
    }
    if (toCount !== 0) {
      throw new Error(`Found both source and destination byte matches for ${patch.name}.`);
    }
    toBuffer.copy(output, output.indexOf(fromBuffer));
  }
  if (!matchedAny) {
    throw new Error("No known Linux titlebar patch targets found in target file.");
  }
  return output;
}

function patchAsarBuffer(buffer) {
  const parsed = parseAsar(buffer);
  const target = findTargetFile(parsed);
  const content = replacePatchSetInBuffer(target.content, "patch");
  const patched = Buffer.from(buffer);
  target.node.integrity = calculateIntegrity(content);
  writeAsarHeader(parsed, patched);
  putFileContent(parsed, patched, target.node, content);
  return patched;
}

function restoreAsarBuffer(buffer) {
  const parsed = parseAsar(buffer);
  const target = findTargetFile(parsed);
  const content = replacePatchSetInBuffer(target.content, "restore");
  const restored = Buffer.from(buffer);
  target.node.integrity = calculateIntegrity(content);
  writeAsarHeader(parsed, restored);
  putFileContent(parsed, restored, target.node, content);
  return restored;
}

function readStatus(appAsarPath) {
  const buffer = fs.readFileSync(appAsarPath);
  return {
    ...readAsarBufferStatus(buffer),
    appAsarPath,
  };
}

function writeBufferIfChanged(filePath, before, after) {
  if (Buffer.compare(before, after) === 0) return false;
  fs.writeFileSync(filePath, after);
  return true;
}

function applyPatch(appAsarPath) {
  if (!fs.existsSync(appAsarPath)) {
    throw new Error(`app.asar not found: ${appAsarPath}`);
  }
  const backupPath = `${appAsarPath}${BACKUP_SUFFIX}`;
  if (!fs.existsSync(backupPath)) {
    fs.copyFileSync(appAsarPath, backupPath);
  }
  let before = fs.readFileSync(appAsarPath);
  try {
    const after = patchAsarBuffer(before);
    const changed = writeBufferIfChanged(appAsarPath, before, after);
    console.log(changed ? "patched app.asar in place" : "app.asar already patched");
  } catch (error) {
    if (!fs.existsSync(backupPath)) throw error;
    fs.copyFileSync(backupPath, appAsarPath);
    before = fs.readFileSync(appAsarPath);
    const after = patchAsarBuffer(before);
    writeBufferIfChanged(appAsarPath, before, after);
    console.log("restored backup, then patched app.asar in place");
  }
  console.log(`backup ${backupPath}`);
}

function restorePatch(appAsarPath) {
  const backupPath = `${appAsarPath}${BACKUP_SUFFIX}`;
  if (fs.existsSync(backupPath)) {
    fs.copyFileSync(backupPath, appAsarPath);
    console.log(`restored backup ${backupPath}`);
    return;
  }
  const before = fs.readFileSync(appAsarPath);
  const after = restoreAsarBuffer(before);
  const changed = writeBufferIfChanged(appAsarPath, before, after);
  console.log(changed ? "restored app.asar in place" : "app.asar already original");
}

function printStatus(status) {
  console.log(`appAsar=${status.appAsarPath}`);
  console.log(`method=${status.method}`);
  console.log(`targetPath=${status.targetPath}`);
  console.log(`state=${status.state}`);
  console.log(`originalCount=${status.originalCount}`);
  console.log(`patchedCount=${status.patchedCount}`);
  console.log(`integrityOk=${status.integrityOk}`);
  console.log(`sizeBytes=${status.sizeBytes}`);
}

function main() {
  const command = process.argv[2] ?? "apply";
  const appAsarPath = getAppAsarPath();
  if (command === "apply") {
    applyPatch(appAsarPath);
    return;
  }
  if (command === "restore") {
    restorePatch(appAsarPath);
    return;
  }
  if (command === "status") {
    printStatus(readStatus(appAsarPath));
    return;
  }
  console.error("Usage: patch-codex-linux-titlebar.cjs [apply|restore|status]");
  process.exit(2);
}

if (require.main === module) {
  main();
}

module.exports = {
  patchMainBundleSource,
  restoreMainBundleSource,
  patchAsarBuffer,
  restoreAsarBuffer,
  readAsarBufferStatus,
};
