// Vercel Serverless Function — Recorridos: ordena y calcula un viaje con tránsito usando Google Routes API.
// La clave NO va en el navegador: se lee de la variable de entorno GOOGLE_ROUTES_KEY (Vercel → Settings → Environment Variables).
//
// POST /api/ruta-google
// body: {
//   origin: {lat, lng},                 // cocina
//   stops: [{lat, lng}, ...],           // paradas en el orden actual (máx. 25)
//   returnToBase: true|false,           // si vuelve a la cocina
//   departureTime: "2026-09-24T08:30:00-03:00"
// }
// respuesta: { order: [índices de stops en el orden optimizado], legs: [{s, m}], polyline: "..." }

const URL_ROUTES = 'https://routes.googleapis.com/directions/v2:computeRoutes'

const wp = p => ({ location: { latLng: { latitude: +p.lat, longitude: +p.lng } } })
const secs = d => (d ? parseFloat(String(d).replace('s', '')) || 0 : 0)

export default async function handler(req, res) {
  res.setHeader('Access-Control-Allow-Origin', '*')
  res.setHeader('Access-Control-Allow-Methods', 'POST, OPTIONS')
  res.setHeader('Access-Control-Allow-Headers', 'Content-Type')
  if (req.method === 'OPTIONS') return res.status(204).end()
  if (req.method !== 'POST') return res.status(405).json({ error: 'Usá POST' })

  const KEY = process.env.GOOGLE_ROUTES_KEY
  if (!KEY) return res.status(503).json({ error: 'sin_clave', message: 'Falta configurar GOOGLE_ROUTES_KEY en Vercel' })

  try {
    const body = typeof req.body === 'string' ? JSON.parse(req.body) : (req.body || {})
    const { origin, stops = [], returnToBase = true, departureTime, moto = false } = body
    if (!origin || !Array.isArray(stops) || !stops.length) return res.status(400).json({ error: 'datos_incompletos' })
    if (stops.length > 26) return res.status(400).json({ error: 'demasiadas_paradas', message: 'Google acepta hasta 25 paradas por viaje' })

    // Si vuelve a la base: origen y destino = cocina, todas las paradas son intermedias y se optimizan.
    // Si no vuelve: la última parada queda fija como destino y se optimizan las del medio.
    const intermediates = returnToBase ? stops : stops.slice(0, -1)
    const destination = returnToBase ? origin : stops[stops.length - 1]

    let dep = departureTime ? new Date(departureTime) : new Date()
    if (isNaN(dep) || dep.getTime() < Date.now() + 60000) dep = new Date(Date.now() + 5 * 60000)

    const build = mode => ({
      origin: wp(origin),
      destination: wp(destination),
      intermediates: intermediates.map(wp),
      travelMode: mode,
      routingPreference: 'TRAFFIC_AWARE',
      departureTime: dep.toISOString(),
      optimizeWaypointOrder: intermediates.length > 1,
      extraComputations: ['TRAFFIC_ON_POLYLINE'],
      languageCode: 'es-419',
      units: 'METRIC'
    })
    const call = async mode => {
      const r = await fetch(URL_ROUTES, {
        method: 'POST',
        headers: {
          'Content-Type': 'application/json',
          'X-Goog-Api-Key': KEY,
          'X-Goog-FieldMask': 'routes.optimizedIntermediateWaypointIndex,routes.legs.duration,routes.legs.distanceMeters,routes.polyline.encodedPolyline,routes.duration,routes.distanceMeters,routes.travelAdvisory.speedReadingIntervals'
        },
        body: JSON.stringify(build(mode))
      })
      return { r, j: await r.json() }
    }
    // Motos: se intenta el modo moto de Google; si no está disponible para la zona, se calcula como auto.
    let usedMode = moto ? 'TWO_WHEELER' : 'DRIVE'
    let { r, j } = await call(usedMode)
    if (moto && (!r.ok || !j.routes || !j.routes.length)) { usedMode = 'DRIVE'; ({ r, j } = await call('DRIVE')) }
    if (!r.ok || !j.routes || !j.routes.length) {
      return res.status(502).json({ error: 'google', message: (j.error && j.error.message) || 'Google no devolvió ruta' })
    }
    const route = j.routes[0]
    let order = intermediates.map((_, i) => i)
    if (Array.isArray(route.optimizedIntermediateWaypointIndex) && route.optimizedIntermediateWaypointIndex.length === intermediates.length && route.optimizedIntermediateWaypointIndex[0] !== -1) {
      order = route.optimizedIntermediateWaypointIndex
    }
    if (!returnToBase) order = order.concat([stops.length - 1])

    return res.status(200).json({
      order,
      legs: (route.legs || []).map(l => ({ s: secs(l.duration), m: l.distanceMeters || 0 })),
      polyline: route.polyline ? route.polyline.encodedPolyline : null,
      traffic: ((route.travelAdvisory && route.travelAdvisory.speedReadingIntervals) || []).map(x => ({ a: x.startPolylinePointIndex || 0, b: x.endPolylinePointIndex || 0, sp: x.speed || 'NORMAL' })),
      mode: usedMode,
      departureTime: dep.toISOString()
    })
  } catch (e) {
    return res.status(500).json({ error: 'interno', message: String(e && e.message || e) })
  }
}
