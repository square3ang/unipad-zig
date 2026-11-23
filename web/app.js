const LANG_KEY = 'unipad-converter-lang';

const STRINGS = {
  ko: {
    docTitle: 'Ableton → UniPack 변환기 · UniPad Zig',
    docDesc: 'Ableton Live 프로젝트(.zip, 폴더, .als)를 서버 전송 없이 브라우저 WebAssembly로 UniPack .zip으로 변환하는 클라이언트 도구.',
    langSwitchLabel: 'English',
    langSwitchAria: '영어로 전환',
    navAria: '프로젝트 링크',
    runtimeNote: '100% 로컬 WASM 처리',
    pageTitle: 'Ableton Live → UniPack 변환기',
    leadHtml: 'Ableton Live 프로젝트(<code>.zip</code>, 프로젝트 폴더, <code>.als</code>)를 서버 전송 없이 브라우저 WebAssembly에서 바로 UniPack <code>.zip</code>으로 변환합니다.',
    workspaceAria: '프로젝트 입력 및 변환',
    dropHeadingHtml: 'Ableton 프로젝트 <code>.zip</code> 또는 폴더를 여기에 놓으세요',
    dropHint: '샘플이 포함된 압축 파일이나 압축 해제된 프로젝트 폴더를 그대로 지원합니다.',
    pickFile: '압축 또는 프로젝트 파일 선택',
    pickDir: '프로젝트 폴더 선택',
    phasePrepare: '변환 준비 중…',
    phaseReadZip: 'ZIP 파일 읽는 중…',
    phaseReadLocal: '로컬 파일 읽는 중…',
    phaseInit: 'WASM 엔진 초기화 중…',
    phaseUnzip: 'ZIP 압축 해제 및 필터링 중…',
    phaseLoad: '프로젝트 파일 적재 중…',
    phaseConvert: 'Ableton .als 분석 및 UniPack 생성 중…',
    statusReading: '파일을 읽는 중입니다.',
    statusDone: (title, size) => `변환 완료: ${title} (${size})`,
    resultTitle: '변환 완료',
    downloadBtn: 'UniPack .zip 다운로드',
    resetBtn: '다른 프로젝트 변환',
    mChains: '체인',
    mSounds: '사운드',
    mLedPads: 'LED 패드',
    mLedEvents: 'LED 이벤트',
    mAuto: 'AutoPlay',
    mSize: '파일 크기',
    notesSummary: '지원 항목 및 변환 참고사항',
    note1: 'Ableton Live 9부터 12까지 <code>.als</code> 스트리밍 파싱 (Drum Rack, Instrument Rack, Simpler / MultiSampler).',
    note2: 'Simpler <code>SampleStart</code>/<code>SampleEnd</code> WAV·MP3 구간 트림 및 동일 패드 레이어 WAV 자동 믹싱.',
    note3: 'MIDI Effect Rack(Pitch, Chord, Velocity, Note Length, Arpeggiator, Random) 및 MIDI Extension(<code>0save</code> + <code>.mid</code>) 라이트쇼 시뮬레이션.',
    note4: '구형 Launchpad S / Mini 2색 벨로시티 자동 감지 및 Novation RGB 팔레트 색 변환.',
    note5: 'Arrangement <code>MidiClip</code> 기반 <code>autoPlay</code> 생성 및 미포함 팩토리 드럼 내장 뱅크 폴백.',
    errNoFiles: 'Ableton 프로젝트(.als) 또는 오디오 파일이 포함된 .zip/폴더를 선택해 주세요.',
    errWorker: (detail) => `Worker 오류: ${detail || '모듈을 실행할 수 없습니다.'}`,
    errCode: {
      wasm_http: (d) => `WASM 로드 실패 (HTTP ${d})`,
      oom: () => 'WASM 메모리 할당 실패 (파일이 너무 큽니다).',
      zip_read: (d) => `ZIP 읽기 오류: ${d || '손상된 압축 파일'}`,
      zip_empty: () => 'ZIP 안에 Ableton 프로젝트(.als) 또는 오디오 파일이 없습니다.',
      file_add: (d) => `파일 등록 오류: ${d || '알 수 없는 오류'}`,
      convert_fail: (d) => `변환 실패: ${d || '알 수 없는 오류'}`,
      unknown: (d) => d || '알 수 없는 변환 오류가 발생했습니다.',
    },
  },
  en: {
    docTitle: 'Ableton → UniPack Converter · UniPad Zig',
    docDesc: 'Convert Ableton Live projects (.zip, folder, or .als) into playable UniPack .zip archives directly in your browser with Zig WebAssembly.',
    langSwitchLabel: '한국어',
    langSwitchAria: 'Switch to Korean',
    navAria: 'Project links',
    runtimeNote: '100% local WASM processing',
    pageTitle: 'Ableton Live → UniPack Converter',
    leadHtml: 'Convert Ableton Live projects (<code>.zip</code>, project folder, or <code>.als</code>) into UniPack <code>.zip</code> archives locally in your browser via WebAssembly, with no uploads.',
    workspaceAria: 'Project input and conversion',
    dropHeadingHtml: 'Drop an Ableton project <code>.zip</code> or folder here',
    dropHint: 'Supports compressed project archives with samples or unpacked Ableton project folders.',
    pickFile: 'Choose archive or project file',
    pickDir: 'Choose project folder',
    phasePrepare: 'Preparing conversion…',
    phaseReadZip: 'Reading archive…',
    phaseReadLocal: 'Reading local files…',
    phaseInit: 'Initializing WASM engine…',
    phaseUnzip: 'Extracting and filtering archive…',
    phaseLoad: 'Loading project files…',
    phaseConvert: 'Parsing .als and building UniPack…',
    statusReading: 'Reading files.',
    statusDone: (title, size) => `Conversion complete: ${title} (${size})`,
    resultTitle: 'Conversion complete',
    downloadBtn: 'Download UniPack .zip',
    resetBtn: 'Convert another project',
    mChains: 'Chains',
    mSounds: 'Sounds',
    mLedPads: 'LED pads',
    mLedEvents: 'LED events',
    mAuto: 'AutoPlay',
    mSize: 'File size',
    notesSummary: 'Supported features and notes',
    note1: 'Streaming <code>.als</code> parser for Ableton Live 9 through 12 (Drum Rack, Instrument Rack, Simpler / MultiSampler).',
    note2: 'Simpler <code>SampleStart</code>/<code>SampleEnd</code> WAV and MP3 trimming plus automatic WAV mixing for layered pads.',
    note3: 'MIDI Effect Rack (Pitch, Chord, Velocity, Note Length, Arpeggiator, Random) and MIDI Extension (<code>0save</code> + <code>.mid</code>) lightshow simulation.',
    note4: 'Automatic Launchpad S / Mini 2-color velocity detection and mapping to the Novation RGB palette.',
    note5: 'Arrangement <code>MidiClip</code> <code>autoPlay</code> generation and bundled factory drum fallback for uncollected Core Library kits.',
    errNoFiles: 'Select a .zip archive or folder containing an Ableton project (.als) and audio samples.',
    errWorker: (detail) => `Worker error: ${detail || 'Failed to run converter module.'}`,
    errCode: {
      wasm_http: (d) => `Failed to load WASM module (HTTP ${d}).`,
      oom: () => 'WASM memory allocation failed (project is too large).',
      zip_read: (d) => `Failed to read archive: ${d || 'invalid zip'}`,
      zip_empty: () => 'No Ableton project (.als) or audio files found inside the archive.',
      file_add: (d) => `Failed to add file: ${d || 'unknown error'}`,
      convert_fail: (d) => `Conversion failed: ${d || 'unknown error'}`,
      unknown: (d) => d || 'An unknown conversion error occurred.',
    },
  },
};

