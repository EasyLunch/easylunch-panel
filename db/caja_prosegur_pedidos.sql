-- =====================================================================
-- EASY LUNCH · Local Prosegur — proveedores y pedidos de reposición
-- Correr en Supabase → SQL Editor → Run, DESPUÉS de caja_prosegur.sql y caja_prosegur_ventas.sql.
-- Se puede volver a correr sin romper nada (no borra datos).
--
-- Circuito: el local pide (tablet de la caja) → al proveedor le llega el pedido por mail
--           → el local recibe el envío, confirma lo que llegó y el stock suma solo.
--
-- Proveedores: cada uno con sus mails, días de entrega y horario de corte. "Easy Lunch" es especial:
--   * Platos calientes del día siguiente: se piden hasta las 13 h. La caja sugiere la cantidad por plato
--     con el promedio vendido ese mismo día de la semana (últimas 4 semanas); sin historial usa la cantidad
--     base por día que se define en Configuración. Si a la hora de corte nadie lo mandó, sale solo (cron).
--   * El resto (viandas frías, descartables, condimentos…) hasta la hora de corte del proveedor.
-- Los demás proveedores: cada producto/insumo tiene stock mínimo e ideal; el pedido sugerido lleva
-- lo que está por debajo del ideal.
--
-- Permisos: pedir y recibir → cualquier usuario de la caja · asignar proveedor / mínimos → encargado
--           · proveedores y configuración → administrador.
-- =====================================================================

-- ---------- proveedores ----------
create table if not exists public.caja_proveedores (
  id          bigint generated always as identity primary key,
  local       text not null default 'prosegur',
  nombre      text not null,
  tipo        text not null default 'mail' check (tipo in ('mail','easylunch')),
  mails       text[] not null default '{}',
  dias        int[] not null default '{1,2,3,4,5}',   -- días de entrega (1 = lunes … 7 = domingo)
  hora_corte  text not null default '15:00',          -- hasta qué hora se le pide para la próxima entrega
  activo      boolean not null default true,
  nota        text not null default '',
  creado      timestamptz not null default now()
);
create unique index if not exists caja_proveedores_nombre on public.caja_proveedores (local, lower(nombre));

-- ---------- columnas nuevas en productos e insumos ----------
alter table public.caja_productos add column if not exists proveedor_id bigint references public.caja_proveedores(id) on delete set null;
alter table public.caja_productos add column if not exists stock_ideal numeric(12,3) not null default 0;
alter table public.caja_productos add column if not exists sobrante boolean not null default false;   -- plato del día anterior que sigue a la venta
alter table public.caja_insumos add column if not exists proveedor_id bigint references public.caja_proveedores(id) on delete set null;
alter table public.caja_insumos add column if not exists stock_ideal numeric(12,3) not null default 0;
alter table public.caja_insumos add column if not exists categoria text not null default 'Insumos';
alter table public.caja_insumos add column if not exists presentacion text not null default '';      -- ej. "Caja x 1000"
alter table public.caja_insumos add column if not exists factor numeric(12,3) not null default 1;      -- unidades de stock por presentación
alter table public.caja_insumos add column if not exists orden int not null default 0;

-- ---------- pedidos ----------
create table if not exists public.caja_pedidos (
  id             bigint generated always as identity primary key,
  local          text not null default 'prosegur',
  proveedor_id   bigint not null references public.caja_proveedores(id),
  parte          text not null default 'general' check (parte in ('general','platos')),
  fecha_entrega  date not null,
  fecha          timestamptz not null default now(),
  usuario        text not null default '',
  origen         text not null default 'manual' check (origen in ('manual','automatico')),
  estado         text not null default 'enviado' check (estado in ('enviado','recibido','cancelado')),
  nota           text not null default '',
  mail_estado    text not null default 'pendiente',   -- pendiente | enviado | error | sin_mail
  mail_detalle   text not null default '',
  recibido_por   text,
  recibido_fecha timestamptz,
  recibido_nota  text not null default ''
);
alter table public.caja_pedidos add column if not exists editado timestamptz;
create index if not exists caja_pedidos_fecha on public.caja_pedidos (local, fecha desc);

create table if not exists public.caja_pedido_items (
  id           bigint generated always as identity primary key,
  pedido_id    bigint not null references public.caja_pedidos(id) on delete cascade,
  producto_id  bigint references public.caja_productos(id),
  insumo_id    bigint references public.caja_insumos(id),
  ref_app      text,                 -- platos del día siguiente que todavía no están en la caja
  nombre       text not null,
  unidad       text not null default 'u',
  factor       numeric(12,3) not null default 1,
  cantidad     numeric(12,3) not null check (cantidad > 0),
  recibido     numeric(12,3)
);
create index if not exists caja_pedido_items_pedido on public.caja_pedido_items (pedido_id);
alter table public.caja_pedido_items add column if not exists grupo text not null default '';   -- módulo de la app (categoría de la planilla de Biel)

alter table public.caja_proveedores enable row level security;
alter table public.caja_pedidos enable row level security;
alter table public.caja_pedido_items enable row level security;

-- ---------- datos iniciales (solo si no existen) ----------
insert into public.caja_proveedores(local, nombre, tipo, mails, dias, hora_corte, nota)
select 'prosegur', 'Easy Lunch', 'easylunch', '{info@easylunch.com.ar}', '{1,2,3,4,5}', '15:00', 'Envío diario desde Biel.'
where not exists (select 1 from public.caja_proveedores where local = 'prosegur' and tipo = 'easylunch');
insert into public.caja_proveedores(local, nombre, tipo, mails, dias, hora_corte, nota)
select 'prosegur', 'Anabella', 'mail', '{anabella@example.com}', '{2,5}', '15:00', 'Postres y dulces. Mail de ejemplo: cambiarlo por el real.'
where not exists (select 1 from public.caja_proveedores where local = 'prosegur' and lower(nombre) = 'anabella');

