// Vercel Serverless Function — OCR de facturas/tickets con Gemini (visión)
// Recibe una o varias fotos (base64) y devuelve el comprobante estructurado en JSON.
// Reusa la misma GEMINI_API_KEY que api/emplatado.js.
// Elige solo un modelo disponible (a prueba de deprecaciones). Podés forzar uno con GEMINI_OCR_MODEL.

const SCHEMA = {
  type: 'object',
  properties: {
    proveedor: { type: 'string' },
    cuit: { type: 'string' },
    tipo: { type: 'string' },
    punto_venta: { type: 'string' },
    nro_comprobante: { type: 'string' },
    fecha: { type: 'string' },
    cond_iva: { type: 'string' },
    cae: { type: 'string' },
    es_fiscal: { type: 'boolean' },
    moneda: { type: 'string' },
    items: {
      type: 'array',
      items: {
        type: 'object',
        properties: {
          descripcion: { type: 'string' },
          cantidad: { type: 'number' },
          unidad: { type: 'string' },
          precio_unit: { type: 'number' },
          iva_pct: { type: 'number' },
          subtotal_neto: { type: 'number' },
          total: { type: 'number' },
          confianza: { type: 'string' }
        },
        required: ['descripcion', 'cantidad', 'unidad', 'precio_unit', 'total']
      }
    },
    total_neto: { type: 'number' },
    total_iva: { type: 'number' },
    total: { type: 'number' }
  },
  required: ['proveedor', 'tipo', 'fecha', 'es_fiscal', 'items', 'total']
}

const PROMPT = `Sos un experto en comprobantes argentinos (facturas AFIP y tickets de comercios). Analizá la o las imágenes y devolvé SOLO el JSON del comprobante, sin texto extra.

Reglas:
- Puede haber VARIAS imágenes del MISMO comprobante (ej. un ticket largo partido en varias fotos, o el frente y el dorso). Combiná TODOS los renglones en una sola lista, en orden, SIN duplicar los que se repitan en el solape entre fotos.
- Números en formato "plano": punto decimal, SIN separador de miles. Ej: "1.234,56" -> 1234.56 ; "$38.000" -> 38000.
- Fecha en formato YYYY-MM-DD. Si dice 07/08/2026 es 2026-08-07 (día/mes/año).
- "tipo": si es Factura A/B/C ponelo así; si es ticket no fiscal poné "Ticket".
- "es_fiscal": true si discrimina IVA o es factura formal (tiene CAE / CUIT / alícuotas). false si es un ticket "documento no fiscal" o remito sin IVA.
- Ítems: un objeto por renglón. "cantidad" es el número comprado, "unidad" la unidad de ese renglón (kg, g, lt, ml, unidad, docena, atado, bolsa, cajon, caja). "por peso" -> kg; "por unidad" -> unidad, salvo que se lea otra.
- "precio_unit": precio por unidad de compra. Si ES fiscal y muestra neto (sin IVA), poné el neto y completá "iva_pct" (21 o 10.5). Si NO es fiscal, poné el precio tal cual e iva_pct 0.
- "subtotal_neto" y "total" del renglón (total = con IVA; si no hay IVA, total = subtotal).
- TICKETS MANUSCRITOS: a veces el nombre del producto está escrito a mano al lado del renglón impreso "cantidad x precio = importe". Usá ESE nombre manuscrito como "descripcion". Verificá cantidad x precio_unit ≈ importe; si no coincide, "confianza":"baja".
- Si algo no se lee seguro, devolvé tu mejor lectura con "confianza":"baja".`

// Permite que Vercel deje correr la función lo suficiente (arranque en frío + Gemini).
export const maxDuration = 60

// Cadena de modelos: se prueban en orden. Si GEMINI_OCR_MODEL está seteado, se usa solo ese.
// El motivo de tener varios: Gemini a veces devuelve 503 "high demand / overloaded" en un modelo
// puntual; en ese caso reintentamos con espera y, si sigue, caemos al siguiente modelo.
const MODELS = process.env.GEMINI_OCR_MODEL
  ? [process.env.GEMINI_OCR_MODEL]
  : ['gemini-flash-latest', 'gemini-2.5-flash', 'gemini-2.0-flash', 'gemini-flash-lite-latest']

const sleep = ms => new Promise(r => setTimeout(r, ms))

// ¿El error es transitorio (vale la pena reintentar el MISMO modelo)?
// 503 overloaded / "high demand", 429 rate limit, 500 internal, timeouts.
const esTransitorio = r => {
  const msg = (r.json && r.json.error && r.json.error.message) || ''
  return r.status === 503 || r.status === 429 || r.status === 500 ||
    /high demand|overloaded|try again later|unavailable|temporarily|deadline|internal error|timeout/i.test(msg)
}

