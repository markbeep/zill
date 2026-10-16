// Place search from swisstopo's own gazetteer, address index and municipality
// list. Keyless, CORS-open and the same source as the basemap, so a name typed
// here lands on ground the camera can actually show.

const ENDPOINT = 'https://api3.geo.admin.ch/rest/services/api/SearchServer';

export type Place = {
  label: string;
  lat: number;
  lng: number;
  /** How close the camera goes: what the result is decides, not the service. */
  zoom: number;
};

/** The service answers `zoomlevel` as a map scale, and answers garbage for
 *  whole-municipality hits (a uint32 sentinel), so the kind of place decides.
 *  Municipalities and cantons are asked for as polygons: their "position" is a
 *  centroid on some mountainside, which is not where a visitor wants to land. */
const ZOOM_BY_ORIGIN: Record<string, number> = {
  address: 16,
  zipcode: 14,
  gazetteer: 13,
};

const FALLBACK_ZOOM = 13;
const LIMIT = 6;

/** Labels are marked up: the object's class in italics ("<i>Populated place</i>
 *  or "<i>Ort</i>", translated per request), the matched part in bold. The class
 *  is the service describing the place rather than naming it, so it goes; an
 *  address carries no class and is left whole. */
const CLASS = /^.*?<\/i>\s*/s;
const TAGS = /<[^>]*>/g;
/** A gazetteer label ends with the communes the name covers ("Zürich (ZH) -
 *  Dübendorf,Zollikon,…"), which is a directory, not a place, and it only ever
 *  follows the canton. A postcode keeps its tail: "8001 - Zürich" is the name. */
const COMMUNES = /^(.*\))\s+-\s+.*$/s;
/** A canton the service has no value for arrives as an empty bracket. */
const EMPTY = /\s*\(\s*\)/;
/** Multi-language names are joined with a machine's separator; the interface's
 *  own is the middle dot. */
const SPLIT = /\|/g;
const SPACES = /\s+/g;

export async function findPlaces(text: string, signal: AbortSignal): Promise<Place[]> {
  const url = new URL(ENDPOINT);
  url.searchParams.set('searchText', text);
  url.searchParams.set('type', 'locations');
  url.searchParams.set('origins', Object.keys(ZOOM_BY_ORIGIN).join(','));
  url.searchParams.set('limit', String(LIMIT));

  const response = await fetch(url, { signal });
  if (!response.ok) throw new Error(`the place search answered ${response.status}`);
  const body = (await response.json()) as { results?: { attrs?: Record<string, unknown> }[] };

  const seen = new Set<string>();
  return (body.results ?? []).flatMap((result) => {
    const attrs = result.attrs ?? {};
    const lat = Number(attrs.lat);
    const lng = Number(attrs.lon);
    const label = String(attrs.label ?? '')
      .replace(CLASS, '')
      .replace(COMMUNES, '$1')
      .replace(TAGS, '')
      .replace(EMPTY, '')
      .replace(SPLIT, ' · ')
      .replace(SPACES, ' ')
      .trim();
    if (!Number.isFinite(lat) || !Number.isFinite(lng) || label === '' || seen.has(label)) return [];
    seen.add(label);
    const origin = String(attrs.origin ?? '');
    return [{ label, lat, lng, zoom: ZOOM_BY_ORIGIN[origin] ?? FALLBACK_ZOOM }];
  });
}