insert into public.caja_config(local, clave, valor)
values ('prosegur', 'pedidos', '{"plato_base":{"1":15,"2":15,"3":15,"4":15,"5":15,"6":0,"7":0},"hora_platos":"13:00","auto_platos":true}')
on conflict (local, clave) do nothing;

-- productos de la app sin proveedor → Easy Lunch (los postres → Anabella)
update public.caja_productos p set proveedor_id = (select id from public.caja_proveedores where local = 'prosegur' and lower(nombre) = 'anabella')
where p.local = 'prosegur' and p.proveedor_id is null and p.tipo = 'postre';
update public.caja_productos p set proveedor_id = (select id from public.caja_proveedores where local = 'prosegur' and tipo = 'easylunch')
where p.local = 'prosegur' and p.proveedor_id is null and p.origen = 'app';

-- descartables y condimentos de ejemplo (se editan o borran desde Configuración → Proveedores y pedidos)
insert into public.caja_insumos(local, nombre, unidad, categoria, presentacion, factor, stock_minimo, stock_ideal, proveedor_id, orden)
select 'prosegur', x.nombre, 'u', x.cat, x.pres, x.factor, x.minimo, x.ideal,
       (select id from public.caja_proveedores where local = 'prosegur' and tipo = 'easylunch'), x.ord
from (values
  ('Vasos de café 8 oz',        'Descartables', 'Paquete x 50',  50, 100, 300, 1),
  ('Tapas para vaso de café',   'Descartables', 'Paquete x 50',  50, 100, 300, 2),
  ('Revolvedores',              'Descartables', 'Caja x 500',   500, 200, 500, 3),
  ('Cubiertos descartables (kit)', 'Descartables', 'Caja x 100', 100, 100, 300, 4),
  ('Servilletas',               'Descartables', 'Paquete x 100', 100, 200, 600, 5),
  ('Bolsas',                    'Descartables', 'Paquete x 100', 100, 100, 300, 6),
  ('Sobres de azúcar',          'Condimentos',  'Caja x 800',   800, 200, 800, 10),
  ('Sobres de edulcorante',     'Condimentos',  'Caja x 400',   400, 100, 400, 11),
  ('Sobres de sal',             'Condimentos',  'Caja x 500',   500, 100, 500, 12),
  ('Sobres de mayonesa',        'Condimentos',  'Caja x 200',   200, 50,  200, 13),
  ('Sobres de ketchup',         'Condimentos',  'Caja x 200',   200, 50,  200, 14),
  ('Sobres de mostaza',         'Condimentos',  'Caja x 200',   200, 50,  200, 15)
) as x(nombre, cat, pres, factor, minimo, ideal, ord)
where not exists (select 1 from public.caja_insumos i where i.local = 'prosegur' and lower(i.nombre) = lower(x.nombre));

-- ---------- helpers ----------
-- Próxima fecha de entrega de un proveedor (la primera de sus días después de hoy).
create or replace function public.caja__proxima_entrega(p_dias int[], p_desde date default null)
returns date language plpgsql stable as $$
declare d date := coalesce(p_desde, (now() at time zone 'America/Argentina/Buenos_Aires')::date); i int;
begin
  if p_dias is null or cardinality(p_dias) = 0 then return d + 1; end if;
  for i in 1..14 loop
    if extract(isodow from d + i)::int = any(p_dias) then return d + i; end if;
  end loop;
  return d + 1;
end $$;

-- Cantidad sugerida POR PLATO caliente para una fecha: promedio vendido por plato ese día de la semana
-- (últimas 4 veces con ventas). Con menos de 2 días de historial usa la cantidad base de Configuración.
create or replace function public.caja__estimado_plato(p_fecha date)
returns json language plpgsql stable security definer set search_path = public as $$
declare v_dow int := extract(isodow from p_fecha)::int; v_dias int; v_prom numeric; v_base numeric; v_cfg jsonb;
begin
  select valor into v_cfg from public.caja_config where local = 'prosegur' and clave = 'pedidos';
  v_base := coalesce(nullif(v_cfg->'plato_base'->>(v_dow::text), '')::numeric, 15);
  select count(*), avg(tot / greatest(n, 1)) into v_dias, v_prom from (
    select (v.fecha at time zone 'America/Argentina/Buenos_Aires')::date dia, sum(i.cantidad)::numeric tot,
           count(distinct coalesce(i.producto_id::text, i.nombre)) n
    from public.caja_venta_items i join public.caja_ventas v on v.id = i.venta_id
    where v.local = 'prosegur' and v.estado = 'pagada' and i.tipo = 'vianda' and i.categoria = 'Plato del día'
      and extract(isodow from (v.fecha at time zone 'America/Argentina/Buenos_Aires'))::int = v_dow
      and v.fecha > now() - interval '60 days'
    group by 1 order by 1 desc limit 4) h;
  if coalesce(v_dias, 0) >= 2 then
    return json_build_object('por_plato', ceil(v_prom), 'fuente', 'historial', 'dias', v_dias, 'base', v_base);
  end if;
  return json_build_object('por_plato', v_base, 'fuente', 'base', 'dias', coalesce(v_dias, 0), 'base', v_base);
end $$;

