import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { createHash } from 'node:crypto';
import { currentApp, activeProfile } from './app.mjs';
import { runtimeParameters, evaluateWithWatchdog, updateLiveControls, sendChatCompletion } from './protocol.mjs';

export async function imRequest(client, route, cmd, key, body, timeoutMs = 10000) {
  const { query } = await runtimeParameters(client);
  return evaluateWithWatchdog(client, `(async () => {
    const response = await fetch(${JSON.stringify('https://www.doubao.com/im/' + route + '?' + query)}, {
      method: 'POST', credentials: 'include', headers: { 'content-type': 'application/json; encoding=utf-8' },
      signal: AbortSignal.timeout(${Math.max(1, timeoutMs)}),
      body: JSON.stringify({ cmd: ${cmd}, uplink_body: { [${JSON.stringify(key)}]: ${JSON.stringify(body)} },
        sequence_id: crypto.randomUUID(), channel: 2, version: '1' }),
    });
    if (!response.ok) throw new Error('Doubao task lookup failed: HTTP ' + response.status);
    const result = await response.json();
    if (result.status_code) throw new Error('Doubao task lookup failed: ' + result.status_desc);
    return result.downlink_body;
  })()`, timeoutMs + 1000);
}

const parse = value => { try { return typeof value === 'string' ? JSON.parse(value) : value || {}; } catch { return {}; } };
const ordered = messages => messages.slice().sort((a, b) => {
  const left = BigInt(a.index_in_conv || a.index_in_thread || a.message_id || 0);
  const right = BigInt(b.index_in_conv || b.index_in_thread || b.message_id || 0);
  return left < right ? -1 : left > right ? 1 : 0;
});
export function messageBlocks(message) {
  const blocks = message.content_blocks_v2 || message.content_block || parse(message.content);
  return Array.isArray(blocks) ? blocks : [];
}
export function messageText(message) {
  const blocks = messageBlocks(message);
  if (!Array.isArray(blocks)) return '';
  return blocks.filter(block => !block.control_info?.collapse_block_id)
    .map(block => block.content?.text_block?.text || '').filter(Boolean).join('\n').trim();
}
export function taskLinks(messages) {
  const links = new Map();
  for (const message of messages) for (const block of messageBlocks(message)) {
    const task = block.content?.complex_task_block || block.content?.task_card_block;
    if (task?.thread_id) links.set(String(task.thread_id), {
      threadId: String(task.thread_id), title: task.title || task.header?.name || '',
      type: task.display_type || 'organizer', sourceMessageId: message.message_id,
    });
  }
  return [...links.values()];
}
function artifacts(messages) {
  const result = new Map();
  for (const message of messages) for (const block of messageBlocks(message)) {
    for (const type of ['artifact_block', 'file_block', 'local_file_block', 'artifact_code_file_block', 'creation_block']) {
      const value = block.content?.[type];
      if (value) result.set(block.block_id, { blockId: block.block_id, type, content: value });
    }
  }
  return [...result.values()];
}
function pendingInputs(messages, threadId) {
  const blocks = new Map();
  for (const message of ordered(messages)) for (const block of messageBlocks(message)) {
    blocks.set(block.block_id || message.message_id, { message, block });
  }
  return [...blocks.values()].flatMap(({ message, block }) => {
    const base = { ...(threadId ? { threadId } : {}), messageId: message.message_id, blockId: block.block_id };
    const ask = block.content?.interaction_ask_block;
    if (ask?.status === 1 && ask.quick_reply_scene !== 11) return [{ ...base,
      kind: 'input', questions: ask.questions || [], clarifyId: ask.clarify_id }];
    const quick = block.content?.quick_reply_block;
    // Ordinary reply suggestions are not blocking interactions. These scenes
    // are the app's ask-human, local-app and authorization controls.
    if (quick?.status === 1 && [2, 7, 8, 9, 10, 12].includes(quick.scene)) return [{ ...base,
      kind: 'approval', scene: quick.scene, items: quick.items || [] }];
    return [];
  });
}
function mergeControlBlocks(stored, live) {
  const terminal = ['completed', 'failed', 'cancelled'].includes(messageState(stored));
  const blocks = new Map(messageBlocks(stored).map(block => [block.block_id, block]));
  for (const block of messageBlocks(live)) {
    const previous = blocks.get(block.block_id);
    const ask = previous?.content?.interaction_ask_block;
    const quick = previous?.content?.quick_reply_block;
    if (ask && [2,3].includes(ask.status) || quick?.status === 2) continue;
    if (!terminal || !previous && [10070,10090].includes(block.block_type)) blocks.set(block.block_id, block);
  }
  stored.content_block = [...blocks.values()]; delete stored.content_blocks_v2;
}

