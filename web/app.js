const dropzone = document.getElementById('dropzone');
const pickFileBtn = document.getElementById('pick-file-btn');
const pickDirBtn = document.getElementById('pick-dir-btn');
const fileInput = document.getElementById('file-input');
const dirInput = document.getElementById('dir-input');

const progressPanel = document.getElementById('progress-panel');
const progressBar = document.getElementById('convert-progress');
const progressLabel = document.getElementById('progress-label');
const progressDetail = document.getElementById('progress-detail');
const statusLive = document.getElementById('status-live');
const errorBox = document.getElementById('error-box');

const resultPanel = document.getElementById('result-panel');
const resultTitle = document.getElementById('result-title');
const resultMeta = document.getElementById('result-meta');
const downloadBtn = document.getElementById('download-btn');
const resetBtn = document.getElementById('reset-btn');

const mChains = document.getElementById('m-chains');
const mSounds = document.getElementById('m-sounds');
const mLedPads = document.getElementById('m-led-pads');
const mLedEvents = document.getElementById('m-led-events');
const mAuto = document.getElementById('m-auto');
const mSize = document.getElementById('m-size');

const RELEVANT_RE = /(?:^|\/)0save$|\.(?:als|wav|mp3|ogg|flac|aiff?|midi?)$/i;

const worker = new Worker('./worker.js', { type: 'module' });
let busy = false;
let lastBlobUrl = null;
let lastFileName = 'unipack.zip';

function formatBytes(n) {
  if (n < 1024) return `${n} B`;
  if (n < 1024 * 1024) return `${(n / 1024).toFixed(1)} KB`;
  return `${(n / (1024 * 1024)).toFixed(2)} MB`;
}

function stemOf(name) {
  const base = name.split('/').pop() || name;
  return base.replace(/\.[^.]+$/, '') || 'Ableton Project';
}

