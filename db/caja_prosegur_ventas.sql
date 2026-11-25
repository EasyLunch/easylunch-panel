-- =====================================================================
-- EASY LUNCH · Local Prosegur — ventas, apertura y cierre de caja, stock
-- Correr en Supabase → SQL Editor → New query → Run, DESPUÉS de db/caja_prosegur.sql.
-- Se puede volver a correr sin romper nada (no borra datos).
--
-- Permisos (mismas tarjetas que caja_prosegur.sql):
--  * Cajero ("prosegur-caja"): abre la caja, vende, registra ingresos/egresos de efectivo y cierra.
--  * Encargado ("prosegur-precios"): además anula ventas, carga ingresos de mercadería y ajustes de stock.
--  * Administrador: todo, más la configuración (mails del cierre, stock mínimo, insumos y recetas).
--
-- El precio de cada venta lo calcula la base de datos con la misma regla que la caja y la pantalla
-- de precios (precio local o de la app, menos el mayor descuento vigente). Si el total que manda la
-- tablet no coincide (porque algo cambió mientras se armaba el ticket) la venta no se registra.
-- =====================================================================

-- ---------- columnas nuevas en productos ----------
alter table public.caja_productos add column if not exists control_stock boolean not null default false;
alter table public.caja_productos add column if not exists stock_minimo numeric(12,3) not null default 0;

-- ---------- tablas ----------
create table if not exists public.caja_config (
  local   text not null default 'prosegur',
  clave   text not null,
  valor   jsonb not null default 'null',
  primary key (local, clave)
);

create table if not exists public.caja_turnos (
  id               bigint generated always as identity primary key,
  local            text not null default 'prosegur',
  abierto          timestamptz not null default now(),
  abierto_por      text not null default '',
  fondo_inicial    numeric(12,2) not null default 0,
  cerrado          timestamptz,
  cerrado_por      text,
  efectivo_contado numeric(12,2),
  notas            text not null default '',
  resumen          jsonb,
  mail_estado      text,              -- 'enviado' · 'error: …' · 'sin destinatarios'
  mail_destinos    text[],
  mail_fecha       timestamptz
);
-- una sola caja abierta por local
create unique index if not exists caja_turnos_un_abierto on public.caja_turnos (local) where cerrado is null;

create table if not exists public.caja_ventas (
  id           bigint generated always as identity primary key,
  local        text not null default 'prosegur',
  turno_id     bigint not null references public.caja_turnos(id),
  fecha        timestamptz not null default now(),
  usuario      text not null default '',
  medio        text not null check (medio in ('efectivo','qr','tarjeta','otro')),
  estado       text not null default 'pagada' check (estado in ('pagada','anulada')),
  subtotal     numeric(12,2) not null,
  descuento    numeric(12,2) not null default 0,
  total        numeric(12,2) not null,
  recibido     numeric(12,2),
  client_id    text unique,           -- evita registrar dos veces la misma venta (doble toque / reintento)
  anulada_por  text,
  anulada_fecha timestamptz,
  anulada_motivo text
);
create index if not exists caja_ventas_turno on public.caja_ventas (turno_id);

create table if not exists public.caja_venta_items (
  id              bigint generated always as identity primary key,
  venta_id        bigint not null references public.caja_ventas(id) on delete cascade,
  producto_id     bigint references public.caja_productos(id),
  nombre          text not null,
  categoria       text not null default '',
  tipo            text not null default 'otro',
  cantidad        int not null check (cantidad > 0),
  precio_lista    numeric(12,2) not null,
  precio_unit     numeric(12,2) not null,
  descuento_id    bigint,
  descuento_nombre text,
  total           numeric(12,2) not null,
  iva             numeric(5,2) not null default 21
);
create index if not exists caja_venta_items_venta on public.caja_venta_items (venta_id);

create table if not exists public.caja_movimientos (
  id        bigint generated always as identity primary key,
  local     text not null default 'prosegur',
  turno_id  bigint not null references public.caja_turnos(id),
  fecha     timestamptz not null default now(),
  usuario   text not null default '',
  tipo      text not null check (tipo in ('ingreso','egreso')),
  monto     numeric(12,2) not null check (monto > 0),
  motivo    text not null default ''
);

create table if not exists public.caja_insumos (
  id           bigint generated always as identity primary key,
  local        text not null default 'prosegur',
  nombre       text not null,
  unidad       text not null default 'u' check (unidad in ('g','ml','u')),
  stock_minimo numeric(12,3) not null default 0,
  activo       boolean not null default true
);

create table if not exists public.caja_recetas (
  producto_id bigint not null references public.caja_productos(id) on delete cascade,
  insumo_id   bigint not null references public.caja_insumos(id) on delete cascade,
  cantidad    numeric(12,3) not null check (cantidad > 0),
  primary key (producto_id, insumo_id)
);

create table if not exists public.caja_stock_mov (
  id          bigint generated always as identity primary key,
  local       text not null default 'prosegur',
  fecha       timestamptz not null default now(),
  usuario     text not null default '',
  producto_id bigint references public.caja_productos(id),
  insumo_id   bigint references public.caja_insumos(id),
  tipo        text not null check (tipo in ('ingreso','venta','anulacion','ajuste','merma')),
  cantidad    numeric(12,3) not null,      -- positivo suma, negativo resta
  venta_id    bigint,
  motivo      text not null default '',
  check ((producto_id is null) <> (insumo_id is null))
);
create index if not exists caja_stock_mov_prod on public.caja_stock_mov (producto_id);
create index if not exists caja_stock_mov_ins on public.caja_stock_mov (insumo_id);

