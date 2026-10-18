import {
    authErrorMessage,
    configErrorMessage,
    hasUsableRevision,
    shouldPreserveLocalDraft,
} from './ui_policy.mjs';

const AUTH_TOKEN_STORAGE_KEY = 'kdedeck.authToken';
const CLIENT_PROTOCOL_VERSION = 1;
const RECONNECT_DELAY_MS = 2000;
let ws = null;
let reconnectTimer = null;
let isAuthenticated = false;
let authChallengeReceived = false;
let configData = null;
let activeBoardIdx = 0;
let draggedItemIndex = null;
let autoSave = true;
let isDirty = false;
let systemApps = [];
let systemAppsLoaded = false;
let configRevision = null;
let configSaveBlocked = false;

// DOM Elements
const statusEl = document.getElementById('connection-status');
const matrixEl = document.getElementById('matrix-container');
const boardListEl = document.getElementById('board-list');
const modal = document.getElementById('editor-modal');
const manualSaveBtn = document.getElementById('manual-save-btn');
const autoSaveToggle = document.getElementById('autosave-toggle');
const colsSelect = document.getElementById('grid-cols-select');
const rowsSelect = document.getElementById('grid-rows-select');
const authModal = document.getElementById('auth-modal');
const authForm = document.getElementById('auth-form');
const pairingCodeInput = document.getElementById('pairing-code');
const authErrorEl = document.getElementById('auth-error');
const reloadConfigBtn = document.getElementById('reload-config-btn');
const localPairingPanel = document.getElementById('local-pairing-panel');
const requestPairingBtn = document.getElementById('request-pairing-btn');
const pairingPayloadEl = document.getElementById('pairing-payload');
const pairingCodeDisplay = document.getElementById('pairing-code-display');
const pairingExpires = document.getElementById('pairing-expires');
const copyPairingBtn = document.getElementById('copy-pairing-btn');
const pairingQrEl = document.getElementById('pairing-qr');
let localPairingRequested = false;

// This is a small, dependency-free QR Code Model 2 byte-mode encoder. The
// enrollment JSON is kept as bytes, so the QR contains the same payload that
// is shown and copied below. The implementation is local so the tray
// dashboard remains usable without a network or a package install.
const QR_ECC_CODEWORDS_PER_BLOCK_LOW = [
    -1, 7, 10, 15, 20, 26, 18, 20, 24, 30, 18, 20, 24, 26, 30, 22, 24, 28, 30, 28,
    28, 28, 28, 28, 30, 30, 26, 28, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30,
];
const QR_ERROR_CORRECTION_BLOCKS_LOW = [
    -1, 1, 1, 1, 1, 1, 2, 2, 2, 2, 4, 4, 4, 4, 4, 6, 6, 6, 6, 7,
    8, 8, 9, 9, 10, 12, 12, 12, 13, 14, 15, 16, 17, 18, 19, 19, 20, 21, 22, 24, 25,
];

function qrAppendBits(bits, value, length) {
    for (let i = length - 1; i >= 0; i -= 1) bits.push((value >>> i) & 1);
}

function qrMultiply(x, y) {
    let result = 0;
    for (let i = 0; i < 8; i += 1) {
        if ((y & 1) !== 0) result ^= x;
        const high = x & 0x80;
        x = (x << 1) & 0xff;
        if (high !== 0) x ^= 0x1d;
        y >>>= 1;
    }
    return result;
}

function qrRawDataModules(version) {
    let result = (16 * version + 128) * version + 64;
    if (version >= 2) {
        const alignmentCount = Math.floor(version / 7) + 2;
        result -= (25 * alignmentCount - 10) * alignmentCount - 55;
        if (version >= 7) result -= 36;
    }
    return result;
}

function qrDataCapacity(version) {
    const rawCodewords = Math.floor(qrRawDataModules(version) / 8);
    return rawCodewords - QR_ECC_CODEWORDS_PER_BLOCK_LOW[version] * QR_ERROR_CORRECTION_BLOCKS_LOW[version];
}

function qrReedSolomonDivisor(degree) {
    const divisor = Array(degree).fill(0);
    divisor[degree - 1] = 1;
    let root = 1;
    for (let i = 0; i < degree; i += 1) {
        for (let j = 0; j < divisor.length; j += 1) {
            divisor[j] = qrMultiply(divisor[j], root);
            if (j + 1 < divisor.length) divisor[j] ^= divisor[j + 1];
        }
        root = qrMultiply(root, 2);
    }
    return divisor;
}

function qrReedSolomonRemainder(data, divisor) {
    const remainder = Array(divisor.length).fill(0);
    for (const byte of data) {
        const factor = byte ^ remainder.shift();
        remainder.push(0);
        divisor.forEach((coefficient, index) => {
            remainder[index] ^= qrMultiply(coefficient, factor);
        });
    }
    return remainder;
}

function qrAddErrorCorrection(dataCodewords, version) {
    const rawCodewords = Math.floor(qrRawDataModules(version) / 8);
    const blockCount = QR_ERROR_CORRECTION_BLOCKS_LOW[version];
    const eccLength = QR_ECC_CODEWORDS_PER_BLOCK_LOW[version];
    const shortBlockLength = Math.floor(rawCodewords / blockCount);
    const shortBlockCount = blockCount - (rawCodewords % blockCount);
    const divisor = qrReedSolomonDivisor(eccLength);
    const blocks = [];
    let offset = 0;

    for (let index = 0; index < blockCount; index += 1) {
        const dataLength = shortBlockLength - eccLength + (index < shortBlockCount ? 0 : 1);
        const blockData = dataCodewords.slice(offset, offset + dataLength);
        offset += dataLength;
        const ecc = qrReedSolomonRemainder(blockData, divisor);
        if (index < shortBlockCount) blockData.push(0);
        blocks.push(blockData.concat(ecc));
    }

    const interleaved = [];
    for (let index = 0; index < blocks[0].length; index += 1) {
        blocks.forEach((block, blockIndex) => {
            if (index !== shortBlockLength - eccLength || blockIndex >= shortBlockCount) {
                interleaved.push(block[index]);
            }
        });
    }
    return interleaved;
}

function qrAlignmentPositions(version, size) {
    if (version === 1) return [];
    const count = Math.floor(version / 7) + 2;
    const step = Math.floor((version * 8 + count * 3 + 5) / (count * 4 - 4)) * 2;
    const positions = [6];
    for (let position = size - 7; positions.length < count; position -= step) {
        positions.splice(1, 0, position);
    }
    return positions;
}

function qrGetBit(value, index) {
    return ((value >>> index) & 1) !== 0;
}

function qrDrawFormatBits(modules, functions, size, mask) {
    const data = (1 << 3) | mask; // Low error correction level is format value 01.
    let remainder = data;
    for (let i = 0; i < 10; i += 1) {
        remainder = (remainder << 1) ^ ((remainder >>> 9) * 0x537);
    }
    const bits = ((data << 10) | remainder) ^ 0x5412;
    const set = (x, y, value) => {
        modules[y][x] = value;
        functions[y][x] = true;
    };

    for (let i = 0; i <= 5; i += 1) set(8, i, qrGetBit(bits, i));
    set(8, 7, qrGetBit(bits, 6));
    set(8, 8, qrGetBit(bits, 7));
    set(7, 8, qrGetBit(bits, 8));
    for (let i = 9; i < 15; i += 1) set(14 - i, 8, qrGetBit(bits, i));
    for (let i = 0; i < 8; i += 1) set(size - 1 - i, 8, qrGetBit(bits, i));
    for (let i = 8; i < 15; i += 1) set(8, size - 15 + i, qrGetBit(bits, i));
    set(8, size - 8, true);
}

