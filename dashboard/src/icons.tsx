// Inline stroke icons for the map toolbar. They inherit `currentColor` and are
// always paired with an accessible name on their button.

const STROKE = {
  fill: 'none',
  stroke: 'currentColor',
  'stroke-width': 1.6,
  'stroke-linecap': 'round',
  'stroke-linejoin': 'round',
} as const;

export function LocateIcon() {
  return (
    <svg
      viewBox="0 0 20 20"
      width="14"
      height="14"
      aria-hidden="true"
      {...STROKE}
    >
      <circle cx="10" cy="10" r="5.5" />
      <circle cx="10" cy="10" r="1.6" fill="currentColor" stroke="none" />
      <path d="M10 1.5v3M10 15.5v3M1.5 10h3M15.5 10h3" />
    </svg>
  );
}

export function UndoIcon() {
  return (
    <svg
      viewBox="0 0 20 20"
      width="14"
      height="14"
      aria-hidden="true"
      {...STROKE}
    >
      <path d="M7.5 5.5 3.5 9.5l4 4" />
      <path d="M3.5 9.5h8a5 5 0 0 1 0 10h-2" />
    </svg>
  );
}

export function RedoIcon() {
  return (
    <svg
      viewBox="0 0 20 20"
      width="14"
      height="14"
      aria-hidden="true"
      {...STROKE}
    >
      <path d="M12.5 5.5l4 4-4 4" />
      <path d="M16.5 9.5h-8a5 5 0 0 0 0 10h2" />
    </svg>
  );
}

export function SearchIcon() {
  return (
    <svg
      viewBox="0 0 20 20"
      width="14"
      height="14"
      aria-hidden="true"
      {...STROKE}
    >
      <circle cx="8.7" cy="8.7" r="5.2" />
      <path d="M12.6 12.6 16.8 16.8" />
    </svg>
  );
}

export function CloseIcon() {
  return (
    <svg
      viewBox="0 0 20 20"
      width="11"
      height="11"
      aria-hidden="true"
      {...STROKE}
    >
      <path d="M5 5l10 10M15 5 5 15" />
    </svg>
  );
}

/** The play mark worn at a route's start, turned to the direction it leaves in.
 *  The map builds its markers out of DOM by hand rather than out of JSX, so this
 *  drawing travels as markup: the icon belongs with the rest of the set even
 *  where the consumer cannot import a component. */
export const ROUTE_START_MARK =
  '<svg viewBox="0 0 10 10" width="9" height="9" aria-hidden="true"><path d="M5 0.5 9.5 9.5 5 7.4 0.5 9.5Z" fill="currentColor"/></svg>';
