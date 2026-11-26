// Pedidos a proveedores · lo atiende /api/caja-sync (el plan de Vercel permite 12 funciones, por eso no es una aparte)
// Local Prosegur: pedidos de reposición a proveedores (Easy Lunch, Anabella, …).
//
// POST { token, accion: 'platos', fecha }            → platos calientes del menú de esa fecha (de la app) + cantidad sugerida
// POST { token, accion: 'enviar', proveedor_id, parte, fecha_entrega, items, nota } → guarda el pedido y lo manda por mail
// POST { token, accion: 'reenviar', id }             → vuelve a mandar el mail de un pedido
// POST { token, accion: 'editar', id, items, nota }  → cambia un pedido no recibido y avisa al proveedor (MODIFICADO)
// POST { token, accion: 'cancelar', id }             → lo cancela y avisa al proveedor (CANCELADO)
// POST { token, accion: 'auto' }                     → si pasó la hora de corte de platos y no se pidió, lo manda solo
// GET ?pedidos=1 (cron diario de vercel.json, 13 h)            → lo mismo que 'auto', por si la tablet estaba apagada
//
// Las tablas y permisos están en db/caja_prosegur_pedidos.sql. Los mails salen igual que el informe de cierre
// (Apps Script de info@easylunch.com.ar: MAIL_APPS_SCRIPT_URL + MAIL_SECRET).

import { enviarMail } from '../api/caja-cierre.js'
import { leerApp, armarItems, EMPRESA } from '../api/caja-sync.js'

const SB = String(process.env.SUPABASE_URL || 'https://xlwcozznliafhouhqjzl.supabase.co').replace(/\/+$/, '').replace(/\/rest\/v1$/, '') + '/rest/v1'
const ANON = process.env.SUPABASE_ANON_KEY ||
  'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6Inhsd2NvenpubGlhZmhvdWhxanpsIiwicm9sZSI6ImFub24iLCJpYXQiOjE3ODA5NTkwMzAsImV4cCI6MjA5NjUzNTAzMH0.i-GTNnGK_5GMUum_tmUKIiX4NUkmEiJovK_M7BwGFfg'
const DIAS = ['domingo', 'lunes', 'martes', 'miércoles', 'jueves', 'viernes', 'sábado']

async function rpc(fn, args, key = ANON) {
  const r = await fetch(`${SB}/rpc/${fn}`, { method: 'POST', headers: { apikey: key, Authorization: 'Bearer ' + key, 'Content-Type': 'application/json' }, body: JSON.stringify(args || {}) })
  const txt = await r.text()
  let d = null; try { d = txt ? JSON.parse(txt) : null } catch (e) { /* */ }
  if (!r.ok) throw Object.assign(new Error((d && (d.message || d.hint)) || ('Supabase ' + r.status)), { status: r.status, code: 'supabase' })
  return d
}

