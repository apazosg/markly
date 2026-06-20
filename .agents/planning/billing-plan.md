---
id: billing-plan
state: draft
date: 2026-06-19
---

# Plan de facturación — Markly

> Reubicado a `.agents/planning/` el 2026-06-19. Trabajo **pendiente de desarrollar** (Stripe freemium con créditos). El sistema de créditos ya implementado en el backend está en `markly-backend/.agents/specs/US-004`.

## Modelo: créditos de horas (pay-as-you-go)

Sin suscripción. El usuario compra un paquete de horas y las consume a su ritmo.

### Paquetes (orientativos)

| Paquete | Precio | Horas | €/hora | Coste infra | Margen neto* |
|---|---|---|---|---|---|
| Starter | €5 | 5h | €1.00 | €1.45 | ~64% |
| Standard | €10 | 12h | €0.83 | €3.48 | ~62% |
| Pro | €20 | 30h | €0.67 | €8.70 | ~54% |

*Después de Stripe fees (~1.5% + €0.25 por transacción)

**Coste de infraestructura por hora:** ~€0.29 (Deepgram Whisper ~€0.24 + Gemini 2.5 Flash ~€0.05)

### Reglas
- Compra mínima: €5 (5 horas)
- Los créditos comprados no caducan nunca
- Sin tarjeta guardada — cada compra es un pago único
- Al registrarse: **30 minutos gratuitos** añadidos al saldo (regalo único de bienvenida)
- Cada mes: **franquicia de 30 minutos** — los primeros 30 min del mes no descuentan saldo; el resto sí

---

## Stack técnico

**Proveedor:** Stripe (pago único, no suscripción recurrente)
- Stripe Checkout en modo `payment` (no `subscription`)
- Stripe Tax para IVA europeo automático
- Sin SDK nativo en Flutter — solo `url_launcher`
- Distribución APK directa (fuera de Play Store)

**Flujo de compra:**
```
Flutter
  → POST /billing/checkout  { package: "starter" }
  → Backend crea Stripe Checkout Session (mode: payment)
  → url_launcher abre checkout.stripe.com
  → Usuario paga
  → Stripe Webhook → POST /billing/webhook
  → Backend suma segundos al saldo del usuario en DB
  → Flutter refresca GET /billing/status
```

**Control de acceso en transcripción:**
```
POST /sessions (subir audio)
  → calcular duración del audio
  → si credits_seconds >= duración → permitir y reservar
  → si no → 402 con saldo y enlace de recarga
  → al finalizar transcripción → descontar segundos reales procesados
```

---

## Cambios en DB (cuando se implemente)

```sql
ALTER TABLE users ADD COLUMN credits_seconds         INT DEFAULT 1800;  -- 30 min bienvenida
ALTER TABLE users ADD COLUMN monthly_free_used_s     INT DEFAULT 0;     -- segundos de franquicia usados este mes
ALTER TABLE users ADD COLUMN monthly_free_reset_at   TIMESTAMP;         -- inicio del mes actual
ALTER TABLE users ADD COLUMN stripe_customer_id      TEXT;
```

**Lógica de descuento al procesar audio** — lazy reset, sin cron job:
```python
MONTHLY_FREE_SECONDS = 1800  # 30 min

# 1. Reset mensual si ha pasado el período
if monthly_free_reset_at is None or now() > monthly_free_reset_at + 30 days:
    monthly_free_used_s = 0
    monthly_free_reset_at = now()

# 2. Calcular cuánto cubre la franquicia esta sesión
free_available = max(0, MONTHLY_FREE_SECONDS - monthly_free_used_s)
free_used      = min(duration_s, free_available)
paid_s         = duration_s - free_used

# 3. Aplicar
monthly_free_used_s += free_used
credits_seconds     -= paid_s  # solo descuenta lo que no cubre la franquicia
```

## Endpoints nuevos

| Método | Ruta | Descripción |
|---|---|---|
| `POST` | `/billing/checkout` | Crea Checkout Session, devuelve URL |
| `POST` | `/billing/webhook` | Eventos Stripe → suma créditos |
| `GET` | `/billing/status` | Saldo actual en segundos |

## Dependencias a añadir

```toml
stripe>=10.0.0
```

---

## Flutter

- Pantalla de cuenta: saldo en horas/minutos + botón "Comprar horas"
- Selector de paquete → `POST /billing/checkout` → `url_launcher`
- Tras volver a la app: refresca saldo desde `GET /billing/status`

---

## Decisiones pendientes

- [ ] Confirmar precios y horas de cada paquete

## Decisiones tomadas
- **Caducidad:** los créditos no caducan nunca
- **Bloqueo:** antes de subir el audio — Flutter consulta `GET /billing/status`, compara con la duración local del archivo y muestra pantalla de recarga si no hay saldo suficiente. El audio nunca se sube si no hay créditos.
