export type GpxRoute = { rank: number; elevation: number; distance: number; points: Float32Array };

/** One `<trk>` element, matching the CLI's `writeGpx` shape (7 decimal places). */
function trackXml(route: GpxRoute): string {
  const p = route.points;
  let out = `<trk>\n<name>zill rank ${route.rank} | elev ${route.elevation}m | dist ${route.distance}m | ${p.length / 3} pts</name>\n<trkseg>\n`;
  for (let i = 0; i < p.length; i += 3) {
    out += `<trkpt lat="${p[i].toFixed(7)}" lon="${p[i + 1].toFixed(7)}"><ele>${p[i + 2]}</ele></trkpt>\n`;
  }
  return out + '</trkseg>\n</trk>\n';
}

function gpxDocument(routes: GpxRoute[], createdAt: Date): string {
  let out =
    '<?xml version="1.0" encoding="UTF-8"?>\n' +
    '<gpx version="1.1" creator="zill" xmlns="http://www.topografix.com/GPX/1/1">\n' +
    `<metadata><time>${createdAt.toISOString()}</time></metadata>\n`;
  for (const route of routes) out += trackXml(route);
  return out + '</gpx>\n';
}

/** GPX 1.1 track for one route. `points` is interleaved lat, lng, elevation triples. */
export function routeToGpx(route: GpxRoute, createdAt: Date): string {
  return gpxDocument([route], createdAt);
}

/** Saves one or more routes as a single GPX download. */
export function downloadGpx(routes: GpxRoute[], filename: string, createdAt: Date): void {
  const url = URL.createObjectURL(new Blob([gpxDocument(routes, createdAt)], { type: 'application/gpx+xml' }));
  const a = document.createElement('a');
  a.href = url;
  a.download = filename;
  a.click();
  URL.revokeObjectURL(url);
}
