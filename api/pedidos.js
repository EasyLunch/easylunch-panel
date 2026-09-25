// Vercel Serverless Function — Recorridos: trae los pedidos del sistema Easy Lunch (app.easylunch.com.ar)
// y devuelve SOLO la cantidad de viandas por empresa y por día (sin datos personales).
//
// GET /api/pedidos?desde=2026-09-28&hasta=2026-10-02
// respuesta: { desde, hasta, filas: [{ id_empresa, empresa, fecha, viandas }], total }

const ORIGEN = process.env.PEDIDOS_URL || 'https://app.easylunch.com.ar/server/easylunch/traer_pedidos_de_todos_los_usuarios.php'
const MESES = { enero: 1, febrero: 2, marzo: 3, abril: 4, mayo: 5, junio: 6, julio: 7, agosto: 8, septiembre: 9, setiembre: 9, octubre: 10, noviembre: 11, diciembre: 12 }
const pad = n => String(n).padStart(2, '0')
const okFecha = s => /^\d{4}-\d{2}-\d{2}$/.test(String(s || ''))

export default async function handler(req, res) {
  res.setHeader('Access-Control-Allow-Origin', '*')
  res.setHeader('Cache-Control', 'no-store')
  if (req.method === 'OPTIONS') return res.status(204).end()

  const { desde, hasta } = req.query || {}
  if (!okFecha(desde) || !okFecha(hasta)) return res.status(400).json({ error: 'fechas', message: 'Pasá desde y hasta como AAAA-MM-DD' })

  try {
    const r = await fetch(ORIGEN, { headers: { Accept: 'application/json' } })
    if (!r.ok) return res.status(502).json({ error: 'origen', message: 'El sistema de pedidos respondió ' + r.status })
    const data = await r.json()
    if (!Array.isArray(data)) return res.status(502).json({ error: 'formato', message: 'El sistema de pedidos no devolvió una lista' })

    const agg = new Map()
    for (const x of data) {
      const mes = MESES[String(x.mes || '').trim().toLowerCase()] || parseInt(x.mes, 10)
      if (!mes || !x.anio || !x.dia) continue
      const fecha = `${x.anio}-${pad(mes)}-${pad(x.dia)}`
      if (fecha < desde || fecha > hasta) continue
      if (!String(x.plato || '').trim()) continue // solo cuenta viandas (no bebidas/postres sueltos)
      const key = x.id_empresa + '|' + fecha
      const cur = agg.get(key) || { id_empresa: String(x.id_empresa), empresa: String(x.nombre_empresa || '').trim(), fecha, viandas: 0 }
      cur.viandas++
      agg.set(key, cur)
    }
    const filas = [...agg.values()].sort((a, b) => a.fecha.localeCompare(b.fecha) || a.empresa.localeCompare(b.empresa))
    return res.status(200).json({ desde, hasta, filas, total: filas.reduce((a, f) => a + f.viandas, 0) })
  } catch (e) {
    return res.status(500).json({ error: 'interno', message: String((e && e.message) || e) })
  }
}
