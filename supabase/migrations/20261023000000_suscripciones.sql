-- Apps One: tienda de aplicaciones por suscripción, con cobro recurrente en Mercado Pago.
-- El acceso se calcula al consultar (vigente_hasta + días de gracia), así que una suscripción
-- impaga se corta sola sin procesos programados. Los clientes solo leen; toda escritura la hacen
-- las Edge Functions con la clave de servicio.

-- Catálogo -----------------------------------------------------------------

create table public.categorias (
  id     text primary key,                -- identificador corto, ej. 'gestion'
  nombre text not null,
  orden  smallint not null default 0
);

create table public.aplicaciones (
  id           text primary key,          -- identificador corto, ej. 'vannucci'
  categoria_id text references public.categorias (id) on delete set null,
  nombre       text not null,
  descripcion  text,
  url          text,
  activa       boolean not null default true
);
create index aplicaciones_categoria_idx on public.aplicaciones (categoria_id);

create table public.planes (
  id               bigint generated always as identity primary key,
  nombre           text not null,
  precio_clp       integer not null check (precio_clp > 0),     -- CLP no tiene decimales
  frecuencia_meses smallint not null default 1 check (frecuencia_meses between 1 and 12),
  dias_gracia      smallint not null default 5 check (dias_gracia >= 0),
  activo           boolean not null default true
);

create table public.plan_aplicaciones (
  plan_id       bigint not null references public.planes (id) on delete cascade,
  aplicacion_id text   not null references public.aplicaciones (id) on delete cascade,
  primary key (plan_id, aplicacion_id)
);
create index plan_aplicaciones_aplicacion_idx on public.plan_aplicaciones (aplicacion_id);

-- Clientes -----------------------------------------------------------------
-- Una cuenta paga y sus miembros usan las apps. Un cliente persona es una cuenta de un solo miembro.

create table public.cuentas (
  id                uuid primary key default gen_random_uuid(),
  nombre            text not null,
  rut               text,
  email_facturacion text,
  creada_en         timestamptz not null default now()
);

create table public.miembros (
  cuenta_id uuid not null references public.cuentas (id) on delete cascade,
  user_id   uuid not null references auth.users (id) on delete cascade,
  rol       text not null default 'miembro' check (rol in ('dueno', 'miembro')),
  primary key (cuenta_id, user_id)
);
create index miembros_user_idx on public.miembros (user_id);

-- Suscripciones y cobros ---------------------------------------------------

create table public.suscripciones (
  id                uuid primary key default gen_random_uuid(),  -- va a Mercado Pago como external_reference
  cuenta_id         uuid   not null references public.cuentas (id) on delete restrict,
  plan_id           bigint not null references public.planes (id) on delete restrict,
  mp_preapproval_id text unique,
  estado            text not null default 'pendiente'
                    check (estado in ('pendiente', 'activa', 'pausada', 'cancelada')),
  vigente_hasta     timestamptz,             -- se extiende con cada cobro aprobado
  proximo_cobro     timestamptz,
  creada_en         timestamptz not null default now(),
  actualizada_en    timestamptz not null default now()
);
create index suscripciones_cuenta_idx on public.suscripciones (cuenta_id);
create index suscripciones_plan_idx on public.suscripciones (plan_id);
-- Una sola suscripción viva por cuenta y plan.
create unique index suscripciones_viva_uidx on public.suscripciones (cuenta_id, plan_id)
  where estado in ('pendiente', 'activa', 'pausada');

create table public.pagos (
  id                       bigint generated always as identity primary key,
  suscripcion_id           uuid not null references public.suscripciones (id) on delete cascade,
  mp_authorized_payment_id text not null unique,
  mp_payment_id            text,
  estado                   text not null,     -- estado del pago en Mercado Pago: approved, rejected, ...
  monto_clp                integer,
  fecha_cobro              timestamptz,
  intento                  smallint,
  aprobado_en              timestamptz,
  actualizado_en           timestamptz not null default now()
);
create index pagos_suscripcion_idx on public.pagos (suscripcion_id);