function detectInitialLang() {
  try {
    const saved = localStorage.getItem(LANG_KEY);
    if (saved === 'ko' || saved === 'en') return saved;
  } catch {}
  const langs = navigator.languages?.length ? navigator.languages : [navigator.language || 'en'];
  return langs.some((l) => /^ko\b/i.test(l)) ? 'ko' : 'en';
}

let lang = detectInitialLang();
let lastProgressKey = 'phasePrepare';
let lastResultSummary = null;
let lastErrorState = null;

const langBtn = document.getElementById('lang-btn');
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

function t() {
  return STRINGS[lang];
}

function formatError(state) {
  if (!state) return '';
  if (state.kind === 'no_files') return t().errNoFiles;
  if (state.kind === 'worker') return t().errWorker(state.detail);
  const fn = t().errCode[state.code] || t().errCode.unknown;
  return fn(state.detail);
}

function applyLang() {
  const dict = t();
  document.documentElement.lang = lang;
  document.title = dict.docTitle;
  const metaDesc = document.querySelector('meta[name="description"]');
  if (metaDesc) metaDesc.setAttribute('content', dict.docDesc);

  langBtn.textContent = dict.langSwitchLabel;
  langBtn.setAttribute('aria-label', dict.langSwitchAria);

  for (const el of document.querySelectorAll('[data-i18n]')) {
    const key = el.getAttribute('data-i18n');
    if (key in dict) el.textContent = dict[key];
  }
  for (const el of document.querySelectorAll('[data-i18n-html]')) {
    const key = el.getAttribute('data-i18n-html');
    if (key in dict) el.innerHTML = dict[key];
  }
  for (const el of document.querySelectorAll('[data-i18n-aria-label]')) {
    const key = el.getAttribute('data-i18n-aria-label');
    if (key in dict) el.setAttribute('aria-label', dict[key]);
  }

  if (!progressPanel.hidden && lastProgressKey in dict) {
    progressLabel.textContent = dict[lastProgressKey];
  }
  if (!errorBox.hidden && lastErrorState) {
    errorBox.textContent = formatError(lastErrorState);
  }
  if (!resultPanel.hidden && lastResultSummary) {
    resultTitle.textContent = lastResultSummary.title;
    mLedEvents.textContent = lastResultSummary.ledEvents.toLocaleString(lang);
    mAuto.textContent = lastResultSummary.autoEvents.toLocaleString(lang);
    statusLive.textContent = dict.statusDone(lastResultSummary.title, formatBytes(lastResultSummary.zipBytes));
  }
}