function qrDrawVersionBits(modules, functions, size, version) {
    if (version < 7) return;
    let remainder = version;
    for (let i = 0; i < 12; i += 1) {
        remainder = (remainder << 1) ^ ((remainder >>> 11) * 0x1f25);
    }
    const bits = (version << 12) | remainder;
    for (let i = 0; i < 18; i += 1) {
        const value = qrGetBit(bits, i);
        const a = size - 11 + (i % 3);
        const b = Math.floor(i / 3);
        modules[b][a] = value;
        functions[b][a] = true;
        modules[a][b] = value;
        functions[a][b] = true;
    }
}

function qrBuildMatrix(version, codewords, mask) {
    const size = version * 4 + 17;
    const modules = Array.from({ length: size }, () => Array(size).fill(false));
    const functions = Array.from({ length: size }, () => Array(size).fill(false));
    const setFunction = (x, y, value) => {
        modules[y][x] = value;
        functions[y][x] = true;
    };
    const drawFinder = (centerX, centerY) => {
        for (let dy = -4; dy <= 4; dy += 1) {
            for (let dx = -4; dx <= 4; dx += 1) {
                const x = centerX + dx;
                const y = centerY + dy;
                if (x >= 0 && x < size && y >= 0 && y < size) {
                    const distance = Math.max(Math.abs(dx), Math.abs(dy));
                    setFunction(x, y, distance !== 2 && distance !== 4);
                }
            }
        }
    };
    const drawAlignment = (centerX, centerY) => {
        for (let dy = -2; dy <= 2; dy += 1) {
            for (let dx = -2; dx <= 2; dx += 1) {
                setFunction(centerX + dx, centerY + dy, Math.max(Math.abs(dx), Math.abs(dy)) !== 1);
            }
        }
    };

    for (let i = 0; i < size; i += 1) {
        setFunction(6, i, i % 2 === 0);
        setFunction(i, 6, i % 2 === 0);
    }
    drawFinder(3, 3);
    drawFinder(size - 4, 3);
    drawFinder(3, size - 4);
    const alignment = qrAlignmentPositions(version, size);
    alignment.forEach((y, yIndex) => alignment.forEach((x, xIndex) => {
        if (!((yIndex === 0 && xIndex === 0) ||
              (yIndex === 0 && xIndex === alignment.length - 1) ||
              (yIndex === alignment.length - 1 && xIndex === 0))) {
            drawAlignment(x, y);
        }
    }));
    qrDrawFormatBits(modules, functions, size, 0);
    qrDrawVersionBits(modules, functions, size, version);

    let bitIndex = 0;
    for (let right = size - 1; right >= 1; right -= 2) {
        if (right === 6) right = 5;
        for (let vertical = 0; vertical < size; vertical += 1) {
            for (let j = 0; j < 2; j += 1) {
                const x = right - j;
                const upward = ((right + 1) & 2) === 0;
                const y = upward ? size - 1 - vertical : vertical;
                if (!functions[y][x] && bitIndex < codewords.length * 8) {
                    modules[y][x] = qrGetBit(codewords[bitIndex >>> 3], 7 - (bitIndex & 7));
                    bitIndex += 1;
                }
            }
        }
    }

    const applyMask = (selectedMask) => {
        for (let y = 0; y < size; y += 1) {
            for (let x = 0; x < size; x += 1) {
                let invert;
                switch (selectedMask) {
                    case 0: invert = (x + y) % 2 === 0; break;
                    case 1: invert = y % 2 === 0; break;
                    case 2: invert = x % 3 === 0; break;
                    case 3: invert = (x + y) % 3 === 0; break;
                    case 4: invert = (Math.floor(x / 3) + Math.floor(y / 2)) % 2 === 0; break;
                    case 5: invert = (x * y) % 2 + (x * y) % 3 === 0; break;
                    case 6: invert = ((x * y) % 2 + (x * y) % 3) % 2 === 0; break;
                    default: invert = ((x + y) % 2 + (x * y) % 3) % 2 === 0; break;
                }
                if (!functions[y][x] && invert) modules[y][x] = !modules[y][x];
            }
        }
    };
    const penalty = () => {
        let score = 0;
        const addLinePenalty = (line) => {
            let runColor = line[0];
            let runLength = 1;
            for (let i = 1; i < line.length; i += 1) {
                if (line[i] === runColor) {
                    runLength += 1;
                    if (runLength === 5) score += 3;
                    else if (runLength > 5) score += 1;
                } else {
                    runColor = line[i];
                    runLength = 1;
                }
            }
            for (let i = 0; i <= line.length - 7; i += 1) {
                if (line[i] && !line[i + 1] && line[i + 2] && line[i + 3] && line[i + 4] && !line[i + 5] && line[i + 6]) {
                    const before = i >= 4 && line.slice(i - 4, i).every((value) => !value);
                    const after = i + 11 <= line.length && line.slice(i + 7, i + 11).every((value) => !value);
                    if (before || after) score += 40;
                }
            }
        };
        for (let y = 0; y < size; y += 1) addLinePenalty(modules[y]);
        for (let x = 0; x < size; x += 1) addLinePenalty(modules.map((row) => row[x]));
        for (let y = 0; y < size - 1; y += 1) {
            for (let x = 0; x < size - 1; x += 1) {
                const value = modules[y][x];
                if (value === modules[y][x + 1] && value === modules[y + 1][x] && value === modules[y + 1][x + 1]) score += 3;
            }
        }
        let dark = 0;
        modules.forEach((row) => row.forEach((value) => { if (value) dark += 1; }));
        score += (Math.ceil(Math.abs(dark * 20 - size * size * 10) / (size * size)) - 1) * 10;
        return score;
    };

    let bestMask = 0;
    let bestPenalty = Number.POSITIVE_INFINITY;
    for (let candidate = 0; candidate < 8; candidate += 1) {
        applyMask(candidate);
        qrDrawFormatBits(modules, functions, size, candidate);
        const candidatePenalty = penalty();
        if (candidatePenalty < bestPenalty) {
            bestPenalty = candidatePenalty;
            bestMask = candidate;
        }
        applyMask(candidate);
    }
    applyMask(bestMask);
    qrDrawFormatBits(modules, functions, size, bestMask);
    return modules;
}

function qrEncode(text) {
    const bytes = typeof TextEncoder === 'function'
        ? Array.from(new TextEncoder().encode(text))
        : Array.from(unescape(encodeURIComponent(text)), (character) => character.charCodeAt(0));
    let version = 1;
    while (version < 40 && 4 + (version <= 9 ? 8 : 16) + bytes.length * 8 > qrDataCapacity(version) * 8) version += 1;
    const countBits = version <= 9 ? 8 : 16;
    if (4 + countBits + bytes.length * 8 > qrDataCapacity(version) * 8) throw new Error('Enrollment payload is too large for a QR code.');

    const bits = [];
    qrAppendBits(bits, 0x4, 4); // Byte mode.
    qrAppendBits(bits, bytes.length, countBits);
    bytes.forEach((byte) => qrAppendBits(bits, byte, 8));
    const capacityBits = qrDataCapacity(version) * 8;
    qrAppendBits(bits, 0, Math.min(4, capacityBits - bits.length));
    while (bits.length % 8 !== 0) bits.push(0);
    for (let pad = 0xec; bits.length < capacityBits; pad ^= 0xec ^ 0x11) qrAppendBits(bits, pad, 8);
    const dataCodewords = [];
    for (let i = 0; i < bits.length; i += 8) {
        let byte = 0;
        for (let bit = 0; bit < 8; bit += 1) byte = (byte << 1) | bits[i + bit];
        dataCodewords.push(byte);
    }
    return qrBuildMatrix(version, qrAddErrorCorrection(dataCodewords, version), 0);
}