export function messageState(message) {
  if (!message) return 'running';
  const job = parse(message.ext?.async_job);
  if (message.ext?.is_interrupted === 'true' || message.content_status === 120 || job.status === 4) return 'cancelled';
  if (message.content_status === 500 || job.status === 3 || message.ext?.error_details) return 'failed';
  if (job.status === 1 || [100, 101, 110].includes(message.content_status)) return 'running';
  if (job.status === 2 || message.ext?.is_finish === '1') return 'completed';
  return 'unknown';
}
export function summarizeTurn(conversationId, root, messages, nodes, receipt = {}) {
  const runMessages = ordered(messages.filter(m => m.user_type === 2 &&
    String(m.bot_reply_message_id || m.ext?.chat_id) === String(root.message_id) && (!m.status || m.status === 0)));
  const latest = runMessages.at(-1);
  let pending = [...pendingInputs(runMessages), ...nodes.filter(n => !['failed','cancelled'].includes(n.status)).flatMap(n => pendingInputs(n.messages, n.threadId))];
  const tasks = { total: nodes.length, running: 0, completed: 0, failed: 0, cancelled: 0, unknown: 0 };
  for (const node of nodes) tasks[node.status in tasks ? node.status : 'unknown']++;
  let status = messageState(latest);
  if (tasks.running || tasks.unknown || receipt.handoffs?.some(task => !task.completed) && !nodes.length) status = 'running';
  else if (status !== 'cancelled' && tasks.failed) status = 'failed';
  else if (status !== 'failed' && tasks.cancelled) status = 'cancelled';
  // A sync reply may finish while its organizer is still producing the final main-chat summary.
  const firstDelegation = runMessages.find(m => taskLinks([m]).length);
  if (status === 'completed' && nodes.length && latest?.message_id === firstDelegation?.message_id) status = 'running';
  if (receipt.cancellation?.confirmed && !tasks.running && !tasks.unknown || receipt.cancellation?.accepted && status === 'completed') status = 'cancelled';
  if (pending.length && !['failed', 'cancelled'].includes(status)) status = 'waiting_input';
  if (['cancelled', 'failed'].includes(status)) pending = [];
  const reply = status === 'completed' ? { role: 'assistant', text: messageText(latest), messageId: latest?.message_id } : null;
  return { conversationId, runId: String(root.message_id), localMessageId: root.local_message_id || receipt.localMessageId,
    status, reply, artifacts: artifacts([...runMessages, ...nodes.flatMap(n => n.messages)]), tasks, pending,
    ...(status !== 'completed' && latest ? { progress: messageText(latest) } : {}) };
}

const remaining = deadline => Math.max(1, Math.min(10000, deadline ? deadline - Date.now() : 10000));