do $$ declare t text; begin
  foreach t in array array['caja_config','caja_turnos','caja_ventas','caja_venta_items','caja_movimientos','caja_insumos','caja_recetas','caja_stock_mov'] loop
    execute format('alter table public.%I enable row level security', t);
    execute format('revoke all on public.%I from anon, authenticated', t);
  end loop;
end $$;

-- ---------- helpers ----------
create or replace function public.caja__quien(u public.panel_usuarios)
returns text language sql immutable as $$ select coalesce(nullif(u.nombre, ''), u.usuario); $$;

-- Precio de UNA unidad en un momento dado: lista (local o app) menos el mayor descuento vigente.
-- Misma regla que prosegur-comun.js (EL.precioFinal).
create or replace function public.caja__precio(p public.caja_productos, p_ts timestamptz default now())
returns table(lista numeric, final numeric, desc_id bigint, desc_nombre text)
language plpgsql stable security definer set search_path = public as $$
declare
  v_lista numeric := coalesce(p.precio_local, p.precio_base);
  v_loc timestamp := p_ts at time zone 'America/Argentina/Buenos_Aires';
  v_fecha date := v_loc::date; v_dow int := extract(isodow from v_loc)::int; v_hora time := date_trunc('minute', v_loc)::time;
  d public.caja_descuentos; v_m numeric; mejor numeric := 0; v_id bigint; v_nom text;
begin
  if v_lista is null then return query select null::numeric, null::numeric, null::bigint, null::text; return; end if;
  for d in select * from public.caja_descuentos x where x.local = p.local and x.activo order by x.id loop
    if d.desde is not null and v_fecha < d.desde then continue; end if;
    if d.hasta is not null and v_fecha > d.hasta then continue; end if;
    if d.dias is not null and array_length(d.dias, 1) > 0 and not (v_dow = any(d.dias)) then continue; end if;
    if d.hora_desde is not null and v_hora < d.hora_desde then continue; end if;
    if d.hora_hasta is not null and v_hora >= d.hora_hasta then continue; end if;
    if d.alcance = 'categoria' and d.alcance_valor is distinct from p.categoria then continue; end if;
    if d.alcance = 'producto' and d.alcance_valor is distinct from p.id::text then continue; end if;
    v_m := case when d.tipo = 'porcentaje' then v_lista * d.valor / 100 else least(v_lista, d.valor) end;
    if v_m > mejor then mejor := v_m; v_id := d.id; v_nom := d.nombre; end if;
  end loop;
  return query select v_lista, round(v_lista - mejor, 2), v_id, v_nom;
end $$;

create or replace function public.caja__turno_abierto(p_local text)
returns public.caja_turnos language sql stable security definer set search_path = public as $$
  select * from public.caja_turnos where local = p_local and cerrado is null limit 1;
$$;

-- Totales de un turno (abierto o cerrado)
create or replace function public.caja__resumen(p_turno bigint)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare t public.caja_turnos; r jsonb; v_ef numeric; v_ing numeric; v_egr numeric;
begin
  select * into t from public.caja_turnos where id = p_turno;
  if t.id is null then return null; end if;
  select coalesce(sum(total) filter (where medio = 'efectivo'), 0) into v_ef from public.caja_ventas where turno_id = t.id and estado = 'pagada';
  select coalesce(sum(monto) filter (where tipo = 'ingreso'), 0), coalesce(sum(monto) filter (where tipo = 'egreso'), 0)
    into v_ing, v_egr from public.caja_movimientos where turno_id = t.id;
  r := jsonb_build_object(
    'turno', t.id, 'abierto', t.abierto, 'abierto_por', t.abierto_por, 'cerrado', t.cerrado, 'cerrado_por', t.cerrado_por,
    'fondo_inicial', t.fondo_inicial,
    'tickets', (select count(*) from public.caja_ventas where turno_id = t.id and estado = 'pagada'),
    'total', (select coalesce(sum(total), 0) from public.caja_ventas where turno_id = t.id and estado = 'pagada'),
    'subtotal', (select coalesce(sum(subtotal), 0) from public.caja_ventas where turno_id = t.id and estado = 'pagada'),
    'descuentos', (select coalesce(sum(descuento), 0) from public.caja_ventas where turno_id = t.id and estado = 'pagada'),
    'unidades', (select coalesce(sum(i.cantidad), 0) from public.caja_venta_items i join public.caja_ventas v on v.id = i.venta_id where v.turno_id = t.id and v.estado = 'pagada'),
    'por_medio', coalesce((select jsonb_object_agg(medio, jsonb_build_object('tickets', n, 'total', tot)) from
                   (select medio, count(*) n, sum(total) tot from public.caja_ventas where turno_id = t.id and estado = 'pagada' group by medio) x), '{}'),
    'anuladas', coalesce((select jsonb_agg(jsonb_build_object('id', id, 'fecha', fecha, 'total', total, 'por', anulada_por, 'motivo', anulada_motivo) order by fecha)
                   from public.caja_ventas where turno_id = t.id and estado = 'anulada'), '[]'),
    'por_categoria', coalesce((select jsonb_agg(jsonb_build_object('categoria', categoria, 'unidades', u, 'total', tot) order by tot desc) from
                   (select i.categoria, sum(i.cantidad) u, sum(i.total) tot from public.caja_venta_items i join public.caja_ventas v on v.id = i.venta_id
                    where v.turno_id = t.id and v.estado = 'pagada' group by i.categoria) x), '[]'),
    'productos', coalesce((select jsonb_agg(jsonb_build_object('nombre', nombre, 'unidades', u, 'total', tot) order by u desc, tot desc) from
                   (select i.nombre, sum(i.cantidad) u, sum(i.total) tot from public.caja_venta_items i join public.caja_ventas v on v.id = i.venta_id
                    where v.turno_id = t.id and v.estado = 'pagada' group by i.nombre) x), '[]'),
    'por_hora', coalesce((select jsonb_agg(jsonb_build_object('hora', h, 'tickets', n, 'total', tot) order by h) from
                   (select extract(hour from fecha at time zone 'America/Argentina/Buenos_Aires')::int h, count(*) n, sum(total) tot
                    from public.caja_ventas where turno_id = t.id and estado = 'pagada' group by 1) x), '[]'),
    'descuentos_aplicados', coalesce((select jsonb_agg(jsonb_build_object('nombre', descuento_nombre, 'unidades', u, 'monto', m) order by m desc) from
                   (select i.descuento_nombre, sum(i.cantidad) u, sum((i.precio_lista - i.precio_unit) * i.cantidad) m from public.caja_venta_items i
                    join public.caja_ventas v on v.id = i.venta_id where v.turno_id = t.id and v.estado = 'pagada' and i.descuento_nombre is not null
                    group by i.descuento_nombre) x), '[]'),
    'movimientos', coalesce((select jsonb_agg(jsonb_build_object('fecha', fecha, 'tipo', tipo, 'monto', monto, 'motivo', motivo, 'usuario', usuario) order by fecha)
                   from public.caja_movimientos where turno_id = t.id), '[]'),
    'ventas_efectivo', v_ef, 'ingresos', v_ing, 'egresos', v_egr,
    'efectivo_esperado', t.fondo_inicial + v_ef + v_ing - v_egr,
    'efectivo_contado', t.efectivo_contado,
    'diferencia', case when t.efectivo_contado is null then null else t.efectivo_contado - (t.fondo_inicial + v_ef + v_ing - v_egr) end,
    'notas', t.notas);
  return r;
