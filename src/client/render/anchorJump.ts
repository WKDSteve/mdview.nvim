// src/client/render/anchorJump.ts
//
// Click an in-page anchor link (a table-of-contents entry like
// `[Setup](#setup)`) and the preview jumps to that heading.
//
// The browser cannot do this on its own here: the WASM renderer emits no id
// attributes on headings, so its `#fragment` handling finds nothing and the
// click only ever showed the hover popup. The anchor is resolved the way
// linkHover.ts resolves it for the popup (GitHub slug with `-1`, `-2`
// numbering, matching markdown.nvim), so what the popup shows is where the
// click lands.
//
// Delegated on `root`, which survives the content swap of each render, so it
// is installed once. The URL hash is left alone: Back/Forward belongs to the
// document history (history.ts), not to positions inside a document.

import { headingAnchors, resolveAnchor, slugify } from './linkHover';

/**
 * Install the jump on `root`. `jump(el)` scrolls the preview to the target
 * heading; main.ts passes docModel.scrollToBlock, the same scroll the outline
 * overlay uses.
 */
export function installAnchorJump(root: HTMLElement, jump: (el: HTMLElement) => void): void {
  root.addEventListener('click', (ev: MouseEvent) => {
    if (
      ev.defaultPrevented ||
      ev.button !== 0 ||
      ev.metaKey ||
      ev.ctrlKey ||
      ev.shiftKey ||
      ev.altKey
    ) {
      return;
    }
    const anchor = (ev.target as Element | null)?.closest?.('a[href]') as HTMLAnchorElement | null;
    if (!anchor || !root.contains(anchor)) return;
    const href = (anchor.getAttribute('href') ?? '').trim();
    if (!href.startsWith('#') || href.length < 2) return;

    let fragment: string;
    try {
      fragment = decodeURIComponent(href.slice(1));
    } catch {
      fragment = href.slice(1);
    }
    // An element of the document that really carries this id (footnotes) is
    // the browser's job; it scrolls there by itself. Only ids inside `root`
    // count: the page chrome (#app, #mdview-overlays, ...) must not swallow a
    // heading that happens to share the slug.
    const byId = document.getElementById(fragment);
    if (byId && root.contains(byId)) return;

    const target = resolveAnchor(headingAnchors(root), slugify(fragment));
    if (!target) return;
    ev.preventDefault();
    jump(target.el);
  });
}
