// Web Worker hosting the pure-Zig ableton-converter.wasm module.
const td = new TextDecoder();
const te = new TextEncoder();

let wasmPromise = null;

async function loadWasm() {
  if (!wasmPromise) {
    wasmPromise = (async () => {
      const url = new URL('./ableton-converter.wasm', self.location.href);
      try {
        const res = await fetch(url);
        if (!res.ok) throw new Error(`WASM 로드 실패 (HTTP ${res.status})`);
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
  if (!ptr || !len) return '알 수 없는 변환 오류가 발생했습니다.';
  return td.decode(new Uint8Array(ex.memory.buffer, ptr, len));
}

function writeBytes(ex, bytes) {
  const ptr = ex.wasm_alloc(bytes.length);
  if (!ptr) throw new Error('WASM 메모리 할당 실패 (파일이 너무 큽니다)');
  new Uint8Array(ex.memory.buffer, ptr, bytes.length).set(bytes);
  return ptr;
}

self.addEventListener('message', async (ev) => {
  const msg = ev.data;
  if (!msg || msg.type !== 'convert') return;

  const t0 = performance.now();
  try {
    self.postMessage({ type: 'progress', phase: 'WASM 엔진 초기화 중…', determinate: false });
    const ex = await loadWasm();
    ex.wasm_reset();

    if (msg.mode === 'zip') {
      self.postMessage({ type: 'progress', phase: 'ZIP 압축 해제 및 필터링 중…', determinate: false });
      const zipBytes = new Uint8Array(msg.zipBuffer);
      const ptr = writeBytes(ex, zipBytes);
      const added = ex.wasm_add_zip(ptr, zipBytes.length);
      ex.wasm_free(ptr, zipBytes.length);
      if (added < 0) throw new Error(`ZIP 읽기 오류: ${readWasmError(ex)}`);
      if (added === 0) throw new Error('ZIP 안에 Ableton 프로젝트(.als) 또는 오디오 파일이 없습니다.');
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
        if (rc < 0) throw new Error(`파일 등록 오류: ${readWasmError(ex)}`);
        if (i === total - 1 || i % 10 === 0) {
          self.postMessage({
            type: 'progress',
            phase: '프로젝트 파일 적재 중…',
            determinate: true,
            value: Math.round(((i + 1) / total) * 100),
            detail: `${i + 1} / ${total}`,
          });
        }
      }
    }

    self.postMessage({ type: 'progress', phase: 'Ableton .als 분석 및 UniPack 생성 중…', determinate: false });
    const fbBytes = te.encode(msg.fallbackTitle || 'Ableton Project');
    const fbPtr = writeBytes(ex, fbBytes);
    const rc = ex.wasm_convert(fbPtr, fbBytes.length);
    ex.wasm_free(fbPtr, fbBytes.length);
    if (rc !== 0) throw new Error(`변환 실패: ${readWasmError(ex)}`);

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