function renderPairingQr(payload) {
    pairingQrEl.replaceChildren();
    pairingQrEl.hidden = !payload;
    if (!payload) return;

    const matrix = qrEncode(payload);
    const size = matrix.length;
    const svg = document.createElementNS
        ? document.createElementNS('http://www.w3.org/2000/svg', 'svg')
        : document.createElement('svg');
    svg.setAttribute('viewBox', `0 0 ${size + 8} ${size + 8}`);
    svg.setAttribute('role', 'img');
    svg.setAttribute('aria-label', 'Scan this QR code to enroll the phone');
    const createSvgElement = (tagName) => document.createElementNS
        ? document.createElementNS('http://www.w3.org/2000/svg', tagName)
        : document.createElement(tagName);
    const background = createSvgElement('rect');
    background.setAttribute('x', '0');
    background.setAttribute('y', '0');
    background.setAttribute('width', String(size + 8));
    background.setAttribute('height', String(size + 8));
    background.setAttribute('fill', '#ffffff');
    svg.appendChild(background);
    matrix.forEach((row, y) => row.forEach((dark, x) => {
        if (!dark) return;
        const module = createSvgElement('rect');
        module.setAttribute('x', String(x + 4));
        module.setAttribute('y', String(y + 4));
        module.setAttribute('width', '1');
        module.setAttribute('height', '1');
        module.setAttribute('fill', '#000000');
        svg.appendChild(module);
    }));
    pairingQrEl.appendChild(svg);
}

function availableStorages() {
    const storages = [];
    try {
        storages.push(window.sessionStorage);
    } catch (_) {
        // Storage can be unavailable in private/restricted browser contexts.
    }
    return storages;
}

function clearLegacyPersistentAuthToken() {
    try {
        window.localStorage.removeItem(AUTH_TOKEN_STORAGE_KEY);
    } catch (_) {
        // Storage can be unavailable in private/restricted browser contexts.
    }
}

function readAuthToken(storage) {
    try {
        return storage.getItem(AUTH_TOKEN_STORAGE_KEY);
    } catch (_) {
        return null;
    }
}

function storedAuthToken() {
    return availableStorages().map(readAuthToken).find(Boolean) || null;
}

function storeAuthToken(token) {
    availableStorages().forEach((storage) => {
        try {
            storage.setItem(AUTH_TOKEN_STORAGE_KEY, token);
        } catch (_) {
            // Storage can be unavailable in private/restricted browser contexts.
        }
    });
}

function clearStoredAuthToken() {
    availableStorages().forEach((storage) => {
        try {
            storage.removeItem(AUTH_TOKEN_STORAGE_KEY);
        } catch (_) {
            // Storage can be unavailable in private/restricted browser contexts.
        }
    });
}

function setConnectionStatus(text, className) {
    statusEl.textContent = text;
    statusEl.className = className;
}

function updateRecoveryControls() {
    reloadConfigBtn.style.display = configSaveBlocked ? 'block' : 'none';
    reloadConfigBtn.disabled = !configSaveBlocked;
}

function preserveDraftUntilReload(message) {
    configRevision = null;
    configSaveBlocked = true;
    isDirty = true;
    setConnectionStatus(message, 'status-offline');
    updateManualSaveBtn();
    updateRecoveryControls();
}

function discardDraftAndReload() {
    if (!configSaveBlocked) return;
    window.location.reload();
}

function createTextElement(tagName, className, text) {
    const element = document.createElement(tagName);
    if (className) element.className = className;
    element.textContent = text == null ? '' : String(text);
    return element;
}

function createMaterialIcon(iconName, className = '') {
    return createTextElement('span', `material-symbols-outlined${className ? ` ${className}` : ''}`, iconName);
}

function showAuthModal(message = '') {
    authModal.classList.add('show');
    authModal.setAttribute('aria-hidden', 'false');
    authErrorEl.textContent = message;
    if (!message) pairingCodeInput.focus();
}

function isTrayDashboard() {
    return new URLSearchParams(window.location.search).get('tray') === '1';
}

async function requestLocalPairingCode() {
    if (localPairingRequested) return;
    localPairingRequested = true;
    requestPairingBtn.disabled = true;
    requestPairingBtn.textContent = 'Loading local code...';
    try {
        // QR/copy-paste enrollment is the exact JSON consumed by
        // EnrollmentInvite.parse on Android. It is served only by a secure
        // daemon listener; a plaintext tray dashboard still keeps the short
        // code fallback below.
        let enrollmentPayload = null;
        try {
            const enrollmentResponse = await fetch('/enrollment', { credentials: 'same-origin' });
            if (enrollmentResponse.ok) {
                const candidate = await enrollmentResponse.json();
                const expected = ['version', 'scheme', 'host', 'port', 'certificate_sha256', 'challenge', 'issued_at', 'expires_at'];
                if (candidate && expected.every((key) => Object.prototype.hasOwnProperty.call(candidate, key)) &&
                    Object.keys(candidate).length === expected.length && candidate.version === 1 && candidate.scheme === 'https' &&
                    typeof candidate.host === 'string' && Number.isInteger(candidate.port) &&
                    typeof candidate.certificate_sha256 === 'string' && typeof candidate.challenge === 'string' &&
                    typeof candidate.issued_at === 'string' && typeof candidate.expires_at === 'string') {
                    enrollmentPayload = candidate;
                }
            }
        } catch (_) {
            // The HTTP loopback tray dashboard may not have a secure
            // enrollment route. The local short-code path remains available.
        }

        let pairing = null;
        try {
            const response = await fetch('/pairing', { credentials: 'same-origin' });
            if (response.ok) {
                const candidate = await response.json();
                if (typeof candidate.code === 'string' && typeof candidate.expires_at === 'string') {
                    pairing = candidate;
                }
            }
        } catch (_) {
            // Secure LAN dashboards intentionally do not expose the local
            // short-code route; the enrollment payload is still usable.
        }
        if (enrollmentPayload === null && pairing === null) {
            throw new Error('The daemon returned no enrollment or local pairing data.');
        }
        if (pairing !== null) {
            pairingCodeInput.value = pairing.code;
            pairingCodeDisplay.textContent = pairing.code;
            pairingExpires.textContent = `Expires ${new Date(pairing.expires_at).toLocaleTimeString()} (one use only)`;
        } else {
            pairingCodeDisplay.textContent = '';
            pairingExpires.textContent = 'Secure enrollment is available; use the payload below.';
        }
        pairingPayloadEl.textContent = enrollmentPayload === null
            ? 'Secure QR enrollment is unavailable on this dashboard. Use the one-time code below.'
            : JSON.stringify(enrollmentPayload);
        try {
            renderPairingQr(enrollmentPayload === null ? '' : pairingPayloadEl.textContent);
        } catch (_) {
            // Keep copy/paste and the short-code fallback if a future payload
            // exceeds the QR encoder's bounded capacity.
            renderPairingQr('');
            authErrorEl.textContent = 'QR display is unavailable; use the pairing payload or short code below.';
        }
        localPairingPanel.hidden = false;
        requestPairingBtn.textContent = 'Refresh enrollment / pairing data';
        localPairingRequested = false;
        requestPairingBtn.disabled = false;
    } catch (error) {
        renderPairingQr('');
        requestPairingBtn.disabled = false;
        requestPairingBtn.textContent = 'Show enrollment / pairing data';
        localPairingRequested = false;
        authErrorEl.textContent = error instanceof Error ? error.message : 'Could not load a local pairing code.';
    }
}

function hideAuthModal() {
    authModal.classList.remove('show');
    authModal.setAttribute('aria-hidden', 'true');
    authErrorEl.textContent = '';
    pairingCodeInput.value = '';
    renderPairingQr('');
}

clearLegacyPersistentAuthToken();

function sendAuthenticatedMessage(payload) {
    if (!isAuthenticated || !ws || ws.readyState !== WebSocket.OPEN) return false;
    ws.send(JSON.stringify(payload));
    return true;
}

function requestSystemApps() {
    sendAuthenticatedMessage({ type: 'get_system_apps' });
}

function scheduleReconnect() {
    if (reconnectTimer !== null) return;
    reconnectTimer = window.setTimeout(() => {
        reconnectTimer = null;
        connectWebSocket();
    }, RECONNECT_DELAY_MS);
}