async function conversationMessages(client, conversationId, deadline) {
  const body = await imRequest(client, 'conversation/batch_get', 1111, 'batch_get_conv_info_uplink_body', {
    conversation_id: [conversationId], option: { recent_message_count_per_conv: 100 }, ext: {},
  }, remaining(deadline));
  const conversation = body?.batch_get_conv_info_downlink_body?.conversation_info_list?.find(c => c.conversation_id === conversationId);
  if (!conversation) throw Object.assign(new Error('Doubao conversation was not found'), { code: 'turn_unavailable' });
  return conversation;
}
export async function readTurn(client, conversationId, { runId, localMessageId, receipt = {}, deadline } = {}) {
  const conversation = await conversationMessages(client, conversationId, deadline);
  const messages = ordered(conversation.messages || []);
  const live = receipt.liveMessages || [];
  const requested = runId || receipt.runId;
  localMessageId ||= receipt.localMessageId;
  const root = requested ? messages.find(m => m.user_type === 1 && String(m.message_id) === requested)
    : localMessageId ? messages.find(m => m.user_type === 1 && m.local_message_id === localMessageId)
      : messages.filter(m => m.user_type === 1).at(-1);
  if (!root) throw Object.assign(new Error(requested || localMessageId ? 'The requested turn is not in the available conversation history; no other turn was selected' : 'Conversation has no submitted turn'), { code: 'turn_unavailable' });
  const own = messages.filter(m => m.user_type === 2 && String(m.bot_reply_message_id || m.ext?.chat_id) === String(root.message_id));
  // Live task cards can precede the stored history by the entire task duration.
  // Merge control blocks only; persisted terminal messages always win.
  for (const message of live) {
    if (message.thread_id && message.thread_id !== '0') continue;
    const stored = own.find(item => item.message_id === message.message_id);
    if (!stored) {
      const item = { ...message, bot_reply_message_id: root.message_id, content_status: 100 };
      messages.push(item); own.push(item);
    }
    if (stored) mergeControlBlocks(stored, message);
  }
  const queue = taskLinks(own), seen = new Set(), nodes = [];
  for (const link of queue) {
    if (seen.has(link.threadId)) continue;
    if (seen.size >= 100) throw new Error('Task tree exceeds 100 threads; completion cannot be confirmed');
    seen.add(link.threadId);
    const info = (await imRequest(client, 'thread/info', 3400, 'get_thread_info_uplink_body', { thread_id: link.threadId }, remaining(deadline)))?.get_thread_info_downlink_body?.thread_info;
    if (!info || info.source_conversation_id !== conversationId) throw new Error('Task thread does not belong to this conversation');
    const threadMessages = []; let cursor = 0;
    for (let page = 0; page < 20; page++) {
      const data = (await imRequest(client, 'chain/thread_message', 3102, 'pull_thread_message_chain_uplink_body', {
        thread_id: link.threadId, limit: 100, direction: cursor ? 1 : 3, anchor_index: cursor, ext: {},
      }, remaining(deadline)))?.pull_thread_message_chain_downlink_body;
      if (!data) throw new Error('Task thread messages are unavailable');
      threadMessages.push(...data.messages || []);
      if (!data.has_more) break;
      if (!data.next_index || String(data.next_index) === String(cursor) || page === 19) throw new Error('Task thread history is incomplete');
      cursor = data.next_index;
    }
    for (const message of live.filter(item => item.thread_id === link.threadId)) {
      const stored = threadMessages.find(item => item.message_id === message.message_id);
      if (stored) mergeControlBlocks(stored, message);
      else threadMessages.push(message);
    }
    const latest = ordered(threadMessages).filter(m => m.user_type === 2).at(-1);
    const rawStatus = info.ext?.thread_status;
    const status = ['running', 'completed', 'failed', 'cancelled'].includes(rawStatus) ? rawStatus
      : rawStatus === 'canceled' ? 'cancelled' : messageState(latest);
    const children = taskLinks(threadMessages);
    nodes.push({ ...link, status, messages: threadMessages, children: children.map(c => c.threadId), job: parse(latest?.ext?.async_job) });
    queue.push(...children);
  }
  return { result: summarizeTurn(conversationId, root, messages, nodes, receipt), root, messages: own, nodes, conversation };
}

