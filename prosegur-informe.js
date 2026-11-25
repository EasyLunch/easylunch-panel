// Local Prosegur — informe de cierre de caja (HTML para mail y para verlo en el panel).
// Lo usan api/caja-cierre.js (mail) y prosegur-precios.html (pestaña Cierres). Es un módulo ES sin dependencias.

const TZ = 'America/Argentina/Buenos_Aires'
const esc = s => String(s == null ? '' : s).replace(/[&<>"']/g, c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]))
const plata = n => {
  if (n == null || n === '') return '—'
  const v = Number(n), abs = Math.abs(v)
  const ent = Math.trunc(abs).toString().replace(/\B(?=(\d{3})+(?!\d))/g, '.')
  const dec = Math.round((abs - Math.trunc(abs)) * 100)
  return (v < 0 ? '-' : '') + '$' + ent + (dec ? ',' + String(dec).padStart(2, '0') : '')
}
const fecha = iso => iso ? new Date(iso).toLocaleDateString('es-AR', { timeZone: TZ, weekday: 'long', day: 'numeric', month: 'long', year: 'numeric' }) : ''
const hora = iso => iso ? new Date(iso).toLocaleTimeString('es-AR', { timeZone: TZ, hour: '2-digit', minute: '2-digit', hour12: false }) : ''
const mayus = t => t ? t.charAt(0).toUpperCase() + t.slice(1) : t
const MEDIOS = { efectivo: 'Efectivo', qr: 'QR Mercado Pago', tarjeta: 'Tarjeta', otro: 'Otro' }
const num = n => (Math.round(Number(n || 0) * 1000) / 1000).toLocaleString('es-AR')

export function asuntoInforme(r) {
  const d = r.cerrado || r.abierto
  const f = d ? new Date(d).toLocaleDateString('es-AR', { timeZone: TZ, day: '2-digit', month: '2-digit', year: 'numeric' }) : ''
  const dif = r.diferencia == null ? '' : Number(r.diferencia) === 0 ? ' · caja OK' : ' · diferencia ' + plata(r.diferencia)
  return `Cierre de caja Local Prosegur ${f} · ${plata(r.total)} en ${r.tickets} ticket${r.tickets === 1 ? '' : 's'}${dif}`
}

export function informeHTML(r) {
  const td = 'padding:7px 10px;border-bottom:1px solid #eef2f7;font-size:14px;'
  const tdr = td + 'text-align:right;white-space:nowrap;'
  const th = 'padding:7px 10px;border-bottom:2px solid #e2e8f0;font-size:12px;color:#64748b;text-align:left;text-transform:uppercase;letter-spacing:.4px;'
  const thr = th + 'text-align:right;'
  const h2 = 'font-size:16px;color:#0f172a;margin:26px 0 8px;'
  const tabla = (cab, filas) => `<table role="presentation" cellspacing="0" cellpadding="0" style="width:100%;border-collapse:collapse;">${cab}${filas}</table>`
  const dif = r.diferencia == null ? null : Number(r.diferencia)
  const colorDif = dif == null ? '#0f172a' : dif === 0 ? '#15803d' : dif > 0 ? '#1d4ed8' : '#b91c1c'
  const textoDif = dif == null ? '—' : dif === 0 ? 'Sin diferencia' : (dif > 0 ? 'Sobrante ' : 'Faltante ') + plata(Math.abs(dif))
  const medios = Object.entries(r.por_medio || {})
  const kpi = (t, v, sub) => `<td style="padding:12px 14px;background:#f8fafc;border-radius:10px;width:33%;vertical-align:top;"><div style="font-size:12px;color:#64748b;">${t}</div><div style="font-size:22px;font-weight:800;color:#0f172a;margin-top:2px;">${v}</div>${sub ? `<div style="font-size:12px;color:#64748b;margin-top:2px;">${sub}</div>` : ''}</td>`
  const ticketProm = r.tickets ? Number(r.total) / r.tickets : 0

  let h = `<div style="font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',Roboto,Arial,sans-serif;color:#0f172a;max-width:680px;margin:0 auto;">`
  h += `<div style="background:#0f172a;color:#fff;padding:18px 22px;border-radius:14px 14px 0 0;"><div style="font-size:13px;color:#94a3b8;">Easy Lunch · Local Prosegur</div>`
  h += `<div style="font-size:21px;font-weight:800;margin-top:2px;">Cierre de caja</div><div style="font-size:13px;color:#cbd5e1;margin-top:4px;">${esc(mayus(fecha(r.abierto)))}</div></div>`
  h += `<div style="border:1px solid #e2e8f0;border-top:0;border-radius:0 0 14px 14px;padding:18px 22px;">`
  h += `<div style="font-size:13px;color:#475569;">Abrió <b>${esc(r.abierto_por)}</b> a las ${hora(r.abierto)}${r.cerrado ? ` · cerró <b>${esc(r.cerrado_por)}</b> a las ${hora(r.cerrado)}` : ' · <b>caja abierta</b>'}</div>`
  h += `<table role="presentation" cellspacing="8" cellpadding="0" style="width:100%;margin:14px -8px 0;"><tr>${kpi('Vendido', plata(r.total), r.descuentos > 0 ? 'Descuentos: ' + plata(r.descuentos) : '')}${kpi('Tickets', r.tickets, 'Promedio ' + plata(Math.round(ticketProm)))}${kpi('Productos', num(r.unidades), '')}</tr></table>`

  h += `<h2 style="${h2}">Por medio de pago</h2>`
  h += tabla(`<tr><th style="${th}">Medio</th><th style="${thr}">Tickets</th><th style="${thr}">Total</th></tr>`,
    (medios.length ? medios.map(([m, x]) => `<tr><td style="${td}">${esc(MEDIOS[m] || m)}</td><td style="${tdr}">${x.tickets}</td><td style="${tdr}"><b>${plata(x.total)}</b></td></tr>`).join('') : `<tr><td style="${td}" colspan="3">Sin ventas</td></tr>`))

  h += `<h2 style="${h2}">Arqueo de efectivo</h2>`
  h += tabla('', [
    ['Fondo inicial', plata(r.fondo_inicial)],
    ['+ Ventas en efectivo', plata(r.ventas_efectivo)],
    ['+ Ingresos de efectivo', plata(r.ingresos)],
    ['− Egresos de efectivo', plata(r.egresos)],
    ['<b>= Efectivo esperado</b>', `<b>${plata(r.efectivo_esperado)}</b>`],
    ['Efectivo contado', r.efectivo_contado == null ? '—' : `<b>${plata(r.efectivo_contado)}</b>`]
  ].map(([a, b]) => `<tr><td style="${td}">${a}</td><td style="${tdr}">${b}</td></tr>`).join('') +
    `<tr><td style="${td}font-weight:800;color:${colorDif};">Diferencia</td><td style="${tdr}font-weight:800;color:${colorDif};">${textoDif}</td></tr>`)
  if (r.notas) h += `<div style="margin-top:10px;font-size:13px;background:#f8fafc;border-radius:8px;padding:10px 12px;"><b>Notas del cierre:</b> ${esc(r.notas)}</div>`

  if ((r.movimientos || []).length) {
    h += `<h2 style="${h2}">Ingresos y egresos de efectivo</h2>`
    h += tabla(`<tr><th style="${th}">Hora</th><th style="${th}">Motivo</th><th style="${th}">Quién</th><th style="${thr}">Monto</th></tr>`,
      r.movimientos.map(m => `<tr><td style="${td}">${hora(m.fecha)}</td><td style="${td}">${esc(m.motivo)}</td><td style="${td}">${esc(m.usuario)}</td><td style="${tdr}color:${m.tipo === 'egreso' ? '#b91c1c' : '#15803d'};">${m.tipo === 'egreso' ? '−' : '+'}${plata(m.monto)}</td></tr>`).join(''))
  }
  if ((r.anuladas || []).length) {
    h += `<h2 style="${h2}">Ventas anuladas</h2>`
    h += tabla(`<tr><th style="${th}">Venta</th><th style="${th}">Hora</th><th style="${th}">Anuló</th><th style="${th}">Motivo</th><th style="${thr}">Total</th></tr>`,
      r.anuladas.map(a => `<tr><td style="${td}">#${a.id}</td><td style="${td}">${hora(a.fecha)}</td><td style="${td}">${esc(a.por)}</td><td style="${td}">${esc(a.motivo)}</td><td style="${tdr}">${plata(a.total)}</td></tr>`).join(''))
  }
  if ((r.por_categoria || []).length) {
    h += `<h2 style="${h2}">Ventas por categoría</h2>`
    h += tabla(`<tr><th style="${th}">Categoría</th><th style="${thr}">Unidades</th><th style="${thr}">Total</th></tr>`,
      r.por_categoria.map(c => `<tr><td style="${td}">${esc(c.categoria || 'Sin categoría')}</td><td style="${tdr}">${num(c.unidades)}</td><td style="${tdr}">${plata(c.total)}</td></tr>`).join(''))
  }
  if ((r.productos || []).length) {
    const top = r.productos.slice(0, 20)
    h += `<h2 style="${h2}">Productos más vendidos${r.productos.length > 20 ? ' (top 20 de ' + r.productos.length + ')' : ''}</h2>`
    h += tabla(`<tr><th style="${th}">Producto</th><th style="${thr}">Unidades</th><th style="${thr}">Total</th></tr>`,
      top.map(p => `<tr><td style="${td}">${esc(p.nombre)}</td><td style="${tdr}">${num(p.unidades)}</td><td style="${tdr}">${plata(p.total)}</td></tr>`).join(''))
  }
  if ((r.descuentos_aplicados || []).length) {
    h += `<h2 style="${h2}">Descuentos aplicados</h2>`
    h += tabla(`<tr><th style="${th}">Descuento</th><th style="${thr}">Unidades</th><th style="${thr}">Monto</th></tr>`,
      r.descuentos_aplicados.map(d => `<tr><td style="${td}">${esc(d.nombre)}</td><td style="${tdr}">${num(d.unidades)}</td><td style="${tdr}">${plata(d.monto)}</td></tr>`).join(''))
  }
  if ((r.por_hora || []).length) {
    const max = Math.max(...r.por_hora.map(x => Number(x.total) || 0), 1)
    h += `<h2 style="${h2}">Ventas por hora</h2>`
    h += tabla(`<tr><th style="${th}">Hora</th><th style="${th}"></th><th style="${thr}">Tickets</th><th style="${thr}">Total</th></tr>`,
      r.por_hora.map(x => `<tr><td style="${td}">${String(x.hora).padStart(2, '0')}:00</td><td style="${td}width:45%;"><div style="height:10px;border-radius:5px;background:#16a34a;width:${Math.max(2, Math.round(Number(x.total) / max * 100))}%;"></div></td><td style="${tdr}">${x.tickets}</td><td style="${tdr}">${plata(x.total)}</td></tr>`).join(''))
  }
  if ((r.stock_bajo || []).length) {
    h += `<h2 style="${h2}color:#9a3412;">Stock bajo el mínimo</h2>`
    h += tabla(`<tr><th style="${th}">Producto / insumo</th><th style="${thr}">Stock</th><th style="${thr}">Mínimo</th></tr>`,
      r.stock_bajo.map(s => { const u = s.unidad === 'u' ? '' : ' ' + s.unidad; return `<tr><td style="${td}">${esc(s.nombre)}</td><td style="${tdr}color:${Number(s.stock) < 0 ? '#b91c1c' : '#9a3412'};"><b>${num(s.stock)}${u}</b></td><td style="${tdr}">${num(s.minimo)}${u}</td></tr>` }).join(''))
  }
  h += `<div style="margin-top:26px;font-size:12px;color:#94a3b8;">Informe automático del panel de Easy Lunch · Turno #${esc(r.turno)}</div></div></div>`
  return h
}

export function informeTexto(r) {
  const l = [`Cierre de caja · Local Prosegur`, mayus(fecha(r.abierto)), ``,
    `Vendido: ${plata(r.total)} en ${r.tickets} tickets (descuentos ${plata(r.descuentos)})`]
  for (const [m, x] of Object.entries(r.por_medio || {})) l.push(`  ${MEDIOS[m] || m}: ${plata(x.total)} (${x.tickets})`)
  l.push('', `Efectivo esperado: ${plata(r.efectivo_esperado)}`, `Efectivo contado: ${plata(r.efectivo_contado)}`, `Diferencia: ${plata(r.diferencia)}`)
  if (r.notas) l.push('', 'Notas: ' + r.notas)
  return l.join('\n')
}
