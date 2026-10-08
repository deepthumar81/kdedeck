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

function hideAuthModal() {
    authModal.classList.remove('show');
    authModal.setAttribute('aria-hidden', 'true');
    authErrorEl.textContent = '';
    pairingCodeInput.value = '';
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
            if (msg.type === 'init_state') requestSystemApps();
        } else if (msg.type === 'system_apps_list') {
            systemApps = msg.apps || [];
            if (modal.classList.contains('show') && document.getElementById('edit-action').value === 'launch_app') {
                // Re-evaluate the custom toggle if it's an existing button
                const payloadStr = editPayloadCustom.value;
                if (payloadStr) {
                    customPayloadToggle.checked = !systemApps.some(app => app.payload === payloadStr);
                }
                updatePayloadVisibility();
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

connectWebSocket();

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

const customPayloadToggle = document.getElementById('custom-payload-toggle');
const appSearchContainer = document.getElementById('app-search-container');
const editPayloadCustom = document.getElementById('edit-payload-custom');
const appSearchInput = document.getElementById('app-search-input');
const appSearchResults = document.getElementById('app-search-results');
const editPayloadApp = document.getElementById('edit-payload-app');

let defaultDropX = null;
let defaultDropY = null;

document.getElementById('add-btn').addEventListener('click', () => openEditor(null));
document.getElementById('btn-cancel').addEventListener('click', () => modal.classList.remove('show'));

function updatePayloadVisibility() {
    const type = typeSelect.value;
    const action = actionSelect.value;
    
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
            document.getElementById('custom-payload-toggle').parentElement.style.display = 'flex';
            editPayloadCustom.placeholder = "e.g. flatpak run org.kde.discover";
            if (customPayloadToggle.checked) {
                appSearchContainer.style.display = 'none';
                editPayloadCustom.style.display = 'block';
            } else {
                appSearchContainer.style.display = 'block';
                editPayloadCustom.style.display = 'none';
            }
        } else if (action === 'mpris_action') {
            document.getElementById('custom-payload-toggle').parentElement.style.display = 'none';
            appSearchContainer.style.display = 'none';
            editPayloadCustom.style.display = 'none';
            document.getElementById('edit-payload-media').style.display = 'block';
        } else if (action === 'kde_action') {
            document.getElementById('custom-payload-toggle').parentElement.style.display = 'none';
            appSearchContainer.style.display = 'none';
            editPayloadCustom.style.display = 'none';
            document.getElementById('edit-payload-kde').style.display = 'block';
        } else {
            // For URLs or custom KDE actions, always show plain text box
            document.getElementById('custom-payload-toggle').parentElement.style.display = 'none';
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

customPayloadToggle.addEventListener('change', () => {
    if (customPayloadToggle.checked) {
        editPayloadCustom.value = editPayloadApp.value;
    }
    updatePayloadVisibility();
});

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
        const message = createTextElement('div', '', '');
        message.appendChild(createTextElement('div', 'app-name', systemApps.length === 0 ? 'Loading apps...' : 'No apps found'));
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
    if (items.length === 0 || (items.length === 1 && systemApps.length === 0)) return; // Loading state
    
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
        
        // Only set to true if apps are loaded and it's genuinely not in the list.
        // If systemApps is empty, default to false and let the onmessage handler fix it later.
        if (systemApps.length > 0) {
            customPayloadToggle.checked = !systemApps.some(app => app.payload === payloadStr);
        } else {
            customPayloadToggle.checked = false;
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
        customPayloadToggle.checked = false;
        
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
        payload = customPayloadToggle.checked ? editPayloadCustom.value : editPayloadApp.value;
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
