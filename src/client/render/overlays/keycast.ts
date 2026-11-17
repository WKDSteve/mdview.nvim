// src/client/render/overlays/keycast.ts
//
// Keycast: the keys pressed in Neovim as a pill at the bottom of the preview,
// fading out shortly after the last key -- for lectures and screen recordings,
// so a viewer of the shared preview sees what is being typed. Neovim sends the
// whole current line (already formatted by ui.screenkey: `<C-W>`, `:w<CR>`,
// `j×3`) over its own channel (`\x08`, /keys) at most once per short batch;
// this overlay only shows it. Off by default (browser.overlays.keycast); which
// keys are captured at all is decided in Neovim (browser.keycast.scope).

import type { Overlay, OverlayCtx } from './types';

/** How long the pill stays fully visible after the last batch. */
export const KEYCAST_FADE_MS = 1500;
/** Longest line shown; Neovim already clips to about 60 columns. */
const MAX_CHARS = 200;

let pill: HTMLElement | null = null;
let fadeTimer: ReturnType<typeof setTimeout> | null = null;

function clearFade(): void {
  if (fadeTimer !== null) {
    clearTimeout(fadeTimer);
    fadeTimer = null;
  }
}

/** Show `text` (text only, never markup) and restart the fade. Empty hides. */
function show(text: string): void {
  if (!pill) return;
  clearFade();
  const line = text.length > MAX_CHARS ? text.slice(text.length - MAX_CHARS) : text;
  pill.textContent = line;
  if (line === '') {
    pill.classList.remove('mdview-keycast-on');
    return;
  }
  pill.classList.add('mdview-keycast-on');
  fadeTimer = setTimeout(() => {
    fadeTimer = null;
    pill?.classList.remove('mdview-keycast-on');
  }, KEYCAST_FADE_MS);
}

/**
 * Parse one keycast payload ({"text": "..."}). Returns null for anything that
 * is not that shape, so a malformed message is ignored instead of shown.
 */
export function parseKeycast(raw: string): string | null {
  try {
    const msg: unknown = JSON.parse(raw);
    if (msg && typeof msg === 'object' && typeof (msg as { text?: unknown }).text === 'string') {
      return (msg as { text: string }).text;
    }
  } catch {
    /* not JSON */
  }
  return null;
}

export const keycastOverlay: Overlay = {
  name: 'keycast',

  mount(ctx: OverlayCtx): void {
    pill = document.createElement('div');
    pill.className = 'mdview-keycast';
    // A screen reader would read every key: the pill is for sighted viewers of a recording.
    pill.setAttribute('aria-hidden', 'true');
    ctx.layer.append(pill);
  },

  unmount(): void {
    clearFade();
    pill?.remove();
    pill = null;
  },

  onControl(data: unknown): void {
    if (typeof data === 'string') show(data);
  },
};
