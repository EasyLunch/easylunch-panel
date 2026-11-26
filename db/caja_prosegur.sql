-- =====================================================================
-- EASY LUNCH · Local Prosegur — productos, precios, descuentos e historial
-- Correr UNA vez en Supabase → SQL Editor → New query → Run.
-- Se puede volver a correr sin romper nada (no borra datos).
-- Requiere que ya esté corrido db/panel_usuarios.sql (usa los usuarios del panel).
--
-- Permisos (tarjetas del panel, se asignan en "Usuarios"):
--  * Administrador: todo (productos, precio local, descuentos, sincronizar).
--  * Tarjeta "prosegur-precios" (encargado): ve todo, sincroniza y activa o
--    pausa descuentos ya creados. No cambia precios.
--  * Tarjeta "prosegur-caja" (cajero): lee el catálogo para vender y puede sincronizar con la app.
--
-- Seguridad: igual que el panel. Las tablas tienen RLS activado y ninguna
-- política; con la clave pública solo se accede a través de las funciones
-- caja_* de abajo, que validan la sesión del panel.
-- =====================================================================

-- ---------- tablas ----------
create table if not exists public.caja_productos (
  id              bigint generated always as identity primary key,
  local           text not null default 'prosegur',
  origen          text not null check (origen in ('app','local')),
  ref_app         text,                        -- clave del producto en la app (ej. "plato:1182"); null en los del local
  nombre          text not null,
  categoria       text not null default '',    -- botón de la caja (ej. "Plato del día", "Milanesas", "Cafetería")
  grupo           text not null default '',    -- módulo de la app de donde viene
  tipo            text not null default 'otro' check (tipo in ('vianda','postre','bebida','cafeteria','kiosco','otro')),
  precio_base     numeric(12,2),               -- app: precio del producto en la app · local: precio cargado acá
  precio_local    numeric(12,2),               -- precio distinto solo para el local (gana sobre el base)
  iva             numeric(5,2) not null default 21,
  activo          boolean not null default true,  -- se puede ocultar a mano en el local
  en_app          boolean not null default true,  -- (solo app) hoy está habilitado para la empresa en la app
  del_dia         boolean not null default false, -- (solo app) es un plato del menú del día
  revisar_precio  boolean not null default false, -- cambió el precio base y tiene precio local: revisar
  orden           int not null default 0,
  ultima_sync     timestamptz,
  creado          timestamptz not null default now(),
  actualizado     timestamptz not null default now(),
  unique (local, ref_app)
);
-- fotos: img = la de la app (URL) · img_local = subida en el panel (gana sobre la de la app)
alter table public.caja_productos add column if not exists img text;
alter table public.caja_productos add column if not exists img_local text;
-- stock (lo usan las ventas: db/caja_prosegur_ventas.sql)
alter table public.caja_productos add column if not exists control_stock boolean not null default false;
alter table public.caja_productos add column if not exists sobrante boolean not null default false;
alter table public.caja_productos add column if not exists stock_minimo numeric(12,3) not null default 0;

create table if not exists public.caja_descuentos (
  id              bigint generated always as identity primary key,
  local           text not null default 'prosegur',
  nombre          text not null,
  tipo            text not null check (tipo in ('porcentaje','monto')),
  valor           numeric(12,2) not null check (valor > 0),
  alcance         text not null check (alcance in ('todo','categoria','producto')),
  alcance_valor   text,                        -- nombre de la categoría o id del producto
  desde           date,
  hasta           date,
  dias            smallint[],                  -- 1 = lunes … 7 = domingo; null = todos
  hora_desde      time,
  hora_hasta      time,
  activo          boolean not null default true,
  creado_por      text not null default '',
  creado          timestamptz not null default now(),
  actualizado     timestamptz not null default now()
);

create table if not exists public.caja_precio_historial (
  id              bigint generated always as identity primary key,
  local           text not null default 'prosegur',
  fecha           timestamptz not null default now(),
  usuario         text not null default '',
  producto_id     bigint,
  descuento_id    bigint,
  objeto          text not null default '',    -- nombre del producto o del descuento
  tipo            text not null,               -- precio_base, precio_local, alta, producto_activado, descuento_nuevo, …
  antes           text,
  despues         text,
  origen          text not null default 'manual' check (origen in ('manual','sincronizacion')),
  motivo          text not null default ''
);
create index if not exists caja_precio_historial_fecha on public.caja_precio_historial (local, fecha desc);