end $$;

-- Stock actual de productos con control y de insumos
create or replace function public.caja__stock_bajo(p_local text)
returns jsonb language sql stable security definer set search_path = public as $$
  select coalesce(jsonb_agg(x order by x->>'nombre'), '[]') from (
    select jsonb_build_object('nombre', p.nombre, 'stock', coalesce(s.st, 0), 'minimo', p.stock_minimo, 'unidad', 'u') x
    from public.caja_productos p left join (select producto_id, sum(cantidad) st from public.caja_stock_mov group by producto_id) s on s.producto_id = p.id
    where p.local = p_local and p.control_stock and (p.origen = 'local' or p.en_app) and p.activo and coalesce(s.st, 0) <= p.stock_minimo
    union all
    select jsonb_build_object('nombre', i.nombre, 'stock', coalesce(s.st, 0), 'minimo', i.stock_minimo, 'unidad', i.unidad)
    from public.caja_insumos i left join (select insumo_id, sum(cantidad) st from public.caja_stock_mov group by insumo_id) s on s.insumo_id = i.id
    where i.local = p_local and i.activo and coalesce(s.st, 0) <= i.stock_minimo
  ) q;
$$;

-- ---------- caja: turno ----------
create or replace function public.caja_turno_estado(p_token text)
returns json language plpgsql stable security definer set search_path = public as $$
declare u public.panel_usuarios; t public.caja_turnos;
begin
  u := public.caja__permiso(p_token, 'ver');
  t := public.caja__turno_abierto('prosegur');
  if t.id is null then return json_build_object('abierto', false); end if;
  return json_build_object('abierto', true, 'resumen', public.caja__resumen(t.id));
end $$;

create or replace function public.caja_turno_abrir(p_token text, p_fondo numeric)
returns json language plpgsql security definer set search_path = public as $$
declare u public.panel_usuarios; t public.caja_turnos;
begin
  u := public.caja__permiso(p_token, 'ver');
  if coalesce(p_fondo, 0) < 0 then raise exception 'El fondo inicial no puede ser negativo.'; end if;
  if (public.caja__turno_abierto('prosegur')).id is not null then raise exception 'La caja ya está abierta.'; end if;
  insert into public.caja_turnos(local, abierto_por, fondo_inicial) values ('prosegur', public.caja__quien(u), coalesce(p_fondo, 0)) returning * into t;
  return json_build_object('abierto', true, 'resumen', public.caja__resumen(t.id));
end $$;

create or replace function public.caja_movimiento(p_token text, p_tipo text, p_monto numeric, p_motivo text)
returns json language plpgsql security definer set search_path = public as $$
declare u public.panel_usuarios; t public.caja_turnos;
begin
  u := public.caja__permiso(p_token, 'ver');
  t := public.caja__turno_abierto('prosegur');
  if t.id is null then raise exception 'La caja está cerrada.'; end if;
  if p_tipo not in ('ingreso','egreso') then raise exception 'Tipo inválido.'; end if;
  if coalesce(p_monto, 0) <= 0 then raise exception 'Poné el monto.'; end if;
  if coalesce(trim(p_motivo), '') = '' then raise exception 'Poné el motivo (ej.: pago a proveedor, cambio).'; end if;
  insert into public.caja_movimientos(local, turno_id, usuario, tipo, monto, motivo) values ('prosegur', t.id, public.caja__quien(u), p_tipo, p_monto, trim(p_motivo));
  return json_build_object('abierto', true, 'resumen', public.caja__resumen(t.id));
