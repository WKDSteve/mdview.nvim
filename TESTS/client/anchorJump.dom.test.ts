// tests/client/anchorJump.dom.test.ts
// @vitest-environment jsdom
//
// A click on an in-page anchor link (a table-of-contents entry like
// `[Setup](#setup)`) must jump to the heading. The WASM renderer emits no id
// attributes on headings, so the browser's own `#fragment` handling finds
// nothing; installAnchorJump resolves the anchor by slug, as the hover popup
// already does, and scrolls there.

import { describe, it, expect, vi } from 'vitest';
import { installAnchorJump } from '../../src/client/render/anchorJump';

function setup(html: string) {
  const root = document.createElement('div');
  root.innerHTML = html;
  document.body.appendChild(root);
  const jump = vi.fn();
  installAnchorJump(root, jump);
  return { root, jump };
}

function click(el: Element, init: MouseEventInit = {}) {
  const ev = new window.MouseEvent('click', {
    bubbles: true,
    cancelable: true,
    button: 0,
    ...init,
  });
  el.dispatchEvent(ev);
  return ev;
}

// What render_markdown emits for a document with a TOC: headings without ids.
const DOC = `
<ul><li><a href="#setup">Setup</a></li><li><a href="#usage-notes">Usage notes</a></li></ul>
<h1>Title</h1>
<h2>Setup</h2>
<p>text</p>
<h2>Usage Notes!</h2>
<h2>Setup</h2>
`;

describe('installAnchorJump (real DOM)', () => {
  it('jumps to the heading a TOC link points at', () => {
    const { root, jump } = setup(DOC);
    const ev = click(root.querySelector('a[href="#setup"]')!);
    expect(ev.defaultPrevented).toBe(true);
    expect(jump).toHaveBeenCalledTimes(1);
    expect(jump.mock.calls[0][0]).toBe(root.querySelectorAll('h2')[0]);
  });

  it('resolves by GitHub slug (case, punctuation) and numbered duplicates', () => {
    const { root, jump } = setup(DOC + '<a id="dup" href="#setup-1">again</a>');
    click(root.querySelector('a[href="#usage-notes"]')!);
    expect(jump.mock.calls[0][0]).toBe(root.querySelectorAll('h2')[1]);
    click(root.querySelector('#dup')!);
    expect(jump.mock.calls[1][0]).toBe(root.querySelectorAll('h2')[2]);
  });

  it('accepts a percent-encoded anchor', () => {
    const { root, jump } = setup('<a href="#%C3%BCbersicht">x</a><h2>Übersicht</h2>');
    click(root.querySelector('a')!);
    expect(jump.mock.calls[0][0]).toBe(root.querySelector('h2'));
  });

  it('works when the click lands on a child of the link', () => {
    const { root, jump } = setup('<a href="#setup"><code>Setup</code></a><h2>Setup</h2>');
    const ev = click(root.querySelector('code')!);
    expect(ev.defaultPrevented).toBe(true);
    expect(jump).toHaveBeenCalledTimes(1);
  });

  it('leaves an anchor without a matching heading to the browser', () => {
    const { root, jump } = setup('<a href="#nowhere">x</a><h2>Setup</h2>');
    const ev = click(root.querySelector('a')!);
    expect(ev.defaultPrevented).toBe(false);
    expect(jump).not.toHaveBeenCalled();
  });

  it('leaves an anchor to an element with that id to the browser (footnotes)', () => {
    const { root, jump } = setup('<a href="#fn-1">1</a><h2>fn 1</h2><li id="fn-1">note</li>');
    const ev = click(root.querySelector('a')!);
    expect(ev.defaultPrevented).toBe(false);
    expect(jump).not.toHaveBeenCalled();
  });

  it('still jumps when the id belongs to the page chrome, not the document', () => {
    // #mdview-overlays, #app ...: ids outside the rendered content must not
    // swallow a heading of the same slug.
    const chrome = document.createElement('div');
    chrome.id = 'overlays';
    document.body.appendChild(chrome);
    const { root, jump } = setup('<a href="#overlays">x</a><h2>Overlays</h2>');
    const ev = click(root.querySelector('a')!);
    expect(ev.defaultPrevented).toBe(true);
    expect(jump.mock.calls[0][0]).toBe(root.querySelector('h2'));
    chrome.remove();
  });

  it('ignores non-anchor links and modifier clicks', () => {
    const { root, jump } = setup('<a href="./x.md">x</a><a href="#setup">s</a><h2>Setup</h2>');
    click(root.querySelector('a[href="./x.md"]')!);
    click(root.querySelector('a[href="#setup"]')!, { ctrlKey: true });
    click(root.querySelector('a[href="#setup"]')!, { button: 1 });
    expect(jump).not.toHaveBeenCalled();
  });
});
