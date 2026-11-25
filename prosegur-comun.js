// Local Prosegur — funciones compartidas entre la caja (prosegur-caja.html) y Productos y precios (prosegur-precios.html).
// Acá está la regla de precio: así la caja cobra exactamente lo que muestra la pantalla de precios.
(function (g) {
  var EL = {}
  EL.SB = 'https://xlwcozznliafhouhqjzl.supabase.co/rest/v1'
  EL.KEY = 'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6Inhsd2NvenpubGlhZmhvdWhxanpsIiwicm9sZSI6ImFub24iLCJpYXQiOjE3ODA5NTkwMzAsImV4cCI6MjA5NjUzNTAzMH0.i-GTNnGK_5GMUum_tmUKIiX4NUkmEiJovK_M7BwGFfg'
  EL.TOKEN_KEY = 'el_panel_token'
  EL.TIPOS = { vianda: 'Viandas', postre: 'Postres', bebida: 'Bebidas', cafeteria: 'Cafetería', kiosco: 'Kiosco', otro: 'Otros' }
  EL.ORDEN_TIPO = ['vianda', 'postre', 'bebida', 'cafeteria', 'kiosco', 'otro']

  EL.esc = function (s) { return String(s == null ? '' : s).replace(/[&<>"']/g, function (c) { return { '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c] }) }
  EL.plata = function (n) { if (n == null || n === '') return '—'; var v = Number(n); return '$' + v.toLocaleString('es-AR', { minimumFractionDigits: v % 1 ? 2 : 0, maximumFractionDigits: 2 }) }
  EL.token = function () { try { return localStorage.getItem(EL.TOKEN_KEY) } catch (e) { return null } }
  EL.rpc = function (fn, args) {
    return fetch(EL.SB + '/rpc/' + fn, { method: 'POST', headers: { apikey: EL.KEY, Authorization: 'Bearer ' + EL.KEY, 'Content-Type': 'application/json' }, body: JSON.stringify(args || {}) })
      .then(function (r) {
        return r.text().then(function (t) {
          var d = null; try { d = t ? JSON.parse(t) : null } catch (e) { }
          if (!r.ok) throw new Error((d && (d.message || d.hint)) || 'Error ' + r.status)
          if (d && d.error) throw new Error(d.error)
          return d
        })
      })
  }

  // ─── regla de precio ───
  /** El producto se puede vender: está activo y (es del local o sigue habilitado en la app). */
  EL.enCaja = function (p) { return !!p.activo && (p.origen === 'local' || !!p.en_app) }
  /** Precio de lista: el precio local si hay; si no, el de la app (o el cargado, en los del local). */
  EL.precioLista = function (p) { return p.precio_local != null ? Number(p.precio_local) : (p.precio_base != null ? Number(p.precio_base) : null) }
  EL.descuentoVigente = function (d, p, ahora) {
    if (!d.activo) return false
    var hoy = ahora.getFullYear() + '-' + String(ahora.getMonth() + 1).padStart(2, '0') + '-' + String(ahora.getDate()).padStart(2, '0')
    if (d.desde && hoy < d.desde) return false
    if (d.hasta && hoy > d.hasta) return false
    var dow = ahora.getDay() || 7
    if (d.dias && d.dias.length && d.dias.indexOf(dow) === -1) return false
    var hm = String(ahora.getHours()).padStart(2, '0') + ':' + String(ahora.getMinutes()).padStart(2, '0')
    if (d.hora_desde && hm < d.hora_desde) return false
    if (d.hora_hasta && hm >= d.hora_hasta) return false
    if (d.alcance === 'categoria') return d.alcance_valor === p.categoria
    if (d.alcance === 'producto') return String(d.alcance_valor) === String(p.id)
    return true
  }
  /** Precio final de UNA unidad: lista menos el MAYOR descuento vigente (no se suman). */
  EL.precioFinal = function (p, descuentos, ahora) {
    var lista = EL.precioLista(p)
    if (lista == null) return { lista: null, final: null, desc: null, ahorro: 0 }
    var mejor = null, monto = 0
    ;(descuentos || []).forEach(function (d) {
      if (!EL.descuentoVigente(d, p, ahora)) return
      var m = d.tipo === 'porcentaje' ? lista * Number(d.valor) / 100 : Math.min(lista, Number(d.valor))
      if (m > monto) { monto = m; mejor = d }
    })
    var final = Math.round((lista - monto) * 100) / 100
    return { lista: lista, final: final, desc: mejor, ahorro: Math.round((lista - final) * 100) / 100 }
  }
  /** Foto del producto: la subida en el panel; si no, la de la app. */
  EL.foto = function (p) { return p.img_local || p.img || null }
  /** Orden de categorías para solapas y listas: "Plato del día" primero, después por tipo y nombre. */
  EL.ordenCategorias = function (prods) {
    var vistas = {}
    prods.forEach(function (p) {
      var c = p.categoria || 'Otros'
      var t = EL.ORDEN_TIPO.indexOf(p.tipo); if (t < 0) t = 99
      if (!(c in vistas) || t < vistas[c]) vistas[c] = t
    })
    return Object.keys(vistas).sort(function (a, b) {
      if (a === 'Plato del día') return -1
      if (b === 'Plato del día') return 1
      return (vistas[a] - vistas[b]) || a.localeCompare(b, 'es')
    })
  }
  g.EL = EL
})(window)
