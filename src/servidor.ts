/** Punto de entrada del proceso. */
import { crearApp } from "./app";

const PUERTO = Number(process.env.PORT ?? 3000);
const app = crearApp();

const servidor = app.listen(PUERTO, "0.0.0.0", () => {
  console.log(`API de pedidos escuchando en el puerto ${PUERTO}`);
  console.log(`Entorno: ${process.env.ENTORNO ?? "desconocido"} - tabla: ${process.env.PEDIDOS_TABLA ?? "memoria"}`);
});

// ECS envia SIGTERM al detener la tarea y espera 30 segundos. Cerrar a
// tiempo evita cortar solicitudes en curso durante un despliegue.
for (const senal of ["SIGTERM", "SIGINT"] as const) {
  process.on(senal, () => {
    console.log(`Senal ${senal} recibida, cerrando el servidor...`);
    servidor.close(() => {
      console.log("Servidor cerrado correctamente.");
      process.exit(0);
    });
  });
}