function connectWebSocket() {
    if (ws && (ws.readyState === WebSocket.OPEN || ws.readyState === WebSocket.CONNECTING)) return;

    const protocol = window.location.protocol === 'https:' ? 'wss' : 'ws';
    ws = new WebSocket(`${protocol}://${window.location.host}/ws`);

    ws.onopen = () => {
        isAuthenticated = false;
        authChallengeReceived = false;
        setConnectionStatus('Authenticating...', 'status-offline');
    };

    ws.onclose = () => {
        isAuthenticated = false;
        authChallengeReceived = false;
        systemApps = [];
        systemAppsLoaded = false;
        updateApprovedAppsHint();
        setConnectionStatus('Offline', 'status-offline');
        scheduleReconnect();
    };

    ws.onerror = () => {
        setConnectionStatus('Connection error', 'status-offline');
    };

    ws.onmessage = handleWebSocketMessage;
}

function handleWebSocketMessage(event) {
    try {
        const msg = JSON.parse(event.data);
        if (msg.type === 'auth_required') {
            authChallengeReceived = true;
            const token = storedAuthToken();
            if (token) {
                setConnectionStatus('Authenticating...', 'status-offline');
                ws.send(JSON.stringify({
                    type: 'authenticate',
                    token,
                    protocol_version: CLIENT_PROTOCOL_VERSION,
                }));
            } else {
                setConnectionStatus('Pairing required', 'status-offline');
                showAuthModal();
            }
            return;
        }

        if (msg.type === 'auth_success') {
            if (typeof msg.token !== 'string' || msg.token.length === 0) {
                isAuthenticated = false;
                clearStoredAuthToken();
                showAuthModal('The server did not provide a valid session. Enter a new pairing code.');
                return;
            }
            storeAuthToken(msg.token);
            isAuthenticated = true;
            setConnectionStatus('Online', 'status-online');
            hideAuthModal();
            return;
        }

        if (msg.type === 'auth_error') {
            if (msg.code !== 'insufficient_permissions') {
                isAuthenticated = false;
            }
            if (msg.code === 'invalid_credentials') {
                clearStoredAuthToken();
                setConnectionStatus('Pairing required', 'status-offline');
                showAuthModal(authErrorMessage(msg.code));
            } else if (msg.code === 'insufficient_permissions') {
                setConnectionStatus('Permission denied', 'status-offline');
                authErrorEl.textContent = authErrorMessage(msg.code);
            } else if (msg.code === 'authentication_required') {
                setConnectionStatus('Pairing required', 'status-offline');
                showAuthModal(authErrorMessage(msg.code));
            } else {
                setConnectionStatus('Authentication error', 'status-offline');
                showAuthModal(authErrorMessage(msg.code));
            }
            return;
        }

        if (!isAuthenticated) return;

        if (msg.type === 'action_error') {
            setConnectionStatus(`Action failed: ${msg.action || 'request'}`, 'status-offline');
            return;
        }

        if (msg.type === 'config_error') {
            isDirty = true;
            if (msg.code === 'config_conflict') {
                preserveDraftUntilReload(configErrorMessage(msg.code));
            } else {
                setConnectionStatus(configErrorMessage(msg.code), 'status-offline');
            }
            updateManualSaveBtn();
            return;
        }

        if (msg.type === 'config_sync' || msg.type === 'init_state' || msg.type === 'config_updated') {
            if (shouldPreserveLocalDraft(configData, isDirty)) {
                preserveDraftUntilReload('Server config changed; local edits are preserved until reload');
                return;
            }
            configData = msg.config;
            configRevision = hasUsableRevision(msg.revision)
                ? msg.revision
                : null;
            configSaveBlocked = false;
            isDirty = false;
            updateManualSaveBtn();
            updateRecoveryControls();
            renderSidebar();
            renderGrid();
            if (msg.type === 'init_state') {
                systemApps = [];
                systemAppsLoaded = false;
                updateApprovedAppsHint();
                requestSystemApps();
            }
        } else if (msg.type === 'system_apps_list') {
            systemApps = Array.isArray(msg.apps)
                ? msg.apps.filter(app => app && app.approved === true && typeof app.payload === 'string' && typeof app.name === 'string')
                : [];
            systemAppsLoaded = true;
            updateApprovedAppsHint();
            if (modal.classList.contains('show') && document.getElementById('edit-action').value === 'launch_app') {
                if (appSearchResults.classList.contains('show')) {
                    renderAppSearchDropdown(appSearchInput.value.toLowerCase());
                }
            }
        }
    } catch(e) {
        console.error("Failed to parse message", e);
    }
}

authForm.addEventListener('submit', (event) => {
    event.preventDefault();
    const pairingCode = pairingCodeInput.value.trim();
    if (!pairingCode) {
        authErrorEl.textContent = 'Enter the pairing code to continue.';
        return;
    }
    if (!ws || ws.readyState !== WebSocket.OPEN || !authChallengeReceived) {
        authErrorEl.textContent = 'Waiting for the server connection. Try again in a moment.';
        return;
    }
    setConnectionStatus('Authenticating...', 'status-offline');
    ws.send(JSON.stringify({
        type: 'authenticate',
        pairing_code: pairingCode,
        protocol_version: CLIENT_PROTOCOL_VERSION,
    }));
});

requestPairingBtn.addEventListener('click', requestLocalPairingCode);
copyPairingBtn.addEventListener('click', async () => {
    if (!pairingPayloadEl.textContent || !pairingPayloadEl.textContent.startsWith('{')) {
        authErrorEl.textContent = 'Secure enrollment is unavailable; enter the short code manually.';
        return;
    }
    try {
        await navigator.clipboard.writeText(pairingPayloadEl.textContent);
        copyPairingBtn.textContent = 'Copied pairing payload';
        window.setTimeout(() => { copyPairingBtn.textContent = 'Copy pairing payload'; }, 1600);
    } catch (_) {
        authErrorEl.textContent = 'Copy is unavailable; select the pairing payload manually.';
    }
});

connectWebSocket();
if (isTrayDashboard()) {
    requestLocalPairingCode();
}

// Save Logic
autoSaveToggle.addEventListener('change', (e) => {
    autoSave = e.target.checked;
    updateManualSaveBtn();
});

function markDirty() {
    isDirty = true;
    if (autoSave) {
        saveConfig();
    } else {
        updateManualSaveBtn();
    }
}

function updateManualSaveBtn() {
    manualSaveBtn.style.display = autoSave ? 'none' : 'block';
    manualSaveBtn.disabled = configSaveBlocked;
    if (!autoSave) {
        if (isDirty) {
            manualSaveBtn.style.backgroundColor = 'var(--success-color)';
            manualSaveBtn.replaceChildren(createMaterialIcon('save'), document.createTextNode(' Save & Apply *'));
        } else {
            manualSaveBtn.style.backgroundColor = 'var(--accent-color)';
            manualSaveBtn.replaceChildren(createMaterialIcon('save'), document.createTextNode(' Save & Apply'));
        }
    }
}

reloadConfigBtn.addEventListener('click', discardDraftAndReload);

manualSaveBtn.addEventListener('click', () => {
    if (isDirty) saveConfig();
});

function saveConfig() {
    if (configSaveBlocked) {
        setConnectionStatus('Reload the configurator before saving', 'status-offline');
        return;
    }
    const payload = {
        type: "save_config",
        config: configData,
    };
    if (Number.isSafeInteger(configRevision) && configRevision >= 0) {
        payload.revision = configRevision;
    }
    const sent = sendAuthenticatedMessage(payload);
    if (!sent) return;
    isDirty = false;
    updateManualSaveBtn();
}

// Sidebar Logic
document.getElementById('add-board-btn').addEventListener('click', () => {
    if (!configData) return;
    if (!configData.boards) configData.boards = [];
    configData.boards.push({
        id: `board_${Date.now()}`,
        title: `Board ${configData.boards.length + 1}`,
        grid_columns: 4,
        grid_rows: 3,
        items: []
    });
    activeBoardIdx = configData.boards.length - 1;
    markDirty();
    renderSidebar();
    renderGrid();
});

