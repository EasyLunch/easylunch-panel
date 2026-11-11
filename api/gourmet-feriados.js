// Vercel Serverless Function · /api/gourmet-feriados
// Copia los feriados del sistema (app.easylunch.com.ar → tabla "feriados", los que tienen mostrar = 1)
// a Supabase (gourmet_config, clave "feriados_sistema") para que la app Gourmet y el link público no ofrezcan esos días.
// La llama el cron diario de vercel.json y el admin de Gourmet al abrir. Usa SUPABASE_URL y SUPABASE_SERVICE_ROLE_KEY.

const ORIGEN = 'https://app.easylunch.com.ar/server/buscar-por-tabla.php'

export default async function handler(req, res) {
  res.setHeader('Cache-Control', 'no-store')
  const BASE = String(process.env.SUPABASE_URL || '').replace(/\/+$/, '').replace(/\/rest\/v1$/, '')
  const SERVICE = process.env.SUPABASE_SERVICE_ROLE_KEY
  if (!BASE || !SERVICE) return res.status(500).json({ error: 'Faltan SUPABASE_URL / SUPABASE_SERVICE_ROLE_KEY' })
  try {
    const body = new URLSearchParams({ tabla: 'feriados', data: '{}' })
    const r = await fetch(ORIGEN, { method: 'POST', body, headers: { 'Content-Type': 'application/x-www-form-urlencoded' } })
    if (!r.ok) return res.status(502).json({ error: 'El sistema respondió ' + r.status })
    const lista = await r.json().catch(() => null)
    if (!Array.isArray(lista)) return res.status(502).json({ error: 'Respuesta inesperada del sistema' })
    const fechas = [...new Set(lista
      .filter(f => Number(f.mostrar) !== 0 && /^\d{4}-\d{2}-\d{2}$/.test(String(f.fecha || '').slice(0, 10)))
      .map(f => String(f.fecha).slice(0, 10)))].sort()
    const H = SERVICE.startsWith('sb_')
      ? { apikey: SERVICE, 'Content-Type': 'application/json' }
      : { apikey: SERVICE, Authorization: `Bearer ${SERVICE}`, 'Content-Type': 'application/json' }
    const w = await fetch(`${BASE}/rest/v1/gourmet_config?on_conflict=clave`, {
      method: 'POST',
      headers: { ...H, Prefer: 'resolution=merge-duplicates,return=minimal' },
      body: JSON.stringify({ clave: 'feriados_sistema', valor: fechas })
    })
    if (!w.ok) return res.status(502).json({ error: 'Supabase ' + w.status + ': ' + (await w.text()).slice(0, 200) })
    return res.status(200).json({ ok: true, feriados: fechas })
  } catch (e) {
    return res.status(500).json({ error: String((e && e.message) || e) })
  }
}
