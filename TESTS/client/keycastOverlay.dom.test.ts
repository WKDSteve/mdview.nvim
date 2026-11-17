// @vitest-environment jsdom
import { afterEach, beforeEach, describe, it, expect, vi } from 'vitest';
import {
  initOverlays,
  setOverlay,
  dispatchOverlayControl,
  resetOverlays,
  overlayNames,
  parseKeycast,
} from '../../src/client/render/overlays';
import { KEYCAST_FADE_MS } from '../../src/client/render/overlays/keycast';

function pill(): HTMLElement | null {
  return document.querySelector('.mdview-keycast');
}

describe('keycast overlay', () => {
  beforeEach(() => {
    vi.useFakeTimers();
    const root = document.createElement('div');
    root.id = 'mdview-root';
    document.body.append(root);
    initOverlays(root);
  });
  afterEach(() => {
    resetOverlays();
    vi.useRealTimers();
    document.body.innerHTML = '';
  });

  it('is registered under the name the Lua manifest uses', () => {
    expect(overlayNames()).toContain('keycast');
  });

  it('draws nothing until it is switched on, and ignores keys while off', () => {
    dispatchOverlayControl('keycast', ':w<CR>');
    expect(pill()).toBeNull();
  });

  it('shows the keys as text and fades out after the last batch', () => {
    setOverlay('keycast', true);
    dispatchOverlayControl('keycast', ':w<CR>');
    const el = pill()!;
    expect(el.textContent).toBe(':w<CR>');
    expect(el.classList.contains('mdview-keycast-on')).toBe(true);
    expect(el.getAttribute('aria-hidden')).toBe('true');

    vi.advanceTimersByTime(KEYCAST_FADE_MS - 100);
    dispatchOverlayControl('keycast', ':w<CR> j');
    vi.advanceTimersByTime(KEYCAST_FADE_MS - 100);
    expect(el.classList.contains('mdview-keycast-on')).toBe(true); // a new batch restarts the fade
    vi.advanceTimersByTime(200);
    expect(el.classList.contains('mdview-keycast-on')).toBe(false);
  });

  it('never renders markup and caps an overlong line, keeping its newest keys', () => {
    setOverlay('keycast', true);
    dispatchOverlayControl('keycast', '<img src=x onerror=alert(1)>' + 'x'.repeat(300) + 'END');
    const el = pill()!;
    expect(el.querySelector('img')).toBeNull();
    expect(el.textContent!.length).toBe(200);
    expect(el.textContent!.endsWith('END')).toBe(true);
  });

  it('an empty line hides it at once; switching it off removes it', () => {
    setOverlay('keycast', true);
    dispatchOverlayControl('keycast', 'j');
    dispatchOverlayControl('keycast', '');
    expect(pill()!.classList.contains('mdview-keycast-on')).toBe(false);
    setOverlay('keycast', false);
    expect(pill()).toBeNull();
  });
});

describe('parseKeycast', () => {
  it('reads the text of a batch and rejects anything else', () => {
    expect(parseKeycast('{"text":"<C-W>"}')).toBe('<C-W>');
    expect(parseKeycast('{"text":""}')).toBe('');
    expect(parseKeycast('{"text":3}')).toBeNull();
    expect(parseKeycast('[]')).toBeNull();
    expect(parseKeycast('not json')).toBeNull();
  });
});