end $$;

create or replace function public.caja_turno_cerrar(p_token text, p_efectivo_contado numeric, p_notas text default '')
returns json language plpgsql security definer set search_path = public as $$
declare u public.panel_usuarios; t public.caja_turnos; r jsonb;
begin
  u := public.caja__permiso(p_token, 'ver');
  t := public.caja__turno_abierto('prosegur');
  if t.id is null then raise exception 'La caja ya está cerrada.'; end if;
  if p_efectivo_contado is null or p_efectivo_contado < 0 then raise exception 'Contá el efectivo de la caja y escribí el total.'; end if;
  update public.caja_turnos set cerrado = now(), cerrado_por = public.caja__quien(u), efectivo_contado = p_efectivo_contado,
         notas = coalesce(trim(p_notas), '') where id = t.id;
  r := public.caja__resumen(t.id) || jsonb_build_object('stock_bajo', public.caja__stock_bajo('prosegur'));
  update public.caja_turnos set resumen = r where id = t.id;
  return json_build_object('turno', t.id, 'resumen', r);
end $$;

-- Resumen de un turno (para el mail o para verlo de nuevo)
create or replace function public.caja_turno_resumen(p_token text, p_id bigint)
returns json language plpgsql stable security definer set search_path = public as $$
declare u public.panel_usuarios; t public.caja_turnos;
begin
  u := public.caja__permiso(p_token, 'ver');
  select * into t from public.caja_turnos where id = p_id and local = 'prosegur';
  if t.id is null then raise exception 'No encontré ese cierre.'; end if;
  -- el cajero solo puede ver el cierre que acaba de hacer (últimas 12 h); el resto es del encargado
  if not (u.es_admin or 'prosegur-precios' = any(u.tarjetas)) and (t.cerrado is null or t.cerrado < now() - interval '12 hours') then
    raise exception 'Tu usuario no tiene permiso para ver ese cierre.';
  end if;
  return json_build_object('turno', t.id, 'resumen', coalesce(t.resumen, public.caja__resumen(t.id)),
                           'mail_estado', t.mail_estado, 'mail_destinos', t.mail_destinos, 'mail_fecha', t.mail_fecha,
                           'destinatarios', (select valor from public.caja_config where local = 'prosegur' and clave = 'mail_cierre'));
end $$;

create or replace function public.caja_turno_mail_registrar(p_token text, p_id bigint, p_estado text, p_destinos text[])
returns void language plpgsql security definer set search_path = public as $$
begin
  perform public.caja__permiso(p_token, 'ver');
  update public.caja_turnos set mail_estado = left(coalesce(p_estado, ''), 300), mail_destinos = p_destinos, mail_fecha = now()
  where id = p_id and local = 'prosegur';
end $$;

create or replace function public.caja_turnos_listar(p_token text, p_limite int default 60)
returns json language plpgsql stable security definer set search_path = public as $$
begin
  perform public.caja__permiso(p_token, 'encargado');
  return coalesce((select json_agg(json_build_object('id', t.id, 'abierto', t.abierto, 'abierto_por', t.abierto_por, 'cerrado', t.cerrado,
                     'cerrado_por', t.cerrado_por, 'resumen', coalesce(t.resumen, public.caja__resumen(t.id)), 'mail_estado', t.mail_estado,
                     'mail_destinos', t.mail_destinos, 'mail_fecha', t.mail_fecha) order by t.abierto desc)
                   from (select * from public.caja_turnos where local = 'prosegur' order by abierto desc limit greatest(1, least(coalesce(p_limite, 60), 400))) t), '[]');
end $$;

-- ---------- caja: ventas ----------
-- p_items: [{id, cant}] · p_medio: efectivo | qr | tarjeta | otro
create or replace function public.caja_venta_registrar(p_token text, p_items jsonb, p_medio text, p_total_esperado numeric,
                                                       p_recibido numeric default null, p_client_id text default null)
returns json language plpgsql security definer set search_path = public as $$
declare
  u public.panel_usuarios; t public.caja_turnos; it jsonb; p public.caja_productos; pr record;
  v_cant int; v_sub numeric := 0; v_tot numeric := 0; v_id bigint; lineas jsonb := '[]'; l jsonb; r public.caja_recetas; ya public.caja_ventas;