create table if not exists public.caja_sync_log (
  id              bigint generated always as identity primary key,
  local           text not null default 'prosegur',
  fecha           timestamptz not null default now(),
  usuario         text not null default '',
  origen          text not null default 'manual' check (origen in ('manual','automatica')),
  fecha_menu      date,
  resumen         jsonb not null default '{}'
);

alter table public.caja_productos        enable row level security;
alter table public.caja_descuentos       enable row level security;
alter table public.caja_precio_historial enable row level security;
alter table public.caja_sync_log         enable row level security;
revoke all on public.caja_productos        from anon, authenticated;
revoke all on public.caja_descuentos       from anon, authenticated;
revoke all on public.caja_precio_historial from anon, authenticated;
revoke all on public.caja_sync_log         from anon, authenticated;

-- ---------- helpers internos ----------
-- nivel: 'ver' (cajero, encargado o admin) · 'encargado' (encargado o admin) · 'admin'
create or replace function public.caja__permiso(p_token text, p_nivel text)
returns public.panel_usuarios language plpgsql stable security definer set search_path = public as $$
declare u public.panel_usuarios;
begin
  u := public.panel__usuario_de(p_token);
  if u.id is null then raise exception 'Sesión vencida. Volvé a ingresar al panel.'; end if;
  if u.es_admin then return u; end if;
  if p_nivel = 'ver' and (u.tarjetas && array['prosegur-precios','prosegur-caja']) then return u; end if;
  if p_nivel = 'encargado' and ('prosegur-precios' = any(u.tarjetas)) then return u; end if;
  raise exception 'Tu usuario no tiene permiso para hacer esto.';
end $$;

create or replace function public.caja__plata(n numeric)
returns text language sql immutable as $$
  -- formato argentino: $10.500 · $2.750,50
  select case when n is null then '—' else
    (case when n < 0 then '-' else '' end) || '$' || replace(to_char(trunc(abs(n)), 'FM999,999,999,990'), ',', '.') ||
    case when abs(n) <> trunc(abs(n)) then ',' || lpad(round((abs(n) - trunc(abs(n))) * 100)::int::text, 2, '0') else '' end
  end;
$$;

create or replace function public.caja__desc_txt(d public.caja_descuentos)
returns text language sql stable set search_path = public as $$
  select concat_ws(' · ',
    case when d.tipo = 'porcentaje' then trim_scale(d.valor)::text || '%' else public.caja__plata(d.valor) end,
    case d.alcance when 'todo' then 'todo el local'
                   when 'categoria' then 'categoría ' || coalesce(d.alcance_valor, '')
                   else 'producto ' || coalesce((select p.nombre from public.caja_productos p where p.id::text = d.alcance_valor), d.alcance_valor) end,
    case when d.desde is not null or d.hasta is not null
         then 'del ' || coalesce(to_char(d.desde, 'DD/MM/YYYY'), '…') || ' al ' || coalesce(to_char(d.hasta, 'DD/MM/YYYY'), '…') end,
    case when d.dias is not null and array_length(d.dias, 1) between 1 and 6
         then (select string_agg((array['lun','mar','mié','jue','vie','sáb','dom'])[x], ' ' order by x) from unnest(d.dias) x) end,
    case when d.hora_desde is not null or d.hora_hasta is not null
         then coalesce(to_char(d.hora_desde, 'HH24:MI'), '00:00') || '–' || coalesce(to_char(d.hora_hasta, 'HH24:MI'), '24:00') end,
    case when d.activo then null else 'pausado' end);
$$;

create or replace function public.caja__log(p_local text, p_usuario text, p_producto bigint, p_descuento bigint,
  p_objeto text, p_tipo text, p_antes text, p_despues text, p_origen text, p_motivo text)
returns void language sql security definer set search_path = public as $$
  insert into public.caja_precio_historial(local, usuario, producto_id, descuento_id, objeto, tipo, antes, despues, origen, motivo)
  values (p_local, coalesce(p_usuario, ''), p_producto, p_descuento, coalesce(p_objeto, ''), p_tipo, p_antes, p_despues,
          coalesce(p_origen, 'manual'), coalesce(trim(p_motivo), ''));
$$;