export async function receiptStore(client) {
  const uid = await client.evaluate('localStorage.getItem("flow_tea_user_id")');
  if (!uid || uid === '0') throw new Error('Sign in to the selected Doubao app');
  const app = currentApp();
  const scope = createHash('sha256').update(JSON.stringify([app.id, path.resolve(app.dataDir), activeProfile(app), uid])).digest('hex').slice(0, 24);
  const dir = path.join(process.env.DOUBAO_CLI_CONFIG_DIR || path.join(os.homedir(), 'Library/Application Support/doubao-cli'), 'turns', scope);
  const validate = id => { if (!/^\d{12,24}$/u.test(id || '')) throw new Error('Invalid run id'); return id; };
  return {
    save(receipt) {
      if (!receipt.conversationId || !receipt.runId) return;
      const name = `${validate(receipt.conversationId)}-${validate(receipt.runId)}.json`;
      fs.mkdirSync(dir, { recursive: true, mode: 0o700 });
      const file = path.join(dir, name), tmp = file + '.' + crypto.randomUUID() + '.tmp';
      let previous = {};
      try { previous = JSON.parse(fs.readFileSync(file, 'utf8')); } catch (error) { if (error.code !== 'ENOENT') throw error; }
      // A concurrent wait must not erase an explicit cancellation or move
      // reconnect cursors backwards when it checkpoints an older snapshot.
      const handoffs = new Map((previous.handoffs || []).map(task => [task.taskId, task]));
      for (const task of receipt.handoffs || []) {
        const old = handoffs.get(task.taskId) || {};
        handoffs.set(task.taskId, { ...old, ...task, seq: Math.max(old.seq || 0, task.seq || 0), completed: old.completed || task.completed });
      }
      const cancellationFile = file + '.cancellation';
      let cancellation = {};
      try { cancellation = JSON.parse(fs.readFileSync(cancellationFile, 'utf8')); }
      catch (error) { if (error.code !== 'ENOENT') throw error; }
      if (receipt.cancellation?.requestedAt) {
        cancellation = { ...cancellation, ...receipt.cancellation,
          accepted: cancellation.accepted || receipt.cancellation.accepted,
          confirmed: cancellation.confirmed || receipt.cancellation.confirmed };
        const pending = cancellationFile + '.' + crypto.randomUUID() + '.tmp';
        fs.writeFileSync(pending, JSON.stringify(cancellation), { mode: 0o600 }); fs.renameSync(pending, cancellationFile);
      }
      const value = { ...receipt, handoffs: [...handoffs.values()], cancellation };
      fs.writeFileSync(tmp, JSON.stringify(value), { mode: 0o600 }); fs.renameSync(tmp, file);
    },
    read(conversationId, runId) {
      try {
        const file = path.join(dir, `${validate(conversationId)}-${validate(runId)}.json`);
        const receipt = JSON.parse(fs.readFileSync(file, 'utf8'));
        try { receipt.cancellation = JSON.parse(fs.readFileSync(file + '.cancellation', 'utf8')); }
        catch (error) { if (error.code !== 'ENOENT') throw error; }
        return receipt;
      }
      catch (e) { if (e.code === 'ENOENT') return {}; throw e; }
    },
  };
}
function reconcileLiveControls(snapshot, receipt) {
  for (const live of receipt.liveMessages || []) {
    const messages = live.thread_id && live.thread_id !== '0'
      ? snapshot.nodes.find(node => node.threadId === live.thread_id)?.messages : snapshot.messages;
    const stored = messages?.find(message => message.message_id === live.message_id);
    if (!stored) continue;
    if (['completed', 'cancelled', 'failed'].includes(messageState(stored))) {
      live.content_block = messageBlocks(live).filter(block => [10070, 10090].includes(block.block_type));
    } else {
      for (const block of messageBlocks(stored)) {
        const ask = block.content?.interaction_ask_block, quick = block.content?.quick_reply_block;
        if (ask && [2, 3].includes(ask.status) || quick?.status === 2) {
          live.content_block = messageBlocks(live).filter(item => item.block_id !== block.block_id);
        }
      }
    }
  }
}

