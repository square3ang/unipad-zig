// Web Worker hosting the pure-Zig ableton-converter.wasm module.
const td = new TextDecoder();
const te = new TextEncoder();

let wasmPromise = null;

async function loadWasm() {
  if (!wasmPromise) {
    wasmPromise = (async () => {
      const url = new URL('./ableton-converter.wasm?v=3', self.location.href);
      try {
        const res = await fetch(url);
        if (!res.ok) throw new Error(`Failed to load WASM module (HTTP ${res.status}).`);
        if (WebAssembly.instantiateStreaming && res.headers.get('content-type')?.includes('wasm')) {
          const { instance } = await WebAssembly.instantiateStreaming(res, {});
          return instance.exports;
        }
        const buf = await res.arrayBuffer();
        const { instance } = await WebAssembly.instantiate(buf, {});
        return instance.exports;
      } catch (err) {
        wasmPromise = null;
        throw err;
      }
    })();
  }
  return wasmPromise;
}

function readWasmError(ex) {
  const ptr = ex.wasm_last_error_ptr();
  const len = ex.wasm_last_error_len();
  if (!ptr || !len) return 'An unknown conversion error occurred.';
  return td.decode(new Uint8Array(ex.memory.buffer, ptr, len));
}

function writeBytes(ex, bytes) {
  const ptr = ex.wasm_alloc(bytes.length);
  if (!ptr) throw new Error('WASM memory allocation failed (project is too large).');
  new Uint8Array(ex.memory.buffer, ptr, bytes.length).set(bytes);
  return ptr;
}

self.addEventListener('message', async (ev) => {
  const msg = ev.data;
  if (!msg || msg.type !== 'convert') return;

  const t0 = performance.now();
  try {
    self.postMessage({ type: 'progress', phase: 'Initializing WASM engine…', determinate: false });
    const ex = await loadWasm();
    ex.wasm_reset();

    if (msg.mode === 'zip') {
      self.postMessage({ type: 'progress', phase: 'Extracting and filtering archive…', determinate: false });
      const zipBytes = new Uint8Array(msg.zipBuffer);
      const ptr = writeBytes(ex, zipBytes);
      const added = ex.wasm_add_zip(ptr, zipBytes.length);
      ex.wasm_free(ptr, zipBytes.length);
      if (added < 0) throw new Error(`Failed to read archive: ${readWasmError(ex)}`);
      if (added === 0) throw new Error('No Ableton project (.als) or audio files found inside the archive.');
    } else {
      const entries = msg.files || [];
      const total = entries.length;
      for (let i = 0; i < total; i++) {
        const entry = entries[i];
        const pathBytes = te.encode(entry.relPath);
        const dataBytes = new Uint8Array(entry.buffer);
        const pPtr = writeBytes(ex, pathBytes);
        const dPtr = dataBytes.length > 0 ? writeBytes(ex, dataBytes) : 0;
        const rc = ex.wasm_add_file(pPtr, pathBytes.length, dPtr, dataBytes.length);
        ex.wasm_free(pPtr, pathBytes.length);
        if (dPtr) ex.wasm_free(dPtr, dataBytes.length);
        if (rc < 0) throw new Error(`Failed to add file: ${readWasmError(ex)}`);
        if (i === total - 1 || i % 10 === 0) {
          self.postMessage({
            type: 'progress',
            phase: 'Loading project files…',
            determinate: true,
            value: Math.round(((i + 1) / total) * 100),
            detail: `${i + 1} / ${total}`,
          });
        }
      }
    }

    self.postMessage({ type: 'progress', phase: 'Parsing .als and building UniPack…', determinate: false });
    const fbBytes = te.encode(msg.fallbackTitle || 'Ableton Project');
    const fbPtr = writeBytes(ex, fbBytes);
    const rc = ex.wasm_convert(fbPtr, fbBytes.length);
    ex.wasm_free(fbPtr, fbBytes.length);
    if (rc !== 0) throw new Error(`Conversion failed: ${readWasmError(ex)}`);

    const jPtr = ex.wasm_out_json_ptr();
    const jLen = ex.wasm_out_json_len();
    const summary = JSON.parse(td.decode(new Uint8Array(ex.memory.buffer, jPtr, jLen)));

    const zPtr = ex.wasm_out_zip_ptr();
    const zLen = ex.wasm_out_zip_len();
    const outZip = new Uint8Array(ex.memory.buffer, zPtr, zLen).slice();
    ex.wasm_reset();

    self.postMessage(
      {
        type: 'done',
        summary,
        elapsedMs: Math.round(performance.now() - t0),
        zipBuffer: outZip.buffer,
      },
      [outZip.buffer],
    );
  } catch (err) {
    self.postMessage({
      type: 'error',
      message: err instanceof Error ? err.message : String(err),
    });
  }
});