function renderSidebar() {
    if (!configData || !configData.boards) return;
    
    boardListEl.replaceChildren();
    configData.boards.forEach((board, idx) => {
        const item = document.createElement('div');
        item.className = `board-item ${idx === activeBoardIdx ? 'active' : ''}`;
        item.append(
            createMaterialIcon('layers'),
            createTextElement('span', 'title', board.title || 'Board')
        );
        
        if (idx === activeBoardIdx) {
            const actionsDiv = document.createElement('div');
            actionsDiv.style.display = 'flex';
            actionsDiv.style.gap = '8px';

            const editBtn = document.createElement('span');
            editBtn.className = 'material-symbols-outlined';
            editBtn.style.fontSize = '1.1rem';
            editBtn.style.opacity = '0.7';
            editBtn.style.cursor = 'pointer';
            editBtn.textContent = 'edit';
            editBtn.onclick = (e) => {
                e.stopPropagation();
                const newTitle = prompt("Enter new board title:", board.title);
                if (newTitle) {
                    board.title = newTitle;
                    markDirty();
                    renderSidebar();
                }
            };
            
            const deleteBtn = document.createElement('span');
            deleteBtn.className = 'material-symbols-outlined';
            deleteBtn.style.fontSize = '1.1rem';
            deleteBtn.style.opacity = '0.7';
            deleteBtn.style.color = 'var(--danger-color)';
            deleteBtn.style.cursor = 'pointer';
            deleteBtn.textContent = 'delete';
            deleteBtn.onclick = (e) => {
                e.stopPropagation();
                if (configData.boards.length <= 1) {
                    alert("Cannot delete the last board.");
                    return;
                }
                if (confirm(`Are you sure you want to delete '${board.title}'?`)) {
                    configData.boards.splice(idx, 1);
                    activeBoardIdx = Math.max(0, idx - 1);
                    markDirty();
                    renderSidebar();
                    renderGrid();
                }
            };

            actionsDiv.appendChild(editBtn);
            actionsDiv.appendChild(deleteBtn);
            item.appendChild(actionsDiv);
        }
        
        item.onclick = () => {
            activeBoardIdx = idx;
            renderSidebar();
            renderGrid();
        };
        
        boardListEl.appendChild(item);
    });

    const activeBoard = configData.boards[activeBoardIdx];
    if (activeBoard) {
        colsSelect.value = activeBoard.grid_columns || 4;
        rowsSelect.value = activeBoard.grid_rows || 3;
    }
}

colsSelect.addEventListener('change', (e) => {
    if (!configData) return;
    configData.boards[activeBoardIdx].grid_columns = parseInt(e.target.value);
    markDirty();
    renderGrid();
});
rowsSelect.addEventListener('change', (e) => {
    if (!configData) return;
    configData.boards[activeBoardIdx].grid_rows = parseInt(e.target.value);
    markDirty();
    renderGrid();
});

// Grid Logic
let occupied = [];

function canFit(r, c, spanRows, spanCols, ignoreIdx = null) {
    const board = configData.boards[activeBoardIdx];
    const cols = board.grid_columns || 4;
    const rows = board.grid_rows || 3;
    
    if (r < 0 || c < 0 || r + spanRows > rows || c + spanCols > cols) return false;
    
    const items = board.items || [];
    for (let i = 0; i < items.length; i++) {
        if (i === ignoreIdx) continue;
        const item = items[i];
        const ir = item.grid_y || 0;
        const ic = item.grid_x || 0;
        const iRows = item.span_rows || 1;
        const iCols = item.span_cols || 1;
        
        // Rect intersection test
        if (!(c + spanCols <= ic || c >= ic + iCols || r + spanRows <= ir || r >= ir + iRows)) {
            return false;
        }
    }
    return true;
}

function renderGrid() {
    if (!configData || !configData.boards || configData.boards.length === 0) return;
    
    const board = configData.boards[activeBoardIdx];
    const cols = board.grid_columns || 4;
    const rows = board.grid_rows || 3;
    const items = board.items || [];
    
    matrixEl.style.gridTemplateColumns = `repeat(${cols}, 1fr)`;
    matrixEl.style.gridTemplateRows = `repeat(${rows}, 100px)`; 
    matrixEl.replaceChildren();

    occupied = Array(rows).fill().map(() => Array(cols).fill(false));

    function markOccupied(r, c, spanRows, spanCols) {
        for (let i = r; i < r + spanRows; i++) {
            for (let j = c; j < c + spanCols; j++) {
                if (i < rows && j < cols) occupied[i][j] = true;
            }
        }
    }

    items.forEach((item, idx) => {
        let r = item.grid_y;
        let c = item.grid_x;
        const spanRows = item.span_rows || 1;
        const spanCols = item.span_cols || 1;

        if (r === undefined || c === undefined || !canFit(r, c, spanRows, spanCols, idx)) {
            let placed = false;
            for (let i = 0; i < rows && !placed; i++) {
                for (let j = 0; j < cols && !placed; j++) {
                    if (canFit(i, j, spanRows, spanCols, idx)) {
                        r = i;
                        c = j;
                        item.grid_y = r;
                        item.grid_x = c;
                        placed = true;
                    }
                }
            }
        }

        if (r !== undefined && c !== undefined) {
            markOccupied(r, c, spanRows, spanCols);
            const el = createTile(item, idx, r, c, spanRows, spanCols);
            matrixEl.appendChild(el);
        }
    });

    for (let i = 0; i < rows; i++) {
        for (let j = 0; j < cols; j++) {
            if (!occupied[i][j]) {
                const emptyEl = document.createElement('div');
                emptyEl.className = 'deck-tile-empty';
                emptyEl.style.gridRow = `${i + 1} / span 1`;
                emptyEl.style.gridColumn = `${j + 1} / span 1`;
                emptyEl.appendChild(createMaterialIcon('add'));
                emptyEl.onclick = () => openEditor(null, j, i);
                setupDropTarget(emptyEl, j, i);
                matrixEl.appendChild(emptyEl);
            }
        }
    }
}

function getIconText(item) {
    if (item.type === "volume_slider") return "volume_up";
    if (item.type === "brightness_slider") return "light_mode";
    if (item.icon) return item.icon;
    return "widgets";
}

