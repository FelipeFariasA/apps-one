# Apps One

Tienda de aplicaciones por suscripción: las apps se agrupan por categoría y cada cliente contrata las que necesita. El cobro es recurrente con **Mercado Pago Suscripciones** (tarjeta de crédito o débito), y el acceso a cada app se habilita o se corta según los pagos. Portal Vannucci es una de las apps a la venta.

La interfaz es `index.html`: **Tienda** (catálogo por categoría, planes y botón Suscribirme), **Mis apps** (apps habilitadas y estado de cada suscripción) e ingreso con enlace al correo. Mientras `SB_URL` tenga el valor de ejemplo, corre con datos de muestra.

## Cómo funciona

1. El usuario inicia sesión en el portal (Supabase Auth) y elige un plan.
2. El portal llama a `mp-crear-suscripcion`, que crea la suscripción en Mercado Pago y devuelve `init_point`.
3. El usuario ingresa su tarjeta en el checkout de Mercado Pago. Desde ahí Mercado Pago cobra solo cada período.
4. Mercado Pago avisa a `mp-webhook`, que vuelve a consultar el recurso en la API y actualiza la base:
   - **Cobro aprobado:** `registrar_cobro` extiende `vigente_hasta` un período.
   - **Cambio de estado** (autorizada, pausada, cancelada): se actualiza `suscripciones.estado`.
5. Cada app consulta `tiene_acceso('<app>')`. El acceso dura mientras `vigente_hasta + dias_gracia` no haya pasado. Si el cliente deja de pagar, se corta solo, sin cron.

Si alguien cancela, conserva el acceso hasta el fin del período que ya pagó.

## Estructura

| Archivo | Qué hace |
|---|---|
| `supabase/migrations/20261023000000_suscripciones.sql` | Tablas, funciones y RLS |
| `supabase/functions/mp-crear-suscripcion` | Crea la suscripción y devuelve el enlace de pago (requiere sesión) |
| `supabase/functions/mp-webhook` | Recibe las notificaciones de Mercado Pago (firma verificada) |
| `supabase/seed.sql` | Catálogo inicial: categorías, apps y planes |
| `marca/` | Manual de marca y logos |

Cada función es un solo archivo, para poder pegarla en el editor del panel de Supabase sin instalar nada.

## Puesta en marcha (desde el panel, sin instalar nada)

