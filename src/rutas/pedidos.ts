/**
 * Rutas REST de la coleccion de pedidos.
 *
 *   POST  /pedidos              crea un pedido                201
 *   GET   /pedidos              lista con filtro y orden      200
 *   GET   /pedidos/:id          obtiene uno                   200 / 404
 *   PATCH /pedidos/:id/estado   cambia el estado              200 / 404 / 409
 */
import { Router, type Request, type Response } from "express";
import {
  validarNuevoPedido,
  crearPedido,
  filtrarYOrdenar,
  esEstado,
  esTransicionValida,
  TRANSICIONES,
  ESTADOS,
  type DatosNuevoPedido,
} from "../dominio/pedidos";
import type { AlmacenPedidos } from "../almacen/pedidos";

export function crearRutasPedidos(almacen: AlmacenPedidos): Router {
  const router = Router();

  // --- Crear -------------------------------------------------------------
  router.post("/", async (req: Request, res: Response) => {
    const errores = validarNuevoPedido(req.body);
    if (errores.length > 0) {
      return res.status(400).json({
        error: "SolicitudInvalida",
        mensaje: "El cuerpo de la solicitud no supero la validacion.",
        detalles: errores,
      });
    }

    const pedido = crearPedido(req.body as DatosNuevoPedido);
    await almacen.guardar(pedido);
    res.status(201).location(`/pedidos/${pedido.id}`).json(pedido);
  });

  // --- Listar con filtro y orden ----------------------------------------
  router.get("/", async (req: Request, res: Response) => {
    const { estado, ordenarPor, orden } = req.query as Record<string, string | undefined>;

    if (estado && !esEstado(estado)) {
      return res.status(400).json({
        error: "FiltroInvalido",
        mensaje: `El estado ${estado} no existe.`,
        estadosValidos: ESTADOS,
      });
    }

    const todos = await almacen.listar();
    const resultado = filtrarYOrdenar(todos, { estado, ordenarPor, orden });

    res.status(200).json({
      total: resultado.length,
      filtro: { estado: estado ?? null },
      orden: { campo: ordenarPor ?? "creadoEn", direccion: orden === "asc" ? "asc" : "desc" },
      datos: resultado,
    });
  });

  // --- Obtener uno -------------------------------------------------------
  router.get("/:id", async (req: Request, res: Response) => {
    const pedido = await almacen.obtener(req.params.id);
    if (!pedido) {
      return res.status(404).json({
        error: "NoEncontrado",
        mensaje: `No existe un pedido con el identificador ${req.params.id}.`,
      });
    }
    res.status(200).json(pedido);
  });

  // --- Cambiar estado ----------------------------------------------------
  router.patch("/:id/estado", async (req: Request, res: Response) => {
    const nuevoEstado = (req.body ?? {}).estado;

    if (!esEstado(nuevoEstado)) {
      return res.status(400).json({
        error: "EstadoInvalido",
        mensaje: "Debe indicar un estado valido en el campo estado.",
        estadosValidos: ESTADOS,
      });
    }

    const pedido = await almacen.obtener(req.params.id);
    if (!pedido) {
      return res.status(404).json({
        error: "NoEncontrado",
        mensaje: `No existe un pedido con el identificador ${req.params.id}.`,
      });
    }

    // La maquina de estados vive en el dominio: aqui solo se consulta.
    if (!esTransicionValida(pedido.estado, nuevoEstado)) {
      return res.status(409).json({
        error: "TransicionNoPermitida",
        mensaje: `Un pedido en estado ${pedido.estado} no puede pasar a ${nuevoEstado}.`,
        transicionesPermitidas: TRANSICIONES[pedido.estado],
      });
    }

    const actualizado = await almacen.cambiarEstado(req.params.id, nuevoEstado);
    res.status(200).json(actualizado);
  });

  return router;
}
