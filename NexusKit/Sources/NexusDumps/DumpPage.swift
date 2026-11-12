import Foundation
import NexusCore

// The web page of the dumps: one HTML file with its style and its script. The design is the frame
// "Dumps Web Page" in nexus.pen. The page shows the same list and tree as the Dumps screen of the
// app and follows the colors of macOS in light and dark mode.
//
// The script puts each value of a dump into the page as text, never as HTML. So a dump cannot run
// a script in the page. The token goes with each request that changes something.
public enum DumpPage {
    // Each answer gets its own nonce. The scripts and the styles of the page carry it. So no other
    // script runs in the page.
    static func response(token: String) -> PageResponse {
        let nonce = DumpPageServer.newToken()
        let policy = "default-src 'none'; script-src 'nonce-\(nonce)'; style-src 'nonce-\(nonce)'; connect-src 'self'; img-src 'self' data:; base-uri 'none'; form-action 'none'; frame-ancestors 'none'"
        let html = html(token: token, nonce: nonce, title: "\(NexusVariant.current.name) Dumps")
        return PageResponse(status: 200, contentType: "text/html; charset=utf-8", body: Data(html.utf8), headers: ["Content-Security-Policy": policy])
    }

    static func html(token: String, nonce: String, title: String) -> String {
        let values = [
            "{{TOKEN}}": token,
            "{{NONCE}}": nonce,
            "{{TITLE}}": title,
            "{{DUMP_LIMIT}}": String(DumpStore.dumpLimit),
            "{{OPEN_LIMIT}}": String(DumpNode.openChildrenLimit),
        ]

        return values.reduce(markup + script + "</script>\n</body>\n</html>\n") { page, value in
            page.replacingOccurrences(of: value.key, with: HTMLText.escaped(value.value))
        }
    }