begin
  u := public.caja__permiso(p_token, 'ver');
  if p_client_id is not null then
    select * into ya from public.caja_ventas where client_id = p_client_id;
    if ya.id is not null then return json_build_object('id', ya.id, 'total', ya.total, 'repetida', true,
                                                       'vuelto', case when ya.recibido is null then null else ya.recibido - ya.total end); end if;
  end if;
  t := public.caja__turno_abierto('prosegur');
  if t.id is null then raise exception 'La caja está cerrada. Abrila para vender.'; end if;
  if p_medio not in ('efectivo','qr','tarjeta','otro') then raise exception 'Medio de pago inválido.'; end if;
  if jsonb_typeof(p_items) <> 'array' or jsonb_array_length(p_items) = 0 then raise exception 'El ticket está vacío.'; end if;
  for it in select * from jsonb_array_elements(p_items) loop
    v_cant := (it->>'cant')::int;
    if v_cant is null or v_cant < 1 or v_cant > 99 then raise exception 'Cantidad inválida.'; end if;
    select * into p from public.caja_productos where id = (it->>'id')::bigint and local = 'prosegur';
    if p.id is null or not p.activo or (p.origen = 'app' and not p.en_app) then
      raise exception 'Hay un producto del ticket que ya no está disponible. Revisá el ticket.';
    end if;
    select * into pr from public.caja__precio(p, now());
    if pr.lista is null then raise exception '"%" no tiene precio.', p.nombre; end if;
    l := jsonb_build_object('p', p.id, 'nombre', p.nombre, 'categoria', p.categoria, 'tipo', p.tipo, 'cant', v_cant, 'lista', pr.lista,
                            'unit', pr.final, 'desc_id', pr.desc_id, 'desc_nombre', pr.desc_nombre, 'total', round(pr.final * v_cant, 2), 'iva', p.iva);
    lineas := lineas || l;
    v_sub := v_sub + pr.lista * v_cant;
    v_tot := v_tot + round(pr.final * v_cant, 2);
  end loop;
  v_sub := round(v_sub, 2); v_tot := round(v_tot, 2);
  if p_total_esperado is null or abs(v_tot - p_total_esperado) > 0.01 then
    raise exception 'Los precios cambiaron mientras armabas el ticket (total actualizado: %). Revisá el ticket y cobrá de nuevo.', public.caja__plata(v_tot);
  end if;
  if p_medio = 'efectivo' and p_recibido is not null and p_recibido < v_tot then raise exception 'El efectivo recibido es menor que el total.'; end if;
  insert into public.caja_ventas(local, turno_id, usuario, medio, subtotal, descuento, total, recibido, client_id)
  values ('prosegur', t.id, public.caja__quien(u), p_medio, v_sub, v_sub - v_tot, v_tot,
          case when p_medio = 'efectivo' then p_recibido else null end, p_client_id)
  returning id into v_id;
  for l in select * from jsonb_array_elements(lineas) loop
    insert into public.caja_venta_items(venta_id, producto_id, nombre, categoria, tipo, cantidad, precio_lista, precio_unit, descuento_id, descuento_nombre, total, iva)
    values (v_id, (l->>'p')::bigint, l->>'nombre', l->>'categoria', l->>'tipo', (l->>'cant')::int, (l->>'lista')::numeric, (l->>'unit')::numeric,
            nullif(l->>'desc_id', '')::bigint, l->>'desc_nombre', (l->>'total')::numeric, (l->>'iva')::numeric);
    select * into p from public.caja_productos where id = (l->>'p')::bigint;
    if p.control_stock then
      insert into public.caja_stock_mov(local, usuario, producto_id, tipo, cantidad, venta_id) values ('prosegur', public.caja__quien(u), p.id, 'venta', -(l->>'cant')::numeric, v_id);
    end if;
    for r in select * from public.caja_recetas where producto_id = p.id loop
      insert into public.caja_stock_mov(local, usuario, insumo_id, tipo, cantidad, venta_id, motivo)
      values ('prosegur', public.caja__quien(u), r.insumo_id, 'venta', -(r.cantidad * (l->>'cant')::numeric), v_id, p.nombre);
    end loop;
  end loop;
  return json_build_object('id', v_id, 'total', v_tot, 'vuelto', case when p_medio = 'efectivo' and p_recibido is not null then p_recibido - v_tot else null end);
end $$;

-- Ventas del turno abierto (o de un turno dado, para el encargado)
create or replace function public.caja_ventas_turno(p_token text, p_turno bigint default null)
returns json language plpgsql stable security definer set search_path = public as $$
declare u public.panel_usuarios; v_t bigint;
begin
  u := public.caja__permiso(p_token, 'ver');
  v_t := coalesce(p_turno, (public.caja__turno_abierto('prosegur')).id);
  if p_turno is not null and not (u.es_admin or 'prosegur-precios' = any(u.tarjetas)) and p_turno is distinct from (public.caja__turno_abierto('prosegur')).id then
    raise exception 'Tu usuario no tiene permiso para ver ese turno.';
  end if;
  if v_t is null then return '[]'; end if;
  return coalesce((select json_agg(json_build_object('id', v.id, 'fecha', v.fecha, 'usuario', v.usuario, 'medio', v.medio, 'estado', v.estado,
                     'total', v.total, 'descuento', v.descuento, 'anulada_motivo', v.anulada_motivo, 'anulada_por', v.anulada_por,
                     'items', (select json_agg(json_build_object('nombre', i.nombre, 'cantidad', i.cantidad, 'precio_unit', i.precio_unit, 'total', i.total,
                                'descuento_nombre', i.descuento_nombre) order by i.id) from public.caja_venta_items i where i.venta_id = v.id)) order by v.fecha desc)
                   from public.caja_ventas v where v.turno_id = v_t), '[]');
end $$;

