// Recibe las notificaciones de Mercado Pago sobre suscripciones y cobros.
// Se despliega sin verificación de JWT (Mercado Pago no envía sesión de Supabase); en su lugar se valida
// la firma x-signature con MP_WEBHOOK_SECRET. Nunca se confía en el cuerpo: cada recurso se vuelve a
// consultar en la API de Mercado Pago antes de tocar la base.
// Archivo autocontenido para poder pegarlo tal cual en el editor de funciones del panel de Supabase.
import 'jsr:@supabase/functions-js/edge-runtime.d.ts';
import { createClient } from 'npm:@supabase/supabase-js@2.45.4';

const responder = (status: number, body: Record<string, unknown>) =>
  new Response(JSON.stringify(body), { status, headers: { 'Content-Type': 'application/json' } });

const clienteAdmin = () =>
  createClient(Deno.env.get('SUPABASE_URL')!, Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!, { auth: { persistSession: false } });

// MP_ACCESS_TOKEN (de prueba o de producción) solo vive en los secretos de Supabase.
async function mp<T>(ruta: string): Promise<T> {
  const res = await fetch('https://api.mercadopago.com' + ruta, {
    headers: { Authorization: 'Bearer ' + Deno.env.get('MP_ACCESS_TOKEN')! },
  });
  const cuerpo = await res.json().catch(() => ({}));
  if (!res.ok) throw new Error(`Mercado Pago ${res.status} en ${ruta}: ${JSON.stringify(cuerpo)}`);
  return cuerpo as T;
}

// Estados de una suscripción (preapproval) en Mercado Pago → estados locales.
const ESTADOS: Record<string, string> = { pending: 'pendiente', authorized: 'activa', paused: 'pausada', cancelled: 'cancelada' };

type Preapproval = { id: string; status: string; external_reference: string | null; next_payment_date: string | null };
type CobroAutorizado = {
  id: number | string;
  preapproval_id: string;
  transaction_amount: number | null;
  debit_date: string | null;
  retry_attempt: number | null;
  payment: { id: number | string | null; status: string | null } | null;
};

// Firma: HMAC-SHA256 de "id:<data.id>;request-id:<x-request-id>;ts:<ts>;" con la clave secreta del webhook.
async function firmaValida(req: Request, dataId: string | null): Promise<boolean> {
  const secreto = Deno.env.get('MP_WEBHOOK_SECRET');
  const cabecera = req.headers.get('x-signature');
  if (!secreto || !cabecera) return false;
  const partes = Object.fromEntries(cabecera.split(',').map((p) => p.trim().split('=', 2) as [string, string]));
  if (!partes.ts || !partes.v1) return false;

  const requestId = req.headers.get('x-request-id');
  let manifiesto = '';
  if (dataId) manifiesto += `id:${/^[a-z0-9]+$/i.test(dataId) ? dataId.toLowerCase() : dataId};`;
  if (requestId) manifiesto += `request-id:${requestId};`;
  manifiesto += `ts:${partes.ts};`;

  const clave = await crypto.subtle.importKey('raw', new TextEncoder().encode(secreto), { name: 'HMAC', hash: 'SHA-256' }, false, ['sign']);
  const firma = new Uint8Array(await crypto.subtle.sign('HMAC', clave, new TextEncoder().encode(manifiesto)));
  const esperada = Array.from(firma, (b) => b.toString(16).padStart(2, '0')).join('');
  if (esperada.length !== partes.v1.length) return false;
  let diferencia = 0;
  for (let i = 0; i < esperada.length; i++) diferencia |= esperada.charCodeAt(i) ^ partes.v1.charCodeAt(i);
  return diferencia === 0;
}

Deno.serve(async (req) => {
  if (req.method !== 'POST') return responder(405, { error: 'Método no permitido' });

  const url = new URL(req.url);
  let cuerpo: { type?: string; action?: string; data?: { id?: string | number } } = {};
  try { cuerpo = await req.json(); } catch { /* algunas notificaciones llegan solo con query string */ }
  const tipo = url.searchParams.get('type') ?? cuerpo.type ?? null;
  const dataId = url.searchParams.get('data.id') ?? (cuerpo.data?.id != null ? String(cuerpo.data.id) : null);

  if (!(await firmaValida(req, dataId))) return responder(401, { error: 'Firma inválida' });

  const admin = clienteAdmin();
  const { data: evento } = await admin.from('eventos_webhook')
    .insert({ tipo, accion: cuerpo.action ?? null, recurso_id: dataId, request_id: req.headers.get('x-request-id'), cuerpo })
    .select('id').single();

  try {
    if (!dataId) throw new Error('Notificación sin data.id');

    if (tipo === 'subscription_preapproval') {
      const pre = await mp<Preapproval>(`/preapproval/${dataId}`);
      const cambios = {
        mp_preapproval_id: pre.id,
        estado: ESTADOS[pre.status] ?? 'pendiente',
        proximo_cobro: pre.next_payment_date,
        actualizada_en: new Date().toISOString(),
      };
      // external_reference es nuestro id de suscripción; sirve aunque mp_preapproval_id aún no se haya guardado.
      const { error } = pre.external_reference
        ? await admin.from('suscripciones').update(cambios).eq('id', pre.external_reference)
        : await admin.from('suscripciones').update(cambios).eq('mp_preapproval_id', pre.id);
      if (error) throw error;
    } else if (tipo === 'subscription_authorized_payment') {
      const cobro = await mp<CobroAutorizado>(`/authorized_payments/${dataId}`);
      const { data: sus, error: e1 } = await admin.from('suscripciones')
        .select('id').eq('mp_preapproval_id', cobro.preapproval_id).maybeSingle();
      if (e1) throw e1;
      if (!sus) throw new Error(`No hay suscripción local para el preapproval ${cobro.preapproval_id}`);

      const { error } = await admin.rpc('registrar_cobro', {
        p_suscripcion_id: sus.id,
        p_mp_authorized_payment_id: String(cobro.id),
        p_mp_payment_id: cobro.payment?.id != null ? String(cobro.payment.id) : null,
        p_estado: cobro.payment?.status ?? 'pending',
        p_monto_clp: cobro.transaction_amount != null ? Math.round(cobro.transaction_amount) : null,
        p_fecha_cobro: cobro.debit_date,
        p_intento: cobro.retry_attempt,
      });
      if (error) throw error;
    }
    // Otros tipos (payment, plan, etc.) quedan en la bitácora sin más proceso.

    if (evento) await admin.from('eventos_webhook').update({ procesado_en: new Date().toISOString() }).eq('id', evento.id);
    return responder(200, { ok: true });
  } catch (e) {
    const mensaje = e instanceof Error ? e.message : JSON.stringify(e);
    if (evento) await admin.from('eventos_webhook').update({ error: mensaje }).eq('id', evento.id);
    // Un 500 hace que Mercado Pago reintente la notificación más tarde.
    return responder(500, { error: mensaje });
  }
});
