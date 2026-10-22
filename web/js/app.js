"use strict";

const $ = (id) => document.getElementById(id);

const journalList = $("journal-list");
const entryList = $("entry-list");
const journalHeading = $("journal-heading");
const journalBlurb = $("journal-blurb");
const editJournalBtn = $("edit-journal");
const newJournalBtn = $("new-journal");
const newEntryBtn = $("new-entry");
const searchInput = $("search");
const empty = $("empty");
const emptyTitle = $("empty-title");
const emptyCopy = $("empty-copy");
const emptyAction = $("empty-action");
const writer = $("writer");
const titleInput = $("title");
const bodyInput = $("body");
const previewPane = $("preview");
const entryWhen = $("entry-when");
const saveState = $("save-state");
const wordCount = $("word-count");
const modeWrite = $("mode-write");
const modePreview = $("mode-preview");
const storagePath = $("storage-path");
const journalDialog = $("journal-dialog");
const journalForm = $("journal-form");
const journalDialogTitle = $("journal-dialog-title");
const journalName = $("journal-name");
const journalDescription = $("journal-description");
const journalError = $("journal-error");
const journalDelete = $("journal-delete");
const journalCancel = $("journal-cancel");
const journalSave = $("journal-save");
const confirmDialog = $("confirm-dialog");
const confirmTitle = $("confirm-title");
const confirmCopy = $("confirm-copy");
const confirmCancel = $("confirm-cancel");
const confirmOk = $("confirm-ok");
const toast = $("toast");
const connection = $("connection");

let journals = [];
let entries = [];
let hits = [];
let activeJournalId = null;
let activeEntry = null;
let server = { title: "", body: "" };
let searchQuery = "";
let previewOn = false;
let editingId = null;
let viewToken = 0;
let listToken = 0;
let saveTimer = 0;
let toastTimer = 0;
let searchTimer = 0;
let tail = Promise.resolve();

function el(tag, className, text) {
  const node = document.createElement(tag);
  if (className) node.className = className;
  if (text !== undefined) node.textContent = text;
  return node;
}

function showBanner(message) {
  if (!message) return;
  toast.textContent = message;
  toast.hidden = false;
  clearTimeout(toastTimer);
  toastTimer = setTimeout(() => { toast.hidden = true; }, 5000);
}

