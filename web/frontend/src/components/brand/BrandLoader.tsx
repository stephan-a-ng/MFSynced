import { FlowerMark } from './FlowerMark';

/**
 * The mark's two colours as theme tokens: petals take the accent, the inner
 * disc its contrast — ink on yellow in light, yellow on ink in dark — so the
 * bloom keeps its two-tone separation on either plane. (Deploy's BrandLoader
 * pattern, mapped onto this app's token names.)
 */
const THEMED_MARK = {
  '#141303': 'var(--color-primary)',
  '#fcd01b': 'var(--color-primary-foreground)',
};

/** Full-viewport brand loading screen — the blooming flower mark, large. */
export function BrandLoader({ label = 'Loading…' }: { label?: string }) {
  return (
    <div
      data-testid="brand-loader"
      className="fixed inset-0 z-50 flex min-h-screen flex-col items-center justify-center gap-8 bg-background text-foreground"
    >
      <FlowerMark
        loop
        trueColor
        colorMap={THEMED_MARK}
        fill="#1a1508"
        size="min(38vw, 300px)"
        className="h-[min(38vw,300px)] w-[min(38vw,300px)] flex-none"
      />
      <p
        role="status"
        className="m-0 text-[11px] font-bold tracking-[0.34em] text-muted-foreground uppercase"
      >
        {label}
      </p>
    </div>
  );
}

/** Inline blooming-flower spinner for in-page loading states. */
export function FlowerSpinner({ size = '48px' }: { size?: string }) {
  return (
    <FlowerMark
      loop
      trueColor
      colorMap={THEMED_MARK}
      fill="#1a1508"
      size={size}
      className="flex-none"
    />
  );
}
