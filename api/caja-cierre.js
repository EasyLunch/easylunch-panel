// Vercel Serverless Function · /api/caja-cierre
// Local Prosegur: manda por mail el informe de cierre de caja (ventas + arqueo) a las direcciones
// configuradas en el panel (Productos y precios → Cierres). Lo llama la caja al cerrar, y el panel para reenviar.
//
// POST { token, turno }  → { ok, estado, destinos }
//
// Envío de mails (una de las dos opciones, variables de entorno de Vercel):
//  A) Google Apps Script (recomendado, sale desde tu cuenta de Google): MAIL_APPS_SCRIPT_URL + MAIL_SECRET
//     El código del script está en db/mail-apps-script.gs.
//  B) Resend (resend.com): RESEND_API_KEY + MAIL_FROM (ej. "Easy Lunch <cierres@easylunch.com.ar>", dominio verificado)

import { informeHTML, informeTexto, asuntoInforme } from '../prosegur-informe.js'

const SB = String(process.env.SUPABASE_URL || 'https://xlwcozznliafhouhqjzl.supabase.co').replace(/\/+$/, '').replace(/\/rest\/v1$/, '') + '/rest/v1'
const ANON = process.env.SUPABASE_ANON_KEY ||
  'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6Inhsd2NvenpubGlhZmhvdWhxanpsIiwicm9sZSI6ImFub24iLCJpYXQiOjE3ODA5NTkwMzAsImV4cCI6MjA5NjUzNTAzMH0.i-GTNnGK_5GMUum_tmUKIiX4NUkmEiJovK_M7BwGFfg'

async function rpc(fn, args) {
  const r = await fetch(`${SB}/rpc/${fn}`, { method: 'POST', headers: { apikey: ANON, Authorization: 'Bearer ' + ANON, 'Content-Type': 'application/json' }, body: JSON.stringify(args) })
  const txt = await r.text()
  let d = null; try { d = txt ? JSON.parse(txt) : null } catch (e) { /* */ }
  if (!r.ok) throw Object.assign(new Error((d && (d.message || d.hint)) || ('Supabase ' + r.status)), { status: r.status })
  return d
}

/** Envía el mail. Devuelve '' si salió bien o el texto del error. */
export async function enviarMail({ to, subject, html, text }) {
  const gas = process.env.MAIL_APPS_SCRIPT_URL
  if (gas) {
    const r = await fetch(gas, { method: 'POST', headers: { 'Content-Type': 'text/plain;charset=utf-8' }, body: JSON.stringify({ secret: process.env.MAIL_SECRET || '', to, subject, html, text, nombre: 'Easy Lunch · Local Prosegur' }), redirect: 'follow' })
    const t = await r.text()
    let d = null; try { d = JSON.parse(t) } catch (e) { /* */ }
    if (!r.ok || !d || !d.ok) return 'Apps Script: ' + ((d && d.error) || ('respuesta ' + r.status))
    return ''
  }
  if (process.env.RESEND_API_KEY) {
    const r = await fetch('https://api.resend.com/emails', {
      method: 'POST', headers: { Authorization: 'Bearer ' + process.env.RESEND_API_KEY, 'Content-Type': 'application/json' },
      body: JSON.stringify({ from: process.env.MAIL_FROM || 'Easy Lunch <onboarding@resend.dev>', to, subject, html, text })
    })
    if (!r.ok) return 'Resend: ' + (await r.text()).slice(0, 200)
    return ''
  }
  return 'Falta configurar el envío de mails en Vercel (MAIL_APPS_SCRIPT_URL + MAIL_SECRET, o RESEND_API_KEY + MAIL_FROM).'
}

export default async function handler(req, res) {
  res.setHeader('Cache-Control', 'no-store')
  if (req.method !== 'POST') return res.status(405).json({ ok: false, message: 'Usá POST' })
  let body = req.body
  if (typeof body === 'string') { try { body = JSON.parse(body) } catch (e) { body = {} } }
  const token = String((body && body.token) || '')
  const turno = Number(body && body.turno)
  if (!token || !turno) return res.status(400).json({ ok: false, message: 'Faltan datos.' })
  try {
    const d = await rpc('caja_turno_resumen', { p_token: token, p_id: turno })
    const r = d.resumen
    if (!r || !r.cerrado) return res.status(400).json({ ok: false, message: 'La caja de ese turno todavía está abierta.' })
    const destinos = Array.isArray(d.destinatarios) ? d.destinatarios.filter(x => typeof x === 'string' && /^[^@\s]+@[^@\s]+\.[^@\s]+$/.test(x)) : []
    let estado
    if (!destinos.length) estado = 'sin destinatarios'
    else {
      const error = await enviarMail({ to: destinos, subject: asuntoInforme(r), html: informeHTML(r), text: informeTexto(r) })
      estado = error ? 'error: ' + error : 'enviado'
    }
    await rpc('caja_turno_mail_registrar', { p_token: token, p_id: turno, p_estado: estado, p_destinos: destinos }).catch(() => {})
    return res.status(200).json({ ok: estado === 'enviado', estado, destinos })
  } catch (e) {
    return res.status(e.status === 400 ? 400 : 502).json({ ok: false, message: String((e && e.message) || e) })
  }
}