function sanitizeFilename(title) {
  const clean = title.replace(/[\\/:*?"<>|]/g, '_').trim();
  return `${clean || 'unipack'}_unipack.zip`;
}

function revokeLastBlob() {
  if (lastBlobUrl) {
    URL.revokeObjectURL(lastBlobUrl);
    lastBlobUrl = null;
  }
}

function setBusy(nextBusy) {
  busy = nextBusy;
  dropzone.dataset.state = nextBusy ? 'busy' : 'idle';
  pickFileBtn.disabled = nextBusy;
  pickDirBtn.disabled = nextBusy;
}

function showError(msg) {
  progressPanel.hidden = true;
  resultPanel.hidden = true;
  errorBox.textContent = msg;
  errorBox.hidden = false;
  statusLive.textContent = '';
  setBusy(false);
}

function setProgress(phase, determinate, value = 0, detail = '') {
  progressPanel.hidden = false;
  progressLabel.textContent = phase;
  progressDetail.textContent = detail;
  if (determinate) {
    progressBar.value = value;
  } else {
    progressBar.removeAttribute('value');
  }
}

function resetUi() {
  if (busy) return;
  revokeLastBlob();
  errorBox.hidden = true;
  progressPanel.hidden = true;
  resultPanel.hidden = true;
  statusLive.textContent = '';
  fileInput.value = '';
  dirInput.value = '';
}

worker.addEventListener('message', (ev) => {
  const msg = ev.data;
  if (!msg) return;

  if (msg.type === 'progress') {
    setProgress(msg.phase, msg.determinate, msg.value ?? 0, msg.detail ?? '');
  } else if (msg.type === 'done') {
    revokeLastBlob();
    const blob = new Blob([msg.zipBuffer], { type: 'application/zip' });
    lastBlobUrl = URL.createObjectURL(blob);
    lastFileName = sanitizeFilename(msg.summary.title);

    progressPanel.hidden = true;
    errorBox.hidden = true;
    resultTitle.textContent = msg.summary.title;
    resultMeta.textContent = `${lastFileName} · ${(msg.elapsedMs / 1000).toFixed(2)}s`;
    mChains.textContent = String(msg.summary.chains);
    mSounds.textContent = String(msg.summary.sounds);
    mLedPads.textContent = String(msg.summary.ledPads);
    mLedEvents.textContent = msg.summary.ledEvents.toLocaleString();
    mAuto.textContent = msg.summary.autoEvents.toLocaleString();
    mSize.textContent = formatBytes(msg.summary.zipBytes);
    resultPanel.hidden = false;
    statusLive.textContent = `변환 완료: ${msg.summary.title} (${formatBytes(msg.summary.zipBytes)})`;
    setBusy(false);
  } else if (msg.type === 'error') {
    showError(msg.message);
  }
});

worker.addEventListener('error', (ev) => {
  showError(`Worker 오류: ${ev.message || '모듈을 실행할 수 없습니다.'}`);
});

async function convertFileList(items) {
  if (busy) return;
  if (!items || items.length === 0) return;

  errorBox.hidden = true;
  resultPanel.hidden = true;
  setBusy(true);
  statusLive.textContent = '파일을 읽는 중입니다.';

  try {
    // Single .zip file fast path
    if (items.length === 1 && /\.zip$/i.test(items[0].relPath)) {
      const f = items[0].file;
      setProgress('ZIP 파일 읽는 중…', false, 0, formatBytes(f.size));
      const zipBuffer = await f.arrayBuffer();
      worker.postMessage(
        {
          type: 'convert',
          mode: 'zip',
          fallbackTitle: stemOf(f.name),
          zipBuffer,
        },
        [zipBuffer],
      );
      return;
    }

    const relevant = items.filter((it) => RELEVANT_RE.test(it.relPath));
    if (relevant.length === 0) {
      showError('Ableton 프로젝트(.als) 또는 오디오 파일이 포함된 .zip/폴더를 선택해 주세요.');
      return;
    }

    const fallbackTitle = stemOf(
      relevant.find((it) => /\.als$/i.test(it.relPath))?.relPath || relevant[0].relPath.split('/')[0] || 'Ableton Project',
    );

    const payload = [];
    const transfers = [];
    for (let i = 0; i < relevant.length; i++) {
      const it = relevant[i];
      const buf = await it.file.arrayBuffer();
      payload.push({ relPath: it.relPath, buffer: buf });
      transfers.push(buf);
      if (i === relevant.length - 1 || i % 10 === 0) {
        setProgress(
          '로컬 파일 읽는 중…',
          true,
          Math.round(((i + 1) / relevant.length) * 100),
          `${i + 1} / ${relevant.length}`,
        );
      }
    }

    worker.postMessage(
      {
        type: 'convert',
        mode: 'files',
        fallbackTitle,
        files: payload,
      },
      transfers,
    );
  } catch (err) {
    showError(err instanceof Error ? err.message : String(err));
  }
}

async function readAllDirectoryEntries(dirReader) {
  const out = [];
  while (true) {
    const batch = await new Promise((resolve, reject) => dirReader.readEntries(resolve, reject));
    if (!batch || batch.length === 0) break;
    out.push(...batch);
  }
  return out;
}

async function collectFromEntry(entry, prefix = '') {
  if (entry.isFile) {
    const file = await new Promise((resolve, reject) => entry.file(resolve, reject));
    const relPath = prefix ? `${prefix}/${entry.name}` : entry.name;
    return [{ relPath, file }];
  }
  if (entry.isDirectory) {
    const nextPrefix = prefix ? `${prefix}/${entry.name}` : entry.name;
    const children = await readAllDirectoryEntries(entry.createReader());
    const nested = [];
    for (const ch of children) {
      nested.push(...(await collectFromEntry(ch, nextPrefix)));
    }
    return nested;
  }
  return [];
}

pickFileBtn.addEventListener('click', () => fileInput.click());
pickDirBtn.addEventListener('click', () => dirInput.click());

fileInput.addEventListener('change', () => {
  const list = Array.from(fileInput.files || []).map((file) => ({ relPath: file.name, file }));
  convertFileList(list);
});

dirInput.addEventListener('change', () => {
  const list = Array.from(dirInput.files || []).map((file) => ({
    relPath: file.webkitRelativePath || file.name,
    file,
  }));
  convertFileList(list);
});

dropzone.addEventListener('dragover', (ev) => {
  ev.preventDefault();
  if (!busy) dropzone.dataset.state = 'dragover';
});

dropzone.addEventListener('dragleave', (ev) => {
  if (ev.target === dropzone && !busy) dropzone.dataset.state = 'idle';
});

dropzone.addEventListener('drop', async (ev) => {
  ev.preventDefault();
  if (busy) return;
  dropzone.dataset.state = 'idle';

  const dtItems = Array.from(ev.dataTransfer?.items || []);
  const entries = dtItems
    .map((item) => (typeof item.webkitGetAsEntry === 'function' ? item.webkitGetAsEntry() : null))
    .filter(Boolean);

  if (entries.length > 0) {
    const collected = [];
    for (const entry of entries) {
      collected.push(...(await collectFromEntry(entry)));
    }
    convertFileList(collected);
    return;
  }

  const files = Array.from(ev.dataTransfer?.files || []).map((file) => ({ relPath: file.name, file }));
  convertFileList(files);
});

downloadBtn.addEventListener('click', () => {
  if (!lastBlobUrl) return;
  const a = document.createElement('a');
  a.href = lastBlobUrl;
  a.download = lastFileName;
  a.click();
});

resetBtn.addEventListener('click', resetUi);
