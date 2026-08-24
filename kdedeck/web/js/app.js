let ws = null;
let currentConfig = null;
let currentState = { volume: 50, brightness: 70, open_windows: [] };
let activeBoardIndex = 0;
let isEditMode = false;

let touchStartX = 0;
let touchEndX = 0;
let editingItemRef = null;

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

// WebSocket Initialization
function initWebSocket() {
  const protocol = location.protocol === 'https:' ? 'wss:' : 'ws:';
  const wsUrl = `${protocol}//${location.host}/ws`;

  ws = new WebSocket(wsUrl);

  ws.onopen = () => {
    console.log('Connected to KdeDeck Server');
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
    titleBar.innerText = board.title;
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

  if (item.type === 'slider') {
    div.className = `deck-item slider-item ${item.color || 'gradient-blue'}`;
    const currentVal = item.action === 'audio_volume' ? currentState.volume : currentState.brightness;

    div.innerHTML = `
      <div class="item-icon">${getIconSvg(item.icon)}</div>
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
      <div class="item-icon">${getIconSvg(item.icon)}</div>
      <div class="item-label">${item.title}</div>
    `;

    div.onclick = (e) => {
      triggerHaptic();
      if (isEditMode) {
        openEditModal(bIdx, itemIdx);
      } else {
        sendAction(item.action, item.payload);
      }
    };
  }

  return div;
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
      <div class="item-icon">${getIconSvg(win.icon || 'window')}</div>
      <div class="item-label">${win.title}</div>
    `;
    div.onclick = () => {
      triggerHaptic();
      sendAction('focus_window', win.id);
    };
    grid.appendChild(div);
  });
}

function sendAction(action, payload=null, value=null) {
  if (ws && ws.readyState === WebSocket.OPEN) {
    ws.send(JSON.stringify({
      type: 'trigger_action',
      action: action,
      payload: payload,
      value: value
    }));
  }
}

function onSliderInput(e, action, id) {
  const val = e.target.value;
  const label = document.getElementById(`val_${id}`);
  if (label) label.innerText = `${val}%`;
  sendAction(action, null, val);
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
  if (Math.abs(diff) > 50) { // Threshold 50px
    if (diff > 0) {
      // Swiped Left -> Next Board
      if (currentConfig && activeBoardIndex < currentConfig.boards.length - 1) {
        switchBoard(activeBoardIndex + 1);
      }
    } else {
      // Swiped Right -> Prev Board
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

// Edit Mode & Modal
function toggleEditMode() {
  isEditMode = !isEditMode;
  document.getElementById('editBtnText').innerText = isEditMode ? 'Done' : 'Edit';
  document.getElementById('editToggleBtn').style.background = isEditMode ? 'var(--accent)' : '';
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

  if (type === 'launch_app' || type === 'open_url' || type === 'mpris_action' || type === 'kde_action') {
    payloadGroup.style.display = 'flex';
  } else {
    payloadGroup.style.display = 'none';
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

  // Save to server
  if (ws && ws.readyState === WebSocket.OPEN) {
    ws.send(JSON.stringify({
      type: 'save_config',
      config: currentConfig
    }));
  }

  closeModal();
  renderAllBoards();
}

// Start WebSocket on Load
window.onload = () => {
  initWebSocket();
};
