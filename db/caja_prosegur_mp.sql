-- =====================================================================
-- EASY LUNCH · Local Prosegur — cobro con QR de Mercado Pago (API de Orders)
-- Correr en Supabase → SQL Editor DESPUÉS de caja_prosegur.sql y caja_prosegur_ventas.sql.
-- Se puede volver a correr sin romper nada.
--
-- Flujo: la caja pide una orden (caja_mp_preparar) → el servidor (api/caja-mp.js) la crea en
-- Mercado Pago y muestra el QR → cuando Mercado Pago dice "processed" el servidor registra la venta
-- (caja_mp_confirmar) con los precios congelados al momento de generar el QR.
-- Las funciones que tocan el resultado del pago solo las puede llamar el servidor (service_role).
-- =====================================================================

create table if not exists public.caja_mp_ordenes (
  id           bigint generated always as identity primary key,
  local        text not null default 'prosegur',
  turno_id     bigint not null references public.caja_turnos(id),
  usuario      text not null default '',
  client_id    text not null unique,
  ref          text unique,                 -- external_reference en Mercado Pago
  calc         jsonb not null,              -- líneas y totales congelados
  total        numeric(12,2) not null,
  mp_order_id  text unique,
  qr_data      text,
  estado       text not null default 'pendiente' check (estado in ('pendiente','creada','pagada','cancelada','expirada','error')),
  detalle      text not null default '',
  venta_id     bigint references public.caja_ventas(id),
  creado       timestamptz not null default now(),
  actualizado  timestamptz not null default now()
);
create index if not exists caja_mp_ordenes_estado on public.caja_mp_ordenes (local, estado, creado);
alter table public.caja_mp_ordenes enable row level security;
revoke all on public.caja_mp_ordenes from anon, authenticated;

-- La caja pide cobrar con QR: valida precios igual que una venta común y deja la orden preparada.
create or replace function public.caja_mp_preparar(p_token text, p_items jsonb, p_total_esperado numeric, p_client_id text)
returns json language plpgsql security definer set search_path = public as $$
declare u public.panel_usuarios; t public.caja_turnos; c jsonb; v_tot numeric; o public.caja_mp_ordenes;
begin
  u := public.caja__permiso(p_token, 'ver');
  if coalesce(trim(p_client_id), '') = '' then raise exception 'Falta el identificador del cobro.'; end if;
  select * into o from public.caja_mp_ordenes where client_id = p_client_id;
  if o.id is not null then
    return json_build_object('id', o.id, 'ref', o.ref, 'total', o.total, 'estado', o.estado, 'mp_order_id', o.mp_order_id, 'qr_data', o.qr_data, 'venta_id', o.venta_id);
  end if;
  t := public.caja__turno_abierto('prosegur');
  if t.id is null then raise exception 'La caja está cerrada. Abrila para vender.'; end if;
  c := public.caja__calcular(p_items);
  v_tot := (c->>'tot')::numeric;
  if p_total_esperado is null or abs(v_tot - p_total_esperado) > 0.01 then
    raise exception 'Los precios cambiaron mientras armabas el ticket (total actualizado: %). Revisá el ticket y cobrá de nuevo.', public.caja__plata(v_tot);
  end if;
  if v_tot <= 0 then raise exception 'El total tiene que ser mayor a cero para cobrar con QR.'; end if;
  insert into public.caja_mp_ordenes(local, turno_id, usuario, client_id, calc, total)
  values ('prosegur', t.id, public.caja__quien(u), p_client_id, c, v_tot) returning * into o;
  update public.caja_mp_ordenes set ref = 'ELPROSEGUR-' || o.id where id = o.id returning * into o;
  return json_build_object('id', o.id, 'ref', o.ref, 'total', o.total, 'estado', o.estado, 'mp_order_id', null, 'qr_data', null, 'venta_id', null,
                           'lineas', (select jsonb_agg(jsonb_build_object('nombre', l->>'nombre', 'cant', (l->>'cant')::int, 'unit', (l->>'unit')::numeric))
                                      from jsonb_array_elements(c->'lineas') l));
end $$;

-- Consulta de una orden (la caja que la generó o cualquier usuario de la caja)
create or replace function public.caja_mp_orden(p_token text, p_id bigint)
returns json language plpgsql stable security definer set search_path = public as $$
declare o public.caja_mp_ordenes;
begin
  perform public.caja__permiso(p_token, 'ver');
  select * into o from public.caja_mp_ordenes where id = p_id and local = 'prosegur';
  if o.id is null then raise exception 'No encontré ese cobro.'; end if;
  return json_build_object('id', o.id, 'ref', o.ref, 'total', o.total, 'estado', o.estado, 'mp_order_id', o.mp_order_id, 'venta_id', o.venta_id, 'creado', o.creado);
end $$;

