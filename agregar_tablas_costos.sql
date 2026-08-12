// Vercel Serverless Function — OCR de facturas/tickets con Gemini (visión)
// Recibe una foto (base64) y devuelve el comprobante estructurado en JSON.
// Reusa la misma GEMINI_API_KEY que api/emplatado.js.

const SCHEMA = {
  type: 'object',
  properties: {
    proveedor: { type: 'string' },
    cuit: { type: 'string' },
    tipo: { type: 'string' },              // "Factura A" | "Factura B" | "Ticket" | "Remito"...
    punto_venta: { type: 'string' },
    nro_comprobante: { type: 'string' },
    fecha: { type: 'string' },             // YYYY-MM-DD
    cond_iva: { type: 'string' },
    cae: { type: 'string' },
    es_fiscal: { type: 'boolean' },        // true si discrimina IVA / es factura formal
    moneda: { type: 'string' },
    items: {
      type: 'array',
      items: {
        type: 'object',
        properties: {
          descripcion: { type: 'string' },
          cantidad: { type: 'number' },
          unidad: { type: 'string' },      // kg,g,lt,ml,unidad,docena,atado,bolsa,cajon,caja...
          precio_unit: { type: 'number' }, // por unidad de compra, SIN IVA si es fiscal
          iva_pct: { type: 'number' },     // 21, 10.5, 0...
          subtotal_neto: { type: 'number' },
          total: { type: 'number' },       // subtotal con IVA
          confianza: { type: 'string' }    // "alta" | "media" | "baja"
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

const PROMPT = `Sos un experto en comprobantes argentinos (facturas AFIP y tickets de comercios). Analizá la imagen y devolvé SOLO el JSON del comprobante, sin texto extra.

Reglas:
- Números en formato "plano": punto decimal, SIN separador de miles. Ej: "1.234,56" -> 1234.56 ; "$38.000" -> 38000.
- Fecha en formato YYYY-MM-DD. Si dice 07/08/2026 es 2026-08-07 (día/mes/año).
- "tipo": si es Factura A/B/C ponelo así; si es ticket no fiscal poné "Ticket".
- "es_fiscal": true si el comprobante discrimina IVA o es una factura formal (tiene CAE / CUIT / alícuotas). false si es un ticket "documento no fiscal" o remito sin IVA.
- Ítems: un objeto por renglón. "cantidad" es el número comprado, "unidad" la unidad de ese renglón (kg, g, lt, ml, unidad, docena, atado, bolsa, cajon, caja). Si el renglón dice "por peso" usá kg; si dice "por unidad" usá unidad, salvo que se lea claramente otra (bolsa, atado, cajón).
- "precio_unit": precio por unidad de compra. Si el comprobante ES fiscal y muestra precio neto (sin IVA), poné el neto y completá "iva_pct" (21 o 10.5). Si NO es fiscal, poné el precio tal cual y iva_pct 0.
- "subtotal_neto" y "total": del renglón (total = con IVA; si no hay IVA, total = subtotal).
- TICKETS MANUSCRITOS: a veces el nombre del producto está escrito a mano al lado del renglón impreso "cantidad x precio = importe". Usá ESE nombre manuscrito como "descripcion". Verificá que cantidad x precio_unit ≈ importe; si no coincide, marcá "confianza":"baja".
- Si algo no se lee con seguridad, igual devolvé tu mejor lectura y poné "confianza":"baja" en ese ítem.
- Respetá el orden de aparición de los renglones.`

export default async function handler(req, res) {
  res.setHeader('Access-Control-Allow-Origin', '*')
  res.setHeader('Access-Control-Allow-Headers', 'Content-Type')
  if (req.method === 'OPTIONS') return res.status(200).end()
  if (req.method !== 'POST') return res.status(405).json({ error: 'Solo POST' })
  try {
    const body = req.body || {}
    let { image, mimeType } = body
    if (!image) return res.status(400).json({ error: 'Falta la imagen' })
    // aceptar data URL o base64 puro
    if (image.startsWith('data:')) {
      const m = image.match(/^data:([^;]+);base64,(.*)$/)
      if (m) { mimeType = mimeType || m[1]; image = m[2] }
    }
    mimeType = mimeType || 'image/jpeg'

    const GK = process.env.GEMINI_API_KEY
    if (!GK) return res.status(500).json({ error: 'Falta GEMINI_API_KEY en Vercel (Settings → Environment Variables)' })
    const model = process.env.GEMINI_OCR_MODEL || 'gemini-2.5-flash'

    const g = await fetch(`https://generativelanguage.googleapis.com/v1beta/models/${model}:generateContent?key=${GK}`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({
        contents: [{ parts: [ { text: PROMPT }, { inlineData: { mimeType, data: image } } ] }],
        generationConfig: { responseMimeType: 'application/json', responseSchema: SCHEMA, temperature: 0.1 }
      })
    })
    const gj = await g.json()
    if (!g.ok) return res.status(502).json({ error: 'Gemini: ' + ((gj.error && gj.error.message) || g.status) })
    const txt = ((gj.candidates || [])[0]?.content?.parts || []).map(p => p.text).filter(Boolean).join('')
    if (!txt) return res.status(502).json({ error: 'Gemini no devolvió datos (probá de nuevo)' })
    let data
    try { data = JSON.parse(txt) } catch (e) { return res.status(502).json({ error: 'Respuesta no-JSON de Gemini', raw: txt.slice(0, 400) }) }
    return res.status(200).json({ ok: true, comprobante: data })
  } catch (e) {
    return res.status(500).json({ error: String(e).slice(0, 250) })
  }
}
