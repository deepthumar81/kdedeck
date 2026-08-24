let ws = null;
let currentConfig = null;
let currentState = { volume: 50, brightness: 70, open_windows: [] };
let activeBoardIndex = 0;
let isEditMode = false;
let installedAppsCache = [];

let touchStartX = 0;
let touchEndX = 0;
let editingItemRef = null;
let sliderDebounceTimers = {};

// Register Service Worker for PWA
if ('serviceWorker' in navigator) {
  navigator.serviceWorker.register('/sw.js').catch(err => console.log('SW reg error:', err));
}

// Themes list
const THEMES = ['theme-breeze-dark', 'theme-cyberpunk', 'theme-oled', 'theme-sunset'];
let currentThemeIdx = 0;

function cycleTheme() {
  document.body.classList.remove(THEMES[currentThemeIdx]);
  currentThemeIdx = (currentThemeIdx + 1) % THEMES.length;
  document.body.classList.add(THEMES[currentThemeIdx]);
}

// Toast Notifications
function showToast(message, type = 'error') {
  const container = document.getElementById('toastContainer');
  if (!container) return;

  const toast = document.createElement('div');
  toast.className = `toast ${type}`;
  toast.innerHTML = `<span>⚠️ ${message}</span>`;
  container.appendChild(toast);

  setTimeout(() => {
    toast.remove();
  }, 4000);
}

// WebSocket Initialization
function initWebSocket() {
  const protocol = location.protocol === 'https:' ? 'wss:' : 'ws:';
  const wsUrl = `${protocol}//${location.host}/ws`;

  ws = new WebSocket(wsUrl);

  ws.onopen = () => {
    console.log('Connected to KdeDeck Server');
    // Send stored token if available
    const savedToken = localStorage.getItem('kdedeck_token');
    if (savedToken) {
      ws.send(JSON.stringify({ type: 'authenticate', token: savedToken }));
    }
  };

  ws.onmessage = (event) => {
    try {
      const data = JSON.parse(event.data);
      handleServerMessage(data);
    } catch (e) {
      console.error('Error parsing WS message:', e);
    }
  };

  ws.onclose = () => {
    console.warn('WebSocket closed. Reconnecting in 2 seconds...');
    setTimeout(initWebSocket, 2000);
  };
}

function triggerHaptic() {
  if ('vibrate' in navigator) {
    navigator.vibrate(35);
  }
}

function handleServerMessage(data) {
  if (data.type === 'init_state' || data.type === 'config_updated') {
    currentConfig = data.config;
    if (data.state) currentState = { ...currentState, ...data.state };
    renderAllBoards();

    // Check PIN requirement
    const savedToken = localStorage.getItem('kdedeck_token');
    if (data.pin_required && !savedToken) {
      document.getElementById('pinModal').classList.add('active');
    }
  } else if (data.type === 'auth_success') {
    localStorage.setItem('kdedeck_token', data.token);
    document.getElementById('pinModal').classList.remove('active');
  } else if (data.type === 'auth_error') {
    showToast(data.message || 'Invalid PIN', 'error');
  } else if (data.type === 'action_warning' || data.type === 'action_error') {
    showToast(data.message, data.type === 'action_warning' ? 'warning' : 'error');
    if (data.item_id) {
      markItemError(data.item_id);
    }
  } else if (data.type === 'state_update') {
    currentState[data.key] = data.value;
    updateSliderUI(data.key, data.value);
  } else if (data.type === 'state_poll') {
    if (data.state) {
      currentState = { ...currentState, ...data.state };
      updateSliderUI('volume', currentState.volume);
      updateSliderUI('brightness', currentState.brightness);
      renderTaskbarBoard();
    }
  } else if (data.type === 'taskbar_update') {
    currentState.open_windows = data.windows;
    renderTaskbarBoard();
  }
}

function submitPinAuth() {
  const pin = document.getElementById('inputPin').value;
  if (ws && ws.readyState === WebSocket.OPEN) {
    ws.send(JSON.stringify({ type: 'authenticate', pin: pin }));
  }
}

