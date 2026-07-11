// Vercel Serverless Function — genera foto de emplatado con Gemini y la cachea en Supabase
const SB = 'https://xlwcozznliafhouhqjzl.supabase.co'
const SK = 'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6Inhsd2NvenpubGlhZmhvdWhxanpsIiwicm9sZSI6ImFub24iLCJpYXQiOjE3ODA5NTkwMzAsImV4cCI6MjA5NjUzNTAzMH0.i-GTNnGK_5GMUum_tmUKIiX4NUkmEiJovK_M7BwGFfg'
const norm = s => String(s || '').toLowerCase().normalize('NFD').replace(/[̀-ͯ]/g, '').replace(/[^a-z0-9 ]/g, ' ').replace(/\s+/g, ' ').trim()

export default async function handler(req, res) {
  res.setHeader('Access-Control-Allow-Origin', '*')
  res.setHeader('Access-Control-Allow-Headers', 'Content-Type')
  if (req.method === 'OPTIONS') return res.status(200).end()
  if (req.method !== 'POST') return res.status(405).json({ error: 'Solo POST' })
  try {
    const { nombre } = req.body || {}
    if (!nombre) return res.status(400).json({ error: 'Falta el nombre del plato' })
    const GK = process.env.GEMINI_API_KEY
    if (!GK) return res.status(500).json({ error: 'Falta configurar GEMINI_API_KEY en Vercel (Settings → Environment Variables)' })
    const model = process.env.GEMINI_MODEL || 'gemini-2.5-flash-image'

    // cache: si ya existe, devolverla
    const nn = norm(nombre)
    const cache = await fetch(`${SB}/rest/v1/emplatados?nombre_norm=eq.${encodeURIComponent(nn)}&select=url`, {
      headers: { apikey: SK, Authorization: 'Bearer ' + SK }
    }).then(r => r.json()).catch(() => [])
    if (Array.isArray(cache) && cache[0] && cache[0].url && !req.body.regenerar) return res.status(200).json({ url: cache[0].url, cache: true })

    const prompt = `Fotografía gastronómica profesional en vista cenital de: ${nombre}. ` +
      'Servido en una bandeja plástica descartable TRANSPARENTE (tipo cristal, para viandas), formato 105: RECTANGULAR de 22,8 cm de largo x 18,0 cm de ancho x 4,1 cm de alto, claramente más larga que ancha, SIN divisiones internas. Se ve el plástico transparente en los bordes y la comida ocupa toda la bandeja. ' +
      'Emplatado GOURMET, muy tentador y apetitoso, nivel fotografía publicitaria de comida: proteína dorada y brillante como protagonista, salsa aplicada en cordón o espejo elegante, guarnición con volumen y color, terminación con hierbas frescas picadas o semillas espolvoreadas por encima, contraste de colores vibrante, texturas visibles. ' +
      'Mesa de madera clara, luz natural suave, estilo catering premium, alta resolución, comida real casera argentina.'

    const g = await fetch(`https://generativelanguage.googleapis.com/v1beta/models/${model}:generateContent?key=${GK}`, {
      method: 'POST', headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ contents: [{ parts: [{ text: prompt }] }], generationConfig: { responseModalities: ['TEXT', 'IMAGE'] } })
    })
    const gj = await g.json()
    if (!g.ok) return res.status(502).json({ error: 'Gemini: ' + ((gj.error && gj.error.message) || g.status) })
    const part = ((gj.candidates || [])[0]?.content?.parts || []).find(p => p.inlineData)
    if (!part) return res.status(502).json({ error: 'Gemini no devolvió imagen (probá de nuevo)' })

    const buf = Buffer.from(part.inlineData.data, 'base64')
    const file = nn.replace(/ /g, '-').slice(0, 70) + '-' + Date.now() + '.png'
    const up = await fetch(`${SB}/storage/v1/object/emplatados/${file}`, {
      method: 'POST',
      headers: { apikey: SK, Authorization: 'Bearer ' + SK, 'Content-Type': part.inlineData.mimeType || 'image/png' },
      body: buf
    })
    if (!up.ok) return res.status(502).json({ error: 'Storage: ' + (await up.text()).slice(0, 180) })
    const url = `${SB}/storage/v1/object/public/emplatados/${file}`

    await fetch(`${SB}/rest/v1/emplatados`, {
      method: 'POST',
      headers: { apikey: SK, Authorization: 'Bearer ' + SK, 'Content-Type': 'application/json', Prefer: 'resolution=merge-duplicates' },
      body: JSON.stringify([{ nombre_norm: nn, url }])
    })
    return res.status(200).json({ url })
  } catch (e) {
    return res.status(500).json({ error: String(e).slice(0, 250) })
  }
}
