import { useEffect, useRef } from "react";

import {
  FLOWER_DEFAULT,
  FLOWER_HOVER,
  FLOWER_SPRING,
  type FlowerNode,
} from "./flowerMarkSpec";

/**
 * The Moon Five flower mark, blooming on hover.
 *
 * Two Figma states (default / hover) with matching node trees; a spring
 * drives a single scalar `x` from 0 → 1 and every node's transform, opacity
 * and path geometry is lerped by it. That is Figma's own SMART_ANIMATE
 * semantics, and it's why the spec's two states must stay structurally
 * identical — see flowerMarkSpec.ts.
 *
 * Ported from the design's `<flower-mark>` custom element. Like ChordMark the
 * per-frame work is imperative: ~12 nodes × (transform + opacity + a rebuilt
 * `d`) per frame is not React's job.
 *
 * Decorative: `aria-hidden`. Under `prefers-reduced-motion` it snaps between
 * the two states instead of springing, and never autoplays.
 */
export interface FlowerMarkProps {
  /** CSS length for the rendered box. */
  size?: string;
  /** Ink for every path — the design's runtime paints the whole mark one colour. */
  fill?: string;
  /** Play the bloom once shortly after mount, then settle back. */
  autoplay?: boolean;
  /**
   * Bloom open and closed forever, for use as a busy indicator.
   *
   * Drives the same spring as hover and `autoplay` — just re-aimed on a timer
   * — so the loop is the mark's own motion rather than a second, competing
   * animation. Ignored under `prefers-reduced-motion`, where a perpetually
   * moving element is exactly what the setting asks us not to render.
   */
  loop?: boolean;
  /**
   * Paint each shape its own colour from the spec instead of one flat `fill`.
   *
   * Needed at large sizes. Monochrome is right for a 26px mark, but the open
   * state is a disc with six shapes sitting on top of it — flatten those to a
   * single ink and they merge into a featureless blob, which is what "the
   * animation squishes out the details" looks like. The original's yellow
   * disc is what separates them.
   */
  trueColor?: boolean;
  /**
   * Remap the spec's own fills, for `trueColor` marks that must sit on a
   * different plane. Keys are the spec colours (`#141303` ink petals,
   * `#fcd01b` the inner disc); values are anything CSS accepts as a fill,
   * including `var(--token)`.
   *
   * This is how the mark goes dark-mode: the two-tone contrast is what keeps
   * the open bloom from merging into a blob, so it has to be preserved and
   * inverted, not flattened to a single colour.
   */
  colorMap?: Record<string, string>;
  className?: string;
}

/**
 * Time the bloom is held at each end of a `loop` cycle.
 *
 * Must exceed the spring's own settle time (~1.53s at k=44.44, damping=10,
 * mass=1, per the source spec) or each cycle is cut off mid-flight and the
 * bloom never actually reaches its open shape.
 */
const LOOP_HOLD_MS = 1750;

/**
 * The looping bloom's phase, kept at module scope so it survives a REMOUNT.
 *
 * The loading mark is mounted more than once in a normal boot — StrictMode
 * double-invokes effects in development, and a Suspense handover can swap the
 * element's position in the tree. Each mount rebuilds the SVG and would
 * otherwise restart the spring at 0, so a bloom that takes ~1.5s to open never
 * finished: the reader saw its opening frames on repeat. Resuming from the
 * shared phase makes the animation continuous no matter how often the
 * component is torn down.
 */
const loopPhase = { x: 0, v: 0, target: 1, at: 0 };

const NS = "http://www.w3.org/2000/svg";

interface Pair {
  a: FlowerNode;
  b: FlowerNode;
  el: SVGElement;
}

/** Decomposed affine transform, about the node's own box centre. */
interface Decomposed {
  cx: number;
  cy: number;
  rot: number;
  sx: number;
  sy: number;
  w: number;
  h: number;
}

const lerp = (a: number, b: number, t: number): number => a + (b - a) * t;

/**
 * Split a Figma matrix into centre / rotation / scale so the two states can
 * be interpolated in a way that rotates rather than shears. Interpolating the
 * six matrix components directly would collapse the mark through zero on any
 * pair whose rotations differ by ~180° — which the hover state's root does.
 */
function decompose(m: number[], w: number, h: number): Decomposed {
  const [a, b, c, d, e, f] = m;
  const sx = Math.hypot(a, b) || 1;
  return {
    cx: (a * w) / 2 + (c * h) / 2 + e,
    cy: (b * w) / 2 + (d * h) / 2 + f,
    rot: Math.atan2(b, a),
    sx,
    sy: (a * d - b * c) / sx,
    w,
    h,
  };
}