const okFecha = f => typeof f === 'string' && /^\d{4}-\d{2}-\d{2}$/.test(f)
const esc = s => String(s == null ? '' : s).replace(/[&<>"']/g, c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]))
const cant = n => { const v = Math.round(Number(n || 0) * 1000) / 1000; return v.toLocaleString('es-AR') }
export function fechaLarga(f) {
  const [y, m, d] = String(f).split('-').map(Number)
  const dt = new Date(Date.UTC(y, m - 1, d, 12))
  return DIAS[dt.getUTCDay()] + ' ' + String(d).padStart(2, '0') + '/' + String(m).padStart(2, '0')
}
export function horaBA() {
  return new Intl.DateTimeFormat('en-GB', { timeZone: 'America/Argentina/Buenos_Aires', hour: '2-digit', minute: '2-digit', hour12: false }).format(new Date())
}

/** Platos calientes del menú de una fecha (lo que la app tiene habilitado para Prosegur ese día). */
export function platosDe(items) {
  return (items || []).filter(i => i.del_dia && i.tipo === 'vianda').map(i => ({ ref_app: i.ref, nombre: i.nombre, grupo: i.grupo || '', img: i.img || null }))
}

export function asuntoPedido(p) {
  return (p.aviso === 'cancelado' ? 'CANCELADO · ' : p.aviso === 'modificado' ? 'MODIFICADO · ' : '') + 'Pedido Local Prosegur · ' + p.proveedor + (p.parte === 'platos' ? ' (platos calientes)' : '') + ' · entrega ' + fechaLarga(p.fecha_entrega)
}
export function mailPedido(p) {
  const total = p.items.reduce((a, i) => a + Number(i.cantidad), 0)
  const filas = p.items.map(i => `<tr><td style="padding:8px 10px;border-bottom:1px solid #eee">${esc(i.nombre)}</td>` +
    `<td style="padding:8px 10px;border-bottom:1px solid #eee;text-align:right;font-weight:700;font-size:16px">${cant(i.cantidad)}</td>` +
    `<td style="padding:8px 10px;border-bottom:1px solid #eee;color:#666">${esc(i.unidad && i.unidad !== 'u' ? i.unidad : 'unidades')}</td></tr>`).join('')
  const html = `<div style="font-family:Arial,Helvetica,sans-serif;max-width:640px;margin:0 auto;color:#111">
  <div style="background:#0f172a;color:#fff;padding:18px 22px;border-radius:12px 12px 0 0">
    <div style="font-size:13px;opacity:.8">Easy Lunch · Local Prosegur</div>
    <div style="font-size:22px;font-weight:700;margin-top:4px">${p.aviso === 'cancelado' ? 'CANCELADO: ' : p.aviso === 'modificado' ? 'MODIFICADO: ' : ''}Pedido${p.parte === 'platos' ? ' de platos calientes' : ''} para el ${esc(fechaLarga(p.fecha_entrega))}</div>
  </div>
  ${p.aviso === 'cancelado' ? '<div style="background:#fee2e2;color:#991b1b;padding:12px 22px;font-weight:700">Este pedido se canceló: no hay que mandarlo.</div>' :
    p.aviso === 'modificado' ? '<div style="background:#fef3c7;color:#92400e;padding:12px 22px;font-weight:700">Este pedido se modificó: vale esta versión, reemplaza a la anterior.</div>' : ''}
  <div style="border:1px solid #e5e7eb;border-top:0;padding:18px 22px;border-radius:0 0 12px 12px">
    <p style="margin:0 0 12px">Hola ${esc(p.proveedor)}, este es el pedido del local de Prosegur (Gral. Julio A. Roca 4530, Florida, Vicente López).</p>
    <table style="width:100%;border-collapse:collapse;font-size:14px">
      <thead><tr style="background:#f8fafc"><th style="text-align:left;padding:8px 10px">Producto</th><th style="text-align:right;padding:8px 10px">Cantidad</th><th style="text-align:left;padding:8px 10px">Presentación</th></tr></thead>
      <tbody>${filas}</tbody>
    </table>
    <p style="margin:14px 0 0;font-size:13px;color:#555">${p.items.length} producto${p.items.length === 1 ? '' : 's'} · ${cant(total)} en total</p>
    ${p.nota ? `<p style="margin:12px 0 0;padding:10px 12px;background:#fef9c3;border-radius:8px"><b>Nota:</b> ${esc(p.nota)}</p>` : ''}
    <p style="margin:16px 0 0;font-size:12px;color:#888">Pedido #${p.id} · ${p.origen === 'automatico' ? 'enviado automáticamente (nadie lo confirmó antes de la hora de corte)' : 'pedido por ' + esc(p.usuario)}</p>
  </div></div>`
  const text = asuntoPedido(p) + '\n\n' + p.items.map(i => `- ${i.nombre}: ${cant(i.cantidad)} ${i.unidad && i.unidad !== 'u' ? i.unidad : 'u.'}`).join('\n') +
    (p.nota ? '\n\nNota: ' + p.nota : '') + `\n\nPedido #${p.id}`
  return { html, text }
}

async function mandar(p, aviso) {
  if (aviso) p = Object.assign({}, p, { aviso })
  // Easy Lunch: el pedido entra solo en la planilla de modificaciones de Biel (LocalProsegur.gs); el mail es opcional
  if (!p.mails || !p.mails.length) return p.proveedor_tipo === 'easylunch'
    ? { estado: 'planilla', detalle: 'Entra en la planilla de modificaciones de Biel' }
    : { estado: 'sin_mail', detalle: 'El proveedor no tiene mail cargado.' }
  const { html, text } = mailPedido(p)
  const error = await enviarMail({ to: p.mails, subject: asuntoPedido(p), html, text })
  return error ? { estado: 'error', detalle: error } : { estado: 'enviado', detalle: p.mails.join(', ') }
}

/** Envío automático de platos calientes (cron o tablet). Usa la clave service_role. */
async function auto() {
  const SERVICE = process.env.SUPABASE_SERVICE_ROLE_KEY
  if (!SERVICE) return { hecho: false, motivo: 'Falta SUPABASE_SERVICE_ROLE_KEY en Vercel' }
  const info = await rpc('caja_pedidos_auto_info', {}, SERVICE)
  if (!info || !info.hacer) return { hecho: false, motivo: (info && info.motivo) || 'Nada para hacer' }
  const { items: todos } = armarItems(await leerApp(), EMPRESA, info.fecha_entrega)
  const platos = platosDe(todos)
  if (!platos.length) return { hecho: false, motivo: 'La app no tiene platos calientes cargados para el ' + info.fecha_entrega }
  const por = Number(info.estimado && info.estimado.por_plato) || 15
  const pedido = await rpc('caja_pedido_sistema', {
    p_proveedor: info.proveedor_id, p_parte: 'platos', p_fecha_entrega: info.fecha_entrega,
    p_items: platos.map(x => ({ ref_app: x.ref_app, nombre: x.nombre, grupo: x.grupo, cantidad: por })),
    p_nota: 'Envío automático: el local no confirmó la cantidad antes de la hora de corte. Se mandó la cantidad estimada.'
  }, SERVICE)
  const m = await mandar(pedido)
  await rpc('caja_pedido_mail_sistema', { p_id: pedido.id, p_estado: m.estado, p_detalle: m.detalle }, SERVICE)
  return { hecho: true, pedido: Object.assign(pedido, { mail_estado: m.estado, mail_detalle: m.detalle }) }
}

export const ACCIONES_PEDIDOS = ['platos', 'enviar', 'reenviar', 'auto', 'editar', 'cancelar']
export async function pedidosHandler(req, res) {
  res.setHeader('Cache-Control', 'no-store')
  try {
    if (req.method === 'GET') {
      const secreto = process.env.CRON_SECRET
      const esCron = secreto ? req.headers.authorization === `Bearer ${secreto}` : /vercel-cron/i.test(String(req.headers['user-agent'] || ''))
      if (!esCron) return res.status(405).json({ error: 'metodo' })
      return res.status(200).json(Object.assign({ ok: true }, await auto()))
    }
    if (req.method !== 'POST') return res.status(405).json({ error: 'metodo' })
    let body = req.body
    if (typeof body === 'string') { try { body = JSON.parse(body) } catch (e) { body = {} } }
    body = body || {}
    const token = String(body.token || '')
    if (!token) return res.status(401).json({ error: 'sesion', message: 'Volvé a ingresar al panel.' })
    const yo = await rpc('panel_sesion', { p_token: token })
    if (!yo) return res.status(401).json({ error: 'sesion', message: 'Sesión vencida. Volvé a ingresar.' })

    if (body.accion === 'platos') {
      if (!okFecha(body.fecha)) return res.status(400).json({ message: 'Fecha inválida.' })
      const { items, menuEncontrado } = armarItems(await leerApp(), EMPRESA, body.fecha)
      return res.status(200).json({ ok: true, fecha: body.fecha, menuEncontrado, platos: platosDe(items) })
    }

    if (body.accion === 'enviar') {
      const pedido = await rpc('caja_pedido_crear', {
        p_token: token, p_proveedor: body.proveedor_id, p_parte: body.parte || 'general',
        p_fecha_entrega: body.fecha_entrega, p_items: body.items || [], p_nota: String(body.nota || '')
      })
      let m
      try { m = await mandar(pedido) } catch (e) { m = { estado: 'error', detalle: String(e.message || e) } }
      await rpc('caja_pedido_mail_registrar', { p_token: token, p_id: pedido.id, p_estado: m.estado, p_detalle: m.detalle })
      return res.status(200).json({ ok: true, pedido: Object.assign(pedido, { mail_estado: m.estado, mail_detalle: m.detalle }) })
    }

    if (body.accion === 'editar' || body.accion === 'cancelar') {
      const pedido = body.accion === 'editar'
        ? await rpc('caja_pedido_editar', { p_token: token, p_id: body.id, p_items: body.items || [], p_nota: String(body.nota || '') })
        : await rpc('caja_pedido_cancelar', { p_token: token, p_id: body.id })
      let m
      try { m = await mandar(pedido, body.accion === 'editar' ? 'modificado' : 'cancelado') } catch (e) { m = { estado: 'error', detalle: String(e.message || e) } }
      await rpc('caja_pedido_mail_registrar', { p_token: token, p_id: pedido.id, p_estado: m.estado, p_detalle: m.detalle })
      return res.status(200).json({ ok: true, pedido: Object.assign(pedido, { mail_estado: m.estado, mail_detalle: m.detalle }) })
    }

    if (body.accion === 'reenviar') {
      const d = await rpc('caja_pedidos_datos', { p_token: token })
      const pedido = (d.pedidos || []).find(p => String(p.id) === String(body.id))
      if (!pedido) return res.status(404).json({ message: 'No encontré ese pedido.' })
      const m = await mandar(pedido)
      await rpc('caja_pedido_mail_registrar', { p_token: token, p_id: pedido.id, p_estado: m.estado, p_detalle: m.detalle })
      return res.status(200).json({ ok: m.estado === 'enviado', estado: m.estado, detalle: m.detalle })
    }

    if (body.accion === 'auto') {
      const d = await rpc('caja_pedidos_datos', { p_token: token })
      const hora = (d.config && d.config.hora_platos) || '13:00'
      if (horaBA() < hora) return res.status(200).json({ ok: true, hecho: false, motivo: 'Todavía no es la hora de corte' })
      return res.status(200).json(Object.assign({ ok: true }, await auto()))
    }

    return res.status(400).json({ message: 'Acción desconocida.' })
  } catch (e) {
    const status = e.code === 'supabase' ? (e.status === 400 ? 400 : 502) : e.code === 'empresa' ? 400 : 502
    return res.status(status).json({ error: e.code || 'error', message: String((e && e.message) || e) })
  }
}
