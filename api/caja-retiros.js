// Vercel Serverless Function · /api/caja-retiros
// Local Prosegur: pedidos del día hechos por la app (app.easylunch.com.ar) para retirar en el local.
// Devuelve solo lo necesario para entregar (nombre, apellido, últimos dígitos del DNI y qué pidió),
// sin mail ni celular. Las entregas se marcan en Supabase (caja_retiro_marcar), así nadie retira dos veces.
//
// POST { token, fecha? (AAAA-MM-DD, por defecto hoy) } → { fecha, pedidos: [...], retirados: [...] }
//
// Usa las mismas variables de entorno que Recorridos: EASYLUNCH_ADMIN_USER y EASYLUNCH_ADMIN_PASSWORD.
// Opcional: CAJA_EMPRESA_ID (por defecto 63 = PROSEGUR) y CAJA_EMPRESA (nombre, por defecto "PROSEGUR").

const ORIGEN = process.env.PEDIDOS_URL || 'https://app.easylunch.com.ar/server/easylunch/traer_pedidos_de_todos_los_usuarios.php'
const LOGIN = process.env.EASYLUNCH_LOGIN_URL || 'https://app.easylunch.com.ar/server/login/login-admin.php'
const EMPRESA_ID = String(process.env.CAJA_EMPRESA_ID || '63')
const EMPRESA = String(process.env.CAJA_EMPRESA || 'PROSEGUR').trim().toLowerCase()
const SB = String(process.env.SUPABASE_URL || 'https://xlwcozznliafhouhqjzl.supabase.co').replace(/\/+$/, '').replace(/\/rest\/v1$/, '') + '/rest/v1'
const ANON = process.env.SUPABASE_ANON_KEY ||
  'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6Inhsd2NvenpubGlhZmhvdWhxanpsIiwicm9sZSI6ImFub24iLCJpYXQiOjE3ODA5NTkwMzAsImV4cCI6MjA5NjUzNTAzMH0.i-GTNnGK_5GMUum_tmUKIiX4NUkmEiJovK_M7BwGFfg'
const MESES = { enero: 1, febrero: 2, marzo: 3, abril: 4, mayo: 5, junio: 6, julio: 7, agosto: 8, septiembre: 9, setiembre: 9, octubre: 10, noviembre: 11, diciembre: 12 }
const pad = n => String(n).padStart(2, '0')
const okFecha = s => /^\d{4}-\d{2}-\d{2}$/.test(String(s || ''))
const hoyBA = () => new Intl.DateTimeFormat('en-CA', { timeZone: 'America/Argentina/Buenos_Aires', year: 'numeric', month: '2-digit', day: '2-digit' }).format(new Date())
const si = v => v === 1 || v === '1' || v === true || String(v).toLowerCase() === 'si'

async function rpc(fn, args) {
  const r = await fetch(`${SB}/rpc/${fn}`, { method: 'POST', headers: { apikey: ANON, Authorization: 'Bearer ' + ANON, 'Content-Type': 'application/json' }, body: JSON.stringify(args) })
  const txt = await r.text()
  let d = null; try { d = txt ? JSON.parse(txt) : null } catch (e) { /* */ }
  if (!r.ok) throw Object.assign(new Error((d && (d.message || d.hint)) || ('Supabase ' + r.status)), { status: r.status })
  return d
}