function countWords(text) {
  const lead = /^[#*_>`\[\]()!-]+/;
  const trail = /[*_`.,;:!?)\]]+$/;
  let count = 0;
  for (const token of text.split(/[\u0000-\u0020]+/)) {
    if (token.replace(lead, "").replace(trail, "").length > 0) count++;
  }
  return count;
}

function soften(text) {
  return text.replaceAll("**", "").replaceAll("__", "").replaceAll("`", "").replaceAll("*", "");
}

function formatWords(n) {
  return n === 1 ? "1 word" : n + " words";
}

function formatWhen(meta) {
  const created = new Date(meta.created);
  if (Number.isNaN(created.getTime())) return meta.created;
  const createdText = created.toLocaleString(undefined, {
    month: "long", day: "numeric", year: "numeric",
    hour: "numeric", minute: "2-digit",
  });
  const updated = new Date(meta.updated);
  if (Number.isNaN(updated.getTime()) || Math.abs(updated - created) < 60000) {
    return createdText;
  }
  const edited = updated.toLocaleString(undefined, {
    month: "short", day: "numeric", hour: "numeric", minute: "2-digit",
  });
  return createdText + " · edited " + edited;
}

function dayKey(iso) {
  const d = new Date(iso);
  if (Number.isNaN(d.getTime())) return iso;
  return d.getFullYear() + "-" + d.getMonth() + "-" + d.getDate();
}

function dayLabel(iso) {
  const d = new Date(iso);
  if (Number.isNaN(d.getTime())) return iso;
  const sameYear = d.getFullYear() === new Date().getFullYear();
  return d.toLocaleDateString(undefined, {
    weekday: "long",
    month: "long",
    day: "numeric",
    year: sameYear ? undefined : "numeric",
  });
}

function formatTime(iso) {
  const d = new Date(iso);
  if (Number.isNaN(d.getTime())) return "";
  return d.toLocaleTimeString(undefined, { hour: "numeric", minute: "2-digit" });
}

function activeJournal() {
  return journals.find((journal) => journal.id === activeJournalId) || null;
}

function isDirty() {
  return activeEntry !== null &&
    (titleInput.value !== server.title || bodyInput.value !== server.body);
}

function setStatus(text) {
  saveState.textContent = text;
  saveState.dataset.state = text === "Saved" ? "saved" : text === "Not saved" ? "error" : "pending";
}

function showJournalHeading() {
  const journal = activeJournal();
  editJournalBtn.disabled = !journal;
  newEntryBtn.disabled = !journal;
  if (!journal) {
    journalHeading.textContent = "Journal";
    journalBlurb.textContent = "";
    return;
  }
  journalHeading.textContent = journal.name;
  journalBlurb.textContent = journal.description;
}

function renderJournalList() {
  journalList.replaceChildren();
  for (const journal of journals) {
    const button = el("button", "journal");
    button.type = "button";
    button.dataset.id = journal.id;
    if (journal.id === activeJournalId) button.classList.add("active");
    button.appendChild(el("span", "journal-name", journal.name));
    if (journal.description) {
      button.appendChild(el("span", "journal-desc", journal.description.replace(/\s+/g, " ")));
    }
    button.addEventListener("click", () => { void selectJournal(journal.id); });
    journalList.appendChild(button);
  }
}

function highlightActive() {
  const id = activeEntry ? activeEntry.meta.id : "";
  for (const button of entryList.querySelectorAll(".entry")) {
    const on = button.dataset.id === id && button.dataset.journal === activeJournalId;
    button.classList.toggle("active", on);
    if (on) button.setAttribute("aria-current", "true");
    else button.removeAttribute("aria-current");
  }
}

function entryButton(meta, journalId, kicker, preview) {
  const button = el("button", "entry");
  button.type = "button";
  button.dataset.id = meta.id;
  button.dataset.journal = journalId;
  if (kicker) button.appendChild(el("span", "entry-kicker", kicker));
  const line = el("span", "entry-topline");
  line.appendChild(el("span", "entry-title", meta.displayTitle));
  line.appendChild(el("span", "entry-time", formatTime(meta.updated)));
  button.appendChild(line);
  if (preview) button.appendChild(el("span", "entry-preview", soften(preview)));
  return button;
}

function renderEntryList() {
  entryList.replaceChildren();
  const query = searchQuery.trim();
  if (!activeJournalId && !query) {
    entryList.appendChild(el("p", "list-note", "Create a journal to begin."));
    return;
  }
  if (query) {
    if (hits.length === 0) {
      entryList.appendChild(el("p", "list-note", "No entries match “" + query + "”."));
      return;
    }
    for (const hit of hits) {
      const button = entryButton(hit.entry, hit.journalId, hit.journalName, hit.snippet);
      button.addEventListener("click", () => { void openHit(hit); });
      entryList.appendChild(button);
    }
    highlightActive();
    return;
  }
  if (entries.length === 0) {
    entryList.appendChild(el("p", "list-note", "No entries yet."));
    return;
  }
  let lastDay = "";
  for (const meta of entries) {
    const key = dayKey(meta.created);
    if (key !== lastDay) {
      entryList.appendChild(el("div", "day", dayLabel(meta.created)));
      lastDay = key;
    }
    const button = entryButton(meta, activeJournalId, "", meta.preview);
    button.addEventListener("click", () => { void openEntry(meta.id); });
    entryList.appendChild(button);
  }
  highlightActive();
}

function updateEntryRow(meta) {
  if (searchQuery.trim()) return;
  const button = entryList.querySelector('.entry[data-id="' + CSS.escape(meta.id) + '"]');
  if (!button) return;
  const title = button.querySelector(".entry-title");
  const preview = button.querySelector(".entry-preview");
  const time = button.querySelector(".entry-time");
  if (title) title.textContent = meta.displayTitle;
  if (time) time.textContent = formatTime(meta.updated);
  if (preview) preview.textContent = soften(meta.preview);
  else if (meta.preview) button.appendChild(el("span", "entry-preview", soften(meta.preview)));
}

function showEmpty(kind) {
  writer.hidden = true;
  empty.hidden = false;
  emptyAction.hidden = false;
  activeEntry = null;
  server = { title: "", body: "" };
  if (kind === "no-journal") {
    emptyTitle.textContent = "No journal yet";
    emptyCopy.textContent = "Entries are markdown files on this computer. Start one journal, or several.";
    emptyAction.textContent = "New journal";
  } else {
    emptyTitle.textContent = "Nothing written yet";
    emptyCopy.textContent = "Entries are markdown. Write the first one for this journal.";
    emptyAction.textContent = "New entry";
  }
  highlightActive();
}

function showEntry(entry) {
  activeEntry = entry;
  server = { title: entry.meta.title, body: entry.body };
  titleInput.value = entry.meta.title;
  bodyInput.value = entry.body;
  entryWhen.textContent = formatWhen(entry.meta);
  wordCount.textContent = formatWords(countWords(entry.body));
  setStatus("Saved");
  empty.hidden = true;
  writer.hidden = false;
  if (previewOn) renderPreview();
  highlightActive();
}

function setMode(preview) {
  previewOn = preview;
  modeWrite.setAttribute("aria-pressed", preview ? "false" : "true");
  modePreview.setAttribute("aria-pressed", preview ? "true" : "false");
  bodyInput.hidden = preview;
  previewPane.hidden = !preview;
  if (preview) renderPreview();
  else bodyInput.focus();
}

function appendInline(parent, text) {
  const re = /(`[^`]+`)|(\*\*[^*]+\*\*)|(\*[^*]+\*)|(\[[^\]]+\]\([^)\s]+\))/g;
  let last = 0;
  for (const match of text.matchAll(re)) {
    if (match.index > last) parent.append(text.slice(last, match.index));
    const token = match[0];
    if (token.startsWith("`")) {
      parent.appendChild(el("code", "", token.slice(1, -1)));
    } else if (token.startsWith("**")) {
      parent.appendChild(el("strong", "", token.slice(2, -2)));
    } else if (token.startsWith("*")) {
      parent.appendChild(el("em", "", token.slice(1, -1)));
    } else {
      const parts = /^\[([^\]]+)\]\(([^)\s]+)\)$/.exec(token);
      const label = parts[1];
      const href = parts[2];
      if (/^(https?:|mailto:)/i.test(href)) {
        const link = el("a", "", label);
        link.href = href;
        link.target = "_blank";
        link.rel = "noreferrer";
        parent.appendChild(link);
      } else {
        parent.append(label);
      }
    }
    last = match.index + token.length;
  }
  if (last < text.length) parent.append(text.slice(last));
}

