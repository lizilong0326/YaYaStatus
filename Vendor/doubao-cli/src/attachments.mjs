import fs from 'node:fs/promises';
import path from 'node:path';
import { APP_MODULE_BOOTSTRAP } from './app-modules.mjs';

const DROP_AREA = '[data-testid="file_drop_area"]';
const ATTACHMENT_AREA = '[data-testid="attachment_area"]';
const ATTACHMENT_ITEM = '[data-testid="attachment_area"] [data-testid="attachment_file_item"]';
const IMAGE_ITEM = '[data-testid="attachment_area"] [data-testid="mdbox_image"]';
const MAX_FILE_COUNT = 50;
const MAX_FILE_BYTES = 100 * 1024 * 1024;
const CHUNK_BYTES = 384 * 1024;

const MIME_TYPES = new Map([
  ['.csv', 'text/csv'],
  ['.doc', 'application/msword'],
  ['.docx', 'application/vnd.openxmlformats-officedocument.wordprocessingml.document'],
  ['.epub', 'application/epub+zip'],
  ['.gif', 'image/gif'],
  ['.jpeg', 'image/jpeg'],
  ['.jpg', 'image/jpeg'],
  ['.json', 'application/json'],
  ['.md', 'text/markdown'],
  ['.mobi', 'application/x-mobipocket-ebook'],
  ['.pdf', 'application/pdf'],
  ['.png', 'image/png'],
  ['.ppt', 'application/vnd.ms-powerpoint'],
  ['.pptx', 'application/vnd.openxmlformats-officedocument.presentationml.presentation'],
  ['.txt', 'text/plain'],
  ['.webp', 'image/webp'],
  ['.xls', 'application/vnd.ms-excel'],
  ['.xlsx', 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet'],
]);

function delay(milliseconds) {
  return new Promise((resolve) => setTimeout(resolve, milliseconds));
}

export function attachmentMimeType(filePath) {
  return MIME_TYPES.get(path.extname(filePath).toLocaleLowerCase('en-US')) || 'application/octet-stream';
}

export async function resolveAttachmentFiles(filePaths) {
  if (!Array.isArray(filePaths) || !filePaths.length) return [];
  if (filePaths.length > MAX_FILE_COUNT) throw new Error(`at most ${MAX_FILE_COUNT} attachments can be uploaded at once`);

  const files = [];
  for (const input of filePaths) {
    const resolvedPath = path.resolve(input);
    let stat;
    try {
      stat = await fs.stat(resolvedPath);
    } catch {
      throw new Error(`attachment does not exist: ${resolvedPath}`);
    }
    if (!stat.isFile()) throw new Error(`attachment is not a regular file: ${resolvedPath}`);
    if (stat.size > MAX_FILE_BYTES) throw new Error(`attachment exceeds the 100 MiB CLI limit: ${resolvedPath}`);
    files.push({
      path: resolvedPath,
      name: path.basename(resolvedPath),
      size: stat.size,
      type: attachmentMimeType(resolvedPath),
      lastModified: Math.trunc(stat.mtimeMs),
    });
  }
  return files;
}

async function stageFiles(client, files, stateKey) {
  await client.evaluate(`globalThis[${JSON.stringify(stateKey)}] = []`);
  for (const [index, file] of files.entries()) {
    await client.evaluate(`globalThis[${JSON.stringify(stateKey)}].push({
      name: ${JSON.stringify(file.name)},
      type: ${JSON.stringify(file.type)},
      lastModified: ${file.lastModified},
      chunks: [],
    })`);
    const bytes = await fs.readFile(file.path);
    for (let offset = 0; offset < bytes.length; offset += CHUNK_BYTES) {
      const base64 = bytes.subarray(offset, offset + CHUNK_BYTES).toString('base64');
      await client.evaluate(`globalThis[${JSON.stringify(stateKey)}][${index}].chunks.push(
        Uint8Array.from(atob(${JSON.stringify(base64)}), (character) => character.charCodeAt(0)),
      )`);
    }
  }
}

async function dispatchDrop(client, stateKey) {
  return client.evaluate(`(() => {
    const records = globalThis[${JSON.stringify(stateKey)}];
    const target = document.querySelector(${JSON.stringify(DROP_AREA)})?.parentElement;
    if (!target) throw new Error('Doubao attachment drop target was not found');
    const transfer = new DataTransfer();
    for (const record of records) {
      transfer.items.add(new File(record.chunks, record.name, {
        type: record.type,
        lastModified: record.lastModified,
      }));
    }
    target.dispatchEvent(new DragEvent('drop', { bubbles: true, cancelable: true, dataTransfer: transfer }));
    return [...transfer.files].map((file) => ({ name: file.name, size: file.size, type: file.type }));
  })()`);
}

export function attachmentUploadReady(state, expected) {
  return state.files.length === expected.files
    && state.files.every((item) => item.available)
    && state.images.length === expected.images
    && state.images.every((item) => item.loaded)
    && !state.progressing;
}

async function waitForUploads(client, files, timeoutMs) {
  const expected = {
    files: files.filter((file) => !file.type.startsWith('image/')).length,
    images: files.filter((file) => file.type.startsWith('image/')).length,
  };
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    const state = await client.evaluate(`(() => {
      const area = document.querySelector(${JSON.stringify(ATTACHMENT_AREA)});
      const fileItems = ${expected.files}
        ? [...document.querySelectorAll(${JSON.stringify(ATTACHMENT_ITEM)})].slice(-${expected.files})
        : [];
      const imageItems = ${expected.images}
        ? [...document.querySelectorAll(${JSON.stringify(IMAGE_ITEM)})]
          .filter((item) => !item.closest('[data-testid="attachment_file_item"]'))
          .slice(-${expected.images})
        : [];
      return {
        files: fileItems.map((item) => ({
          available: item.getAttribute('data-available') === 'true',
          name: (item.querySelector('[data-testid="message_nested_content_file_name"]')?.innerText || '').trim(),
          status: (item.querySelector('[data-testid="message_nested_content_file_subtitle"]')?.innerText || '').trim(),
        })),
        images: imageItems.map((item) => {
          const image = item.querySelector('img[alt="image"]');
          return { loaded: Boolean(image?.complete && image?.naturalWidth > 0) };
        }),
        progressing: /(?:^|\\s)\\d{1,3}%(?:\\s|$)/u.test(area?.innerText || ''),
        status: (area?.innerText || '').trim(),
      };
    })()`);
    if (attachmentUploadReady(state, expected)) return;
    const failed = state.files.find((item) => /(?:失败|不支持|超出|error|failed)/iu.test(item.status));
    if (failed) throw new Error(`Doubao failed to upload attachment ${failed.name || ''}: ${failed.status}`.trim());
    if (/(?:失败|不支持|超出|error|failed)/iu.test(state.status)) {
      throw new Error(`Doubao failed to upload an attachment: ${state.status}`);
    }
    await delay(250);
  }
  throw new Error(`Doubao attachments did not finish uploading within ${timeoutMs} ms`);
}