create or replace function public.caja_venta_anular(p_token text, p_id bigint, p_motivo text)
returns void language plpgsql security definer set search_path = public as $$
declare u public.panel_usuarios; v public.caja_ventas; m public.caja_stock_mov;
begin
  u := public.caja__permiso(p_token, 'encargado');
  if coalesce(trim(p_motivo), '') = '' then raise exception 'Poné el motivo de la anulación.'; end if;
  select * into v from public.caja_ventas where id = p_id and local = 'prosegur' for update;
  if v.id is null then raise exception 'No encontré la venta.'; end if;
  if v.estado = 'anulada' then raise exception 'La venta ya estaba anulada.'; end if;
  if (select cerrado from public.caja_turnos where id = v.turno_id) is not null then raise exception 'Esa venta es de una caja ya cerrada.'; end if;
  update public.caja_ventas set estado = 'anulada', anulada_por = public.caja__quien(u), anulada_fecha = now(), anulada_motivo = trim(p_motivo) where id = v.id;
  for m in select * from public.caja_stock_mov where venta_id = v.id and tipo = 'venta' loop
    insert into public.caja_stock_mov(local, usuario, producto_id, insumo_id, tipo, cantidad, venta_id, motivo)
    values (m.local, public.caja__quien(u), m.producto_id, m.insumo_id, 'anulacion', -m.cantidad, v.id, 'Anulación venta #' || v.id);
  end loop;
end $$;

-- ---------- configuración ----------
create or replace function public.caja_config_leer(p_token text)
returns json language plpgsql stable security definer set search_path = public as $$
begin
  perform public.caja__permiso(p_token, 'encargado');
  return coalesce((select json_object_agg(clave, valor) from public.caja_config where local = 'prosegur'), '{}');
end $$;

create or replace function public.caja_config_mail(p_token text, p_destinos text[])
returns json language plpgsql security definer set search_path = public as $$
declare d text; limpios text[] := '{}';
begin
  perform public.caja__permiso(p_token, 'admin');
  foreach d in array coalesce(p_destinos, '{}') loop
    d := lower(trim(d));
    if d = '' then continue; end if;
    if d !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' then raise exception 'Mail inválido: %', d; end if;
    if not (d = any(limpios)) then limpios := limpios || d; end if;
  end loop;
  if array_length(limpios, 1) > 10 then raise exception 'Máximo 10 direcciones.'; end if;
  insert into public.caja_config(local, clave, valor) values ('prosegur', 'mail_cierre', to_jsonb(limpios))
  on conflict (local, clave) do update set valor = excluded.valor;
  return to_json(limpios);
end $$;

-- ---------- stock ----------
create or replace function public.caja_stock(p_token text)
returns json language plpgsql stable security definer set search_path = public as $$
declare u public.panel_usuarios;
begin
  u := public.caja__permiso(p_token, 'encargado');
  return json_build_object(
    'productos', coalesce((select json_agg(json_build_object('id', p.id, 'nombre', p.nombre, 'categoria', p.categoria, 'tipo', p.tipo, 'origen', p.origen,
                   'en_caja', p.activo and (p.origen = 'local' or p.en_app), 'del_dia', p.del_dia,
                   'control_stock', p.control_stock, 'stock_minimo', p.stock_minimo, 'stock', coalesce(s.st, 0),
                   'receta', (select json_agg(json_build_object('insumo_id', r.insumo_id, 'cantidad', r.cantidad)) from public.caja_recetas r where r.producto_id = p.id))
                   order by p.tipo, p.categoria, p.nombre)
                 from public.caja_productos p left join (select producto_id, sum(cantidad) st from public.caja_stock_mov group by producto_id) s on s.producto_id = p.id
                 where p.local = 'prosegur'), '[]'),
    'insumos', coalesce((select json_agg(json_build_object('id', i.id, 'nombre', i.nombre, 'unidad', i.unidad, 'stock_minimo', i.stock_minimo, 'activo', i.activo,
                   'stock', coalesce(s.st, 0)) order by i.nombre)
                 from public.caja_insumos i left join (select insumo_id, sum(cantidad) st from public.caja_stock_mov group by insumo_id) s on s.insumo_id = i.id
                 where i.local = 'prosegur'), '[]'),
    'movimientos', coalesce((select json_agg(json_build_object('fecha', m.fecha, 'usuario', m.usuario, 'tipo', m.tipo, 'cantidad', m.cantidad, 'motivo', m.motivo,
                   'venta_id', m.venta_id, 'nombre', coalesce(p.nombre, i.nombre), 'unidad', coalesce(i.unidad, 'u')) order by m.fecha desc, m.id desc)
                 from (select * from public.caja_stock_mov where local = 'prosegur' and tipo <> 'venta' order by fecha desc, id desc limit 300) m
                 left join public.caja_productos p on p.id = m.producto_id left join public.caja_insumos i on i.id = m.insumo_id), '[]'));
end $$;