function handoffsFromSnapshot(snapshot, receipt) {
  receipt.handoffs ||= [];
  for (const message of [...snapshot.messages, ...snapshot.nodes.flatMap(node => node.messages)]) {
    const job = parse(message.ext?.async_job);
    if (job.job_id && job.append_scene && !receipt.handoffs.some(task => task.taskId === String(job.job_id))) {
      receipt.handoffs.push({ taskId: String(job.job_id), appendScene: job.append_scene, seq: 0 });
    }
  }
}

export async function waitTurn(client, conversationId, options = {}) {
  const deadline = options.deadline || Date.now() + (options.timeoutMs || 120000);
  const receipt = options.receipt || {};
  receipt.conversationId = conversationId;
  receipt.runId ||= options.runId;
  receipt.localMessageId ||= options.localMessageId;
  let snapshot = options.snapshot, lastError, resumed = false;
  do {
    try {
      const saved = options.loadReceipt?.(receipt.runId);
      if (saved?.cancellation) receipt.cancellation = saved.cancellation;
      snapshot = await readTurn(client, conversationId, { ...options, runId: receipt.runId || options.runId, receipt, deadline });
      receipt.runId = snapshot.result.runId;
      receipt.localMessageId ||= snapshot.result.localMessageId;
      reconcileLiveControls(snapshot, receipt);
      handoffsFromSnapshot(snapshot, receipt);
      options.onReceipt?.(receipt);
      if (['completed', 'failed', 'cancelled', 'waiting_input'].includes(snapshot.result.status)) return snapshot.result;
    } catch (error) {
      lastError = error;
      // An ACK can precede IM persistence. Retry lookups, never the send.
      if (error.code !== 'turn_unavailable') break;
    }
    if (Date.now() >= deadline) break;
    try {
      if (!resumed && receipt.requestBody && !receipt.handoffs?.length && !receipt.liveMessages?.some(m => pendingInputs([m]).length)) {
        resumed = true;
        try {
          const result = await sendChatCompletion(client, { conversationId, runId: receipt.runId,
            localMessageId: receipt.localMessageId, model: {}, resumeRequest: receipt.requestBody,
            timeoutMs: Math.max(1, deadline - Date.now()), waitForReply: true,
            onReceipt: next => { Object.assign(receipt, next); options.onReceipt?.(receipt); } });
          Object.assign(receipt, result); options.onReceipt?.(receipt);
        } catch (error) {
          if (error.receipt) { Object.assign(receipt, error.receipt); options.onReceipt?.(receipt); }
          if (!['timeout', 'incomplete_stream', 'exception'].includes(error.code)) throw error;
        }
      } else if (receipt.handoffs?.some(task => !task.completed)) {
        await followTaskStreams(client, receipt, Math.min(1500, deadline - Date.now()), options.onReceipt);
      } else await new Promise(resolve => setTimeout(resolve, Math.min(750, deadline - Date.now())));
    } catch (error) { lastError = error; break; }
  } while (Date.now() < deadline);
  const timedOut = Date.now() >= deadline;
  const error = new Error(timedOut
    ? 'Waiting timed out; the task was not cancelled. Continue with sessions wait ' + conversationId + (receipt.runId ? ' --run ' + receipt.runId : '')
    : 'Could not confirm task state; the task was not cancelled. ' + lastError?.message);
  error.code = timedOut ? 'timeout' : 'task_unavailable';
  error.result = { ...(snapshot?.result || { conversationId, runId: receipt.runId, localMessageId: receipt.localMessageId, reply: null, status: 'unknown' }),
    ...(!timedOut ? { status: 'unknown' } : {}) };
  throw error;
}

