/**
 * Pruebas unitarias del dominio de pedidos.
 *
 * Usan el ejecutor de pruebas que trae Node (node:test), sin dependencias
 * externas. Corren en milisegundos y sin red, que es justo lo que se
 * necesita en una etapa de integracion continua: si algo falla aqui, el
 * pipeline se detiene antes de construir la imagen.
 */
import { test, describe } from "node:test";
import assert from "node:assert/strict";
import {
  validarNuevoPedido,
  crearPedido,
  calcularTotales,
  esTransicionValida,
  filtrarYOrdenar,
  redondear,
  type Pedido,
} from "../src/dominio/pedidos";

const PEDIDO_VALIDO = {
  cliente: "Camila Rodriguez",
  correoCliente: "camila@lasalle.edu.co",
  direccionEnvio: "Carrera 5 #59A-44, Bogota",
  items: [
    { producto: "Teclado mecanico", cantidad: 2, precioUnitario: 180000 },
    { producto: "Mouse inalambrico", cantidad: 1, precioUnitario: 95000 },
  ],
};

describe("Validacion de pedidos", () => {
  test("acepta un pedido completo y correcto", () => {
    assert.deepEqual(validarNuevoPedido(PEDIDO_VALIDO), []);
  });

  test("rechaza el pedido sin cliente", () => {
    const errores = validarNuevoPedido({ ...PEDIDO_VALIDO, cliente: "   " });
    assert.equal(errores.length, 1);
    assert.equal(errores[0].campo, "cliente");
  });

  test("rechaza un correo con formato invalido", () => {
    const errores = validarNuevoPedido({ ...PEDIDO_VALIDO, correoCliente: "esto-no-es-correo" });
    assert.ok(errores.some((e) => e.campo === "correoCliente"));
  });

  test("rechaza un pedido sin productos", () => {
    const errores = validarNuevoPedido({ ...PEDIDO_VALIDO, items: [] });
    assert.ok(errores.some((e) => e.campo === "items"));
  });

  test("rechaza cantidades que no son enteros positivos", () => {
    const errores = validarNuevoPedido({
      ...PEDIDO_VALIDO,
      items: [{ producto: "Monitor", cantidad: 0, precioUnitario: 500000 }],
    });
    assert.ok(errores.some((e) => e.campo === "items[0].cantidad"));
  });

  test("rechaza precios unitarios menores o iguales a cero", () => {
    const errores = validarNuevoPedido({
      ...PEDIDO_VALIDO,
      items: [{ producto: "Monitor", cantidad: 1, precioUnitario: -10 }],
    });
    assert.ok(errores.some((e) => e.campo === "items[0].precioUnitario"));
  });

  test("rechaza un cuerpo que no es un objeto", () => {
    assert.equal(validarNuevoPedido("texto suelto").length, 1);
    assert.equal(validarNuevoPedido([1, 2, 3]).length, 1);
  });
});

describe("Calculo de totales", () => {
  test("calcula el subtotal de cada linea", () => {
    const { lineas } = calcularTotales(PEDIDO_VALIDO.items);
    assert.equal(lineas[0].subtotal, 360000);
    assert.equal(lineas[1].subtotal, 95000);
  });

  test("suma el total del pedido", () => {
    const { total } = calcularTotales(PEDIDO_VALIDO.items);
    assert.equal(total, 455000);
  });

  test("redondea a dos decimales sin arrastrar errores de punto flotante", () => {
    assert.equal(redondear(0.1 + 0.2), 0.3);
    const { total } = calcularTotales([{ producto: "Cable", cantidad: 3, precioUnitario: 10.1 }]);
    assert.equal(total, 30.3);
  });
});

describe("Creacion de pedidos", () => {
  test("asigna identificador, estado inicial y marcas de tiempo", () => {
    const pedido = crearPedido(PEDIDO_VALIDO);
    assert.match(pedido.id, /^[0-9a-f-]{36}$/);
    assert.equal(pedido.estado, "PENDIENTE");
    assert.equal(pedido.creadoEn, pedido.actualizadoEn);
    assert.equal(pedido.total, 455000);
  });

  test("normaliza el correo a minusculas y recorta espacios", () => {
    const pedido = crearPedido({ ...PEDIDO_VALIDO, correoCliente: "  Camila@LaSalle.Edu.Co " });
    assert.equal(pedido.correoCliente, "camila@lasalle.edu.co");
  });
});

describe("Maquina de estados", () => {
  test("permite el recorrido normal del pedido", () => {
    assert.ok(esTransicionValida("PENDIENTE", "EN_PROCESO"));
    assert.ok(esTransicionValida("EN_PROCESO", "ENVIADO"));
    assert.ok(esTransicionValida("ENVIADO", "ENTREGADO"));
  });

  test("permite cancelar antes del envio", () => {
    assert.ok(esTransicionValida("PENDIENTE", "CANCELADO"));
    assert.ok(esTransicionValida("EN_PROCESO", "CANCELADO"));
  });

  test("impide cancelar un pedido ya enviado", () => {
    assert.equal(esTransicionValida("ENVIADO", "CANCELADO"), false);
  });

  test("impide retroceder de estado", () => {
    assert.equal(esTransicionValida("ENVIADO", "PENDIENTE"), false);
    assert.equal(esTransicionValida("ENTREGADO", "EN_PROCESO"), false);
  });

  test("los estados finales no admiten ninguna transicion", () => {
    assert.equal(esTransicionValida("ENTREGADO", "CANCELADO"), false);
    assert.equal(esTransicionValida("CANCELADO", "PENDIENTE"), false);
  });
});

describe("Filtrado y ordenamiento", () => {
  const base = (over: Partial<Pedido>): Pedido => ({
    id: "x", cliente: "c", correoCliente: "c@d.co", direccionEnvio: "d",
    items: [], total: 0, estado: "PENDIENTE",
    creadoEn: "2026-01-01T00:00:00.000Z", actualizadoEn: "2026-01-01T00:00:00.000Z",
    ...over,
  });

  const coleccion: Pedido[] = [
    base({ id: "a", total: 100, estado: "PENDIENTE", creadoEn: "2026-01-01T00:00:00.000Z" }),
    base({ id: "b", total: 300, estado: "ENVIADO", creadoEn: "2026-01-03T00:00:00.000Z" }),
    base({ id: "c", total: 200, estado: "PENDIENTE", creadoEn: "2026-01-02T00:00:00.000Z" }),
  ];

  test("filtra por estado", () => {
    const r = filtrarYOrdenar(coleccion, { estado: "PENDIENTE" });
    assert.equal(r.length, 2);
    assert.ok(r.every((p) => p.estado === "PENDIENTE"));
  });

  test("ordena por fecha de creacion descendente de forma predeterminada", () => {
    const r = filtrarYOrdenar(coleccion);
    assert.deepEqual(r.map((p) => p.id), ["b", "c", "a"]);
  });

  test("ordena por total ascendente cuando se pide", () => {
    const r = filtrarYOrdenar(coleccion, { ordenarPor: "total", orden: "asc" });
    assert.deepEqual(r.map((p) => p.id), ["a", "c", "b"]);
  });

  test("ignora un campo de orden desconocido y usa el predeterminado", () => {
    const r = filtrarYOrdenar(coleccion, { ordenarPor: "campoInventado" });
    assert.deepEqual(r.map((p) => p.id), ["b", "c", "a"]);
  });

  test("no modifica el arreglo original", () => {
    const copia = [...coleccion];
    filtrarYOrdenar(coleccion, { ordenarPor: "total", orden: "asc" });
    assert.deepEqual(coleccion, copia);
  });
});