-- Carga los ítems de un pedido (borra los que tenía). p_items: [{producto_id | insumo_id | ref_app, nombre?, grupo?, cantidad}]
create or replace function public.caja__pedido_items_cargar(v_id bigint, p_items jsonb)
returns int language plpgsql security definer set search_path = public as $$
declare it jsonb; v_c numeric; pr public.caja_productos; ins public.caja_insumos; n int := 0;
begin
  if jsonb_typeof(p_items) <> 'array' then raise exception 'El pedido está vacío.'; end if;
  delete from public.caja_pedido_items where pedido_id = v_id;
  for it in select * from jsonb_array_elements(p_items) loop
    v_c := nullif(it->>'cantidad', '')::numeric;
    if v_c is null or v_c <= 0 then continue; end if;
    if nullif(it->>'producto_id', '') is not null then
      select * into pr from public.caja_productos where id = (it->>'producto_id')::bigint and local = 'prosegur';
      if pr.id is null then raise exception 'Producto inexistente.'; end if;
      insert into public.caja_pedido_items(pedido_id, producto_id, ref_app, nombre, unidad, factor, cantidad, grupo)
      values (v_id, pr.id, pr.ref_app, pr.nombre, 'u', 1, v_c, coalesce(nullif(pr.grupo, ''), pr.categoria, ''));
    elsif nullif(it->>'insumo_id', '') is not null then
      select * into ins from public.caja_insumos where id = (it->>'insumo_id')::bigint and local = 'prosegur';
      if ins.id is null then raise exception 'Insumo inexistente.'; end if;
      insert into public.caja_pedido_items(pedido_id, insumo_id, nombre, unidad, factor, cantidad, grupo)
      values (v_id, ins.id, ins.nombre, coalesce(nullif(ins.presentacion, ''), ins.unidad), greatest(ins.factor, 0.001), v_c, ins.categoria);
    elsif nullif(it->>'ref_app', '') is not null and coalesce(trim(it->>'nombre'), '') <> '' then
      insert into public.caja_pedido_items(pedido_id, producto_id, ref_app, nombre, unidad, factor, cantidad, grupo)
      values (v_id, (select id from public.caja_productos where local = 'prosegur' and ref_app = it->>'ref_app'), it->>'ref_app', trim(it->>'nombre'), 'u', 1, v_c,
              coalesce(nullif(trim(it->>'grupo'), ''), 'Plato del día'));
    else
      continue;
    end if;
    n := n + 1;
  end loop;
  if n = 0 then raise exception 'El pedido está vacío: poné al menos una cantidad.'; end if;
  return n;
end $$;

-- Arma un pedido. p_items: [{producto_id | insumo_id | ref_app, nombre?, grupo?, cantidad}]
create or replace function public.caja__pedido_insertar(p_usuario text, p_origen text, p_proveedor bigint, p_parte text,
  p_fecha_entrega date, p_items jsonb, p_nota text)
returns bigint language plpgsql security definer set search_path = public as $$
declare v_id bigint; v_prov public.caja_proveedores;
begin
  select * into v_prov from public.caja_proveedores where id = p_proveedor and local = 'prosegur';
  if v_prov.id is null then raise exception 'Proveedor inexistente.'; end if;
  if coalesce(p_parte, 'general') not in ('general','platos') then raise exception 'Tipo de pedido inválido.'; end if;
  if p_parte = 'platos' and v_prov.tipo <> 'easylunch' then raise exception 'Los platos calientes se piden a Easy Lunch.'; end if;
  insert into public.caja_pedidos(local, proveedor_id, parte, fecha_entrega, usuario, origen, nota)
  values ('prosegur', p_proveedor, coalesce(p_parte, 'general'), p_fecha_entrega, coalesce(p_usuario, ''), p_origen, coalesce(trim(p_nota), ''))
  returning id into v_id;
  perform public.caja__pedido_items_cargar(v_id, p_items);
  return v_id;
end $$;

-- Hasta cuándo el cajero puede cambiar o cancelar un pedido: la hora de corte del proveedor del último día hábil
-- anterior a la entrega (para los platos calientes, la hora de corte de platos). Después, solo el encargado.
create or replace function public.caja__pedido_limite(p_id bigint)
returns timestamptz language plpgsql stable security definer set search_path = public as $$
declare p public.caja_pedidos; v public.caja_proveedores; d date; v_hora text; v_cfg jsonb;
begin
  select * into p from public.caja_pedidos where id = p_id;
  select * into v from public.caja_proveedores where id = p.proveedor_id;
  select valor into v_cfg from public.caja_config where local = 'prosegur' and clave = 'pedidos';
  v_hora := case when p.parte = 'platos' then coalesce(v_cfg->>'hora_platos', '13:00') else coalesce(v.hora_corte, '15:00') end;
  d := p.fecha_entrega - 1;
  while extract(isodow from d) in (6, 7) loop d := d - 1; end loop;
  return ((d::text || ' ' || v_hora)::timestamp) at time zone 'America/Argentina/Buenos_Aires';
end $$;

create or replace function public.caja__pedido_json(p_id bigint)
returns json language sql stable security definer set search_path = public as $$
  select json_build_object('id', p.id, 'proveedor_id', p.proveedor_id, 'proveedor', pv.nombre, 'proveedor_tipo', pv.tipo, 'mails', pv.mails,
    'parte', p.parte, 'fecha_entrega', p.fecha_entrega, 'fecha', p.fecha, 'usuario', p.usuario, 'origen', p.origen, 'estado', p.estado,
    'nota', p.nota, 'mail_estado', p.mail_estado, 'mail_detalle', p.mail_detalle, 'recibido_por', p.recibido_por,
    'recibido_fecha', p.recibido_fecha, 'recibido_nota', p.recibido_nota, 'limite', public.caja__pedido_limite(p.id), 'editado', p.editado,
    'items', coalesce((select json_agg(json_build_object('id', i.id, 'producto_id', i.producto_id, 'insumo_id', i.insumo_id, 'ref_app', i.ref_app,
               'nombre', i.nombre, 'unidad', i.unidad, 'factor', i.factor, 'cantidad', i.cantidad, 'recibido', i.recibido) order by i.id)
             from public.caja_pedido_items i where i.pedido_id = p.id), '[]'))
  from public.caja_pedidos p join public.caja_proveedores pv on pv.id = p.proveedor_id where p.id = p_id;