function markItemError(itemId) {
  const itemEl = document.getElementById(`item_${itemId}`);
  if (itemEl && !itemEl.querySelector('.error-badge')) {
    const badge = document.createElement('div');
    badge.className = 'error-badge';
    badge.innerText = '!';
    itemEl.appendChild(badge);
    setTimeout(() => badge.remove(), 4000);
  }
}

function renderAllBoards() {
  if (!currentConfig || !currentConfig.boards) return;

  const container = document.getElementById('boardsContainer');
  const dotsContainer = document.getElementById('pageDots');

  container.innerHTML = '';
  dotsContainer.innerHTML = '';

  currentConfig.boards.forEach((board, bIdx) => {
    // Render Dot Indicator
    const dot = document.createElement('div');
    dot.className = `dot ${bIdx === activeBoardIndex ? 'active' : ''}`;
    dot.onclick = () => switchBoard(bIdx);
    dotsContainer.appendChild(dot);

    // Render Board Page
    const page = document.createElement('div');
    page.className = 'board-page';

    const titleBar = document.createElement('div');
    titleBar.className = 'board-title-bar';
    titleBar.innerHTML = `<span>${board.title}</span>`;

    if (isEditMode) {
      const delBoardBtn = document.createElement('button');
      delBoardBtn.className = 'action-btn';
      delBoardBtn.style.padding = '2px 8px';
      delBoardBtn.style.fontSize = '0.75rem';
      delBoardBtn.innerText = 'Delete Board';
      delBoardBtn.onclick = () => deleteBoard(bIdx);
      titleBar.appendChild(delBoardBtn);
    }

    page.appendChild(titleBar);

    const grid = document.createElement('div');
    grid.className = 'deck-grid';

    if (board.dynamic === 'kwin_active_apps') {
      grid.id = 'taskbarGrid';
      renderTaskbarItems(grid);
    } else {
      board.items.forEach((item, itemIdx) => {
        const el = createDeckItemElement(item, bIdx, itemIdx);
        grid.appendChild(el);
      });
    }

    page.appendChild(grid);
    container.appendChild(page);
  });

  updateBoardTransform();
}

function createDeckItemElement(item, bIdx, itemIdx) {
  const div = document.createElement('div');
  div.id = `item_${item.id || itemIdx}`;

  if (item.type === 'slider') {
    div.className = `deck-item slider-item ${item.color || 'gradient-blue'}`;
    const currentVal = item.action === 'audio_volume' ? currentState.volume : currentState.brightness;

    div.innerHTML = `
      <div class="item-icon">${renderIconHTML(item.icon)}</div>
      <div class="slider-container">
        <div class="slider-header">
          <span>${item.title}</span>
          <span id="val_${item.id}">${currentVal}%</span>
        </div>
        <input type="range" class="range-slider" id="input_${item.id}" min="0" max="100" value="${currentVal}"
          oninput="onSliderInput(event, '${item.action}', '${item.id}')">
      </div>
    `;
  } else {
    div.className = `deck-item ${item.color || 'gradient-blue'}`;
    div.innerHTML = `
      <div class="item-icon">${renderIconHTML(item.icon)}</div>
      <div class="item-label">${item.title}</div>
    `;

    div.onclick = (e) => {
      triggerHaptic();
      if (isEditMode) {
        openEditModal(bIdx, itemIdx);
      } else {
        sendAction(item.action, item.payload, null, item.id);
      }
    };
  }

  return div;
}

function renderIconHTML(iconName) {
  if (!iconName) return getIconSvg('box');
  // Check if system icon exists via API image or SVG fallback
  if (ICONS[iconName]) {
    return ICONS[iconName];
  }
  return `<img src="/api/icon/${encodeURIComponent(iconName)}" class="app-icon-img" onerror="this.onerror=null; this.outerHTML=\`${getIconSvg('box')}\`;">`;
}

function renderTaskbarBoard() {
  const grid = document.getElementById('taskbarGrid');
  if (grid) renderTaskbarItems(grid);
}

function renderTaskbarItems(grid) {
  grid.innerHTML = '';
  if (!currentState.open_windows || currentState.open_windows.length === 0) {
    grid.innerHTML = `<div style="grid-column: span 4; text-align: center; color: var(--text-muted); padding: 40px;">No Active Windows</div>`;
    return;
  }

  currentState.open_windows.forEach(win => {
    const div = document.createElement('div');
    div.className = 'deck-item gradient-indigo';
    div.innerHTML = `
      <div class="item-icon">${renderIconHTML(win.icon)}</div>
      <div class="item-label">${win.title}</div>
    `;
    div.onclick = () => {
      triggerHaptic();
      sendAction('focus_window', win.id);
    };
    grid.appendChild(div);
  });
}