-- Bitácora de notificaciones recibidas, para auditar y reprocesar.
create table public.eventos_webhook (
  id           bigint generated always as identity primary key,
  recibido_en  timestamptz not null default now(),
  tipo         text,
  accion       text,
  recurso_id   text,
  request_id   text,
  cuerpo       jsonb,
  procesado_en timestamptz,
  error        text
);

-- Cotizaciones de desarrollo a medida ---------------------------------------
-- Cualquier visita puede enviar una; solo el equipo (service_role o el panel de Supabase) las lee.

create table public.cotizaciones (
  id          bigint generated always as identity primary key,
  nombre      text not null check (char_length(nombre) between 2 and 120),
  email       text not null check (char_length(email) <= 254 and email ~* '^[^@\s]+@[^@\s]+\.[^@\s]+$'),
  empresa     text check (char_length(empresa) <= 120),
  necesidad   text not null check (char_length(necesidad) between 10 and 2000),
  presupuesto text check (presupuesto in ('hasta_2m', '2m_5m', '5m_15m', 'mas_15m', 'no_se')),
  user_id     uuid references auth.users (id) on delete set null default auth.uid(),
  estado      text not null default 'nueva' check (estado in ('nueva', 'en_revision', 'cotizada', 'descartada')),
  creada_en   timestamptz not null default now()
);
create index cotizaciones_pendientes_idx on public.cotizaciones (creada_en) where estado = 'nueva';

-- Funciones ----------------------------------------------------------------

-- Cuentas del usuario conectado. Security definer para que las políticas no se llamen en círculo.
create function public.mis_cuentas()
returns setof uuid
language sql stable security definer set search_path = ''
as $$
  select cuenta_id from public.miembros where user_id = (select auth.uid());
$$;

-- ¿El usuario conectado puede usar esta aplicación? La llama cada app al cargar.
create function public.tiene_acceso(p_aplicacion text)
returns boolean
language sql stable security definer set search_path = ''
as $$
  select exists (
    select 1
    from public.miembros m
    join public.suscripciones s     on s.cuenta_id = m.cuenta_id
    join public.planes p            on p.id = s.plan_id
    join public.plan_aplicaciones pa on pa.plan_id = p.id
    join public.aplicaciones a      on a.id = pa.aplicacion_id
    where m.user_id = (select auth.uid())
      and pa.aplicacion_id = p_aplicacion
      and a.activa
      and s.vigente_hasta + make_interval(days => p.dias_gracia) > now()
  );
$$;

-- Aplicaciones habilitadas para el usuario conectado, para armar el menú del portal.
create function public.aplicaciones_habilitadas()
returns table (aplicacion_id text, nombre text, url text, vigente_hasta timestamptz)
language sql stable security definer set search_path = ''
as $$
  select a.id, a.nombre, a.url, max(s.vigente_hasta)
  from public.miembros m
  join public.suscripciones s     on s.cuenta_id = m.cuenta_id
  join public.planes p            on p.id = s.plan_id
  join public.plan_aplicaciones pa on pa.plan_id = p.id
  join public.aplicaciones a      on a.id = pa.aplicacion_id
  where m.user_id = (select auth.uid())
    and a.activa
    and s.vigente_hasta + make_interval(days => p.dias_gracia) > now()
  group by a.id, a.nombre, a.url;
$$;

-- Registra un cobro informado por Mercado Pago. Idempotente: el mismo cobro puede llegar varias
-- veces, pero la vigencia se extiende solo la primera vez que aparece aprobado.
create function public.registrar_cobro(
  p_suscripcion_id           uuid,
  p_mp_authorized_payment_id text,
  p_mp_payment_id            text,
  p_estado                   text,
  p_monto_clp                integer,
  p_fecha_cobro              timestamptz,
  p_intento                  smallint
)
returns void
language plpgsql security definer set search_path = ''
as $$
declare
  v_estado_previo text;
  v_frecuencia    smallint;