async function clearComposerAttachments(client) {
  await client.evaluate(`(() => {
    for (const item of document.querySelectorAll(${JSON.stringify(ATTACHMENT_ITEM)})) {
      item.querySelector('[data-testid="message_nested_content_file_delete"]')
        ?.dispatchEvent(new MouseEvent('click', { bubbles: true, cancelable: true }));
    }
    const area = document.querySelector(${JSON.stringify(ATTACHMENT_AREA)});
    const imageItems = [...document.querySelectorAll(${JSON.stringify(IMAGE_ITEM)})]
      .filter((item) => !item.closest('[data-testid="attachment_file_item"]'));
    for (const image of imageItems) {
      let container = image.parentElement;
      while (container && container !== area) {
        const deleteButton = [...container.children]
          .find((child) => /(?:^|\\s)delete-btn-[^\\s]+/u.test(child.className || ''));
        if (deleteButton) {
          deleteButton.dispatchEvent(new MouseEvent('click', { bubbles: true, cancelable: true }));
          break;
        }
        container = container.parentElement;
      }
    }
  })()`);
}

export async function uploadAttachmentsFromClient(client, filePaths, options = {}) {
  const files = await resolveAttachmentFiles(filePaths);
  if (!files.length) return [];
  const existingAttachmentCount = await client.evaluate(`(() => {
    const files = document.querySelectorAll(${JSON.stringify(ATTACHMENT_ITEM)}).length;
    const images = [...document.querySelectorAll(${JSON.stringify(IMAGE_ITEM)})]
      .filter((item) => !item.closest('[data-testid="attachment_file_item"]')).length;
    return files + images;
  })()`);
  if (existingAttachmentCount) {
    throw new Error('Doubao composer already contains draft attachments; remove them before using --attach');
  }
  const timeoutMs = options.timeoutMs || 60_000;
  const stateKey = `__doubaoCliUpload_${Date.now()}_${Math.random().toString(16).slice(2)}`;
  try {
    await stageFiles(client, files, stateKey);
    const dropped = await dispatchDrop(client, stateKey);
    if (dropped.length !== files.length) throw new Error('Doubao did not accept every attachment from the drop event');
    try {
      await waitForUploads(client, files, timeoutMs);
    } catch (error) {
      await clearComposerAttachments(client).catch(() => {});
      throw error;
    }
    return files;
  } finally {
    await client.evaluate(`delete globalThis[${JSON.stringify(stateKey)}]`).catch(() => {});
  }
}