async function pickModelFromList(GK) {
  const r = await fetch(`https://generativelanguage.googleapis.com/v1beta/models?key=${GK}&pageSize=1000`)
  const j = await r.json()
  const names = (j.models || [])
    .filter(m => (m.supportedGenerationMethods || []).includes('generateContent'))
    .map(m => String(m.name || '').replace(/^models\//, ''))
  const bad = /image|imagen|tts|audio|embedding|aqa|live|learnlm|gemma|veo|robotics/i
  const score = n => {
    if (bad.test(n)) return -1
    let s = 0
    if (/flash/i.test(n)) s += 100
    if (/lite/i.test(n)) s -= 30
    if (/latest/i.test(n)) s += 20
    const v = (n.match(/gemini-(\d+(?:\.\d+)?)/) || [])[1]
    if (v) s += parseFloat(v) * 5
    if (/pro/i.test(n)) s += 10
    return s
  }
  const ranked = names.filter(n => !bad.test(n)).sort((a, b) => score(b) - score(a))
  return ranked[0] || 'gemini-2.0-flash'
}

// Un intento contra un modelo dado. Devuelve {ok, status, json}.
async function callGemini(GK, model, parts) {
  const g = await fetch(`https://generativelanguage.googleapis.com/v1beta/models/${model}:generateContent?key=${GK}`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ contents: [{ parts }], generationConfig: { responseMimeType: 'application/json', responseSchema: SCHEMA, temperature: 0.1 } })
  })
  const json = await g.json().catch(() => ({}))
  return { ok: g.ok, status: g.status, json }
}
const modelNoDisponible = r =>
  r.status === 404 ||
  /not found|not supported|no.?such.?model|is not available|deprecat/i.test((r.json && r.json.error && r.json.error.message) || '')

function toInline(s, fallbackMime) {
  if (typeof s !== 'string') return null
  if (s.startsWith('data:')) {
    const m = s.match(/^data:([^;]+);base64,(.*)$/)
    if (m) return { mimeType: m[1], data: m[2] }
  }
  return { mimeType: fallbackMime || 'image/jpeg', data: s }
}

export default async function handler(req, res) {
  res.setHeader('Access-Control-Allow-Origin', '*')
  res.setHeader('Access-Control-Allow-Headers', 'Content-Type')
  if (req.method === 'OPTIONS') return res.status(200).end()
  if (req.method !== 'POST') return res.status(405).json({ error: 'Solo POST' })
  try {
    const body = req.body || {}
    const { image, images, mimeType } = body
    let raw = Array.isArray(images) && images.length ? images : (image ? [image] : [])
    const inlines = raw.map(s => toInline(s, mimeType)).filter(Boolean)
    if (!inlines.length) return res.status(400).json({ error: 'Falta la imagen' })

    const GK = process.env.GEMINI_API_KEY
    if (!GK) return res.status(500).json({ error: 'Falta GEMINI_API_KEY en Vercel (Settings → Environment Variables)' })

    const parts = [{ text: PROMPT }, ...inlines.map(i => ({ inlineData: i }))]

    // Estrategia: recorrer la cadena de modelos. En cada uno, hasta 3 intentos con espera
    // creciente si el error es transitorio (503 "high demand" / 429 / 500). Si el modelo no
    // existe, pasar al siguiente. Si un modelo devuelve OK, listo.
    let r = null, model = null, ultimoMsg = ''
    outer:
    for (const m of MODELS) {
      for (let intento = 0; intento < 3; intento++) {
        r = await callGemini(GK, m, parts)
        model = m
        if (r.ok) break outer
        ultimoMsg = (r.json && r.json.error && r.json.error.message) || ('HTTP ' + r.status)
        if (modelNoDisponible(r)) break            // este modelo no sirve → probar el siguiente
        if (esTransitorio(r) && intento < 2) {      // saturado → esperar y reintentar el mismo
          await sleep(1500 * (intento + 1))         // 1.5s, luego 3s
          continue
        }
        break                                       // error no reintentable → siguiente modelo
      }
    }

    // Último recurso: si ningún modelo de la lista respondió, listar modelos disponibles y probar uno.
    if (!r || !r.ok) {
      try {
        const alt = await pickModelFromList(GK)
        if (alt && !MODELS.includes(alt)) {
          const r2 = await callGemini(GK, alt, parts)
          if (r2.ok) { r = r2; model = alt }
        }
      } catch (e) { /* seguimos con el error original */ }
    }

    if (!r || !r.ok) {
      const saturado = r && esTransitorio(r)
      return res.status(saturado ? 503 : 502).json({
        error: saturado
          ? 'El lector está con mucha demanda en este momento. Esperá unos segundos y tocá Procesar de nuevo.'
          : 'Gemini (' + model + '): ' + ultimoMsg
      })
    }
    const gj = r.json
    const txt = ((gj.candidates || [])[0]?.content?.parts || []).map(p => p.text).filter(Boolean).join('')
    if (!txt) return res.status(502).json({ error: 'Gemini no devolvió datos (probá de nuevo)' })
    let data
    try { data = JSON.parse(txt) } catch (e) { return res.status(502).json({ error: 'Respuesta no-JSON de Gemini', raw: txt.slice(0, 400) }) }
    return res.status(200).json({ ok: true, comprobante: data, modelo: model })
  } catch (e) {
    return res.status(500).json({ error: String(e).slice(0, 250) })
  }
}
