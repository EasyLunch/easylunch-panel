// Vercel Serverless Function · /api/caja-sync
// Local Prosegur: trae de la app de Easy Lunch (app.easylunch.com.ar) los productos que la empresa tiene habilitados
// y los pasa al catálogo de la caja (Supabase, tabla caja_productos, vía las funciones de db/caja_prosegur.sql).
//
// Qué lee de la app (todo por el nombre de la empresa, como lo guarda la app):
//   asignar_modulo  → módulo diario (ej. "Platos Calientes (400gr - 450gr)") + módulos fijos (Tartas, Milanesas…)
//   asignar_postre  → módulo diario de postres + módulos fijos de postres
//   asignar_bebidas → bebidas habilitadas
//   mes             → menú de cada día: qué platos tiene hoy cada módulo diario
//   modulos_fijos   → qué platos tiene cada módulo fijo
//   platos, bebidas → id y PRECIO DEL PRODUCTO (para Prosegur vale el precio del producto, no el del módulo)
//
// Cómo se llama:
//   POST { token, fecha? }          → botón "Sincronizar productos" (token = sesión del panel; cualquier usuario de la caja)
//   POST { token, fecha?, preview } → solo muestra qué traería, sin guardar nada
//   GET (cron diario de vercel.json) → sincronización automática a primera hora
//
// Variables de entorno de Vercel que usa (ya existen para Recorridos y Gourmet):
//   SUPABASE_URL, SUPABASE_ANON_KEY (opcional), SUPABASE_SERVICE_ROLE_KEY (solo para el cron),
//   EASYLUNCH_ADMIN_USER y EASYLUNCH_ADMIN_PASSWORD (inicia sesión de admin en la app antes de leer).
//   Opcionales: CAJA_EMPRESA (por defecto "PROSEGUR"), CRON_SECRET (si está, el cron tiene que mandarlo).

const APP = 'https://app.easylunch.com.ar'
const LOGIN = process.env.EASYLUNCH_LOGIN_URL || APP + '/server/login/login-admin.php'
export const EMPRESA = process.env.CAJA_EMPRESA || 'PROSEGUR'
const SB = String(process.env.SUPABASE_URL || 'https://xlwcozznliafhouhqjzl.supabase.co').replace(/\/+$/, '').replace(/\/rest\/v1$/, '') + '/rest/v1'
const ANON = process.env.SUPABASE_ANON_KEY ||
  'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6Inhsd2NvenpubGlhZmhvdWhxanpsIiwicm9sZSI6ImFub24iLCJpYXQiOjE3ODA5NTkwMzAsImV4cCI6MjA5NjUzNTAzMH0.i-GTNnGK_5GMUum_tmUKIiX4NUkmEiJovK_M7BwGFfg'
const MESES = ['enero', 'febrero', 'marzo', 'abril', 'mayo', 'junio', 'julio', 'agosto', 'septiembre', 'octubre', 'noviembre', 'diciembre']

// ───────────── utilidades de texto (se exportan para los tests) ─────────────
/** Normaliza un nombre para comparar: minúsculas, sin espacios dobles, sin punto final. */
export function norm(s) {
  return String(s == null ? '' : s).normalize('NFC').toLowerCase().replace(/\s+/g, ' ').trim().replace(/[.\s]+$/, '')
}
/** "[A], [B], [C]" → ["A", "B", "C"] */
export function lista(s) {
  const out = []
  const re = /\[([^\[\]]*)\]/g
  let m
  while ((m = re.exec(String(s || '')))) { const v = m[1].replace(/\s+/g, ' ').trim(); if (v) out.push(v) }
  return out
}
/**
 * Menú del día de la tabla "mes" → { 'módulo a': ['p1','p2'], … }
 * En la base viene como JSON: {"Módulo A":["[p1]","[p2]"],"Módulo B":null}
 * (el admin lo muestra como "Módulo A :[ [p1] , [p2] ]"; también se acepta ese formato).
 */
