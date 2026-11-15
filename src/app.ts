/**
 * Construccion de la aplicacion Express.
 * Se separa de servidor.ts para poder montarla en pruebas sin abrir puerto.
 */
import express, { type Application, type Request, type Response, type NextFunction } from "express";
import { crearRutasPedidos } from "./rutas/pedidos";
import { AlmacenDynamoDB, AlmacenEnMemoria, type AlmacenPedidos } from "./almacen/pedidos";

/** Elige el almacen segun haya o no tabla configurada. */
export function almacenPorDefecto(): AlmacenPedidos {
  const tabla = process.env.PEDIDOS_TABLA;
  if (tabla) return new AlmacenDynamoDB(tabla);
  console.warn("PEDIDOS_TABLA no definida: se usa almacenamiento en memoria.");
  return new AlmacenEnMemoria();
}

export function crearApp(almacen: AlmacenPedidos = almacenPorDefecto()): Application {
  const app = express();

  app.disable("x-powered-by");
  app.use(express.json({ limit: "32kb" }));

  // Registro de cada solicitud. En Fargate esta salida va a CloudWatch.
  app.use((req: Request, res: Response, siguiente: NextFunction) => {
    const inicio = Date.now();
    res.on("finish", () => {
      console.log(JSON.stringify({
        metodo: req.method,
        ruta: req.originalUrl,
        estado: res.statusCode,
        latenciaMs: Date.now() - inicio,
        entorno: process.env.ENTORNO ?? "desconocido",
        fecha: new Date().toISOString(),
      }));
    });
    siguiente();
  });

  // Sonda de salud. El campo entorno permite distinguir de un vistazo si se
  // esta hablando con el servicio de pruebas o con el de produccion.
  app.get("/health", (_req: Request, res: Response) => {
    res.status(200).json({
      estado: "ok",
      servicio: "api-pedidos",
      entorno: process.env.ENTORNO ?? "desconocido",
      tabla: process.env.PEDIDOS_TABLA ?? "memoria",
      version: process.env.VERSION_IMAGEN ?? "desarrollo",
      tiempoActivoSegundos: Math.round(process.uptime()),
    });
  });

  app.use("/pedidos", crearRutasPedidos(almacen));

  app.use((req: Request, res: Response) => {
    res.status(404).json({
      error: "RutaNoEncontrada",
      mensaje: `La ruta ${req.method} ${req.originalUrl} no existe en esta API.`,
    });
  });

  app.use((error: Error & { status?: number; type?: string }, _req: Request, res: Response, _s: NextFunction) => {
    if (error.type === "entity.parse.failed") {
      return res.status(400).json({ error: "JsonInvalido", mensaje: "El cuerpo no es JSON valido." });
    }
    console.error("Error no controlado:", error);
    res.status(error.status ?? 500).json({
      error: "ErrorInterno",
      mensaje: "Ocurrio un error inesperado procesando la solicitud.",
    });
  });

  return app;
}