-- Aplica la lista de productos que manda la sincronización.
-- p_items: [{ref, nombre, categoria, grupo, tipo, precio, del_dia, orden}]
create or replace function public.caja__sync(p_local text, p_items jsonb, p_fecha date, p_usuario text, p_origen text)
returns json language plpgsql security definer set search_path = public as $$
declare
  it jsonb; p public.caja_productos; v_precio numeric; v_ref text; v_tipo text;
  nuevos text[] := '{}'; precios jsonb := '[]'; revisar text[] := '{}'; reactivados int := 0;
  quitados text[] := '{}'; sale_dia int := 0; sin_precio text[] := '{}'; refs text[] := '{}';
  v_resumen json;
begin
  if jsonb_typeof(p_items) <> 'array' or jsonb_array_length(p_items) = 0 then
    raise exception 'La sincronización no trajo productos. No se cambió nada.';
  end if;
  for it in select * from jsonb_array_elements(p_items) loop
    v_ref := nullif(trim(it->>'ref'), '');
    if v_ref is null or v_ref = any(refs) then continue; end if;
    refs := refs || v_ref;
    v_precio := nullif(it->>'precio', '')::numeric;
    v_tipo := case when it->>'tipo' in ('vianda','postre','bebida','cafeteria','kiosco','otro') then it->>'tipo' else 'otro' end;
    if v_precio is null then sin_precio := sin_precio || (it->>'nombre'); end if;
    select * into p from public.caja_productos where local = p_local and ref_app = v_ref;
    if p.id is null then
      insert into public.caja_productos(local, origen, ref_app, nombre, categoria, grupo, tipo, precio_base, del_dia, orden, ultima_sync, img, control_stock)
      values (p_local, 'app', v_ref, it->>'nombre', coalesce(it->>'categoria', ''), coalesce(it->>'grupo', ''), v_tipo,
              v_precio, coalesce((it->>'del_dia')::boolean, false), coalesce((it->>'orden')::int, 0), now(), nullif(trim(it->>'img'), ''),
              v_tipo in ('vianda','postre','bebida'))
      returning * into p;
      -- proveedor: el mismo que otro producto de la categoría; si no hay, Easy Lunch (tabla de db/caja_prosegur_pedidos.sql)
      if to_regclass('public.caja_proveedores') is not null then
        execute 'update public.caja_productos set proveedor_id = coalesce(
                   (select proveedor_id from public.caja_productos where local = $1 and categoria = $2 and proveedor_id is not null and id <> $3 limit 1),
                   (select id from public.caja_proveedores where local = $1 and tipo = ''easylunch'' and activo order by id limit 1))
                 where id = $3' using p_local, p.categoria, p.id;
      end if;
      nuevos := nuevos || (it->>'nombre');
    else
      if not p.en_app then reactivados := reactivados + 1; end if;
      if v_precio is not null and p.precio_base is distinct from v_precio then
        perform public.caja__log(p_local, p_usuario, p.id, null, it->>'nombre', 'precio_base',
          public.caja__plata(p.precio_base), public.caja__plata(v_precio), 'sincronizacion', '');
        precios := precios || jsonb_build_object('nombre', it->>'nombre', 'antes', p.precio_base, 'despues', v_precio,
                                                 'precio_local', p.precio_local);
        if p.precio_local is not null then revisar := revisar || (it->>'nombre'); end if;
      end if;
      update public.caja_productos set
        nombre = it->>'nombre', categoria = coalesce(it->>'categoria', ''), grupo = coalesce(it->>'grupo', ''), tipo = v_tipo,
        img = coalesce(nullif(trim(it->>'img'), ''), img),
        precio_base = coalesce(v_precio, precio_base),
        revisar_precio = revisar_precio or (v_precio is not null and precio_base is distinct from v_precio and precio_local is not null),
        del_dia = coalesce((it->>'del_dia')::boolean, false), orden = coalesce((it->>'orden')::int, 0),
        en_app = true, sobrante = false, ultima_sync = now(), actualizado = now()
      where id = p.id;
    end if;
  end loop;
  -- lo que ya no está habilitado en la app queda fuera de la caja (no se borra: se conserva el historial)
  for p in select * from public.caja_productos
           where local = p_local and origen = 'app' and en_app and not (ref_app = any(refs)) loop
    -- plato del día que sobró: sigue a la venta (como "de ayer") hasta que se termine el stock
    if (p.del_dia or p.sobrante) and p.control_stock
       and coalesce((select sum(cantidad) from public.caja_stock_mov where producto_id = p.id), 0) > 0 then
      update public.caja_productos set del_dia = false, sobrante = true, actualizado = now() where id = p.id;
      continue;
    end if;
    if p.del_dia then sale_dia := sale_dia + 1; else quitados := quitados || p.nombre; end if;
    update public.caja_productos set en_app = false, del_dia = false, actualizado = now() where id = p.id;
  end loop;
  v_resumen := json_build_object(
    'fecha_menu', p_fecha, 'total', array_length(refs, 1),
    'nuevos', to_json(nuevos), 'precios', precios, 'revisar', to_json(revisar),
    'quitados', to_json(quitados), 'platos_dia_anteriores', sale_dia, 'reactivados', reactivados,
    'sin_precio', to_json(sin_precio));
  insert into public.caja_sync_log(local, usuario, origen, fecha_menu, resumen)
  values (p_local, coalesce(p_usuario, ''), p_origen, p_fecha, v_resumen::jsonb);
  return v_resumen;