Todo se hace en [supabase.com/dashboard](https://supabase.com/dashboard) y en el panel de Mercado Pago. `<ref>` es el identificador del proyecto que aparece en su URL.

### 1. Crear el proyecto
- **New project** con nombre `apps-one`, **separado del de Vannucci**. Región: *South America (São Paulo)*, la más cercana a Chile.
- Guarda la contraseña de la base en un gestor de contraseñas.

### 2. Crear las tablas
- **SQL Editor → New query**: pega todo `supabase/migrations/20261023000000_suscripciones.sql` y presiona **Run**.
- Abre otra consulta, pega `supabase/seed.sql` (ajusta antes precios y apps) y presiona **Run**.
- Revisa en **Advisors → Security** que no aparezcan alertas de tablas sin RLS.

### 3. Publicar el portal
`index.html` necesita una URL `https` pública, porque Mercado Pago y los enlaces de ingreso vuelven a ella. Por ejemplo, en Vercel igual que Vannucci: un proyecto nuevo con esta carpeta, sin build. Anota la URL (por ejemplo, `https://apps-one.vercel.app`).

### 4. Configurar el ingreso por correo
- **Authentication → URL Configuration**: en *Site URL* pon la URL del portal y agrégala también en *Redirect URLs*.
- El correo de Supabase de fábrica envía pocos correos por hora. Antes de abrir a clientes, configura un SMTP propio en **Authentication → Emails → SMTP Settings**.

### 5. Mercado Pago (modo de prueba)
- En [Tus integraciones](https://www.mercadopago.cl/developers/panel/app), crea una aplicación de tipo *Suscripciones*.
- En **Cuentas de prueba**, crea un vendedor y un comprador. Entra al panel con el vendedor de prueba y copia su **Access Token** (empieza con `APP_USR-` o `TEST-`).

### 6. Desplegar las funciones
- **Edge Functions → Deploy a new function → Via Editor**:
  - nombre `mp-crear-suscripcion`: pega `supabase/functions/mp-crear-suscripcion/index.ts` y despliega;
  - nombre `mp-webhook`: pega `supabase/functions/mp-webhook/index.ts` y despliega.
- En `mp-webhook` → **Details**, desactiva **Verify JWT with legacy secret** (o "Enforce JWT verification"). Mercado Pago no envía sesión de Supabase; la seguridad la da la firma.

### 7. Webhook en Mercado Pago
- En tu aplicación: **Webhooks → Configurar notificaciones**, modo de prueba.
  - URL: `https://<ref>.supabase.co/functions/v1/mp-webhook`
  - Eventos: **Planes y suscripciones**.
- Guarda y copia la **clave secreta** que aparece.

### 8. Secretos de las funciones
**Edge Functions → Secrets**, agrega:

| Nombre | Valor |
|---|---|
| `MP_ACCESS_TOKEN` | Access Token del vendedor de prueba |
| `MP_WEBHOOK_SECRET` | Clave secreta del paso 7 |
| `PORTAL_URL` | URL del paso 3, sin `/` al final |

`SUPABASE_URL`, `SUPABASE_ANON_KEY` y `SUPABASE_SERVICE_ROLE_KEY` ya vienen incluidos.

### 9. Conectar `index.html`
- En **Project Settings → API Keys**, copia la **Publishable key**. La *Project URL* es `https://<ref>.supabase.co`.
- Reemplaza `SB_URL` y `SB_KEY` al inicio del `<script>` de `index.html` y vuelve a publicar. La clave publicable puede ir en la página; la *secret* o *service_role* nunca.

### 10. Prueba completa
1. Ingresa al portal con el **correo del comprador de prueba**: Mercado Pago exige que el pagador sea esa cuenta.
2. Elige un plan → **Suscribirme** → paga con una [tarjeta de prueba](https://www.mercadopago.cl/developers/es/docs/subscriptions/additional-content/your-integrations/test/cards), con titular `APRO`.
3. Al volver, el portal muestra "Confirmando tu pago…" y luego la app en **Mis apps**.
4. Si no se activa, revisa en **Table Editor** la tabla `eventos_webhook` (columna `error`) y en **Edge Functions → mp-webhook → Logs**.

Para pasar a producción, cambia `MP_ACCESS_TOKEN` por el de tu cuenta real y configura el webhook en modo productivo con su propia clave.

## Uso desde las apps

```js
// Portal: botón "Suscribirme"
const { data } = await supabase.functions.invoke('mp-crear-suscripcion', { body: { plan_id: 1 } });
location.href = data.init_point;

// Cada app al cargar
const { data: ok } = await supabase.rpc('tiene_acceso', { p_aplicacion: 'vannucci' });
if (!ok) location.href = 'https://tu-portal.cl/planes';
```

Las apps deben usar el **mismo proyecto Supabase Auth** que el portal, o validar contra él. El bloqueo de pantalla es solo visual. El corte real se hace añadiendo `public.tiene_acceso('<app>')` a las políticas RLS de las tablas de cada app.

## Pruebas

- Usa **usuarios de prueba** de Mercado Pago: uno vendedor (su token va en `MP_ACCESS_TOKEN`) y uno comprador. El `payer_email` debe ser el correo del comprador de prueba.
- Usa las [tarjetas de prueba de Chile](https://www.mercadopago.cl/developers/es/docs/subscriptions/additional-content/your-integrations/test/cards). El nombre del titular define el resultado: `APRO` aprueba y `OTHE` rechaza.
- Revisa `eventos_webhook`: cada notificación queda registrada, con `error` si falló. Si se responde 500, Mercado Pago reintenta.

## Pendiente

- Cancelar o cambiar de plan desde el portal (`PUT /preapproval/{id}` con `status: cancelled`).
- Boleta electrónica al SII por cada cobro aprobado.
- Invitar miembros a una cuenta empresa.