begin
  -- Bloquea la suscripción para que dos notificaciones simultáneas no extiendan dos veces.
  select p.frecuencia_meses into v_frecuencia
  from public.suscripciones s join public.planes p on p.id = s.plan_id
  where s.id = p_suscripcion_id
  for update of s;
  if not found then
    raise exception 'Suscripción % no existe', p_suscripcion_id;
  end if;

  select estado into v_estado_previo
  from public.pagos where mp_authorized_payment_id = p_mp_authorized_payment_id;

  insert into public.pagos as pg (suscripcion_id, mp_authorized_payment_id, mp_payment_id, estado,
                                  monto_clp, fecha_cobro, intento, aprobado_en)
  values (p_suscripcion_id, p_mp_authorized_payment_id, p_mp_payment_id, p_estado,
          p_monto_clp, p_fecha_cobro, p_intento,
          case when p_estado = 'approved' then now() end)
  on conflict (mp_authorized_payment_id) do update set
    mp_payment_id  = coalesce(excluded.mp_payment_id, pg.mp_payment_id),
    estado         = excluded.estado,
    monto_clp      = coalesce(excluded.monto_clp, pg.monto_clp),
    fecha_cobro    = coalesce(excluded.fecha_cobro, pg.fecha_cobro),
    intento        = coalesce(excluded.intento, pg.intento),
    aprobado_en    = coalesce(pg.aprobado_en, excluded.aprobado_en),
    actualizado_en = now();

  if p_estado = 'approved' and v_estado_previo is distinct from 'approved' then
    update public.suscripciones set
      vigente_hasta  = greatest(coalesce(vigente_hasta, now()), coalesce(p_fecha_cobro, now()))
                       + make_interval(months => v_frecuencia),
      estado         = case when estado = 'pendiente' then 'activa' else estado end,
      actualizada_en = now()
    where id = p_suscripcion_id;
  end if;
end;
$$;

-- Supabase da EXECUTE a anon y authenticated por defecto: registrar_cobro queda solo para el servidor.
revoke execute on function public.registrar_cobro(uuid, text, text, text, integer, timestamptz, smallint)
  from public, anon, authenticated;
grant execute on function public.registrar_cobro(uuid, text, text, text, integer, timestamptz, smallint)
  to service_role;
revoke execute on function public.tiene_acceso(text), public.aplicaciones_habilitadas(), public.mis_cuentas()
  from public, anon;

-- Seguridad por filas --------------------------------------------------------
-- Solo lectura para los clientes; sin políticas de escritura.

alter table public.categorias        enable row level security;
alter table public.aplicaciones      enable row level security;
alter table public.planes            enable row level security;
alter table public.plan_aplicaciones enable row level security;
alter table public.cuentas           enable row level security;
alter table public.miembros          enable row level security;
alter table public.suscripciones     enable row level security;
alter table public.pagos             enable row level security;
alter table public.eventos_webhook   enable row level security;  -- sin políticas: solo service_role
alter table public.cotizaciones      enable row level security;

-- Solo insertar, siempre como nueva y a nombre propio (o sin usuario si no ha iniciado sesión).
create policy "enviar cotización" on public.cotizaciones
  for insert to anon, authenticated
  with check (estado = 'nueva' and (user_id is null or user_id = (select auth.uid())));

create policy "categorías visibles" on public.categorias
  for select to anon, authenticated using (true);
create policy "catálogo visible" on public.aplicaciones
  for select to anon, authenticated using (activa);
create policy "planes visibles" on public.planes
  for select to anon, authenticated using (activo);
create policy "contenido de planes visible" on public.plan_aplicaciones
  for select to anon, authenticated using (true);

create policy "ver mis cuentas" on public.cuentas
  for select to authenticated using (id in (select public.mis_cuentas()));
create policy "ver miembros de mis cuentas" on public.miembros
  for select to authenticated using (cuenta_id in (select public.mis_cuentas()));
create policy "ver mis suscripciones" on public.suscripciones
  for select to authenticated using (cuenta_id in (select public.mis_cuentas()));
create policy "ver mis pagos" on public.pagos
  for select to authenticated using (
    suscripcion_id in (select id from public.suscripciones where cuenta_id in (select public.mis_cuentas()))
  );