$$;

-- ---------- lectura (pantalla de pedidos de la caja y de Configuración) ----------
create or replace function public.caja_pedidos_datos(p_token text)
returns json language plpgsql stable security definer set search_path = public as $$
declare u public.panel_usuarios; v_hoy date := (now() at time zone 'America/Argentina/Buenos_Aires')::date; v_cfg jsonb; v_el public.caja_proveedores;
begin
  u := public.caja__permiso(p_token, 'ver');
  select valor into v_cfg from public.caja_config where local = 'prosegur' and clave = 'pedidos';
  select * into v_el from public.caja_proveedores where local = 'prosegur' and tipo = 'easylunch' and activo order by id limit 1;
  return json_build_object(
    'hoy', v_hoy,
    'config', coalesce(v_cfg, '{}'::jsonb),
    'proveedores', coalesce((select json_agg(json_build_object('id', p.id, 'nombre', p.nombre, 'tipo', p.tipo, 'mails', p.mails, 'dias', p.dias,
        'hora_corte', p.hora_corte, 'activo', p.activo, 'nota', p.nota, 'proxima_entrega', public.caja__proxima_entrega(p.dias)) order by (p.tipo = 'easylunch') desc, p.nombre)
      from public.caja_proveedores p where p.local = 'prosegur'), '[]'),
    'productos', coalesce((select json_agg(json_build_object('id', p.id, 'nombre', p.nombre, 'categoria', p.categoria, 'tipo', p.tipo, 'origen', p.origen,
        'del_dia', p.del_dia, 'sobrante', p.sobrante, 'en_caja', p.activo and (p.origen = 'local' or p.en_app), 'proveedor_id', p.proveedor_id,
        'control_stock', p.control_stock, 'stock_minimo', p.stock_minimo, 'stock_ideal', p.stock_ideal, 'stock', coalesce(s.st, 0)) order by p.categoria, p.nombre)
      from public.caja_productos p left join (select producto_id, sum(cantidad) st from public.caja_stock_mov group by producto_id) s on s.producto_id = p.id
      where p.local = 'prosegur' and p.activo and (p.origen = 'local' or p.en_app)), '[]'),
    'insumos', coalesce((select json_agg(json_build_object('id', i.id, 'nombre', i.nombre, 'unidad', i.unidad, 'categoria', i.categoria,
        'presentacion', i.presentacion, 'factor', i.factor, 'proveedor_id', i.proveedor_id, 'stock_minimo', i.stock_minimo,
        'stock_ideal', i.stock_ideal, 'activo', i.activo, 'stock', coalesce(s.st, 0)) order by i.categoria, i.orden, i.nombre)
      from public.caja_insumos i left join (select insumo_id, sum(cantidad) st from public.caja_stock_mov group by insumo_id) s on s.insumo_id = i.id
      where i.local = 'prosegur'), '[]'),
    'platos_estimado', case when v_el.id is null then null else public.caja__estimado_plato(public.caja__proxima_entrega(v_el.dias)) end,
    'pedidos', coalesce((select json_agg(public.caja__pedido_json(x.id) order by x.fecha desc)
      from (select id, fecha from public.caja_pedidos where local = 'prosegur' and (estado = 'enviado' or fecha > now() - interval '21 days')
            order by fecha desc limit 80) x), '[]'));
end $$;

-- ---------- pedir ----------
create or replace function public.caja_pedido_crear(p_token text, p_proveedor bigint, p_parte text, p_fecha_entrega date, p_items jsonb, p_nota text default '')
returns json language plpgsql security definer set search_path = public as $$
declare u public.panel_usuarios; v_id bigint;
begin
  u := public.caja__permiso(p_token, 'ver');
  if p_fecha_entrega is null or p_fecha_entrega < (now() at time zone 'America/Argentina/Buenos_Aires')::date then
    raise exception 'Elegí una fecha de entrega válida.';
  end if;
  v_id := public.caja__pedido_insertar(public.caja__quien(u), 'manual', p_proveedor, p_parte, p_fecha_entrega, p_items, p_nota);
  return public.caja__pedido_json(v_id);
end $$;

create or replace function public.caja_pedido_mail_registrar(p_token text, p_id bigint, p_estado text, p_detalle text)
returns void language plpgsql security definer set search_path = public as $$
begin
  perform public.caja__permiso(p_token, 'ver');
  update public.caja_pedidos set mail_estado = left(coalesce(p_estado, ''), 20), mail_detalle = left(coalesce(p_detalle, ''), 500)
  where id = p_id and local = 'prosegur';
end $$;

create or replace function public.caja__pedido_puede_cambiar(p_token text, p_id bigint)
returns public.panel_usuarios language plpgsql security definer set search_path = public as $$
declare u public.panel_usuarios; p public.caja_pedidos;
begin
  u := public.caja__permiso(p_token, 'ver');
  select * into p from public.caja_pedidos where id = p_id and local = 'prosegur';
  if p.id is null then raise exception 'No encontré el pedido.'; end if;
  if p.estado <> 'enviado' then raise exception 'Ese pedido ya fue recibido o cancelado.'; end if;
  if now() > public.caja__pedido_limite(p.id) then
    begin
      u := public.caja__permiso(p_token, 'encargado');
    exception when others then
      raise exception 'Ya pasó la hora de corte: solo el encargado puede cambiarlo o cancelarlo (y avisarle al proveedor).';
    end;
  end if;
  return u;