-- Ingreso de mercadería: [{producto_id | insumo_id, cantidad}]
create or replace function public.caja_stock_ingreso(p_token text, p_items jsonb, p_motivo text default '')
returns json language plpgsql security definer set search_path = public as $$
declare u public.panel_usuarios; it jsonb; n int := 0; v_c numeric;
begin
  u := public.caja__permiso(p_token, 'encargado');
  if jsonb_typeof(p_items) <> 'array' then raise exception 'Nada para cargar.'; end if;
  for it in select * from jsonb_array_elements(p_items) loop
    v_c := nullif(it->>'cantidad', '')::numeric;
    if v_c is null or v_c = 0 then continue; end if;
    if v_c < 0 then raise exception 'Las cantidades de un ingreso tienen que ser positivas (para restar usá un ajuste o merma).'; end if;
    if nullif(it->>'producto_id', '') is not null then
      if not exists (select 1 from public.caja_productos where id = (it->>'producto_id')::bigint and local = 'prosegur') then raise exception 'Producto inexistente.'; end if;
      insert into public.caja_stock_mov(local, usuario, producto_id, tipo, cantidad, motivo) values ('prosegur', public.caja__quien(u), (it->>'producto_id')::bigint, 'ingreso', v_c, coalesce(trim(p_motivo), ''));
      update public.caja_productos set control_stock = true where id = (it->>'producto_id')::bigint and not control_stock;
    elsif nullif(it->>'insumo_id', '') is not null then
      if not exists (select 1 from public.caja_insumos where id = (it->>'insumo_id')::bigint and local = 'prosegur') then raise exception 'Insumo inexistente.'; end if;
      insert into public.caja_stock_mov(local, usuario, insumo_id, tipo, cantidad, motivo) values ('prosegur', public.caja__quien(u), (it->>'insumo_id')::bigint, 'ingreso', v_c, coalesce(trim(p_motivo), ''));
    else continue; end if;
    n := n + 1;
  end loop;
  if n = 0 then raise exception 'No pusiste ninguna cantidad.'; end if;
  return json_build_object('cargados', n);
end $$;

-- Ajuste (conteo real) o merma (se tira/rompe): p_cantidad = stock contado (ajuste) o cantidad perdida (merma)
create or replace function public.caja_stock_ajuste(p_token text, p_producto_id bigint, p_insumo_id bigint, p_tipo text, p_cantidad numeric, p_motivo text)
returns void language plpgsql security definer set search_path = public as $$
declare u public.panel_usuarios; v_actual numeric; v_delta numeric;
begin
  u := public.caja__permiso(p_token, 'encargado');
  if (p_producto_id is null) = (p_insumo_id is null) then raise exception 'Elegí un producto o un insumo.'; end if;
  if p_tipo not in ('ajuste','merma') then raise exception 'Tipo inválido.'; end if;
  if p_cantidad is null or p_cantidad < 0 then raise exception 'Cantidad inválida.'; end if;
  if coalesce(trim(p_motivo), '') = '' and p_tipo = 'merma' then raise exception 'Poné el motivo de la merma.'; end if;
  select coalesce(sum(cantidad), 0) into v_actual from public.caja_stock_mov where (producto_id = p_producto_id or insumo_id = p_insumo_id);
  v_delta := case when p_tipo = 'ajuste' then p_cantidad - v_actual else -p_cantidad end;
  if v_delta = 0 then return; end if;
  insert into public.caja_stock_mov(local, usuario, producto_id, insumo_id, tipo, cantidad, motivo)
  values ('prosegur', public.caja__quien(u), p_producto_id, p_insumo_id, p_tipo, v_delta,
          coalesce(nullif(trim(p_motivo), ''), case when p_tipo = 'ajuste' then 'Conteo: había ' || trim_scale(v_actual)::text else '' end));
  if p_producto_id is not null then update public.caja_productos set control_stock = true where id = p_producto_id and not control_stock; end if;
end $$;

create or replace function public.caja_stock_config(p_token text, p_producto_id bigint, p_control boolean, p_minimo numeric)
returns void language plpgsql security definer set search_path = public as $$
begin
  perform public.caja__permiso(p_token, 'admin');
  if coalesce(p_minimo, 0) < 0 then raise exception 'El mínimo no puede ser negativo.'; end if;
  update public.caja_productos set control_stock = coalesce(p_control, control_stock), stock_minimo = coalesce(p_minimo, stock_minimo), actualizado = now()
  where id = p_producto_id and local = 'prosegur';
end $$;

create or replace function public.caja_insumo_guardar(p_token text, p_id bigint, p_nombre text, p_unidad text, p_minimo numeric, p_activo boolean default true)
returns json language plpgsql security definer set search_path = public as $$
declare i public.caja_insumos;
begin
  perform public.caja__permiso(p_token, 'admin');
  if coalesce(trim(p_nombre), '') = '' then raise exception 'Falta el nombre del insumo.'; end if;
  if p_unidad not in ('g','ml','u') then raise exception 'Unidad inválida (g, ml o u).'; end if;
  if p_id is null then
    insert into public.caja_insumos(local, nombre, unidad, stock_minimo, activo) values ('prosegur', trim(p_nombre), p_unidad, coalesce(p_minimo, 0), coalesce(p_activo, true)) returning * into i;
  else
    update public.caja_insumos set nombre = trim(p_nombre), unidad = p_unidad, stock_minimo = coalesce(p_minimo, 0), activo = coalesce(p_activo, true)
    where id = p_id and local = 'prosegur' returning * into i;
    if i.id is null then raise exception 'No encontré el insumo.'; end if;
  end if;
  return row_to_json(i);
end $$;

-- Receta de un producto: [{insumo_id, cantidad}] (reemplaza la anterior; lista vacía = sin receta)
create or replace function public.caja_receta_guardar(p_token text, p_producto_id bigint, p_items jsonb)
returns void language plpgsql security definer set search_path = public as $$
declare it jsonb;
begin
  perform public.caja__permiso(p_token, 'admin');
  if not exists (select 1 from public.caja_productos where id = p_producto_id and local = 'prosegur') then raise exception 'No encontré el producto.'; end if;
  delete from public.caja_recetas where producto_id = p_producto_id;
  for it in select * from jsonb_array_elements(coalesce(p_items, '[]')) loop
    if coalesce(nullif(it->>'cantidad', '')::numeric, 0) <= 0 then continue; end if;
    insert into public.caja_recetas(producto_id, insumo_id, cantidad) values (p_producto_id, (it->>'insumo_id')::bigint, (it->>'cantidad')::numeric);
  end loop;