end $$;

-- ---------- funciones que usa la página ----------
create or replace function public.caja_catalogo(p_token text)
returns json language plpgsql stable security definer set search_path = public as $$
declare u public.panel_usuarios;
begin
  u := public.caja__permiso(p_token, 'ver');
  return json_build_object(
    'yo', json_build_object('nombre', coalesce(nullif(u.nombre, ''), u.usuario), 'admin', u.es_admin,
                            'encargado', u.es_admin or 'prosegur-precios' = any(u.tarjetas)),
    'productos', coalesce((select json_agg(row_to_json(p) order by p.tipo, p.categoria, p.orden, p.nombre)
                           from public.caja_productos p where p.local = 'prosegur'), '[]'),
    'descuentos', coalesce((select json_agg(json_build_object(
                             'id', d.id, 'nombre', d.nombre, 'tipo', d.tipo, 'valor', d.valor, 'alcance', d.alcance,
                             'alcance_valor', d.alcance_valor, 'desde', d.desde, 'hasta', d.hasta, 'dias', d.dias,
                             'hora_desde', to_char(d.hora_desde, 'HH24:MI'), 'hora_hasta', to_char(d.hora_hasta, 'HH24:MI'),
                             'activo', d.activo, 'creado_por', d.creado_por, 'texto', public.caja__desc_txt(d)) order by d.activo desc, d.creado desc)
                           from public.caja_descuentos d where d.local = 'prosegur'), '[]'),
    'ultima_sync', (select row_to_json(s) from public.caja_sync_log s where s.local = 'prosegur' order by s.fecha desc limit 1));
end $$;

create or replace function public.caja_historial(p_token text, p_limite int default 500)
returns json language plpgsql stable security definer set search_path = public as $$
begin
  perform public.caja__permiso(p_token, 'encargado');
  return coalesce((select json_agg(row_to_json(h) order by h.fecha desc)
                   from (select * from public.caja_precio_historial where local = 'prosegur'
                         order by fecha desc limit greatest(1, least(coalesce(p_limite, 500), 5000))) h), '[]');
end $$;

