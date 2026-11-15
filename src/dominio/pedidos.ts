/**
 * Dominio de pedidos: modelo, validacion, calculo de totales y maquina de
 * estados.
 *
 * Todo lo que hay en este archivo es logica pura, sin dependencias de
 * Express ni de AWS. Eso es deliberado: permite probarlo con pruebas
 * unitarias rapidas que no necesitan red ni base de datos, que es lo que
 * ejecuta CodeBuild en cada compilacion.
 */
import { randomUUID } from "node:crypto";

export const ESTADOS = ["PENDIENTE", "EN_PROCESO", "ENVIADO", "ENTREGADO", "CANCELADO"] as const;
export type Estado = (typeof ESTADOS)[number];

export interface LineaPedido {
  producto: string;
  cantidad: number;
  precioUnitario: number;
  subtotal: number;
}

export interface Pedido {
  id: string;
  cliente: string;
  correoCliente: string;
  direccionEnvio: string;
  items: LineaPedido[];
  total: number;
  estado: Estado;
  creadoEn: string;
  actualizadoEn: string;
}

export interface DatosNuevoPedido {
  cliente: string;
  correoCliente: string;
  direccionEnvio: string;
  items: { producto: string; cantidad: number; precioUnitario: number }[];
}

export interface ErrorValidacion {
  campo: string;
  mensaje: string;
}

const CORREO_VALIDO = /^[^\s@]+@[^\s@]+\.[^\s@]{2,}$/;

/**
 * Transiciones permitidas entre estados.
 *
 * Modelar esto como un grafo explicito evita que un pedido entregado vuelva
 * a "pendiente" o que uno cancelado siga avanzando. Es la regla de negocio
 * mas facil de romper por accidente y la mas facil de proteger con pruebas.
 */
export const TRANSICIONES: Record<Estado, Estado[]> = {
  PENDIENTE: ["EN_PROCESO", "CANCELADO"],
  EN_PROCESO: ["ENVIADO", "CANCELADO"],
  ENVIADO: ["ENTREGADO"],
  ENTREGADO: [],
  CANCELADO: [],
};

export function esTransicionValida(desde: Estado, hacia: Estado): boolean {
  return TRANSICIONES[desde]?.includes(hacia) ?? false;
}

export function esEstado(valor: unknown): valor is Estado {
  return typeof valor === "string" && (ESTADOS as readonly string[]).includes(valor);
}

/** Redondea a dos decimales evitando los errores del punto flotante. */
export function redondear(valor: number): number {
  return Math.round((valor + Number.EPSILON) * 100) / 100;
}

/** Calcula el subtotal de cada linea y el total del pedido. */
export function calcularTotales(
  items: DatosNuevoPedido["items"]
): { lineas: LineaPedido[]; total: number } {
  const lineas = items.map((i) => ({
    producto: i.producto.trim(),
    cantidad: i.cantidad,
    precioUnitario: redondear(i.precioUnitario),
    subtotal: redondear(i.cantidad * i.precioUnitario),
  }));
  const total = redondear(lineas.reduce((suma, l) => suma + l.subtotal, 0));
  return { lineas, total };
}

/** Valida el cuerpo de un POST /pedidos. Arreglo vacio significa correcto. */
export function validarNuevoPedido(cuerpo: unknown): ErrorValidacion[] {
  const errores: ErrorValidacion[] = [];

  if (typeof cuerpo !== "object" || cuerpo === null || Array.isArray(cuerpo)) {
    return [{ campo: "cuerpo", mensaje: "Se esperaba un objeto JSON." }];
  }
  const datos = cuerpo as Record<string, unknown>;

  for (const campo of ["cliente", "direccionEnvio"] as const) {
    const valor = datos[campo];
    if (typeof valor !== "string" || valor.trim().length === 0) {
      errores.push({ campo, mensaje: `El campo ${campo} es obligatorio.` });
    }
  }

  const correo = datos.correoCliente;
  if (typeof correo !== "string" || !CORREO_VALIDO.test(correo.trim())) {
    errores.push({ campo: "correoCliente", mensaje: "El correo del cliente no es valido." });
  }

  const items = datos.items;
  if (!Array.isArray(items) || items.length === 0) {
    errores.push({ campo: "items", mensaje: "El pedido debe tener al menos un producto." });
  } else {
    items.forEach((item, indice) => {
      const linea = item as Record<string, unknown>;
      if (typeof linea.producto !== "string" || linea.producto.trim().length === 0) {
        errores.push({ campo: `items[${indice}].producto`, mensaje: "El producto es obligatorio." });
      }
      if (typeof linea.cantidad !== "number" || !Number.isInteger(linea.cantidad) || linea.cantidad < 1) {
        errores.push({ campo: `items[${indice}].cantidad`, mensaje: "La cantidad debe ser un entero mayor que cero." });
      }
      if (typeof linea.precioUnitario !== "number" || linea.precioUnitario <= 0) {
        errores.push({ campo: `items[${indice}].precioUnitario`, mensaje: "El precio unitario debe ser mayor que cero." });
      }
    });
  }

  return errores;
}

/** Construye un pedido nuevo ya validado, con su total y su estado inicial. */
export function crearPedido(datos: DatosNuevoPedido): Pedido {
  const { lineas, total } = calcularTotales(datos.items);
  const ahora = new Date().toISOString();
  return {
    id: randomUUID(),
    cliente: datos.cliente.trim(),
    correoCliente: datos.correoCliente.trim().toLowerCase(),
    direccionEnvio: datos.direccionEnvio.trim(),
    items: lineas,
    total,
    estado: "PENDIENTE",
    creadoEn: ahora,
    actualizadoEn: ahora,
  };
}

export type CampoOrden = "creadoEn" | "total" | "estado";
export type Direccion = "asc" | "desc";

/** Filtra por estado y ordena la coleccion segun los criterios indicados. */
export function filtrarYOrdenar(
  pedidos: Pedido[],
  opciones: { estado?: string; ordenarPor?: string; orden?: string } = {}
): Pedido[] {
  let resultado = pedidos;

  if (opciones.estado) {
    resultado = resultado.filter((p) => p.estado === opciones.estado);
  }

  const campo: CampoOrden = (["creadoEn", "total", "estado"] as const).includes(
    opciones.ordenarPor as CampoOrden
  )
    ? (opciones.ordenarPor as CampoOrden)
    : "creadoEn";
  const direccion: Direccion = opciones.orden === "asc" ? "asc" : "desc";

  const ordenados = [...resultado].sort((a, b) => {
    const va = a[campo];
    const vb = b[campo];
    if (typeof va === "number" && typeof vb === "number") return va - vb;
    return String(va).localeCompare(String(vb));
  });

  return direccion === "asc" ? ordenados : ordenados.reverse();
}