end $$;

-- ---------- retiro de pedidos de la app ----------
create table if not exists public.caja_retiros (
  id            bigint generated always as identity primary key,
  local         text not null default 'prosegur',
  fecha         date not null,
  id_usuario    text not null,              -- usuario de la app de pedidos
  nombre        text not null default '',
  detalle       text not null default '',   -- qué se llevó (plato, postre, bebida)
  entregado     timestamptz not null default now(),
  entregado_por text not null default '',
  unique (local, fecha, id_usuario)
);
alter table public.caja_retiros enable row level security;
revoke all on public.caja_retiros from anon, authenticated;

create or replace function public.caja_retiros_dia(p_token text, p_fecha date)
returns json language plpgsql stable security definer set search_path = public as $$
begin
  perform public.caja__permiso(p_token, 'ver');
  return coalesce((select json_agg(json_build_object('id_usuario', id_usuario, 'nombre', nombre, 'entregado', entregado, 'entregado_por', entregado_por) order by entregado)
                   from public.caja_retiros where local = 'prosegur' and fecha = p_fecha), '[]');
end $$;

-- Marca la entrega. Si esa persona ya retiró ese día, no deja entregar de nuevo.
create or replace function public.caja_retiro_marcar(p_token text, p_fecha date, p_id_usuario text, p_nombre text, p_detalle text)
returns json language plpgsql security definer set search_path = public as $$
declare u public.panel_usuarios; r public.caja_retiros;
begin
  u := public.caja__permiso(p_token, 'ver');
  if coalesce(trim(p_id_usuario), '') = '' or p_fecha is null then raise exception 'Faltan datos del pedido.'; end if;
  select * into r from public.caja_retiros where local = 'prosegur' and fecha = p_fecha and id_usuario = trim(p_id_usuario);
  if r.id is not null then
    raise exception 'YA RETIRÓ: % se llevó su pedido a las % (entregó %).', r.nombre,
      to_char(r.entregado at time zone 'America/Argentina/Buenos_Aires', 'HH24:MI'), r.entregado_por;
  end if;
  insert into public.caja_retiros(local, fecha, id_usuario, nombre, detalle, entregado_por)
  values ('prosegur', p_fecha, trim(p_id_usuario), left(coalesce(p_nombre, ''), 120), left(coalesce(p_detalle, ''), 400), public.caja__quien(u))
  returning * into r;
  return json_build_object('entregado', r.entregado, 'entregado_por', r.entregado_por);
end $$;

-- Deshacer una entrega marcada por error (encargado)
create or replace function public.caja_retiro_deshacer(p_token text, p_fecha date, p_id_usuario text)
returns void language plpgsql security definer set search_path = public as $$
begin
  perform public.caja__permiso(p_token, 'encargado');
  delete from public.caja_retiros where local = 'prosegur' and fecha = p_fecha and id_usuario = trim(p_id_usuario);
end $$;

-- ---------- permisos ----------
revoke all on function public.caja__quien(public.panel_usuarios) from public, anon, authenticated;
revoke all on function public.caja__precio(public.caja_productos, timestamptz) from public, anon, authenticated;
revoke all on function public.caja__turno_abierto(text) from public, anon, authenticated;
revoke all on function public.caja__resumen(bigint) from public, anon, authenticated;
revoke all on function public.caja__stock_bajo(text) from public, anon, authenticated;
grant execute on function public.caja_turno_estado(text) to anon, authenticated;
grant execute on function public.caja_turno_abrir(text, numeric) to anon, authenticated;
grant execute on function public.caja_movimiento(text, text, numeric, text) to anon, authenticated;
grant execute on function public.caja_turno_cerrar(text, numeric, text) to anon, authenticated;
grant execute on function public.caja_turno_resumen(text, bigint) to anon, authenticated;
grant execute on function public.caja_turno_mail_registrar(text, bigint, text, text[]) to anon, authenticated;
grant execute on function public.caja_turnos_listar(text, int) to anon, authenticated;
grant execute on function public.caja_venta_registrar(text, jsonb, text, numeric, numeric, text) to anon, authenticated;
grant execute on function public.caja_ventas_turno(text, bigint) to anon, authenticated;
grant execute on function public.caja_venta_anular(text, bigint, text) to anon, authenticated;
grant execute on function public.caja_config_leer(text) to anon, authenticated;
grant execute on function public.caja_config_mail(text, text[]) to anon, authenticated;
grant execute on function public.caja_stock(text) to anon, authenticated;
grant execute on function public.caja_stock_ingreso(text, jsonb, text) to anon, authenticated;
grant execute on function public.caja_stock_ajuste(text, bigint, bigint, text, numeric, text) to anon, authenticated;
grant execute on function public.caja_stock_config(text, bigint, boolean, numeric) to anon, authenticated;
grant execute on function public.caja_insumo_guardar(text, bigint, text, text, numeric, boolean) to anon, authenticated;
grant execute on function public.caja_receta_guardar(text, bigint, jsonb) to anon, authenticated;
grant execute on function public.caja_retiros_dia(text, date) to anon, authenticated;
grant execute on function public.caja_retiro_marcar(text, date, text, text, text) to anon, authenticated;
grant execute on function public.caja_retiro_deshacer(text, date, text) to anon, authenticated;

notify pgrst, 'reload schema';