function prefersReducedMotion(): boolean {
  return (
    typeof window !== "undefined" &&
    typeof window.matchMedia === "function" &&
    window.matchMedia("(prefers-reduced-motion: reduce)").matches
  );
}

export function FlowerMark({
  size = "100%",
  fill = "#141303",
  autoplay = false,
  loop = false,
  trueColor = false,
  colorMap,
  className,
}: FlowerMarkProps) {
  const hostRef = useRef<HTMLSpanElement>(null);

  useEffect(() => {
    const host = hostRef.current;
    if (!host) return;

    const svg = document.createElementNS(NS, "svg");
    svg.setAttribute("viewBox", "0 0 90 90");
    svg.setAttribute("aria-hidden", "true");
    svg.style.width = size;
    svg.style.height = size;
    svg.style.display = "block";
    host.appendChild(svg);

    // ── build the paired tree ─────────────────────────────────────────────
    const pairs: Pair[] = [];
    const build = (a: FlowerNode, b: FlowerNode, parent: SVGElement): SVGElement => {
      let el: SVGElement;
      if (a.paths) {
        el = document.createElementNS(NS, "path");
        // Monochrome by default, matching the design's own runtime, which
        // paints every path with the single `fill` prop. `trueColor` restores
        // the per-node fills the .fig carried — see the prop's docstring for
        // why that matters once the mark is rendered large.
        const own = a.fill ?? fill;
        el.setAttribute("fill", trueColor ? (colorMap?.[own] ?? own) : fill);
      } else {
        el = document.createElementNS(NS, "g");
      }
      parent.appendChild(el);
      pairs.push({ a, b, el });
      (a.children ?? []).forEach((childA, i) => {
        const childB = b.children?.[i];
        if (childB) build(childA, childB, el);
      });
      return el;
    };
    const rootEl = build(FLOWER_DEFAULT, FLOWER_HOVER, svg);

    // ── apply a morph position ────────────────────────────────────────────
    const apply = (raw: number): void => {
      // The spring overshoots past 1 and below 0. Geometry is clamped (so it
      // never inverts), but the overshoot is kept as `exc` and spent on the
      // root's spin + scale — that's what gives the bloom its snap.
      const exc = raw - Math.max(0, Math.min(1, raw));
      const x = Math.max(0, Math.min(1, raw));

      for (const { a, b, el } of pairs) {
        const da = decompose(a.matrix, a.size[0], a.size[1]);
        const db = decompose(b.matrix, b.size[0], b.size[1]);

        // Take the short way round.
        let dr = db.rot - da.rot;
        while (dr > Math.PI) dr -= 2 * Math.PI;
        while (dr < -Math.PI) dr += 2 * Math.PI;

        const rot = da.rot + dr * x;
        const cx = lerp(da.cx, db.cx, x);
        const cy = lerp(da.cy, db.cy, x);
        const sx = lerp(da.sx, db.sx, x);
        const sy = lerp(da.sy, db.sy, x);
        const w = lerp(da.w, db.w, x);
        const h = lerp(da.h, db.h, x);

        const cos = Math.cos(rot);
        const sin = Math.sin(rot);
        const ma = sx * cos;
        const mb = sx * sin;
        const mc = -sy * sin;
        const md = sy * cos;
        // Recompose about the centre.
        const me = cx - ((ma * w) / 2 + (mc * h) / 2);
        const mf = cy - ((mb * w) / 2 + (md * h) / 2);

        const transform =
          el === rootEl
            ? // The root also carries the 20px inset into the 90-unit
              // viewBox, plus the overshoot spin and swell.
              `translate(20 20) rotate(${exc * 180} 25 25) ` +
              `translate(25 25) scale(${1 + 0.1224 * exc}) translate(-25 -25)`
            : `matrix(${ma} ${mb} ${mc} ${md} ${me} ${mf})`;
        el.setAttribute("transform", transform);
        el.setAttribute("opacity", lerp(a.opacity, b.opacity, x).toFixed(3));

        if (a.paths && b.paths) {
          let d = "";
          for (let p = 0; p < a.paths.length; p++) {
            const pa = a.paths[p];
            const pb = b.paths[p];
            for (let i = 0; i < pa.length; i++) {
              d += pa[i][0];
              for (let j = 1; j < pa[i].length; j++) {
                d += lerp(pa[i][j] as number, pb[i][j] as number, x).toFixed(3) + " ";
              }
            }
          }
          el.setAttribute("d", d);
        }
      }
    };

    // ── spring ────────────────────────────────────────────────────────────
    const reduced = prefersReducedMotion();
    let x = 0;
    let v = 0;
    let target = 0;
    let raf = 0;
    let last: number | null = null;

    const tick = (ts: number): void => {
      if (last == null) last = ts;
      const dt = Math.min((ts - last) / 1000, 0.05);
      last = ts;
      // Sub-step at ~4ms so a long frame can't make the spring explode.
      const steps = Math.ceil(dt / 0.004) || 1;
      const h = dt / steps;
      for (let i = 0; i < steps; i++) {
        const accel =
          (FLOWER_SPRING.stiffness * (target - x) - FLOWER_SPRING.damping * v) /
          FLOWER_SPRING.mass;
        v += accel * h;
        x += v * h;
      }
      apply(x);
      if (Math.abs(target - x) < 0.0005 && Math.abs(v) < 0.0005) {
        x = target;
        v = 0;
        apply(x);
        raf = 0;
        last = null;
        return;
      }
      raf = requestAnimationFrame(tick);
    };

    const setTarget = (t: number): void => {
      target = t;
      if (reduced) {
        // No spring, no overshoot — just the end state.
        x = t;
        v = 0;
        apply(x);
        return;
      }
      if (!raf) {
        last = null;
        raf = requestAnimationFrame(tick);
      }
    };

    const onEnter = (): void => setTarget(1);
    const onLeave = (): void => setTarget(0);
    const onClick = (): void => setTarget(target > 0.5 ? 0 : 1);
    host.addEventListener("pointerenter", onEnter);
    host.addEventListener("pointerleave", onLeave);
    host.addEventListener("click", onClick);

    apply(0);

    // Autoplay is a greeting, not information — reduced motion skips it and
    // the mark simply sits in its default state.
    let bloomIn: ReturnType<typeof setTimeout> | undefined;
    let bloomOut: ReturnType<typeof setTimeout> | undefined;
    let cycle: ReturnType<typeof setInterval> | undefined;
    if (loop && !reduced) {
      // Resume where the last mount left off rather than snapping shut and
      // starting over. `at` also carries the interval's phase, so the cycle
      // keeps its cadence across a remount instead of restarting its clock.
      const now = performance.now();
      const elapsed = loopPhase.at === 0 ? 0 : now - loopPhase.at;
      x = loopPhase.x;
      v = loopPhase.v;
      target = loopPhase.target;
      apply(x);

      // Advance the cycle by however many holds elapsed while unmounted.
      let phase = target;
      let remaining = LOOP_HOLD_MS - (elapsed % LOOP_HOLD_MS || 0);
      if (elapsed >= LOOP_HOLD_MS) {
        const flips = Math.floor(elapsed / LOOP_HOLD_MS);
        if (flips % 2 === 1) phase = phase > 0.5 ? 0 : 1;
      }
      if (loopPhase.at === 0) remaining = LOOP_HOLD_MS;
      setTarget(phase);

      const startCycle = () => {
        cycle = setInterval(() => setTarget(target > 0.5 ? 0 : 1), LOOP_HOLD_MS);
      };
      bloomIn = setTimeout(() => {
        setTarget(target > 0.5 ? 0 : 1);
        startCycle();
      }, remaining);
    } else if (autoplay && !reduced) {
      bloomIn = setTimeout(() => {
        setTarget(1);
        bloomOut = setTimeout(() => setTarget(0), 1600);
      }, 350);
    }

    return () => {
      if (loop) {
        // Hand the phase to the next mount.
        loopPhase.x = x;
        loopPhase.v = v;
        loopPhase.target = target;
        loopPhase.at = performance.now();
      }
      if (raf) cancelAnimationFrame(raf);
      if (bloomIn) clearTimeout(bloomIn);
      if (bloomOut) clearTimeout(bloomOut);
      if (cycle) clearInterval(cycle);
      host.removeEventListener("pointerenter", onEnter);
      host.removeEventListener("pointerleave", onLeave);
      host.removeEventListener("click", onClick);
      svg.remove();
    };
  }, [size, fill, autoplay, loop, trueColor, colorMap]);

  return (
    <span
      ref={hostRef}
      aria-hidden="true"
      className={className}
      style={{ display: "inline-block", lineHeight: 0 }}
    />
  );
}