-- Órdenes generadas en las últimas 2 horas que todavía no se confirmaron (para conciliar)
create or replace function public.caja_mp_pendientes(p_token text)
returns json language plpgsql stable security definer set search_path = public as $$
begin
  perform public.caja__permiso(p_token, 'ver');
  return coalesce((select json_agg(json_build_object('id', id, 'mp_order_id', mp_order_id, 'total', total, 'creado', creado) order by creado)
                   from public.caja_mp_ordenes where local = 'prosegur' and estado = 'creada' and mp_order_id is not null
                     and creado > now() - interval '2 hours'), '[]');
end $$;

-- ---------- solo servidor (service_role) ----------
create or replace function public.caja_mp_vincular(p_id bigint, p_mp_order_id text, p_qr_data text)
returns void language sql security definer set search_path = public as $$
  update public.caja_mp_ordenes set mp_order_id = p_mp_order_id, qr_data = p_qr_data, estado = 'creada', actualizado = now()
  where id = p_id and estado in ('pendiente','creada');
$$;

create or replace function public.caja_mp_marcar(p_id bigint, p_estado text, p_detalle text)
returns void language sql security definer set search_path = public as $$
  update public.caja_mp_ordenes set estado = p_estado, detalle = left(coalesce(p_detalle, ''), 300), actualizado = now()
  where id = p_id and estado <> 'pagada' and p_estado in ('cancelada','expirada','error');
$$;

-- Mercado Pago confirmó el pago: registra la venta con los precios congelados. Idempotente.
create or replace function public.caja_mp_confirmar(p_id bigint, p_mp_order_id text, p_monto numeric)
returns json language plpgsql security definer set search_path = public as $$
declare o public.caja_mp_ordenes; v_turno bigint; v_id bigint;
begin
  select * into o from public.caja_mp_ordenes where id = p_id for update;
  if o.id is null then raise exception 'Orden inexistente.'; end if;
  if o.venta_id is not null then return json_build_object('venta_id', o.venta_id, 'total', o.total, 'repetida', true); end if;
  if o.mp_order_id is distinct from p_mp_order_id then raise exception 'La orden de Mercado Pago no coincide.'; end if;
  if p_monto is null or abs(p_monto - o.total) > 0.01 then raise exception 'El monto pagado (%) no coincide con el total (%).', p_monto, o.total; end if;
  -- la venta va al turno donde se generó el QR; si ya se cerró, al turno abierto (si hay)
  v_turno := o.turno_id;
  if (select cerrado from public.caja_turnos where id = o.turno_id) is not null then
    v_turno := coalesce((public.caja__turno_abierto('prosegur')).id, o.turno_id);
  end if;
  v_id := public.caja__insertar_venta(v_turno, o.usuario, 'qr', o.calc, null, 'mp:' || o.client_id, o.mp_order_id);
  update public.caja_mp_ordenes set estado = 'pagada', venta_id = v_id, detalle = '', actualizado = now() where id = o.id;
  return json_build_object('venta_id', v_id, 'total', o.total);
end $$;

create or replace function public.caja_mp_config()
returns jsonb language sql stable security definer set search_path = public as $$
  select valor from public.caja_config where local = 'prosegur' and clave = 'mp_caja';
$$;

create or replace function public.caja_mp_config_guardar(p_valor jsonb)
returns void language sql security definer set search_path = public as $$
  insert into public.caja_config(local, clave, valor) values ('prosegur', 'mp_caja', p_valor)
  on conflict (local, clave) do update set valor = excluded.valor;
$$;

-- Permiso para configurar la caja de Mercado Pago (lo valida el servidor antes de crear sucursal y caja)
create or replace function public.caja_mp_permiso_admin(p_token text)
returns json language plpgsql stable security definer set search_path = public as $$
declare u public.panel_usuarios;
begin
  u := public.caja__permiso(p_token, 'admin');
  return json_build_object('ok', true, 'nombre', public.caja__quien(u));
end $$;

-- ---------- permisos ----------
grant execute on function public.caja_mp_preparar(text, jsonb, numeric, text) to anon, authenticated;
grant execute on function public.caja_mp_orden(text, bigint) to anon, authenticated;
grant execute on function public.caja_mp_pendientes(text) to anon, authenticated;
grant execute on function public.caja_mp_permiso_admin(text) to anon, authenticated;
revoke all on function public.caja_mp_vincular(bigint, text, text) from public, anon, authenticated;
revoke all on function public.caja_mp_marcar(bigint, text, text) from public, anon, authenticated;
revoke all on function public.caja_mp_confirmar(bigint, text, numeric) from public, anon, authenticated;
revoke all on function public.caja_mp_config() from public, anon, authenticated;
revoke all on function public.caja_mp_config_guardar(jsonb) from public, anon, authenticated;
grant execute on function public.caja_mp_vincular(bigint, text, text) to service_role;
grant execute on function public.caja_mp_marcar(bigint, text, text) to service_role;
grant execute on function public.caja_mp_confirmar(bigint, text, numeric) to service_role;
grant execute on function public.caja_mp_config() to service_role;
grant execute on function public.caja_mp_config_guardar(jsonb) to service_role;

notify pgrst, 'reload schema';
