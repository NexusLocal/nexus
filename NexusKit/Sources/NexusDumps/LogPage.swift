import Foundation
import NexusCore

// The web page of the logs (group 7): one HTML file with its style and its script. The design is
// the frame "Logs Web Page" in nexus.pen. The page shows the same entries as the Logs screen of the
// app, with the look of the page of the dumps. It only reads the logs. Only "open in the editor"
// does something. It needs the token.
//
// The script puts each value of an entry into the page as text, never as HTML. So an entry cannot
// run a script in the page. The page asks for the entries every 2 seconds and sends the version
// that it has. nexusd then answers "unchanged" while nothing changed.
public enum LogPage {
    static let pollMilliseconds = 2000

    static func response(token: String) -> PageResponse {
        let nonce = DumpPageServer.newToken()
        let html = html(token: token, nonce: nonce, title: "\(NexusVariant.current.name) Logs")
        return PageResponse(status: 200, contentType: "text/html; charset=utf-8", body: Data(html.utf8), headers: ["Content-Security-Policy": PageParts.policy(nonce: nonce)])
    }

    static func html(token: String, nonce: String, title: String) -> String {
        let page = head + PageParts.style + markup + PageParts.logic + logic + PageParts.interface + interface
        return filled(page + "</script>\n</body>\n</html>\n", token: token, nonce: nonce, title: title)
    }

    // The part of the script that uses no page: the times, the texts of a row and the Markdown of
    // an entry. The tests run it in JavaScriptCore.
    static var logicScript: String {
        filled(PageParts.logic + logic, token: "", nonce: "", title: "")
    }

    private static func filled(_ text: String, token: String, nonce: String, title: String) -> String {
        let values = [
            "{{TOKEN}}": token,
            "{{NONCE}}": nonce,
            "{{TITLE}}": title,
            "{{OPEN_LIMIT}}": String(DumpNode.openChildrenLimit),
            "{{ROW_PAGE}}": String(LogPageStore.rowPage),
            "{{POLL_MILLISECONDS}}": String(pollMilliseconds),
            "{{SHOWN_CHARACTERS}}": String(LogEntryParser.shownCharacters),
        ]

        return values.reduce(text) { page, value in
            page.replacingOccurrences(of: value.key, with: HTMLText.escaped(value.value))
        }
    }

    private static let head = #"""
    <!doctype html>
    <html lang="en">
    <head>
    <meta charset="utf-8">
    <meta name="viewport" content="width=device-width, initial-scale=1">
    <meta name="nexus-token" content="{{TOKEN}}">
    <link rel="icon" href="data:,">
    <title>{{TITLE}}</title>
    <style nonce="{{NONCE}}">