-- Alta o edición de un producto. Los del local (cafetería, kiosco…) se editan completos;
-- los que vienen de la app solo cambian IVA, orden y si se muestran (nombre y precio base vienen de la app).
create or replace function public.caja_producto_guardar(p_token text, p_id bigint, p_datos jsonb, p_motivo text default '')
returns json language plpgsql security definer set search_path = public as $$
declare u public.panel_usuarios; p public.caja_productos; v_nombre text; v_precio numeric; v_iva numeric; v_activo boolean; v_tipo text;
begin
  u := public.caja__permiso(p_token, 'admin');
  v_iva := coalesce(nullif(p_datos->>'iva', '')::numeric, 21);
  if v_iva not in (0, 10.5, 21, 27) then raise exception 'IVA inválido (0, 10,5, 21 o 27).'; end if;
  v_activo := coalesce((p_datos->>'activo')::boolean, true);
  if p_datos ? 'img_local' and p_datos->>'img_local' is not null and p_datos->>'img_local' <> '' then
    if p_datos->>'img_local' !~ '^data:image/(webp|jpeg|png);base64,' then raise exception 'La foto tiene un formato inválido.'; end if;
    if length(p_datos->>'img_local') > 400000 then raise exception 'La foto es muy pesada (máximo ~300 KB).'; end if;
  end if;
  if p_id is null then
    v_nombre := trim(coalesce(p_datos->>'nombre', ''));
    v_precio := nullif(p_datos->>'precio', '')::numeric;
    v_tipo := case when p_datos->>'tipo' in ('vianda','postre','bebida','cafeteria','kiosco','otro') then p_datos->>'tipo' else 'otro' end;
    if v_nombre = '' then raise exception 'Falta el nombre.'; end if;
    if v_precio is null or v_precio < 0 then raise exception 'Falta el precio.'; end if;
    insert into public.caja_productos(local, origen, nombre, categoria, tipo, precio_base, iva, activo, orden, img_local, control_stock)
    values ('prosegur', 'local', v_nombre, trim(coalesce(p_datos->>'categoria', '')), v_tipo, v_precio, v_iva, v_activo,
            coalesce(nullif(p_datos->>'orden', '')::int, 0), nullif(p_datos->>'img_local', ''), v_tipo in ('kiosco','bebida','postre','vianda'))
    returning * into p;
    perform public.caja__log('prosegur', coalesce(nullif(u.nombre, ''), u.usuario), p.id, null, p.nombre, 'alta', null,
                             public.caja__plata(v_precio), 'manual', p_motivo);
    return row_to_json(p);
  end if;
  select * into p from public.caja_productos where id = p_id and local = 'prosegur';
  if p.id is null then raise exception 'No encontré el producto.'; end if;
  if p.origen = 'local' then
    v_nombre := coalesce(nullif(trim(p_datos->>'nombre'), ''), p.nombre);
    v_precio := coalesce(nullif(p_datos->>'precio', '')::numeric, p.precio_base);
    if v_precio < 0 then raise exception 'Precio inválido.'; end if;
    if v_precio is distinct from p.precio_base then
      perform public.caja__log('prosegur', coalesce(nullif(u.nombre, ''), u.usuario), p.id, null, v_nombre, 'precio_base',
                               public.caja__plata(p.precio_base), public.caja__plata(v_precio), 'manual', p_motivo);
    end if;
    update public.caja_productos set nombre = v_nombre,
      categoria = coalesce(p_datos->>'categoria', categoria),
      tipo = case when p_datos->>'tipo' in ('vianda','postre','bebida','cafeteria','kiosco','otro') then p_datos->>'tipo' else tipo end,
      precio_base = v_precio, iva = v_iva, activo = v_activo,
      img_local = case when p_datos ? 'img_local' then nullif(p_datos->>'img_local', '') else img_local end,
      orden = coalesce(nullif(p_datos->>'orden', '')::int, orden), actualizado = now()
    where id = p.id;
  else
    update public.caja_productos set iva = v_iva, activo = v_activo,
      img_local = case when p_datos ? 'img_local' then nullif(p_datos->>'img_local', '') else img_local end,
      orden = coalesce(nullif(p_datos->>'orden', '')::int, orden), actualizado = now()
    where id = p.id;
  end if;
  if v_activo is distinct from p.activo then
    perform public.caja__log('prosegur', coalesce(nullif(u.nombre, ''), u.usuario), p.id, null, p.nombre,
      case when v_activo then 'producto_activado' else 'producto_desactivado' end, null, null, 'manual', p_motivo);
  end if;
  if v_iva is distinct from p.iva then
    perform public.caja__log('prosegur', coalesce(nullif(u.nombre, ''), u.usuario), p.id, null, p.nombre, 'iva',
      trim_scale(p.iva)::text || '%', trim_scale(v_iva)::text || '%', 'manual', p_motivo);
  end if;
  select * into p from public.caja_productos where id = p_id;
  return row_to_json(p);
end $$;

-- Precio local: p_precio = null lo quita (vuelve al precio de la app).
create or replace function public.caja_precio_local(p_token text, p_id bigint, p_precio numeric, p_motivo text default '')
returns json language plpgsql security definer set search_path = public as $$
declare u public.panel_usuarios; p public.caja_productos;
begin
  u := public.caja__permiso(p_token, 'admin');
  if p_precio is not null and p_precio < 0 then raise exception 'Precio inválido.'; end if;
  select * into p from public.caja_productos where id = p_id and local = 'prosegur';
  if p.id is null then raise exception 'No encontré el producto.'; end if;
  if p.origen <> 'app' then raise exception 'Los productos del local se editan directamente (no tienen precio local aparte).'; end if;
  if p_precio is distinct from p.precio_local then
    perform public.caja__log('prosegur', coalesce(nullif(u.nombre, ''), u.usuario), p.id, null, p.nombre, 'precio_local',
      case when p.precio_local is null then 'sin precio local (' || public.caja__plata(p.precio_base) || ')' else public.caja__plata(p.precio_local) end,
      case when p_precio is null then 'sin precio local (' || public.caja__plata(p.precio_base) || ')' else public.caja__plata(p_precio) end,
      'manual', p_motivo);
  end if;
  update public.caja_productos set precio_local = p_precio, revisar_precio = false, actualizado = now() where id = p.id returning * into p;
  return row_to_json(p);
