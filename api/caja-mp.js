// Vercel Serverless Function · /api/caja-mp
// Local Prosegur: cobro con QR de Mercado Pago usando la API de Orders (QR dinámico).
//
// POST { accion, token, ... }
//   crear      { items:[{id,cant}], total, client_id } → { id, qr_data, total, expira }
//   estado     { id }                                   → { estado: esperando|pagada|cancelada|expirada, venta_id? }
//   cancelar   { id }                                   → { estado }
//   pendientes {}                                       → { confirmadas: [{id, venta_id, total}] }  (concilia QRs pagados sin confirmar)
//   config     {}                                       → { config }   (encargado/admin: ver si la caja de MP está creada)
//   setup      { datos:{nombre, calle, numero, ciudad, provincia, lat, lng, referencia} } → { config }  (admin: crea sucursal y caja en MP)
//
// Variables de entorno de Vercel: MP_ACCESS_TOKEN (credencial de producción de la cuenta de Mercado Pago del local),
// SUPABASE_SERVICE_ROLE_KEY (para registrar la venta cuando Mercado Pago confirma el pago), SUPABASE_URL (opcional).

const MP = 'https://api.mercadopago.com'
const SB = String(process.env.SUPABASE_URL || 'https://xlwcozznliafhouhqjzl.supabase.co').replace(/\/+$/, '').replace(/\/rest\/v1$/, '') + '/rest/v1'
const ANON = process.env.SUPABASE_ANON_KEY ||
  'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6Inhsd2NvenpubGlhZmhvdWhxanpsIiwicm9sZSI6ImFub24iLCJpYXQiOjE3ODA5NTkwMzAsImV4cCI6MjA5NjUzNTAzMH0.i-GTNnGK_5GMUum_tmUKIiX4NUkmEiJovK_M7BwGFfg'
const STORE_EXT = 'ELPROSEGUR'
const POS_EXT = 'ELPROSEGURCAJA1'
const EXPIRA_MIN = 10

const err = (message, status = 400, code = 'error') => Object.assign(new Error(message), { status, code })

async function rpc(fn, args, key) {
  const k = key || ANON
  const H = k.startsWith('sb_') ? { apikey: k } : { apikey: k, Authorization: 'Bearer ' + k }
  const r = await fetch(`${SB}/rpc/${fn}`, { method: 'POST', headers: { ...H, 'Content-Type': 'application/json' }, body: JSON.stringify(args || {}) })
  const txt = await r.text()
  let d = null; try { d = txt ? JSON.parse(txt) : null } catch (e) { /* */ }
  if (!r.ok) throw err((d && (d.message || d.hint)) || ('Supabase ' + r.status), r.status === 400 ? 400 : 502, 'supabase')
  return d
}
function service() {
  const k = process.env.SUPABASE_SERVICE_ROLE_KEY
  if (!k) throw err('Falta SUPABASE_SERVICE_ROLE_KEY en Vercel.', 500, 'config')
  return k
}
async function mp(method, path, body, idem) {
  const token = process.env.MP_ACCESS_TOKEN
  if (!token) throw err('Falta MP_ACCESS_TOKEN en Vercel (credencial de producción de Mercado Pago).', 500, 'config')
  const headers = { Authorization: 'Bearer ' + token, 'Content-Type': 'application/json' }
  if (idem) headers['X-Idempotency-Key'] = idem
  const r = await fetch(MP + path, { method, headers, body: body ? JSON.stringify(body) : undefined })
  const txt = await r.text()
  let d = null; try { d = txt ? JSON.parse(txt) : null } catch (e) { /* */ }
  if (!r.ok) {
    const det = d && (d.message || (d.errors && d.errors.map(e => e.message || e.code).join('; ')) || d.error)
    throw Object.assign(err('Mercado Pago: ' + (det || ('error ' + r.status)), r.status >= 500 ? 502 : 400, 'mp'), { mpStatus: r.status, mpBody: d })
  }
  return d
}

/** Traduce el estado de una order de Mercado Pago (se exporta para los tests). */
export function estadoOrden(o) {
  const st = String((o && o.status) || '').toLowerCase()
  const pay = (o && o.transactions && o.transactions.payments && o.transactions.payments[0]) || {}
  if (st === 'processed' || (String(pay.status).toLowerCase() === 'processed' && String(pay.status_detail).toLowerCase() === 'accredited')) return 'pagada'
  if (st === 'canceled' || st === 'cancelled') return 'cancelada'
  if (st === 'expired') return 'expirada'
  if (st === 'refunded') return 'pagada'   // se cobró y después se devolvió desde Mercado Pago: la venta existe
  return 'esperando'
}
const montoOrden = o => Number((o && (o.total_paid_amount || o.total_amount)) || 0)

