// Vercel Serverless Function — Orden de carga: dice en qué vehículo y en qué orden se entrega cada empresa un día.
// La usa la app de Modificaciones de pedidos (Apps Script) para ordenar la solapa "Base" de la comanda.
// Lee los recorridos que se arman en Recorridos (Supabase: rutas_config, rutas_clientes, rutas_recorridos).
// No devuelve datos personales: solo empresas, vehículos y posiciones.
//
// GET /api/orden-carga?fecha=2026-10-05
// respuesta: {
//   fecha, dia: 'lun', hayRecorrido: true,
//   vehiculos: [{ idx, nombre, tipo }],                      // camionetas primero, después motos (orden de carga)
//   empresas: { [id_empresa]: { cliente, vehiculo, tipo, vehIdx, viaje, entrega, paradas, fuente } }
// }
// fuente: 'recorrido' (recorrido armado para ese día) o 'habitual' (recorrido de siempre, si ese día no la tiene).

const SB = process.env.SUPABASE_URL || 'https://xlwcozznliafhouhqjzl.supabase.co/rest/v1'
const KEY = process.env.SUPABASE_ANON_KEY ||
  'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6Inhsd2NvenpubGlhZmhvdWhxanpsIiwicm9sZSI6ImFub24iLCJpYXQiOjE3ODA5NTkwMzAsImV4cCI6MjA5NjUzNTAzMH0.i-GTNnGK_5GMUum_tmUKIiX4NUkmEiJovK_M7BwGFfg'
const H = { apikey: KEY, Authorization: 'Bearer ' + KEY }
const DIAS = ['', 'lun', 'mar', 'mie', 'jue', 'vie', '']
const okFecha = s => /^\d{4}-\d{2}-\d{2}$/.test(String(s || ''))

async function sbGet(q) {
  const r = await fetch(SB + '/' + q, { headers: H })
  if (!r.ok) throw new Error('Supabase ' + r.status + ': ' + (await r.text()).slice(0, 200))
  return r.json()
}

// Igual que vehicles() de recorridos.html
function vehiculos(c) {
  const V = []
  const nv = Math.max(0, Math.min(8, parseInt(c.vans, 10) || 0))
  const nm = Math.max(0, Math.min(12, parseInt(c.motos, 10) || 0))
  for (let i = 0; i < nv; i++) V.push({ idx: i, nombre: 'Camioneta ' + (i + 1), tipo: 'camioneta' })
  for (let i = 0; i < nm; i++) V.push({ idx: nv + i, nombre: 'Moto ' + (i + 1), tipo: 'moto' })
  if (!V.length) V.push({ idx: 0, nombre: 'Camioneta 1', tipo: 'camioneta' })
  return V
}

export default async function handler(req, res) {
  res.setHeader('Access-Control-Allow-Origin', '*')
  res.setHeader('Cache-Control', 'no-store')
  if (req.method === 'OPTIONS') return res.status(204).end()

  const { fecha } = req.query || {}
  if (!okFecha(fecha)) return res.status(400).json({ error: 'fecha', message: 'Pasá fecha como AAAA-MM-DD' })
  const dia = DIAS[new Date(fecha + 'T12:00:00Z').getUTCDay()]
  if (!dia) return res.status(200).json({ fecha, dia: null, hayRecorrido: false, vehiculos: [], empresas: {} })

  try {
    const [cfgRows, cliRows, rutRows] = await Promise.all([
      sbGet('rutas_config?select=data&id=eq.main'),
      sbGet('rutas_clientes?select=id,data'),
      sbGet('rutas_recorridos?select=dia,data&dia=eq.' + dia)
    ])
    const cfg = (cfgRows[0] && cfgRows[0].data) || {}
    const V = vehiculos(cfg)
    const veh = i => V.find(v => v.idx === i) || { idx: i, nombre: 'Vehículo ' + (i + 1), tipo: 'camioneta' }
    const clientes = {}
    cliRows.forEach(r => { clientes[r.id] = r.data || {} })

    // posición de cada cliente en el recorrido del día
    const pos = {}
    const ruta = rutRows[0] && rutRows[0].data
    const cuenta = {}
    ;((ruta && ruta.trips) || []).forEach(t => {
      const van = t.van | 0
      cuenta[van] = (cuenta[van] || 0) + 1
      const viaje = t.trip | 0 || cuenta[van]
      const stops = (t.stops || []).filter(id => clientes[id])
      stops.forEach((id, i) => {
        if (!pos[id]) pos[id] = { vehIdx: van, viaje, entrega: i + 1, paradas: stops.length, fuente: 'recorrido' }
      })
    })

    // si ese día no está en el recorrido: su vehículo de siempre (sin posición exacta, va al final de ese vehículo)
    const habit = (cfg.habit && cfg.habit[dia]) || {}
    Object.keys(habit).forEach(id => {
      if (pos[id] || !clientes[id] || !habit[id]) return
      pos[id] = { vehIdx: habit[id].v | 0, viaje: 1, entrega: 999, paradas: null, fuente: 'habitual' }
    })

    // empresas del sistema → cliente de Recorridos
    const empresas = {}
    const empMap = cfg.empMap || {}
    Object.keys(empMap).forEach(idEmp => {
      const cli = empMap[idEmp]
      if (!cli || cli === '_ign' || !pos[cli]) return
      const p = pos[cli], v = veh(p.vehIdx)
      empresas[idEmp] = { cliente: clientes[cli].name || '', vehiculo: v.nombre, tipo: v.tipo, ...p }
    })

    // degustaciones (clientes "deg_<id>" que carga la app de Modificaciones): se devuelven con su propio id
    Object.keys(pos).forEach(id => {
      if (!id.startsWith('deg_')) return
      const p = pos[id], v = veh(p.vehIdx)
      empresas[id] = { cliente: clientes[id].name || '', vehiculo: v.nombre, tipo: v.tipo, ...p }
    })

    return res.status(200).json({ fecha, dia, hayRecorrido: !!(ruta && (ruta.trips || []).length), vehiculos: V, empresas })
  } catch (e) {
    return res.status(500).json({ error: 'interno', message: String((e && e.message) || e) })
  }
}