end $$;

-- "Revisado": cambió el precio de la app pero se mantiene el precio local.
create or replace function public.caja_precio_revisado(p_token text, p_id bigint, p_motivo text default '')
returns void language plpgsql security definer set search_path = public as $$
declare u public.panel_usuarios; p public.caja_productos;
begin
  u := public.caja__permiso(p_token, 'admin');
  select * into p from public.caja_productos where id = p_id and local = 'prosegur';
  if p.id is null then raise exception 'No encontré el producto.'; end if;
  update public.caja_productos set revisar_precio = false, actualizado = now() where id = p.id;
  perform public.caja__log('prosegur', coalesce(nullif(u.nombre, ''), u.usuario), p.id, null, p.nombre, 'precio_local_confirmado',
    public.caja__plata(p.precio_local), public.caja__plata(p.precio_local), 'manual',
    coalesce(nullif(trim(p_motivo), ''), 'Se mantiene el precio local (precio de la app: ' || public.caja__plata(p.precio_base) || ')'));
end $$;

create or replace function public.caja_descuento_guardar(p_token text, p_id bigint, p_datos jsonb, p_motivo text default '')
returns json language plpgsql security definer set search_path = public as $$
declare u public.panel_usuarios; d public.caja_descuentos; antes text; v_dias smallint[];
begin
  u := public.caja__permiso(p_token, 'admin');
  if coalesce(trim(p_datos->>'nombre'), '') = '' then raise exception 'Poné un nombre al descuento.'; end if;
  if p_datos->>'tipo' not in ('porcentaje','monto') then raise exception 'Elegí si es porcentaje o monto fijo.'; end if;
  if coalesce(nullif(p_datos->>'valor', '')::numeric, 0) <= 0 then raise exception 'El valor del descuento tiene que ser mayor a 0.'; end if;
  if p_datos->>'tipo' = 'porcentaje' and (p_datos->>'valor')::numeric > 100 then raise exception 'El porcentaje no puede pasar de 100.'; end if;
  if p_datos->>'alcance' not in ('todo','categoria','producto') then raise exception 'Elegí a qué se aplica el descuento.'; end if;
  if p_datos->>'alcance' <> 'todo' and coalesce(trim(p_datos->>'alcance_valor'), '') = '' then raise exception 'Elegí la categoría o el producto.'; end if;
  if jsonb_typeof(p_datos->'dias') = 'array' and jsonb_array_length(p_datos->'dias') > 0 then
    select array_agg(distinct x::smallint order by x::smallint) into v_dias from jsonb_array_elements_text(p_datos->'dias') x where x::int between 1 and 7;
  end if;
  if p_id is null then
    insert into public.caja_descuentos(local, nombre, tipo, valor, alcance, alcance_valor, desde, hasta, dias, hora_desde, hora_hasta, activo, creado_por)
    values ('prosegur', trim(p_datos->>'nombre'), p_datos->>'tipo', (p_datos->>'valor')::numeric, p_datos->>'alcance',
            case when p_datos->>'alcance' = 'todo' then null else trim(p_datos->>'alcance_valor') end,
            nullif(p_datos->>'desde', '')::date, nullif(p_datos->>'hasta', '')::date, v_dias,
            nullif(p_datos->>'hora_desde', '')::time, nullif(p_datos->>'hora_hasta', '')::time,
            coalesce((p_datos->>'activo')::boolean, true), coalesce(nullif(u.nombre, ''), u.usuario))
    returning * into d;
    perform public.caja__log('prosegur', coalesce(nullif(u.nombre, ''), u.usuario), null, d.id, d.nombre, 'descuento_nuevo',
                             null, public.caja__desc_txt(d), 'manual', p_motivo);
  else
    select * into d from public.caja_descuentos where id = p_id and local = 'prosegur';
    if d.id is null then raise exception 'No encontré el descuento.'; end if;
    antes := public.caja__desc_txt(d);
    update public.caja_descuentos set nombre = trim(p_datos->>'nombre'), tipo = p_datos->>'tipo', valor = (p_datos->>'valor')::numeric,
      alcance = p_datos->>'alcance', alcance_valor = case when p_datos->>'alcance' = 'todo' then null else trim(p_datos->>'alcance_valor') end,
      desde = nullif(p_datos->>'desde', '')::date, hasta = nullif(p_datos->>'hasta', '')::date, dias = v_dias,
      hora_desde = nullif(p_datos->>'hora_desde', '')::time, hora_hasta = nullif(p_datos->>'hora_hasta', '')::time,
      activo = coalesce((p_datos->>'activo')::boolean, activo), actualizado = now()
    where id = d.id returning * into d;
    if antes is distinct from public.caja__desc_txt(d) then
      perform public.caja__log('prosegur', coalesce(nullif(u.nombre, ''), u.usuario), null, d.id, d.nombre, 'descuento_modificado',
                               antes, public.caja__desc_txt(d), 'manual', p_motivo);
    end if;
  end if;
  return json_build_object('id', d.id);