async function confirmarSiPagada(orden, mpOrder) {
  const est = estadoOrden(mpOrder)
  if (est === 'pagada') {
    const r = await rpc('caja_mp_confirmar', { p_id: orden.id, p_mp_order_id: mpOrder.id, p_monto: montoOrden(mpOrder) }, service())
    return { estado: 'pagada', venta_id: r.venta_id, total: r.total }
  }
  if (est === 'cancelada' || est === 'expirada') {
    await rpc('caja_mp_marcar', { p_id: orden.id, p_estado: est, p_detalle: String(mpOrder.status_detail || '') }, service())
    return { estado: est }
  }
  return { estado: 'esperando', detalle: String(mpOrder.status_detail || mpOrder.status || '') }
}

async function crear(body) {
  const token = body.token
  const prep = await rpc('caja_mp_preparar', { p_token: token, p_items: body.items, p_total_esperado: body.total, p_client_id: String(body.client_id || '') })
  if (prep.estado === 'pagada') return { id: prep.id, estado: 'pagada', venta_id: prep.venta_id, total: prep.total }
  if (prep.estado === 'creada' && prep.qr_data) return { id: prep.id, qr_data: prep.qr_data, total: prep.total, expira: EXPIRA_MIN }
  const cfg = await rpc('caja_mp_config', {}, service())
  if (!cfg || !cfg.pos_external_id) throw err('Falta crear la caja de Mercado Pago. Entrá al panel → Local Prosegur · Productos y precios → Cierres de caja → Mercado Pago.', 400, 'sin_caja')
  const total = Number(prep.total).toFixed(2)
  const resumen = (prep.lineas || []).map(l => `${l.cant}x ${l.nombre}`).join(', ')
  let o
  try {
    o = await mp('POST', '/v1/orders', {
      type: 'qr',
      total_amount: total,
      external_reference: prep.ref,
      description: ('Easy Lunch · ' + resumen).slice(0, 150),
      expiration_time: `PT${EXPIRA_MIN}M`,
      config: { qr: { external_pos_id: cfg.pos_external_id, mode: 'dynamic' } },
      transactions: { payments: [{ amount: total }] }
    }, 'elp-' + prep.id)
  } catch (e) {
    await rpc('caja_mp_marcar', { p_id: prep.id, p_estado: 'error', p_detalle: e.message }, service()).catch(() => {})
    throw e
  }
  const qr = (o.type_response && o.type_response.qr_data) || o.qr_data
  if (!o.id || !qr) throw err('Mercado Pago no devolvió el código QR.', 502, 'mp')
  await rpc('caja_mp_vincular', { p_id: prep.id, p_mp_order_id: o.id, p_qr_data: qr }, service())
  return { id: prep.id, qr_data: qr, total: prep.total, expira: EXPIRA_MIN }
}

async function estado(body) {
  const orden = await rpc('caja_mp_orden', { p_token: body.token, p_id: Number(body.id) })
  if (orden.estado === 'pagada') return { estado: 'pagada', venta_id: orden.venta_id, total: orden.total }
  if (orden.estado !== 'creada' || !orden.mp_order_id) return { estado: orden.estado === 'pendiente' ? 'esperando' : orden.estado }
  const o = await mp('GET', '/v1/orders/' + encodeURIComponent(orden.mp_order_id))
  return confirmarSiPagada(orden, o)
}

async function cancelar(body) {
  const orden = await rpc('caja_mp_orden', { p_token: body.token, p_id: Number(body.id) })
  if (orden.estado === 'pagada') return { estado: 'pagada', venta_id: orden.venta_id, total: orden.total }
  if (orden.estado !== 'creada' || !orden.mp_order_id) {
    await rpc('caja_mp_marcar', { p_id: orden.id, p_estado: 'cancelada', p_detalle: 'cancelada en la caja' }, service())
    return { estado: 'cancelada' }
  }
  try {
    await mp('POST', '/v1/orders/' + encodeURIComponent(orden.mp_order_id) + '/cancel', null, 'elp-cancel-' + orden.id)
  } catch (e) {
    // si no se pudo cancelar puede ser porque justo se pagó: se consulta el estado real
    const o = await mp('GET', '/v1/orders/' + encodeURIComponent(orden.mp_order_id))
    const r = await confirmarSiPagada(orden, o)
    if (r.estado === 'esperando') throw err('No se pudo cancelar el cobro en Mercado Pago: ' + e.message, 502, 'mp')
    return r
  }
  await rpc('caja_mp_marcar', { p_id: orden.id, p_estado: 'cancelada', p_detalle: 'cancelada en la caja' }, service())
  return { estado: 'cancelada' }
}

