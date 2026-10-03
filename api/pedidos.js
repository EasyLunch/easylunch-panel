// Vercel Serverless Function — Recorridos: trae los pedidos del sistema Easy Lunch (app.easylunch.com.ar)
// y devuelve SOLO la cantidad de viandas por empresa y por día (sin datos personales).
//
// GET /api/pedidos?desde=2026-09-28&hasta=2026-10-02
// respuesta: { desde, hasta, filas: [{ id_empresa, empresa, fecha, viandas }], total,
//             extras: [{ id_empresa, empresa, fecha, postres, bebidas }], ajustes: { ok, aplicados, actualizado } }
// viandas = pedidos con plato. extras = postres y bebidas (incluye los pedidos de solo postre o solo bebida).
//
// Cambios cargados en la app de Modificaciones (altas, bajas, cambios de día/sede, temporales, impagos sacados,
// empresas de prueba): la app publica en Supabase (rutas_config, id "mods_pedidos") la diferencia por empresa y día
// entre los pedidos con modificaciones y los del sistema. Acá se suma a lo que trae el sistema.
// Si no se puede leer, se devuelve solo lo del sistema (ajustes.ok = false).
//
// Sábados y domingos: se entregan junto con el viernes (o el día que se elija en Modificaciones si el viernes es
// feriado). La app publica ese mapa en la misma fila (data.entregaFinde = { 'AAAA-MM-DD': 'AAAA-MM-DD' }); si no está,
// se usa el viernes anterior. Las filas de fin de semana salen con la fecha del día de entrega.

const ORIGEN = process.env.PEDIDOS_URL || 'https://app.easylunch.com.ar/server/easylunch/traer_pedidos_de_todos_los_usuarios.php'
const MESES = { enero: 1, febrero: 2, marzo: 3, abril: 4, mayo: 5, junio: 6, julio: 7, agosto: 8, septiembre: 9, setiembre: 9, octubre: 10, noviembre: 11, diciembre: 12 }
const pad = n => String(n).padStart(2, '0')
const okFecha = s => /^\d{4}-\d{2}-\d{2}$/.test(String(s || ''))
// Misma base y misma clave pública que usa Recorridos
const SB = process.env.SUPABASE_URL || 'https://xlwcozznliafhouhqjzl.supabase.co/rest/v1'
const KEY = process.env.SUPABASE_ANON_KEY ||
  'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6Inhsd2NvenpubGlhZmhvdWhxanpsIiwicm9sZSI6ImFub24iLCJpYXQiOjE3ODA5NTkwMzAsImV4cCI6MjA5NjUzNTAzMH0.i-GTNnGK_5GMUum_tmUKIiX4NUkmEiJovK_M7BwGFfg'

/** Día de entrega: sábado/domingo → el que diga el mapa, o el viernes anterior; el resto, el mismo día. */
function diaEntrega(fecha, mapa) {
  if (mapa && mapa[fecha]) return mapa[fecha]
  const d = new Date(fecha + 'T12:00:00Z'), w = d.getUTCDay()
  if (w !== 6 && w !== 0) return fecha
  d.setUTCDate(d.getUTCDate() - (w === 6 ? 1 : 2))
  return d.toISOString().slice(0, 10)
}

async function leerAjustes() {
  const r = await fetch(SB + '/rutas_config?select=data&id=eq.mods_pedidos', { headers: { apikey: KEY, Authorization: 'Bearer ' + KEY } })
  if (!r.ok) throw new Error('Supabase ' + r.status)
  const rows = await r.json()
  return (rows[0] && rows[0].data) || null
}

export default async function handler(req, res) {
  res.setHeader('Access-Control-Allow-Origin', '*')
  res.setHeader('Cache-Control', 'no-store')
  if (req.method === 'OPTIONS') return res.status(204).end()

  const { desde, hasta } = req.query || {}
  if (!okFecha(desde) || !okFecha(hasta)) return res.status(400).json({ error: 'fechas', message: 'Pasá desde y hasta como AAAA-MM-DD' })

  try {
    const pAjustes = leerAjustes().catch(e => ({ error: String((e && e.message) || e) }))
    const r = await fetch(ORIGEN, { headers: { Accept: 'application/json' } })
    if (!r.ok) return res.status(502).json({ error: 'origen', message: 'El sistema de pedidos respondió ' + r.status })
    const data = await r.json()
    if (!Array.isArray(data)) return res.status(502).json({ error: 'formato', message: 'El sistema de pedidos no devolvió una lista' })
    const aj = await pAjustes
    const mapaFinde = (aj && aj.entregaFinde) || {}

    const agg = new Map()
    const ext = new Map()
    const orden = (a, b) => a.fecha.localeCompare(b.fecha) || a.empresa.localeCompare(b.empresa)
    for (const x of data) {
      const mes = MESES[String(x.mes || '').trim().toLowerCase()] || parseInt(x.mes, 10)
      if (!mes || !x.anio || !x.dia) continue
      const fecha = diaEntrega(`${x.anio}-${pad(mes)}-${pad(x.dia)}`, mapaFinde)
      if (fecha < desde || fecha > hasta) continue
      const key = x.id_empresa + '|' + fecha
      const empresa = String(x.nombre_empresa || '').trim()
      const postre = !!String(x.postre || '').trim()
      const bebida = !!String(x.bebida || '').trim()
      if (postre || bebida) {
        const e = ext.get(key) || { id_empresa: String(x.id_empresa), empresa, fecha, postres: 0, bebidas: 0 }
        if (postre) e.postres++
        if (bebida) e.bebidas++
        ext.set(key, e)
      }
      if (!String(x.plato || '').trim()) continue // viandas = solo los pedidos con plato
      const cur = agg.get(key) || { id_empresa: String(x.id_empresa), empresa, fecha, viandas: 0 }
      cur.viandas++
      agg.set(key, cur)
    }

    // Cambios de la app de Modificaciones
    const ajustes = { ok: !!(aj && !aj.error), aplicados: 0, actualizado: (aj && aj.actualizado) || null }
    if (aj && aj.error) ajustes.error = aj.error
    for (const x of (aj && Array.isArray(aj.deltas) ? aj.deltas : [])) {
      if (!okFecha(x.fecha)) continue
      const fecha = diaEntrega(x.fecha, mapaFinde)
      if (fecha < desde || fecha > hasta) continue
      const key = x.id_empresa + '|' + fecha
      const empresa = String(x.empresa || '').trim()
      const v = parseInt(x.viandas, 10) || 0, p = parseInt(x.postres, 10) || 0, b = parseInt(x.bebidas, 10) || 0
      if (v) {
        const cur = agg.get(key) || { id_empresa: String(x.id_empresa), empresa, fecha, viandas: 0 }
        cur.viandas = Math.max(0, cur.viandas + v)
        agg.set(key, cur)
      }
      if (p || b) {
        const e = ext.get(key) || { id_empresa: String(x.id_empresa), empresa, fecha, postres: 0, bebidas: 0 }
        e.postres = Math.max(0, e.postres + p)
        e.bebidas = Math.max(0, e.bebidas + b)
        ext.set(key, e)
      }
      ajustes.aplicados++
    }

    const filas = [...agg.values()].filter(f => f.viandas > 0).sort(orden)
    const extras = [...ext.values()].filter(e => e.postres > 0 || e.bebidas > 0).sort(orden)
    return res.status(200).json({ desde, hasta, filas, total: filas.reduce((a, f) => a + f.viandas, 0), extras, ajustes })
  } catch (e) {
    return res.status(500).json({ error: 'interno', message: String((e && e.message) || e) })
  }
}
