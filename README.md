# Plataforma de Gestión de Pedidos — Despliegue automatizado en AWS

Proyecto final · Herramientas de Software II · Universidad de La Salle

API RESTful de gestión de pedidos en Node.js + TypeScript, contenerizada con
Docker, persistida en DynamoDB y desplegada con un pipeline de CI/CD de cinco
etapas que incluye pruebas unitarias y aprobación manual antes de producción.

## Endpoints

| Método | Ruta | Descripción |
|---|---|---|
| `GET` | `/health` | Estado del servicio y entorno en que corre |
| `POST` | `/pedidos` | Crea un pedido · `201` · `400` inválido |
| `GET` | `/pedidos` | Lista con filtro y orden · `?estado=&ordenarPor=&orden=` |
| `GET` | `/pedidos/{id}` | Obtiene un pedido · `200` / `404` |
| `PATCH` | `/pedidos/{id}/estado` | Cambia el estado · `200` / `404` / `409` |

Estados y transiciones permitidas:

```
PENDIENTE ──> EN_PROCESO ──> ENVIADO ──> ENTREGADO
    │              │
    └──> CANCELADO <┘
```

## Ejecución local

```bash
npm install
npm run prueba        # 33 pruebas unitarias
npm run dev           # http://localhost:3000 (almacén en memoria)
npm run probar-api    # 8 pruebas funcionales
```

Con DynamoDB: `PEDIDOS_TABLA=pedidos-pruebas npm run dev`

## Despliegue

```bash
bash infra/desplegar-aws.sh    # tablas, ECR, cluster y los dos servicios
USUARIO_GITHUB=tu-usuario REPO_GITHUB=tu-repo bash infra/crear-pipeline.sh
```

## Pipeline

```
Fuente → Construcción → Despliegue a PRUEBAS → Aprobación → Despliegue a PRODUCCIÓN
```

La etapa de construcción ejecuta las pruebas unitarias antes de construir la
imagen: si fallan, el pipeline se detiene y nada llega a desplegarse.

## Limpieza

```bash
bash infra/apagar-todo.sh
```