function createTile(item, idx, r, c, spanRows, spanCols) {
    const el = document.createElement('div');
    el.className = 'deck-tile';
    el.draggable = true;
    el.style.gridRow = `${r + 1} / span ${spanRows}`;
    el.style.gridColumn = `${c + 1} / span ${spanCols}`;
    
    let icon = getIconText(item);
    let color = 'var(--accent-color)';
    if (item.type === "brightness_slider") color = '#F59E0B';

    if (item.action === 'clock_widget') {
        const timeEl = createTextElement('div', 'tile-title', '--:--');
        const clockId = `clock_${item.id}`;
        timeEl.id = clockId;
        timeEl.style.color = color;
        timeEl.style.fontSize = `${1 + (spanCols * 0.2)}rem`;
        timeEl.style.fontWeight = 'bold';
        timeEl.style.marginTop = 'auto';
        timeEl.style.marginBottom = 'auto';
        el.appendChild(timeEl);
        const updateTime = () => {
            const currentTimeEl = document.getElementById(clockId);
            if (currentTimeEl) {
                const now = new Date();
                currentTimeEl.textContent = now.toLocaleTimeString([], { hour: 'numeric', minute: '2-digit', hour12: true });
            }
        };
        updateTime(); // Call instantly
        setInterval(updateTime, 1000);
    } else if (item.icon_base64) {
        const image = document.createElement('img');
        image.src = item.icon_base64;
        image.style.width = '100%';
        image.style.height = '100%';
        image.style.objectFit = 'contain';
        image.style.borderRadius = '8px';
        el.appendChild(image);
        if (item.title) {
            const title = createTextElement('div', 'tile-title', item.title);
            title.style.color = color;
            title.style.background = 'rgba(0,0,0,0.5)';
            title.style.padding = '2px 4px';
            title.style.borderRadius = '4px';
            title.style.position = 'absolute';
            title.style.bottom = '5px';
            el.appendChild(title);
        }
    } else if (item.system_icon_path) {
        const image = document.createElement('img');
        image.src = `/system_icons?path=${encodeURIComponent(item.system_icon_path)}`;
        image.style.width = '60%';
        image.style.height = '60%';
        image.style.objectFit = 'contain';
        image.style.borderRadius = '8px';
        el.appendChild(image);
        if (item.title) {
            const title = createTextElement('div', 'tile-title', item.title);
            title.style.color = color;
            el.appendChild(title);
        }
    } else {
        const iconEl = createTextElement('div', 'tile-icon');
        iconEl.style.color = color;
        iconEl.appendChild(createMaterialIcon(icon));
        const title = createTextElement('div', 'tile-title', item.title || 'Button');
        title.style.color = color;
        el.append(iconEl, title);
    }
    
    if (item.type === "volume_slider" || item.type === "brightness_slider") {
        const sliderTrack = document.createElement('div');
        sliderTrack.className = 'tile-slider-track';
        const sliderFill = document.createElement('div');
        sliderFill.className = 'tile-slider-fill';
        sliderFill.style.background = color;
        sliderTrack.appendChild(sliderFill);
        el.appendChild(sliderTrack);
    }

    el.addEventListener('dragstart', (e) => {
        draggedItemIndex = idx;
        e.dataTransfer.setData('text/plain', idx);
        
        const rect = el.getBoundingClientRect();
        const offsetX = e.clientX ? e.clientX - rect.left : rect.width / 2;
        const offsetY = e.clientY ? e.clientY - rect.top : rect.height / 2;
        
        // Wrap in a container to prevent browser from stripping opacity from root
        const dragWrapper = document.createElement('div');
        dragWrapper.style.position = 'absolute';
        dragWrapper.style.top = '-9999px';
        dragWrapper.style.left = '-9999px';
        dragWrapper.style.zIndex = '-100';
        
        const dragGhost = el.cloneNode(true);
        dragGhost.style.opacity = '0.25'; // Make entire button transparent
        dragGhost.style.width = rect.width + 'px';
        dragGhost.style.height = rect.height + 'px';
        dragGhost.style.margin = '0'; // Ensure no offset inside wrapper
        
        dragWrapper.appendChild(dragGhost);
        document.body.appendChild(dragWrapper);
        e.dataTransfer.setDragImage(dragWrapper, offsetX, offsetY);
        
        setTimeout(() => {
            document.body.removeChild(dragWrapper);
            el.classList.add('dragging');
        }, 0);
    });
    
    el.addEventListener('dragend', () => {
        el.classList.remove('dragging');
        draggedItemIndex = null;
    });

    setupDropTarget(el, c, r, idx);
    el.addEventListener('click', () => openEditor(idx));

    return el;
}

function setupDropTarget(el, targetX, targetY, targetIdx = null) {
    el.addEventListener('dragover', (e) => {
        e.preventDefault();
        if (draggedItemIndex === null) return;
        
        const items = configData.boards[activeBoardIdx].items;
        const draggedItem = items[draggedItemIndex];
        const spanCols = draggedItem.span_cols || 1;
        const spanRows = draggedItem.span_rows || 1;
        
        let isValid = canFit(targetY, targetX, spanRows, spanCols, draggedItemIndex);
        
        if (!isValid) {
            if (targetIdx !== null) {
                // Check if it can swap
                const tItem = items[targetIdx];
                const oldDX = draggedItem.grid_x;
                const oldDY = draggedItem.grid_y;
                if (canFitDoubleIgnore(tItem.grid_y, tItem.grid_x, spanRows, spanCols, draggedItemIndex, targetIdx) &&
                    canFitDoubleIgnore(oldDY, oldDX, tItem.span_rows || 1, tItem.span_cols || 1, draggedItemIndex, targetIdx)) {
                    isValid = true;
                }
            }
        }
        
        if (isValid) {
            el.classList.add('drag-over-green');
            el.classList.remove('drag-over-red');
        } else {
            el.classList.add('drag-over-red');
            el.classList.remove('drag-over-green');
        }
    });

    el.addEventListener('dragleave', () => {
        el.classList.remove('drag-over-green');
        el.classList.remove('drag-over-red');
    });

    el.addEventListener('drop', (e) => {
        e.preventDefault();
        el.classList.remove('drag-over-green');
        el.classList.remove('drag-over-red');
        
        const draggedIdx = e.dataTransfer.getData('text/plain');
        if (draggedIdx && draggedIdx != targetIdx) {
            handleDrop(parseInt(draggedIdx), targetX, targetY, targetIdx);
        }
    });
}

function findValidSnap(draggedIdx, targetX, targetY, spanCols, spanRows) {
    if (canFit(targetY, targetX, spanRows, spanCols, draggedIdx)) return {x: targetX, y: targetY};
    const offsets = [
        {dx: -1, dy: 0}, {dx: 0, dy: -1}, {dx: -1, dy: -1},
        {dx: -2, dy: 0}, {dx: 0, dy: -2}, {dx: 1, dy: 0}, {dx: 0, dy: 1}
    ];
    for (let off of offsets) {
        const nx = targetX + off.dx;
        const ny = targetY + off.dy;
        if (nx >= 0 && ny >= 0 && canFit(ny, nx, spanRows, spanCols, draggedIdx)) {
            return {x: nx, y: ny};
        }
    }
    return null;
}

function canFitDoubleIgnore(r, c, spanRows, spanCols, ignore1, ignore2) {
    const board = configData.boards[activeBoardIdx];
    const cols = board.grid_columns || 4;
    const rows = board.grid_rows || 3;
    if (r < 0 || c < 0 || r + spanRows > rows || c + spanCols > cols) return false;
    
    const items = board.items || [];
    for (let i = 0; i < items.length; i++) {
        if (i === ignore1 || i === ignore2) continue;
        const item = items[i];
        const ir = item.grid_y || 0;
        const ic = item.grid_x || 0;
        const iRows = item.span_rows || 1;
        const iCols = item.span_cols || 1;
        if (!(c + spanCols <= ic || c >= ic + iCols || r + spanRows <= ir || r >= ir + iRows)) return false;
    }
    return true;
}

function handleDrop(draggedIdx, targetX, targetY, targetIdx = null) {
    const items = configData.boards[activeBoardIdx].items;
    const draggedItem = items[draggedIdx];
    const spanCols = draggedItem.span_cols || 1;
    const spanRows = draggedItem.span_rows || 1;
    
    // First try smart snap
    const snap = findValidSnap(draggedIdx, targetX, targetY, spanCols, spanRows);
    if (snap) {
        items[draggedIdx].grid_x = snap.x;
        items[draggedIdx].grid_y = snap.y;
        markDirty();
        renderGrid();
        return;
    }
    
    // If it didn't snap, try swap if dropped on another item
    if (targetIdx !== null) {
        const targetItem = items[targetIdx];
        const tSpanCols = targetItem.span_cols || 1;
        const tSpanRows = targetItem.span_rows || 1;
        
        const oldDX = draggedItem.grid_x;
        const oldDY = draggedItem.grid_y;
        
        if (canFitDoubleIgnore(targetItem.grid_y, targetItem.grid_x, spanRows, spanCols, draggedIdx, targetIdx) &&
            canFitDoubleIgnore(oldDY, oldDX, tSpanRows, tSpanCols, draggedIdx, targetIdx)) {
            
            items[draggedIdx].grid_x = targetItem.grid_x;
            items[draggedIdx].grid_y = targetItem.grid_y;
            
            items[targetIdx].grid_x = oldDX;
            items[targetIdx].grid_y = oldDY;
            
            markDirty();
            renderGrid();
        }
    }
}

// Editor Modal Logic
const typeSelect = document.getElementById('edit-type');
const spanSelect = document.getElementById('edit-span');
const titleGroup = document.getElementById('title-group');
const actionGroup = document.getElementById('action-group');
const payloadGroup = document.getElementById('payload-group');
const iconGroup = document.getElementById('icon-group');
const customSpanInputs = document.getElementById('custom-span-inputs');
const actionSelect = document.getElementById('edit-action');

