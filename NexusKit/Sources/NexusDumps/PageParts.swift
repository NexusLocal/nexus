import Foundation

// The parts that the web pages of the dumps and of the logs share: the colors of macOS in light
// and dark mode, the header with the switch between the pages, the list, the tags and the tree of
// a value. So the two pages look the same.
enum PageParts {
    // Each answer gets its own nonce. The scripts and the styles of the page carry it. So no other
    // script runs in the page.
    static func policy(nonce: String) -> String {
        "default-src 'none'; script-src 'nonce-\(nonce)'; style-src 'nonce-\(nonce)'; connect-src 'self'; img-src 'self' data:; base-uri 'none'; form-action 'none'; frame-ancestors 'none'"
    }

    static let style = #"""
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
      --orange: #f59a0a;
      --orange-text: #a35f00;
      --red: #ff3b30;
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
        --orange: #ffa51f;
        --orange-text: #ffb54d;
        --red: #ff453a;
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
    button, select, input { font: inherit; color: inherit; }
    .bar {
      display: flex;
      align-items: center;
      gap: 12px;
      min-height: 56px;
      padding: 0 24px;
      background: var(--bar);
      border-bottom: 1px solid var(--separator);
    }
    .title-block { flex: 0 1 auto; min-width: 0; }
    .bar-spacer { flex: 1; }
    h1 { margin: 0; font-size: 15px; font-weight: 600; }
    .subtitle { margin: 0; font-size: 11px; color: var(--secondary); white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
    .live { display: flex; align-items: center; gap: 6px; font-size: 11px; color: var(--secondary); white-space: nowrap; }
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
    .list { width: 360px; flex: none; overflow-y: auto; border-right: 1px solid var(--separator); outline: none; }
    .row { padding: 9px 12px; border-bottom: 1px solid var(--separator); cursor: default; }
    .row.selected { background: var(--selection); }
    .row-line { display: flex; align-items: center; gap: 6px; min-width: 0; }
    .row-line + .row-line { margin-top: 3px; }
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
    .segmented { display: inline-flex; gap: 2px; padding: 2px; border: 1px solid var(--separator); border-radius: 8px; background: var(--track); }
    .segment { padding: 3px 12px; border: 0; border-radius: 6px; background: none; cursor: default; }
    .segment[aria-selected="true"] { background: var(--control); box-shadow: 0 0.5px 1.5px rgba(0, 0, 0, 0.15); font-weight: 600; }
    .page-switch { flex: none; }
    .page-switch .segment { color: inherit; text-decoration: none; }
    .page-switch .segment[aria-current="page"] { background: var(--control); box-shadow: 0 0.5px 1.5px rgba(0, 0, 0, 0.15); font-weight: 600; }
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
    .section-title { font-size: 11px; font-weight: 600; color: var(--secondary); }
    .empty-line { padding: 12px 14px; border-radius: 10px; background: var(--group); color: var(--secondary); }
    .center { margin: auto; color: var(--secondary); }
    .footer { margin: 0; font-size: 11px; line-height: 1.35; color: var(--secondary); }
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

    """#

    // The texts that both scripts use. This part uses no page. So the tests run it too.
    static let logic = #"""
    "use strict";

    function count(number, noun, plural = `${noun}s`) {
      return number === 1 ? `1 ${noun}` : `${number} ${plural}`;
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

    """#

    // The parts of both scripts that build the page: the elements, the icons, the toast and the
    // tree of a value.
    static let interface = #"""
    const openChildrenLimit = {{OPEN_LIMIT}};
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
      globe: ["M22 12a10 10 0 1 1-20 0 10 10 0 0 1 20 0z", "M12 2a14.5 14.5 0 0 0 0 20 14.5 14.5 0 0 0 0-20", "M2 12h20"],
      search: ["M11 18a7 7 0 1 0 0-14 7 7 0 0 0 0 14z", "M20 20l-4-4"],
      chevronDown: ["M6 9l6 6 6-6"],
      close: ["M18 6 6 18", "M6 6l12 12"],
      scissors: ["M6 9a3 3 0 1 0 0-6 3 3 0 0 0 0 6z", "M6 21a3 3 0 1 0 0-6 3 3 0 0 0 0 6z", "M20 4 8.1 15.9", "M14.5 14.5 20 20", "M8.1 8.1 12 12"],
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

    function showToast(text) {
      const toast = $("toast");
      toast.textContent = text;
      toast.hidden = false;
      clearTimeout(showToast.timer);
      showToast.timer = setTimeout(() => { toast.hidden = true; }, 4000);
    }

    async function copyText(text, done) {
      try {
        await navigator.clipboard.writeText(text);
        showToast(done);
      } catch {
        showToast("The browser did not copy the text.");
      }
    }

    function copyButton(text, help, done) {
      return iconButton("copy", help, () => copyText(text, done));
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

    """#
}