function sendAction(action, payload=null, value=null, itemId=null) {
  if (ws && ws.readyState === WebSocket.OPEN) {
    ws.send(JSON.stringify({
      type: 'trigger_action',
      action: action,
      payload: payload,
      value: value,
      item_id: itemId
    }));
  }
}

// 150ms Client-Side Slider Debouncing
function onSliderInput(e, action, id) {
  const val = e.target.value;
  const label = document.getElementById(`val_${id}`);
  if (label) label.innerText = `${val}%`;

  if (sliderDebounceTimers[id]) {
    clearTimeout(sliderDebounceTimers[id]);
  }

  sliderDebounceTimers[id] = setTimeout(() => {
    sendAction(action, null, val, id);
  }, 150);
}

function updateSliderUI(key, val) {
  const sliders = document.querySelectorAll('.range-slider');
  sliders.forEach(slider => {
    if (key === 'volume' && slider.oninput.toString().includes('audio_volume')) {
      slider.value = val;
      const label = slider.parentElement.querySelector('span:last-child');
      if (label) label.innerText = `${val}%`;
    } else if (key === 'brightness' && slider.oninput.toString().includes('brightness')) {
      slider.value = val;
      const label = slider.parentElement.querySelector('span:last-child');
      if (label) label.innerText = `${val}%`;
    }
  });
}

// Touch Swipe Navigation
const mainContainer = document.getElementById('mainContainer');

mainContainer.addEventListener('touchstart', e => {
  touchStartX = e.changedTouches[0].screenX;
}, false);

mainContainer.addEventListener('touchend', e => {
  touchEndX = e.changedTouches[0].screenX;
  handleSwipe();
}, false);

function handleSwipe() {
  const diff = touchStartX - touchEndX;
  if (Math.abs(diff) > 50) {
    if (diff > 0) {
      if (currentConfig && activeBoardIndex < currentConfig.boards.length - 1) {
        switchBoard(activeBoardIndex + 1);
      }
    } else {
      if (activeBoardIndex > 0) {
        switchBoard(activeBoardIndex - 1);
      }
    }
  }
}

function switchBoard(idx) {
  triggerHaptic();
  activeBoardIndex = idx;
  updateBoardTransform();

  const dots = document.querySelectorAll('.dot');
  dots.forEach((dot, i) => {
    if (i === idx) dot.classList.add('active');
    else dot.classList.remove('active');
  });
}

function updateBoardTransform() {
  const container = document.getElementById('boardsContainer');
  if (container) {
    container.style.transform = `translateX(-${activeBoardIndex * 100}%)`;
  }
}

// Edit Mode & System Apps Fetching
function toggleEditMode() {
  isEditMode = !isEditMode;
  document.getElementById('editBtnText').innerText = isEditMode ? 'Done' : 'Edit';
  document.getElementById('editToggleBtn').classList.toggle('active', isEditMode);

  document.getElementById('addBtnControl').style.display = isEditMode ? 'block' : 'none';
  document.getElementById('addBoardControl').style.display = isEditMode ? 'block' : 'none';

  if (isEditMode && installedAppsCache.length === 0) {
    fetchInstalledApps();
  }

  renderAllBoards();
}

function fetchInstalledApps() {
  fetch('/api/apps')
    .then(res => res.json())
    .then(data => {
      if (data.apps) {
        installedAppsCache = data.apps;
        populateAppPickerDropdown();
      }
    })
    .catch(err => console.error('Error fetching system apps:', err));
}

function populateAppPickerDropdown() {
  const picker = document.getElementById('systemAppPicker');
  if (!picker) return;
  picker.innerHTML = `<option value="">-- Choose Installed Application --</option>`;

  installedAppsCache.forEach(app => {
    const opt = document.createElement('option');
    opt.value = app.exec;
    opt.dataset.name = app.name;
    opt.dataset.icon = app.icon;
    opt.innerText = `${app.name} (${app.exec})`;
    picker.appendChild(opt);
  });
}