    private static let markup = #"""
    <!doctype html>
    <html lang="en">
    <head>
    <meta charset="utf-8">
    <meta name="viewport" content="width=device-width, initial-scale=1">
    <meta name="nexus-token" content="{{TOKEN}}">
    <link rel="icon" href="data:,">
    <title>{{TITLE}}</title>
    <style nonce="{{NONCE}}">
    :root {
      color-scheme: light dark;
      --window: #ffffff;
      --bar: #f1eff5;
      --group: #f6f5f8;
      --separator: rgba(0, 0, 0, 0.1);
      --label: rgba(0, 0, 0, 0.85);
      --secondary: rgba(0, 0, 0, 0.55);
      --tertiary: rgba(0, 0, 0, 0.26);
      --accent: #7a3cf0;
      --accent-soft: rgba(122, 60, 240, 0.08);
      --selection: rgba(122, 60, 240, 0.12);
      --control: #ffffff;
      --control-border: rgba(0, 0, 0, 0.14);
      --green: #30c25a;
      --green-text: #1e8a3c;
      --orange-text: #a35f00;
      --red-text: #c9261c;
      --warning: rgba(245, 154, 10, 0.12);
      --box: #ffffff;
      --dim: rgba(0, 0, 0, 0.25);
    }
    @media (prefers-color-scheme: dark) {
      :root {
        --window: #1c1b20;
        --bar: #26242c;
        --group: #2a2830;
        --separator: rgba(255, 255, 255, 0.1);
        --label: rgba(255, 255, 255, 0.9);
        --secondary: rgba(255, 255, 255, 0.6);
        --tertiary: rgba(255, 255, 255, 0.3);
        --accent: #b48cff;
        --accent-soft: rgba(180, 140, 255, 0.12);
        --selection: rgba(180, 140, 255, 0.18);
        --control: #45424d;
        --control-border: rgba(255, 255, 255, 0.12);
        --green: #32d35e;
        --green-text: #4ade80;
        --orange-text: #ffb54d;
        --red-text: #ff6b61;
        --warning: rgba(255, 165, 31, 0.15);
        --box: #1c1b20;
        --dim: rgba(0, 0, 0, 0.45);
      }
    }
    * { box-sizing: border-box; }
    [hidden] { display: none !important; }
    html, body { height: 100%; }
    body {
      margin: 0;
      display: flex;
      flex-direction: column;
      background: var(--window);
      color: var(--label);
      font: 13px/1.4 -apple-system, BlinkMacSystemFont, "SF Pro Text", system-ui, sans-serif;
    }
    button, select { font: inherit; color: inherit; }
    .bar {
      display: flex;
      align-items: center;
      gap: 12px;
      min-height: 56px;
      padding: 0 24px;
      background: var(--bar);
      border-bottom: 1px solid var(--separator);
    }
    .title-block { flex: 1; min-width: 0; }
    h1 { margin: 0; font-size: 15px; font-weight: 600; }
    .subtitle { margin: 0; font-size: 11px; color: var(--secondary); }
    .live { display: flex; align-items: center; gap: 6px; font-size: 11px; color: var(--secondary); }
    .live-dot { width: 8px; height: 8px; border-radius: 50%; background: var(--tertiary); }
    .live.on .live-dot { background: var(--green); }
    .control {
      padding: 3px 11px;
      border: 1px solid var(--control-border);
      border-radius: 6px;
      background: var(--control);
      box-shadow: 0 0.5px 1px rgba(0, 0, 0, 0.1);
      cursor: default;
    }
    .control:disabled { opacity: 0.45; }
    select.control { padding-right: 24px; }
    main { flex: 1; display: flex; flex-direction: column; gap: 8px; min-height: 0; padding: 24px; }
    .banner {
      display: flex;
      align-items: center;
      gap: 12px;
      padding: 10px 14px;
      border-radius: 10px;
      background: var(--warning);
    }
    .banner-text { flex: 1; min-width: 0; }
    .banner-title { font-weight: 600; }
    .banner-message { font-size: 12px; color: var(--secondary); white-space: pre-line; }
    .banner-icon { color: var(--orange-text); font-size: 16px; }
    .requests {
      flex: 1;
      display: flex;
      min-height: 0;
      border-radius: 10px;
      background: var(--group);
      overflow: hidden;
    }
    .list { width: 360px; flex: none; overflow-y: auto; border-right: 1px solid var(--separator); outline: none; }
    .row { padding: 9px 12px; border-bottom: 1px solid var(--separator); cursor: default; }
    .row.selected { background: var(--selection); }
    .row-line { display: flex; align-items: center; gap: 6px; min-width: 0; }
    .row-line + .row-line { margin-top: 3px; }
    .method { font: 600 11px ui-monospace, "SF Mono", Menlo, monospace; color: var(--secondary); }
    .target { flex: 1; min-width: 0; font-weight: 600; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
    .small { font-size: 11px; color: var(--secondary); }
    .summary { flex: 1; min-width: 0; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
    .tag {
      flex: none;
      padding: 1px 6px;
      border-radius: 4px;
      background: var(--accent-soft);
      color: var(--accent);
      font-size: 10.5px;
      font-weight: 500;
    }
    .tag.warning { background: var(--warning); color: var(--orange-text); font-family: ui-monospace, "SF Mono", Menlo, monospace; }
    .detail { flex: 1; min-width: 0; display: flex; flex-direction: column; }
    .head { padding: 12px 16px; border-bottom: 1px solid var(--separator); }
    .head-title { display: flex; align-items: center; gap: 8px; }
    .head-title h2 { flex: 1; min-width: 0; margin: 0; font-size: 15px; font-weight: 600; overflow-wrap: anywhere; }
    .head-line { display: flex; gap: 8px; margin-top: 6px; font-size: 12px; }
    .head-key { width: 48px; flex: none; color: var(--secondary); }
    .head-value { min-width: 0; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
    a, .link { color: var(--accent); text-decoration: none; }
    a:hover, .link:hover { text-decoration: underline; }
    .icon-button {
      display: inline-flex;
      align-items: center;
      justify-content: center;
      width: 22px;
      height: 20px;
      padding: 0;
      border: 0;
      border-radius: 5px;
      background: none;
      color: var(--secondary);
    }
    .icon-button:hover { background: var(--separator); }
    .icon-button.remove:hover { color: var(--red-text); }
    svg { width: 14px; height: 14px; fill: none; stroke: currentColor; stroke-width: 2; stroke-linecap: round; stroke-linejoin: round; }
    .dumps { flex: 1; overflow-y: auto; padding: 16px; }
    .dump + .dump { margin-top: 14px; }
    .source { display: flex; align-items: center; gap: 6px; font-size: 12px; }
    .source svg { width: 13px; height: 13px; color: var(--secondary); flex: none; }
    .source .link {
      min-width: 0;
      padding: 0;
      border: 0;
      background: none;
      overflow: hidden;
      text-overflow: ellipsis;
      white-space: nowrap;
      direction: rtl;
      text-align: left;
    }
    .source .label { font-weight: 600; white-space: nowrap; }
    .source .spacer { flex: 1; }
    .kind { font: 11px ui-monospace, "SF Mono", Menlo, monospace; color: var(--secondary); }
    .box {
      margin-top: 6px;
      padding: 8px 12px;
      border: 1px solid var(--separator);
      border-radius: 8px;
      background: var(--box);
      font: 12px/1.45 ui-monospace, "SF Mono", Menlo, monospace;
      overflow-x: auto;
    }
    .box pre { margin: 0; font: inherit; white-space: pre-wrap; overflow-wrap: anywhere; }
    .node-line { display: flex; align-items: baseline; gap: 4px; padding: 1px 0; white-space: pre-wrap; overflow-wrap: anywhere; }
    .leaf { padding-left: 16px; }
    .children { padding-left: 16px; }
    .chevron {
      flex: none;
      width: 12px;
      height: 12px;
      padding: 0;
      border: 0;
      background: none;
      color: var(--secondary);
      font-size: 9px;
      font-weight: 700;
      line-height: 12px;
      transition: transform 0.1s;
    }
    .chevron.open { transform: rotate(90deg); }
    .key-index, .number { color: var(--accent); }
    .key-string, .string { color: var(--green-text); }
    .muted { color: var(--tertiary); }
    .soft { color: var(--secondary); }
    .bold { font-weight: 600; }
    .note { margin-top: 4px; font-size: 11px; color: var(--secondary); }
    .empty-line { padding: 12px 14px; border-radius: 10px; background: var(--group); color: var(--secondary); }
    .center { margin: auto; color: var(--secondary); }
    .footer { margin: 0; font-size: 11px; line-height: 1.35; color: var(--secondary); }
    dialog {
      width: 360px;
      padding: 20px;
      border: 1px solid var(--separator);
      border-radius: 12px;
      background: var(--window);
      color: var(--label);
      box-shadow: 0 16px 40px rgba(0, 0, 0, 0.25);
    }
    dialog::backdrop { background: var(--dim); }
    dialog h2 { margin: 0 0 8px; font-size: 15px; font-weight: 600; }
    dialog p { margin: 0; font-size: 12px; color: var(--secondary); }
    .buttons { display: flex; justify-content: flex-end; gap: 8px; margin-top: 16px; }
    .danger { color: var(--red-text); }
    .toast {
      position: fixed;
      right: 24px;
      bottom: 24px;
      max-width: 420px;
      padding: 10px 14px;
      border-radius: 10px;
      background: var(--label);
      color: var(--window);
      font-size: 12px;
    }
    </style>
    </head>
    <body>
    <header class="bar">
      <div class="title-block">
        <h1>{{TITLE}}</h1>
        <p class="subtitle" id="subtitle"></p>
      </div>
      <span class="live" id="live"><span class="live-dot"></span><span id="live-text">Connects to Nexus</span></span>
      <select class="control" id="filter" aria-label="Filter"></select>
      <button class="control" id="clear" type="button">Clear…</button>
    </header>
    <main>
      <div id="banners"></div>
      <section class="requests" id="requests" hidden>
        <div class="list" id="list" role="listbox" tabindex="0" aria-label="Requests"></div>
        <div class="detail" id="detail"></div>
      </section>
      <p class="empty-line" id="empty" hidden></p>
      <p class="footer">Nexus keeps the newest {{DUMP_LIMIT}} dumps. A click on a file opens it in your code editor.</p>
    </main>
    <dialog id="confirm">
      <h2 id="confirm-title"></h2>
      <p>You cannot get these dumps back.</p>
      <div class="buttons">
        <button class="control" id="confirm-cancel" type="button">Cancel</button>
        <button class="control danger" id="confirm-clear" type="button">Clear dumps</button>
      </div>
    </dialog>
    <div class="toast" id="toast" role="status" hidden></div>
    <script nonce="{{NONCE}}">

    """#

    private static let script = #"""
    "use strict";

    const token = document.querySelector('meta[name="nexus-token"]').content;
    const openChildrenLimit = {{OPEN_LIMIT}};
    const state = {
      list: null,
      requests: [],
      filter: "",
      filterLabel: null,
      choices: "",
      openID: null,
      dumps: [],
      loadProblem: null,
      boxes: new Map(),
      rows: new Map(),
      loading: false,
      requestedLast: null,
      generation: 0,
      lostConnection: false,
    };

    const timeFormat = new Intl.DateTimeFormat(undefined, { hour: "numeric", minute: "2-digit" });
    const secondsFormat = new Intl.DateTimeFormat(undefined, { hour: "numeric", minute: "2-digit", second: "2-digit" });
    const dayFormat = new Intl.DateTimeFormat(undefined, { day: "numeric", month: "short" });
    const dateFormat = new Intl.DateTimeFormat(undefined, { day: "numeric", month: "short", year: "numeric" });

    const $ = (id) => document.getElementById(id);

    function element(tag, className, text) {
      const node = document.createElement(tag);

      if (className) {
        node.className = className;
      }

      if (text != null) {
        node.textContent = text;
      }

      return node;
    }

    // A container gets its children again only when they changed. So the browser does not lay out
    // the same list and the same trees again.
    function show(container, nodes) {
      const children = container.children;

      if (children.length === nodes.length && nodes.every((node, index) => children[index] === node)) {
        return;
      }

      container.replaceChildren(...nodes);
    }

    const iconPaths = {
      file: ["M14 2H6a2 2 0 0 0-2 2v16a2 2 0 0 0 2 2h12a2 2 0 0 0 2-2V8z", "M14 2v6h6", "M10 13l-2 2 2 2", "M14 17l2-2-2-2"],
      copy: ["M8 8h12v12H8z", "M4 16V4h12"],
      trash: ["M3 6h18", "M19 6l-1 14H6L5 6", "M10 11v6", "M14 11v6", "M9 6V4h6v2"],
      warning: ["M10.3 3.9 1.8 18a2 2 0 0 0 1.7 3h17a2 2 0 0 0 1.7-3L13.7 3.9a2 2 0 0 0-3.4 0z", "M12 9v4", "M12 17h.01"],
    };

    function icon(name) {
      const svg = document.createElementNS("http://www.w3.org/2000/svg", "svg");
      svg.setAttribute("viewBox", "0 0 24 24");
      svg.setAttribute("aria-hidden", "true");

      for (const data of iconPaths[name]) {
        const path = document.createElementNS("http://www.w3.org/2000/svg", "path");
        path.setAttribute("d", data);
        svg.append(path);
      }

      return svg;
    }

    function iconButton(name, help, action) {
      const button = element("button", name === "trash" ? "icon-button remove" : "icon-button");
      button.type = "button";
      button.title = help;
      button.setAttribute("aria-label", help);
      button.append(icon(name));
      button.addEventListener("click", action);
      return button;
    }

    function count(number, noun) {
      return number === 1 ? `1 ${noun}` : `${number} ${noun}s`;
    }

    // A request and a block both have a site and a workspace.
    function placeKey(place) {
      return JSON.stringify([place.site ?? null, place.workspace ?? null]);
    }

    function placeOfKey(key) {
      const [site, workspace] = JSON.parse(key);
      return { site, workspace };
    }

    function displayMethod(request) {
      return request.kind === "command" ? "CLI" : (request.method ?? "");
    }

    // The same texts as nexus dumps and the Dumps screen.
    function durationText(seconds) {
      const milliseconds = Math.round(seconds * 1000);

      if (milliseconds < 1000) {
        return `${milliseconds} ms`;
      }

      const tenths = Math.round(seconds * 10) / 10;

      if (tenths < 60) {
        return `${tenths.toFixed(1)} s`;
      }

      const whole = Math.round(seconds);
      return `${Math.floor(whole / 60)} min ${whole % 60} s`;
    }

    function statusText(request) {
      if (request.kind === "command") {
        return request.exitCode == null ? null : `exit ${request.exitCode}`;
      }

      return request.status == null ? null : String(request.status);
    }

    function resultText(request) {
      const parts = [statusText(request), request.duration == null ? null : durationText(request.duration)].filter(Boolean);
      return parts.length ? parts.join(" · ") : null;
    }

    function summary(request) {
      return [count(request.dumpCount, "dump"), resultText(request)].filter(Boolean).join(" · ");
    }

    function daysAgo(date) {
      const start = (day) => new Date(day.getFullYear(), day.getMonth(), day.getDate()).getTime();
      return Math.round((start(new Date()) - start(date)) / 86400000);
    }

    function listTime(milliseconds) {
      const date = new Date(milliseconds);

      switch (daysAgo(date)) {
        case 0: return timeFormat.format(date);
        case 1: return "Yesterday";
        default: return dayFormat.format(date);
      }
    }

    function fullTime(milliseconds) {
      const date = new Date(milliseconds);
      const time = secondsFormat.format(date);

      switch (daysAgo(date)) {
        case 0: return `Today at ${time}`;
        case 1: return `Yesterday at ${time}`;
        default: return `${dateFormat.format(date)} at ${time}`;
      }
    }

    // The browser sends a GET without a body. So only the page of a GET request opens again.
    function pageURL(request) {
      if (request.kind !== "http" || request.method !== "GET" || !request.url) {
        return null;
      }

      try {
        const url = new URL(request.url);
        return url.protocol === "http:" || url.protocol === "https:" ? url.href : null;
      } catch {
        return null;
      }
    }

    function shortPath(file, projectFolder) {
      if (projectFolder && file.startsWith(`${projectFolder}/`)) {
        return file.slice(projectFolder.length + 1);
      }

      return file;
    }

    function showToast(text) {
      const toast = $("toast");
      toast.textContent = text;
      toast.hidden = false;
      clearTimeout(showToast.timer);
      showToast.timer = setTimeout(() => { toast.hidden = true; }, 4000);
    }

    // The change itself comes back as an event, as it reaches the app.
    async function post(path, body) {
      try {
        const response = await fetch(path, {
          method: "POST",
          headers: { "Content-Type": "application/json", "X-Nexus-Token": token },
          body: JSON.stringify(body),
        });

        if (!response.ok) {
          const answer = await response.json().catch(() => ({}));
          showToast(answer.message ?? "Nexus did not do this.");
        }
      } catch {
        showToast("Nexus does not answer. Is Nexus running?");
      }
    }

    // The list and the changes

    const catchesDumps = () => state.list?.settings?.catchDumps !== false;

    function visibleRequests() {
      return state.filter ? state.requests.filter((request) => placeKey(request) === state.filter) : state.requests;
    }

    function placeChoices() {
      const choices = new Map();

      for (const request of state.requests) {
        const key = placeKey(request);

        if (!choices.has(key)) {
          choices.set(key, { key, label: request.placeHost ?? "No site", hasSite: request.site != null });
        }
      }

      if (state.filter && !choices.has(state.filter)) {
        choices.set(state.filter, { key: state.filter, label: state.filterLabel ?? "No site", hasSite: placeOfKey(state.filter).site != null });
      }

      return [...choices.values()].sort((first, second) => {
        if (first.hasSite !== second.hasSite) {
          return first.hasSite ? -1 : 1;
        }

        return first.label.localeCompare(second.label, undefined, { numeric: true });
      });
    }

    function applyList(list) {
      state.list = list;
      state.requests = list.requests;
      listChanged();
    }

    // The same steps as DumpChange.apply in Nexus.
    function applyChange(change) {
      if (change.cleared) {
        state.requests = [];
      }

      const gone = new Set(change.removed);
      state.requests = state.requests.filter((request) => !gone.has(request.id));

      for (const request of change.changed) {
        const index = state.requests.findIndex((known) => known.id === request.id);

        if (index >= 0) {
          state.requests[index] = request;
        } else {
          state.requests.unshift(request);
        }
      }

      removeDumps(change.removedDumps ?? []);
      listChanged();
    }

    // A load that started before the removal can bring a removed dump back. So that load goes,
    // and the next load asks after the highest dump that stays.
    function removeDumps(numbers) {
      if (numbers.length === 0) {
        return;
      }

      const gone = new Set(numbers);
      state.dumps = state.dumps.filter((dump) => !gone.has(dump.number));
      state.generation += 1;
      state.loading = false;
      state.requestedLast = null;
    }

    function listChanged() {
      const visible = visibleRequests();

      if (!visible.some((request) => request.id === state.openID)) {
        openRequest(visible[0]?.id ?? null);
      }

      render();
      loadOpenDumps();
    }

    // The rendering

    function render() {
      renderHead();
      renderBanners();
      renderFilter();
      renderList();
      renderDetailHead();
    }

    function renderHead() {
      const visible = visibleRequests();
      const showsList = catchesDumps() && visible.length > 0;

      $("subtitle").textContent = state.list ? subtitleText(visible) : "";
      $("clear").disabled = !showsList;
      $("filter").disabled = !catchesDumps();
      $("requests").hidden = !showsList;
      $("empty").hidden = showsList || !state.list;
      $("empty").textContent = showsList ? "" : emptyText();
    }

    function subtitleText(visible) {
      if (!catchesDumps()) {
        return "Catch dumps is off";
      }

      if (visible.length === 0) {
        return state.list.loaded ? "No dumps" : "Nexus loads the dumps";
      }

      const dumps = visible.reduce((total, request) => total + request.dumpCount, 0);
      return `${count(visible.length, "request")} with ${count(dumps, "dump")}`;
    }

    function emptyText() {
      if (!catchesDumps()) {
        return "Turn on Catch dumps in Nexus to see the dumps of your sites.";
      }

      if (state.list && !state.list.loaded) {
        return "Nexus loads the dumps of its last run.";
      }

      if (state.filter) {
        return `${state.filterLabel ?? "No site"} has no dumps.`;
      }

      return "No dumps yet. Add dump($value) to the code of a site and open the page.";
    }

    function banner(title, message) {
      const box = element("div", "banner");
      const sign = element("span", "banner-icon");
      sign.append(icon("warning"));
      const text = element("div", "banner-text");
      text.append(element("div", "banner-title", title), element("div", "banner-message", message));
      box.append(sign, text);
      return box;
    }

    // A block of an older nexusd has no place. It shows only without a filter, as in the app.
    function renderBanners() {
      const banners = [];

      if (state.list && catchesDumps()) {
        if (state.list.problem) {
          banners.push(banner("The dump viewer has a problem", state.list.problem));
        }

        for (const block of state.list.blocked ?? []) {
          if (state.filter && (!block.place || placeKey(block.place) !== state.filter)) {
            continue;
          }

          const name = block.file ? block.file.split("/").pop() : null;
          const source = name ? `The ${name} of ${block.host}` : block.host;
          const message = block.reason === "var_dumper_format"
            ? `${source} sets VAR_DUMPER_FORMAT. Remove this key to see its dumps here.`
            : `${source} sets its own prepend file. PHP then runs that file and not the file of Nexus.`;
          banners.push(banner(`Nexus cannot catch the dumps of ${block.host}`, message));
        }
      }

      $("banners").replaceChildren(...banners);
    }

    // The options change only with the places. So an open menu stays open while dumps arrive.
    function renderFilter() {
      const choices = placeChoices();
      const key = JSON.stringify(choices);
      const select = $("filter");

      if (key !== state.choices) {
        state.choices = key;
        select.replaceChildren(new Option("All sites and workspaces", ""), ...choices.map((choice) => new Option(choice.label, choice.key)));
      }

      select.value = state.filter;
    }

    // A row is made again only when its request or its selection changed.
    function renderList() {
      const rows = visibleRequests().map((request) => {
        const selected = request.id === state.openID;
        const signature = `${selected} ${JSON.stringify(request)}`;
        const cached = state.rows.get(request.id);

        if (cached?.signature === signature) {
          return cached.row;
        }

        const row = requestRow(request, selected);
        state.rows.set(request.id, { signature, row });
        return row;
      });

      const known = new Set(state.requests.map((request) => request.id));

      for (const id of state.rows.keys()) {
        if (!known.has(id)) {
          state.rows.delete(id);
        }
      }

      show($("list"), rows);
    }

    function requestRow(request, selected) {
      const row = element("div", selected ? "row selected" : "row");
      row.setAttribute("role", "option");
      row.setAttribute("aria-selected", String(selected));
      row.setAttribute("aria-label", `${displayMethod(request)} ${request.target}, ${summary(request)}`);
      row.dataset.id = request.id;

      const top = element("div", "row-line");
      top.append(element("span", "method", displayMethod(request)), element("span", "target", request.target), element("span", "small", listTime(request.started)));

      const bottom = element("div", "row-line");
      bottom.append(element("span", "small summary", summary(request)));

      if (request.hasDD) {
        const tag = element("span", "tag warning", "dd()");
        tag.title = "This request called dd(). PHP stopped there.";
        bottom.append(tag);
      }

      bottom.append(element("span", "tag", request.placeHost ?? "No site"));
      row.append(top, bottom);
      return row;
    }

    function openRequestData() {
      return state.requests.find((request) => request.id === state.openID) ?? null;
    }

    function headLine(key, value, link) {
      const line = element("div", "head-line");
      line.append(element("span", "head-key", key));

      if (!link) {
        line.append(element("span", "head-value", value));
        return line;
      }

      const anchor = element("a", "head-value", value);
      anchor.href = link;
      anchor.target = "_blank";
      anchor.rel = "noopener noreferrer";
      anchor.title = `Open ${value} in the browser`;
      line.append(anchor);
      return line;
    }

    // The dumps keep their own container while the request stays open.
    function renderDetailHead() {
      const request = openRequestData();
      const detail = $("detail");

      if (!request) {
        detail.dataset.id = "";
        detail.replaceChildren(element("p", "center", "Choose a request."));
        return;
      }

      if (detail.dataset.id !== request.id) {
        detail.dataset.id = request.id;
        detail.replaceChildren(element("div", "head"), element("div", "dumps"));
      }

      const title = element("div", "head-title");
      title.append(element("h2", null, `${displayMethod(request)} ${request.target}`), element("span", "tag", request.placeHost ?? "No site"));
      title.append(iconButton("trash", "Remove this request and its dumps", () => post("/api/remove-request", { id: request.id })));

      const lines = [title];

      if (request.url) {
        lines.push(headLine("URL", request.url, pageURL(request)));
      }

      if (request.kind === "command" && request.root) {
        lines.push(headLine("Folder", request.root));
      }

      const result = resultText(request);

      if (result) {
        lines.push(headLine("Status", result));
      }

      lines.push(headLine("Time", fullTime(request.started)));
      detail.querySelector(".head").replaceChildren(...lines);
    }

    // The dumps of the open request

    function openRequest(id) {
      if (id === state.openID) {
        return;
      }

      state.openID = id;
      state.generation += 1;
      state.dumps = [];
      state.loadProblem = null;
      state.loading = false;
      state.requestedLast = null;
    }

    // A second click on a request whose dumps did not load tries again, as in the app.
    function loadAgain() {
      if (!state.loadProblem) {
        return;
      }

      state.loadProblem = null;
      state.requestedLast = null;
      loadOpenDumps();
    }

    // The numbers of the store follow the order in which the dumps arrived. So the page asks for
    // the dumps after the highest number that it has, once for each lastNumber, as the app does.
    async function loadOpenDumps() {
      const request = openRequestData();

      if (!request) {
        return;
      }

      state.dumps = state.dumps.filter((dump) => dump.number >= request.firstNumber);
      renderDumps();

      if (state.loading) {
        return;
      }

      const highest = state.dumps.reduce((top, dump) => Math.max(top, dump.number), 0);

      if (!(request.lastNumber > highest) || request.lastNumber === state.requestedLast) {
        return;
      }

      const generation = state.generation;
      state.requestedLast = request.lastNumber;
      state.loading = true;
      renderDumps();
      let dumps = [];
      let problem = null;

      try {
        const response = await fetch(`/api/dumps?request=${encodeURIComponent(request.id)}&after=${highest}`);

        if (response.ok) {
          dumps = await response.json();
        } else {
          problem = (await response.json().catch(() => ({}))).message ?? "Nexus did not load the dumps.";
        }
      } catch {
        problem = "Nexus does not answer. Is Nexus running?";
      }

      if (generation !== state.generation) {
        return;
      }

      const known = new Set(state.dumps.map((dump) => dump.number));
      state.dumps.push(...dumps.filter((dump) => !known.has(dump.number)));
      state.loadProblem = problem;
      state.loading = false;
      loadOpenDumps();
    }

    // Each box stays while its dump stays. So an open node of a tree stays open.
    function renderDumps() {
      const container = $("detail").querySelector(".dumps");

      if (!container) {
        return;
      }

      const projectFolder = openRequestData()?.projectFolder;
      state.boxes = new Map(state.dumps.map((dump) => [dump.number, state.boxes.get(dump.number) ?? dumpBox(dump, projectFolder)]));

      if (state.boxes.size === 0 && state.loading) {
        container.replaceChildren(element("p", "center", "Nexus loads the dumps."));
        return;
      }

      const problem = state.loadProblem ? [element("p", "note", `${state.loadProblem} Click the request to try again.`)] : [];
      show(container, [...state.boxes.values(), ...problem]);
    }

    function dumpBox(dump, projectFolder) {
      const box = element("div", "dump");
      const source = element("div", "source");
      source.append(icon("file"));

      if (dump.file) {
        const link = element("button", "link");
        link.type = "button";
        link.title = `Open ${dump.file} in your code editor`;
        link.append(element("bdi", null, shortPath(dump.file, projectFolder) + (dump.line ? `:${dump.line}` : "")));
        link.addEventListener("click", () => post("/api/open", { number: dump.number }));
        source.append(link);
      } else {
        source.append(element("span", "soft", "No file"));
      }

      if (dump.label) {
        source.append(element("span", "label", dump.label));
      }

      source.append(element("span", "spacer"), element("span", "kind", dump.kind === "dd" ? "dd()" : "dump()"));
      source.append(iconButton("copy", "Copy the text of this dump", async () => {
        try {
          await navigator.clipboard.writeText(dump.text);
          showToast("Nexus copied the text of the dump.");
        } catch {
          showToast("The browser did not copy the text.");
        }
      }));
      source.append(iconButton("trash", "Remove this dump", () => post("/api/remove-dump", { number: dump.number })));

      const content = element("div", "box");
      const tree = parsedTree(dump.tree);

      if (tree) {
        content.append(treeNode(tree, (tree.children?.length ?? 0) <= openChildrenLimit));
      } else {
        content.append(element("pre", null, dump.text));
      }

      box.append(source, content);

      if (dump.truncated) {
        box.append(element("div", "note", "Nexus shortened the text of this dump, because it is very large."));
      }

      return box;
    }

    function parsedTree(text) {
      if (!text) {
        return null;
      }

      try {
        return JSON.parse(text);
      } catch {
        return null;
      }
    }

    // The tree follows CliDumper, as the Dumps screen does: green for a string, the accent for a
    // number, bold for a class. The children of a node show only when it opens.

    const containerKinds = new Set(["array", "object", "resource"]);
    const knownKinds = new Set(["null", "bool", "int", "float", "string", "label", "array", "object", "resource"]);

    function cutOf(node) {
      return node.cut == null || node.cut === 0 ? null : node.cut;
    }

    function leftOut(cut, word) {
      return cut < 0 ? `… some ${word}s left out` : `… ${count(cut, word)} left out`;
    }

    function displayKey(node) {
      if (node.key == null) {
        return null;
      }

      switch (node.access ?? null) {
        case null: return node.index === true ? node.key : `"${node.key}"`;
        case "public": return `+${node.key}`;
        case "protected": return `#${node.key}`;
        case "private": return `-${node.key}`;
        case "dynamic": return `+"${node.key}"`;
        default: return node.key;
      }
    }

    function span(text, className) {
      return element("span", className, text);
    }

    function nodeText(node, isExpanded, hasChildren) {
      const parts = [];
      const key = displayKey(node);
      const kind = knownKinds.has(node.kind) ? node.kind : "label";

      if (key !== null) {
        if (node.access == null) {
          parts.push(span(key, node.index === true ? "key-index" : "key-string"), span(" => ", "soft"));
        } else {
          parts.push(span(`${key}: `));
        }
      }

      switch (kind) {
        case "null":
        case "bool":
        case "int":
        case "float":
          parts.push(span(node.value ?? kind, "number"));
          break;
        case "label":
          parts.push(span(node.value ?? ""));
          break;
        case "string": {
          parts.push(span(`"${node.value ?? ""}"`, "string"));
          const cut = cutOf(node);

          if (cut !== null) {
            parts.push(span(` ${leftOut(cut, "character")}`, "muted"));
          }

          break;
        }
        case "array": {
          const size = node.count ?? node.children?.length ?? 0;
          parts.push(span(size === 0 ? "[]" : `array:${size}`, "bold"));
          break;
        }
        case "object":
          parts.push(span(node.class ?? "object", "bold"));

          if (node.ref != null) {
            parts.push(span(` #${node.ref}`, "muted"));
          }

          break;
        case "resource":
          parts.push(span(`${node.class ?? "unknown"} resource`, "bold"));

          if (node.ref != null) {
            parts.push(span(` @${node.ref}`, "muted"));
          }

          break;
      }

      const items = itemsText(node, kind, isExpanded, hasChildren);

      if (items) {
        parts.push(span(` ${items}`, "muted"));
      }

      return parts;
    }

    function itemsText(node, kind, isExpanded, hasChildren) {
      if (!containerKinds.has(kind)) {
        return null;
      }

      if (!hasChildren) {
        if (node.refersTo != null) {
          return null;
        }

        const cut = cutOf(node);
        return cut === null ? null : leftOut(cut, "item");
      }

      if (kind === "array" || isExpanded || node.count == null) {
        return null;
      }

      return `· ${count(node.count, "item")}`;
    }

    function treeNode(node, isExpanded = false) {
      const children = node.refersTo == null ? (node.children ?? []) : [];

      if (children.length === 0) {
        const line = element("div", "node-line leaf");
        line.append(...nodeText(node, false, false));
        return line;
      }

      const wrapper = element("div");
      const line = element("div", "node-line");
      const chevron = element("button", "chevron", "›");
      chevron.type = "button";
      const text = element("span");
      const content = element("div", "children");
      let open = false;
      let filled = false;

      const showChildren = (shouldOpen) => {
        open = shouldOpen;
        chevron.classList.toggle("open", open);
        chevron.setAttribute("aria-label", open ? "Hide the items" : "Show the items");
        text.replaceChildren(...nodeText(node, open, true));
        content.hidden = !open;

        if (open && !filled) {
          filled = true;
          content.append(...children.map((child) => treeNode(child)));
          const cut = cutOf(node);

          if (cut !== null) {
            content.append(element("div", "node-line leaf muted", leftOut(cut, "item")));
          }
        }
      };

      chevron.addEventListener("click", () => showChildren(!open));
      line.append(chevron, text);
      wrapper.append(line, content);
      showChildren(isExpanded);
      return wrapper;
    }

    // The controls

    $("filter").addEventListener("change", (event) => {
      state.filter = event.target.value;
      state.filterLabel = event.target.selectedOptions[0]?.textContent ?? null;
      listChanged();
    });

    $("list").addEventListener("click", (event) => {
      const row = event.target.closest(".row");

      if (!row) {
        return;
      }

      if (row.dataset.id === state.openID) {
        loadAgain();
        return;
      }

      openRequest(row.dataset.id);
      listChanged();
    });

    // The arrow keys move through the list. Delete removes the open request, as in the app.
    $("list").addEventListener("keydown", (event) => {
      const visible = visibleRequests();
      const index = visible.findIndex((request) => request.id === state.openID);

      if (event.key === "ArrowDown" || event.key === "ArrowUp") {
        event.preventDefault();
        const next = visible[event.key === "ArrowDown" ? index + 1 : Math.max(index - 1, 0)];

        if (next) {
          openRequest(next.id);
          listChanged();
          $("list").querySelector(".row.selected")?.scrollIntoView({ block: "nearest" });
        }

        return;
      }

      if ((event.key === "Delete" || event.key === "Backspace") && state.openID) {
        event.preventDefault();
        post("/api/remove-request", { id: state.openID });
      }
    });

    $("clear").addEventListener("click", () => {
      $("confirm-title").textContent = state.filter ? `Remove the dumps of ${state.filterLabel ?? "No site"}?` : "Remove all dumps?";
      $("confirm").showModal();
    });

    $("confirm-cancel").addEventListener("click", () => $("confirm").close());

    $("confirm-clear").addEventListener("click", () => {
      $("confirm").close();
      post("/api/clear", state.filter ? { place: placeOfKey(state.filter) } : { all: true });
    });

    // The events of Nexus. Nexus sends the whole list first. A change before that list is in the
    // list. After a lost connection the page loads again, because Nexus started again with a new
    // token.

    function setLive(isLive) {
      $("live").classList.toggle("on", isLive);
      $("live-text").textContent = isLive ? "Updates live" : "Waits for Nexus";
    }

    function connect() {
      const events = new EventSource("/api/events");

      events.addEventListener("open", () => {
        if (state.lostConnection) {
          location.reload();
          return;
        }

        setLive(true);
      });

      events.addEventListener("error", () => {
        state.lostConnection = true;
        setLive(false);
      });

      events.addEventListener("list", (event) => {
        applyList(JSON.parse(event.data));
      });

      events.addEventListener("change", (event) => {
        if (!state.list) {
          return;
        }

        applyChange(JSON.parse(event.data));
      });
    }

    connect();

    """#
}