export async function refreshTurn(client, conversationId, options = {}) {
  const receipt = options.receipt || {};
  let snapshot = await readTurn(client, conversationId, { ...options, receipt });
  receipt.conversationId = conversationId; receipt.runId = snapshot.result.runId;
  reconcileLiveControls(snapshot, receipt);
  handoffsFromSnapshot(snapshot, receipt);
  if (['running', 'unknown'].includes(snapshot.result.status) && receipt.handoffs.some(task => !task.completed)) {
    await followTaskStreams(client, receipt, Math.min(1500, remaining(options.deadline)), options.onReceipt);
    snapshot = await readTurn(client, conversationId, { ...options, runId: receipt.runId, receipt });
  }
  options.onReceipt?.(receipt);
  return snapshot;
}

export async function stopTurn(client, conversationId, options = {}) {
  const deadline = Date.now() + (options.timeoutMs || 15000);
  options.receipt ||= {};
  let snapshot = await refreshTurn(client, conversationId, { ...options, deadline });
  const runId = snapshot.result.runId;
  const terminal = result => ['completed', 'failed', 'cancelled'].includes(result.status)
    && !result.tasks.running && !result.tasks.unknown;
  if (terminal(snapshot.result)) return { ...snapshot.result, stopped: true };
  const stopped = new Set(), errors = [];
  const receipt = options.receipt;
  receipt.conversationId = conversationId; receipt.runId = runId;
  receipt.cancellation = { requestedAt: new Date().toISOString(), accepted: false };
  options.onReceipt?.(receipt);
  // The server request addresses this question id, never the latest UI reply.
  try {
    await imRequest(client, 'message/break_stream_msg', 2240, 'break_stream_msg_uplink_body', {
      reply_msg_id: runId, message_id: '', conversation_id: conversationId,
      conversation_type: snapshot.conversation.conversation_type, break_reason: 7,
    }, remaining(deadline));
    receipt.cancellation.accepted = true; options.onReceipt?.(receipt);
  } catch (error) { errors.push({ runId, message: error.message }); }
  do {
    for (const node of snapshot.nodes) {
      if (Date.now() >= deadline) break;
      if (['completed', 'cancelled', 'failed'].includes(node.status) || stopped.has(node.threadId)) continue;
      try {
        const timeout = remaining(deadline);
        const result = await evaluateWithWatchdog(client, `(async () => {
          const req = await new Promise(resolve => window['@flow-web/desktop:stable'].push([['doubao_stop_' + crypto.randomUUID()], {}, resolve]));
          await req.e('1383');
          return req(359531).iv.AGWTaskTerminate({ thread_id: ${JSON.stringify(node.threadId)} });
        })()`, timeout + 1000);
        if (result.code !== 0) throw new Error('Task cancellation rejected: ' + (result.message || result.msg || result.code));
        stopped.add(node.threadId);
        receipt.cancellation.accepted = true; options.onReceipt?.(receipt);
      } catch (error) { errors.push({ threadId: node.threadId, message: error.message }); }
    }
    try { snapshot = await readTurn(client, conversationId, { runId, receipt: options.receipt, deadline }); }
    catch (error) { errors.push({ runId, message: error.message }); break; }
    if (terminal(snapshot.result)) {
      receipt.cancellation.confirmed = true; options.onReceipt?.(receipt);
      return { ...snapshot.result, status: 'cancelled', reply: null, pending: [], stopped: true };
    }
    if (Date.now() >= deadline) break;
    await new Promise(resolve => setTimeout(resolve, Math.min(500, deadline - Date.now())));
  } while (Date.now() < deadline);
  return { ...snapshot.result, stopped: false,
    reason: 'Cancellation requested, but not all task states could be confirmed', ...(errors.length ? { errors } : {}) };
}