end $$;

create or replace function public.caja_pedido_cancelar(p_token text, p_id bigint)
returns json language plpgsql security definer set search_path = public as $$
declare u public.panel_usuarios;
begin
  u := public.caja__pedido_puede_cambiar(p_token, p_id);
  update public.caja_pedidos set estado = 'cancelado', recibido_nota = 'Cancelado por ' || public.caja__quien(u)
  where id = p_id and local = 'prosegur' and estado = 'enviado';
  if not found then raise exception 'Ese pedido ya no está pendiente.'; end if;
  return public.caja__pedido_json(p_id);
end $$;

-- Editar un pedido todavía no recibido: reemplaza los ítems y la nota.
create or replace function public.caja_pedido_editar(p_token text, p_id bigint, p_items jsonb, p_nota text default '')
returns json language plpgsql security definer set search_path = public as $$
declare u public.panel_usuarios;
begin
  u := public.caja__pedido_puede_cambiar(p_token, p_id);
  perform public.caja__pedido_items_cargar(p_id, p_items);
  update public.caja_pedidos set nota = coalesce(trim(p_nota), ''), editado = now(),
         recibido_nota = left(trim(recibido_nota || ' Modificado por ' || public.caja__quien(u) || ' el ' ||
           to_char(now() at time zone 'America/Argentina/Buenos_Aires', 'DD/MM HH24:MI') || '.'), 500)
  where id = p_id;
  return public.caja__pedido_json(p_id);
end $$;

-- Recibir: p_items [{id (ítem del pedido), recibido}] — lo recibido entra al stock (presentaciones × factor).
create or replace function public.caja_pedido_recibir(p_token text, p_id bigint, p_items jsonb, p_nota text default '')
returns json language plpgsql security definer set search_path = public as $$
declare u public.panel_usuarios; p public.caja_pedidos; it public.caja_pedido_items; v_r numeric; v_prod bigint; v_motivo text; sin_prod text[] := '{}';
begin
  u := public.caja__permiso(p_token, 'ver');
  select * into p from public.caja_pedidos where id = p_id and local = 'prosegur' for update;
  if p.id is null then raise exception 'No encontré el pedido.'; end if;
  if p.estado <> 'enviado' then raise exception 'Ese pedido ya fue recibido o cancelado.'; end if;
  v_motivo := 'Pedido #' || p.id || ' (' || (select nombre from public.caja_proveedores where id = p.proveedor_id) || ')';
  for it in select * from public.caja_pedido_items where pedido_id = p.id loop
    select nullif(x->>'recibido', '')::numeric into v_r from jsonb_array_elements(coalesce(p_items, '[]')) x where (x->>'id')::bigint = it.id limit 1;
    v_r := greatest(coalesce(v_r, it.cantidad), 0);
    update public.caja_pedido_items set recibido = v_r where id = it.id;
    if v_r = 0 then continue; end if;
    if it.insumo_id is not null then
      insert into public.caja_stock_mov(local, usuario, insumo_id, tipo, cantidad, motivo)
      values ('prosegur', public.caja__quien(u), it.insumo_id, 'ingreso', v_r * it.factor, v_motivo);
    else
      v_prod := coalesce(it.producto_id, (select id from public.caja_productos where local = 'prosegur' and ref_app = it.ref_app));
      if v_prod is null then sin_prod := sin_prod || it.nombre; continue; end if;
      update public.caja_pedido_items set producto_id = v_prod where id = it.id and producto_id is null;
      insert into public.caja_stock_mov(local, usuario, producto_id, tipo, cantidad, motivo)
      values ('prosegur', public.caja__quien(u), v_prod, 'ingreso', v_r, v_motivo);
      update public.caja_productos set control_stock = true where id = v_prod and not control_stock;
    end if;
  end loop;
  update public.caja_pedidos set estado = 'recibido', recibido_por = public.caja__quien(u), recibido_fecha = now(),
         recibido_nota = coalesce(trim(p_nota), '') where id = p.id;
  return json_build_object('pedido', public.caja__pedido_json(p.id), 'sin_producto', sin_prod);
end $$;