export function menuDelDia(s) {
  const out = {}
  let json = null
  if (s && typeof s === 'object') json = s
  else { try { json = JSON.parse(String(s || '')) } catch (e) { json = null } }
  if (json && typeof json === 'object' && !Array.isArray(json)) {
    for (const [mod, val] of Object.entries(json)) {
      const k = norm(mod)
      if (!k || !Array.isArray(val)) continue
      const platos = []
      for (const v of val) { const l = lista(v); if (l.length) platos.push(...l); else if (String(v || '').trim()) platos.push(String(v).replace(/\s+/g, ' ').trim()) }
      if (platos.length) out[k] = (out[k] || []).concat(platos)
    }
    return out
  }
  const re = /([^\[\]:]+?)\s*:\s*\[((?:\s*\[[^\[\]]*\]\s*,?)*)\s*\]/g
  let m
  while ((m = re.exec(String(s || '')))) {
    const modulo = norm(m[1].replace(/^[\s,]+/, ''))
    if (modulo) out[modulo] = (out[modulo] || []).concat(lista(m[2]))
  }
  return out
}
/** Fecha AAAA-MM-DD de hoy en Buenos Aires. */
export function hoyBA() {
  return new Intl.DateTimeFormat('en-CA', { timeZone: 'America/Buenos_Aires', year: 'numeric', month: '2-digit', day: '2-digit' }).format(new Date())
}
const num = v => { const n = Number(v); return Number.isFinite(n) && n > 0 ? n : null }
/** Foto de la app: URL completa (si viene relativa se completa con el dominio de la app). */
export function foto(v) {
  const s = String(v || '').trim()
  if (!s) return null
  if (/^https:\/\//i.test(s)) return s
  if (/^http:\/\//i.test(s)) return s.replace(/^http:/i, 'https:')
  if (/^[\w./-]+\.(webp|jpe?g|png|gif)$/i.test(s)) return 'https://app.easylunch.com.ar/' + s.replace(/^\/+/, '')
  return null
}
const si = v => v === 1 || v === '1' || v === true || String(v).toLowerCase() === 'si'

/**
 * Arma la lista de productos de la empresa para una fecha, a partir de las tablas de la app.
 * t = { asignar_modulo, asignar_postre, asignar_bebidas, mes, modulos_fijos, platos, bebidas } (arrays)
 * Devuelve { items, avisos, menuEncontrado }.
 */
export function armarItems(t, empresa, fecha) {
  const avisos = []
  const deEmpresa = rows => (rows || []).find(r => norm(r.empresa) === norm(empresa) || String(r.id_empresa || '') === String(empresa))
  const am = deEmpresa(t.asignar_modulo)
  const ap = deEmpresa(t.asignar_postre)
  const ab = deEmpresa(t.asignar_bebidas)
  if (!am && !ap && !ab) throw Object.assign(new Error(`La empresa "${empresa}" no tiene módulos, postres ni bebidas asignados en la app.`), { code: 'empresa' })

  // índice de platos por nombre (si hay repetidos: primero los que se muestran, después el más nuevo)
  const platos = new Map()
  ;[...(t.platos || [])].sort((a, b) => (si(b.mostrar) - si(a.mostrar)) || (Number(b.id) - Number(a.id))).forEach(p => {
    const k = norm(p.nombre); if (k && !platos.has(k)) platos.set(k, p)
  })
  const bebidas = new Map()
  ;[...(t.bebidas || [])].sort((a, b) => Number(b.id) - Number(a.id)).forEach(b => { const k = norm(b.nombre); if (k && !bebidas.has(k)) bebidas.set(k, b) })
  const fijos = new Map((t.modulos_fijos || []).map(m => [norm(m.nombre), m]))

  // menú del día
  const [anio, mes, dia] = fecha.split('-').map(Number)
  const filaMes = (t.mes || []).filter(r => Number(r.anio) === anio && norm(r.mes) === MESES[mes - 1] && Number(r.dia) === dia)
    .sort((a, b) => (si(b.mostrar) - si(a.mostrar)) || (Number(b.id) - Number(a.id)))[0]
  const menu = filaMes ? menuDelDia(filaMes.menu) : {}

  const items = []
  let orden = 0
  const agregarPlato = (nombre, { categoria, grupo, tipo, del_dia }) => {
    const p = platos.get(norm(nombre))
    if (!p) avisos.push(`No encontré "${nombre}" en Platos: entra sin precio.`)
    else if (!num(p.precio)) avisos.push(`"${nombre}" tiene precio 0 en la app: entra sin precio.`)
    items.push({
      ref: p ? 'plato:' + p.id : 'nombre:' + norm(nombre),
      nombre: p ? String(p.nombre).replace(/\s+/g, ' ').trim() : nombre,
      categoria, grupo, tipo, precio: p ? num(p.precio) : null, del_dia: !!del_dia, orden: orden++, img: p ? foto(p.img) : null
    })
  }
  const nombreCategoria = n => String(n).replace(new RegExp('^\\s*' + empresa.replace(/[.*+?^${}()|[\]\\]/g, '\\$&') + '\\s*-\\s*', 'i'), '').trim() || n

  // 1) módulos fijos (siempre disponibles) — van primero: si un plato está en un fijo y en el del día, queda como fijo
  const fijosDe = (fila, tipo) => {
    if (!fila || !si(fila.usar_modulo_fijo)) return
    for (const nombreMod of lista(fila.id_modulo_fijo)) {
      const mod = fijos.get(norm(nombreMod))
      if (!mod) { avisos.push(`No encontré el módulo fijo "${nombreMod}".`); continue }
      const cat = tipo === 'postre' ? 'Postres' : nombreCategoria(mod.nombre)
      for (const pl of lista(mod.platos)) agregarPlato(pl, { categoria: cat, grupo: mod.nombre, tipo, del_dia: false })
    }
  }
  fijosDe(am, 'vianda')
  fijosDe(ap, 'postre')

  // 2) módulos diarios: los platos de hoy según el menú del mes
  const diariosDe = (fila, campoBool, campoLista, tipo) => {
    if (!fila || !si(fila[campoBool]) || si(fila.usar_solo_modulo_fijo)) return
    for (const nombreMod of lista(fila[campoLista])) {
      const delDia = menu[norm(nombreMod)]
      if (!delDia) {
        if (tipo === 'vianda') avisos.push(filaMes ? `El menú del ${fecha} no tiene platos para "${nombreMod}".` : `No hay menú cargado para el ${fecha}.`)
        continue
      }
      for (const pl of delDia) agregarPlato(pl, { categoria: tipo === 'postre' ? 'Postres' : 'Plato del día', grupo: nombreMod, tipo, del_dia: true })
    }
  }
  diariosDe(am, 'modulo_boolean', 'modulo_empresa', 'vianda')
  diariosDe(ap, 'postre_boolean', 'postre_empresa', 'postre')

  // 3) bebidas
  if (ab && si(ab.bebidas_boolean)) {
    for (const nb of lista(ab.bebida_empresa)) {
      const b = bebidas.get(norm(nb))
      const p = b ? null : platos.get(norm(nb))
      const precio = b ? num(b.precio) : p ? num(p.precio) : null
      if (!precio) avisos.push(`La bebida "${nb}" no tiene precio en la app: entra sin precio (podés ponerle precio local).`)
      items.push({ ref: b ? 'bebida:' + b.id : p ? 'plato:' + p.id : 'bebida:' + norm(nb), nombre: nb, categoria: 'Bebidas', grupo: 'Bebidas', tipo: 'bebida', precio, del_dia: false, orden: orden++, img: foto(b ? b.img : p ? p.img : null) })
    }
  }
  // sin repetidos (gana el primero)
  const vistos = new Set()
  return { items: items.filter(i => !vistos.has(i.ref) && vistos.add(i.ref)), avisos: [...new Set(avisos)], menuEncontrado: !!filaMes }
}

// ───────────── acceso a la app de Easy Lunch ─────────────
let cookieAdmin = ''
async function sesionAdmin() {
  if (cookieAdmin) return cookieAdmin
  const user = String(process.env.EASYLUNCH_ADMIN_USER || '').trim()
  const pass = process.env.EASYLUNCH_ADMIN_PASSWORD || ''
  if (!user || !pass) return ''
  try {
    const r = await fetch(LOGIN, {
      method: 'POST', redirect: 'manual',
      headers: { 'Content-Type': 'application/x-www-form-urlencoded', Accept: 'application/json' },
      body: new URLSearchParams({ user, pass }).toString()
    })
    if (r.status !== 200) return ''
    const lista = typeof r.headers.getSetCookie === 'function' ? r.headers.getSetCookie() : [r.headers.get('set-cookie') || '']
    for (const c of lista) { const m = /(?:^|[,\s])EASYLUNCH_ADMIN=([A-Za-z0-9,-]{1,256}?)(?=;|$|,\s*[A-Za-z_]+=)/.exec(String(c || '')); if (m) cookieAdmin = 'EASYLUNCH_ADMIN=' + m[1] }
  } catch (e) { /* si el login falla se intenta leer igual */ }
  return cookieAdmin
}
async function tabla(nombre) {
  const url = `${APP}/server/traer-tabla-por-id.php?tabla=${encodeURIComponent(nombre)}&id=0&order=DESC&by=id`
  const pedir = async () => { const c = await sesionAdmin(); return fetch(url, { headers: c ? { Accept: 'application/json', Cookie: c } : { Accept: 'application/json' } }) }
  let r = await pedir()
  if (r.status === 401 || r.status === 403) { cookieAdmin = ''; r = await pedir() }
  if (!r.ok) throw Object.assign(new Error(`La app respondió ${r.status} al leer "${nombre}"`), { code: 'origen' })
  const txt = await r.text()
  let data; try { data = JSON.parse(txt) } catch (e) { throw Object.assign(new Error(`La app no devolvió datos válidos para "${nombre}"`), { code: 'origen' }) }
  if (!Array.isArray(data)) throw Object.assign(new Error(`La app no devolvió una lista para "${nombre}"`), { code: 'origen' })
  return data
}
export async function leerApp() {
  const nombres = ['asignar_modulo', 'asignar_postre', 'asignar_bebidas', 'mes', 'modulos_fijos', 'platos', 'bebidas']
  const datos = await Promise.all(nombres.map(tabla))
  return Object.fromEntries(nombres.map((n, i) => [n, datos[i]]))
}

// ───────────── Supabase ─────────────
async function rpc(fn, args, key) {
  const H = key.startsWith('sb_') ? { apikey: key } : { apikey: key, Authorization: 'Bearer ' + key }
  const r = await fetch(`${SB}/rpc/${fn}`, { method: 'POST', headers: { ...H, 'Content-Type': 'application/json' }, body: JSON.stringify(args) })
  const txt = await r.text()
  let d = null; try { d = txt ? JSON.parse(txt) : null } catch (e) { /* */ }
  if (!r.ok) throw Object.assign(new Error((d && (d.message || d.hint)) || ('Supabase ' + r.status)), { code: 'supabase', status: r.status })
  return d
}

const okFecha = s => /^\d{4}-\d{2}-\d{2}$/.test(String(s || ''))

export default async function handler(req, res) {
  res.setHeader('Cache-Control', 'no-store')
  try {
    if (req.method === 'POST') {
      let body = req.body
      if (typeof body === 'string') { try { body = JSON.parse(body) } catch (e) { body = {} } }
      body = body || {}
      const token = String(body.token || '')
      if (!token) return res.status(401).json({ error: 'sesion', message: 'Volvé a ingresar al panel.' })
      const fecha = okFecha(body.fecha) ? body.fecha : hoyBA()
      // valida la sesión antes de leer la app
      const yo = await rpc('panel_sesion', { p_token: token }, ANON)
      if (!yo) return res.status(401).json({ error: 'sesion', message: 'Sesión vencida. Volvé a ingresar al panel.' })
      const { items, avisos, menuEncontrado } = armarItems(await leerApp(), EMPRESA, fecha)
      if (body.preview) return res.status(200).json({ ok: true, preview: true, fecha, menuEncontrado, items, avisos })
      const resumen = await rpc('caja_sync_aplicar', { p_token: token, p_items: items, p_fecha: fecha }, ANON)
      return res.status(200).json({ ok: true, fecha, menuEncontrado, resumen, avisos })
    }

    if (req.method === 'GET') {
      // solo el cron de Vercel
      const secreto = process.env.CRON_SECRET
      const esCron = secreto ? req.headers.authorization === `Bearer ${secreto}` : /vercel-cron/i.test(String(req.headers['user-agent'] || ''))
      if (!esCron) return res.status(405).json({ error: 'metodo', message: 'Usá el botón "Sincronizar productos" del panel.' })
      const SERVICE = process.env.SUPABASE_SERVICE_ROLE_KEY
      if (!SERVICE) return res.status(500).json({ error: 'config', message: 'Falta SUPABASE_SERVICE_ROLE_KEY en Vercel' })
      const fecha = hoyBA()
      const { items, avisos } = armarItems(await leerApp(), EMPRESA, fecha)
      const resumen = await rpc('caja_sync_sistema', { p_items: items, p_fecha: fecha }, SERVICE)
      return res.status(200).json({ ok: true, fecha, resumen, avisos })
    }
    return res.status(405).json({ error: 'metodo' })
  } catch (e) {
    const status = e.code === 'supabase' ? (e.status === 400 ? 400 : 502) : e.code === 'empresa' ? 400 : 502
    return res.status(status).json({ error: e.code || 'error', message: String((e && e.message) || e) })
  }
}