const appSearchContainer = document.getElementById('app-search-container');
const editPayloadCustom = document.getElementById('edit-payload-custom');
const appSearchInput = document.getElementById('app-search-input');
const appSearchResults = document.getElementById('app-search-results');
const editPayloadApp = document.getElementById('edit-payload-app');
const approvedAppsHint = document.getElementById('approved-apps-hint');
const launchAppError = document.getElementById('launch-app-error');

let defaultDropX = null;
let defaultDropY = null;

document.getElementById('add-btn').addEventListener('click', () => openEditor(null));
document.getElementById('btn-cancel').addEventListener('click', () => modal.classList.remove('show'));

function updateApprovedAppsHint() {
    const visible = actionSelect.value === 'launch_app' && typeSelect.value === 'button';
    approvedAppsHint.style.display = visible ? 'block' : 'none';
    if (!visible) return;
    approvedAppsHint.textContent = !systemAppsLoaded
        ? 'Loading approved applications...'
        : systemApps.length === 0
            ? 'No approved applications are available. Configure the local server registry (KDEDECK_APPROVED_APPS) and reload the configurator.'
            : 'Select an approved application from the list.';
}

function showLaunchAppError(message) {
    launchAppError.textContent = message;
    launchAppError.style.display = message ? 'block' : 'none';
}

function updatePayloadVisibility() {
    const type = typeSelect.value;
    const action = actionSelect.value;
    showLaunchAppError('');
    updateApprovedAppsHint();
    
    document.getElementById('edit-payload-media').style.display = 'none';
    document.getElementById('edit-payload-kde').style.display = 'none';
    
    if (type === 'volume_slider' || type === 'brightness_slider') {
        payloadGroup.style.display = 'none';
        return;
    }
    
    if (action === 'audio_volume' || action === 'brightness' || action === 'audio_mute_toggle' || action === 'clock_widget') {
        payloadGroup.style.display = 'none';
    } else {
        payloadGroup.style.display = 'block';
        if (action === 'launch_app') {
            // Launches are identity-only. The server resolves the selected
            // approved identity to a fixed executable and argv template.
            appSearchContainer.style.display = 'block';
            editPayloadCustom.style.display = 'none';
            appSearchInput.placeholder = 'Search approved applications...';
        } else if (action === 'mpris_action') {
            appSearchContainer.style.display = 'none';
            editPayloadCustom.style.display = 'none';
            document.getElementById('edit-payload-media').style.display = 'block';
        } else if (action === 'kde_action') {
            appSearchContainer.style.display = 'none';
            editPayloadCustom.style.display = 'none';
            document.getElementById('edit-payload-kde').style.display = 'block';
        } else {
            // For URLs or custom KDE actions, always show plain text box
            appSearchContainer.style.display = 'none';
            editPayloadCustom.style.display = 'block';
            
            if (action === 'open_url') {
                editPayloadCustom.placeholder = "https://www.youtube.com";
            } else {
                editPayloadCustom.placeholder = "Custom payload string";
            }
        }
    }
}

actionSelect.addEventListener('change', updatePayloadVisibility);

// App Search Logic
let currentSearchFocus = -1;

function renderAppSearchDropdown(query = '') {
    appSearchResults.replaceChildren();
    currentSearchFocus = -1;
    
    let results = systemApps;
    if (query.length > 0) {
        results = systemApps.filter(app => app.name.toLowerCase().includes(query) || app.payload.toLowerCase().includes(query));
    }
    
    if (results.length > 0) {
        results.forEach(app => {
            const li = document.createElement('li');
            li.append(
                createMaterialIcon('apps', 'app-icon'),
                createTextElement('div', '', '')
            );
            const appDetails = li.lastElementChild;
            appDetails.append(
                createTextElement('div', 'app-name', app.name),
                createTextElement('div', 'app-payload', app.payload)
            );
            li.onclick = () => {
                appSearchInput.value = app.name;
                editPayloadApp.value = app.payload;
                document.getElementById('edit-icon').value = app.icon || 'apps';
                document.getElementById('edit-system-icon-path').value = app.system_icon_path || '';
                document.getElementById('edit-title').value = app.name;
                appSearchResults.classList.remove('show');
            };
            appSearchResults.appendChild(li);
        });
        appSearchResults.classList.add('show');
    } else {
        const li = document.createElement('li');
        li.className = 'app-search-empty';
        const message = createTextElement('div', '', '');
        message.appendChild(createTextElement('div', 'app-name', !systemAppsLoaded ? 'Loading approved applications...' : systemApps.length === 0 ? 'No approved applications available' : 'No approved applications found'));
        li.appendChild(message);
        appSearchResults.appendChild(li);
        appSearchResults.classList.add('show');
    }
}

// Image Upload Logic
const imageUploadInput = document.getElementById('edit-image-upload');
const iconBase64Input = document.getElementById('edit-icon-base64');
const imagePreviewContainer = document.getElementById('image-preview-container');
const imagePreview = document.getElementById('image-preview');
const btnRemoveImage = document.getElementById('btn-remove-image');

imageUploadInput.addEventListener('change', (e) => {
    const file = e.target.files[0];
    if (!file) return;
    
    if (file.size > 5 * 1024 * 1024) { // 5MB limit
        alert("File is too large! Please select an image under 5MB to prevent syncing lag.");
        imageUploadInput.value = '';
        return;
    }
    
    const reader = new FileReader();
    reader.onload = (event) => {
        const base64Str = event.target.result;
        iconBase64Input.value = base64Str;
        imagePreview.src = base64Str;
        imagePreviewContainer.style.display = 'block';
    };
    reader.readAsDataURL(file);
});

btnRemoveImage.addEventListener('click', () => {
    iconBase64Input.value = '';
    imagePreview.src = '';
    imagePreviewContainer.style.display = 'none';
    imageUploadInput.value = '';
});

appSearchInput.addEventListener('keydown', (e) => {
    if (!appSearchResults.classList.contains('show')) return;
    
    const items = appSearchResults.getElementsByTagName('li');
    if (items.length === 0 || items[0].classList.contains('app-search-empty')) return;
    
    if (e.key === 'ArrowDown') {
        currentSearchFocus++;
        if (currentSearchFocus >= items.length) currentSearchFocus = 0;
        setActive(items);
        e.preventDefault();
    } else if (e.key === 'ArrowUp') {
        currentSearchFocus--;
        if (currentSearchFocus < 0) currentSearchFocus = items.length - 1;
        setActive(items);
        e.preventDefault();
    } else if (e.key === 'Enter') {
        e.preventDefault();
        if (currentSearchFocus > -1) {
            items[currentSearchFocus].click();
        }
    }
});

function setActive(items) {
    for (let i = 0; i < items.length; i++) {
        items[i].classList.remove('active');
    }
    if (currentSearchFocus > -1 && currentSearchFocus < items.length) {
        items[currentSearchFocus].classList.add('active');
        items[currentSearchFocus].scrollIntoView({ block: 'nearest' });
    }
}

appSearchInput.addEventListener('input', () => {
    editPayloadApp.value = '';
    showLaunchAppError('');
    renderAppSearchDropdown(appSearchInput.value.toLowerCase());
});

appSearchInput.addEventListener('focus', () => {
    // We let click handle opening to avoid auto-opening when modal focuses
});

appSearchInput.addEventListener('click', () => {
    renderAppSearchDropdown(appSearchInput.value.toLowerCase());
});

// Hide dropdown if clicked outside
document.addEventListener('click', (e) => {
    if (!appSearchContainer.contains(e.target)) {
        appSearchResults.classList.remove('show');
    }
});