langBtn.addEventListener('click', () => {
  lang = lang === 'ko' ? 'en' : 'ko';
  try {
    localStorage.setItem(LANG_KEY, lang);
  } catch {}
  applyLang();
});

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

function showErrorState(state) {
  lastErrorState = state;
  lastResultSummary = null;
  progressPanel.hidden = true;
  resultPanel.hidden = true;
  errorBox.textContent = formatError(state);
  errorBox.hidden = false;
  statusLive.textContent = '';
  setBusy(false);
}

function setProgress(phaseKey, determinate, value = 0, detail = '') {
  lastProgressKey = phaseKey;
  progressPanel.hidden = false;
  progressLabel.textContent = t()[phaseKey] || phaseKey;
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
  lastResultSummary = null;
  lastErrorState = null;
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
    setProgress(msg.phaseKey, msg.determinate, msg.value ?? 0, msg.detail ?? '');
  } else if (msg.type === 'done') {
    revokeLastBlob();
    lastErrorState = null;
    lastResultSummary = msg.summary;
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
    mLedEvents.textContent = msg.summary.ledEvents.toLocaleString(lang);
    mAuto.textContent = msg.summary.autoEvents.toLocaleString(lang);
    mSize.textContent = formatBytes(msg.summary.zipBytes);
    resultPanel.hidden = false;
    statusLive.textContent = t().statusDone(msg.summary.title, formatBytes(msg.summary.zipBytes));
    setBusy(false);
  } else if (msg.type === 'error') {
    showErrorState({ kind: 'code', code: msg.code, detail: msg.detail });
  }
});

worker.addEventListener('error', (ev) => {
  showErrorState({ kind: 'worker', detail: ev.message || '' });
});

async function convertFileList(items) {
  if (busy) return;
  if (!items || items.length === 0) return;

  errorBox.hidden = true;
  resultPanel.hidden = true;
  lastErrorState = null;
  lastResultSummary = null;
  setBusy(true);
  statusLive.textContent = t().statusReading;

  try {
    if (items.length === 1 && /\.zip$/i.test(items[0].relPath)) {
      const f = items[0].file;
      setProgress('phaseReadZip', false, 0, formatBytes(f.size));
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
      showErrorState({ kind: 'no_files' });
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
          'phaseReadLocal',
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
    showErrorState({ kind: 'code', code: 'unknown', detail: err instanceof Error ? err.message : String(err) });
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

applyLang();