// Consume each asynchronous handoff without submitting another user message.
// Server snapshots remain authoritative for final text, task state and artifacts.
export async function followTaskStreams(client, receipt, timeoutMs, onReceipt = () => {}) {
  if (!receipt.handoffs?.length) return;
  const { query } = await runtimeParameters(client);
  const result = await evaluateWithWatchdog(client, `(async () => {
    const tasks = ${JSON.stringify(receipt.handoffs)};
    const state = { liveMessages: ${JSON.stringify(receipt.liveMessages || [])} };
    const updateLiveControls = ${updateLiveControls.toString()};
    const deadline = Date.now() + ${Math.max(1, timeoutMs)};
    const seen = new Set(), pending = [];
    const read = async task => {
      if (seen.has(task.taskId) || task.completed) return;
      seen.add(task.taskId);
      delete task.waitingInput;
      while (Date.now() < deadline && !task.completed) {
        const ac = new AbortController(); const timer = setTimeout(() => ac.abort(), Math.max(1, deadline - Date.now()));
        try {
          const response = await fetch(${JSON.stringify('https://api5-normal-gl.doubao.com/chat/async/chunk_stream?' + query)}, {
            method: 'POST', credentials: 'include', headers: { 'content-type': 'application/json' },
            body: JSON.stringify({ task_id: task.taskId, seq_start: task.seq || 0, append_scene: task.appendScene, ext: {} }), signal: ac.signal,
          });
          if (!response.ok) throw new Error('Async stream HTTP ' + response.status);
          const reader = response.body.getReader(), decoder = new TextDecoder(); let buffer = '';
          try { while (!task.completed) {
            const part = await reader.read(); if (part.done) break;
            buffer += decoder.decode(part.value, { stream: true }).replaceAll('\\r\\n', '\\n');
            let end;
            while ((end = buffer.indexOf('\\n\\n')) >= 0) {
              const chunk = buffer.slice(0, end); buffer = buffer.slice(end + 2);
              const lines = chunk.split('\\n'), event = lines.find(l => l.startsWith('event:'))?.slice(6).trim();
              const id = Number(lines.find(l => l.startsWith('id:'))?.slice(3).trim());
              let data; try { data = JSON.parse(lines.filter(l => l.startsWith('data:')).map(l => l.slice(5)).join('\\n')); } catch { continue; }
              if (Number.isFinite(id) && id > 0 && id <= (task.seq || 0)) continue;
              if (Number.isFinite(id)) task.seq = Math.max(task.seq || 0, id);
              const waiting = updateLiveControls(state, event, data);
              if (waiting) { task.waitingInput = true; break; }
              if (event === 'ASYNC_CHUNK_SNAPSHOT') task.seq = Math.max(task.seq || 0, Number(data.next_seq) || 0);
              if (event === 'FETCH_STREAM' && data.fetch_type === 2 && data.fetch_key && !tasks.some(t => t.taskId === String(data.fetch_key))) {
                if (tasks.length >= 100) throw new Error('Async task stream limit exceeded');
                const child = { taskId: String(data.fetch_key), appendScene: data.append_scene, threadId: data.thread_id || '', seq: 0 };
                tasks.push(child); pending.push(read(child));
              }
              if (event === 'SSE_REPLY_END' && data.end_type === 3) task.completed = true;
              if (event === 'STREAM_ERROR' || event === 'gateway-error') { task.error = data.error_msg || data.error_code || event; task.completed = true; }
            }
            if (task.waitingInput) break;
          } } finally { await reader.cancel().catch(() => {}); }
        } catch (error) { task.connectionError = String(error.message || error); }
        finally { clearTimeout(timer); }
        if (task.waitingInput) break;
        if (!task.completed && Date.now() < deadline) await new Promise(r => setTimeout(r, 300));
      }
    };
    for (const task of tasks) pending.push(read(task));
    for (let index = 0; index < pending.length; index++) await pending[index];
    return { tasks, liveMessages: state.liveMessages };
  })()`, Math.max(1, timeoutMs) + 1000);
  receipt.handoffs = result.tasks; receipt.liveMessages = result.liveMessages; onReceipt(receipt);
}
