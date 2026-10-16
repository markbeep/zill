import { createSignal, For, Show } from 'solid-js';
import { findPlaces } from '../geocode';
import type { Place } from '../geocode';
import { CloseIcon, SearchIcon } from '../icons';

type PlaceSearchProps = {
  /** A chosen result: the camera goes there and the place is marked. */
  onPick: (place: Place) => void;
};

/** Keystrokes are cheap, the service is not. */
const SETTLE_MS = 180;
/** Below this the gazetteer answers with half the country at once. */
const MIN_CHARS = 3;

/** A magnifier that unfolds into the field, and stays out of the toolbar's way
 *  when it is folded: on a phone this control is one cell wide, not a row. */
export function PlaceSearch(props: PlaceSearchProps) {
  const [open, setOpen] = createSignal(false);
  const [text, setText] = createSignal('');
  const [results, setResults] = createSignal<Place[]>([]);
  const [active, setActive] = createSignal(-1);
  const [note, setNote] = createSignal<string | null>(null);

  let field: HTMLInputElement | undefined;
  let trigger: HTMLButtonElement | undefined;
  let list: HTMLUListElement | undefined;
  let controller: AbortController | undefined;
  let settle: number | undefined;

  function unfold(): void {
    setOpen(true);
    // The field is the whole point of the button: focus it, keyboard and all.
    field?.focus();
  }

  function fold(): void {
    clearTimeout(settle);
    controller?.abort();
    setOpen(false);
    setText('');
    setResults([]);
    setActive(-1);
    setNote(null);
    trigger?.focus();
  }

  function ask(next: string): void {
    setText(next);
    setActive(-1);
    setResults([]);
    clearTimeout(settle);
    controller?.abort();
    const query = next.trim();
    if (query.length < MIN_CHARS) {
      setNote(null);
      return;
    }
    setNote('searching.');
    settle = setTimeout(async () => {
      const pending = new AbortController();
      controller = pending;
      try {
        const found = await findPlaces(query, pending.signal);
        if (pending.signal.aborted) return;
        setResults(found);
        setNote(found.length > 0 ? null : 'no place by that name');
      } catch {
        if (pending.signal.aborted) return;
        setNote('the place search could not be reached');
      }
    }, SETTLE_MS);
  }

  function pick(place: Place): void {
    props.onPick(place);
    fold();
  }

  function onKey(event: KeyboardEvent): void {
    if (event.key === 'Escape') {
      event.preventDefault();
      fold();
      return;
    }
    const found = results();
    if (event.key === 'Enter') {
      if (found.length === 0) return;
      event.preventDefault();
      pick(found[Math.max(active(), 0)]);
      return;
    }
    if (event.key !== 'ArrowDown' && event.key !== 'ArrowUp') return;
    event.preventDefault();
    if (found.length === 0) return;
    const step = event.key === 'ArrowDown' ? 1 : -1;
    const next = Math.min(found.length - 1, Math.max(0, active() + step));
    setActive(next);
    list?.children[next]?.scrollIntoView({ block: 'nearest' });
  }

  return (
    <div class="search">
      <Show
        when={open()}
        fallback={
          <button
            type="button"
            class="toolbar__button toolbar__button--icon"
            ref={trigger}
            onClick={unfold}
            title="search for a place by name"
            aria-label="search for a place by name"
          >
            <SearchIcon />
          </button>
        }
      >
        <div class="search__field">
          <input
            ref={field}
            class="search__input"
            type="text"
            autocomplete="off"
            spellcheck={false}
            aria-label="place name"
            placeholder="place name"
            value={text()}
            onInput={(event) => ask(event.currentTarget.value)}
            onKeyDown={onKey}
          />
          <button
            type="button"
            class="search__fold"
            onClick={fold}
            title="close the place search"
            aria-label="close the place search"
          >
            <CloseIcon />
          </button>
        </div>
        <Show when={note() !== null || results().length > 0}>
          <div class="search__panel">
            <Show when={note()}>
              <p class="search__note">{note()}</p>
            </Show>
            <Show when={results().length > 0}>
              <ul class="search__results" ref={list}>
                <For each={results()}>
                  {(place, index) => (
                    <li>
                      <button
                        type="button"
                        class="search__result"
                        classList={{ 'is-active': active() === index() }}
                        onClick={() => pick(place)}
                        onMouseEnter={() => setActive(index())}
                      >
                        {place.label}
                      </button>
                    </li>
                  )}
                </For>
              </ul>
            </Show>
          </div>
        </Show>
      </Show>
    </div>
  );
}
