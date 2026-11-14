import Foundation
import NexusCore

// The web page of the dumps: one HTML file with its style and its script. The design is the frame
// "Dumps Web Page" in nexus.pen. The page shows the same list, tabs and tree as the Dumps screen
// of the app and follows the colors of macOS in light and dark mode.
//
// The script puts each value of an entry into the page as text, never as HTML. So an entry cannot
// run a script in the page. The token goes with each request that changes something.
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
        filled(markup + logic + interface + "</script>\n</body>\n</html>\n", token: token, nonce: nonce, title: title)
    }

    // The part of the script that uses no page: the marks of the queries and the texts. The tests
    // run it in JavaScriptCore and compare it with QueryMarks and DumpText.
    static var logicScript: String {
        filled(logic, token: "", nonce: "", title: "")
    }

    // The marks use the limits of QueryMarks. So the page and the app mark the same queries.
    private static func filled(_ text: String, token: String, nonce: String, title: String) -> String {
        let values = [
            "{{TOKEN}}": token,
            "{{NONCE}}": nonce,
            "{{TITLE}}": title,
            "{{REQUEST_LIMIT}}": String(DumpStore.requestLimit),
            "{{OPEN_LIMIT}}": String(DumpNode.openChildrenLimit),
            "{{SLOW_MILLISECONDS}}": String(QueryMarks.slowMilliseconds),
            "{{DUPLICATE_COUNT}}": String(QueryMarks.duplicateCount),
            "{{N_PLUS_ONE_COUNT}}": String(QueryMarks.nPlusOneCount),
        ]

        return values.reduce(text) { page, value in
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
      --red-soft: rgba(201, 38, 28, 0.1);
      --gray-soft: rgba(0, 0, 0, 0.06);
      --track: rgba(0, 0, 0, 0.05);
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
        --red-soft: rgba(255, 107, 97, 0.16);
        --gray-soft: rgba(255, 255, 255, 0.1);
        --track: rgba(255, 255, 255, 0.06);
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
    .tag.mono, .tag.warning { font-family: ui-monospace, "SF Mono", Menlo, monospace; }
    .tag.warning { background: var(--warning); color: var(--orange-text); }
    .tag.red { background: var(--red-soft); color: var(--red-text); }
    .tag.gray { background: var(--gray-soft); color: var(--secondary); }
    .detail { flex: 1; min-width: 0; display: flex; flex-direction: column; }
    .head { padding: 12px 16px; border-bottom: 1px solid var(--separator); }
    .head-title { display: flex; align-items: center; gap: 8px; }
    .head-title h2 { flex: 1; min-width: 0; margin: 0; font-size: 15px; font-weight: 600; overflow-wrap: anywhere; }
    .head-line { display: flex; gap: 8px; margin-top: 6px; font-size: 12px; }
    .head-key { width: 48px; flex: none; color: var(--secondary); }
    .head-value { min-width: 0; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
    .head-value.failed { color: var(--red-text); }
    button.head-value { padding: 0; border: 0; background: none; text-align: left; }
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
    .tabs-bar { display: flex; align-items: center; gap: 12px; padding: 10px 16px; border-bottom: 1px solid var(--separator); }
    .segmented { display: inline-flex; gap: 2px; padding: 2px; border: 1px solid var(--separator); border-radius: 8px; background: var(--track); }
    .segment { padding: 3px 12px; border: 0; border-radius: 6px; background: none; cursor: default; }
    .segment[aria-selected="true"] { background: var(--control); box-shadow: 0 0.5px 1.5px rgba(0, 0, 0, 0.15); font-weight: 600; }
    .tabs-total { margin-left: auto; font-size: 11px; color: var(--secondary); white-space: nowrap; }
    .entries { flex: 1; overflow-y: auto; padding: 16px; }
    .entry + .entry { margin-top: 14px; }
    .source { display: flex; align-items: center; gap: 6px; font-size: 12px; }
    .source + .source { margin-top: 4px; }
    .message { flex: 1; min-width: 0; overflow-wrap: anywhere; }
    .code { font: 12px ui-monospace, "SF Mono", Menlo, monospace; }
    .time { font-size: 11px; color: var(--secondary); white-space: nowrap; }
    .time.slow { color: var(--red-text); font-weight: 600; }
    .member { display: flex; align-items: center; gap: 6px; padding: 6px 0 0; margin-top: 6px; border-top: 1px solid var(--separator); }
    .member-sql { flex: 1; min-width: 0; }
    .member .time { flex: none; font-family: -apple-system, BlinkMacSystemFont, system-ui, sans-serif; }
    .hint { margin-top: 6px; font-size: 11px; color: var(--secondary); }
    .jump { flex: none; padding: 0; border: 0; background: none; color: var(--accent); font-size: 12px; white-space: nowrap; }
    .jump:hover { text-decoration: underline; }
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
      <p class="footer">Nexus keeps the newest {{REQUEST_LIMIT}} requests. A click on a file opens it in your editor. Test runs send nothing.</p>
    </main>
    <dialog id="confirm">
      <h2 id="confirm-title"></h2>
      <p>This removes their dumps, queries, log lines and jobs. You cannot get them back.</p>
      <div class="buttons">
        <button class="control" id="confirm-cancel" type="button">Cancel</button>
        <button class="control danger" id="confirm-clear" type="button">Clear</button>
      </div>
    </dialog>
    <div class="toast" id="toast" role="status" hidden></div>
    <script nonce="{{NONCE}}">

    """#

    private static let logic = #"""
    "use strict";

    // The texts and the marks of the queries. They follow DumpText and QueryMarks in Swift, as the
    // app and nexus dumps show them. This part uses no page.

    const slowMilliseconds = {{SLOW_MILLISECONDS}};
    const duplicateCount = {{DUPLICATE_COUNT}};
    const nPlusOneCount = {{N_PLUS_ONE_COUNT}};
    const kinds = ["dump", "query", "log", "job"];
    const errorLevels = new Set(["error", "critical", "alert", "emergency"]);
    const phpErrorDetails = new Set(["PHP error", "PHP fatal error"]);

    function count(number, noun, plural = `${noun}s`) {
      return number === 1 ? `1 ${noun}` : `${number} ${plural}`;
    }

    // "184 ms", "1.3 s" or "1 min 5 s", as DumpedRequest.durationText.
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

    // "0.84 ms", "9.6 ms", "142 ms" or "1.4 s", as DumpEntryText.milliseconds: a short time gets
    // more digits, without zeros at the end. The number format of Swift rounds a half to the even
    // digit. So the page does that too. locale is for the tests.
    function millisecondsText(milliseconds, locale = undefined) {
      if (Math.round(milliseconds) >= 1000) {
        return durationText(milliseconds / 1000);
      }

      const digits = milliseconds < 1 ? 2 : (milliseconds < 100 ? 1 : 0);
      const format = new Intl.NumberFormat(locale, { maximumFractionDigits: digits, useGrouping: false, roundingMode: "halfEven" });
      return `${format.format(milliseconds)} ms`;
    }

    // DumpedRequest.displayMethod: JOB, CRON or ACTION for a job of a worker.
    function displayMethod(request) {
      switch (request.kind) {
        case "command": return "CLI";
        case "job": return { cron: "CRON", action: "ACTION" }[request.job?.system] ?? "JOB";
        default: return request.method ?? "";
      }
    }

    // A job has no title of a method. Its name is the title.
    function titleText(request) {
      return request.kind === "job" ? request.target : `${displayMethod(request)} ${request.target}`;
    }

    // DumpedRequest.statusText: a failed job gives its try.
    function statusText(request) {
      switch (request.kind) {
        case "command": return request.exitCode == null ? null : `exit ${request.exitCode}`;
        case "job": return outcomeText(request.job ?? {});
        default: return request.status == null ? null : String(request.status);
      }
    }

    // JobRun.tryText: "try 3 of 3", or "try 3" without a maximum.
    function tryText(job) {
      return job.attempt == null ? null : `try ${job.attempt}${job.maxTries == null ? "" : ` of ${job.maxTries}`}`;
    }

    // JobRun.outcomeText: "done", "released", or the try of a failed job.
    function outcomeText(job) {
      if (!job.outcome) {
        return null;
      }

      return job.outcome === "failed" ? (tryText(job) ?? job.outcome) : job.outcome;
    }

    // DumpBlock.isShown: a block shows only while a kind that it stops is switched on. A prepend
    // file of the site stops each kind.
    function blockIsShown(block, settings) {
      switch (block.reason) {
        case "var_dumper_format": return settings.catchDumps === true;
        case "savequeries": return settings.catchQueries === true;
        default: return [settings.catchDumps, settings.catchQueries, settings.catchLogs, settings.catchJobs].includes(true);
      }
    }

    // DumpBlock.title and DumpBlock.message, the texts of the approved design.
    function blockTitle(block) {
      switch (block.reason) {
        case "var_dumper_format": return `Nexus cannot catch the dumps of ${block.host}`;
        case "savequeries": return `Nexus cannot catch the queries of ${block.host}`;
        default: return `Nexus cannot catch anything from ${block.host}`;
      }
    }

    function blockMessage(block) {
      const source = (placeOfTheSetting) => block.file == null ? `${placeOfTheSetting} for ${block.host}` : `The ${block.file.split("/").pop()} of ${block.host}`;

      switch (block.reason) {
        case "var_dumper_format": return `${source("The environment of PHP")} sets VAR_DUMPER_FORMAT. Remove this key to see its dumps here.`;
        case "savequeries": return `${source("The wp-config.php")} sets SAVEQUERIES to false. Remove this line to see its queries here.`;
        default: return `${source("A .user.ini")} sets its own prepend file. PHP then runs that file and not the file of Nexus.`;
      }
    }

    function kindCount(request, kind) {
      switch (kind) {
        case "dump": return request.dumpCount ?? 0;
        case "query": return request.queryCount ?? 0;
        case "log": return request.logCount ?? 0;
        default: return request.jobCount ?? 0;
      }
    }

    // At most two counts, so the status and the time fit in the row of the list. The tabs show the
    // other counts.
    function countTexts(request) {
      const nouns = { dump: ["dump", "dumps"], query: ["query", "queries"], log: ["log line", "log lines"] };
      return Object.keys(nouns).filter((kind) => kindCount(request, kind) > 0).slice(0, 2).map((kind) => count(kindCount(request, kind), ...nouns[kind]));
    }

    // The info line of a request in the list, as DumpEntryText.summary: "3 dumps · 24 queries · 200 ·
    // 184 ms". A job starts with its outcome: "done · 4 queries · 220 ms". A failed job has the tag
    // failed and starts with its try.
    function summary(request) {
      const duration = request.duration == null ? null : durationText(request.duration);
      const counts = countTexts(request);

      if (request.kind !== "job") {
        return [...counts, statusText(request), duration].filter(Boolean).join(" · ");
      }

      const job = request.job ?? {};
      const start = job.outcome === "failed" ? tryText(job) : outcomeText(job);
      return [start, ...counts, duration].filter(Boolean).join(" · ");
    }

    // The Status line of a job: "Done · 220 ms" or "Failed on try 3 of 3 · 1.4 s".
    function jobStatusText(request) {
      const job = request.job ?? {};

      if (!job.outcome) {
        return null;
      }

      const failed = tryText(job) == null ? "Failed" : `Failed on ${tryText(job)}`;
      const word = job.outcome === "failed" ? failed : job.outcome[0].toUpperCase() + job.outcome.slice(1);
      return [word, request.duration == null ? null : durationText(request.duration)].filter(Boolean).join(" · ");
    }

    // The kinds that the request has, in the order of the tabs.
    function presentKinds(request) {
      return kinds.filter((kind) => kindCount(request, kind) > 0);
    }

    function entryKind(entry) {
      return entry.kind === "dd" ? "dump" : entry.kind;
    }

    function entryID(entry) {
      return `${entry.requestID}-${entry.seq}`;
    }

    // CaughtDump.isError: a log line of the level error or higher, or a PHP error.
    function isError(entry) {
      return entry.kind === "log" && (errorLevels.has((entry.label ?? "").toLowerCase()) || phpErrorDetails.has(entry.detail));
    }

    // The color of the tag of a log line or a job row, as DumpEntryText.tone: red for an error and
    // for a sync job that failed, orange for a warning, the accent for a queued job and gray for
    // the rest.
    function tone(entry) {
      if (entry.kind === "log") {
        return isError(entry) ? "red" : ((entry.label ?? "").toLowerCase() === "warning" ? "warning" : "gray");
      }

      if (entry.kind !== "job") {
        return "gray";
      }

      return { queued: "accent", failed: "red" }[entry.label] ?? "gray";
    }

    // CaughtDump.ranInRequest: a sync job, also one that failed. Its ms is the time of that run.
    function ranInRequest(entry) {
      return entry.kind === "job" && (entry.label === "sync" || entry.label === "failed");
    }

    function nPlusOneHint(number, laravel) {
      const hint = `This line runs the same query ${number} times with other values. One query for all values is faster.`;
      return laravel ? `${hint} In Laravel, load the relation with with().` : hint;
    }

    function droppedText(number) {
      return `Nexus did not keep ${count(number, "more query", "more queries")}.`;
    }

    // DumpEntryText.text: a tree as text in the way of CliDumper, for the copy button of a log line.
    function treeText(node, depth = 0) {
      const indent = "  ".repeat(depth);
      const key = displayKey(node);
      const start = indent + (key === null ? "" : (node.access == null ? `${key} => ` : `${key}: `));
      const children = node.refersTo == null ? (node.children ?? []) : [];
      const cut = node.cut == null || node.cut === 0 ? null : node.cut;
      const leftOut = cut === null ? null : (cut < 0 ? "…" : `…${cut}`);

      switch (node.kind) {
        case "string":
          return [`${start}"${node.value ?? ""}"${leftOut ?? ""}`];
        case "array":
        case "object":
        case "resource": {
          const [head, open, close] = node.kind === "object"
            ? [node.class ?? "object", node.ref == null ? "{" : `{#${node.ref}`, "}"]
            : (node.kind === "resource" ? [`${node.class ?? "unknown"} resource${node.ref == null ? "" : ` @${node.ref}`}`, "{", "}"] : [`array:${node.count ?? node.children?.length ?? 0}`, "[", "]"]);

          if (children.length === 0) {
            const inside = leftOut === null ? "" : ` ${leftOut}`;
            return [open === "[" && (node.count ?? 0) === 0 ? `${start}[]` : `${start}${head} ${open}${inside}${close}`];
          }

          return [`${start}${head} ${open}`, ...children.flatMap((child) => treeText(child, depth + 1)), ...(leftOut === null ? [] : [`${indent}  ${leftOut}`]), `${indent}${close}`];
        }
        case "label":
          return [`${start}${node.value ?? ""}`];
        case "null":
        case "bool":
        case "int":
        case "float":
          return [`${start}${node.value ?? node.kind}`];
        default:
          return [`${start}${node.value ?? ""}`];
      }
    }

    // The key as the tree shows it, as DumpNode.displayKey.
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

    // QueryMarks.pattern: the SQL with a ? for each string and number literal. The steps follow
    // the bytes of the Swift code. A character outside ASCII counts as a part of a name there.
    // A code unit of JavaScript above 0x7f gives the same answer.

    function isDigit(code) {
      return code >= 48 && code <= 57;
    }

    function isWordCode(code) {
      if (isDigit(code) || code === 95 || code === 36 || code >= 0x80) {
        return true;
      }

      const lower = code | 0x20;
      return lower >= 97 && lower <= 122;
    }

    // The index after the closing quote. A text without its closing quote ends at the end.
    function endOfQuote(text, quote, start) {
      let index = start + 1;

      while (index < text.length) {
        const code = text.charCodeAt(index);

        if (code === 92 && quote !== 96) {
          index += 2;
          continue;
        }

        if (code !== quote) {
          index += 1;
          continue;
        }

        if (index + 1 < text.length && text.charCodeAt(index + 1) === quote) {
          index += 2;
          continue;
        }

        return index + 1;
      }

      return text.length;
    }

    function endOfNumber(text, start) {
      let index = start;

      while (index < text.length && isDigit(text.charCodeAt(index))) {
        index += 1;
      }

      if (!(index + 1 < text.length && text.charCodeAt(index) === 46 && isDigit(text.charCodeAt(index + 1)))) {
        return index;
      }

      index += 1;

      while (index < text.length && isDigit(text.charCodeAt(index))) {
        index += 1;
      }

      return index;
    }

    function sqlPattern(sql) {
      const parts = [];
      let index = 0;

      while (index < sql.length) {
        const code = sql.charCodeAt(index);

        if (code === 39 || code === 34) {
          index = endOfQuote(sql, code, index);
          parts.push("?");
          continue;
        }

        if (code === 96) {
          const end = endOfQuote(sql, code, index);
          parts.push(sql.slice(index, end));
          index = end;
          continue;
        }

        if (!isDigit(code) || (index > 0 && isWordCode(sql.charCodeAt(index - 1)))) {
          parts.push(sql[index]);
          index += 1;
          continue;
        }

        const end = endOfNumber(sql, index);

        if (end < sql.length && isWordCode(sql.charCodeAt(end))) {
          parts.push(sql.slice(index, end));
          index = end;
          continue;
        }

        parts.push("?");
        index = end;
      }

      return parts.join("");
    }

    function queryPattern(query) {
      return query.pattern ?? sqlPattern(query.text);
    }

    function sourceKey(query) {
      return JSON.stringify([queryPattern(query), query.file ?? null, query.line ?? null]);
    }

    // QueryMarks.reads: only a select can be N+1.
    function reads(sql) {
      return sql.replace(/^[\s(]+/, "").slice(0, 6).toLowerCase() === "select";
    }

    // QueryMarks: slow, duplicate (the same text two times or more) and N+1 (one line of code ran
    // the same select pattern 5 times or more, with other texts). Gives the marks by the id of the
    // query, in the order n_plus_one, duplicate, slow. A query without marks has no key.
    function queryMarks(entries) {
      const queries = entries.filter((entry) => entry.kind === "query").map((query) => ({ query, source: sourceKey(query) }));
      const textCounts = new Map();
      const sources = new Map();

      for (const { query, source } of queries) {
        textCounts.set(query.text, (textCounts.get(query.text) ?? 0) + 1);
        const group = sources.get(source) ?? { count: 0, texts: new Set() };
        group.count += 1;
        group.texts.add(query.text);
        sources.set(source, group);
      }

      const marks = new Map();

      for (const { query, source } of queries) {
        const group = sources.get(source);
        const own = [];

        if (reads(query.text) && group.count >= nPlusOneCount && group.texts.size > 1) {
          own.push("n_plus_one");
        }

        if (textCounts.get(query.text) >= duplicateCount) {
          own.push("duplicate");
        }

        if ((query.ms ?? 0) >= slowMilliseconds) {
          own.push("slow");
        }

        if (own.length > 0) {
          marks.set(entryID(query), own);
        }
      }

      return marks;
    }

    // The rows of the Queries tab, as QueryRow.rows of the app. The queries of an N+1 line show as
    // one group, and so do the queries with the same text. A query that is both goes into the N+1
    // group. A group shows at the place of its first query. A group of one query is a single row.
    // A row has its queries, its tags, its time, its SQL and the hint of an N+1 group.
    function queryRows(entries) {
      const queries = entries.filter((entry) => entry.kind === "query");
      const marks = queryMarks(queries);
      const marksOf = (query) => marks.get(entryID(query)) ?? [];
      const groups = new Map();
      const rows = [];

      for (const query of queries) {
        const own = marksOf(query);
        const mark = own.includes("n_plus_one") ? "n_plus_one" : (own.includes("duplicate") ? "duplicate" : null);

        if (mark === null) {
          rows.push({ mark: null, queries: [query] });
          continue;
        }

        const key = mark === "n_plus_one" ? `n ${sourceKey(query)}` : `d ${query.text}`;

        if (!groups.has(key)) {
          groups.set(key, { mark, queries: [] });
          rows.push(groups.get(key));
        }

        groups.get(key).queries.push(query);
      }

      return rows.map((row) => {
        const first = row.queries[0];
        const slow = row.queries.some((query) => marksOf(query).includes("slow"));

        if (row.queries.length === 1) {
          const tags = [marksOf(first).includes("duplicate") ? "duplicate" : null, slow ? "slow" : null].filter(Boolean);
          return { mark: null, queries: row.queries, tags, slow, milliseconds: first.ms ?? null, hint: null, text: first.text };
        }

        const tags = [`${row.mark === "n_plus_one" ? "N+1" : "duplicate"} · ${row.queries.length}×`, ...(slow ? ["slow"] : [])];
        const milliseconds = row.queries.reduce((total, query) => total + (query.ms ?? 0), 0);
        const hint = row.mark === "n_plus_one" ? nPlusOneHint(row.queries.length, first.pattern != null) : null;
        const text = row.mark === "n_plus_one" ? queryPattern(first) : first.text;
        return { mark: row.mark, queries: row.queries, tags, slow, milliseconds, hint, text };
      });
    }

    """#

    private static let interface = #"""
    const token = document.querySelector('meta[name="nexus-token"]').content;
    const openChildrenLimit = {{OPEN_LIMIT}};
    const state = {
      list: null,
      requests: [],
      filter: "",
      filterLabel: null,
      choices: "",
      openID: null,
      tab: null,
      dumps: [],
      dumpsVersion: 0,
      queryRows: { version: -1, rows: [] },
      jobsByUUID: new Map(),
      shownEntries: "",
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

    // A request and a block both have a site and a workspace.
    function placeKey(place) {
      return JSON.stringify([place.site ?? null, place.workspace ?? null]);
    }

    function placeOfKey(key) {
      const [site, workspace] = JSON.parse(key);
      return { site, workspace };
    }

    function resultText(request) {
      const parts = [statusText(request), request.duration == null ? null : durationText(request.duration)].filter(Boolean);
      return parts.length ? parts.join(" · ") : null;
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

    // nexusd gives each setting, also the defaults of a setting that its file does not have.
    function catchesAnything() {
      const settings = state.list?.settings ?? {};
      return settings.catchDumps || settings.catchQueries || settings.catchLogs || settings.catchJobs;
    }

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
      setDumps(state.dumps.filter((dump) => !gone.has(dump.number)));
      state.generation += 1;
      state.loading = false;
      state.requestedLast = null;
    }

    // The version tells the cached query rows that the entries changed.
    function setDumps(dumps) {
      state.dumps = dumps;
      state.dumpsVersion += 1;
    }

    // A released job runs again with the same uuid. The newest run comes first in the list. So a
    // job row links to that run.
    function indexJobs() {
      state.jobsByUUID = new Map();

      for (const request of state.requests) {
        const uuid = request.kind === "job" ? request.job?.uuid : null;

        if (uuid != null && !state.jobsByUUID.has(uuid)) {
          state.jobsByUUID.set(uuid, request);
        }
      }
    }

    function listChanged() {
      indexJobs();
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
      const showsList = catchesAnything() && visible.length > 0;

      $("subtitle").textContent = state.list ? subtitleText(visible) : "";
      $("clear").disabled = !showsList;
      $("filter").disabled = !catchesAnything();
      $("requests").hidden = !showsList;
      $("empty").hidden = showsList || !state.list;
      $("empty").textContent = showsList ? "" : emptyText();
    }

    function subtitleText(visible) {
      if (!catchesAnything()) {
        return "All Catch switches are off";
      }

      if (visible.length === 0) {
        return state.list.loaded ? "No requests" : "Nexus loads the requests";
      }

      const dumps = visible.reduce((total, request) => total + request.dumpCount, 0);
      return dumps > 0 ? `${count(visible.length, "request")} with ${count(dumps, "dump")}` : count(visible.length, "request");
    }

    function emptyText() {
      if (!catchesAnything()) {
        return "Turn on Catch dumps, Catch queries, Catch log lines or Catch queue jobs in Nexus to see them here.";
      }

      if (state.list && !state.list.loaded) {
        return "Nexus loads the requests of its last run.";
      }

      if (state.filter) {
        return `Nexus has no requests of ${state.filterLabel ?? "No site"}.`;
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

      if (state.list && catchesAnything()) {
        if (state.list.problem) {
          banners.push(banner("The dump viewer has a problem", state.list.problem));
        }

        for (const block of state.list.blocked ?? []) {
          if (!blockIsShown(block, state.list.settings)) {
            continue;
          }

          if (state.filter && (!block.place || placeKey(block.place) !== state.filter)) {
            continue;
          }

          banners.push(banner(blockTitle(block), blockMessage(block)));
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

      if (request.marks?.includes("n_plus_one")) {
        const tag = element("span", "tag warning", "N+1");
        tag.title = "A line of code in this request runs the same query many times with other values.";
        bottom.append(tag);
      }

      if (request.hasDD) {
        const tag = element("span", "tag warning", "dd()");
        tag.title = "This request called dd(). PHP stopped there.";
        bottom.append(tag);
      }

      if (request.job?.outcome === "failed") {
        bottom.append(element("span", "tag red mono", "failed"));
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

    // A line that opens another request of the list.
    function requestLine(key, value, id) {
      const line = element("div", "head-line");
      const button = element("button", "head-value link", value);
      button.type = "button";
      button.title = `Show ${value}`;
      button.addEventListener("click", () => showRequest(id));
      line.append(element("span", "head-key", key), button);
      return line;
    }

    // The entries keep their own container while the request stays open.
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
        detail.replaceChildren(element("div", "head"), element("div", "tabs-bar"), element("div", "entries"));
      }

      const title = element("div", "head-title");
      title.append(element("h2", null, titleText(request)), element("span", "tag", request.placeHost ?? "No site"));
      title.append(iconButton("trash", "Remove this request and its entries", () => post("/api/remove-request", { id: request.id })));

      const lines = [title, ...(request.kind === "job" ? jobHeadLines(request) : headLines(request))];
      lines.push(headLine("Time", fullTime(request.started)));
      detail.querySelector(".head").replaceChildren(...lines);
      renderTabs(request);
    }

    function headLines(request) {
      const lines = [];

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

      return lines;
    }

    // Queue, Status, Worker and From, as the head of a job in the app.
    function jobHeadLines(request) {
      const job = request.job ?? {};
      const lines = [];
      const queue = [job.queue, job.connection].filter(Boolean).join(" · ");
      const status = jobStatusText(request);

      if (queue) {
        lines.push(headLine("Queue", queue));
      }

      if (status) {
        const line = headLine("Status", status);
        line.lastChild.classList.toggle("failed", job.outcome === "failed");
        lines.push(line);
      }

      if (job.command) {
        lines.push(headLine("Worker", job.command));
      }

      const from = state.requests.find((other) => other.id === job.queuedBy);

      if (from) {
        lines.push(requestLine("From", `${displayMethod(from)} ${from.target} at ${secondsFormat.format(new Date(from.started))}`, from.id));
      }

      return lines;
    }

    function currentTab(request) {
      const present = presentKinds(request);
      return present.includes(state.tab) ? state.tab : (present[0] ?? "dump");
    }

    // A request with only dumps has no tabs, as in the app.
    function renderTabs(request) {
      const bar = $("detail").querySelector(".tabs-bar");
      const present = presentKinds(request);
      bar.hidden = present.every((kind) => kind === "dump");

      if (bar.hidden) {
        bar.replaceChildren();
        return;
      }

      const selected = currentTab(request);
      const names = { dump: "Dumps", query: "Queries", log: "Log lines", job: "Jobs" };
      const tabs = element("div", "segmented");
      tabs.setAttribute("role", "tablist");

      for (const kind of present) {
        const tab = element("button", "segment", `${names[kind]} (${kindCount(request, kind)})`);
        tab.type = "button";
        tab.setAttribute("role", "tab");
        tab.setAttribute("aria-selected", String(kind === selected));
        tab.addEventListener("click", () => {
          state.tab = kind;
          renderTabs(request);
          renderDumps();
        });
        tabs.append(tab);
      }

      const parts = [tabs];

      if (selected === "query") {
        parts.push(element("span", "tabs-total", `${millisecondsText(request.queryMilliseconds ?? 0)} in total`));
      }

      bar.replaceChildren(...parts);
    }

    // The From line of a job and the Ran at link of a job row open another request. The filter
    // goes when it hides that request.
    function showRequest(id) {
      if (!state.requests.some((request) => request.id === id)) {
        return;
      }

      if (!visibleRequests().some((request) => request.id === id)) {
        state.filter = "";
        state.filterLabel = null;
      }

      openRequest(id);
      listChanged();
      $("list").querySelector(".row.selected")?.scrollIntoView({ block: "nearest" });
    }

    // The dumps of the open request

    function openRequest(id) {
      if (id === state.openID) {
        return;
      }

      state.openID = id;
      state.tab = null;
      state.generation += 1;
      setDumps([]);
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

      const kept = state.dumps.filter((dump) => dump.number >= request.firstNumber);

      if (kept.length < state.dumps.length) {
        setDumps(kept);
      }

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
          problem = (await response.json().catch(() => ({}))).message ?? "Nexus did not load the entries.";
        }
      } catch {
        problem = "Nexus does not answer. Is Nexus running?";
      }

      if (generation !== state.generation) {
        return;
      }

      const known = new Set(state.dumps.map((dump) => dump.number));
      setDumps([...state.dumps, ...dumps.filter((dump) => !known.has(dump.number))]);
      state.loadProblem = problem;
      state.loading = false;
      loadOpenDumps();
    }

    // Each box stays while its entries and its texts stay, also after a switch of the tab. So an
    // open node of a tree stays open. A group of queries gets a new box when it gets a query. Each
    // change of the list calls this. It does nothing when the entries, the tab, the end of the
    // request and the runs of its jobs stay the same.
    function renderDumps() {
      const container = $("detail").querySelector(".entries");
      const request = openRequestData();

      if (!container || !request) {
        return;
      }

      const tab = currentTab(request);
      const runs = tab === "job" ? state.dumps.filter((entry) => entry.kind === "job").map((row) => runSignature(ranRequest(row))) : [];
      const shown = JSON.stringify([request.id, state.dumpsVersion, tab, request.droppedQueries ?? 0, state.loading, state.loadProblem, runs]);

      if (shown === state.shownEntries && container.childElementCount > 0) {
        return;
      }

      state.shownEntries = shown;
      const numbers = new Set(state.dumps.map((dump) => dump.number));
      const boxes = new Map([...state.boxes].filter(([, cached]) => cached.numbers.every((number) => numbers.has(number))));
      const nodes = tabItems(tab, request).map((item) => {
        if (!boxes.has(item.key)) {
          boxes.set(item.key, { numbers: item.numbers, box: item.make(request.projectFolder) });
        }

        return boxes.get(item.key).box;
      });

      state.boxes = boxes;

      if (nodes.length === 0 && state.loading) {
        container.replaceChildren(element("p", "center", "Nexus loads the entries."));
        return;
      }

      if (state.loadProblem) {
        nodes.push(element("p", "note", `${state.loadProblem} Click the request to try again.`));
      }

      show(container, nodes);
    }

    // The rows are made again only when the entries changed.
    function cachedQueryRows() {
      if (state.queryRows.version !== state.dumpsVersion) {
        state.queryRows = { version: state.dumpsVersion, rows: queryRows(state.dumps) };
      }

      return state.queryRows.rows;
    }

    function runSignature(ran) {
      return ran ? `${ran.id} ${ran.started} ${statusText(ran) ?? ""}` : "";
    }

    // The boxes of one tab, each with a key that changes when its box must change. The Queries tab
    // ends with the number of queries that PHP did not keep.
    function tabItems(tab, request) {
      const entries = state.dumps.filter((entry) => entryKind(entry) === tab);
      const numbersOf = (list) => list.map((entry) => entry.number);

      switch (tab) {
        case "query": {
          const rows = cachedQueryRows().map((row) => ({
            key: `query ${row.tags.join("|")} ${numbersOf(row.queries).join(",")}`,
            numbers: numbersOf(row.queries),
            make: (projectFolder) => queryBox(row, projectFolder),
          }));

          if (rows.length > 0 && request.droppedQueries > 0) {
            rows.push({ key: `dropped ${request.droppedQueries}`, numbers: [], make: () => element("p", "note", droppedText(request.droppedQueries)) });
          }

          return rows;
        }
        case "log":
          return entries.map((log) => ({ key: `log ${log.number}`, numbers: [log.number], make: (projectFolder) => logBox(log, projectFolder) }));
        case "job":
          return entries.map((row) => {
            const ran = ranRequest(row);
            return { key: `job ${row.number} ${runSignature(ran)}`, numbers: [row.number], make: (projectFolder) => jobBox(row, ran, projectFolder) };
          });
        default:
          return entries.map((dump) => ({ key: `dump ${dump.number}`, numbers: [dump.number], make: (projectFolder) => dumpBox(dump, projectFolder) }));
      }
    }

    function fileLink(entry, projectFolder) {
      if (!entry.file) {
        return element("span", "soft", "No file");
      }

      const link = element("button", "link");
      link.type = "button";
      link.title = `Open ${entry.file} in your code editor`;
      link.append(element("bdi", null, shortPath(entry.file, projectFolder) + (entry.line ? `:${entry.line}` : "")));
      link.addEventListener("click", () => post("/api/open", { number: entry.number }));
      return link;
    }

    function copyButton(text, help, done) {
      return iconButton("copy", help, async () => {
        try {
          await navigator.clipboard.writeText(text);
          showToast(done);
        } catch {
          showToast("The browser did not copy the text.");
        }
      });
    }

    function treeBox(tree) {
      const content = element("div", "box");
      content.append(treeNode(tree, (tree.children?.length ?? 0) <= openChildrenLimit));
      return content;
    }

    function textBox(text) {
      const content = element("div", "box");
      content.append(element("pre", null, text));
      return content;
    }

    function dumpBox(dump, projectFolder) {
      const box = element("div", "entry");
      const source = element("div", "source");
      source.append(icon("file"), fileLink(dump, projectFolder));

      if (dump.label) {
        source.append(element("span", "label", dump.label));
      }

      source.append(element("span", "spacer"), element("span", "kind", dump.kind === "dd" ? "dd()" : "dump()"));
      source.append(copyButton(dump.text, "Copy the text of this dump", "Nexus copied the text of the dump."));
      source.append(iconButton("trash", "Remove this dump", () => post("/api/remove-dump", { number: dump.number })));

      const tree = parsedTree(dump.tree);
      box.append(source, tree ? treeBox(tree) : textBox(dump.text));

      if (dump.truncated) {
        box.append(element("div", "note", "Nexus shortened the text of this dump, because it is very large."));
      }

      return box;
    }

    // One query, or a group with its pattern. A group opens to show each query with its time.
    function queryBox(row, projectFolder) {
      const first = row.queries[0];
      const box = element("div", "entry");
      const source = element("div", "source");
      source.append(icon("file"), fileLink(first, projectFolder), element("span", "spacer"));

      for (const tag of row.tags) {
        source.append(element("span", tag === "slow" ? "tag red mono" : "tag warning", tag));
      }

      if (row.milliseconds != null) {
        source.append(element("span", row.slow ? "time slow" : "time", millisecondsText(row.milliseconds)));
      }

      source.append(copyButton(row.text, "Copy the SQL", "Nexus copied the SQL."));

      box.append(source, row.queries.length === 1 ? textBox(first.text) : groupBox(row, projectFolder));

      if (row.queries.some((query) => query.truncated)) {
        box.append(element("div", "note", "Nexus shortened the SQL, because it is very large."));
      }

      if (row.hint) {
        box.append(element("div", "hint", row.hint));
      }

      return box;
    }

    // A query of a duplicate group can come from another line. That query shows its line.
    function groupBox(row, projectFolder) {
      const wrapper = element("div", "box");
      const line = element("div", "node-line");
      const chevron = element("button", "chevron", "›");
      chevron.type = "button";
      const members = element("div", "children");
      const first = row.queries[0];
      let open = false;
      let filled = false;

      const member = (query) => {
        const item = element("div", "member");
        const sql = element("div", "member-sql");
        const slow = (query.ms ?? 0) >= slowMilliseconds;

        if (query.file !== first.file || query.line !== first.line) {
          const source = element("div", "source");
          source.append(icon("file"), fileLink(query, projectFolder));
          sql.append(source);
        }

        sql.append(element("pre", null, query.text));
        item.append(sql, element("span", slow ? "time slow" : "time", query.ms == null ? "" : millisecondsText(query.ms)), copyButton(query.text, "Copy the SQL of this query", "Nexus copied the SQL."));
        return item;
      };

      const showQueries = (shouldOpen) => {
        open = shouldOpen;
        chevron.classList.toggle("open", open);
        chevron.setAttribute("aria-label", open ? "Hide the queries" : "Show the queries");
        members.hidden = !open;

        if (open && !filled) {
          filled = true;
          members.append(...row.queries.map(member));
        }
      };

      chevron.addEventListener("click", () => showQueries(!open));
      line.append(chevron, element("span", null, row.text));
      wrapper.append(line, members);
      showQueries(false);
      return wrapper;
    }

    // The level, the message and the time, then the file and the channel, then the context.
    function logBox(log, projectFolder) {
      const box = element("div", "entry");
      const head = element("div", "source");
      const tree = parsedTree(log.tree);
      const copied = tree ? [log.text, ...treeText(tree)].join("\n") : log.text;
      head.append(toneTag(log), element("span", "message", log.text), element("span", "time", secondsFormat.format(new Date(log.time))));
      head.append(copyButton(copied, "Copy the message and the context of this log line", "Nexus copied the log line."));

      const source = element("div", "source");
      source.append(icon("file"), fileLink(log, projectFolder), element("span", "spacer"));

      if (log.detail) {
        source.append(element("span", "kind", log.detail));
      }

      box.append(head, source);

      if (tree) {
        box.append(treeBox(tree));
      }

      if (log.truncated) {
        box.append(element("div", "note", "Nexus shortened the message, because it is very large."));
      }

      return box;
    }

    function toneTag(entry) {
      const classes = { red: "tag red mono", warning: "tag warning", accent: "tag mono", gray: "tag gray mono" };
      return element("span", classes[tone(entry)], entry.label ?? entry.kind);
    }

    // A queued job that a worker ran links to the entry of that run.
    function ranRequest(row) {
      return row.ref == null ? null : (state.jobsByUUID.get(row.ref) ?? null);
    }

    function jobBox(row, ran, projectFolder) {
      const box = element("div", "entry");
      const head = element("div", "source");
      head.append(toneTag(row), element("span", "message code", row.text));

      if (ranInRequest(row)) {
        if (row.ms != null) {
          head.append(element("span", "time", millisecondsText(row.ms)));
        }
      } else if (ran) {
        const time = secondsFormat.format(new Date(ran.started));
        const link = element("button", "jump", [`Ran at ${time}`, statusText(ran)].filter(Boolean).join(" · "));
        link.type = "button";
        link.title = "Show the entry of this job";
        link.addEventListener("click", () => showRequest(ran.id));
        head.append(link);
      }

      const source = element("div", "source");
      source.append(icon("file"), fileLink(row, projectFolder), element("span", "spacer"));

      if (row.detail) {
        source.append(element("span", "kind", row.detail));
      }

      box.append(head, source);
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
      $("confirm-title").textContent = state.filter ? `Remove the requests of ${state.filterLabel ?? "No site"}?` : "Remove all requests?";
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