function onSystemAppPick() {
  const picker = document.getElementById('systemAppPicker');
  const selectedOpt = picker.options[picker.selectedIndex];
  if (!selectedOpt || !selectedOpt.value) return;

  document.getElementById('editLabel').value = selectedOpt.dataset.name || '';
  document.getElementById('editActionType').value = 'launch_app';
  document.getElementById('editPayload').value = selectedOpt.value;
  document.getElementById('editIcon').value = selectedOpt.dataset.icon || 'terminal';
  onActionTypeChange();
}

function addNewItemToBoard() {
  if (!currentConfig || !currentConfig.boards[activeBoardIndex]) return;
  const newItem = {
    type: 'button',
    id: `item_${Date.now()}`,
    title: 'New Button',
    action: 'launch_app',
    payload: 'konsole',
    icon: 'terminal',
    color: 'gradient-blue'
  };

  currentConfig.boards[activeBoardIndex].items.push(newItem);
  saveConfigToServer();
  renderAllBoards();
}

function addNewBoard() {
  if (!currentConfig) return;
  const newBoard = {
    id: `board_${Date.now()}`,
    title: `Board ${currentConfig.boards.length + 1}`,
    icon: 'layers',
    items: []
  };

  currentConfig.boards.push(newBoard);
  saveConfigToServer();
  switchBoard(currentConfig.boards.length - 1);
  renderAllBoards();
}

function deleteBoard(bIdx) {
  if (!currentConfig || currentConfig.boards.length <= 1) {
    showToast('Cannot delete the last board', 'warning');
    return;
  }

  currentConfig.boards.splice(bIdx, 1);
  saveConfigToServer();
  activeBoardIndex = Math.max(0, activeBoardIndex - 1);
  renderAllBoards();
}

function openEditModal(bIdx, itemIdx) {
  editingItemRef = { bIdx, itemIdx };
  const item = currentConfig.boards[bIdx].items[itemIdx];

  document.getElementById('editLabel').value = item.title || '';
  document.getElementById('editActionType').value = item.action || 'launch_app';
  document.getElementById('editPayload').value = item.payload || '';
  document.getElementById('editIcon').value = item.icon || 'terminal';
  document.getElementById('editColor').value = item.color || 'gradient-blue';

  onActionTypeChange();
  document.getElementById('editorModal').classList.add('active');
}

function closeModal() {
  document.getElementById('editorModal').classList.remove('active');
}

function onActionTypeChange() {
  const type = document.getElementById('editActionType').value;
  const payloadGroup = document.getElementById('payloadGroup');
  const kdePresetGroup = document.getElementById('kdeActionPresetGroup');

  if (type === 'launch_app' || type === 'open_url' || type === 'mpris_action') {
    payloadGroup.style.display = 'flex';
    kdePresetGroup.style.display = 'none';
  } else if (type === 'kde_action') {
    payloadGroup.style.display = 'flex';
    kdePresetGroup.style.display = 'flex';
  } else {
    payloadGroup.style.display = 'none';
    kdePresetGroup.style.display = 'none';
  }
}

function saveItemChanges() {
  if (!editingItemRef) return;
  const { bIdx, itemIdx } = editingItemRef;
  const item = currentConfig.boards[bIdx].items[itemIdx];

  item.title = document.getElementById('editLabel').value;
  item.action = document.getElementById('editActionType').value;
  item.payload = document.getElementById('editPayload').value;
  item.icon = document.getElementById('editIcon').value;
  item.color = document.getElementById('editColor').value;

  saveConfigToServer();
  closeModal();
  renderAllBoards();
}

function deleteCurrentItem() {
  if (!editingItemRef) return;
  const { bIdx, itemIdx } = editingItemRef;
  currentConfig.boards[bIdx].items.splice(itemIdx, 1);
  saveConfigToServer();
  closeModal();
  renderAllBoards();
}

function saveConfigToServer() {
  if (ws && ws.readyState === WebSocket.OPEN) {
    ws.send(JSON.stringify({
      type: 'save_config',
      config: currentConfig
    }));
  }
}

// Start WebSocket on Load
window.onload = () => {
  initWebSocket();
};