async function pendientes(body) {
  const lista = await rpc('caja_mp_pendientes', { p_token: body.token })
  const confirmadas = []
  for (const orden of (lista || []).slice(0, 15)) {
    try {
      const o = await mp('GET', '/v1/orders/' + encodeURIComponent(orden.mp_order_id))
      const r = await confirmarSiPagada(orden, o)
      if (r.estado === 'pagada') confirmadas.push({ id: orden.id, venta_id: r.venta_id, total: r.total })
    } catch (e) { /* se reintenta en la próxima pasada */ }
  }
  return { confirmadas }
}

async function config(body) {
  await rpc('caja_config_leer', { p_token: body.token })    // valida encargado/admin
  const cfg = await rpc('caja_mp_config', {}, service())
  return { config: cfg || null, token_cargado: !!process.env.MP_ACCESS_TOKEN }
}

async function setup(body) {
  await rpc('caja_mp_permiso_admin', { p_token: body.token })
  const d = body.datos || {}
  const req = ['nombre', 'calle', 'numero', 'ciudad', 'provincia']
  for (const k of req) if (!String(d[k] || '').trim()) throw err('Completá todos los datos de la dirección.')
  const lat = Number(d.lat), lng = Number(d.lng)
  if (!isFinite(lat) || !isFinite(lng) || Math.abs(lat) > 90 || Math.abs(lng) > 180 || (lat === 0 && lng === 0)) throw err('Revisá la latitud y longitud.')
  const me = await mp('GET', '/users/me')
  // ¿ya existe la caja?
  let pos = null
  try {
    const l = await mp('GET', '/pos?external_id=' + POS_EXT)
    pos = (l && l.results && l.results[0]) || null
  } catch (e) { /* si no existe, se crea */ }
  let storeId = pos ? pos.store_id : null
  if (!pos) {
    let store = null
    try {
      const ls = await mp('GET', `/users/${me.id}/stores/search?external_id=${STORE_EXT}`)
      store = (ls && ls.results && ls.results[0]) || null
    } catch (e) { /* */ }
    if (!store) {
      store = await mp('POST', `/users/${me.id}/stores`, {
        name: String(d.nombre).trim().slice(0, 60),
        external_id: STORE_EXT,
        location: {
          street_number: String(d.numero).trim(), street_name: String(d.calle).trim(),
          city_name: String(d.ciudad).trim(), state_name: String(d.provincia).trim(),
          latitude: lat, longitude: lng, reference: String(d.referencia || '').trim().slice(0, 100) || 'Local de Easy Lunch'
        }
      })
    }
    storeId = store.id
    pos = await mp('POST', '/v2/pos', { name: 'Caja 1', store_id: String(store.id), external_id: POS_EXT, config: { qr: { operating_mode: 'pdv' } } }, 'elp-pos-' + POS_EXT)
  }
  const cfg = { user_id: me.id, cuenta: me.nickname || '', store_id: storeId, store_external_id: STORE_EXT, pos_id: pos.id, pos_external_id: pos.external_id || POS_EXT, creado: new Date().toISOString() }
  await rpc('caja_mp_config_guardar', { p_valor: cfg }, service())
  return { config: cfg }
}

const ACCIONES = { crear, estado, cancelar, pendientes, config, setup }

export default async function handler(req, res) {
  res.setHeader('Cache-Control', 'no-store')
  if (req.method !== 'POST') return res.status(405).json({ message: 'Usá POST' })
  let body = req.body
  if (typeof body === 'string') { try { body = JSON.parse(body) } catch (e) { body = {} } }
  body = body || {}
  const fn = ACCIONES[body.accion]
  if (!fn) return res.status(400).json({ message: 'Acción inválida.' })
  if (!body.token) return res.status(401).json({ message: 'Volvé a ingresar al panel.' })
  try {
    return res.status(200).json(await fn(body))
  } catch (e) {
    return res.status(e.status || 502).json({ message: String((e && e.message) || e), code: e.code || 'error' })
  }
}