function isBlockStart(line) {
  return /^(#{1,6}\s+|```|>|-{3,}|\*{3,})/.test(line) ||
    /^\s*[-*]\s+/.test(line) ||
    /^\s*\d+\.\s+/.test(line);
}

function renderPreview() {
  previewPane.replaceChildren();
  const lines = bodyInput.value.replace(/\r\n/g, "\n").split("\n");
  let i = 0;
  while (i < lines.length) {
    const line = lines[i];
    if (line.trim() === "") {
      i++;
      continue;
    }
    if (line.startsWith("```")) {
      const buf = [];
      i++;
      while (i < lines.length && !lines[i].startsWith("```")) {
        buf.push(lines[i]);
        i++;
      }
      if (i < lines.length) i++;
      const pre = document.createElement("pre");
      pre.appendChild(el("code", "", buf.join("\n")));
      previewPane.appendChild(pre);
      continue;
    }
    if (/^(-{3,}|\*{3,})$/.test(line.trim())) {
      previewPane.appendChild(document.createElement("hr"));
      i++;
      continue;
    }
    const heading = /^(#{1,6})\s+(.*)$/.exec(line);
    if (heading) {
      const node = document.createElement("h" + heading[1].length);
      appendInline(node, heading[2]);
      previewPane.appendChild(node);
      i++;
      continue;
    }
    if (line.startsWith(">")) {
      const buf = [];
      while (i < lines.length && lines[i].startsWith(">")) {
        buf.push(lines[i].replace(/^>\s?/, ""));
        i++;
      }
      const quote = document.createElement("blockquote");
      const paragraph = document.createElement("p");
      appendInline(paragraph, buf.join(" "));
      quote.appendChild(paragraph);
      previewPane.appendChild(quote);
      continue;
    }
    if (/^\s*[-*]\s+/.test(line)) {
      const list = document.createElement("ul");
      while (i < lines.length && /^\s*[-*]\s+/.test(lines[i])) {
        const item = document.createElement("li");
        appendInline(item, lines[i].replace(/^\s*[-*]\s+/, ""));
        list.appendChild(item);
        i++;
      }
      previewPane.appendChild(list);
      continue;
    }
    if (/^\s*\d+\.\s+/.test(line)) {
      const list = document.createElement("ol");
      while (i < lines.length && /^\s*\d+\.\s+/.test(lines[i])) {
        const item = document.createElement("li");
        appendInline(item, lines[i].replace(/^\s*\d+\.\s+/, ""));
        list.appendChild(item);
        i++;
      }
      previewPane.appendChild(list);
      continue;
    }
    const buf = [line];
    i++;
    while (i < lines.length && lines[i].trim() !== "" && !isBlockStart(lines[i])) {
      buf.push(lines[i]);
      i++;
    }
    const paragraph = document.createElement("p");
    appendInline(paragraph, buf.join(" "));
    previewPane.appendChild(paragraph);
  }
}

function flushSave() {
  const run = tail.then(() => saveIfDirty());
  tail = run.then(() => {}, () => {});
  return run;
}

async function saveIfDirty() {
  clearTimeout(saveTimer);
  while (isDirty()) {
    const journalId = activeJournalId;
    const entryId = activeEntry.meta.id;
    const title = titleInput.value;
    const body = bodyInput.value;
    setStatus("Saving…");
    let saved;
    try {
      saved = await neel.updateEntry(journalId, entryId, title, body);
    } catch (e) {
      setStatus("Not saved");
      showBanner(e.message || "Could not save.");
      throw e;
    }
    if (!activeEntry || activeEntry.meta.id !== entryId) return;
    server = { title: title, body: body };
    activeEntry = saved;
    entryWhen.textContent = formatWhen(saved.meta);
    wordCount.textContent = formatWords(countWords(bodyInput.value));
    updateEntryRow(saved.meta);
    const journal = activeJournal();
    if (journal) journal.updated = saved.meta.updated;
    if (titleInput.value === title && bodyInput.value === body) {
      setStatus("Saved");
      return;
    }
  }
}

function scheduleSave() {
  clearTimeout(saveTimer);
  saveTimer = setTimeout(() => { flushSave().catch(() => {}); }, 450);
}

function onDraftInput() {
  wordCount.textContent = formatWords(countWords(bodyInput.value));
  if (previewOn) renderPreview();
  if (!isDirty()) {
    clearTimeout(saveTimer);
    setStatus("Saved");
    return;
  }
  setStatus("Unsaved");
  scheduleSave();
}

async function selectJournal(id) {
  const token = ++viewToken;
  try {
    await flushSave();
  } catch (e) {
    return;
  }
  if (token !== viewToken) return;
  activeJournalId = id;
  searchInput.value = "";
  searchQuery = "";
  hits = [];
  try {
    entries = await neel.listEntries(id);
  } catch (e) {
    showBanner(e.message);
    return;
  }
  if (token !== viewToken) return;
  renderJournalList();
  showJournalHeading();
  renderEntryList();
  if (entries.length === 0) showEmpty("no-entry");
  else await openEntry(entries[0].id, token);
}

async function openEntry(id, token = ++viewToken) {
  try {
    await flushSave();
  } catch (e) {
    return;
  }
  if (token !== viewToken) return;
  let entry;
  try {
    entry = await neel.readEntry(activeJournalId, id);
  } catch (e) {
    showBanner(e.message);
    return;
  }
  if (token !== viewToken) return;
  showEntry(entry);
}

async function openHit(hit) {
  const token = ++viewToken;
  try {
    await flushSave();
  } catch (e) {
    return;
  }
  if (token !== viewToken) return;
  if (hit.journalId !== activeJournalId) {
    activeJournalId = hit.journalId;
    renderJournalList();
    showJournalHeading();
  }
  let entry;
  try {
    entry = await neel.readEntry(hit.journalId, hit.entry.id);
  } catch (e) {
    showBanner(e.message);
    return;
  }
  if (token !== viewToken) return;
  showEntry(entry);
}

async function newEntry() {
  if (!activeJournalId) return;
  const token = ++viewToken;
  try {
    await flushSave();
  } catch (e) {
    return;
  }
  if (token !== viewToken) return;
  let entry;
  try {
    entry = await neel.createEntry(activeJournalId, "", "");
    entries = await neel.listEntries(activeJournalId);
    journals = await neel.listJournals();
  } catch (e) {
    showBanner(e.message);
    return;
  }
  if (token !== viewToken) return;
  searchInput.value = "";
  searchQuery = "";
  hits = [];
  renderJournalList();
  showJournalHeading();
  renderEntryList();
  showEntry(entry);
  setMode(false);
  titleInput.focus();
}

function confirmAction({ title, copy, ok }) {
  confirmTitle.textContent = title;
  confirmCopy.textContent = copy;
  confirmOk.textContent = ok;
  return new Promise((resolve) => {
    let settled = false;
    const finish = (value) => {
      if (settled) return;
      settled = true;
      confirmDialog.close();
      resolve(value);
    };
    confirmOk.onclick = () => finish(true);
    confirmCancel.onclick = () => finish(false);
    confirmDialog.onclose = () => finish(false);
    confirmDialog.showModal();
  });
}

async function deleteCurrent() {
  if (!activeEntry || !activeJournalId) return;
  const label = activeEntry.meta.displayTitle || "this entry";
  const ok = await confirmAction({
    title: "Delete entry",
    copy: "Delete “" + label + "”? This removes its markdown file.",
    ok: "Delete",
  });
  if (!ok || !activeEntry) return;
  const journalId = activeJournalId;
  const entryId = activeEntry.meta.id;
  clearTimeout(saveTimer);
  server = { title: titleInput.value, body: bodyInput.value };
  try {
    await flushSave();
    await neel.deleteEntry(journalId, entryId);
    entries = await neel.listEntries(journalId);
  } catch (e) {
    showBanner(e.message);
    return;
  }
  activeEntry = null;
  renderEntryList();
  if (entries.length > 0) await openEntry(entries[0].id);
  else showEmpty("no-entry");
}

function openJournalDialog(journal) {
  editingId = journal ? journal.id : null;
  journalError.textContent = "";
  journalDialogTitle.textContent = journal ? "Edit journal" : "New journal";
  journalSave.textContent = journal ? "Save" : "Create";
  journalName.value = journal ? journal.name : "";
  journalDescription.value = journal ? journal.description : "";
  journalDelete.hidden = !journal;
  journalDialog.showModal();
  journalName.focus();
}

async function submitJournal(event) {
  event.preventDefault();
  journalError.textContent = "";
  const name = journalName.value;
  const description = journalDescription.value;
  const id = editingId;
  try {
    const saved = id
      ? await neel.updateJournal(id, name, description)
      : await neel.createJournal(name, description);
    journals = await neel.listJournals();
    journalDialog.close();
    if (id) {
      renderJournalList();
      showJournalHeading();
    } else {
      await selectJournal(saved.id);
    }
  } catch (e) {
    journalError.textContent = e.message;
  }
}

async function deleteActiveJournal() {
  const journal = activeJournal();
  if (!journal) return;
  const ok = await confirmAction({
    title: "Delete journal",
    copy: "Delete “" + journal.name + "” and every entry in it? This removes the markdown files.",
    ok: "Delete journal",
  });
  if (!ok) return;
  try {
    clearTimeout(saveTimer);
    await flushSave();
    activeEntry = null;
    server = { title: "", body: "" };
    await neel.deleteJournal(journal.id);
    journals = await neel.listJournals();
  } catch (e) {
    showBanner(e.message);
    return;
  }
  journalDialog.close();
  searchInput.value = "";
  searchQuery = "";
  hits = [];
  if (journals.length === 0) {
    activeJournalId = null;
    entries = [];
    renderJournalList();
    showJournalHeading();
    renderEntryList();
    showEmpty("no-journal");
  } else {
    await selectJournal(journals[0].id);
  }
}

async function applySearch(value) {
  const token = ++listToken;
  searchQuery = value;
  const query = value.trim();
  if (!query) {
    hits = [];
    if (activeJournalId) {
      try {
        entries = await neel.listEntries(activeJournalId);
      } catch (e) {
        showBanner(e.message);
        return;
      }
    }
    if (token !== listToken) return;
    renderEntryList();
    return;
  }
  try {
    hits = await neel.searchEntries(query);
  } catch (e) {
    showBanner(e.message);
    return;
  }
  if (token !== listToken) return;
  renderEntryList();
}

function onEmptyAction() {
  if (!activeJournalId) openJournalDialog(null);
  else void newEntry();
}

function onKeyDown(event) {
  if (journalDialog.open || confirmDialog.open) return;
  const mod = event.ctrlKey || event.metaKey;
  if (mod && event.key.toLowerCase() === "s") {
    event.preventDefault();
    flushSave().catch(() => {});
  } else if (mod && event.key.toLowerCase() === "n") {
    event.preventDefault();
    void newEntry();
  }
}

titleInput.addEventListener("input", onDraftInput);
bodyInput.addEventListener("input", onDraftInput);
titleInput.addEventListener("keydown", (event) => {
  if (event.key === "Enter") {
    event.preventDefault();
    bodyInput.focus();
  }
});
modeWrite.addEventListener("click", () => setMode(false));
modePreview.addEventListener("click", () => setMode(true));
newJournalBtn.addEventListener("click", () => openJournalDialog(null));
editJournalBtn.addEventListener("click", () => {
  const journal = activeJournal();
  if (journal) openJournalDialog(journal);
});
newEntryBtn.addEventListener("click", () => { void newEntry(); });
emptyAction.addEventListener("click", onEmptyAction);
document.getElementById("delete-entry").addEventListener("click", () => { void deleteCurrent(); });
journalForm.addEventListener("submit", (event) => { void submitJournal(event); });
journalCancel.addEventListener("click", () => journalDialog.close());
journalDelete.addEventListener("click", () => { void deleteActiveJournal(); });
searchInput.addEventListener("input", () => {
  clearTimeout(searchTimer);
  const value = searchInput.value;
  searchTimer = setTimeout(() => { void applySearch(value); }, 200);
});
document.addEventListener("keydown", onKeyDown);

async function boot() {
  if (!window.neel) {
    emptyTitle.textContent = "Open Journal from the app";
    emptyCopy.textContent = "This page talks to the Nim backend through Neel.";
    emptyAction.hidden = true;
    return;
  }
  neel.onclose((code, reconnecting) => {
    if (reconnecting) connection.hidden = false;
  });
  neel.onreconnect(() => { connection.hidden = true; });
  try {
    const info = await neel.appInfo();
    storagePath.textContent = info.dataDir;
    storagePath.title = info.dataDir;
    journals = await neel.listJournals();
    renderJournalList();
    showJournalHeading();
    if (journals.length === 0) {
      renderEntryList();
      showEmpty("no-journal");
    } else {
      await selectJournal(journals[0].id);
    }
  } catch (e) {
    emptyTitle.textContent = "Could not open the journal";
    emptyCopy.textContent = e.message || "Something went wrong.";
    emptyAction.hidden = true;
    showBanner(e.message);
  }
}

void boot();