// Reuse the app's uploaded attachment records and official wire formatter.
// Only read/remove the uploads staged by this invocation, never another draft.
export async function uploadedAttachmentBlocks(client, files) {
  return client.evaluate(`(async () => {
    const req = await new Promise(resolve => window['@flow-web/desktop:stable'].push([['doubao_attachment_' + crypto.randomUUID()], {}, resolve]));
    ${APP_MODULE_BOOTSTRAP}
    const chatId = appModule(req, 'stores').Wp('chatViewCoreStore').getState().currentChatViewConfig?.chatId;
    const map = appModule(req, 'stores').Wp('attachmentsStore').getState().attachmentsMap?.[chatId] || {};
    const groups = Object.entries(map).filter(([, list]) => list?.length);
    if (groups.length !== 1) throw new Error('Cannot identify the staged attachments safely');
    const [group, attachments] = groups[0];
    const expected = ${JSON.stringify(files.map(f => ({ name: f.name, size: f.size })))};
    if (attachments.length !== expected.length || attachments.some((a, i) =>
      (a.fileName || a.file?.name) !== expected[i].name || Number(a.file?.size ?? a.size) !== expected[i].size)) {
      throw new Error('Composer attachments changed; nothing was sent');
    }
    const params = { chatId, skillType: group.slice(1) };
    const api = appModule(req, 'attachments');
    const states = api.getAttachmentStates(params), keys = api.getAttachmentsKeys(params);
    if (keys.some(k => !k)) throw new Error('Attachment upload identifiers are not ready');
    const block = appModule(req, 'attachmentBlock').S({ attachments, attachmentKeys: keys, attachmentStates: states });
    if (block?.content?.attachment_block?.attachments?.length !== expected.length) throw new Error('The app could not encode every attachment');
    return { blocks: [block], params, localKeys: attachments.map(a => a.localKey) };
  })()`);
}

export async function clearUploadedAttachments(client, snapshot) {
  await client.evaluate(`(async () => {
    const req = await new Promise(resolve => window['@flow-web/desktop:stable'].push([['doubao_attachment_cleanup_' + crypto.randomUUID()], {}, resolve]));
    ${APP_MODULE_BOOTSTRAP}
    const snapshot = ${JSON.stringify(snapshot)};
    const api = appModule(req, 'attachments'), actions = api.getAttachmentActions(snapshot.params);
    for (const key of snapshot.localKeys.slice().reverse()) {
      const index = api.getAttachments(snapshot.params).findIndex(a => a.localKey === key);
      if (index >= 0) await actions.deleteAttachment({ index });
    }
  })()`);
}