end $$;

create or replace function public.caja_descuento_activar(p_token text, p_id bigint, p_activo boolean, p_motivo text default '')
returns void language plpgsql security definer set search_path = public as $$
declare u public.panel_usuarios; d public.caja_descuentos;
begin
  u := public.caja__permiso(p_token, 'encargado');
  select * into d from public.caja_descuentos where id = p_id and local = 'prosegur';
  if d.id is null then raise exception 'No encontré el descuento.'; end if;
  if d.activo = p_activo then return; end if;
  update public.caja_descuentos set activo = p_activo, actualizado = now() where id = d.id returning * into d;
  perform public.caja__log('prosegur', coalesce(nullif(u.nombre, ''), u.usuario), null, d.id, d.nombre,
    case when p_activo then 'descuento_activado' else 'descuento_pausado' end, null, public.caja__desc_txt(d), 'manual', p_motivo);
end $$;

-- Carga masiva de productos del local (pegados desde Excel).
-- p_items: [{nombre, categoria, precio, iva?, tipo?}]
-- Si ya existe un producto del local con el mismo nombre, se actualiza (categoría, precio, IVA, tipo); si no, se crea.
create or replace function public.caja_productos_masivo(p_token text, p_items jsonb, p_motivo text default '')
returns json language plpgsql security definer set search_path = public as $$
declare
  u public.panel_usuarios; quien text; it jsonb; p public.caja_productos;
  v_nombre text; v_cat text; v_precio numeric; v_iva numeric; v_tipo text; n int := 0;
  nuevos int := 0; actualizados int := 0; iguales int := 0; vistos text[] := '{}';