-- ---------- configuración ----------
-- Proveedor: {nombre, tipo, mails: [..], dias: [1..7], hora_corte 'HH:MM', activo, nota}
create or replace function public.caja_proveedor_guardar(p_token text, p_id bigint, p_datos jsonb)
returns json language plpgsql security definer set search_path = public as $$
declare u public.panel_usuarios; v public.caja_proveedores; v_mails text[]; v_dias int[]; v_hora text;
begin
  u := public.caja__permiso(p_token, 'admin');
  if coalesce(trim(p_datos->>'nombre'), '') = '' then raise exception 'Falta el nombre del proveedor.'; end if;
  select coalesce(array_agg(lower(trim(m))), '{}') into v_mails from jsonb_array_elements_text(coalesce(p_datos->'mails', '[]')) m where trim(m) <> '';
  if exists (select 1 from unnest(v_mails) m where m !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$') then raise exception 'Hay un mail mal escrito.'; end if;
  select coalesce(array_agg(distinct d::int order by d::int), '{}') into v_dias from jsonb_array_elements_text(coalesce(p_datos->'dias', '[]')) d where d ~ '^[1-7]$';
  if cardinality(v_dias) = 0 then raise exception 'Marcá al menos un día de entrega.'; end if;
  v_hora := coalesce(nullif(trim(p_datos->>'hora_corte'), ''), '15:00');
  if v_hora !~ '^([01][0-9]|2[0-3]):[0-5][0-9]$' then raise exception 'Hora de corte inválida (formato 15:00).'; end if;
  if p_id is null then
    insert into public.caja_proveedores(local, nombre, tipo, mails, dias, hora_corte, activo, nota)
    values ('prosegur', trim(p_datos->>'nombre'), case when p_datos->>'tipo' = 'easylunch' then 'easylunch' else 'mail' end,
            v_mails, v_dias, v_hora, coalesce((p_datos->>'activo')::boolean, true), coalesce(trim(p_datos->>'nota'), ''))
    returning * into v;
  else
    update public.caja_proveedores set nombre = trim(p_datos->>'nombre'), mails = v_mails, dias = v_dias, hora_corte = v_hora,
           activo = coalesce((p_datos->>'activo')::boolean, true), nota = coalesce(trim(p_datos->>'nota'), '')
    where id = p_id and local = 'prosegur' returning * into v;
    if v.id is null then raise exception 'No encontré el proveedor.'; end if;
  end if;
  return row_to_json(v);
exception when unique_violation then raise exception 'Ya hay un proveedor con ese nombre.';
end $$;

-- {plato_base: {"1":15,…}, hora_platos: '13:00', auto_platos: true}
create or replace function public.caja_pedidos_config_guardar(p_token text, p_datos jsonb)
returns json language plpgsql security definer set search_path = public as $$
declare u public.panel_usuarios; v jsonb; v_base jsonb := '{}'; d int; v_hora text;
begin
  u := public.caja__permiso(p_token, 'admin');
  for d in 1..7 loop
    v_base := v_base || jsonb_build_object(d::text, greatest(0, round(coalesce(nullif(p_datos->'plato_base'->>(d::text), '')::numeric, 0))));
  end loop;
  v_hora := coalesce(nullif(trim(p_datos->>'hora_platos'), ''), '13:00');
  if v_hora !~ '^([01][0-9]|2[0-3]):[0-5][0-9]$' then raise exception 'Hora inválida (formato 13:00).'; end if;
  v := jsonb_build_object('plato_base', v_base, 'hora_platos', v_hora, 'auto_platos', coalesce((p_datos->>'auto_platos')::boolean, true));
  insert into public.caja_config(local, clave, valor) values ('prosegur', 'pedidos', v)
  on conflict (local, clave) do update set valor = excluded.valor;
  return v;
end $$;

-- Proveedor y stock mínimo/ideal de un producto o insumo
create or replace function public.caja_item_pedido_guardar(p_token text, p_producto bigint, p_insumo bigint, p_proveedor bigint, p_minimo numeric, p_ideal numeric)
returns void language plpgsql security definer set search_path = public as $$
begin
  perform public.caja__permiso(p_token, 'encargado');
  if p_proveedor is not null and not exists (select 1 from public.caja_proveedores where id = p_proveedor and local = 'prosegur') then raise exception 'Proveedor inexistente.'; end if;
  if p_producto is not null then
    update public.caja_productos set proveedor_id = p_proveedor, stock_minimo = greatest(coalesce(p_minimo, 0), 0), stock_ideal = greatest(coalesce(p_ideal, 0), 0),
           control_stock = control_stock or p_proveedor is not null, actualizado = now()
    where id = p_producto and local = 'prosegur';
  elsif p_insumo is not null then
    update public.caja_insumos set proveedor_id = p_proveedor, stock_minimo = greatest(coalesce(p_minimo, 0), 0), stock_ideal = greatest(coalesce(p_ideal, 0), 0)
    where id = p_insumo and local = 'prosegur';
  end if;
  if not found then raise exception 'No encontré el producto.'; end if;
end $$;

-- Asignar proveedor a toda una categoría de productos
create or replace function public.caja_proveedor_categoria(p_token text, p_categoria text, p_proveedor bigint)
returns int language plpgsql security definer set search_path = public as $$
declare n int;
begin
  perform public.caja__permiso(p_token, 'encargado');
  update public.caja_productos set proveedor_id = p_proveedor, control_stock = control_stock or p_proveedor is not null, actualizado = now()
  where local = 'prosegur' and categoria = p_categoria;
  get diagnostics n = row_count;
  return n;
end $$;

-- Insumo para pedir (descartables, condimentos, café…): {nombre, unidad, categoria, presentacion, factor, proveedor_id, stock_minimo, stock_ideal, activo}
create or replace function public.caja_insumo_pedido_guardar(p_token text, p_id bigint, p_datos jsonb)
returns json language plpgsql security definer set search_path = public as $$
declare u public.panel_usuarios; i public.caja_insumos; v_un text;
begin
  u := public.caja__permiso(p_token, 'encargado');
  if coalesce(trim(p_datos->>'nombre'), '') = '' then raise exception 'Falta el nombre.'; end if;
  v_un := coalesce(nullif(p_datos->>'unidad', ''), 'u');
  if v_un not in ('g','ml','u') then raise exception 'Unidad inválida (g, ml o u).'; end if;
  if p_id is null then
    insert into public.caja_insumos(local, nombre, unidad, categoria, presentacion, factor, proveedor_id, stock_minimo, stock_ideal, activo)
    values ('prosegur', trim(p_datos->>'nombre'), v_un, coalesce(nullif(trim(p_datos->>'categoria'), ''), 'Insumos'), coalesce(trim(p_datos->>'presentacion'), ''),
            greatest(coalesce(nullif(p_datos->>'factor', '')::numeric, 1), 0.001), nullif(p_datos->>'proveedor_id', '')::bigint,
            greatest(coalesce(nullif(p_datos->>'stock_minimo', '')::numeric, 0), 0), greatest(coalesce(nullif(p_datos->>'stock_ideal', '')::numeric, 0), 0),
            coalesce((p_datos->>'activo')::boolean, true))
    returning * into i;
  else
    update public.caja_insumos set nombre = trim(p_datos->>'nombre'), unidad = v_un, categoria = coalesce(nullif(trim(p_datos->>'categoria'), ''), 'Insumos'),
           presentacion = coalesce(trim(p_datos->>'presentacion'), ''), factor = greatest(coalesce(nullif(p_datos->>'factor', '')::numeric, 1), 0.001),
           proveedor_id = nullif(p_datos->>'proveedor_id', '')::bigint, stock_minimo = greatest(coalesce(nullif(p_datos->>'stock_minimo', '')::numeric, 0), 0),
           stock_ideal = greatest(coalesce(nullif(p_datos->>'stock_ideal', '')::numeric, 0), 0), activo = coalesce((p_datos->>'activo')::boolean, true)
    where id = p_id and local = 'prosegur' returning * into i;
    if i.id is null then raise exception 'No encontré el insumo.'; end if;
  end if;
  return row_to_json(i);
end $$;

-- ---------- automático (cron de Vercel, con la clave service_role) ----------
-- Datos para el envío automático de platos calientes: si ya hay un pedido de platos para esa fecha, no hace nada.
create or replace function public.caja_pedidos_auto_info()
returns json language plpgsql stable security definer set search_path = public as $$
declare v_el public.caja_proveedores; v_fecha date; v_cfg jsonb;
begin
  select * into v_el from public.caja_proveedores where local = 'prosegur' and tipo = 'easylunch' and activo order by id limit 1;
  if v_el.id is null then return json_build_object('hacer', false, 'motivo', 'Sin proveedor Easy Lunch activo'); end if;
  select valor into v_cfg from public.caja_config where local = 'prosegur' and clave = 'pedidos';
  if coalesce((v_cfg->>'auto_platos')::boolean, true) = false then return json_build_object('hacer', false, 'motivo', 'Envío automático desactivado'); end if;
  v_fecha := public.caja__proxima_entrega(v_el.dias);
  if exists (select 1 from public.caja_pedidos where local = 'prosegur' and proveedor_id = v_el.id and parte = 'platos'
             and fecha_entrega = v_fecha and estado <> 'cancelado') then
    return json_build_object('hacer', false, 'motivo', 'Ya hay pedido de platos para ' || v_fecha);
  end if;
  return json_build_object('hacer', true, 'proveedor_id', v_el.id, 'fecha_entrega', v_fecha, 'estimado', public.caja__estimado_plato(v_fecha));
end $$;

create or replace function public.caja_pedido_sistema(p_proveedor bigint, p_parte text, p_fecha_entrega date, p_items jsonb, p_nota text)
returns json language plpgsql security definer set search_path = public as $$
declare v_id bigint;
begin
  v_id := public.caja__pedido_insertar('Envío automático', 'automatico', p_proveedor, p_parte, p_fecha_entrega, p_items, p_nota);
  return public.caja__pedido_json(v_id);
end $$;

create or replace function public.caja_pedido_mail_sistema(p_id bigint, p_estado text, p_detalle text)
returns void language sql security definer set search_path = public as $$
  update public.caja_pedidos set mail_estado = left(coalesce(p_estado, ''), 20), mail_detalle = left(coalesce(p_detalle, ''), 500) where id = p_id;
$$;

-- ---------- planilla de modificaciones de Biel (Apps Script "Modificación de pedidos", archivo LocalProsegur.gs) ----------
-- Los pedidos del local a Easy Lunch (no cancelados) entran a la planilla como altas de la empresa PROSEGUR:
-- planilla, comanda, Base, Despacho, celular, Producción y Recorridos. No se facturan (son nuestros).
-- El Apps Script la llama con el token guardado en caja_config (clave export_planilla), copiado en LocalProsegur.gs.
-- El token se genera acá al azar (no está en el repositorio). Para verlo: select valor #>> '{}' from caja_config where clave = 'export_planilla';
insert into public.caja_config(local, clave, valor) values ('prosegur', 'export_planilla', to_jsonb(encode(extensions.gen_random_bytes(18), 'hex')))
on conflict (local, clave) do nothing;

create or replace function public.caja_pedidos_export(p_token text, p_desde date, p_hasta date)
returns json language plpgsql stable security definer set search_path = public as $$
declare v_tok text;
begin
  select valor #>> '{}' into v_tok from public.caja_config where local = 'prosegur' and clave = 'export_planilla';
  if v_tok is null or p_token is distinct from v_tok then raise exception 'Token inválido.'; end if;
  if p_hasta < p_desde or p_hasta > p_desde + 62 then raise exception 'Período inválido.'; end if;
  return coalesce((select json_agg(json_build_object(
      'id', p.id, 'fecha', p.fecha_entrega, 'parte', p.parte, 'estado', p.estado, 'origen', p.origen, 'usuario', p.usuario, 'nota', p.nota,
      'items', coalesce((select json_agg(json_build_object(
          'nombre', i.nombre, 'cantidad', i.cantidad, 'unidad', i.unidad, 'grupo', i.grupo,
          'tipo', case when i.insumo_id is not null then 'insumo' else coalesce(pr.tipo, 'vianda') end) order by i.id)
        from public.caja_pedido_items i left join public.caja_productos pr on pr.id = i.producto_id where i.pedido_id = p.id), '[]'))
    order by p.fecha_entrega, p.id)
    from public.caja_pedidos p join public.caja_proveedores pv on pv.id = p.proveedor_id
    where p.local = 'prosegur' and pv.tipo = 'easylunch' and p.estado <> 'cancelado'
      and p.fecha_entrega between p_desde and p_hasta), '[]');
end $$;
grant execute on function public.caja_pedidos_export(text, date, date) to anon, authenticated;

-- ---------- retiros con las modificaciones de Biel ----------
-- El Apps Script publica, cada vez que recalcula (al guardar un cambio y cada 10 minutos), la lista FINAL de pedidos
-- de PROSEGUR por persona y día (sistema + altas, bajas, cambios y temporales de la planilla; sin lo del local).
-- "Retiros app" de la caja la usa en vez de los pedidos crudos de la app. Solo se lee con sesión de la caja.
create table if not exists public.caja_retiros_planilla (
  local       text not null default 'prosegur',
  fecha       date not null,
  pedidos     jsonb not null default '[]',
  actualizado timestamptz not null default now(),
  version     text not null default '',
  primary key (local, fecha)
);
alter table public.caja_retiros_planilla enable row level security;
revoke all on public.caja_retiros_planilla from anon, authenticated;

-- p_dias: { "AAAA-MM-DD": [ {id_usuario, nombre, apellido, dni (últimos 3), items: [{tipo, nombre, pagado}], pago_pendiente, alta} ] }
-- Reemplaza todo el período (los días sin pedidos quedan con lista vacía).
create or replace function public.caja_retiros_planilla_publicar(p_token text, p_desde date, p_hasta date, p_dias jsonb, p_version text default '')
returns int language plpgsql security definer set search_path = public as $$
declare v_tok text; d date; n int := 0;
begin
  select valor #>> '{}' into v_tok from public.caja_config where local = 'prosegur' and clave = 'export_planilla';
  if v_tok is null or p_token is distinct from v_tok then raise exception 'Token inválido.'; end if;
  if p_hasta < p_desde or p_hasta > p_desde + 31 then raise exception 'Período inválido.'; end if;
  for d in select generate_series(p_desde, p_hasta, interval '1 day')::date loop
    insert into public.caja_retiros_planilla(local, fecha, pedidos, actualizado, version)
    values ('prosegur', d, coalesce(p_dias->(d::text), '[]'), now(), left(coalesce(p_version, ''), 80))
    on conflict (local, fecha) do update set pedidos = excluded.pedidos, actualizado = excluded.actualizado, version = excluded.version;
    n := n + jsonb_array_length(coalesce(p_dias->(d::text), '[]'));
  end loop;
  return n;
end $$;

create or replace function public.caja_retiros_planilla_dia(p_token text, p_fecha date)
returns json language plpgsql stable security definer set search_path = public as $$
begin
  perform public.caja__permiso(p_token, 'ver');
  return (select json_build_object('pedidos', pedidos, 'actualizado', actualizado, 'version', version)
          from public.caja_retiros_planilla where local = 'prosegur' and fecha = p_fecha);
end $$;
grant execute on function public.caja_retiros_planilla_publicar(text, date, date, jsonb, text) to anon, authenticated;
grant execute on function public.caja_retiros_planilla_dia(text, date) to anon, authenticated;

-- ---------- permisos ----------
revoke all on function public.caja__proxima_entrega(int[], date) from public, anon, authenticated;
revoke all on function public.caja__estimado_plato(date) from public, anon, authenticated;
revoke all on function public.caja__pedido_insertar(text, text, bigint, text, date, jsonb, text) from public, anon, authenticated;
revoke all on function public.caja__pedido_items_cargar(bigint, jsonb) from public, anon, authenticated;
revoke all on function public.caja__pedido_limite(bigint) from public, anon, authenticated;
revoke all on function public.caja__pedido_puede_cambiar(text, bigint) from public, anon, authenticated;
revoke all on function public.caja__pedido_json(bigint) from public, anon, authenticated;
revoke all on function public.caja_pedidos_auto_info() from public, anon, authenticated;
revoke all on function public.caja_pedido_sistema(bigint, text, date, jsonb, text) from public, anon, authenticated;
revoke all on function public.caja_pedido_mail_sistema(bigint, text, text) from public, anon, authenticated;
grant execute on function public.caja_pedidos_auto_info() to service_role;
grant execute on function public.caja_pedido_sistema(bigint, text, date, jsonb, text) to service_role;
grant execute on function public.caja_pedido_mail_sistema(bigint, text, text) to service_role;
grant execute on function public.caja_pedidos_datos(text) to anon, authenticated;
grant execute on function public.caja_pedido_crear(text, bigint, text, date, jsonb, text) to anon, authenticated;
grant execute on function public.caja_pedido_mail_registrar(text, bigint, text, text) to anon, authenticated;
grant execute on function public.caja_pedido_cancelar(text, bigint) to anon, authenticated;
grant execute on function public.caja_pedido_editar(text, bigint, jsonb, text) to anon, authenticated;
grant execute on function public.caja_pedido_recibir(text, bigint, jsonb, text) to anon, authenticated;
grant execute on function public.caja_proveedor_guardar(text, bigint, jsonb) to anon, authenticated;
grant execute on function public.caja_pedidos_config_guardar(text, jsonb) to anon, authenticated;
grant execute on function public.caja_item_pedido_guardar(text, bigint, bigint, bigint, numeric, numeric) to anon, authenticated;
grant execute on function public.caja_proveedor_categoria(text, text, bigint) to anon, authenticated;
grant execute on function public.caja_insumo_pedido_guardar(text, bigint, jsonb) to anon, authenticated;

notify pgrst, 'reload schema';
