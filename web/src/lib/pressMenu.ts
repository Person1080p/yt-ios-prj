import { useRef, type MouseEvent, type PointerEvent } from "react";

/** How long a finger has to stay down to count as press-and-hold. */
const HOLD_MS = 500;
/** Moving further than this (px) while holding is a scroll, not a press. */
const MOVE_PX = 10;

/**
 * Handlers that open a menu on right-click and on press-and-hold (touch or pen). Spread them on
 * the item's main element. Pass null for items without a menu.
 *
 * Android fires `contextmenu` on a long press by itself; iOS Safari doesn't, hence the timer.
 * After a hold, the click the browser sends when the finger lifts is swallowed, so it neither
 * plays the item nor taps whatever the menu put under the finger.
 */
export function usePressMenu(open: (() => void) | null) {
  const timer = useRef<number | undefined>(undefined);
  const start = useRef<{ x: number; y: number } | null>(null);
  /** When the hold last opened the menu, so Android's own contextmenu right after is ignored. */
  const firedAt = useRef(0);

  const cancel = () => {
    window.clearTimeout(timer.current);
    timer.current = undefined;
    start.current = null;
  };

  if (!open) return {};

  const fire = () => {
    firedAt.current = Date.now();
    swallowClickAfterRelease();
    navigator.vibrate?.(10);
    open();
  };

  return {
    onPointerDown: (e: PointerEvent) => {
      if (e.pointerType === "mouse" || !e.isPrimary) return;
      start.current = { x: e.clientX, y: e.clientY };
      window.clearTimeout(timer.current);
      timer.current = window.setTimeout(() => {
        timer.current = undefined;
        start.current = null;
        fire();
      }, HOLD_MS);
    },
    onPointerMove: (e: PointerEvent) => {
      const s = start.current;
      if (s && Math.hypot(e.clientX - s.x, e.clientY - s.y) > MOVE_PX) cancel();
    },
    onPointerUp: cancel,
    onPointerCancel: cancel,
    onContextMenu: (e: MouseEvent) => {
      e.preventDefault();
      if (Date.now() - firedAt.current < 1000) return;
      // A touch long press (Android) still has the finger down: same as the timer firing.
      if (start.current) {
        cancel();
        fire();
      } else {
        open();
      }
    },
  };
}

/** Swallow the next click, which a touch sends once the finger lifts. */
function swallowClickAfterRelease() {
  let t: number | undefined;
  const done = () => {
    window.clearTimeout(t);
    window.removeEventListener("click", swallow, true);
    window.removeEventListener("pointerup", released, true);
    window.removeEventListener("pointercancel", released, true);
  };
  const swallow = (e: Event) => {
    e.preventDefault();
    e.stopPropagation();
    done();
  };
  // The click (if any) follows the release closely; stop waiting soon after.
  const released = () => {
    window.clearTimeout(t);
    t = window.setTimeout(done, 400);
  };
  window.addEventListener("click", swallow, true);
  window.addEventListener("pointerup", released, true);
  window.addEventListener("pointercancel", released, true);
  t = window.setTimeout(done, 10_000);
}