typeSelect.addEventListener('change', () => {
    const val = typeSelect.value;
    if (val === 'volume_slider' || val === 'brightness_slider') {
        titleGroup.style.display = 'none';
        actionGroup.style.display = 'none';
        iconGroup.style.display = 'none';
        spanSelect.value = "1x4";
        spanSelect.disabled = true;
    } else {
        titleGroup.style.display = 'block';
        actionGroup.style.display = 'block';
        iconGroup.style.display = 'block';
        spanSelect.disabled = false;
        if(spanSelect.value === '1x4' || spanSelect.value === '1x3') spanSelect.value = "1x1";
    }
    spanSelect.dispatchEvent(new Event('change'));
    updatePayloadVisibility();
});

spanSelect.addEventListener('change', () => {
    if (spanSelect.value === 'custom') {
        customSpanInputs.style.display = 'flex';
    } else {
        customSpanInputs.style.display = 'none';
        const parts = spanSelect.value.split('x');
        document.getElementById('edit-span-cols').value = parts[0];
        document.getElementById('edit-span-rows').value = parts[1];
    }
});

function openEditor(idx, dropX = null, dropY = null) {
    if (!isAuthenticated) {
        showAuthModal('Pair with the server before editing the board.');
        return;
    }
    requestSystemApps(); // Pre-fetch apps
    
    const form = document.getElementById('editor-form');
    form.reset();
    showLaunchAppError('');
    customSpanInputs.style.display = 'none';
    spanSelect.disabled = false;
    
    const board = configData.boards[activeBoardIdx];
    document.getElementById('edit-span-cols').max = board.grid_columns || 4;
    document.getElementById('edit-span-rows').max = board.grid_rows || 3;
    
    defaultDropX = dropX;
    defaultDropY = dropY;
    
    if (idx !== null) {
        document.getElementById('modal-title').textContent = "Configure Item";
        const item = board.items[idx];
        document.getElementById('edit-id').value = idx;
        typeSelect.value = item.type || 'button';
        document.getElementById('edit-title').value = item.title || '';
        actionSelect.value = item.action || 'launch_app';
        
        const payloadStr = item.payload || '';
        editPayloadCustom.value = payloadStr;
        editPayloadApp.value = payloadStr;
        appSearchInput.value = payloadStr;
        
        // Set dropdowns if applicable
        if (item.action === 'mpris_action') {
            document.getElementById('edit-payload-media').value = payloadStr;
        } else if (item.action === 'kde_action') {
            document.getElementById('edit-payload-kde').value = payloadStr;
        }
        
        document.getElementById('edit-icon').value = item.icon || '';
        document.getElementById('edit-system-icon-path').value = item.system_icon_path || '';
        
        if (item.icon_base64) {
            iconBase64Input.value = item.icon_base64;
            imagePreview.src = item.icon_base64;
            imagePreviewContainer.style.display = 'block';
        } else {
            iconBase64Input.value = '';
            imagePreview.src = '';
            imagePreviewContainer.style.display = 'none';
            imageUploadInput.value = '';
        }
        
        const cols = item.span_cols || 1;
        const rows = item.span_rows || 1;
        const spanVal = `${cols}x${rows}`;
        
        let matched = false;
        for (let option of spanSelect.options) {
            if (option.value === spanVal) {
                spanSelect.value = spanVal;
                matched = true;
                break;
            }
        }
        if (!matched) {
            spanSelect.value = "custom";
            customSpanInputs.style.display = 'flex';
        }
        
        document.getElementById('edit-span-cols').value = cols;
        document.getElementById('edit-span-rows').value = rows;
        
        document.getElementById('btn-delete').style.display = 'block';
    } else {
        document.getElementById('modal-title').textContent = "Add Item";
        document.getElementById('edit-id').value = '';
        document.getElementById('btn-delete').style.display = 'none';
        typeSelect.value = 'button';
        spanSelect.value = '1x1';
        actionSelect.value = 'launch_app';
        
        iconBase64Input.value = '';
        document.getElementById('edit-system-icon-path').value = '';
        imagePreview.src = '';
        imagePreviewContainer.style.display = 'none';
        imageUploadInput.value = '';
    }
    
    typeSelect.dispatchEvent(new Event('change'));
    updatePayloadVisibility();
    modal.classList.add('show');
}

document.getElementById('editor-form').addEventListener('submit', (e) => {
    e.preventDefault();
    const idx = document.getElementById('edit-id').value;
    const items = configData.boards[activeBoardIdx].items;
    
    let action = actionSelect.value;
    let title = document.getElementById('edit-title').value;
    const type = typeSelect.value;
    
    if (type === 'volume_slider') { action = 'audio_volume'; title = 'Volume'; }
    if (type === 'brightness_slider') { action = 'brightness'; title = 'Brightness'; }

    let payload = '';
    if (action === 'launch_app') {
        payload = editPayloadApp.value;
        if (!payload || !systemApps.some(app => app.payload === payload)) {
            showLaunchAppError(systemAppsLoaded && systemApps.length > 0
                ? 'Select an approved application from the list before saving.'
                : 'No approved application is selected. Configure the local server registry (KDEDECK_APPROVED_APPS) and reload the configurator.');
            return;
        }
    } else if (action === 'mpris_action') {
        payload = document.getElementById('edit-payload-media').value;
    } else if (action === 'kde_action') {
        payload = document.getElementById('edit-payload-kde').value;
    } else {
        payload = editPayloadCustom.value;
    }

    const newItem = {
        id: idx !== '' ? items[parseInt(idx)].id : `item_${Date.now()}`,
        title: title,
        type: type,
        action: action,
        payload: payload,
        icon: document.getElementById('edit-icon').value,
        icon_base64: iconBase64Input.value || null,
        system_icon_path: document.getElementById('edit-system-icon-path').value || null,
        span_cols: parseInt(document.getElementById('edit-span-cols').value) || 1,
        span_rows: parseInt(document.getElementById('edit-span-rows').value) || 1
    };
    
    if (type === 'volume_slider' || type === 'brightness_slider') {
        newItem.span_cols = 1;
        newItem.span_rows = 4;
    }

    if (idx === '') {
        if (defaultDropX !== null && defaultDropY !== null) {
            if (canFit(defaultDropY, defaultDropX, newItem.span_rows, newItem.span_cols, -1)) {
                newItem.grid_x = defaultDropX;
                newItem.grid_y = defaultDropY;
            } else {
                alert("The new size cannot fit in the selected spot! Please choose a smaller size or drag it into an empty space later.");
                return;
            }
        } else {
            // Find empty space
            let placed = false;
            const cols = configData.boards[activeBoardIdx].grid_columns || 4;
            const rows = configData.boards[activeBoardIdx].grid_rows || 3;
            for (let i = 0; i < rows && !placed; i++) {
                for (let j = 0; j < cols && !placed; j++) {
                    if (canFit(i, j, newItem.span_rows, newItem.span_cols, -1)) {
                        newItem.grid_y = i;
                        newItem.grid_x = j;
                        placed = true;
                    }
                }
            }
            if (!placed) {
                alert("Not enough space on the board for this button size!");
                return;
            }
        }
        items.push(newItem);
    } else {
        newItem.grid_x = items[parseInt(idx)].grid_x; 
        newItem.grid_y = items[parseInt(idx)].grid_y;
        
        // Ensure new bounds are valid
        const cols = configData.boards[activeBoardIdx].grid_columns || 4;
        const rows = configData.boards[activeBoardIdx].grid_rows || 3;
        if (!canFit(newItem.grid_y, newItem.grid_x, newItem.span_rows, newItem.span_cols, parseInt(idx))) {
            alert("New size cannot fit in current position without overlapping!");
            return; // Prevent saving if it causes collision
        }
        
        items[parseInt(idx)] = newItem;
    }
    
    markDirty();
    renderGrid();
    modal.classList.remove('show');
});

document.getElementById('btn-delete').addEventListener('click', () => {
    const idx = document.getElementById('edit-id').value;
    if (idx !== '') {
        configData.boards[activeBoardIdx].items.splice(parseInt(idx), 1);
        markDirty();
        renderGrid();
        modal.classList.remove('show');
    }
});