    """#

    private static let markup = #"""
    .logs { flex: 1; display: flex; flex-direction: column; min-height: 0; border-radius: 10px; background: var(--group); overflow: hidden; }
    .filter-bar { display: flex; flex-wrap: wrap; align-items: center; gap: 8px; padding: 8px 12px; border-bottom: 1px solid var(--separator); }
    .search-field {
      display: flex;
      align-items: center;
      gap: 6px;
      width: 220px;
      padding: 3px 8px;
      border: 1px solid var(--control-border);
      border-radius: 6px;
      background: var(--control);
      color: var(--secondary);
    }
    .search-field svg { flex: none; width: 13px; height: 13px; }
    .search-field input { flex: 1; min-width: 0; padding: 0; border: 0; outline: none; background: none; color: var(--label); }
    .search-field input::placeholder { color: var(--tertiary); }
    .levels { display: flex; flex-wrap: wrap; gap: 6px; }
    .chip {
      display: inline-flex;
      align-items: center;
      gap: 6px;
      padding: 2px 8px;
      border: 1px solid var(--control-border);
      border-radius: 6px;
      background: var(--control);
      white-space: nowrap;
      cursor: default;
    }
    .chip.off { background: none; color: var(--tertiary); }
    .chip-count { color: var(--secondary); font-variant-numeric: tabular-nums; }
    .chip.off .chip-count { color: var(--tertiary); }
    .dot { flex: none; width: 7px; height: 7px; border-radius: 50%; background: #8e8e93; }
    .dot.red { background: var(--red); }
    .dot.warning { background: var(--orange); }
    .chip.off .dot { background: var(--tertiary); }
    .check { display: inline-flex; align-items: center; gap: 6px; white-space: nowrap; }
    .check input { margin: 0; accent-color: var(--accent); }
    .chips-bar { display: flex; flex-wrap: wrap; align-items: center; gap: 6px; padding: 6px 12px; border-bottom: 1px solid var(--separator); font-size: 11px; }
    .chips-label { color: var(--secondary); }
    .hidden-chip {
      display: inline-flex;
      align-items: center;
      gap: 4px;
      max-width: 360px;
      padding: 1px 4px 1px 8px;
      border: 0;
      border-radius: 5px;
      background: var(--gray-soft);
      cursor: default;
    }
    .chip-text { overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
    .hidden-chip svg { flex: none; width: 10px; height: 10px; color: var(--secondary); }
    .file-chip {
      display: inline-flex;
      align-items: center;
      gap: 6px;
      padding: 2px 8px;
      border: 1px solid transparent;
      border-radius: 6px;
      background: var(--accent-soft);
      color: var(--accent);
      font-size: 12px;
      cursor: default;
    }
    .file-chip.chosen { border-color: var(--accent); }
    .file-chip:disabled { border-color: var(--separator); background: none; color: var(--secondary); }
    .file-chip .chip-count { color: inherit; }
    .split { flex: 1; display: flex; min-height: 0; }
    .no-rows { flex: 1; display: flex; align-items: center; justify-content: center; margin: 0; color: var(--secondary); }
    .day {
      position: sticky;
      top: 0;
      z-index: 1;
      padding: 4px 12px;
      border-bottom: 1px solid var(--separator);
      background: var(--bar);
      font-size: 11px;
      font-weight: 600;
      color: var(--secondary);
    }
    .row-message { flex: 1; min-width: 0; font-weight: 500; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
    .row-time { flex: none; font: 11px ui-monospace, "SF Mono", Menlo, monospace; color: var(--secondary); }
    .log-detail { display: block; overflow-y: auto; }
    .log-detail > .center { margin: 40px 16px; text-align: center; }
    .log-detail .head-key { width: 56px; }
    .log-detail .head-title { align-items: flex-start; }
    .log-detail .head-title .tag { margin-top: 2px; }
    .head-extra { flex: none; color: var(--tertiary); white-space: nowrap; }
    .cut-line { display: flex; align-items: center; gap: 6px; margin-top: 6px; font-size: 12px; color: var(--secondary); }
    .cut-line svg { flex: none; width: 13px; height: 13px; }
    .section { padding: 10px 16px; border-bottom: 1px solid var(--separator); }
    .section-head { display: flex; align-items: baseline; gap: 8px; margin-bottom: 4px; }
    .section-note { margin-left: auto; font-size: 11px; color: var(--tertiary); white-space: nowrap; }
    .class-name { margin-top: 4px; font: 12px ui-monospace, "SF Mono", Menlo, monospace; overflow-wrap: anywhere; }
    .exception-message { margin-top: 4px; font-size: 12px; white-space: pre-wrap; overflow-wrap: anywhere; }
    .source-line { display: flex; align-items: center; gap: 6px; min-width: 0; margin-top: 6px; font-size: 12px; }
    .source-line svg { flex: none; width: 13px; height: 13px; color: var(--secondary); }
    button.link { min-width: 0; padding: 0; border: 0; background: none; text-align: left; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; cursor: pointer; }
    .frame { display: flex; align-items: baseline; gap: 8px; min-width: 0; padding: 2px 0; font-size: 12px; }
    .frame-number { flex: none; width: 26px; font: 11px ui-monospace, "SF Mono", Menlo, monospace; color: var(--tertiary); }
    .frame .link { flex: 0 1 auto; max-width: 65%; }
    .frame-call { flex: 1 1 0; min-width: 0; font: 11px ui-monospace, "SF Mono", Menlo, monospace; color: var(--secondary); overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
    .vendor-row { display: flex; align-items: center; gap: 8px; width: 100%; padding: 2px 0; border: 0; background: none; color: var(--secondary); font-size: 12px; text-align: left; cursor: default; }
    .vendor-row .frame-number { font: 700 10px -apple-system, BlinkMacSystemFont, system-ui, sans-serif; color: var(--secondary); }
    .find-all {
      display: inline-flex;
      align-items: center;
      gap: 3px;
      margin-left: 6px;
      padding: 0 6px;
      border: 0;
      border-radius: 4px;
      background: var(--accent-soft);
      color: var(--accent);
      font: 11px -apple-system, BlinkMacSystemFont, system-ui, sans-serif;
      white-space: nowrap;
      cursor: default;
    }
    .find-all svg { width: 10px; height: 10px; }
    .menu-button { width: auto; gap: 1px; padding: 0 4px; }
    .menu-button svg + svg { width: 10px; height: 10px; }
    .status-bar { display: flex; align-items: center; gap: 6px; min-width: 0; padding: 6px 12px; border-top: 1px solid var(--separator); font-size: 11px; color: var(--secondary); }
    .status-bar .live-dot { flex: none; width: 7px; height: 7px; }
    .status-bar.on .live-dot { background: var(--green); }
    .status-live { font-weight: 600; white-space: nowrap; }
    .status-bar.on .status-live { color: var(--green-text); }
    .status-count { white-space: nowrap; }
    .status-files { flex: 1; min-width: 0; text-align: right; color: var(--tertiary); overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
    .older { flex: none; font-size: 11px; }
    .menu {
      position: fixed;
      z-index: 10;
      min-width: 190px;
      padding: 4px;
      border: 1px solid var(--separator);
      border-radius: 8px;
      background: var(--window);
      box-shadow: 0 8px 24px rgba(0, 0, 0, 0.18);
    }
    .menu button { display: block; width: 100%; padding: 4px 10px; border: 0; border-radius: 5px; background: none; text-align: left; cursor: default; }
    .menu button:hover, .menu button:focus-visible { background: var(--accent); color: #ffffff; outline: none; }
    .spinner {
      flex: none;
      width: 12px;
      height: 12px;
      border: 2px solid var(--tertiary);
      border-top-color: transparent;
      border-radius: 50%;
      animation: turn 0.8s linear infinite;
    }
    @keyframes turn { to { transform: rotate(360deg); } }
    .wordpress { display: flex; flex-direction: column; align-items: center; gap: 8px; padding: 28px 16px; border-radius: 10px; background: var(--group); text-align: center; }
    .wordpress h2 { margin: 0; font-size: 15px; font-weight: 600; }
    .wordpress p { margin: 0; color: var(--secondary); }
    .wordpress .box { width: 100%; max-width: 460px; text-align: left; }
    </style>
    </head>
    <body>
    <header class="bar">
      <div class="title-block">
        <h1>{{TITLE}}</h1>
        <p class="subtitle" id="subtitle"></p>
      </div>
      <nav class="segmented page-switch" aria-label="Pages">
        <a class="segment" href="/">Dumps</a>
        <a class="segment" href="/logs" aria-current="page">Logs</a>
      </nav>
      <span class="bar-spacer"></span>
      <span class="live" id="live"><span class="live-dot"></span><span id="live-text">Connects to Nexus</span></span>
      <select class="control" id="place" aria-label="Site or workspace" disabled></select>
      <select class="control" id="file" aria-label="File" disabled></select>
    </header>
    <main>
      <section class="logs" id="logs" hidden>
        <div class="filter-bar">
          <label class="search-field">
            <svg viewBox="0 0 24 24" aria-hidden="true"><path d="M11 18a7 7 0 1 0 0-14 7 7 0 0 0 0 14z"/><path d="M20 20l-4-4"/></svg>
            <input type="search" id="search" placeholder="Search all files" aria-label="Search all files" autocomplete="off" spellcheck="false">
          </label>
          <span class="spinner" id="searching" hidden></span>
          <div class="levels" id="levels"></div>
          <span class="bar-spacer"></span>
          <label class="check"><input type="checkbox" id="group" checked><span>Group equal entries</span></label>
        </div>
        <div class="chips-bar" id="hidden-bar" hidden></div>
        <div class="chips-bar" id="search-bar" hidden></div>
        <div class="split" id="split">
          <div class="list" id="list" role="listbox" tabindex="0" aria-label="Entries"></div>
          <div class="detail log-detail" id="detail"></div>
        </div>
        <p class="no-rows" id="no-rows" hidden></p>
        <div class="status-bar" id="status">
          <span class="live-dot"></span>
          <span class="status-live" id="status-live">Live</span>
          <span class="status-count" id="status-count"></span>
          <button class="link older" id="older" type="button" hidden>Show older entries</button>
          <span class="status-files" id="status-files"></span>
        </div>
      </section>
      <div id="empty"></div>
      <p class="footer">This page shows the same entries as the Logs screen of Nexus. It only reads the logs. Clear a log in the app.</p>
    </main>
    <div class="menu" id="menu" role="menu" hidden></div>
    <div class="toast" id="toast" role="status" hidden></div>
    <script nonce="{{NONCE}}">

    """#

    private static let logic = #"""
    // The times and the texts of the Logs screen. They follow LogTimeText, LogRowText and
    // LogEntryDetail in Swift. The times are in the time zone of the browser, which is the time
    // zone of the Mac. This part uses no page.

    const weekdays = ["Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"];
    const months = ["January", "February", "March", "April", "May", "June", "July", "August", "September", "October", "November", "December"];

    function twoDigits(number) {
      return String(number).padStart(2, "0");
    }

    // HH:mm:ss, as LogTimeText.time.
    function clockText(milliseconds) {
      const date = new Date(milliseconds);
      return `${twoDigits(date.getHours())}:${twoDigits(date.getMinutes())}:${twoDigits(date.getSeconds())}`;
    }

    function sameDay(first, second) {
      return first.getFullYear() === second.getFullYear() && first.getMonth() === second.getMonth() && first.getDate() === second.getDate();
    }

    function dayBefore(date) {
      return new Date(date.getFullYear(), date.getMonth(), date.getDate() - 1);
    }

    // "Monday 23 November", with the year for a day of another year.
    function dayName(date, now) {
      const name = `${weekdays[date.getDay()]} ${date.getDate()} ${months[date.getMonth()]}`;
      return date.getFullYear() === now.getFullYear() ? name : `${name} ${date.getFullYear()}`;
    }

    // "Today · Monday 23 November", "Yesterday · Sunday 22 November" or "Friday 20 November", as
    // LogTimeText.dayTitle.
    function dayTitle(milliseconds, now = Date.now()) {
      const date = new Date(milliseconds);
      const today = new Date(now);
      const name = dayName(date, today);

      if (sameDay(date, today)) {
        return `Today · ${name}`;
      }

      return sameDay(date, dayBefore(today)) ? `Yesterday · ${name}` : name;
    }

    // The day line above a row. An entry without a time sorts with the entry above it. A file that
    // starts without times has no day for its first entries.
    function rowDay(row, now = Date.now()) {
      const moment = row.time ?? (row.sortTime > 0 ? row.sortTime : null);
      return moment == null ? "No time in the log" : dayTitle(moment, now);
    }

    // "Today at 14:18:31" or "Friday 20 November at 14:18:31", as LogTimeText.full.
    function fullTime(milliseconds, now = Date.now()) {
      const date = new Date(milliseconds);
      const today = new Date(now);

      if (sameDay(date, today)) {
        return `Today at ${clockText(milliseconds)}`;
      }

      if (sameDay(date, dayBefore(today))) {
        return `Yesterday at ${clockText(milliseconds)}`;
      }

      return `${dayTitle(milliseconds, now)} at ${clockText(milliseconds)}`;
    }

    // "yesterday at 14:18:31" or "on Sunday 13 December at 14:18:31", as LogTimeText.since.
    function sinceText(milliseconds, now = Date.now()) {
      const date = new Date(milliseconds);
      const today = new Date(now);

      if (sameDay(date, today)) {
        return `today at ${clockText(milliseconds)}`;
      }

      if (sameDay(date, dayBefore(today))) {
        return `yesterday at ${clockText(milliseconds)}`;
      }

      return `on ${dayName(date, today)} at ${clockText(milliseconds)}`;
    }

    // The Count line of a group: "12 times, the first at 13:52:10" on the same day.
    function countText(row, now = Date.now()) {
      if (row.firstTime == null) {
        return `${row.count} times`;
      }

      const sameDate = row.time != null && sameDay(new Date(row.time), new Date(row.firstTime));
      return `${row.count} times, the first ${sameDate ? `at ${clockText(row.firstTime)}` : sinceText(row.firstTime, now)}`;
    }

    // "13:18:31 UTC in the log" when the log has the times of another zone than the browser. The
    // time comes from the start of the entry, as the log wrote it.
    function logTimeNote(detail, file, browserOffset) {
      if (!detail.logTime || !file || file.kind !== "app" || file.zoneOffset === browserOffset) {
        return null;
      }

      const clock = /\d{2}:\d{2}:\d{2}/.exec(detail.logTime);
      return clock ? `${clock[0]} ${file.zone} in the log` : null;
    }

    // The color of a level tag, as LogLevelGroup.tint: red for an error and worse, orange for a
    // warning and gray for the other levels.
    function levelTone(group) {
      return group === "error" ? "red" : (group === "warning" ? "warning" : "gray");
    }

    // The second line of a row, as LogRowText.info: the exception and the first line of the app, or
    // the file name and the short context.
    function rowInfo(row, file) {
      const parts = [row.exception ?? file.name];

      if (row.source != null) {
        parts.push(`${row.source}:${row.sourceLine ?? 0}`);
      } else if (file.kind === "requests") {
        parts.push(`status ${row.level}`);
      }

      if (row.exception != null && row.source == null) {
        parts.push(file.name);
      }

      return [...parts, ...(row.context ?? [])].join(" · ");
    }

    // The text of the chip of hidden entries: at most 40 characters of the message.
    function hiddenText(message) {
      const characters = Array.from(message);
      return characters.length > 40 ? `${characters.slice(0, 40).join("")}…` : message;
    }

    // The frames of the app one by one and each run of frames in vendor/ as one row, as
    // LogFrameGroup. A frame keeps its index in the stack trace.
    function frameGroups(frames, showsVendor) {
      if (showsVendor) {
        return frames.map((frame, index) => ({ frame, index }));
      }

      const groups = [];
      let run = 0;
      let first = 0;

      frames.forEach((frame, index) => {
        if (frame.vendor && frame.file != null) {
          if (run === 0) {
            first = index;
          }

          run += 1;
          return;
        }

        if (run > 0) {
          groups.push({ vendor: run, first });
          run = 0;
        }

        groups.push({ frame, index });
      });

      if (run > 0) {
        groups.push({ vendor: run, first });
      }

      return groups;
    }

    // "2 frames of the app, 31 in vendor/".
    function stackText(frames) {
      const vendor = frames.filter((frame) => frame.vendor && frame.file != null).length;
      return `${count(frames.length - vendor, "frame")} of the app, ${vendor} in vendor/`;
    }

    // A value of the context on one line, as LogEntryText.plain.
    function plainValue(node) {
      switch (node.kind) {
        case "string":
          return `"${node.value ?? ""}"`;
        case "array": {
          const children = node.children ?? [];
          const keyed = children.some((child) => child.index !== true);
          const parts = children.map((child) => keyed ? `${child.key ?? ""}: ${plainValue(child)}` : plainValue(child));
          return keyed ? `{${parts.join(", ")}}` : `[${parts.join(", ")}]`;
        }
        default:
          return node.value ?? "";
      }
    }

    // The text of Copy as Markdown, as LogEntryDetail.markdown: the message, each exception with
    // the frames of the app, and the context.
    function entryMarkdown(detail, time, fileName) {
      const lines = [`**${detail.level || "log"}** ${time} in \`${fileName}\``, "", "```", detail.message, "```"];

      for (const exception of detail.exceptions ?? []) {
        const place = exception.file == null ? "" : ` at \`${exception.shortFile}:${exception.line ?? 0}\``;
        lines.push("", `**${exception.className}**${place}`, "");

        for (const frame of exception.frames) {
          if (!frame.vendor) {
            const file = frame.file == null ? "" : `${frame.shortFile}:${frame.line ?? 0} `;
            lines.push(`- \`#${frame.number ?? 0}\` ${file}\`${frame.call}\``);
          }
        }

        const vendor = exception.frames.filter((frame) => frame.vendor).length;

        if (vendor > 0) {
          lines.push(`- ${count(vendor, "frame")} in vendor/ left out`);
        }
      }

      const children = detail.context?.children ?? [];

      if (children.length > 0) {
        lines.push("", "Context:", "```", ...children.map((child) => `${child.key ?? ""}: ${plainValue(child)}`), "```");
      }

      return lines.join("\n");
    }

    """#

    private static let interface = #"""
    const token = document.querySelector('meta[name="nexus-token"]').content;
    const rowPage = {{ROW_PAGE}};
    const pollMilliseconds = {{POLL_MILLISECONDS}};
    const shownCharacters = {{SHOWN_CHARACTERS}};
    const contextOpenLimit = 10;
    const levelNames = { error: "Error", warning: "Warning", info: "Info", debug: "Debug" };
    const wordPressLines = "define( 'WP_DEBUG', true );\ndefine( 'WP_DEBUG_LOG', true );\ndefine( 'WP_DEBUG_DISPLAY', false );";
    // Two no-break spaces between the name and the size of a file. A menu shows two plain spaces as one.
    const wideSpace = "\xa0\xa0";

    // Debug is off by default and equal entries form one row, as on the Logs screen.
    const state = {
      places: null,
      placesAge: 0,
      placeChoices: "",
      fileChoices: "",
      placeID: new URLSearchParams(location.search).get("place"),
      hiddenByPlace: new Map(),
      fileKey: null,
      levels: new Set(["error", "warning", "info"]),
      hidesTestRuns: true,
      hidden: new Map(),
      groups: true,
      search: "",
      searchTimer: null,
      limit: rowPage,
      data: null,
      problem: null,
      generation: 0,
      timer: null,
      polling: false,
      pollAgain: false,
      lostConnection: false,
      openID: null,
      openHash: null,
      detail: null,
      detailFor: null,
      detailProblem: null,
      detailGeneration: 0,
      vendorShown: new Set(),
      rows: new Map(),
      emptyShown: null,
      today: new Date().toDateString(),
    };

    function currentData() {
      return state.data && state.data.place === state.placeID ? state.data : null;
    }

    function fileOf(key) {
      return currentData()?.files.find((file) => file.key === key) ?? null;
    }

    function rowOf(id) {
      return currentData()?.rows.find((row) => row.id === id) ?? null;
    }

    // The address keeps the place. So a reload and a bookmark show the same site.
    function showPlaceInAddress() {
      const url = new URL(location.href);

      if (state.placeID) {
        url.searchParams.set("place", state.placeID);
      } else {
        url.searchParams.delete("place");
      }

      history.replaceState(null, "", url);
    }

    // The answers of Nexus

    // null when Nexus does not answer. An answer with an error gives its message as problem.
    async function getJSON(url) {
      let response;

      try {
        response = await fetch(url);
      } catch {
        setLive(false);
        return null;
      }

      setLive(true);
      const answer = await response.json().catch(() => null);

      if (!response.ok || answer === null) {
        return { problem: answer?.message ?? "Nexus did not load the logs.", status: response.status };
      }

      return answer;
    }

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

    // After a lost connection the page loads again, because Nexus started again with a new token.
    function setLive(isLive) {
      if (isLive && state.lostConnection) {
        location.reload();
        return;
      }

      state.lostConnection = !isLive;
      $("live").classList.toggle("on", isLive);
      $("live-text").textContent = isLive ? "Updates live" : "Waits for Nexus";
      $("status").classList.toggle("on", isLive);
      $("status-live").textContent = isLive ? "Live" : "Waits for Nexus";
    }

    function entriesURL(known) {
      const parameters = new URLSearchParams({
        place: state.placeID,
        levels: [...state.levels].join(","),
        tests: state.hidesTestRuns ? "hidden" : "shown",
        group: state.groups ? "1" : "0",
        limit: String(state.limit),
      });

      if (state.fileKey) {
        parameters.set("file", state.fileKey);
      }

      if (state.search.trim()) {
        parameters.set("search", state.search);
      }

      if (state.hidden.size > 0) {
        parameters.set("hidden", [...state.hidden.keys()].join(","));
      }

      if (known) {
        parameters.set("known", known);
      }

      return `/api/logs/entries?${parameters}`;
    }

    // A change of a filter asks Nexus at once. The answer to an older question then goes.
    function refresh() {
      state.generation += 1;
      render();
      poll();
    }

    function poll() {
      clearTimeout(state.timer);
      state.timer = null;

      if (state.polling) {
        state.pollAgain = true;
        return;
      }

      run();
    }

    // The list of the places loads again every 10 seconds. A page in a tab that the browser hides
    // asks for nothing.
    async function run() {
      state.polling = true;

      try {
        if (!document.hidden) {
          state.placesAge += 1;

          if (state.places === null || state.placesAge > 5) {
            await loadPlaces();
          }

          if (state.placeID) {
            await loadEntries();
          }
        }
      } finally {
        state.polling = false;

        if (state.pollAgain) {
          state.pollAgain = false;
          poll();
        } else {
          state.timer = setTimeout(poll, pollMilliseconds);
        }
      }
    }

    async function loadPlaces() {
      state.placesAge = 0;
      const answer = await getJSON("/api/logs/places");

      if (answer === null || answer.problem) {
        return;
      }

      state.places = answer.places;

      if (!state.places.some((place) => place.id === state.placeID)) {
        choosePlace(state.places[0]?.id ?? null);
        return;
      }

      render();
    }

    // The version tells Nexus what the page has. Nexus then answers "unchanged" while nothing
    // changed. A place that is gone loads the list of the places again.
    async function loadEntries() {
      const generation = state.generation;
      const place = state.placeID;
      const data = currentData();
      const known = data && data.generation === generation ? data.version : null;
      const answer = await getJSON(entriesURL(known));

      if (generation !== state.generation || place !== state.placeID || answer === null) {
        return;
      }

      if (answer.problem) {
        state.problem = answer.problem;

        if (answer.status === 404) {
          state.places = null;
        }

        render();
        return;
      }

      const hadProblem = state.problem !== null;
      state.problem = null;

      if (answer.unchanged) {
        if (hadProblem || state.today !== new Date().toDateString()) {
          render();
        }

        return;
      }

      answer.generation = generation;
      state.data = answer;
      state.fileKey = answer.file ?? null;
      dataChanged();
    }

    // The open entry stays open while it is in the list. A newer entry of its group takes its place.
    function dataChanged() {
      const rows = state.data.rows;

      if (!rows.some((row) => row.id === state.openID)) {
        const same = state.openHash === null ? null : rows.find((row) => row.hash === state.openHash);
        openRow(same?.id ?? rows[0]?.id ?? null);
      }

      render();
    }

    // The detail of an entry loads again when its entry grows.
    async function loadDetail() {
      const row = rowOf(state.openID);

      if (!row) {
        return;
      }

      const signature = `${row.id} ${row.length}`;

      if (state.detailFor === signature) {
        return;
      }

      state.detailFor = signature;
      state.detailGeneration += 1;
      const generation = state.detailGeneration;
      const parameters = new URLSearchParams({ place: state.placeID, file: row.file, offset: String(row.offset) });
      const answer = await getJSON(`/api/logs/entry?${parameters}`);

      if (generation !== state.detailGeneration) {
        return;
      }

      if (answer === null) {
        state.detailFor = null;
        return;
      }

      if (answer.problem) {
        state.detailProblem = answer.problem;
      } else {
        state.detail = answer;
        state.detailProblem = null;
      }

      renderDetail();
    }

    // The choices

    // Another place starts with all files and without a search. Its hidden entries come back, as
    // in the app.
    function choosePlace(id) {
      if (id === state.placeID && state.data !== null) {
        return;
      }

      if (state.placeID) {
        state.hiddenByPlace.set(state.placeID, state.hidden);
      }

      state.placeID = id;
      state.hidden = state.hiddenByPlace.get(id) ?? new Map();
      state.fileKey = null;
      state.search = "";
      $("search").value = "";
      state.limit = rowPage;
      state.data = null;
      state.problem = null;
      openRow(null);
      showPlaceInAddress();
      refresh();
    }

    function chooseFile(key) {
      state.fileKey = key;
      state.limit = rowPage;
      refresh();
    }

    function toggleLevel(group) {
      if (state.levels.has(group)) {
        state.levels.delete(group);
      } else {
        state.levels.add(group);
      }

      refresh();
    }

    function setSearch(text) {
      clearTimeout(state.searchTimer);

      if (text === state.search) {
        return;
      }

      state.search = text;
      refresh();
    }

    function findAll(value) {
      $("search").value = value;
      setSearch(value);
    }

    function hideEntriesLike(row) {
      state.hidden.set(row.hash, hiddenText(row.message));
      refresh();
    }

    function openRow(id) {
      if (id === state.openID) {
        return;
      }

      state.openID = id;
      state.openHash = rowOf(id)?.hash ?? null;
      state.detail = null;
      state.detailFor = null;
      state.detailProblem = null;
      state.detailGeneration += 1;
      state.vendorShown = new Set();
    }

    // Without an exception the log file opens at the line of the entry. nexusd finds the file
    // itself. The page sends no path.
    function openInEditor(target) {
      const row = rowOf(state.openID);

      if (row) {
        post("/api/logs/open", { place: state.placeID, file: row.file, offset: row.offset, ...target });
      }
    }

    // The rendering

    function render() {
      $("subtitle").textContent = subtitleText();
      renderPlaces();
      renderFiles();
      renderMain();
    }

    function subtitleText() {
      if (state.places === null) {
        return "";
      }

      if (state.places.length === 0) {
        return "No sites";
      }

      const data = currentData();
      return data ? `${data.place} · ${count(data.files.length, "file")} · ${data.size}` : (state.placeID ?? "");
    }

    // The options change only with the places. So an open menu stays open while entries arrive.
    function renderPlaces() {
      const select = $("place");
      const places = state.places ?? [];
      const key = JSON.stringify(places.map((place) => [place.id, place.label]));

      if (key !== state.placeChoices) {
        state.placeChoices = key;
        select.replaceChildren(...places.map((place) => new Option(place.label, place.id)));
      }

      select.disabled = places.length === 0;
      select.value = state.placeID ?? "";
    }

    // "All files", each file of the app with its size, then the PHP errors, the output and the
    // requests. A new size changes only the text of its option.
    function renderFiles() {
      const select = $("file");
      const files = currentData()?.files ?? [];
      const appFiles = files.filter((file) => file.kind === "app");
      const others = files.filter((file) => file.kind !== "app");
      const key = JSON.stringify(files.map((file) => [file.key, file.name]));

      if (key !== state.fileChoices) {
        state.fileChoices = key;
        const options = [new Option("All files", "")];

        if (appFiles.length > 0) {
          options.push(document.createElement("hr"), ...appFiles.map((file) => new Option(file.name, file.key)));
        }

        if (others.length > 0) {
          options.push(document.createElement("hr"), ...others.map((file) => new Option(file.name, file.key)));
        }

        select.replaceChildren(...options);
      }

      for (const file of appFiles) {
        const option = [...select.options].find((item) => item.value === file.key);
        const text = `${file.name}${wideSpace}${file.size}`;

        if (option && option.textContent !== text) {
          option.textContent = text;
        }
      }

      select.disabled = files.length === 0;
      select.value = state.fileKey ?? "";
    }

    function renderMain() {
      const data = currentData();
      const showsLogs = state.problem === null && data !== null && data.files.length > 0;
      $("logs").hidden = !showsLogs;
      renderEmpty(data);

      if (!showsLogs) {
        return;
      }

      renderFilterBar(data);
      renderHiddenBar(data);
      renderSearchBar(data);
      renderList(data);
      renderDetail();
      renderStatus(data);
      loadDetail();
    }

    function emptyText(data) {
      if (state.problem) {
        return state.problem;
      }

      if (state.places === null || (state.places.length > 0 && data === null)) {
        return "Nexus reads the logs.";
      }

      if (state.places.length === 0) {
        return "Add a site to see the logs of its app.";
      }

      if (data.files.length > 0) {
        return null;
      }

      if (data.kind === "wordpress") {
        return "wordpress";
      }

      return data.kind === "proxy" ? "A site that sends its requests to a port has no logs in Nexus." : "This site has no log files yet. Each file that the app writes shows here.";
    }

    // "Logs States" in the design: WordPress without WP_DEBUG_LOG, and a site without log files.
    function renderEmpty(data) {
      const text = emptyText(data);

      if (text === state.emptyShown) {
        return;
      }

      state.emptyShown = text;
      const empty = $("empty");
      empty.hidden = text === null;

      if (text === null) {
        empty.replaceChildren();
        return;
      }

      empty.replaceChildren(text === "wordpress" ? wordPressBlock() : element("p", "empty-line", text));
    }

    function wordPressBlock() {
      const block = element("div", "wordpress");
      const button = element("button", "control", "Copy lines");
      button.type = "button";
      button.addEventListener("click", () => copyText(wordPressLines, "Nexus copied the lines."));
      block.append(element("h2", null, "WordPress writes no log file"), element("p", null, "Add these lines to wp-config.php, above \"That's all, stop editing!\"."), textBox(wordPressLines), button);
      return block;
    }

    // A level chip shows … while Nexus counts the entries of a large file.
    function renderFilterBar(data) {
      const levels = $("levels");

      if (levels.childElementCount === 0) {
        for (const [group, name] of Object.entries(levelNames)) {
          const chip = element("button", "chip");
          chip.type = "button";
          chip.dataset.group = group;
          chip.append(element("span", `dot ${levelTone(group)}`), element("span", null, name), element("span", "chip-count"));
          chip.addEventListener("click", () => toggleLevel(group));
          levels.append(chip);
        }
      }

      for (const chip of levels.children) {
        const group = chip.dataset.group;
        const isOn = state.levels.has(group);
        chip.classList.toggle("off", !isOn);
        chip.setAttribute("aria-pressed", String(isOn));
        chip.title = `${isOn ? "Hide" : "Show"} the ${levelNames[group].toLowerCase()} entries`;
        chip.querySelector(".chip-count").textContent = data.counting == null ? String(data.levelCounts[group] ?? 0) : "…";
      }

      $("group").checked = state.groups;
      $("searching").hidden = !searchIsPending(data);
    }

    function searchIsPending(data) {
      return state.search.trim() !== "" && data.generation !== state.generation;
    }

    function hiddenChip(text, help, action) {
      const chip = element("button", "hidden-chip");
      chip.type = "button";
      chip.title = help;
      chip.setAttribute("aria-label", `${text}. ${help}`);
      chip.append(element("span", "chip-text", text), icon("close"));
      chip.addEventListener("click", action);
      return chip;
    }

    // A click on the x of a chip shows its entries again.
    function renderHiddenBar(data) {
      const bar = $("hidden-bar");
      const hidden = [...state.hidden.entries()].sort((first, second) => (first[1] < second[1] ? -1 : (first[1] > second[1] ? 1 : 0)));
      const testRuns = state.hidesTestRuns ? data.hiddenTestRuns : 0;
      bar.hidden = hidden.length === 0 && testRuns === 0;
      const signature = JSON.stringify([testRuns, hidden.map(([hash, text]) => [hash, text, data.hiddenByMessage[hash] ?? 0])]);

      if (bar.hidden || bar.dataset.shown === signature) {
        return;
      }

      bar.dataset.shown = signature;
      const chips = [];

      if (testRuns > 0) {
        chips.push(hiddenChip(`Test runs · ${testRuns}`, "Show the entries of test runs. They have the tag testing.", () => {
          state.hidesTestRuns = false;
          refresh();
        }));
      }

      for (const [hash, text] of hidden) {
        chips.push(hiddenChip(`“${text}” · ${data.hiddenByMessage[hash] ?? 0}`, "Show these entries again", () => {
          state.hidden.delete(hash);
          refresh();
        }));
      }

      bar.replaceChildren(element("span", "chips-label", "Hidden:"), ...chips);
    }

    // "Logs Entry States": the count of each file after a search. A click shows only that file.
    function renderSearchBar(data) {
      const bar = $("search-bar");
      bar.hidden = state.search.trim() === "" || data.searchCounts == null || searchIsPending(data);
      const signature = JSON.stringify([data.matching, data.searchCounts, state.fileKey]);

      if (bar.hidden || bar.dataset.shown === signature) {
        return;
      }

      bar.dataset.shown = signature;

      const chips = data.files.map((file) => {
        const found = data.searchCounts[file.key] ?? 0;
        const chosen = state.fileKey === file.key;
        const chip = element("button", chosen ? "file-chip chosen" : "file-chip");
        chip.type = "button";
        chip.disabled = found === 0;
        chip.title = chosen ? "Show the entries of all files" : `Show only the entries of ${file.name}`;
        chip.append(element("span", null, file.name), element("span", "chip-count", String(found)));
        chip.addEventListener("click", () => chooseFile(chosen ? null : file.key));
        return chip;
      });

      bar.replaceChildren(element("span", "chips-label", `${count(data.matching, "entry", "entries")}:`), ...chips);
    }

    // A row is made again only when its entry or its selection changed.
    function renderList(data) {
      const hasRows = data.rows.length > 0;
      $("split").hidden = !hasRows;
      $("no-rows").hidden = hasRows;
      $("no-rows").textContent = data.total === 0 ? "The log has no entries." : "No entries match the filters.";

      if (!hasRows) {
        return;
      }

      const now = Date.now();
      const kept = new Map();
      const nodes = [];
      let lastDay = null;
      state.today = new Date(now).toDateString();

      for (const row of data.rows) {
        const day = rowDay(row, now);

        if (day !== lastDay) {
          nodes.push(element("div", "day", day));
          lastDay = day;
        }

        const selected = row.id === state.openID;
        const file = fileOf(row.file);
        const signature = `${selected} ${file?.name ?? ""} ${JSON.stringify(row)}`;
        const cached = state.rows.get(row.id);
        const node = cached?.signature === signature ? cached.node : logRow(row, file, selected);
        kept.set(row.id, { signature, node });
        nodes.push(node);
      }

      state.rows = kept;
      reuseDays($("list"), nodes);
      show($("list"), nodes);
    }

    // A day line that did not change keeps its element. So the list is not laid out again.
    function reuseDays(list, nodes) {
      const known = new Map([...list.querySelectorAll(".day")].map((day) => [day.textContent, day]));

      nodes.forEach((node, index) => {
        if (node.classList.contains("day") && known.has(node.textContent)) {
          nodes[index] = known.get(node.textContent);
          known.delete(node.textContent);
        }
      });
    }

    function levelTag(level, group) {
      const classes = { red: "tag red mono", warning: "tag warning", gray: "tag gray mono" };
      return element("span", classes[levelTone(group)], level);
    }

    function logRow(row, file, selected) {
      const node = element("div", selected ? "row selected" : "row");
      node.setAttribute("role", "option");
      node.setAttribute("aria-selected", String(selected));
      node.dataset.id = row.id;

      const top = element("div", "row-line");

      if (row.level) {
        top.append(levelTag(row.level, row.group));
      }

      if (row.testRun) {
        const tag = element("span", "tag gray mono", "testing");
        tag.title = "A test run wrote this entry.";
        top.append(tag);
      }

      top.append(element("span", "row-message", row.message || " "));

      if (row.time != null) {
        top.append(element("span", "row-time", clockText(row.time)));
      }

      const bottom = element("div", "row-line");
      bottom.append(element("span", "small summary", file ? rowInfo(row, file) : ""));

      if (row.count > 1) {
        const tag = element("span", "tag gray mono", `×${row.count}`);
        tag.title = `${row.count} equal entries`;
        bottom.append(tag);
      }

      node.append(top, bottom);
      return node;
    }

    function renderStatus(data) {
      $("status-count").textContent = data.counting == null ? `Shows ${data.rows.length} of ${count(data.total, "entry", "entries")}` : `Counting: ${Math.floor(data.counting * 100)}%`;
      $("older").hidden = !(data.rowCount > data.rows.length);
      const chosen = fileOf(state.fileKey);
      $("status-files").textContent = chosen ? chosen.name : data.files.map((file) => file.name).join(", ");
    }

    // The open entry is made again only when it changed. So an open node of the tree stays open
    // while entries arrive.
    function renderDetail() {
      const container = $("detail");
      const row = rowOf(state.openID);
      const file = row ? fileOf(row.file) : null;
      const detail = row && state.detail?.id === row.id ? state.detail : null;
      const signature = JSON.stringify([row?.id ?? null, row?.count ?? null, row?.firstTime ?? null, detail?.length ?? null, detail ? null : state.detailProblem, [...state.vendorShown], state.today, file?.name ?? null]);

      if (container.dataset.shown === signature) {
        return;
      }

      const sameEntry = container.dataset.id === (row?.id ?? "");
      const scroll = container.scrollTop;
      container.dataset.shown = signature;
      container.dataset.id = row?.id ?? "";

      if (!row) {
        container.replaceChildren(element("p", "center", "Choose an entry."));
        return;
      }

      if (!detail) {
        container.replaceChildren(element("p", "center", state.detailProblem ?? "Nexus loads the entry."));
        return;
      }

      container.replaceChildren(...detailNodes(detail, row, file));

      if (sameEntry) {
        container.scrollTop = scroll;
      }
    }

    function detailNodes(detail, row, file) {
      const nodes = [detailHead(detail, row, file)];

      detail.exceptions.forEach((exception, index) => {
        nodes.push(exceptionSection(detail, exception, index));

        if (exception.frames.length > 0) {
          nodes.push(stackSection(exception, index));
        }
      });

      if ((detail.context?.children?.length ?? 0) > 0) {
        nodes.push(contextSection(detail));
      }

      return nodes;
    }

    function headLine(key, value) {
      const line = element("div", "head-line");
      line.append(element("span", "head-key", key), element("span", "head-value", value));
      return line;
    }

    function detailTime(detail) {
      return detail.time == null ? "No time in the log" : fullTime(detail.time);
    }

    function detailHead(detail, row, file) {
      const head = element("div", "head");
      const title = element("div", "head-title");

      if (detail.level) {
        title.append(levelTag(detail.level, detail.group));
      }

      title.append(element("h2", null, detail.message || row.message), copyMenu(detail, file));
      head.append(title);

      if (detail.isCut) {
        const line = element("div", "cut-line");
        const button = element("button", "link", "Open in your editor");
        button.type = "button";
        button.addEventListener("click", () => openInEditor({}));
        line.append(icon("scissors"), element("span", null, `Nexus shows ${shownCharacters} of the ${detail.characters} characters of this entry.`), button);
        head.append(line);
      }

      if (detail.time != null) {
        const line = headLine("Time", detailTime(detail));
        const note = logTimeNote(detail, file, -new Date().getTimezoneOffset() * 60);

        if (note) {
          line.append(element("span", "head-extra", note));
        }

        head.append(line);
      }

      if (row.count > 1) {
        head.append(headLine("Count", countText(row)));
      }

      const fileLine = element("div", "head-line");
      const name = file?.name ?? "";
      const link = element("button", "head-value link", detail.line > 0 ? `${name}, line ${detail.line}` : name);
      link.type = "button";
      link.title = file ? `Open ${file.path} in your editor` : "";
      link.addEventListener("click", () => openInEditor({}));
      fileLine.append(element("span", "head-key", "File"), link);
      head.append(fileLine);

      if (detail.channel) {
        head.append(headLine("Channel", detail.channel));
      }

      return head;
    }

    function copyMenu(detail, file) {
      const button = element("button", "icon-button menu-button");
      button.type = "button";
      button.title = "Copy this entry";
      button.setAttribute("aria-label", "Copy this entry");
      button.setAttribute("aria-haspopup", "menu");
      button.append(icon("copy"), icon("chevronDown"));

      button.addEventListener("click", (event) => {
        event.stopPropagation();
        const place = button.getBoundingClientRect();

        showMenu([
          ["Copy", () => copyText(detail.text, "Nexus copied the entry.")],
          ["Copy as Markdown", () => copyText(entryMarkdown(detail, detailTime(detail), file?.name ?? ""), "Nexus copied the entry as Markdown.")],
        ], place.right, place.bottom + 4, true);
      });

      return button;
    }

    function sourceLink(shortFile, path, line, target) {
      const link = element("button", "link");
      link.type = "button";
      link.title = `Open ${path} in your editor`;
      link.append(element("bdi", null, line == null ? shortFile : `${shortFile}:${line}`));
      link.addEventListener("click", () => openInEditor(target));
      return link;
    }

    // The namespace of the class is gray. A previous exception and a message that the title does
    // not show get their message.
    function exceptionSection(detail, exception, index) {
      const section = element("div", "section");
      const name = element("div", "class-name");
      name.append(element("span", "soft", exception.namespace), element("span", "bold", exception.shortName));
      section.append(element("div", "section-title", index > 0 ? "Previous exception" : "Exception"), name);

      if (index > 0 || exception.message !== detail.message) {
        section.append(element("div", "exception-message", exception.message));
      }

      if (exception.file != null) {
        const source = element("div", "source-line");
        source.append(icon("file"), sourceLink(exception.shortFile, exception.file, exception.line, { exception: index }));
        section.append(source);
      }

      return section;
    }

    // The frames in vendor/ form one row until a click shows them.
    function stackSection(exception, index) {
      const section = element("div", "section");
      const head = element("div", "section-head");
      head.append(element("span", "section-title", "Stack trace"), element("span", "section-note", stackText(exception.frames)));
      section.append(head);

      for (const group of frameGroups(exception.frames, state.vendorShown.has(index))) {
        section.append(group.frame ? frameLine(group.frame, group.index, index) : vendorLine(group.vendor, index));
      }

      return section;
    }

    function frameLine(frame, frameIndex, exceptionIndex) {
      const line = element("div", "frame");
      line.append(element("span", "frame-number", frame.number == null ? "" : `#${frame.number}`));

      if (frame.file != null) {
        line.append(sourceLink(frame.shortFile, frame.file, frame.line, { exception: exceptionIndex, frame: frameIndex }));
      }

      const call = element("span", "frame-call", frame.call);
      call.title = frame.call;
      line.append(call);
      return line;
    }

    function vendorLine(number, exceptionIndex) {
      const button = element("button", "vendor-row");
      button.type = "button";
      button.title = "Show the frames in vendor/";
      button.append(element("span", "frame-number", "›"), element("span", null, `${count(number, "frame")} in vendor/`));

      button.addEventListener("click", () => {
        state.vendorShown.add(exceptionIndex);
        renderDetail();
      });

      return button;
    }

    // The context with the tree of the dumps. A value of request_id, trace_id and the other ID keys
    // gets "Find all".
    function contextSection(detail) {
      const section = element("div", "section");
      const box = element("div", "box");

      for (const node of detail.context.children) {
        const tree = treeNode(node, (node.children?.length ?? 0) <= contextOpenLimit);
        const id = detail.ids.find((item) => item.key === node.key && item.value === node.value);

        if (id && tree.classList.contains("node-line")) {
          const button = element("button", "find-all");
          button.type = "button";
          button.title = `Find all entries with ${id.key} ${id.value}`;
          button.append(icon("search"), "Find all");
          button.addEventListener("click", () => findAll(id.value));
          tree.append(button);
        }

        box.append(tree);
      }

      section.append(element("div", "section-title", "Context and extra"), box);
      return section;
    }

    // The menu of the copy button and of a row

    function showMenu(items, x, y, alignsRight) {
      const menu = $("menu");

      menu.replaceChildren(...items.map(([label, action]) => {
        const item = element("button", null, label);
        item.type = "button";
        item.setAttribute("role", "menuitem");

        item.addEventListener("click", (event) => {
          event.stopPropagation();
          hideMenu();
          action();
        });

        return item;
      }));

      menu.hidden = false;
      const left = alignsRight ? x - menu.offsetWidth : x;
      menu.style.left = `${Math.max(8, Math.min(left, window.innerWidth - menu.offsetWidth - 8))}px`;
      menu.style.top = `${Math.max(8, Math.min(y, window.innerHeight - menu.offsetHeight - 8))}px`;
      menu.querySelector("button")?.focus();
    }

    function hideMenu() {
      $("menu").hidden = true;
    }

    $("menu").addEventListener("keydown", (event) => {
      const items = [...$("menu").querySelectorAll("button")];
      const index = items.indexOf(document.activeElement);

      if (event.key === "ArrowDown" || event.key === "ArrowUp") {
        event.preventDefault();
        items[(index + (event.key === "ArrowDown" ? 1 : items.length - 1)) % items.length]?.focus();
      }
    });

    document.addEventListener("click", (event) => {
      if (!$("menu").contains(event.target)) {
        hideMenu();
      }
    });

    document.addEventListener("keydown", (event) => {
      if (event.key === "Escape") {
        hideMenu();
      }
    });

    window.addEventListener("blur", hideMenu);
    window.addEventListener("resize", hideMenu);
    $("list").addEventListener("scroll", hideMenu);
    $("detail").addEventListener("scroll", hideMenu);

    // The controls

    $("place").addEventListener("change", (event) => choosePlace(event.target.value));
    $("file").addEventListener("change", (event) => chooseFile(event.target.value || null));

    $("group").addEventListener("change", (event) => {
      state.groups = event.target.checked;
      refresh();
    });

    $("search").addEventListener("input", (event) => {
      clearTimeout(state.searchTimer);
      const text = event.target.value;
      state.searchTimer = setTimeout(() => setSearch(text), 300);
    });

    $("older").addEventListener("click", () => {
      state.limit += rowPage;
      refresh();
    });

    $("list").addEventListener("click", (event) => {
      const node = event.target.closest(".row");

      if (!node || node.dataset.id === state.openID) {
        return;
      }

      openRow(node.dataset.id);
      renderMain();
    });

    // "Hide entries like this" and "Hide test runs", as the menu of a row in the app.
    $("list").addEventListener("contextmenu", (event) => {
      const node = event.target.closest(".row");
      const row = node ? rowOf(node.dataset.id) : null;

      if (!row) {
        return;
      }

      event.preventDefault();
      const items = [["Hide entries like this", () => hideEntriesLike(row)]];

      if (row.testRun) {
        items.push(["Hide test runs", () => {
          state.hidesTestRuns = true;
          refresh();
        }]);
      }

      showMenu(items, event.clientX, event.clientY, false);
    });

    // The arrow keys move through the list, as in the app.
    $("list").addEventListener("keydown", (event) => {
      if (event.key !== "ArrowDown" && event.key !== "ArrowUp") {
        return;
      }

      event.preventDefault();
      const rows = currentData()?.rows ?? [];
      const index = rows.findIndex((row) => row.id === state.openID);
      const next = rows[event.key === "ArrowDown" ? index + 1 : Math.max(index - 1, 0)];

      if (!next) {
        return;
      }

      openRow(next.id);
      renderMain();
      $("list").querySelector(".row.selected")?.scrollIntoView({ block: "nearest" });
    });

    document.addEventListener("visibilitychange", () => {
      if (!document.hidden) {
        poll();
      }
    });

    render();
    poll();

    """#
}