let cookieAdmin = ''
async function sesionAdmin() {
  if (cookieAdmin) return cookieAdmin
  const user = String(process.env.EASYLUNCH_ADMIN_USER || '').trim()
  const pass = process.env.EASYLUNCH_ADMIN_PASSWORD || ''
  if (!user || !pass) throw Object.assign(new Error('Faltan EASYLUNCH_ADMIN_USER y/o EASYLUNCH_ADMIN_PASSWORD en Vercel.'), { code: 'config' })
  const r = await fetch(LOGIN, { method: 'POST', redirect: 'manual', headers: { 'Content-Type': 'application/x-www-form-urlencoded', Accept: 'application/json' }, body: new URLSearchParams({ user, pass }).toString() })
  if (r.status !== 200) throw Object.assign(new Error('El login de Easy Lunch respondió ' + r.status), { code: 'login' })
  const lista = typeof r.headers.getSetCookie === 'function' ? r.headers.getSetCookie() : [r.headers.get('set-cookie') || '']
  for (const c of lista) { const m = /(?:^|[,\s])EASYLUNCH_ADMIN=([A-Za-z0-9,-]{1,256}?)(?=;|$|,\s*[A-Za-z_]+=)/.exec(String(c || '')); if (m) cookieAdmin = 'EASYLUNCH_ADMIN=' + m[1] }
  if (!cookieAdmin) throw Object.assign(new Error('El login de Easy Lunch no entregó la sesión'), { code: 'login' })
  return cookieAdmin
}
async function traerPedidos() {
  const pedir = async () => fetch(ORIGEN, { redirect: 'manual', headers: { Accept: 'application/json', Cookie: await sesionAdmin() } })
  let r = await pedir()
  if (r.status === 401 || r.status === 403) { cookieAdmin = ''; r = await pedir() }
  if (!r.ok) throw Object.assign(new Error('El sistema de pedidos respondió ' + r.status), { code: 'origen' })
  const data = await r.json()
  if (!Array.isArray(data)) throw Object.assign(new Error('El sistema de pedidos no devolvió una lista'), { code: 'origen' })
  return data
}

/** Pedidos de la empresa para la fecha, agrupados por persona (se exporta para los tests). */
export function pedidosDelDia(data, fecha) {
  const porUsuario = new Map()
  for (const x of data) {
    if (String(x.id_empresa) !== EMPRESA_ID && String(x.nombre_empresa || '').trim().toLowerCase() !== EMPRESA) continue
    const mes = MESES[String(x.mes || '').trim().toLowerCase()] || parseInt(x.mes, 10)
    if (!mes || !x.anio || !x.dia) continue
    if (`${x.anio}-${pad(mes)}-${pad(x.dia)}` !== fecha) continue
    const id = String(x.id_usuario || '').trim()
    if (!id) continue
    const p = porUsuario.get(id) || { id_usuario: id, nombre: '', apellido: '', dni: '', items: [], pago_pendiente: false }
    p.nombre = String(x.nombre || p.nombre || '').trim()
    p.apellido = String(x.apellido || p.apellido || '').trim()
    const dni = String(x.dni || '').replace(/\D/g, '')
    if (dni) p.dni = dni.slice(-3)   // solo los últimos 3 dígitos, para confirmar identidad
    const agregar = (tipo, nombre, pagado) => {
      const n = String(nombre || '').trim()
      if (!n) return
      p.items.push({ tipo, nombre: n, pagado: si(pagado) })
      if (!si(pagado)) p.pago_pendiente = true
    }
    agregar('plato', x.plato, x.plato_pagado)
    agregar('postre', x.postre, x.postre_pagado)
    agregar('bebida', x.bebida, x.bebida_pagado)
    porUsuario.set(id, p)
  }
  return [...porUsuario.values()].filter(p => p.items.length)
    .sort((a, b) => (a.apellido + ' ' + a.nombre).localeCompare(b.apellido + ' ' + b.nombre, 'es'))
}

export default async function handler(req, res) {
  res.setHeader('Cache-Control', 'no-store')
  if (req.method !== 'POST') return res.status(405).json({ message: 'Usá POST' })
  let body = req.body
  if (typeof body === 'string') { try { body = JSON.parse(body) } catch (e) { body = {} } }
  const token = String((body && body.token) || '')
  const fecha = okFecha(body && body.fecha) ? body.fecha : hoyBA()
  if (!token) return res.status(401).json({ message: 'Volvé a ingresar al panel.' })
  try {
    const retirados = await rpc('caja_retiros_dia', { p_token: token, p_fecha: fecha })   // valida la sesión y el permiso
    const pedidos = pedidosDelDia(await traerPedidos(), fecha)
    return res.status(200).json({ fecha, pedidos, retirados })
  } catch (e) {
    return res.status(e.status === 400 ? 400 : 502).json({ message: String((e && e.message) || e) })
  }
}
