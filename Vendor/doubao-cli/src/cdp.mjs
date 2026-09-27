import { currentApp, resolveApp, isAppTarget } from './app.mjs';

export function cdpEndpoint(env) {
  return env ? resolveApp(undefined, env).endpoint : currentApp().endpoint;
}

async function fetchJson(url, timeoutMs = 3000) {
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), timeoutMs);
  try {
    const response = await fetch(url, { signal: controller.signal });
    if (!response.ok) throw new Error(`HTTP ${response.status}`);
    return await response.json();
  } finally {
    clearTimeout(timer);
  }
}

export async function cdpStatus(endpoint = cdpEndpoint()) {
  try {
    const version = await fetchJson(`${endpoint}/json/version`);
    const targets = await fetchJson(`${endpoint}/json/list`);
    if (!targets.some((target) => isAppTarget(target.url) || isAppTarget(target.url, currentApp(), 'background'))) {
      return { available: false, endpoint, identityMismatch: true, error: `CDP endpoint ${endpoint} does not belong to ${currentApp().name}; select the correct --app or endpoint` };
    }
    return { app: currentApp().id, available: true, endpoint, browser: version.Browser, protocolVersion: version['Protocol-Version'] };
  } catch (error) {
    return { available: false, endpoint, error: error.message };
  }
}

export async function findChatTarget(endpoint = cdpEndpoint(), timeoutMs = 5000) {
  const deadline = Date.now() + timeoutMs;
  do {
    const targets = await fetchJson(`${endpoint}/json/list`);
    const target = targets.find(
      (item) => item.type === 'page' && isAppTarget(item.url),
    );
    if (target?.webSocketDebuggerUrl) return target;
    await new Promise((resolve) => setTimeout(resolve, 100));
  } while (Date.now() < deadline);
  throw new Error(`no Doubao chat page found at ${endpoint}; open a chat window in ${currentApp().name} explicitly, then retry`);
}

// The background page hosts the local-tool dispatch (connector.call routing).
export async function findBackgroundTarget(endpoint = cdpEndpoint(), timeoutMs = 5000) {
  const deadline = Date.now() + timeoutMs;
  do {
    const targets = await fetchJson(`${endpoint}/json/list`);
    const target = targets.find(
      (item) => item.type === 'page' && isAppTarget(item.url, currentApp(), 'background'),
    );
    if (target?.webSocketDebuggerUrl) return target;
    await new Promise((resolve) => setTimeout(resolve, 100));
  } while (Date.now() < deadline);
  throw new Error(`no Doubao background page found at ${endpoint}`);
}

export class CdpClient {
  constructor(webSocketUrl) {
    this.webSocketUrl = webSocketUrl;
    this.nextId = 1;
    this.pending = new Map();
    this.socket = null;
    this.listeners = new Map();
  }

  async connect() {
    this.socket = new WebSocket(this.webSocketUrl);
    await new Promise((resolve, reject) => {
      this.socket.addEventListener('open', resolve, { once: true });
      this.socket.addEventListener('error', () => reject(new Error('CDP WebSocket connection failed')), { once: true });
    });
    this.socket.addEventListener('message', (event) => {
      const message = JSON.parse(String(event.data));
      if (!message.id) {
        for (const callback of this.listeners.get(message.method) || []) callback(message.params);
        return;
      }
      const pending = this.pending.get(message.id);
      if (!pending) return;
      this.pending.delete(message.id);
      if (message.error) pending.reject(new Error(message.error.message));
      else pending.resolve(message.result);
    });
    this.socket.addEventListener('close', () => {
      for (const pending of this.pending.values()) pending.reject(new Error('CDP WebSocket closed'));
      this.pending.clear();
    });
    return this;
  }

  send(method, params = {}) {
    if (!this.socket || this.socket.readyState !== WebSocket.OPEN) throw new Error('CDP client is not connected');
    const id = this.nextId;
    this.nextId += 1;
    const promise = new Promise((resolve, reject) => this.pending.set(id, { resolve, reject }));
    this.socket.send(JSON.stringify({ id, method, params }));
    return promise;
  }

  subscribe(event, callback) {
    const callbacks = this.listeners.get(event) || new Set();
    callbacks.add(callback); this.listeners.set(event, callbacks);
    return () => callbacks.delete(callback);
  }

  async evaluate(expression) {
    const result = await this.send('Runtime.evaluate', {
      expression,
      awaitPromise: true,
      returnByValue: true,
      userGesture: true,
    });
    if (result.exceptionDetails) {
      throw new Error(result.exceptionDetails.exception?.description || result.exceptionDetails.text || 'JavaScript evaluation failed');
    }
    return result.result?.value;
  }

  async click(selector) {
    const point = await this.evaluate(`(() => {
      const element = [...document.querySelectorAll(${JSON.stringify(selector)})].find(item => {
        const rect = item.getBoundingClientRect();
        return rect.width > 0 && rect.height > 0 && getComputedStyle(item).visibility !== 'hidden';
      });
      if (!element) throw new Error('click target was not found');
      element.scrollIntoView({ block: 'center', inline: 'center' });
      const rect = element.getBoundingClientRect();
      if (!rect.width || !rect.height) throw new Error('click target is not visible');
      return { x: rect.left + rect.width / 2, y: rect.top + rect.height / 2 };
    })()`);
    await this.send('Input.dispatchMouseEvent', {
      type: 'mousePressed',
      x: point.x,
      y: point.y,
      button: 'left',
      clickCount: 1,
    });
    await this.send('Input.dispatchMouseEvent', {
      type: 'mouseReleased',
      x: point.x,
      y: point.y,
      button: 'left',
      clickCount: 1,
    });
  }

  async pressEscape() {
    await this.send('Input.dispatchKeyEvent', {
      type: 'rawKeyDown',
      key: 'Escape',
      code: 'Escape',
      windowsVirtualKeyCode: 27,
      nativeVirtualKeyCode: 53,
    });
    await this.send('Input.dispatchKeyEvent', {
      type: 'keyUp',
      key: 'Escape',
      code: 'Escape',
      windowsVirtualKeyCode: 27,
      nativeVirtualKeyCode: 53,
    });
  }

  close() {
    this.socket?.close();
  }
}

export async function withChatClient(callback, endpoint = cdpEndpoint()) {
  const status = await cdpStatus(endpoint);
  if (!status.available) {
    throw new Error(status.error && status.identityMismatch ? status.error : `${currentApp().name} CDP is unavailable at ${endpoint}. Run "doubao --app ${currentApp().id} cdp launch" to enable CDP.`);
  }
  const target = await findChatTarget(endpoint);
  const client = await new CdpClient(target.webSocketDebuggerUrl).connect();
  try {
    return await callback(client, target);
  } finally {
    client.close();
  }
}

export async function withBackgroundClient(callback, endpoint = cdpEndpoint()) {
  const status = await cdpStatus(endpoint);
  if (!status.available) {
    throw new Error(status.error && status.identityMismatch ? status.error : `${currentApp().name} CDP is unavailable at ${endpoint}. Run "doubao --app ${currentApp().id} cdp launch" to enable CDP.`);
  }
  const target = await findBackgroundTarget(endpoint);
  const client = await new CdpClient(target.webSocketDebuggerUrl).connect();
  try {
    return await callback(client, target);
  } finally {
    client.close();
  }
}
