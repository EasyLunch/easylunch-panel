// Vercel Serverless Function · /api/gourmet-empresas
// Lista de empresas de la plataforma principal (app.easylunch.com.ar) para elegirlas en el admin Gourmet.
// Devuelve SOLO id, nombre y si está activa (la tabla original trae datos sensibles que no se reenvían).

const ORIGEN = 'https://app.easylunch.com.ar/server/traer-tabla-por-id.php?tabla=empresa&id=0&order=ASC&by=nombre'

export default async function handler(req, res) {
  res.setHeader('Cache-Control', 's-maxage=300, stale-while-revalidate=600')
  try {
    const r = await fetch(ORIGEN, { headers: { Accept: 'application/json' } })
    if (!r.ok) return res.status(502).json({ error: 'El sistema de Easy Lunch respondió ' + r.status })
    const data = await r.json()
    if (!Array.isArray(data)) return res.status(502).json({ error: 'Respuesta inesperada del sistema' })
    const empresas = data
      .map(e => ({ id: String(e.id), nombre: String(e.nombre || '').trim(), activa: String(e.activa) !== '0' }))
      .filter(e => e.id && e.nombre)
      .sort((a, b) => a.nombre.localeCompare(b.nombre, 'es'))
    return res.status(200).json(empresas)
  } catch (e) {
    return res.status(500).json({ error: 'No se pudo leer la lista de empresas: ' + e.message })
  }
}