begin
  u := public.caja__permiso(p_token, 'admin');
  quien := coalesce(nullif(u.nombre, ''), u.usuario);
  if jsonb_typeof(p_items) <> 'array' or jsonb_array_length(p_items) = 0 then raise exception 'No hay productos para cargar.'; end if;
  if jsonb_array_length(p_items) > 500 then raise exception 'Máximo 500 productos por carga.'; end if;
  -- primero se valida todo: si una fila está mal no se carga nada
  for it in select * from jsonb_array_elements(p_items) loop
    n := n + 1;
    v_nombre := trim(coalesce(it->>'nombre', ''));
    if v_nombre = '' then raise exception 'Fila %: falta el nombre.', n; end if;
    if lower(v_nombre) = any(vistos) then raise exception 'Fila %: "%" está repetido en la lista.', n, v_nombre; end if;
    vistos := vistos || lower(v_nombre);
    if trim(coalesce(it->>'categoria', '')) = '' then raise exception 'Fila % (%): falta la categoría.', n, v_nombre; end if;
    if nullif(it->>'precio', '') is null or (it->>'precio')::numeric < 0 then raise exception 'Fila % (%): precio inválido.', n, v_nombre; end if;
    if coalesce(nullif(it->>'iva', '')::numeric, 21) not in (0, 10.5, 21, 27) then raise exception 'Fila % (%): IVA inválido (0, 10,5, 21 o 27).', n, v_nombre; end if;
  end loop;
  for it in select * from jsonb_array_elements(p_items) loop
    v_nombre := trim(it->>'nombre');
    v_cat := trim(it->>'categoria');
    v_precio := (it->>'precio')::numeric;
    v_iva := coalesce(nullif(it->>'iva', '')::numeric, 21);
    v_tipo := case when it->>'tipo' in ('vianda','postre','bebida','cafeteria','kiosco','otro') then it->>'tipo' else 'otro' end;
    select * into p from public.caja_productos
      where local = 'prosegur' and origen = 'local' and lower(trim(nombre)) = lower(v_nombre) order by id limit 1;
    if p.id is null then
      insert into public.caja_productos(local, origen, nombre, categoria, tipo, precio_base, iva, activo, control_stock)
      values ('prosegur', 'local', v_nombre, v_cat, v_tipo, v_precio, v_iva, true, v_tipo in ('kiosco','bebida','postre','vianda')) returning * into p;
      perform public.caja__log('prosegur', quien, p.id, null, p.nombre, 'alta', null, public.caja__plata(v_precio), 'manual',
                               concat_ws(' · ', 'Carga masiva', nullif(trim(p_motivo), '')));
      nuevos := nuevos + 1;
    else
      if p.precio_base is distinct from v_precio then
        perform public.caja__log('prosegur', quien, p.id, null, p.nombre, 'precio_base', public.caja__plata(p.precio_base),
                                 public.caja__plata(v_precio), 'manual', concat_ws(' · ', 'Carga masiva', nullif(trim(p_motivo), '')));
      end if;
      if p.iva is distinct from v_iva then
        perform public.caja__log('prosegur', quien, p.id, null, p.nombre, 'iva', trim_scale(p.iva)::text || '%',
                                 trim_scale(v_iva)::text || '%', 'manual', concat_ws(' · ', 'Carga masiva', nullif(trim(p_motivo), '')));
      end if;
      if p.precio_base is distinct from v_precio or p.iva is distinct from v_iva or p.categoria is distinct from v_cat or p.tipo is distinct from v_tipo then
        update public.caja_productos set categoria = v_cat, tipo = v_tipo, precio_base = v_precio, iva = v_iva, actualizado = now() where id = p.id;
        actualizados := actualizados + 1;
      else
        iguales := iguales + 1;
      end if;
    end if;
  end loop;
  return json_build_object('nuevos', nuevos, 'actualizados', actualizados, 'sin_cambios', iguales);
end $$;

-- Sincronización pedida desde el panel o desde la caja (botón "Sincronizar productos").
-- La puede pedir cualquier usuario de la caja: solo trae lo que está habilitado en la app.
create or replace function public.caja_sync_aplicar(p_token text, p_items jsonb, p_fecha date)
returns json language plpgsql security definer set search_path = public as $$
declare u public.panel_usuarios;
begin
  u := public.caja__permiso(p_token, 'ver');
  return public.caja__sync('prosegur', p_items, p_fecha, coalesce(nullif(u.nombre, ''), u.usuario), 'manual');
end $$;

-- Sincronización automática (cron de Vercel, con la clave service_role)
create or replace function public.caja_sync_sistema(p_items jsonb, p_fecha date)
returns json language plpgsql security definer set search_path = public as $$
begin
  return public.caja__sync('prosegur', p_items, p_fecha, 'Sincronización automática', 'automatica');
end $$;

-- ---------- permisos ----------
revoke all on function public.caja__permiso(text, text) from public, anon, authenticated;
revoke all on function public.caja__log(text, text, bigint, bigint, text, text, text, text, text, text) from public, anon, authenticated;
revoke all on function public.caja__sync(text, jsonb, date, text, text) from public, anon, authenticated;
revoke all on function public.caja_sync_sistema(jsonb, date) from public, anon, authenticated;
grant execute on function public.caja_sync_sistema(jsonb, date) to service_role;
grant execute on function public.caja_catalogo(text) to anon, authenticated;
grant execute on function public.caja_historial(text, int) to anon, authenticated;
grant execute on function public.caja_producto_guardar(text, bigint, jsonb, text) to anon, authenticated;
grant execute on function public.caja_precio_local(text, bigint, numeric, text) to anon, authenticated;
grant execute on function public.caja_precio_revisado(text, bigint, text) to anon, authenticated;
grant execute on function public.caja_descuento_guardar(text, bigint, jsonb, text) to anon, authenticated;
grant execute on function public.caja_descuento_activar(text, bigint, boolean, text) to anon, authenticated;
grant execute on function public.caja_sync_aplicar(text, jsonb, date) to anon, authenticated;
grant execute on function public.caja_productos_masivo(text, jsonb, text) to anon, authenticated;

notify pgrst, 'reload schema';
